import Foundation

/// Persists wallets to a JSON file in the app's documents directory.
/// Key shares are stored encrypted in the Keychain separately.
@MainActor
final class WalletStore: ObservableObject {
    @Published private(set) var wallets: [Wallet] = []

    private let fileURL: URL
    private let keychain = KeychainManager.shared

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        fileURL = docs.appendingPathComponent("horcrux_wallets.json")
        load()
    }

    // MARK: - CRUD

    func add(_ wallet: Wallet) {
        wallets.append(wallet)
        save()
    }

    func remove(id: String) {
        let removed = wallets.first { $0.id == id }
        wallets.removeAll { $0.id == id }
        // Only delete the shared shard entry if no sibling (same accountId)
        // wallets remain — shard is per-account, not per-chain.
        if let removed,
           !wallets.contains(where: { $0.accountId == removed.accountId }) {
            try? keychain.delete(key: "shard_\(removed.accountId)")
        }
        save()
    }

    /// Remove every wallet belonging to the given account, plus the shared
    /// shard entry. This is the user-facing "delete account" operation.
    func removeAccount(accountId: String) {
        wallets.removeAll { $0.accountId == accountId }
        try? keychain.delete(key: "shard_\(accountId)")
        save()
    }

    func wallet(for id: String) -> Wallet? {
        wallets.first { $0.id == id }
    }

    func rename(id: String, newName: String) {
        guard let idx = wallets.firstIndex(where: { $0.id == id }) else { return }
        wallets[idx] = Wallet(
            id: wallets[idx].id,
            name: newName,
            chain: wallets[idx].chain,
            address: wallets[idx].address,
            groupPublicKey: wallets[idx].groupPublicKey,
            threshold: wallets[idx].threshold,
            totalParties: wallets[idx].totalParties,
            partyIndex: wallets[idx].partyIndex,
            createdAt: wallets[idx].createdAt,
            isHidden: wallets[idx].isHidden
        )
        save()
    }

    /// Toggle a wallet's hidden flag without changing any other data.
    /// Hidden wallets are filtered out of the main wallet list but remain
    /// signable and recoverable — this is purely a declutter aid for users
    /// who generate many per-chain wallets from a single DKG ceremony.
    func setHidden(id: String, hidden: Bool) {
        guard let idx = wallets.firstIndex(where: { $0.id == id }) else { return }
        let w = wallets[idx]
        wallets[idx] = Wallet(
            id: w.id,
            name: w.name,
            chain: w.chain,
            address: w.address,
            groupPublicKey: w.groupPublicKey,
            threshold: w.threshold,
            totalParties: w.totalParties,
            partyIndex: w.partyIndex,
            createdAt: w.createdAt,
            isHidden: hidden ? true : nil
        )
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        wallets.move(fromOffsets: source, toOffset: destination)
        save()
    }

    // MARK: - Key Share Storage (Keychain)

    /// Store an encrypted key share keyed by **accountId** (= hex of the
    /// group public key). All wallets that share the same DKG ceremony
    /// resolve to the same entry, so this is written exactly once per
    /// account.
    func storeKeyShare(_ data: Data, accountId: String) throws {
        try keychain.storeSecure(key: "shard_\(accountId)", data: data)
    }

    /// Retrieve the key share for an account.
    func loadKeyShare(accountId: String) throws -> Data? {
        try keychain.retrieve(key: "shard_\(accountId)")
    }

    // MARK: - Wipe

    /// Delete all wallets and their key shares. Irreversible.
    func wipeAll() {
        var seen = Set<String>()
        for wallet in wallets where seen.insert(wallet.accountId).inserted {
            try? keychain.delete(key: "shard_\(wallet.accountId)")
        }
        wallets = []
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            wallets = try JSONDecoder().decode([Wallet].self, from: data)
        } catch {
            SecureLog.error("WalletStore: failed to load wallets: \(error)")
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(wallets)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            // Exclude from iCloud/iTunes backup
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var mutableURL = fileURL
            try mutableURL.setResourceValues(resourceValues)
        } catch {
            SecureLog.error("WalletStore: failed to save wallets: \(error)")
        }
    }
}
