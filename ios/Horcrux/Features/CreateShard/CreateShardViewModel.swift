import Foundation
import Combine
import os
import UIKit

private let dkgLog = Logger(subsystem: "com.horcrux.wallet", category: "DKG")

/// View model for the DKG (shard creation) ceremony.
@MainActor
final class CreateShardViewModel: ObservableObject {
    enum Step {
        case configure, discover, dkg, complete, error
    }

    // Configuration
    @Published var step: Step = .configure
    @Published var walletName: String = ""
    @Published var selectedCurve: FfiCurveType = .secp256k1
    @Published var threshold: Int = 2
    @Published var totalParties: Int = 3
    @Published var partyIndex: Int = 1
    @Published var selectedTransports: Set<TransportType> = [.relay]
    @Published var roomCode: String = "apple-tiger-moon"

    // Discovery
    @Published var foundPeers: [Peer] = []

    // DKG progress
    @Published var dkgProgress: Double = 0
    @Published var dkgStatusMessage: String = ""
    @Published var currentRound: Int = 0
    @Published var totalRounds: Int = 9 // CGGMP21 = 9 rounds, FROST = 3

    // Result
    @Published var generatedAddresses: [(chain: Chain, address: String)] = []
    @Published var errorMessage: String = ""

    private var sessionId: String?
    private var keygenResult: FfiKeygenResult?
    private var peerManager: PeerManager?
    private var bridge: HorcruxBridge?
    private var cancellables = Set<AnyCancellable>()
    private var ceremonyTask: Task<Void, Never>?

    /// Local peer identifier shown during discovery.
    var localPeerId: String {
        let hasRelay = foundPeers.contains { $0.channel == "relay" }
        if hasRelay, let relayId = peerManager?.relay.deviceId {
            return String(relayId.prefix(8))
        }
        return UIDevice.current.name
    }

