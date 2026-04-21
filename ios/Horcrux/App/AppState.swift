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

    /// Bridges child ObservableObject changes (walletStore) to our own
    /// objectWillChange so views using `@EnvironmentObject appState` refresh
    /// when wallets are added/removed.
    private var childCancellables = Set<AnyCancellable>()

    /// Blockchain RPC endpoint configuration
    let networkConfig = NetworkConfig.shared

    /// On-chain query service (balance, nonce, gas, broadcast)
    let blockchainService = BlockchainService()

    /// Local transaction history
    let transactionStore = TransactionStore()

    /// User-added ERC-20 / SPL tokens beyond the built-in catalog.
    let customTokenStore = CustomTokenStore()

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

    /// Shard Wrap Key cached in RAM for the duration of this unlocked
    /// session. The SWK is a random 32-byte key that directly encrypts
    /// every shard's ciphertext; it is unwrapped at unlock time via either
    /// PIN (PBKDF2-derived wrap key) or biometric (Secure Enclave seal).
    ///
    /// Callers that need to encrypt/decrypt shards should read this value
    /// via `cachedShardKey()`. If it is `nil` (locked / backgrounded), the
    /// UI must prompt PIN or biometric to unwrap the SWK via `SecureKeyVault`.
    ///
    /// Zeroed on app backgrounding and auto-lock.
    private var cachedShardKeyMaterial: Data?

    init() {
        // Migration: older builds allowed Auto-Lock = Never (-1). Remove that
        // option for security — existing users on -1 get bumped to 1 hour.
        if UserDefaults.standard.double(forKey: "autoLockTimeout") < 0 {
            UserDefaults.standard.set(3600.0, forKey: "autoLockTimeout")
        }

        // Propagate walletStore changes through our own objectWillChange so
        // every @EnvironmentObject appState consumer re-renders when wallets
        // are added, removed, or renamed. Without this, WalletHomeView would
        // show a stale empty list after a fresh DKG save.
        walletStore.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &childCancellables)

        // Same bridge for the pending-broadcast queue so WalletHomeView's
        // "Pending broadcasts" section refreshes when rows are dequeued
        // (user taps 丢弃 / Discard or a broadcast retry succeeds). Without
        // this the underlying @Published updates fire on the child but never
        // reach @EnvironmentObject appState consumers — the discard button
        // appears unresponsive even though the item is already removed.
        pendingBroadcastQueue.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &childCancellables)

        // Same bridge for the transaction store so any view that reads
        // `appState.transactionStore.records(for:)` (WalletHomeView history
        // preview, TransactionHistoryView) re-renders when records are
        // added/updated/removed. Without this a newly-broadcast tx or a
        // status flip (signed → broadcast → confirmed) only reaches views
        // that explicitly hold `@ObservedObject transactionStore`.
        transactionStore.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &childCancellables)

        // Same bridge for the custom-token store so views reading
        // `appState.customTokenStore.tokens` / `.effectiveTokens(for:)`
        // refresh when the user adds or removes a custom ERC-20 / SPL
        // token from Settings.
        customTokenStore.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &childCancellables)
    }

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

    /// Set the user's PIN during onboarding. Generates a fresh Shard Wrap
    /// Key and persists both the PIN-wrapped and (if available) SE-sealed
    /// copies. To change an existing PIN use `changePin` — that path only
    /// re-wraps the SWK and leaves shard ciphertexts untouched.
    func setPin(_ pin: String) throws {
        let saltedHash = Self.hashPin(pin)
        try KeychainManager.shared.store(key: KeychainKeys.pinHash, data: saltedHash)
        resetFailedAttempts()

        // Provision SWK on first PIN set. If one already exists (user wiped
        // PIN hash but not vault?), unwrap + re-wrap with the new PIN.
        if SecureKeyVault.hasPinWrapped {
            // Unexpected but tolerate: we can't unwrap without the old PIN,
            // so the only safe thing is to overwrite with a fresh SWK. Any
            // existing shards will become undecryptable — caller should
            // only hit this branch during a recovery flow.
            SecureKeyVault.wipe()
        }
        cachedShardKeyMaterial = try SecureKeyVault.provision(pin: pin)
    }

    /// Verify a PIN against the stored salt||hash. Returns false if locked out.
    /// On success, unwraps the Shard Wrap Key and caches it for the session.
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
        guard recomputed == stored else {
            recordFailedAttempt()
            return false
        }
        resetFailedAttempts()

        // Unwrap the SWK. The vault is always provisioned by setPin,
        // so a missing vault indicates a device onboarded before the SWK
        // feature shipped. Since that user has no shards yet (shards can
        // only be created after PIN is set and an SWK exists), provision
        // one now using this PIN and continue as normal. This keeps the
        // lock screen from turning into a dead end.
        guard SecureKeyVault.hasPinWrapped else {
            SecureLog.info("SWK vault missing — provisioning fresh vault with verified PIN")
            cachedShardKeyMaterial = try? SecureKeyVault.provision(pin: pin)
            return true
        }
        cachedShardKeyMaterial = try? SecureKeyVault.unwrapWithPin(pin)
        if let swk = cachedShardKeyMaterial {
            SecureKeyVault.ensureSealed(swk: swk)
        }
        return true
    }

    /// Unwrap the SWK via biometric (Face ID / Touch ID) and cache it.
    /// Returns true if successful. Safe to call from the lock screen after
    /// `BiometricAuth.authenticate()` has already surfaced a prompt.
    func unlockShardKeyWithBiometric() async -> Bool {
        guard SecureKeyVault.hasSESealed else { return false }
        do {
            let swk = try await Task.detached {
                try SecureKeyVault.unwrapWithBiometric()
            }.value
            await MainActor.run { self.cachedShardKeyMaterial = swk }
            return true
        } catch {
            SecureLog.error("Biometric SWK unwrap failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Returns the cached SWK, or nil when the app is locked / backgrounded.
    /// Callers that receive nil must prompt the user to re-authenticate.
    func cachedShardKey() -> Data? {
        cachedShardKeyMaterial
    }

    /// Forget the cached SWK. Called on app backgrounding and logout.
    func clearCachedShardKey() {
        if var k = cachedShardKeyMaterial {
            k.resetBytes(in: 0..<k.count)
        }
        cachedShardKeyMaterial = nil
    }

    /// Change the user's PIN. With SWK-based shard encryption this only
    /// re-wraps the Shard Wrap Key under the new PIN; the SWK itself does
    /// not change, so existing shards remain decryptable immediately and
    /// no bulk re-encryption is required.
    func changePin(
        current currentPin: String,
        new newPin: String,
        walletStore: WalletStore
    ) throws {
        _ = walletStore // retained for source compat
        guard verifyPin(currentPin) else {
            throw AppError.invalidPin
        }
        // `verifyPin` will have populated the cache (either directly or via
        // the migration path). Fall back to an explicit unwrap if needed.
        let swk: Data
        if let cached = cachedShardKeyMaterial {
            swk = cached
        } else if SecureKeyVault.hasPinWrapped {
            swk = try SecureKeyVault.unwrapWithPin(currentPin)
        } else {
            throw AppError.keychainUnavailable("Shard Wrap Key not provisioned")
        }

        // Write the new PIN hash (new salt).
        let newPinHash = Self.hashPin(newPin)
        try KeychainManager.shared.store(key: KeychainKeys.pinHash, data: newPinHash)
        resetFailedAttempts()

        // Re-wrap SWK under the new PIN. SE-sealed copy is left alone.
        try SecureKeyVault.rewrapPinWrapped(swk: swk, newPin: newPin)

        cachedShardKeyMaterial = swk
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
            // Try SE-sealed path first. On simulators / devices without a
            // passcode, SE key creation fails (`errSecAuthFailed`) because
            // the ACL requires `WhenPasscodeSet`. Fall back to software in
            // that case rather than blocking all shard writes.
            if SecureEnclaveManager.shared.isAvailable {
                do {
                    return try deviceKeyViaSE()
                } catch {
                    SecureLog.warning("SE device-key path failed, falling back to software: \(error.localizedDescription)")
                }
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

    /// Called when app enters background — track time, but keep the SWK
    /// in memory for brief suspensions (switch to Messages to paste a room
    /// code, etc.). SWK is only cleared when auto-lock actually triggers on
    /// foreground, keeping the save-shard flow interaction-free for users
    /// who momentarily leave the app mid-ceremony.
    func onEnterBackground() {
        lastActiveTime = .now
        NotificationCenter.default.post(name: .appDidEnterBackground, object: nil)
    }

    /// Called when app returns to foreground — check if auto-lock should trigger.
    func checkAutoLock() {
        guard autoLockTimeout > 0, isUnlocked else { return }
        let elapsed = Date.now.timeIntervalSince(lastActiveTime)
        if elapsed >= autoLockTimeout {
            isUnlocked = false
            clearCachedShardKey()
        }
    }

    // MARK: - Wipe

    func wipeAllData() {
        walletStore.wipeAll()
        transactionStore.wipeAll()
        pendingBroadcastQueue.wipeAll()
        SecureKeyVault.wipe()
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

// MARK: - Notifications

extension Notification.Name {
    static let appDidEnterBackground = Notification.Name("appDidEnterBackground")
}

// MARK: - App Errors

enum AppError: LocalizedError {
    case keychainUnavailable(String)
    case invalidPin

    var errorDescription: String? {
        switch self {
        case .keychainUnavailable(let message): return message
        case .invalidPin: return "Invalid PIN"
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
    /// Optional so legacy wallets (pre-0.3.0-dev.13) decode with nil == not hidden.
    let isHidden: Bool?

    var hidden: Bool { isHidden ?? false }

    /// Canonical ID for the MPC account (= DKG ceremony). All wallets that
    /// share the same `groupPublicKey` belong to one account and share the
    /// same encrypted key share in the Keychain. Fallback to `id` for any
    /// wallet that somehow lacks a group public key.
    var accountId: String {
        guard !groupPublicKey.isEmpty else { return id }
        return groupPublicKey.map { String(format: "%02x", $0) }.joined()
    }
}

enum Chain: String, Codable, CaseIterable, Identifiable {
    case ethereum = "Ethereum"
    case bnb = "BNB Smart Chain"
    case polygon = "Polygon"
    case arbitrum = "Arbitrum One"
    case base = "Base"
    case avalanche = "Avalanche"
    case optimism = "Optimism"
    case zksync = "zkSync Era"
    case linea = "Linea"
    case scroll = "Scroll"
    case bitcoin = "Bitcoin"
    case litecoin = "Litecoin"
    case solana = "Solana"
    case tron = "Tron"

    var id: String { rawValue }

    /// User-facing name used in row labels. Short enough to fit on a
    /// single line next to a 44pt icon plus a balance column; differs
    /// from `rawValue` (which is the Codable persistence key) so
    /// renaming for UX does not invalidate stored wallets/backups.
    var displayName: String {
        switch self {
        case .bnb: return "BNB Chain"
        case .arbitrum: return "Arbitrum"
        default: return rawValue
        }
    }

    /// Unique 3–4 char chain code used in compact chip lists where
    /// `symbol` would collide across EVM L2s (all return "ETH"). Stable
    /// enough to show on a card without localising.
    var shortCode: String {
        switch self {
        case .ethereum: return "ETH"
        case .bnb: return "BNB"
        case .polygon: return "POL"
        case .arbitrum: return "ARB"
        case .base: return "BASE"
        case .avalanche: return "AVAX"
        case .optimism: return "OP"
        case .zksync: return "ZKS"
        case .linea: return "LNA"
        case .scroll: return "SCR"
        case .bitcoin: return "BTC"
        case .litecoin: return "LTC"
        case .solana: return "SOL"
        case .tron: return "TRX"
        }
    }

    /// All EVM-family chains share the same secp256k1 derivation and EIP-55
    /// address format; only chainId, RPC endpoint and explorer differ.
    var isEVM: Bool {
        switch self {
        case .ethereum, .bnb, .polygon, .arbitrum, .base,
             .avalanche, .optimism, .zksync, .linea, .scroll: return true
        case .bitcoin, .litecoin, .solana, .tron: return false
        }
    }

    /// Default EVMNetwork mapping for non-Ethereum EVM chains. Returns the
    /// canonical mainnet network — Ethereum itself defers to NetworkConfig
    /// so users can pick mainnet vs Sepolia vs a custom chainId.
    var defaultEVMNetwork: EVMNetwork? {
        switch self {
        case .ethereum: return .mainnet
        case .bnb: return .bnb
        case .polygon: return .polygon
        case .arbitrum: return .arbitrumOne
        case .base: return .base
        case .avalanche: return .avalanche
        case .optimism: return .optimism
        case .zksync: return .zkSyncEra
        case .linea: return .linea
        case .scroll: return .scroll
        default: return nil
        }
    }

    var curveType: FfiCurveType {
        if isEVM { return .secp256k1 }
        switch self {
        case .bitcoin, .litecoin, .tron: return .secp256k1
        case .solana: return .ed25519
        default: return .secp256k1
        }
    }

    var symbol: String {
        switch self {
        case .ethereum, .arbitrum, .base, .optimism, .zksync, .linea, .scroll: return "ETH"
        case .bnb: return "BNB"
        case .polygon: return "POL"
        case .avalanche: return "AVAX"
        case .bitcoin: return "BTC"
        case .litecoin: return "LTC"
        case .solana: return "SOL"
        case .tron: return "TRX"
        }
    }

    var iconName: String {
        switch self {
        case .ethereum: return "e.circle.fill"
        case .bnb: return "b.circle.fill"
        case .polygon: return "hexagon.fill"
        case .arbitrum: return "a.square.fill"
        case .base: return "b.square.fill"
        case .avalanche: return "a.circle.fill"
        case .optimism: return "o.circle.fill"
        case .zksync: return "z.circle.fill"
        case .linea: return "l.square.fill"
        case .scroll: return "s.square.fill"
        case .bitcoin: return "bitcoinsign.circle.fill"
        case .litecoin: return "l.circle.fill"
        case .solana: return "s.circle.fill"
        case .tron: return "t.circle.fill"
        }
    }

    /// Asset catalog name for the chain's brand logo (PNG bundled in
    /// `Assets.xcassets/ChainIcons`). Falls back to `iconName` (SF Symbol)
    /// if the asset is missing at runtime.
    var assetName: String {
        switch self {
        case .ethereum: return "ChainIcons/ethereum"
        case .bnb: return "ChainIcons/bnb"
        case .polygon: return "ChainIcons/polygon"
        case .arbitrum: return "ChainIcons/arbitrum"
        case .base: return "ChainIcons/base"
        case .avalanche: return "ChainIcons/avalanche"
        case .optimism: return "ChainIcons/optimism"
        case .zksync: return "ChainIcons/zksync"
        case .linea: return "ChainIcons/linea"
        case .scroll: return "ChainIcons/scroll"
        case .bitcoin: return "ChainIcons/bitcoin"
        case .litecoin: return "ChainIcons/litecoin"
        case .solana: return "ChainIcons/solana"
        case .tron: return "ChainIcons/tron"
        }
    }

    /// Brand-accurate accent color for each chain, used for row tints,
    /// icon backgrounds and accent stripes. Values taken from each chain's
    /// primary logo hex to keep visual identity consistent across the app.
    var color: Color {
        switch self {
        case .ethereum:  return Color(red: 0.384, green: 0.494, blue: 0.918) // #627EEA
        case .bnb:       return Color(red: 0.941, green: 0.725, blue: 0.043) // #F0B90B
        case .polygon:   return Color(red: 0.510, green: 0.278, blue: 0.898) // #8247E5
        case .arbitrum:  return Color(red: 0.157, green: 0.627, blue: 0.941) // #28A0F0
        case .base:      return Color(red: 0.000, green: 0.322, blue: 1.000) // #0052FF
        case .avalanche: return Color(red: 0.910, green: 0.255, blue: 0.259) // #E84142
        case .optimism:  return Color(red: 1.000, green: 0.016, blue: 0.125) // #FF0420
        case .zksync:    return Color(red: 0.549, green: 0.553, blue: 0.988) // #8C8DFC
        case .linea:     return Color(red: 0.380, green: 0.875, blue: 0.776) // #61DFC6
        case .scroll:    return Color(red: 1.000, green: 0.929, blue: 0.741) // #FFEDBD
        case .bitcoin:   return Color(red: 0.969, green: 0.576, blue: 0.102) // #F7931A
        case .litecoin:  return Color(red: 0.651, green: 0.663, blue: 0.667) // #A6A9AA
        case .solana:    return Color(red: 0.600, green: 0.271, blue: 1.000) // #9945FF
        case .tron:      return Color(red: 0.937, green: 0.000, blue: 0.153) // #EF0027
        }
    }

    /// True when the current release can produce broadcastable signatures for this chain.
    /// Litecoin/Tron currently ship as read-only (address + balance); signing is a later milestone.
    /// All EVM-family chains share Ethereum's signing path.
    var signingSupported: Bool {
        if isEVM { return true }
        switch self {
        case .bitcoin, .solana: return true
        case .litecoin: return true
        case .tron: return true
        default: return false
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
