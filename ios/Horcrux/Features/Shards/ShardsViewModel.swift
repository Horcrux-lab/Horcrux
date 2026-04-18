import Foundation

/// View model for shard management operations. All operations are
/// account-scoped: a single MPC account may derive multiple chain
/// wallets but shares exactly one encrypted key share.
@MainActor
final class ShardsViewModel: ObservableObject {
    @Published var backupStatus: String?
    @Published var exportData: Data?
    @Published var importStatus: ImportStatus?
    @Published var error: String?

    enum ImportStatus: Equatable {
        case success(accountName: String, walletCount: Int)
        case failure(String)
    }

    private var appState: AppState?

    func bind(to appState: AppState) {
        self.appState = appState
    }

    // MARK: - Backup (account-level)

    /// Export every wallet belonging to the account identified by
    /// `accountId` into a single portable backup file.
    ///
    /// Two wire formats are supported:
    /// - **v5 (preferred)** — shard is wrapped with the iCloud-synced
    ///   Recovery Key (HKDF-SHA256 → AES-GCM). Restoring on any peer
    ///   Apple-ID device is frictionless; no PIN / password needed.
    /// - **v4 (fallback)** — shard is wrapped with PBKDF2(PIN). Used
    ///   when the user has no iCloud Keychain / RK provisioned.
    ///
    /// When `pin` is empty and an RK is present we always choose v5.
    /// When `pin` is non-empty we produce both paths' inputs and write
    /// v5 preferentially, falling back to v4 if RK provisioning fails.
    func backupAccount(accountId: String, pin: String) {
        guard let appState else { return }
        exportData = nil
        error = nil

        let siblings = appState.walletStore.wallets.filter { $0.accountId == accountId }
        guard let anchor = siblings.first else {
            error = "Account not found"
            return
        }

        // Need plaintext SWK to decrypt the device-wrapped ciphertext.
        // If it's not cached, the caller supplied a PIN; verify + unlock.
        if appState.cachedShardKey() == nil {
            guard !pin.isEmpty else {
                error = L10n.ShardsVM.pinRequired
                return
            }
            guard appState.verifyPin(pin) else {
                error = L10n.ShardsVM.pinWrong
                return
            }
        }

        do {
            guard let storedData = try appState.walletStore.loadKeyShare(accountId: accountId) else {
                error = "Key shard not found"
                return
            }

            let dto = try JSONDecoder().decode(EncryptedShardDTO.self, from: storedData)
            let deviceKey = try appState.deviceKey
            let swk = try resolveShardKey(pin: pin, appState: appState)
            let plaintext = try appState.bridge.decryptShard(
                encrypted: dto.toFfi(),
                deviceKey: deviceKey,
                pin: swk
            )

            // Prefer v5 (Recovery Key) so restoring on another Apple-ID
            // device doesn't need a PIN. Fall back to v4 (PIN) only if
            // RK provisioning fails AND the user gave us a PIN.
            let envelope: Data
            let backupVersion: Int
            let usedRK: Bool
            do {
                let rk = try RecoveryKeyManager.getOrCreate()
                envelope = try PortableBackupCrypto.encrypt(plaintext: plaintext, recoveryKey: rk)
                backupVersion = 5
                usedRK = true
            } catch {
                SecureLog.warning("RK unavailable for backup, falling back to PIN: \(error.localizedDescription)")
                guard !pin.isEmpty else {
                    self.error = L10n.ShardsVM.icloudRKUnavailable
                    return
                }
                envelope = try PortableBackupCrypto.encrypt(plaintext: plaintext, password: pin)
                backupVersion = 4
                usedRK = false
            }

            let walletEntries = siblings.map { w in
                AccountBackup.WalletEntry(
                    id: w.id,
                    name: w.name,
                    chain: w.chain,
                    address: w.address,
                    createdAt: w.createdAt
                )
            }

            let accountName = anchor.name
                .replacingOccurrences(of: " (\(anchor.chain.rawValue))", with: "")
                .replacingOccurrences(of: " (\(anchor.chain.symbol))", with: "")

            let backup = AccountBackup(
                version: backupVersion,
                accountId: accountId,
                accountName: accountName,
                partyIndex: anchor.partyIndex,
                threshold: anchor.threshold,
                totalParties: anchor.totalParties,
                encryptedShard: envelope,
                groupPublicKey: anchor.groupPublicKey,
                wallets: walletEntries,
                exportedAt: Date()
            )

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

            let data = try encoder.encode(backup)
            exportData = data
            let mode = usedRK ? L10n.ShardsVM.encModeICloudRK : L10n.ShardsVM.encModePIN
            backupStatus = L10n.ShardsVM.exportedSummary(siblings.count, data.count, mode)
            SecureLog.info("Account backup created for \(accountId.prefix(8)) (v\(backupVersion))")
        } catch {
            self.error = error.localizedDescription
            SecureLog.error("Account backup failed: \(error.localizedDescription)")
        }
    }

