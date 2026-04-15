import SwiftUI
import Combine

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

    /// Currently active signing request (if any)
    @Published var activeSigningRequest: SigningRequest?

    /// Whether the app is unlocked (PIN / biometric verified)
    @Published var isUnlocked: Bool = false

    /// Whether this is the first launch (no PIN set yet)
    var isFirstLaunch: Bool {
        (try? KeychainManager.shared.retrieve(key: KeychainKeys.pinHash)) == nil
    }

    // MARK: - PIN Management

    /// Hash a PIN for storage (SHA-256 of UTF-8 bytes).
    static func hashPin(_ pin: String) -> Data {
        horcruxKeccak256(data: Data(pin.utf8))
    }

    /// Set (or change) the user's PIN.
    func setPin(_ pin: String) throws {
        let hash = Self.hashPin(pin)
        try KeychainManager.shared.store(key: KeychainKeys.pinHash, data: hash)
    }

    /// Verify a PIN against the stored hash.
    func verifyPin(_ pin: String) -> Bool {
        guard let stored = try? KeychainManager.shared.retrieve(key: KeychainKeys.pinHash) else {
            return false
        }
        return stored == Self.hashPin(pin)
    }

    /// A stable device key derived from a random seed stored in Keychain.
    /// Used alongside the PIN for shard encryption.
    var deviceKey: Data {
        if let existing = try? KeychainManager.shared.retrieve(key: KeychainKeys.deviceKey) {
            return existing
        }
        // Generate and persist a 32-byte device key on first access
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let key = Data(bytes)
        try? KeychainManager.shared.store(key: KeychainKeys.deviceKey, data: key)
        return key
    }

    // MARK: - Wipe

    func wipeAllData() {
        walletStore.wipeAll()
        try? KeychainManager.shared.delete(key: KeychainKeys.pinHash)
        try? KeychainManager.shared.delete(key: KeychainKeys.deviceKey)
        isUnlocked = false
    }
}

// MARK: - Keychain Key Constants

enum KeychainKeys {
    static let pinHash = "com.horcrux.pin_hash"
    static let deviceKey = "com.horcrux.device_key"
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
