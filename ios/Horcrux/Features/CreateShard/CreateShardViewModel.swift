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
    @Published var roomCode: String = RoomCode.generate()

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
                let outgoing = try bridge.startKeygen(
                    sessionId: sessionId!,
                    config: config
                )
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
    private func autoAssignPartyIndex() {
        // Use peer.id for comparison — ensures same namespace on both sides.
        // For relay: peer.id is the remote deviceId (UUID), local is relay.deviceId (UUID).
        // For WiFi-LAN: peer.id is the device name, local is UIDevice.current.name.
        let hasRelayPeer = foundPeers.contains { $0.channel == "relay" }
        let localId = hasRelayPeer
            ? (peerManager?.relay.deviceId ?? UIDevice.current.name)
            : UIDevice.current.name

        var peerIds: [String] = []
        var seen: Set<String> = []
        for peer in foundPeers {
            if seen.insert(peer.id).inserted {
                peerIds.append(peer.id)
            }
        }
        var allIds = peerIds
        allIds.append(localId)
        allIds.sort()
        let myIndex = (allIds.firstIndex(of: localId) ?? 0) + 1
        NSLog("[DKG] Auto-assign party index: localId=\"\(localId.prefix(8))\", participants=\(allIds.map { String($0.prefix(8)) }), myIndex=\(myIndex)")
        partyIndex = myIndex
    }

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
            for await (peer, data) in peerManager.incomingMpcMessages {
                msgCount += 1
                NSLog("[DKG] Received msg #\(msgCount) from \(peer.id.prefix(8))... (\(data.count) bytes, channel=\(peer.channel))")

                // Deduplicate: skip if we already processed identical payload
                if processedPayloads.contains(data) {
                    NSLog("[DKG] Skipping duplicate message (already processed via another transport)")
                    continue
                }
                processedPayloads.insert(data)

                let decodedDTO: MpcMessageDTO?
                do {
                    decodedDTO = try JSONDecoder().decode(MpcMessageDTO.self, from: data)
                } catch {
                    NSLog("[DKG] Failed to decode MPC message: \(error.localizedDescription)")
                    SecureLog.error("Failed to decode MPC message during DKG: \(error.localizedDescription)")
                    decodedDTO = nil
                }
                if let dto = decodedDTO {
                    let msg = dto.toFfi()
                    NSLog("[DKG] Processing msg: from=\(msg.fromParty) to=\(msg.toParty) session=\(msg.sessionId.prefix(8))...")

                    let responses: [FfiMpcMessage]
                    do {
                        NSLog("[DKG] Calling bridge.handleMessage...")
                        responses = try bridge.handleMessage(msg)
                    } catch {
                        NSLog("[DKG] handleMessage error: \(error.localizedDescription)")
                        throw error
                    }
                    NSLog("[DKG] handleMessage returned \(responses.count) responses")

                    // Update round progress (use msgCount since msg.round is always 0 from FFI)
                    currentRound = msgCount
                    updateProgress()
                    updateDKGStatusMessage()

                    // Send responses to peers
                    for response in responses {
                        let responseData = try JSONEncoder().encode(MpcMessageDTO(response))
                        NSLog("[DKG] Sending response: to=\(response.toParty) data=\(responseData.count)B")
                        try await peerManager.broadcastMpcMessage(responseData)
                    }

                    // Check if keygen is complete
                    if let result = bridge.getKeygenResult(sessionId: sessionId!) {
                        NSLog("[DKG] ✅ Keygen complete! publicKey=\(result.publicKey.count)B shard=\(result.shardData.count)B")
                        keygenResult = result
                        break
                    } else {
                        NSLog("[DKG] Keygen not yet complete, waiting for more messages...")
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

    /// Save the freshly-generated shard. Pass the PBKDF2-derived key material
    /// directly (callers may use `AppState.cachedShardKey()` to reuse the key
    /// from the just-completed unlock and skip a second PIN prompt).
    func saveWallet(to appState: AppState, keyMaterial: Data) {
        guard let result = keygenResult else { return }

        let baseId = sessionId ?? UUID().uuidString
        // accountId is the hex of the DKG group public key and is shared
        // across all derived chains. We write the encrypted shard exactly
        // once, keyed by accountId.
        let accountId = result.publicKey.map { String(format: "%02x", $0) }.joined()

        // Persist the shard once.
        do {
            let deviceKey = try appState.deviceKey
            let encrypted = try appState.bridge.encryptShard(
                plaintext: result.shardData,
                deviceKey: deviceKey,
                pin: keyMaterial
            )
            let encoded = try JSONEncoder().encode(EncryptedShardDTO(encrypted))
            try appState.walletStore.storeKeyShare(encoded, accountId: accountId)
        } catch {
            SecureLog.error("Failed to store key share: \(error)")
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
        appState.bridge.removeSession(sessionId: sessionId!)
    }

    /// Convenience: unwrap the Shard Wrap Key via PIN and save. Used as
    /// the fallback path when the SWK isn't already cached (e.g. session
    /// was unlocked via biometric on a build without an SE-sealed SWK).
    func saveWallet(to appState: AppState, pin: String) {
        guard appState.verifyPin(pin) else { return }
        guard let swk = appState.cachedShardKey() else { return }
        saveWallet(to: appState, keyMaterial: swk)
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