    func clearExport() {
        exportData = nil
        backupStatus = nil
        error = nil
    }

    // MARK: - Import (account- or legacy-single-chain)

    /// Decode, re-encrypt, and store a backup file on this device. Both
    /// v3 (multi-chain account) and v2 (single-chain shard) formats are
    /// accepted.
    func importBackup(from data: Data, pin: String, appState: AppState) throws {
        if let parsed = try? parseAccountBackup(from: data), parsed.version >= 3 {
            try importAccount(backup: parsed, pin: pin, appState: appState)
            return
        }
        let legacy = try parseLegacyBackup(from: data)
        try importLegacy(backup: legacy, pin: pin, appState: appState)
    }

    private func importAccount(backup: AccountBackup, pin: String, appState: AppState) throws {
        guard backup.version >= 3 && backup.version <= 5 else {
            throw ShardImportError.unsupportedVersion(backup.version)
        }
        if appState.walletStore.wallets.contains(where: { $0.accountId == backup.accountId }) {
            throw ShardImportError.duplicateWallet(backup.accountName)
        }

        // Decode the portable envelope into the raw shard plaintext.
        //  v5 → iCloud Recovery Key (no PIN needed)
        //  v4 → PBKDF2(PIN)
        //  v3 → plaintext (legacy, pre-encryption)
        let shardPlaintext: Data
        switch backup.version {
        case 5:
            guard let rk = try? RecoveryKeyManager.getOrCreate() else {
                throw ShardImportError.invalidPin
            }
            do {
                shardPlaintext = try PortableBackupCrypto.decrypt(
                    envelope: backup.encryptedShard,
                    recoveryKey: rk
                )
            } catch PortableBackupCrypto.Error.decryptFailed {
                // Same Apple ID expected but RK didn't match — likely a
                // peer device hasn't finished syncing. Surface that.
                throw ShardImportError.invalidPin
            }
        case 4:
            do {
                shardPlaintext = try PortableBackupCrypto.decrypt(
                    envelope: backup.encryptedShard,
                    password: pin
                )
            } catch PortableBackupCrypto.Error.decryptFailed {
                throw ShardImportError.invalidPin
            }
        default:
            shardPlaintext = backup.encryptedShard // v3 legacy plaintext
        }

        let deviceKey = try appState.deviceKey
        let swk = try resolveShardKey(pin: pin, appState: appState)
        let encrypted = try appState.bridge.encryptShard(
            plaintext: shardPlaintext,
            deviceKey: deviceKey,
            pin: swk
        )
        let encoded = try JSONEncoder().encode(EncryptedShardDTO(encrypted))
        try appState.walletStore.storeKeyShare(encoded, accountId: backup.accountId)

        for entry in backup.wallets {
            let wallet = Wallet(
                id: entry.id,
                name: entry.name,
                chain: entry.chain,
                address: entry.address,
                groupPublicKey: backup.groupPublicKey,
                threshold: backup.threshold,
                totalParties: backup.totalParties,
                partyIndex: backup.partyIndex,
                createdAt: entry.createdAt,
                isHidden: nil
            )
            appState.walletStore.add(wallet)
        }

        importStatus = .success(accountName: backup.accountName, walletCount: backup.wallets.count)
        SecureLog.info("Account imported: \(backup.accountId.prefix(8)) (\(backup.wallets.count) wallets, v\(backup.version))")
    }

