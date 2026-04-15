import SwiftUI
import Combine
import CommonCrypto

/// Global application state — owns the core Rust bridge instances.
@MainActor
final class AppState: ObservableObject {
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
        guard let stored = try? KeychainManager.shared.retrieve(key: KeychainKeys.pinHash),
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

    /// The raw PIN bytes for shard encryption — caller must supply the verified PIN.
    static func pinKeyMaterial(_ pin: String) -> Data {
        Data(pin.utf8)
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
        try? KeychainManager.shared.store(key: KeychainKeys.failedAttempts, data: data)
    }

    func loadFailedAttempts() {
        if let data = try? KeychainManager.shared.retrieve(key: KeychainKeys.failedAttempts),
           let str = String(data: data, encoding: .utf8),
           let count = Int(str) {
            failedAttempts = count
        }
    }

    // MARK: - Device Key

    /// A stable device key stored in Keychain. Used alongside PIN for shard encryption.
    var deviceKey: Data {
        get throws {
            if let existing = try? KeychainManager.shared.retrieve(key: KeychainKeys.deviceKey) {
                return existing
            }
            var bytes = [UInt8](repeating: 0, count: 32)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            guard status == errSecSuccess else {
                throw KeychainError.storeFailed(status)
            }
            let key = Data(bytes)
            try KeychainManager.shared.store(key: KeychainKeys.deviceKey, data: key)
            return key
        }
    }

    // MARK: - Wipe

    func wipeAllData() {
        walletStore.wipeAll()
        try? KeychainManager.shared.delete(key: KeychainKeys.pinHash)
        try? KeychainManager.shared.delete(key: KeychainKeys.deviceKey)
        try? KeychainManager.shared.delete(key: KeychainKeys.failedAttempts)
        try? KeychainManager.shared.delete(key: KeychainKeys.noiseKeypair)
        failedAttempts = 0
        lockoutUntil = nil
        isUnlocked = false
    }
}

// MARK: - Keychain Key Constants

enum KeychainKeys {
    static let pinHash = "com.horcrux.pin_hash"
    static let deviceKey = "com.horcrux.device_key"
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
