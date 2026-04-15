import SwiftUI
import Combine
import CommonCrypto

/// Global application state — owns the core Rust bridge instances.
@MainActor
final class AppState: ObservableObject {
    /// Shared singleton for use by background tasks (e.g. BGProcessingTask).
    static let shared = AppState()
    /// Core MPC session manager (wraps Rust SessionManager via UniFFI)
    let sessionManager = HorcruxSessionManager()

    /// Shard storage manager
    let shardManager = HorcruxShardManager()

    /// Peer transport coordinator
    let peerManager = PeerManager()

    /// High-level bridge wrapping Rust FFI
    lazy var bridge: HorcruxBridge = HorcruxBridge(session: sessionManager, shards: shardManager)

    /// Persistent wallet storage
    let walletStore = WalletStore()

    /// Blockchain RPC endpoint configuration
    let networkConfig = NetworkConfig.shared

    /// On-chain query service (balance, nonce, gas, broadcast)
    let blockchainService = BlockchainService()

    /// Local transaction history
    let transactionStore = TransactionStore()

    /// MPC ceremony state for reconnection
    let ceremonyState = CeremonyStateManager()

    /// Offline signing: queue for pending broadcast
    let pendingBroadcastQueue = PendingBroadcastQueue()

    /// Polls chain for transaction confirmations
    let confirmationPoller = TransactionConfirmationPoller()

    /// Currently active signing request (if any)
    @Published var activeSigningRequest: SigningRequest?

    /// Whether the app is unlocked (PIN / biometric verified)
    @Published var isUnlocked: Bool = false

    /// Whether this is the first launch (no PIN set yet)
    var isFirstLaunch: Bool {
        (try? KeychainManager.shared.retrieve(key: KeychainKeys.pinHash)) == nil
    }

    // MARK: - PIN Management (PBKDF2 + salt)

    private static let pbkdf2Iterations: UInt32 = 100_000
    private static let saltSize = 16
    private static let hashSize = 32

