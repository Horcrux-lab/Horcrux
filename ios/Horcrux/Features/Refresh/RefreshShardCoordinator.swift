import Foundation
import Combine

/// Drives a CGGMP21 proactive key refresh ceremony for a single account.
///
/// Both phones must be online and connected to the same room (via the existing
/// `PeerManager` relay channel). On success the local Keychain entry for the
/// account's encrypted shard is atomically replaced; the wallet's group public
/// key (and therefore on-chain address) is unchanged.
///
/// Scope (Phase A):
/// - n-of-n only (currently exclusively 2-of-2 in the app)
/// - Same parties, same threshold — this is **proactive refresh**, not
///   replace-device. Lost-device migration is still the existing flow.
@MainActor
final class RefreshShardCoordinator: ObservableObject {
    enum Phase: Equatable {
        case idle
        case waitingForPeer
        case running
        case persisting
        case complete
        case error(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var roundsCompleted: Int = 0
    /// Approximate target — CGGMP21 key_refresh runs ~5 rounds; we use this
    /// only for the progress bar.
    let approxTotalRounds: Int = 5

    /// Wallet whose underlying account shard is being refreshed.
    let wallet: Wallet
    private let appState: AppState

    private var sessionId: String?
    private var refreshTask: Task<Void, Never>?
    /// Holder of the in-flight Shard Wrap Key. Zeroed on completion.
    private var swk: Data?
    private var cancellables = Set<AnyCancellable>()

    init(wallet: Wallet, appState: AppState) {
        self.wallet = wallet
        self.appState = appState

        // Auto-advance from .waitingForPeer → .running as soon as the
        // peer count meets the threshold. Without this the user would
        // have to tap "Start" a second time after their partner joins.
        //
        // We observe BOTH connectedPeers (Noise-encrypted channels like
        // BLE / Wi-Fi Direct) AND allPeers (local-trusted transports
        // like Wi-Fi LAN / Relay, which never populate connectedPeers).
        // `broadcastMpcMessage` falls back to allPeers when connected
        // is empty, so gating on connected alone would make those
        // transports wait forever.
        Publishers.CombineLatest(
            appState.peerManager.$connectedPeers,
            appState.peerManager.$allPeers
        )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                guard let self else { return }
                guard self.phase == .waitingForPeer else { return }
                if self.hasEnoughPeers, self.swk != nil {
                    self.start()
                }
            }
            .store(in: &cancellables)
    }

    /// Effective reachable-peer count across all transports. Matches the
    /// fallback rule used by `PeerManager.broadcastMpcMessage`.
    private var hasEnoughPeers: Bool {
        let pm = appState.peerManager
        let effective = pm.connectedPeers.isEmpty ? pm.allPeers.count : pm.connectedPeers.count
        return effective >= Int(wallet.totalParties) - 1
    }

    /// Inject the unwrapped SWK before calling `start()`. The sheet pulls it
    /// from `appState.cachedShardKey()` after PIN verification.
    func setShardKey(_ key: Data) {
        self.swk = key
    }

    func cancel() {
        refreshTask?.cancel()
        refreshTask = nil
        zeroSwk()
        if let sid = sessionId {
            appState.bridge.removeSession(sessionId: sid)
        }
        sessionId = nil
        if phase != .complete {
            phase = .idle
        }
    }

    func start() {
        guard phase == .idle || phase == .waitingForPeer else { return }
        guard wallet.threshold == wallet.totalParties else {
            phase = .error(L10n.Refresh.errorNonNofN)
            return
        }
        guard hasEnoughPeers else {
            phase = .waitingForPeer
            return
        }
        guard let swk, !swk.isEmpty else {
            phase = .error(L10n.Refresh.errorNeedsPin)
            return
        }

        phase = .running
        roundsCompleted = 0
        sessionId = "refresh-\(UUID().uuidString)"

        refreshTask = Task { [weak self] in
            await self?.run()
        }
    }

