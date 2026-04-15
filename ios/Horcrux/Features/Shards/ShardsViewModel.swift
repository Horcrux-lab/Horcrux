import Foundation

/// View model for shard management operations.
@MainActor
final class ShardsViewModel: ObservableObject {
    @Published var backupStatus: String?
    @Published var error: String?

    private var appState: AppState?

    func bind(to appState: AppState) {
        self.appState = appState
    }

    func backupShard(wallet: Wallet, pin: String) {
        guard let appState else { return }

        do {
            // Load the encrypted shard from Keychain
            guard let storedData = try appState.walletStore.loadKeyShare(walletId: wallet.id) else {
                error = "Key shard not found"
                return
            }

            let exportData = try JSONEncoder().encode(ShardBackup(
                walletId: wallet.id,
                walletName: wallet.name,
                chain: wallet.chain,
                partyIndex: wallet.partyIndex,
                threshold: wallet.threshold,
                totalParties: wallet.totalParties,
                encryptedShard: storedData
            ))

            // In production: present share sheet / save to iCloud
            backupStatus = "Shard exported (\(exportData.count) bytes)"
        } catch {
            self.error = error.localizedDescription
        }
    }

    func restoreShard(from data: Data) throws -> ShardBackup {
        try JSONDecoder().decode(ShardBackup.self, from: data)
    }

    func deleteShard(wallet: Wallet) {
        appState?.walletStore.remove(id: wallet.id)
    }
}

/// Serializable shard backup format.
struct ShardBackup: Codable {
    let walletId: String
    let walletName: String
    let chain: Chain
    let partyIndex: UInt16
    let threshold: UInt16
    let totalParties: UInt16
    let encryptedShard: Data
}