    /// Derive a PIN hash using PBKDF2-HMAC-SHA256 with a random salt.
    /// Returns `salt (16 bytes) || hash (32 bytes)`.
    static func hashPin(_ pin: String, salt: Data? = nil) -> Data {
        let pinData = Data(pin.utf8)
        let actualSalt: Data
        if let salt {
            actualSalt = salt
        } else {
            var bytes = [UInt8](repeating: 0, count: saltSize)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            actualSalt = Data(bytes)
        }
        var derivedKey = Data(count: hashSize)
        derivedKey.withUnsafeMutableBytes { derivedBuf in
            pinData.withUnsafeBytes { pinBuf in
                actualSalt.withUnsafeBytes { saltBuf in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pinBuf.baseAddress?.assumingMemoryBound(to: Int8.self),
                        pinData.count,
                        saltBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        actualSalt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        pbkdf2Iterations,
                        derivedBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        hashSize
                    )
                }
            }
        }
        return actualSalt + derivedKey
    }

    /// Set (or change) the user's PIN. Stores salt||hash in Keychain.
    func setPin(_ pin: String) throws {
        let saltedHash = Self.hashPin(pin)
        try KeychainManager.shared.store(key: KeychainKeys.pinHash, data: saltedHash)
        // Reset attempt counter
        resetFailedAttempts()
    }

    /// Verify a PIN against the stored salt||hash. Returns false if locked out.
    func verifyPin(_ pin: String) -> Bool {
        if isLockedOut { return false }
        let storedData: Data?
        do {
            storedData = try KeychainManager.shared.retrieve(key: KeychainKeys.pinHash)
        } catch {
            SecureLog.error("Failed to retrieve PIN hash for verification: \(error.localizedDescription)")
            storedData = nil
        }
        guard let stored = storedData,
              stored.count == Self.saltSize + Self.hashSize else {
            return false
        }
        let salt = stored.prefix(Self.saltSize)
        let recomputed = Self.hashPin(pin, salt: Data(salt))
        if recomputed == stored {
            resetFailedAttempts()
            return true
        } else {
            recordFailedAttempt()
            return false
        }
    }

    /// Derive encryption key material from PIN using PBKDF2.
    /// Uses the stored salt from the PIN hash to ensure consistent derivation.
    /// Returns 32 bytes of key material suitable for shard encryption.
    static func pinKeyMaterial(_ pin: String) throws -> Data {
        // Retrieve stored salt from Keychain PIN hash (first 16 bytes)
        guard let stored = try? KeychainManager.shared.retrieve(key: KeychainKeys.pinHash),
              stored.count >= saltSize else {
            throw AppError.keychainUnavailable("PIN salt not found — cannot derive key material")
        }
        let salt = Data(stored.prefix(saltSize))
        let pinData = Data(pin.utf8)
        var derivedKey = Data(count: 32)
        derivedKey.withUnsafeMutableBytes { derivedBuf in
            pinData.withUnsafeBytes { pinBuf in
                salt.withUnsafeBytes { saltBuf in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pinBuf.baseAddress?.assumingMemoryBound(to: Int8.self),
                        pinData.count,
                        saltBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        pbkdf2Iterations,
                        derivedBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        32
                    )
                }
            }
        }
        return derivedKey
    }

    // MARK: - Brute-Force Protection

    /// Maximum failed PIN attempts before wipe.
    static let maxFailedAttempts = 10

    @Published private(set) var failedAttempts: Int = 0
    @Published private(set) var lockoutUntil: Date?

    /// Whether the app is currently locked out due to too many failed attempts.
    var isLockedOut: Bool {
        if let until = lockoutUntil, Date.now < until { return true }
        return false
    }

    /// Seconds remaining in the current lockout, or 0.
    var lockoutRemaining: TimeInterval {
        guard let until = lockoutUntil else { return 0 }
        return max(0, until.timeIntervalSinceNow)
    }

    private func recordFailedAttempt() {
        failedAttempts += 1
        persistFailedAttempts()

        if failedAttempts >= Self.maxFailedAttempts {
            wipeAllData()
            return
        }

        // Exponential backoff: 0, 0, 0, 5s, 15s, 30s, 60s, 120s, 300s, wipe
        let delays: [TimeInterval] = [0, 0, 0, 5, 15, 30, 60, 120, 300]
        let idx = min(failedAttempts - 1, delays.count - 1)
        let delay = delays[idx]
        if delay > 0 {
            lockoutUntil = Date.now.addingTimeInterval(delay)
        }
    }

    private func resetFailedAttempts() {
        failedAttempts = 0
        lockoutUntil = nil
        persistFailedAttempts()
    }

    private func persistFailedAttempts() {
        let data = Data("\(failedAttempts)".utf8)
        do {
            try KeychainManager.shared.store(key: KeychainKeys.failedAttempts, data: data)
        } catch {
            SecureLog.error("Failed to persist attempt count: \(error.localizedDescription)")
        }
    }

    func loadFailedAttempts() {
        let attemptData: Data?
        do {
            attemptData = try KeychainManager.shared.retrieve(key: KeychainKeys.failedAttempts)
        } catch {
            SecureLog.error("Failed to load failed attempt count: \(error.localizedDescription)")
            attemptData = nil
        }
        if let data = attemptData,
           let str = String(data: data, encoding: .utf8),
           let count = Int(str) {
            failedAttempts = count
        }
    }

    // MARK: - Device Key (Secure Enclave envelope)

    /// A stable device key stored in Keychain, sealed by Secure Enclave when available.
    /// On SE-capable devices the raw key is encrypted under an SE P-256 key,
    /// so extracting it requires biometric authentication at the hardware level.
    ///
    /// - Warning: Callers **must** zero the returned key after use:
    ///   `defer { var k = key; k.resetBytes(in: 0..<k.count) }`
    var deviceKey: Data {
        get throws {
            // Try SE-sealed path first
            if SecureEnclaveManager.shared.isAvailable {
                return try deviceKeyViaSE()
            }
            // Fallback: software-only Keychain storage
            return try deviceKeySoftware()
        }
    }

    /// Device key path using Secure Enclave envelope encryption.
    private func deviceKeyViaSE() throws -> Data {
        // Check for existing SE-sealed blob
        if let sealedBlob = try? KeychainManager.shared.retrieve(key: KeychainKeys.deviceKeySE) {
            // Unseal via SE (triggers biometric)
            return try SecureEnclaveManager.shared.open(sealedBlob)
        }

        // Migrate from legacy unprotected key if it exists
        if var legacyKey = try? KeychainManager.shared.retrieve(key: KeychainKeys.deviceKey) {
            let sealed = try SecureEnclaveManager.shared.seal(legacyKey)
            try KeychainManager.shared.storeSecure(key: KeychainKeys.deviceKeySE, data: sealed)
            // Remove legacy key from Keychain immediately
            try? KeychainManager.shared.delete(key: KeychainKeys.deviceKey)
            // Zero out the in-memory copy
            legacyKey.resetBytes(in: 0..<legacyKey.count)
            // Return freshly unsealed copy (triggers biometric)
            return try SecureEnclaveManager.shared.open(sealed)
        }

        // Fresh install: generate, seal, store
        var bytes = [UInt8](repeating: 0, count: 32)
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw KeychainError.storeFailed(status)
        }
        let key = Data(bytes)
        let sealed = try SecureEnclaveManager.shared.seal(key)
        try KeychainManager.shared.storeSecure(key: KeychainKeys.deviceKeySE, data: sealed)
        return key
    }

    /// Fallback device key for devices without Secure Enclave (e.g. simulator).
    private func deviceKeySoftware() throws -> Data {
        if let existing = try? KeychainManager.shared.retrieve(key: KeychainKeys.deviceKey) {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw KeychainError.storeFailed(status)
        }
        let key = Data(bytes)
        try KeychainManager.shared.storeSecure(key: KeychainKeys.deviceKey, data: key)
        return key
    }

    // MARK: - Auto-Lock

    /// Auto-lock timeout in seconds (0 = disabled). Default 5 minutes.
    @AppStorage("autoLockTimeout") var autoLockTimeout: TimeInterval = 300

    private var lastActiveTime: Date = .now

    /// Called when app enters background — clear sensitive in-memory data and track time.
    func onEnterBackground() {
        lastActiveTime = .now
    }

    /// Called when app returns to foreground — check if auto-lock should trigger.
    func checkAutoLock() {
        guard autoLockTimeout > 0, isUnlocked else { return }
        let elapsed = Date.now.timeIntervalSince(lastActiveTime)
        if elapsed >= autoLockTimeout {
            isUnlocked = false
        }
    }

    // MARK: - Wipe

    func wipeAllData() {
        walletStore.wipeAll()
        transactionStore.wipeAll()
        pendingBroadcastQueue.wipeAll()
        try? KeychainManager.shared.delete(key: KeychainKeys.pinHash)
        try? KeychainManager.shared.delete(key: KeychainKeys.deviceKey)
        try? KeychainManager.shared.delete(key: KeychainKeys.deviceKeySE)
        try? KeychainManager.shared.delete(key: KeychainKeys.failedAttempts)
        try? KeychainManager.shared.delete(key: KeychainKeys.noiseKeypair)
        try? KeychainManager.shared.delete(key: "noise_static_keypair_se")
        SecureEnclaveManager.shared.deleteKey()
        failedAttempts = 0
        lockoutUntil = nil
        isUnlocked = false
    }
}