    func bind(to appState: AppState) {
        self.peerManager = appState.peerManager
        self.bridge = appState.bridge

        // Observe discovered peers from PeerManager
        appState.peerManager.$allPeers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] peers in
                self?.foundPeers = peers
            }
            .store(in: &cancellables)
    }

    func startDiscovery() {
        totalRounds = selectedCurve == .ed25519 ? 3 : 9
        dkgStatusMessage = L10n.DKG.searchingDevices

        if selectedTransports.contains(.relay) && !roomCode.isEmpty {
            Task {
                do {
                    try await peerManager?.joinRelayRoom(roomId: roomCode)
                    peerManager?.relay.startDiscovery()
                } catch {
                    errorMessage = "Failed to join relay room: \(error.localizedDescription)"
                    step = .error
                }
            }
        }
        peerManager?.startDiscovery(transports: selectedTransports)
    }

    func startDKG() {
        // Block on jailbroken devices
        guard !SecurityEnvironment.isCompromised else {
            errorMessage = L10n.DKG.compromisedDevice
            step = .error
            return
        }
        guard bridge != nil else {
            errorMessage = "Bridge not initialized"
            step = .error
            return
        }

        step = .dkg
        // Use room code as session ID so both parties share the same MPC session
        sessionId = roomCode.isEmpty ? UUID().uuidString : roomCode
        peerManager?.stopDiscovery()

        // Auto-assign party index: sort local + peer IDs deterministically
        autoAssignPartyIndex()

        NSLog("[DKG] Starting DKG: sessionId=\(self.sessionId!), party=\(self.partyIndex), threshold=\(self.threshold)/\(self.totalParties), peers=\(self.foundPeers.count)")

        ceremonyTask = Task {
            do {
                guard let bridge else { throw DKGError.notInitialized }

                // Negotiate config with peers BEFORE starting keygen. Two
                // devices that pick different (t,n,curve) will otherwise
                // each send messages addressed to phantom parties and
                // silently hang at round 1/9 for the full 2-minute timeout.
                dkgStatusMessage = L10n.DKG.negotiatingConfig
                try await negotiateConfigOrThrow()

                let config = FfiHorcruxConfig(
                    threshold: UInt16(threshold),
                    totalParties: UInt16(totalParties),
                    partyIndex: UInt16(partyIndex),
                    curve: selectedCurve
                )

                dkgStatusMessage = L10n.DKG.initializingKeyGen
                currentRound = 1
                updateProgress()

                NSLog("[DKG] Calling bridge.startKeygen (session=\(self.sessionId!))...")
                // startKeygen can be heavy (Paillier setup on secp256k1).
                // Offload to background so the UI doesn't freeze at step 3 start.
                let session = bridge.session
                let sid = sessionId!
                let cfg = config
                let outgoing: [FfiMpcMessage] = try await Task.detached(priority: .userInitiated) {
                    try session.createKeygen(sessionId: sid, config: cfg)
                }.value
                NSLog("[DKG] startKeygen returned \(outgoing.count) messages")

                dkgStatusMessage = L10n.DKG.exchangingCommitments

                await runDKGRounds(initialMessages: outgoing)

            } catch {
                NSLog("[DKG] Error: \(error.localizedDescription)")
                if !Task.isCancelled {
                    errorMessage = error.localizedDescription
                    step = .error
                }
            }
        }
    }

    func cancel() {
        ceremonyTask?.cancel()
        ceremonyTask = nil
        peerManager?.stopDiscovery()
        if let sessionId, let bridge {
            bridge.removeSession(sessionId: sessionId)
        }
        step = .error
        errorMessage = L10n.DKG.ceremonyCancel
    }

    /// Auto-assign party index by sorting all participant IDs deterministically.
    /// Both devices independently reach the same assignment without negotiation.
    ///
    /// IMPORTANT: the identifiers used for sorting MUST live in the same
    /// namespace on both sides. Previously we used `peer.id` (a Bonjour
    /// service name with `\032` escapes on WiFi-LAN, a UUID on relay) but
    /// compared it against `UIDevice.current.name` locally — causing both
    /// devices to sort themselves to index 1 over WiFi-LAN.
    private func autoAssignPartyIndex() {
        let hasRelayPeer = foundPeers.contains { $0.channel == "relay" }
        let localId: String
        let peerIdOf: (Peer) -> String
        if hasRelayPeer {
            // Relay namespace: both sides use the relay device UUID.
            localId = peerManager?.relay.deviceId ?? UIDevice.current.name
            peerIdOf = { $0.id }
        } else {
            // WiFi-LAN namespace: use the Bonjour *display name* on both
            // sides (matches UIDevice.current.name on the peer).
            localId = UIDevice.current.name
            peerIdOf = { $0.name }
        }

        var peerIds: [String] = []
        var seen: Set<String> = []
        for peer in foundPeers {
            let pid = peerIdOf(peer)
            if seen.insert(pid).inserted {
                peerIds.append(pid)
            }
        }
        var allIds = peerIds
        allIds.append(localId)
        allIds.sort()
        let myIndex = (allIds.firstIndex(of: localId) ?? 0) + 1
        NSLog("[DKG] Auto-assign party index: localId=\"\(localId)\", participants=\(allIds), myIndex=\(myIndex)")
        partyIndex = myIndex
    }

    /// Pre-DKG config handshake. Each party broadcasts its (t,n,curve)
    /// and waits up to 10s for peers' equivalents. Any mismatch aborts.
    ///
    /// We tolerate slow WiFi-LAN and relay paths by collecting until
    /// we hear from every discovered peer, OR the timeout fires. For a
    /// 2-party ceremony that means waiting for 1 reply.
    private func negotiateConfigOrThrow() async throws {
        guard let peerManager else { return }
        let expectedPeers = peerManager.allPeers.count
        if expectedPeers == 0 { return } // local-only; nothing to negotiate

        let myHello = ConfigHelloDTO(
            threshold: threshold,
            totalParties: totalParties,
            curve: selectedCurve,
            partyIndex: partyIndex,
            deviceName: UIDevice.current.name
        )
        let helloData = try JSONEncoder().encode(myHello)
        let mySummary = myHello.summary

        NSLog("[DKG] Broadcasting config hello: \(mySummary) to \(expectedPeers) peers")
        try await peerManager.broadcastMpcMessage(helloData)

        // Re-broadcast a few times so peers that entered the ceremony
        // slightly later still see our hello before their 10s timeout.
        let rebroadcast = Task { [helloData, peerManager] in
            for delayMs in [500, 1500, 3500] {
                try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                try? await peerManager.broadcastMpcMessage(helloData)
            }
        }
        defer { rebroadcast.cancel() }

        // Single consumer loop with a separate timeout task that
        // throws to break us out. Creating a fresh for-await iterator
        // per message (previous implementation) dropped inbound bytes
        // because AsyncStream is single-consumer and the dropped
        // iterators took buffered values with them.
        var heard: [String: ConfigHelloDTO] = [:]

        enum Done: Error { case timeout, satisfied, mismatch(DKGError) }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [expectedPeers] in
                    try await Task.sleep(nanoseconds: 10 * 1_000_000_000)
                    _ = expectedPeers
                    throw Done.timeout
                }
                group.addTask { @MainActor in
                    for await (peer, data) in peerManager.incomingMpcMessages {
                        if let hello = try? JSONDecoder().decode(ConfigHelloDTO.self, from: data),
                           hello.magic == ConfigHelloDTO.magic {
                            if heard[peer.id] == nil {
                                heard[peer.id] = hello
                                NSLog("[DKG] Got config hello from \(peer.name): \(hello.summary)")
                            }
                            if hello.threshold != myHello.threshold
                                || hello.totalParties != myHello.totalParties
                                || hello.curve != myHello.curve {
                                throw Done.mismatch(.configMismatch(
                                    local: mySummary,
                                    remote: hello.summary,
                                    peer: peer.name
                                ))
                            }
                            if heard.count >= expectedPeers {
                                throw Done.satisfied
                            }
                        } else {
                            // Non-hello MPC bytes arrived during the
                            // handshake window; stash for the round
                            // loop so we don't lose them.
                            self.pendingMpcMessages.append((peer, data))
                            NSLog("[DKG] Stashing non-hello payload from \(peer.name) for DKG loop (\(data.count)B)")
                        }
                    }
                }
                try await group.next()
                group.cancelAll()
            }
        } catch Done.satisfied {
            NSLog("[DKG] Config agreed: \(mySummary)")
            return
        } catch Done.timeout {
            NSLog("[DKG] Config negotiation timed out — heard from \(heard.count)/\(expectedPeers)")
            if heard.isEmpty { throw DKGError.configTimeout }
            NSLog("[DKG] Config partially agreed (\(heard.count) peers): \(mySummary)")
            return
        } catch Done.mismatch(let err) {
            throw err
        }
    }

    /// Non-hello messages received during negotiation are replayed into
    /// the DKG round loop. Keep them in arrival order.
    private var pendingMpcMessages: [(Peer, Data)] = []

    private func runDKGRounds(initialMessages: [FfiMpcMessage]) async {
        guard let bridge, let peerManager else { return }

        do {
            // Send initial outgoing messages to peers
            NSLog("[DKG] Broadcasting \(initialMessages.count) initial messages to \(peerManager.allPeers.count) peers")
            for msg in initialMessages {
                let data = try JSONEncoder().encode(MpcMessageDTO(msg))
                NSLog("[DKG] Sending initial msg: from=\(msg.fromParty) to=\(msg.toParty) payload=\(msg.payload.count)B data=\(data.count)B")
                try await peerManager.broadcastMpcMessage(data)
            }
            NSLog("[DKG] Initial messages sent. Waiting for incoming on mpcMessageStream...")

            // Listen for incoming messages and process rounds
            var msgCount = 0
            var processedPayloads: Set<Data> = [] // Deduplicate messages from multiple transports

            // Drain anything the negotiation step stashed (real MPC
            // messages that arrived before we finished negotiating).
            var initialQueue = pendingMpcMessages
            pendingMpcMessages.removeAll()

            func process(_ peer: Peer, _ data: Data) async throws -> Bool {
                // Returns true if keygen is now complete.
                msgCount += 1
                NSLog("[DKG] Received msg #\(msgCount) from \(peer.id.prefix(8))... (\(data.count) bytes, channel=\(peer.channel))")

                if processedPayloads.contains(data) {
                    NSLog("[DKG] Skipping duplicate message (already processed via another transport)")
                    return false
                }
                processedPayloads.insert(data)

                // Ignore any late ConfigHello echoes so the MPC decoder
                // below doesn't trip on them.
                if let hello = try? JSONDecoder().decode(ConfigHelloDTO.self, from: data),
                   hello.magic == ConfigHelloDTO.magic {
                    NSLog("[DKG] Ignoring late config hello from \(peer.name)")
                    return false
                }

                let decodedDTO: MpcMessageDTO?
                do {
                    decodedDTO = try JSONDecoder().decode(MpcMessageDTO.self, from: data)
                } catch {
                    NSLog("[DKG] Failed to decode MPC message: \(error.localizedDescription)")
                    SecureLog.error("Failed to decode MPC message during DKG: \(error.localizedDescription)")
                    return false
                }
                guard let dto = decodedDTO else { return false }
                let msg = dto.toFfi()
                NSLog("[DKG] Processing msg: from=\(msg.fromParty) to=\(msg.toParty) session=\(msg.sessionId.prefix(8))...")

                let responses: [FfiMpcMessage]
                do {
                    NSLog("[DKG] Calling bridge.handleMessage (off-main)...")
                    let session = bridge.session
                    let msgToProcess = msg
                    responses = try await Task.detached(priority: .userInitiated) {
                        try session.handleMessage(msg: msgToProcess)
                    }.value
                } catch {
                    NSLog("[DKG] handleMessage error: \(error.localizedDescription)")
                    throw error
                }
                NSLog("[DKG] handleMessage returned \(responses.count) responses")

                currentRound = msgCount
                updateProgress()
                updateDKGStatusMessage()

                for response in responses {
                    let responseData = try JSONEncoder().encode(MpcMessageDTO(response))
                    NSLog("[DKG] Sending response: to=\(response.toParty) data=\(responseData.count)B")
                    try await peerManager.broadcastMpcMessage(responseData)
                }

                if bridge.getKeygenResult(sessionId: sessionId!) != nil { return true }
                NSLog("[DKG] Keygen not yet complete, waiting for more messages...")
                return false
            }

            for (peer, data) in initialQueue {
                if try await process(peer, data) {
                    if let result = bridge.getKeygenResult(sessionId: sessionId!) {
                        NSLog("[DKG] ✅ Keygen complete (from stashed queue)! publicKey=\(result.publicKey.count)B shard=\(result.shardData.count)B")
                        keygenResult = result
                        break
                    }
                }
            }

            if keygenResult == nil {
                for await (peer, data) in peerManager.incomingMpcMessages {
                    if try await process(peer, data) {
                        if let result = bridge.getKeygenResult(sessionId: sessionId!) {
                            NSLog("[DKG] ✅ Keygen complete! publicKey=\(result.publicKey.count)B shard=\(result.shardData.count)B")
                            keygenResult = result
                            break
                        }
                    }
                }
            }

            // Derive address from group public key
            guard let result = keygenResult else {
                throw DKGError.keygenIncomplete
            }

            dkgProgress = 0.95
            dkgStatusMessage = L10n.DKG.derivingAddress

            // Auto-derive addresses for ALL chains using the same curve
            generatedAddresses = []
            for chain in Chain.allCases where chain.curveType == selectedCurve {
                let addr = try bridge.deriveAddress(
                    chain: chain,
                    publicKey: result.publicKey
                )
                generatedAddresses.append((chain: chain, address: addr))
                NSLog("[DKG] ✅ Address derived for \(chain.rawValue): \(addr)")
            }

            dkgProgress = 1.0
            step = .complete

        } catch {
            NSLog("[DKG] ❌ runDKGRounds error: \(error)")
            errorMessage = error.localizedDescription
            step = .error
        }
    }

    /// Single source of truth for progress: derive from currentRound/totalRounds.
    private func updateProgress() {
        // Reserve 0-90% for DKG rounds, 95% for address derivation, 100% for complete
        dkgProgress = min(Double(currentRound) / Double(totalRounds), 0.9)
    }

    private func updateDKGStatusMessage() {
        switch currentRound {
        case 1: dkgStatusMessage = L10n.DKG.exchangingCommitments
        case 2: dkgStatusMessage = L10n.DKG.verifyingShares
        case 3: dkgStatusMessage = selectedCurve == .ed25519
            ? L10n.DKG.finalizingKeyPackage
            : L10n.DKG.computingPaillierKeys
        case 4: dkgStatusMessage = L10n.DKG.generatingZKProofs
        case 5: dkgStatusMessage = L10n.DKG.verifyingProofs
        case 6: dkgStatusMessage = L10n.DKG.computingAuxInfo
        case 7: dkgStatusMessage = L10n.DKG.finalizingKeyShares
        case 8: dkgStatusMessage = L10n.DKG.verifyingProofs
        case 9: dkgStatusMessage = L10n.DKG.finalizingKeyShares
        default: dkgStatusMessage = L10n.DKG.processing
        }
    }

    /// Error cases surfaced by `saveWallet` so the caller can show the
    /// user an alert instead of a silent no-op.
    enum SaveError: LocalizedError {
        case missingKeygenResult
        case noDerivedAddresses
        case encryptFailed(Error)
        case storeFailed(Error)

        var errorDescription: String? {
            switch self {
            case .missingKeygenResult: return "密钥生成结果丢失，无法保存。请重新生成分片。"
            case .noDerivedAddresses: return "未推导出任何链上地址，无法保存钱包。"
            case .encryptFailed(let e): return "加密分片失败：\(e.localizedDescription)"
            case .storeFailed(let e): return "写入钥匙串失败：\(e.localizedDescription)"
            }
        }
    }

    /// Save the freshly-generated shard. Pass the PBKDF2-derived key material
    /// directly (callers may use `AppState.cachedShardKey()` to reuse the key
    /// from the just-completed unlock and skip a second PIN prompt).
    func saveWallet(to appState: AppState, keyMaterial: Data) throws {
        guard let result = keygenResult else {
            NSLog("[Save] ❌ keygenResult is nil")
            throw SaveError.missingKeygenResult
        }
        guard !generatedAddresses.isEmpty else {
            NSLog("[Save] ❌ generatedAddresses is empty (curve=\(selectedCurve))")
            throw SaveError.noDerivedAddresses
        }

        let baseId = sessionId ?? UUID().uuidString
        // accountId is the hex of the DKG group public key and is shared
        // across all derived chains. We write the encrypted shard exactly
        // once, keyed by accountId.
        let accountId = result.publicKey.map { String(format: "%02x", $0) }.joined()
        NSLog("[Save] accountId=\(accountId.prefix(16))… addresses=\(generatedAddresses.count)")

        // Persist the shard once. Any failure here must abort — otherwise
        // we'd add wallet rows pointing at a non-existent key share.
        do {
            let deviceKey = try appState.deviceKey
            let encrypted = try appState.bridge.encryptShard(
                plaintext: result.shardData,
                deviceKey: deviceKey,
                pin: keyMaterial
            )
            let encoded = try JSONEncoder().encode(EncryptedShardDTO(encrypted))
            try appState.walletStore.storeKeyShare(encoded, accountId: accountId)
            NSLog("[Save] ✅ key share persisted (\(encoded.count)B)")
        } catch {
            NSLog("[Save] ❌ store key share failed: \(error)")
            throw SaveError.storeFailed(error)
        }

        // Save one wallet entry per derived chain address.
        for (index, entry) in generatedAddresses.enumerated() {
            let walletId = generatedAddresses.count > 1 ? "\(baseId)-\(entry.chain.symbol)" : baseId
            let wallet = Wallet(
                id: walletId,
                name: generatedAddresses.count > 1 ? "\(walletName) (\(entry.chain.symbol))" : walletName,
                chain: entry.chain,
                address: entry.address,
                groupPublicKey: result.publicKey,
                threshold: UInt16(threshold),
                totalParties: UInt16(totalParties),
                partyIndex: UInt16(partyIndex),
                createdAt: .now
            )

            appState.walletStore.add(wallet)
            NSLog("[Save] ✅ wallet added: \(wallet.name) (\(entry.chain.rawValue))")

            // Register shard with the in-memory shard manager once.
            if index == 0 {
                let shardInfo = FfiShardInfo(
                    shardId: accountId,
                    publicKey: result.publicKey,
                    partyIndex: result.partyIndex,
                    threshold: result.threshold,
                    totalParties: result.totalParties,
                    curve: entry.chain.curveType,
                    createdAt: UInt64(Date.now.timeIntervalSince1970),
                    isLocal: true
                )
                appState.bridge.addShard(info: shardInfo)
            }
        }

        // Clean up MPC session
        if let sid = sessionId {
            appState.bridge.removeSession(sessionId: sid)
        }
    }

    /// Convenience: unwrap the Shard Wrap Key via PIN and save. Used as
    /// the fallback path when the SWK isn't already cached (e.g. session
    /// was unlocked via biometric on a build without an SE-sealed SWK).
    func saveWallet(to appState: AppState, pin: String) throws {
        guard appState.verifyPin(pin) else {
            throw SaveError.missingKeygenResult // caller already validated PIN; shouldn't hit
        }
        guard let swk = appState.cachedShardKey() else {
            NSLog("[Save] ❌ cachedShardKey() is nil after verifyPin — vault corrupt")
            throw SaveError.storeFailed(NSError(
                domain: "Horcrux.Save", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法解开密钥保险库。请在设置中重设 PIN 后重试。"]
            ))
        }
        try saveWallet(to: appState, keyMaterial: swk)
    }
}

