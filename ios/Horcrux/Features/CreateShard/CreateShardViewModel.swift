import Foundation
import Combine

/// View model for the DKG (shard creation) ceremony.
@MainActor
final class CreateShardViewModel: ObservableObject {
    enum Step {
        case configure, discover, dkg, complete, error
    }

    // Configuration
    @Published var step: Step = .configure
    @Published var walletName: String = ""
    @Published var selectedChain: Chain = .ethereum
    @Published var threshold: Int = 2
    @Published var totalParties: Int = 2
    @Published var partyIndex: Int = 1
    @Published var selectedTransports: Set<TransportType> = [.relay]
    @Published var roomCode: String = ""

    // Discovery
    @Published var foundPeers: [Peer] = []

    // DKG progress
    @Published var dkgProgress: Double = 0
    @Published var dkgStatusMessage: String = ""
    @Published var currentRound: Int = 0
    @Published var totalRounds: Int = 7 // CGGMP21 = 7 rounds, FROST = 3

    // Result
    @Published var generatedAddress: String?
    @Published var errorMessage: String = ""

    private var sessionId: String?
    private var keygenResult: FfiKeygenResult?
    private var peerManager: PeerManager?
    private var bridge: HorcruxBridge?
    private var cancellables = Set<AnyCancellable>()
    private var ceremonyTask: Task<Void, Never>?

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
        totalRounds = selectedChain == .solana ? 3 : 7
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
        sessionId = UUID().uuidString
        peerManager?.stopDiscovery()

        ceremonyTask = Task {
            do {
                guard let bridge else { throw DKGError.notInitialized }

                let config = FfiHorcruxConfig(
                    threshold: UInt16(threshold),
                    totalParties: UInt16(totalParties),
                    partyIndex: UInt16(partyIndex),
                    curve: selectedChain.curveType
                )

                dkgStatusMessage = L10n.DKG.initializingKeyGen
                currentRound = 1

                let outgoing = try bridge.startKeygen(
                    sessionId: sessionId!,
                    config: config
                )

                dkgProgress = 0.15
                dkgStatusMessage = L10n.DKG.exchangingCommitments

                await runDKGRounds(initialMessages: outgoing)

            } catch {
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

    private func runDKGRounds(initialMessages: [FfiMpcMessage]) async {
        guard let bridge, let peerManager else { return }

        do {
            // Send initial outgoing messages to peers
            for msg in initialMessages {
                let data = try JSONEncoder().encode(MpcMessageDTO(msg))
                try await peerManager.broadcastMpcMessage(data)
            }

            // Listen for incoming messages and process rounds
            var roundComplete = false
            for await (_, data) in peerManager.incomingMpcMessages {
                guard !roundComplete else { break }

                let decodedDTO: MpcMessageDTO?
                do {
                    decodedDTO = try JSONDecoder().decode(MpcMessageDTO.self, from: data)
                } catch {
                    SecureLog.error("Failed to decode MPC message during DKG: \(error.localizedDescription)")
                    decodedDTO = nil
                }
                if let dto = decodedDTO {
                    let msg = dto.toFfi()
                    let responses = try bridge.handleMessage(msg)

                    // Update round progress
                    currentRound = Int(msg.round)
                    dkgProgress = Double(currentRound) / Double(totalRounds + 1)
                    updateDKGStatusMessage()

                    // Send responses to peers
                    for response in responses {
                        let responseData = try JSONEncoder().encode(MpcMessageDTO(response))
                        try await peerManager.broadcastMpcMessage(responseData)
                    }

                    // Check if keygen is complete
                    if let result = bridge.getKeygenResult(sessionId: sessionId!) {
                        keygenResult = result
                        roundComplete = true
                    }
                }
            }

            // Derive address from group public key
            guard let result = keygenResult else {
                throw DKGError.keygenIncomplete
            }

            dkgProgress = 0.95
            dkgStatusMessage = L10n.DKG.derivingAddress

            generatedAddress = try bridge.deriveAddress(
                chain: selectedChain,
                publicKey: result.publicKey
            )

            dkgProgress = 1.0
            step = .complete

        } catch {
            errorMessage = error.localizedDescription
            step = .error
        }
    }

    private func updateDKGStatusMessage() {
        switch currentRound {
        case 1: dkgStatusMessage = L10n.DKG.exchangingCommitments
        case 2: dkgStatusMessage = L10n.DKG.verifyingShares
        case 3: dkgStatusMessage = selectedChain == .solana
            ? L10n.DKG.finalizingKeyPackage
            : L10n.DKG.computingPaillierKeys
        case 4: dkgStatusMessage = L10n.DKG.generatingZKProofs
        case 5: dkgStatusMessage = L10n.DKG.verifyingProofs
        case 6: dkgStatusMessage = L10n.DKG.computingAuxInfo
        case 7: dkgStatusMessage = L10n.DKG.finalizingKeyShares
        default: dkgStatusMessage = L10n.DKG.processing
        }
    }

    func saveWallet(to appState: AppState, pin: String) {
        guard let result = keygenResult else { return }

        let wallet = Wallet(
            id: sessionId ?? UUID().uuidString,
            name: walletName,
            chain: selectedChain,
            address: generatedAddress ?? "unknown",
            groupPublicKey: result.publicKey,
            threshold: UInt16(threshold),
            totalParties: UInt16(totalParties),
            partyIndex: UInt16(partyIndex),
            createdAt: .now
        )

        appState.walletStore.add(wallet)

        // Store encrypted key share in Keychain (PIN used for real encryption)
        do {
            let deviceKey = try appState.deviceKey
            let encrypted = try appState.bridge.encryptShard(
                plaintext: result.shardData,
                deviceKey: deviceKey,
                pin: try AppState.pinKeyMaterial(pin)
            )
            let encoded = try JSONEncoder().encode(EncryptedShardDTO(encrypted))
            try appState.walletStore.storeKeyShare(encoded, walletId: wallet.id)
        } catch {
            SecureLog.error("Failed to store key share: \(error)")
        }

        // Register shard with the in-memory shard manager
        let shardInfo = FfiShardInfo(
            shardId: wallet.id,
            publicKey: result.publicKey,
            partyIndex: result.partyIndex,
            threshold: result.threshold,
            totalParties: result.totalParties,
            curve: selectedChain.curveType,
            createdAt: UInt64(Date.now.timeIntervalSince1970),
            isLocal: true
        )
        appState.bridge.addShard(info: shardInfo)

        // Clean up MPC session
        appState.bridge.removeSession(sessionId: sessionId!)
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