    private func importLegacy(backup: ShardBackup, pin: String, appState: AppState) throws {
        guard backup.version >= 1 && backup.version <= 2 else {
            throw ShardImportError.unsupportedVersion(backup.version)
        }
        if appState.walletStore.wallet(for: backup.walletId) != nil {
            throw ShardImportError.duplicateWallet(backup.walletName)
        }

        let deviceKey = try appState.deviceKey
        let swk = try resolveShardKey(pin: pin, appState: appState)
        let encrypted = try appState.bridge.encryptShard(
            plaintext: backup.encryptedShard,
            deviceKey: deviceKey,
            pin: swk
        )
        let encoded = try JSONEncoder().encode(EncryptedShardDTO(encrypted))

        let wallet = Wallet(
            id: backup.walletId,
            name: backup.walletName,
            chain: backup.chain,
            address: backup.address,
            groupPublicKey: backup.groupPublicKey ?? Data(),
            threshold: backup.threshold,
            totalParties: backup.totalParties,
            partyIndex: backup.partyIndex,
            createdAt: Date(),
            isHidden: nil
        )

        try appState.walletStore.storeKeyShare(encoded, accountId: wallet.accountId)
        appState.walletStore.add(wallet)

        importStatus = .success(accountName: backup.walletName, walletCount: 1)
        SecureLog.info("Legacy shard imported for wallet \(backup.walletId)")
    }

    /// Parse a v3 account backup.
    func parseAccountBackup(from data: Data) throws -> AccountBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AccountBackup.self, from: data)
    }

    /// Parse a v2 legacy shard backup.
    func parseLegacyBackup(from data: Data) throws -> ShardBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ShardBackup.self, from: data)
    }

    /// Attempt both parsers; returns either the v3 description or v2.
    func previewBackup(from data: Data) -> BackupPreview? {
        if let account = try? parseAccountBackup(from: data), account.version >= 3 {
            return .account(account)
        }
        if let legacy = try? parseLegacyBackup(from: data) {
            return .legacy(legacy)
        }
        return nil
    }

    // MARK: - Delete (account-level)

    func deleteAccount(accountId: String) {
        appState?.walletStore.removeAccount(accountId: accountId)
    }

    // MARK: - Helpers

    private func resolveShardKey(pin: String, appState: AppState) throws -> Data {
        if let cached = appState.cachedShardKey() {
            return cached
        }
        guard appState.verifyPin(pin) else { throw ShardImportError.invalidPin }
        guard let unwrapped = appState.cachedShardKey() else { throw ShardImportError.invalidPin }
        return unwrapped
    }
}

// MARK: - Backup Models

/// V3: multi-chain account backup. One encrypted shard + N derived wallets.
struct AccountBackup: Codable {
    let version: Int
    let accountId: String
    let accountName: String
    let partyIndex: UInt16
    let threshold: UInt16
    let totalParties: UInt16
    let encryptedShard: Data
    let groupPublicKey: Data
    let wallets: [WalletEntry]
    let exportedAt: Date

    struct WalletEntry: Codable {
        let id: String
        let name: String
        let chain: Chain
        let address: String
        let createdAt: Date
    }
}

/// V2 legacy single-chain backup (still accepted on import).
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
    let groupPublicKey: Data?
}

enum BackupPreview {
    case account(AccountBackup)
    case legacy(ShardBackup)

    var name: String {
        switch self {
        case .account(let b): return b.accountName
        case .legacy(let b): return b.walletName
        }
    }

    var chainLabel: String {
        switch self {
        case .account(let b):
            return b.wallets.map(\.chain.symbol).sorted().joined(separator: " · ")
        case .legacy(let b):
            return b.chain.rawValue
        }
    }

    var threshold: (t: UInt16, total: UInt16) {
        switch self {
        case .account(let b): return (b.threshold, b.totalParties)
        case .legacy(let b): return (b.threshold, b.totalParties)
        }
    }

    var partyIndex: UInt16 {
        switch self {
        case .account(let b): return b.partyIndex
        case .legacy(let b): return b.partyIndex
        }
    }
}

// MARK: - Import Errors

enum ShardImportError: LocalizedError {
    case unsupportedVersion(Int)
    case duplicateWallet(String)
    case invalidData
    case decryptionFailed
    case invalidPin

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let v):
            return "Unsupported backup version: \(v)"
        case .duplicateWallet(let name):
            return "Account '\(name)' already exists on this device"
        case .invalidData:
            return "Invalid backup data"
        case .decryptionFailed:
            return "Failed to decrypt shard — check your PIN"
        case .invalidPin:
            return "Incorrect PIN"
        }
    }
}