private enum DKGError: LocalizedError {
    case notInitialized
    case keygenIncomplete
    case configMismatch(local: String, remote: String, peer: String)
    case configTimeout

    var errorDescription: String? {
        switch self {
        case .notInitialized: return "Session not initialized"
        case .keygenIncomplete: return "Key generation did not complete"
        case .configMismatch(let local, let remote, let peer):
            return "参数不一致：本机 \(local)，对端「\(peer)」为 \(remote)。请双方选择相同的门限/总数/曲线后重试。"
        case .configTimeout:
            return "等待对端参数超时。请确认双方都已进入此界面后重试。"
        }
    }
}

/// Pre-DKG handshake: every party broadcasts its (t,n,curve) so
/// mismatches abort cleanly instead of hanging for the full 2-minute
/// keygen timeout. Tagged with a magic string so the main MPC message
/// decoder can ignore it.
struct ConfigHelloDTO: Codable {
    static let magic = "HCFG-v1"
    let magic: String
    let threshold: UInt16
    let totalParties: UInt16
    let curve: String
    let partyIndex: UInt16
    let deviceName: String

    init(threshold: Int, totalParties: Int, curve: FfiCurveType, partyIndex: Int, deviceName: String) {
        self.magic = Self.magic
        self.threshold = UInt16(threshold)
        self.totalParties = UInt16(totalParties)
        self.curve = Self.curveString(curve)
        self.partyIndex = UInt16(partyIndex)
        self.deviceName = deviceName
    }

