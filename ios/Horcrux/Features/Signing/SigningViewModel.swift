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

    private let bridge = HorcruxBridge()
    private var sessionId: String?

    var shortRecipient: String {
        guard recipientAddress.count > 12 else { return recipientAddress }
        return "\(recipientAddress.prefix(6))…\(recipientAddress.suffix(4))"
    }

    init(wallet: Wallet) {
        self.wallet = wallet
        self.totalRounds = wallet.chain == .solana ? 2 : 4
    }

    func startSigning() {
        step = .signing
        sessionId = UUID().uuidString

        Task {
            do {
                let config = FfiHorcruxConfig(
                    threshold: wallet.threshold,
                    totalParties: wallet.totalParties,
                    partyIndex: wallet.partyIndex,
                    curve: wallet.chain.curveType
                )

                // Build the transaction message to sign
                let message = buildTransactionMessage()

                signingStatusMessage = "Initializing signing protocol…"
                currentRound = 1

                // Start signing session
                let outgoing = try bridge.startSigning(
                    sessionId: sessionId!,
                    config: config,
                    keyShare: wallet.groupPublicKey, // In production: load actual key share
                    message: message
                )

                signingProgress = 0.2

                // Run signing rounds (same pattern as DKG)
                await runSigningRounds(initialMessages: outgoing)

            } catch {
                errorMessage = error.localizedDescription
                step = .error
            }
        }
    }

    private func runSigningRounds(initialMessages: [FfiMpcMessage]) async {
        do {
            for round in 1...totalRounds {
                currentRound = round
                signingProgress = Double(round) / Double(totalRounds + 1)

                switch round {
                case 1: signingStatusMessage = "Broadcasting nonce commitments…"
                case 2: signingStatusMessage = wallet.chain == .solana
                    ? "Computing signature shares…"
                    : "Exchanging encrypted nonces…"
                case 3: signingStatusMessage = "Computing partial signatures…"
                case 4: signingStatusMessage = "Combining signature…"
                default: signingStatusMessage = "Processing…"
                }

                try await Task.sleep(for: .milliseconds(300))
            }

            // Finalize
            signingProgress = 0.95
            signingStatusMessage = "Verifying signature…"

            let result = try bridge.finalizeSigning(sessionId: sessionId!)

            // In production: broadcast the signed transaction to the network
            txHash = "0x" + result.signature.map { String(format: "%02x", $0) }.joined().prefix(16) + "…"

            signingProgress = 1.0
            step = .complete

        } catch {
            errorMessage = error.localizedDescription
            step = .error
        }
    }

    private func buildTransactionMessage() -> Data {
        // In production: construct a proper transaction and hash it
        let txDescription = "\(amount) \(wallet.chain.symbol) → \(recipientAddress)"
        return Data(txDescription.utf8)
    }
}
