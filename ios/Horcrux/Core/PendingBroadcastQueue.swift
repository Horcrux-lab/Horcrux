import Foundation

/// Queue for signed transactions pending broadcast.
/// Enables offline signing — sign now, broadcast later when connectivity returns.
@MainActor
final class PendingBroadcastQueue: ObservableObject {
    @Published private(set) var pending: [PendingTransaction] = []

    struct PendingTransaction: Identifiable, Codable {
        let id: String
        let walletId: String
        let chain: Chain
        let signedPayload: String   // hex or base64 signed tx
        let toAddress: String
        let amount: String
        let createdAt: Date
        var attempts: Int = 0
        var lastError: String?
    }

    private let fileURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        fileURL = docs.appendingPathComponent("horcrux_pending_broadcast.json")
        load()
    }

    // MARK: - Queue Operations

    func enqueue(_ tx: PendingTransaction) {
        pending.append(tx)
        save()
    }

    func dequeue(id: String) {
        pending.removeAll { $0.id == id }
        save()
    }

    func markAttempt(id: String, error: String?) {
        guard let idx = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[idx].attempts += 1
        pending[idx].lastError = error
        save()
    }

    var count: Int { pending.count }
    var isEmpty: Bool { pending.isEmpty }

    func pendingFor(walletId: String) -> [PendingTransaction] {
        pending.filter { $0.walletId == walletId }
    }

    /// Attempt to broadcast all pending transactions.
    func broadcastAll(service: BlockchainService, config: NetworkConfig,
                      transactionStore: TransactionStore) async {
        for tx in pending {
            do {
                let result: String
                switch tx.chain {
                case .ethereum:
                    result = try await service.ethSendRawTransaction(
                        signedTxHex: tx.signedPayload, rpcURL: config.ethereumRPC)
                case .bitcoin:
                    result = try await service.btcBroadcast(
                        signedTxHex: tx.signedPayload, apiURL: config.bitcoinAPI)
                case .solana:
                    result = try await service.solSendTransaction(
                        signedTxBase64: tx.signedPayload, rpcURL: config.solanaRPC)
                }
                // Success — update transaction store and remove from queue
                transactionStore.updateStatus(id: tx.id, status: .broadcast, txHash: result)
                dequeue(id: tx.id)
            } catch {
                markAttempt(id: tx.id, error: error.localizedDescription)
            }
        }
    }

    func wipeAll() {
        pending = []
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            pending = try JSONDecoder().decode([PendingTransaction].self, from: data)
        } catch {
            SecureLog.error("PendingBroadcastQueue: load failed: \(error)")
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(pending)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        } catch {
            SecureLog.error("PendingBroadcastQueue: save failed: \(error)")
        }
    }
}