    static func curveString(_ c: FfiCurveType) -> String {
        switch c {
        case .secp256k1: return "secp256k1"
        case .ed25519: return "ed25519"
        }
    }

    var summary: String { "\(threshold)/\(totalParties) \(curve)" }
}

/// Codable DTO for serializing FfiMpcMessage.
struct MpcMessageDTO: Codable {
    let fromParty: UInt16
    let toParty: UInt16
    let round: UInt32
    let sessionId: String
    let payload: Data

    init(_ msg: FfiMpcMessage) {
        self.fromParty = msg.fromParty
        self.toParty = msg.toParty
        self.round = msg.round
        self.sessionId = msg.sessionId
        self.payload = msg.payload
    }

    func toFfi() -> FfiMpcMessage {
        FfiMpcMessage(
            fromParty: fromParty,
            toParty: toParty,
            round: round,
            sessionId: sessionId,
            payload: payload
        )
    }
}

/// Codable DTO for serializing FfiEncryptedShard.
struct EncryptedShardDTO: Codable {
    let nonce: Data
    let ciphertext: Data
    let salt: Data

    init(_ shard: FfiEncryptedShard) {
        self.nonce = shard.nonce
        self.ciphertext = shard.ciphertext
        self.salt = shard.salt
    }

    func toFfi() -> FfiEncryptedShard {
        FfiEncryptedShard(nonce: nonce, ciphertext: ciphertext, salt: salt)
    }
}
