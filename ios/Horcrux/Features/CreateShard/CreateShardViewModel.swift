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

    /// Whether this device is the session creator (chooses m/n/curve
    /// and triggers start) or a joiner (adopts the creator's
    /// `SessionBegin` broadcast and auto-enters DKG).
    enum Role: String, CaseIterable, Identifiable {
        case create
        case join
        var id: String { rawValue }
    }

    // Configuration
    @Published var step: Step = .configure
    @Published var role: Role = .create
    @Published var walletName: String = ""
    @Published var selectedCurve: FfiCurveType = .secp256k1
    @Published var threshold: Int = 2
    @Published var totalParties: Int = 3
    @Published var partyIndex: Int = 1
    @Published var selectedTransports: Set<TransportType> = [.relay]
    @Published var roomCode: String = ""

    // Discovery
    @Published var foundPeers: [Peer] = []
    /// App-level presence beacon keyed by deviceName. Populated from
    /// `RoomPresenceDTO` broadcasts during `.discover`. Used to gate the
    /// creator's Start button (rather than relying on transport-layer
    /// `foundPeers`, which can double-count a single peer discovered on
    /// both relay and WiFi-LAN).
    @Published var roomPresence: [String: RoomPresenceDTO] = [:]

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
    private var presenceTask: Task<Void, Never>?
    private var roomListenerTask: Task<Void, Never>?
    /// PeerManager subscription ID for our room listener. Stored so
    /// `stopAllListeners()` can unsubscribe synchronously — Task
    /// cancellation alone doesn't release the AsyncStream continuation,
    /// so stale subscribers would otherwise eat half the DKG messages
    /// in the next ceremony attempt.
    private var roomListenerSubId: UUID?
    /// Recently-consumed `SessionBegin` session IDs — so a re-broadcast
    /// or echo doesn't accidentally kick us back into DKG.
    private var consumedSessionBegins: Set<String> = []
    /// Channel that the persistent room listener uses to forward
    /// non-room-phase (i.e. actual MPC) bytes to `runDKGRounds`. Using
    /// a single consumer of `peerManager.incomingMpcMessages` across
    /// the whole ceremony avoids the AsyncStream single-consumer
    /// pitfall that otherwise drops messages when we transition from
    /// discovery to DKG.
    private var dkgMessageStream: AsyncStream<(Peer, Data)>?
    private var dkgMessageContinuation: AsyncStream<(Peer, Data)>.Continuation?

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
        // Idempotent: if a room listener is already running we're
        // already in the discover phase — do nothing. Without this
        // guard a double call (e.g. rapid button taps, or a view
        // re-render triggering an extra button action) wipes
        // `consumedSessionBegins` while a stale listener is still
        // draining `mpcMessageStream()`, which lets the same
        // SessionBegin trigger `autoJoinFromBegin` twice and spawn
        // two concurrent DKG ceremonies on the same device.
        if roomListenerTask != nil {
            NSLog("[DKG] startDiscovery called while already running — ignoring")
            return
        }
        totalRounds = selectedCurve == .ed25519 ? 3 : 9
        dkgStatusMessage = L10n.DKG.searchingDevices
        roomPresence.removeAll()
        consumedSessionBegins.removeAll()

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

        // Periodically announce our presence so other devices in the
        // room know we're here (with our role/proposed t,n) and the
        // creator's Start gate can fire without each device having to
        // hit a button.
        presenceTask?.cancel()
        presenceTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.broadcastPresence()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }

        // Single persistent consumer of `incomingMpcMessages` for the
        // whole ceremony. Room-phase packets (presence / SessionBegin)
        // are handled inline; everything else gets forwarded to
        // `dkgMessageStream` for `runDKGRounds` to consume. This avoids
        // the AsyncStream single-consumer trap we'd otherwise hit when
        // transitioning from discovery to DKG.
        let stream = AsyncStream<(Peer, Data)> { cont in
            self.dkgMessageContinuation = cont
        }
        self.dkgMessageStream = stream

        roomListenerTask?.cancel()
        let (subId, mpcStream) = peerManager!.mpcMessageStream()
        self.roomListenerSubId = subId
        roomListenerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            NSLog("[DKG] roomListenerTask started")
            for await (peer, data) in mpcStream {
                if Task.isCancelled { break }
                NSLog("[DKG] roomListener got \(data.count)B from \(peer.name) ch=\(peer.channel)")

                if let pres = try? JSONDecoder().decode(RoomPresenceDTO.self, from: data),
                   pres.magic == RoomPresenceDTO.magic {
                    NSLog("[DKG]   → RoomPresence from \(pres.deviceName) role=\(pres.role)")
                    if pres.deviceName != UIDevice.current.name {
                        self.roomPresence[pres.deviceName] = pres
                    }
                    continue
                }
                if let begin = try? JSONDecoder().decode(SessionBeginDTO.self, from: data),
                   begin.magic == SessionBeginDTO.magic {
                    if self.consumedSessionBegins.contains(begin.sessionId) { continue }
                    self.consumedSessionBegins.insert(begin.sessionId)
                    NSLog("[DKG] Received SessionBegin sid=\(begin.sessionId.prefix(8))… from creator; auto-joining")
                    self.autoJoinFromBegin(begin)
                    continue
                }
                // Real MPC payload — forward to the DKG loop (which may
                // not have started yet; AsyncStream buffers for us).
                self.dkgMessageContinuation?.yield((peer, data))
            }
            self.dkgMessageContinuation?.finish()
        }
    }

    /// Stops the periodic presence beacon broadcast but leaves the
    /// room listener task alive — it keeps forwarding real MPC bytes
    /// into `dkgMessageStream` throughout the DKG rounds.
    private func stopDiscoveryTasks() {
        presenceTask?.cancel()
        presenceTask = nil
    }

    /// Called only on full ceremony teardown (completion, error,
    /// cancel). Kills the room listener and closes the DKG stream.
    private func stopAllListeners() {
        presenceTask?.cancel()
        presenceTask = nil
        roomListenerTask?.cancel()
        roomListenerTask = nil
        if let subId = roomListenerSubId {
            peerManager?.unsubscribeMpc(subId)
            roomListenerSubId = nil
        }
        dkgMessageContinuation?.finish()
        dkgMessageContinuation = nil
        dkgMessageStream = nil
    }

    /// One presence broadcast.
    private func broadcastPresence() async {
        guard let peerManager else { return }
        let beacon = RoomPresenceDTO(
            deviceName: UIDevice.current.name,
            role: role,
            proposedThreshold: role == .create ? threshold : nil,
            proposedTotalParties: role == .create ? totalParties : nil,
            curve: role == .create ? selectedCurve : nil
        )
        guard let data = try? JSONEncoder().encode(beacon) else { return }
        try? await peerManager.broadcastMpcMessage(data)
    }

    /// Called when a joiner receives a `SessionBegin` broadcast from the
    /// creator. Adopts the authoritative config + participant list and
    /// transitions straight into DKG — no button press required.
    private func autoJoinFromBegin(_ begin: SessionBeginDTO) {
        guard step == .discover else { return }
        guard let myIdx = begin.participantIds.firstIndex(of: UIDevice.current.name) else {
            NSLog("[DKG] SessionBegin ignored — I am not in the participant list \(begin.participantIds)")
            return
        }
        threshold = Int(begin.threshold)
        totalParties = Int(begin.totalParties)
        selectedCurve = begin.curve == "ed25519" ? .ed25519 : .secp256k1
        totalRounds = selectedCurve == .ed25519 ? 3 : 9
        partyIndex = myIdx + 1
        sessionId = begin.sessionId
        stopDiscoveryTasks()
        startDKG(precomputed: true)
    }

    /// Called by the creator when they tap Start. Publishes a
    /// `SessionBegin` with the final authoritative config + a
    /// deterministic participant list, then enters DKG. All joiners
    /// receive the broadcast and auto-enter.
    func creatorStartDKG() {
        guard role == .create else { return }

        // Participant list: self + presences, sorted by deviceName,
        // trimmed to exactly `totalParties`.
        var names = Array(roomPresence.keys)
        names.append(UIDevice.current.name)
        names = Array(Set(names)).sorted()
        guard names.count >= totalParties else {
            errorMessage = L10n.DKG.errNotEnoughPeers(totalParties, names.count)
            step = .error
            return
        }
        let participants = Array(names.prefix(totalParties))
        guard let myIdx = participants.firstIndex(of: UIDevice.current.name) else {
            errorMessage = L10n.DKG.errNotInParticipants
            step = .error
            return
        }
        partyIndex = myIdx + 1
        let sid = roomCode.isEmpty ? UUID().uuidString : roomCode
        sessionId = sid

        let begin = SessionBeginDTO(
            threshold: threshold,
            totalParties: totalParties,
            curve: selectedCurve,
            participantIds: participants,
            sessionId: sid
        )
        consumedSessionBegins.insert(sid)

        // Fire-and-forget re-broadcast so late joiners still see it.
        Task { [weak self] in
            guard let peerManager = self?.peerManager else { return }
            guard let data = try? JSONEncoder().encode(begin) else { return }
            for i in 0..<5 {
                try? await peerManager.broadcastMpcMessage(data)
                try? await Task.sleep(nanoseconds: UInt64(200 + i * 200) * 1_000_000)
            }
        }

        stopDiscoveryTasks()
        startDKG(precomputed: true)
    }

    func startDKG(precomputed: Bool = false) {
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
        if sessionId == nil {
            sessionId = roomCode.isEmpty ? UUID().uuidString : roomCode
        }
        peerManager?.stopDiscovery()

        // Legacy path: if caller didn't pre-resolve the config (no
        // SessionBegin adopted), fall back to sorted-ID party index.
        if !precomputed {
            autoAssignPartyIndex()
        }

        NSLog("[DKG] Starting DKG: sessionId=\(self.sessionId!), party=\(self.partyIndex), threshold=\(self.threshold)/\(self.totalParties), peers=\(self.foundPeers.count)")

        ceremonyTask = Task {
            do {
                guard let bridge else { throw DKGError.notInitialized }

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
                let startKeygenStart = Date()
                let outgoing: [FfiMpcMessage] = try await Task.detached(priority: .userInitiated) {
                    try session.createKeygen(sessionId: sid, config: cfg)
                }.value
                let startKeygenElapsed = Date().timeIntervalSince(startKeygenStart)
                NSLog("[DKG-PERF] startKeygen elapsed=\(String(format: "%.2f", startKeygenElapsed))s messages=\(outgoing.count)")

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
        stopAllListeners()
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

    /// Legacy buffer (kept for API compatibility); unused now that the
    /// persistent room listener forwards MPC bytes straight into
    /// `dkgMessageStream`.
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

            func process(_ peer: Peer, _ data: Data) async throws -> Bool {
                // Returns true if keygen is now complete.
                msgCount += 1
                NSLog("[DKG] Received msg #\(msgCount) from \(peer.id.prefix(8))... (\(data.count) bytes, channel=\(peer.channel))")

                if processedPayloads.contains(data) {
                    NSLog("[DKG] Skipping duplicate message (already processed via another transport)")
                    return false
                }
                processedPayloads.insert(data)

                // Ignore any late room-phase echoes (presence beacons
                // or SessionBegin re-broadcasts from the creator).
                if let magic = try? JSONDecoder().decode(MagicPeek.self, from: data) {
                    if magic.magic == RoomPresenceDTO.magic
                        || magic.magic == SessionBeginDTO.magic {
                        NSLog("[DKG] Ignoring late room-phase payload (\(magic.magic)) from \(peer.name)")
                        return false
                    }
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

                // Advance the status label BEFORE the (potentially
                // very long, up to ~90s on secp256k1) Rust computation
                // so the user sees the right phase ("Paillier keys",
                // "ZK proofs") while it's happening instead of the
                // previous round's label.
                currentRound = msgCount
                updateProgress()
                updateDKGStatusMessage()

                let responses: [FfiMpcMessage]
                let roundStart = Date()
                do {
                    NSLog("[DKG] Calling bridge.handleMessage (off-main) for round \(msgCount)...")
                    let session = bridge.session
                    let msgToProcess = msg
                    responses = try await Task.detached(priority: .userInitiated) {
                        try session.handleMessage(msg: msgToProcess)
                    }.value
                } catch {
                    NSLog("[DKG] handleMessage error: \(error.localizedDescription)")
                    throw error
                }
                let roundElapsed = Date().timeIntervalSince(roundStart)
                NSLog("[DKG-PERF] round=\(msgCount) elapsed=\(String(format: "%.2f", roundElapsed))s responses=\(responses.count)")

                for response in responses {
                    let responseData = try JSONEncoder().encode(MpcMessageDTO(response))
                    NSLog("[DKG] Sending response: to=\(response.toParty) data=\(responseData.count)B")
                    try await peerManager.broadcastMpcMessage(responseData)
                }

                if bridge.getKeygenResult(sessionId: sessionId!) != nil { return true }
                NSLog("[DKG] Keygen not yet complete, waiting for more messages...")
                return false
            }

            if keygenResult == nil {
                guard let dkgStream = self.dkgMessageStream else {
                    NSLog("[DKG] ❌ dkgMessageStream missing — aborting")
                    throw DKGError.keygenIncomplete
                }
                for await (peer, data) in dkgStream {
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
            stopAllListeners()

        } catch {
            NSLog("[DKG] ❌ runDKGRounds error: \(error)")
            errorMessage = error.localizedDescription
            step = .error
            stopAllListeners()
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
            case .missingKeygenResult: return L10n.DKG.errMissingKeygen
            case .noDerivedAddresses: return L10n.DKG.errNoAddresses
            case .encryptFailed(let e): return L10n.DKG.errEncryptFailed(e.localizedDescription)
            case .storeFailed(let e): return L10n.DKG.errStoreFailed(e.localizedDescription)
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
            // Use rawValue (unique per chain) to avoid ID/name collisions
            // between EVM chains that share the same symbol (ETH).
            let chainKey = entry.chain.rawValue.replacingOccurrences(of: " ", with: "-")
            let walletId = generatedAddresses.count > 1 ? "\(baseId)-\(chainKey)" : baseId
            let wallet = Wallet(
                id: walletId,
                name: generatedAddresses.count > 1 ? "\(walletName) (\(entry.chain.rawValue))" : walletName,
                chain: entry.chain,
                address: entry.address,
                groupPublicKey: result.publicKey,
                threshold: UInt16(threshold),
                totalParties: UInt16(totalParties),
                partyIndex: UInt16(partyIndex),
                createdAt: .now,
                isHidden: nil
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
                userInfo: [NSLocalizedDescriptionKey: L10n.DKG.errCannotUnlockVault]
            ))
        }
        try saveWallet(to: appState, keyMaterial: swk)
    }
}

private enum DKGError: LocalizedError {
    case notInitialized
    case keygenIncomplete

    var errorDescription: String? {
        switch self {
        case .notInitialized: return "Session not initialized"
        case .keygenIncomplete: return "Key generation did not complete"
        }
    }
}

/// Lightweight envelope used to peek at a payload's `magic` field
/// without fully decoding. Lets `runDKGRounds` drop stray room-phase
/// broadcasts (presence beacons, SessionBegin echoes) that arrive
/// after we've left `.discover`.
private struct MagicPeek: Codable {
    let magic: String
}

/// Periodic presence beacon broadcast during `.discover`. Every party
/// sends these so the creator's Start gate can fire on app-level
/// presence rather than transport-level `foundPeers` (which double-
/// counts peers seen on multiple channels).
struct RoomPresenceDTO: Codable {
    static let magic = "HRP-v1"
    let magic: String
    let deviceName: String
    let role: String
    let proposedThreshold: UInt16?
    let proposedTotalParties: UInt16?
    let curve: String?

    init(
        deviceName: String,
        role: CreateShardViewModel.Role,
        proposedThreshold: Int?,
        proposedTotalParties: Int?,
        curve: FfiCurveType?
    ) {
        self.magic = Self.magic
        self.deviceName = deviceName
        self.role = role.rawValue
        self.proposedThreshold = proposedThreshold.map(UInt16.init)
        self.proposedTotalParties = proposedTotalParties.map(UInt16.init)
        self.curve = curve.map(Self.curveString)
    }

    static func curveString(_ c: FfiCurveType) -> String {
        switch c {
        case .secp256k1: return "secp256k1"
        case .ed25519: return "ed25519"
        }
    }
}

/// Authoritative "let's start" broadcast from the session creator.
/// Carries the final (t,n,curve) + the ordered participant list that
/// all devices use to derive their `partyIndex`. Joiners receiving
/// this auto-enter DKG without needing a manual Start tap.
struct SessionBeginDTO: Codable {
    static let magic = "HSB-v1"
    let magic: String
    let threshold: UInt16
    let totalParties: UInt16
    let curve: String
    /// Sorted device names. Index in this list (1-based) = partyIndex.
    let participantIds: [String]
    let sessionId: String

    init(
        threshold: Int,
        totalParties: Int,
        curve: FfiCurveType,
        participantIds: [String],
        sessionId: String
    ) {
        self.magic = Self.magic
        self.threshold = UInt16(threshold)
        self.totalParties = UInt16(totalParties)
        self.curve = RoomPresenceDTO.curveString(curve)
        self.participantIds = participantIds
        self.sessionId = sessionId
    }
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
