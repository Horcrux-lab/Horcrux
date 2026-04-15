import Foundation

/// View model for shard management operations.
@MainActor
final class ShardsViewModel: ObservableObject {
    private let bridge = HorcruxBridge()

    @Published var backupStatus: String?
    @Published var error: String?

    func backupShard(wallet: Wallet, pin: String) {
        do {
            let shardData = wallet.groupPublicKey // In production: actual key share bytes
            let encrypted = try bridge.encryptShard(data: shardData, pin: pin)

            // In production: save encrypted shard to a file / iCloud / share sheet
            let exportData = try JSONEncoder().encode(ShardBackup(
                walletId: wallet.id,
                walletName: wallet.name,
                chain: wallet.chain,
                partyIndex: wallet.partyIndex,
                threshold: wallet.threshold,
                totalParties: wallet.totalParties,
                encrypted: ShardBackup.EncryptedData(
                    ciphertext: encrypted.ciphertext,
                    nonce: encrypted.nonce,
                    salt: encrypted.salt
                )
            ))

            backupStatus = "Shard exported (\(exportData.count) bytes)"
        } catch {
            self.error = error.localizedDescription
        }
    }

    func restoreShard(from data: Data, pin: String) throws -> ShardBackup {
        let backup = try JSONDecoder().decode(ShardBackup.self, from: data)
        let encrypted = FfiEncryptedShard(
            ciphertext: backup.encrypted.ciphertext,
            nonce: backup.encrypted.nonce,
            salt: backup.encrypted.salt
        )
        let _ = try bridge.decryptShard(encrypted: encrypted, pin: pin)
        return backup
    }

    func deleteShard(wallet: Wallet) {
        try? bridge.deleteShard(id: wallet.id)
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
    let encrypted: EncryptedData

    struct EncryptedData: Codable {
        let ciphertext: [UInt8]
        let nonce: [UInt8]
        let salt: [UInt8]
    }
}