    private func run() async {
        let bridge = appState.bridge
        let peerManager = appState.peerManager
        let walletStore = appState.walletStore
        let deviceKey: Data
        do {
            deviceKey = try appState.deviceKey
        } catch {
            await MainActor.run { self.phase = .error("device key unavailable") }
            return
        }
        guard var swkLocal = self.swk, !swkLocal.isEmpty else {
            await MainActor.run { self.phase = .error(L10n.Refresh.errorNeedsPin) }
            return
        }
        defer { swkLocal.resetBytes(in: 0..<swkLocal.count) }

        // 1. Decrypt the existing shard.
        let plaintext: Data
        do {
            plaintext = try loadAndDecryptShard(
                walletStore: walletStore,
                bridge: bridge,
                deviceKey: deviceKey,
                swk: swkLocal
            )
        } catch {
            await MainActor.run { self.phase = .error("decrypt shard: \(error.localizedDescription)") }
            return
        }
        var plaintextMut = plaintext
        defer { plaintextMut.resetBytes(in: 0..<plaintextMut.count) }

        // 2. Kick off the refresh state machine.
        let config = FfiHorcruxConfig(
            threshold: wallet.threshold,
            totalParties: wallet.totalParties,
            partyIndex: wallet.partyIndex,
            curve: wallet.chain.curveType
        )
        let initialMessages: [FfiMpcMessage]
        do {
            initialMessages = try bridge.startRefresh(
                sessionId: sessionId!,
                config: config,
                shardData: plaintextMut
            )
        } catch {
            await MainActor.run { self.phase = .error("startRefresh: \(error.localizedDescription)") }
            return
        }

        // 3. Run the round loop over the relay.
        let (subId, stream) = peerManager.mpcMessageStream()
        defer { peerManager.unsubscribeMpc(subId) }

        do {
            for msg in initialMessages {
                let data = try JSONEncoder().encode(MpcMessageDTO(msg))
                try await peerManager.broadcastMpcMessage(data)
            }

            for await (_, data) in stream {
                if Task.isCancelled { return }
                let dto = try JSONDecoder().decode(MpcMessageDTO.self, from: data)
                let inbound = dto.toFfi()
                guard inbound.sessionId == sessionId else { continue }
                let responses = try bridge.handleMessage(inbound)
                await MainActor.run {
                    self.roundsCompleted = min(self.roundsCompleted + 1, self.approxTotalRounds)
                }
                for r in responses {
                    let rd = try JSONEncoder().encode(MpcMessageDTO(r))
                    try await peerManager.broadcastMpcMessage(rd)
                }
                if let result = bridge.getRefreshResult(sessionId: sessionId!) {
                    await persist(result: result, deviceKey: deviceKey, swk: swkLocal, bridge: bridge, walletStore: walletStore)
                    return
                }
            }
        } catch {
            await MainActor.run { self.phase = .error("refresh round: \(error.localizedDescription)") }
        }
    }

    private func loadAndDecryptShard(
        walletStore: WalletStore,
        bridge: HorcruxBridge,
        deviceKey: Data,
        swk: Data
    ) throws -> Data {
        guard let encoded = try walletStore.loadKeyShare(accountId: wallet.accountId) else {
            throw NSError(
                domain: "RefreshShardCoordinator", code: 404,
                userInfo: [NSLocalizedDescriptionKey: "shard not found"]
            )
        }
        let dto = try JSONDecoder().decode(EncryptedShardDTO.self, from: encoded)
        return try bridge.decryptShard(
            encrypted: dto.toFfi(),
            deviceKey: deviceKey,
            pin: swk
        )
    }

    private func persist(
        result: FfiKeygenResult,
        deviceKey: Data,
        swk: Data,
        bridge: HorcruxBridge,
        walletStore: WalletStore
    ) async {
        await MainActor.run { self.phase = .persisting }

        // CRITICAL invariant: the refreshed group public key MUST equal the
        // pre-refresh value, otherwise we would silently rotate the wallet
        // address. The Rust layer already aborts on mismatch but we re-check
        // defensively before touching the Keychain.
        let oldPubKeyHex = wallet.accountId.lowercased()
        let newPubKeyHex = result.publicKey.map { String(format: "%02x", $0) }.joined()
        if newPubKeyHex != oldPubKeyHex {
            await MainActor.run {
                self.phase = .error("public key mismatch — refresh rejected (old=\(oldPubKeyHex.prefix(10))…, new=\(newPubKeyHex.prefix(10))…)")
            }
            return
        }

        do {
            let encrypted = try bridge.encryptShard(
                plaintext: result.shardData,
                deviceKey: deviceKey,
                pin: swk
            )
            let dto = EncryptedShardDTO(encrypted)
            let payload = try JSONEncoder().encode(dto)

            // Keychain `update` (used by `storeSecure` when an item already
            // exists) is atomic per-item, so a crash mid-call leaves either
            // the old or the new ciphertext fully intact — never a torn write.
            try walletStore.storeKeyShare(payload, accountId: wallet.accountId)

            RefreshTracker.recordRefresh(accountId: wallet.accountId)

            bridge.removeSession(sessionId: sessionId!)
            sessionId = nil
            await MainActor.run {
                self.phase = .complete
                self.roundsCompleted = self.approxTotalRounds
            }
            zeroSwk()
            Haptics.success()
        } catch {
            await MainActor.run {
                self.phase = .error("persist: \(error.localizedDescription)")
            }
        }
    }

    private func zeroSwk() {
        if var s = swk {
            s.resetBytes(in: 0..<s.count)
            swk = nil
        }
    }
}