// MARK: - App Errors

enum AppError: LocalizedError {
    case keychainUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .keychainUnavailable(let message): return message
        }
    }
}

// MARK: - Keychain Key Constants

enum KeychainKeys {
    static let pinHash = "com.horcrux.pin_hash"
    static let deviceKey = "com.horcrux.device_key"
    static let deviceKeySE = "com.horcrux.device_key_se"
    static let failedAttempts = "com.horcrux.failed_attempts"
    static let noiseKeypair = "com.horcrux.noise_keypair"
}

// MARK: - Domain Models

struct Wallet: Identifiable, Codable {
    let id: String
    let name: String
    let chain: Chain
    let address: String
    let groupPublicKey: Data
    let threshold: UInt16
    let totalParties: UInt16
    let partyIndex: UInt16
    let createdAt: Date
}

enum Chain: String, Codable, CaseIterable, Identifiable {
    case ethereum = "Ethereum"
    case bitcoin = "Bitcoin"
    case solana = "Solana"

    var id: String { rawValue }

    var curveType: FfiCurveType {
        switch self {
        case .ethereum, .bitcoin: return .secp256k1
        case .solana: return .ed25519
        }
    }

    var symbol: String {
        switch self {
        case .ethereum: return "ETH"
        case .bitcoin: return "BTC"
        case .solana: return "SOL"
        }
    }

    var iconName: String {
        switch self {
        case .ethereum: return "e.circle.fill"
        case .bitcoin: return "bitcoinsign.circle.fill"
        case .solana: return "s.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .ethereum: return .blue
        case .bitcoin: return .orange
        case .solana: return .purple
        }
    }
}

struct SigningRequest: Identifiable {
    let id: String
    let wallet: Wallet
    let message: Data
    let displayMessage: String
    let requiredSigners: UInt16
    var collectedSigners: UInt16 = 0
}
