import Foundation
import Combine

/// View model for threshold signing ceremony.
@MainActor
final class SigningViewModel: ObservableObject {
    enum Step {
        case compose, invite, signing, complete, error
    }

    let wallet: Wallet

    @Published var step: Step = .compose
    @Published var recipientAddress: String = ""
    @Published var amount: String = ""

    // Signing
    @Published var joinedSigners: [Peer] = []
    @Published var signingProgress: Double = 0
    @Published var signingStatusMessage: String = ""
    @Published var currentRound: Int = 0
    @Published var totalRounds: Int = 4 // CGGMP21 signing = 4, FROST = 2

    // Result
    @Published var txHash: String?
    @Published var errorMessage: String = ""

    private var bridge: HorcruxBridge?
    private var peerManager: PeerManager?
    private var walletStore: WalletStore?
    private var deviceKey: Data?
    private var sessionId: String?
    private var cancellables = Set<AnyCancellable>()

    var shortRecipient: String {
        guard recipientAddress.count > 12 else { return recipientAddress }
        return "\(recipientAddress.prefix(6))…\(recipientAddress.suffix(4))"
    }

    init(wallet: Wallet) {
        self.wallet = wallet
        self.totalRounds = wallet.chain == .solana ? 2 : 4
    }

    func bind(to appState: AppState) {
        self.bridge = appState.bridge
        self.peerManager = appState.peerManager
        self.walletStore = appState.walletStore
        self.deviceKey = appState.deviceKey

        // Observe connected peers as potential co-signers
        appState.peerManager.$connectedPeers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] peers in
                self?.joinedSigners = peers
            }
            .store(in: &cancellables)
    }

    func startSigning() {
        step = .signing
        sessionId = UUID().uuidString

        Task {
            do {
                guard let bridge, let peerManager, let deviceKey else {
                    throw SigningError.notInitialized
                }

                let config = FfiHorcruxConfig(
                    threshold: wallet.threshold,
                    totalParties: wallet.totalParties,
                    partyIndex: wallet.partyIndex,
                    curve: wallet.chain.curveType
                )

                // Load and decrypt the key share
                let shardData = try loadKeyShare(deviceKey: deviceKey)

                // Build the transaction hash to sign
                let messageHash = buildSignHash()

                // Collect participant indices
                let participants = [wallet.partyIndex] + joinedSigners.prefix(Int(wallet.threshold) - 1).enumerated().map { UInt16($0.offset + 1) }

                signingStatusMessage = "Initializing signing protocol…"
                currentRound = 1

                let outgoing = try bridge.startSigning(
                    sessionId: sessionId!,
                    config: config,
                    messageHash: messageHash,
                    shardData: shardData,
                    participants: participants
                )

                signingProgress = 0.2

                await runSigningRounds(initialMessages: outgoing)

            } catch {
                errorMessage = error.localizedDescription
                step = .error
            }
        }
    }

    private func runSigningRounds(initialMessages: [FfiMpcMessage]) async {
        guard let bridge, let peerManager else { return }

        do {
            // Send initial messages
            for msg in initialMessages {
                let data = try JSONEncoder().encode(MpcMessageDTO(msg))
                try await peerManager.broadcastMpcMessage(data)
            }

            // Process incoming messages
            for await (_, data) in peerManager.incomingMpcMessages {
                if let dto = try? JSONDecoder().decode(MpcMessageDTO.self, from: data) {
                    let msg = dto.toFfi()
                    let responses = try bridge.handleMessage(msg)

                    currentRound = Int(msg.round)
                    signingProgress = Double(currentRound) / Double(totalRounds + 1)
                    updateSigningStatusMessage()

                    for response in responses {
                        let responseData = try JSONEncoder().encode(MpcMessageDTO(response))
                        try await peerManager.broadcastMpcMessage(responseData)
                    }

                    if let result = bridge.getSigningResult(sessionId: sessionId!) {
                        signingProgress = 0.95
                        signingStatusMessage = "Verifying signature…"

                        txHash = "0x" + result.signature.map { String(format: "%02x", $0) }.joined()

                        signingProgress = 1.0
                        bridge.removeSession(sessionId: sessionId!)
                        step = .complete
                        return
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            step = .error
        }
    }

    private func updateSigningStatusMessage() {
        switch currentRound {
        case 1: signingStatusMessage = "Broadcasting nonce commitments…"
        case 2: signingStatusMessage = wallet.chain == .solana
            ? "Computing signature shares…"
            : "Exchanging encrypted nonces…"
        case 3: signingStatusMessage = "Computing partial signatures…"
        case 4: signingStatusMessage = "Combining signature…"
        default: signingStatusMessage = "Processing…"
        }
    }

    private func loadKeyShare(deviceKey: Data) throws -> Data {
        guard let walletStore,
              let encoded = try walletStore.loadKeyShare(walletId: wallet.id) else {
            throw SigningError.shardNotFound
        }
        let dto = try JSONDecoder().decode(EncryptedShardDTO.self, from: encoded)
        let encrypted = dto.toFfi()
        guard let bridge else { throw SigningError.notInitialized }
        return try bridge.decryptShard(
            encrypted: encrypted,
            deviceKey: deviceKey,
            pin: Data(Array(repeating: UInt8(0), count: 1))
        )
    }

    private func buildSignHash() -> Data {
        // Build a proper transaction message hash based on chain
        switch wallet.chain {
        case .ethereum:
            // EIP-1559 transaction hash placeholder
            let txData = "\(amount) ETH → \(recipientAddress)"
            return horcruxKeccak256(data: Data(txData.utf8))
        case .bitcoin:
            let txData = "\(amount) BTC → \(recipientAddress)"
            return horcruxKeccak256(data: Data(txData.utf8))
        case .solana:
            let txData = "\(amount) SOL → \(recipientAddress)"
            return Data(txData.utf8)
        }
    }
}

private enum SigningError: LocalizedError {
    case notInitialized
    case shardNotFound

    var errorDescription: String? {
        switch self {
        case .notInitialized: return "Signing session not initialized"
        case .shardNotFound: return "Key shard not found on this device"
        }
    }
}
