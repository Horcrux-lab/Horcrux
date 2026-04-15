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
        wallets.removeAll { $0.id == id }
        try? keychain.delete(key: "shard_\(id)")
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
            createdAt: wallets[idx].createdAt
        )
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        wallets.move(fromOffsets: source, toOffset: destination)
        save()
    }

    // MARK: - Key Share Storage (Keychain)

    /// Store an encrypted key share in the Keychain (with enhanced protection).
    func storeKeyShare(_ data: Data, walletId: String) throws {
        try keychain.storeSecure(key: "shard_\(walletId)", data: data)
    }

    /// Retrieve the key share for a wallet from the Keychain.
    func loadKeyShare(walletId: String) throws -> Data? {
        try keychain.retrieve(key: "shard_\(walletId)")
    }

    // MARK: - Wipe

    /// Delete all wallets and their key shares. Irreversible.
    func wipeAll() {
        for wallet in wallets {
            try? keychain.delete(key: "shard_\(wallet.id)")
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
