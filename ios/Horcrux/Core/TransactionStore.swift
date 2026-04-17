import Foundation

/// Record of a signed/broadcast transaction, persisted locally.
struct TransactionRecord: Identifiable, Codable {
    let id: String
    let walletId: String
    let chain: Chain
    let fromAddress: String
    let toAddress: String
    let amount: String
    let fee: String?
    let txHash: String?
    var status: TxStatus
    let createdAt: Date
    var broadcastAt: Date?

    enum TxStatus: String, Codable {
        case signed     // Locally signed but not broadcast
        case broadcast  // Sent to network
        case confirmed  // Confirmed on-chain (future: check receipt)
        case failed     // Broadcast failed
    }

    /// Explorer URL for this transaction.
    var explorerURL: URL? {
        guard let txHash, !txHash.isEmpty else { return nil }
        return AddressFormatter.txExplorerURL(txHash: txHash, chain: chain)
    }

    var statusIcon: String {
        switch status {
        case .signed:    return "signature"
        case .broadcast: return "antenna.radiowaves.left.and.right"
        case .confirmed: return "checkmark.seal.fill"
        case .failed:    return "xmark.circle.fill"
        }
    }

    var statusColor: String {
        switch status {
        case .signed:    return "orange"
        case .broadcast: return "blue"
        case .confirmed: return "green"
        case .failed:    return "red"
        }
    }
}

/// Persists transaction records to a JSON file in documents directory.
@MainActor
final class TransactionStore: ObservableObject {
    @Published private(set) var records: [TransactionRecord] = []

    private let fileURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        fileURL = docs.appendingPathComponent("horcrux_transactions.json")
        load()
    }

    /// For testing: inject a custom file URL.
    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    // MARK: - CRUD

    func add(_ record: TransactionRecord) {
        records.insert(record, at: 0) // newest first
        save()
    }

    func updateStatus(id: String, status: TransactionRecord.TxStatus, txHash: String? = nil) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        records[idx].status = status
        if let txHash { records[idx] = withUpdatedHash(records[idx], txHash: txHash) }
        if status == .broadcast { records[idx].broadcastAt = Date() }
        save()
    }

    func records(for walletId: String) -> [TransactionRecord] {
        records.filter { $0.walletId == walletId }
    }

    func removeAll(for walletId: String) {
        records.removeAll { $0.walletId == walletId }
        save()
    }

    func wipeAll() {
        records = []
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            records = try JSONDecoder().decode([TransactionRecord].self, from: data)
        } catch {
            SecureLog.error("TransactionStore: failed to load: \(error)")
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(records)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            var mutableURL = fileURL
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try mutableURL.setResourceValues(resourceValues)
        } catch {
            SecureLog.error("TransactionStore: failed to save: \(error)")
        }
    }

    /// Helper: create a copy with updated txHash (since txHash is let).
    private func withUpdatedHash(_ record: TransactionRecord, txHash: String) -> TransactionRecord {
        TransactionRecord(
            id: record.id,
            walletId: record.walletId,
            chain: record.chain,
            fromAddress: record.fromAddress,
            toAddress: record.toAddress,
            amount: record.amount,
            fee: record.fee,
            txHash: txHash,
            status: record.status,
            createdAt: record.createdAt,
            broadcastAt: record.broadcastAt
        )
    }
}
