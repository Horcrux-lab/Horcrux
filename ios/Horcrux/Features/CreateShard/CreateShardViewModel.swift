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
    @Published var totalParties: Int = 3
    @Published var partyIndex: Int = 1
    @Published var selectedTransports: Set<TransportType> = [.ble, .wifiLAN]

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

    private let bridge = HorcruxBridge()
    private var sessionId: String?
    private var keygenResult: FfiKeygenResult?

    init() {
        // Adjust total rounds based on chain selection
    }

    func startDiscovery() {
        // In a real app, this drives the PeerManager
        // For now, simulate peer discovery
        totalRounds = selectedChain == .solana ? 3 : 7

        Task {
            dkgStatusMessage = "Searching for nearby devices…"
        }
    }

    func startDKG() {
        step = .dkg
        sessionId = UUID().uuidString

        Task {
            do {
                let config = FfiHorcruxConfig(
                    threshold: UInt16(threshold),
                    totalParties: UInt16(totalParties),
                    partyIndex: UInt16(partyIndex),
                    curve: selectedChain.curveType
                )

                dkgStatusMessage = "Initializing key generation…"
                currentRound = 1

                // Start keygen — get first round messages
                let outgoing = try bridge.startKeygen(
                    sessionId: sessionId!,
                    config: config
                )

                dkgProgress = 0.15
                dkgStatusMessage = "Exchanging commitments…"

                // In production: send outgoing messages via PeerManager,
                // receive responses, feed back into processMessages(),
                // repeat until all rounds complete.
                // Here we show the DKG orchestration structure:

                await runDKGRounds(initialMessages: outgoing)

            } catch {
                errorMessage = error.localizedDescription
                step = .error
            }
        }
    }

    private func runDKGRounds(initialMessages: [FfiMpcMessage]) async {
        // TODO: Wire to PeerManager for actual message exchange.
        // The flow is:
        //
        // 1. Send `initialMessages` to peers via PeerManager
        // 2. Collect incoming messages from peers
        // 3. Call bridge.processMessages(sessionId, incomingMessages)
        // 4. Send resulting outgoing messages to peers
        // 5. Repeat until processMessages returns empty (protocol complete)
        // 6. Call bridge.finalizeKeygen(sessionId)
        //
        // Each round updates currentRound and dkgProgress.

        do {
            // Simulate round progression for UI demonstration
            for round in 1...totalRounds {
                currentRound = round
                dkgProgress = Double(round) / Double(totalRounds + 1)

                switch round {
                case 1: dkgStatusMessage = "Exchanging commitments…"
                case 2: dkgStatusMessage = "Verifying shares…"
                case 3: dkgStatusMessage = selectedChain == .solana
                    ? "Finalizing key package…"
                    : "Computing Paillier keys…"
                case 4: dkgStatusMessage = "Generating ZK proofs…"
                case 5: dkgStatusMessage = "Verifying proofs…"
                case 6: dkgStatusMessage = "Computing auxiliary info…"
                case 7: dkgStatusMessage = "Finalizing key shares…"
                default: dkgStatusMessage = "Processing…"
                }

                try await Task.sleep(for: .milliseconds(500))
            }

            // Finalize
            dkgProgress = 0.95
            dkgStatusMessage = "Deriving address…"

            let result = try bridge.finalizeKeygen(sessionId: sessionId!)
            keygenResult = result

            // Derive address
            switch selectedChain {
            case .ethereum:
                generatedAddress = try bridge.evmAddress(publicKey: Data(result.groupPublicKey))
            case .bitcoin:
                generatedAddress = try bridge.btcAddress(publicKey: Data(result.groupPublicKey))
            case .solana:
                generatedAddress = try bridge.solanaAddress(publicKey: Data(result.groupPublicKey))
            }

            dkgProgress = 1.0
            step = .complete

        } catch {
            errorMessage = error.localizedDescription
            step = .error
        }
    }

    func saveWallet(to appState: AppState) {
        guard let result = keygenResult else { return }

        let wallet = Wallet(
            id: sessionId ?? UUID().uuidString,
            name: walletName,
            chain: selectedChain,
            address: generatedAddress ?? "unknown",
            groupPublicKey: Data(result.groupPublicKey),
            threshold: UInt16(threshold),
            totalParties: UInt16(totalParties),
            partyIndex: UInt16(partyIndex),
            createdAt: .now
        )

        appState.wallets.append(wallet)
    }
}
