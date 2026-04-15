import Foundation

/// View model for shard management operations.
@MainActor
final class ShardsViewModel: ObservableObject {
    @Published var backupStatus: String?
    @Published var exportData: Data?
    @Published var importStatus: ImportStatus?
    @Published var error: String?

    enum ImportStatus: Equatable {
        case success(walletName: String)
        case failure(String)
    }

    private var appState: AppState?

    func bind(to appState: AppState) {
        self.appState = appState
    }

    // MARK: - Backup

    func backupShard(wallet: Wallet, pin: String) {
        guard let appState else { return }
        exportData = nil
        error = nil

        do {
            guard let storedData = try appState.walletStore.loadKeyShare(walletId: wallet.id) else {
                error = "Key shard not found"
                return
            }

            // Decrypt the shard so the backup is portable across devices
            let dto = try JSONDecoder().decode(EncryptedShardDTO.self, from: storedData)
            let deviceKey = try appState.deviceKey
            let plaintext = try appState.bridge.decryptShard(
                encrypted: dto.toFfi(),
                deviceKey: deviceKey,
                pin: AppState.pinKeyMaterial(pin)
            )

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

            let backup = ShardBackup(
                version: 1,
                walletId: wallet.id,
                walletName: wallet.name,
                chain: wallet.chain,
                address: wallet.address,
                partyIndex: wallet.partyIndex,
                threshold: wallet.threshold,
                totalParties: wallet.totalParties,
                encryptedShard: plaintext,
                exportedAt: Date()
            )

            let data = try encoder.encode(backup)
            exportData = data
            backupStatus = "Shard exported (\(data.count) bytes)"
            SecureLog.info("Shard backup created for wallet \(wallet.id)")
        } catch {
            self.error = error.localizedDescription
            SecureLog.error("Shard backup failed: \(error.localizedDescription)")
        }
    }

    func clearExport() {
        exportData = nil
        backupStatus = nil
        error = nil
    }

    // MARK: - Import

    /// Decode, re-encrypt, and store a shard backup on this device.
    func importShard(from data: Data, pin: String, appState: AppState) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let backup = try decoder.decode(ShardBackup.self, from: data)

        guard backup.version == 1 else {
            throw ShardImportError.unsupportedVersion(backup.version)
        }

        if appState.walletStore.wallet(for: backup.walletId) != nil {
            throw ShardImportError.duplicateWallet(backup.walletName)
        }

        // Re-encrypt the shard with this device's credentials
        let deviceKey = try appState.deviceKey
        let pinData = AppState.pinKeyMaterial(pin)
        let encrypted = try appState.bridge.encryptShard(
            plaintext: backup.encryptedShard,
            deviceKey: deviceKey,
            pin: pinData
        )
        let encoded = try JSONEncoder().encode(EncryptedShardDTO(encrypted))

        // Reconstruct wallet metadata from the backup
        let wallet = Wallet(
            id: backup.walletId,
            name: backup.walletName,
            chain: backup.chain,
            address: backup.address,
            groupPublicKey: Data(),
            threshold: backup.threshold,
            totalParties: backup.totalParties,
            partyIndex: backup.partyIndex,
            createdAt: Date()
        )

        try appState.walletStore.storeKeyShare(encoded, walletId: wallet.id)
        appState.walletStore.add(wallet)

        importStatus = .success(walletName: backup.walletName)
        SecureLog.info("Shard imported for wallet \(backup.walletId)")
    }

    /// Parse a backup file without importing it (for preview).
    func parseBackup(from data: Data) throws -> ShardBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ShardBackup.self, from: data)
    }

    // MARK: - Delete

    func deleteShard(wallet: Wallet) {
        appState?.walletStore.remove(id: wallet.id)
    }
}

// MARK: - Backup Model

/// Versioned, serializable shard backup format.
struct ShardBackup: Codable {
    let version: Int
    let walletId: String
    let walletName: String
    let chain: Chain
    let address: String
    let partyIndex: UInt16
    let threshold: UInt16
    let totalParties: UInt16
    let encryptedShard: Data
    let exportedAt: Date
}

// MARK: - Import Errors

enum ShardImportError: LocalizedError {
    case unsupportedVersion(Int)
    case duplicateWallet(String)
    case invalidData
    case decryptionFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let v):
            return "Unsupported backup version: \(v)"
        case .duplicateWallet(let name):
            return "Wallet '\(name)' already exists on this device"
        case .invalidData:
            return "Invalid backup data"
        case .decryptionFailed:
            return "Failed to decrypt shard — check your PIN"
        }
    }
}
