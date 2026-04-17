import Foundation
import Combine

/// Per-chain RPC endpoint configuration with sensible public defaults.
///
/// The module owns three sources of truth per chain:
///   1. A **network selector** (`evmChainId`, `btcTestnet`, `solDevnet`)
///   2. An optional **user-supplied RPC URL**
///   3. A built-in **default RPC** per (chain, network) derived from the selector
///
/// When the user switches networks (e.g. picks Polygon, toggles BTC testnet),
/// the URL field auto-swaps to the new default *iff* the current URL is one of
/// the recognized built-in defaults. If the user has typed a custom URL, it is
/// preserved — but in that case the UI should prompt them to update it.
///
/// Any mutation also fires `BalanceCache.shared.invalidateAll()` so cached
/// balances from the previous network never leak across a switch.
final class NetworkConfig: ObservableObject, @unchecked Sendable {
    static let shared = NetworkConfig()

    @Published var ethereumRPC: String {
        didSet {
            save(ethereumRPC, forKey: Keys.ethereumRPC)
            invalidateBalances()
        }
    }
    @Published var bitcoinAPI: String {
        didSet {
            save(bitcoinAPI, forKey: Keys.bitcoinAPI)
            invalidateBalances()
        }
    }
    @Published var solanaRPC: String {
        didSet {
            save(solanaRPC, forKey: Keys.solanaRPC)
            invalidateBalances()
        }
    }
    @Published var evmChainId: UInt64 {
        didSet {
            UserDefaults.standard.set(evmChainId, forKey: Keys.evmChainId)
            autoSwapEthereumRPCIfDefault(previousChainId: oldValue)
            invalidateBalances()
        }
    }
    @Published var btcTestnet: Bool {
        didSet {
            UserDefaults.standard.set(btcTestnet, forKey: Keys.btcTestnet)
            autoSwapBitcoinAPIIfDefault(previousTestnet: oldValue)
            invalidateBalances()
        }
    }
    @Published var solDevnet: Bool {
        didSet {
            UserDefaults.standard.set(solDevnet, forKey: Keys.solDevnet)
            autoSwapSolanaRPCIfDefault(previousDevnet: oldValue)
            invalidateBalances()
        }
    }

    /// Alchemy API key for EVM. Stored in Keychain (never UserDefaults).
    /// When `ethereumRPC` contains the `{KEY}` placeholder, this value is
    /// substituted in at RPC-call time.
    @Published var alchemyAPIKey: String {
        didSet {
            saveKeychain(alchemyAPIKey, forKey: Keys.alchemyKey)
            invalidateBalances()
        }
    }

    /// Helius API key for Solana. Same substitution pattern as `alchemyAPIKey`.
    @Published var heliusAPIKey: String {
        didSet {
            saveKeychain(heliusAPIKey, forKey: Keys.heliusKey)
            invalidateBalances()
        }
    }

    private init() {
        let ud = UserDefaults.standard
        self.ethereumRPC = ud.string(forKey: Keys.ethereumRPC) ?? Defaults.ethereumRPC
        self.bitcoinAPI = ud.string(forKey: Keys.bitcoinAPI) ?? Defaults.bitcoinAPI
        self.solanaRPC = ud.string(forKey: Keys.solanaRPC) ?? Defaults.solanaRPC
        let storedChainId = ud.integer(forKey: Keys.evmChainId)
        if storedChainId == 0 && ud.object(forKey: Keys.evmChainId) != nil {
            NSLog("[NetworkConfig] Stored EVM chainId was 0 (invalid) — falling back to mainnet (1)")
        }
        self.evmChainId = UInt64(storedChainId == 0 ? 1 : storedChainId)
        self.btcTestnet = ud.bool(forKey: Keys.btcTestnet)
        self.solDevnet = ud.bool(forKey: Keys.solDevnet)
        self.alchemyAPIKey = Self.loadKeychainString(key: Keys.alchemyKey)
        self.heliusAPIKey = Self.loadKeychainString(key: Keys.heliusKey)
    }

    func rpcURL(for chain: Chain) -> String {
        let raw: String
        switch chain {
        case .ethereum: raw = ethereumRPC
        case .bitcoin: raw = bitcoinAPI
        case .solana: raw = solanaRPC
        }
        return substituteAPIKey(in: raw, chain: chain)
    }

    /// Replace `{KEY}` placeholder in a URL template with the per-chain
    /// Keychain-stored API key. Returns the raw URL unchanged if no
    /// placeholder is present or the relevant key is empty.
    func substituteAPIKey(in url: String, chain: Chain) -> String {
        guard url.contains("{KEY}") else { return url }
        let key: String
        switch chain {
        case .ethereum: key = alchemyAPIKey
        case .solana: key = heliusAPIKey
        case .bitcoin: key = ""  // no provider template for BTC
        }
        guard !key.isEmpty else { return url }
        return url.replacingOccurrences(of: "{KEY}", with: key)
    }

    func resetToDefaults() {
        applyPreset(.mainnet)
    }

    /// Apply a named network preset (mainnet or testnet).
    func applyPreset(_ preset: NetworkPreset) {
        ethereumRPC = preset.ethereumRPC
        bitcoinAPI = preset.bitcoinAPI
        solanaRPC = preset.solanaRPC
        evmChainId = preset.evmChainId
        btcTestnet = preset.btcTestnet
        solDevnet = preset.solDevnet
    }

    private func save(_ value: String, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    // Persist API keys to Keychain rather than UserDefaults. Empty string
    // means "no key set" — we delete the item instead of storing an empty
    // blob, so the Keychain never holds placeholder rows.
    private func saveKeychain(_ value: String, forKey key: String) {
        do {
            if value.isEmpty {
                try KeychainManager.shared.delete(key: key)
            } else if let data = value.data(using: .utf8) {
                try KeychainManager.shared.store(key: key, data: data)
            }
        } catch {
            NSLog("[NetworkConfig] Keychain write failed for \(key): \(error)")
        }
    }

    private static func loadKeychainString(key: String) -> String {
        do {
            guard let data = try KeychainManager.shared.retrieve(key: key) else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            NSLog("[NetworkConfig] Keychain read failed for \(key): \(error)")
            return ""
        }
    }

    private func invalidateBalances() {
        Task { @MainActor in
            BalanceCache.shared.invalidateAll()
        }
    }

    // MARK: - Auto-swap helpers

    /// Swap `ethereumRPC` to the new chain's default when the previous value was
    /// a recognized default (public or Alchemy template) for *any* known chain.
    /// User-customized URLs are preserved untouched.
    private func autoSwapEthereumRPCIfDefault(previousChainId: UInt64) {
        guard previousChainId != evmChainId else { return }
        let publicDefaults = Set(EVMNetwork.allCases.map(\.defaultRPC))
        let alchemyTemplates = Set(EVMNetwork.allCases.compactMap { RPCProviderTemplate.alchemy(evm: $0) })

        guard let newNet = EVMNetwork(rawValue: evmChainId) else { return }

        if publicDefaults.contains(ethereumRPC) {
            ethereumRPC = newNet.defaultRPC
        } else if alchemyTemplates.contains(ethereumRPC),
                  let newTmpl = RPCProviderTemplate.alchemy(evm: newNet) {
            ethereumRPC = newTmpl
        }
    }

    private func autoSwapBitcoinAPIIfDefault(previousTestnet: Bool) {
        guard previousTestnet != btcTestnet else { return }
        let known: Set<String> = [BitcoinNetwork.mainnet.defaultAPI, BitcoinNetwork.testnet.defaultAPI]
        guard known.contains(bitcoinAPI) else { return }
        bitcoinAPI = (btcTestnet ? BitcoinNetwork.testnet : BitcoinNetwork.mainnet).defaultAPI
    }

    private func autoSwapSolanaRPCIfDefault(previousDevnet: Bool) {
        guard previousDevnet != solDevnet else { return }
        let known: Set<String> = [SolanaNetwork.mainnet.defaultRPC, SolanaNetwork.devnet.defaultRPC]
        guard known.contains(solanaRPC) else { return }
        solanaRPC = (solDevnet ? SolanaNetwork.devnet : SolanaNetwork.mainnet).defaultRPC
    }

    // MARK: - URL validation

    struct URLValidation {
        let ok: Bool
        let warning: String?   // non-nil when we want to surface caution
    }

    /// Validate a user-entered RPC URL. Returns a warning for http://, empty,
    /// or malformed values. An empty string is flagged as invalid.
    static func validate(url: String) -> URLValidation {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return URLValidation(ok: false, warning: "URL is empty")
        }
        guard let parsed = URL(string: trimmed), let scheme = parsed.scheme?.lowercased() else {
            return URLValidation(ok: false, warning: "Not a valid URL")
        }
        switch scheme {
        case "https", "wss":
            return URLValidation(ok: true, warning: nil)
        case "http", "ws":
            return URLValidation(ok: true, warning: "Insecure scheme — traffic can be tampered with")
        default:
            return URLValidation(ok: false, warning: "Unsupported scheme (\(scheme))")
        }
    }
}

// MARK: - EVM / BTC / SOL network tables

/// Supported EVM networks exposed in the Picker, each with a recommended
/// public RPC. Adding a row here makes it available in settings.
enum EVMNetwork: UInt64, CaseIterable, Identifiable {
    case mainnet = 1
    case sepolia = 11155111
    case polygon = 137
    case arbitrumOne = 42161
    case base = 8453

    var id: UInt64 { rawValue }

    var displayName: String {
        switch self {
        case .mainnet: return "Ethereum Mainnet"
        case .sepolia: return "Sepolia Testnet"
        case .polygon: return "Polygon"
        case .arbitrumOne: return "Arbitrum One"
        case .base: return "Base"
        }
    }

    var defaultRPC: String {
        switch self {
        case .mainnet: return "https://eth.llamarpc.com"
        case .sepolia: return "https://eth-sepolia.public.blastapi.io"
        case .polygon: return "https://polygon-rpc.com"
        case .arbitrumOne: return "https://arb1.arbitrum.io/rpc"
        case .base: return "https://mainnet.base.org"
        }
    }
}

enum BitcoinNetwork {
    case mainnet, testnet
    var defaultAPI: String {
        switch self {
        case .mainnet: return "https://blockstream.info/api"
        case .testnet: return "https://blockstream.info/testnet/api"
        }
    }
}

enum SolanaNetwork {
    case mainnet, devnet
    var defaultRPC: String {
        switch self {
        case .mainnet: return "https://api.mainnet-beta.solana.com"
        case .devnet: return "https://api.devnet.solana.com"
        }
    }
}

// MARK: - Network Presets

struct NetworkPreset: Identifiable {
    let id: String
    let name: String
    let ethereumRPC: String
    let bitcoinAPI: String
    let solanaRPC: String
    let evmChainId: UInt64
    let btcTestnet: Bool
    let solDevnet: Bool

    static let mainnet = NetworkPreset(
        id: "mainnet", name: "Mainnet",
        ethereumRPC: EVMNetwork.mainnet.defaultRPC,
        bitcoinAPI: BitcoinNetwork.mainnet.defaultAPI,
        solanaRPC: SolanaNetwork.mainnet.defaultRPC,
        evmChainId: EVMNetwork.mainnet.rawValue, btcTestnet: false, solDevnet: false
    )

    static let testnet = NetworkPreset(
        id: "testnet", name: "Testnet",
        ethereumRPC: EVMNetwork.sepolia.defaultRPC,
        bitcoinAPI: BitcoinNetwork.testnet.defaultAPI,
        solanaRPC: SolanaNetwork.devnet.defaultRPC,
        evmChainId: EVMNetwork.sepolia.rawValue, btcTestnet: true, solDevnet: true
    )

    static let all: [NetworkPreset] = [.mainnet, .testnet]
}

// MARK: - Network Reachability

actor NetworkStatus {
    static let shared = NetworkStatus()

    /// Real reachability probe for a given chain. Uses the actual JSON-RPC
    /// health method instead of a meaningless HEAD request (RPC endpoints
    /// typically 405 HEAD which was previously treated as "connected").
    func check(chain: Chain, config: NetworkConfig) async -> Bool {
        let service = BlockchainService()
        do {
            switch chain {
            case .ethereum:
                _ = try await service.ethBlockNumber(rpcURL: config.ethereumRPC)
                return true
            case .bitcoin:
                let base = config.bitcoinAPI
                guard let url = URL(string: "\(base)/blocks/tip/height") else { return false }
                var req = URLRequest(url: url, timeoutInterval: 5)
                req.httpMethod = "GET"
                let (_, response) = try await PinnedURLSession.shared.session.data(for: req)
                if let http = response as? HTTPURLResponse { return (200...299).contains(http.statusCode) }
                return false
            case .solana:
                _ = try await service.solHealth(rpcURL: config.solanaRPC)
                return true
            }
        } catch {
            return false
        }
    }

    /// Check if the active chain endpoints are reachable.
    func checkAll(config: NetworkConfig) async -> [Chain: Bool] {
        async let ethOk = check(chain: .ethereum, config: config)
        async let btcOk = check(chain: .bitcoin, config: config)
        async let solOk = check(chain: .solana, config: config)
        return [
            .ethereum: await ethOk,
            .bitcoin: await btcOk,
            .solana: await solOk
        ]
    }
}

// MARK: - Keys & Defaults

private extension NetworkConfig {
    enum Keys {
        static let ethereumRPC = "com.horcrux.rpc.ethereum"
        static let bitcoinAPI = "com.horcrux.rpc.bitcoin"
        static let solanaRPC = "com.horcrux.rpc.solana"
        static let evmChainId = "com.horcrux.rpc.evmChainId"
        static let btcTestnet = "com.horcrux.rpc.btcTestnet"
        static let solDevnet = "com.horcrux.rpc.solDevnet"
        static let alchemyKey = "com.horcrux.rpc.alchemyAPIKey"
        static let heliusKey = "com.horcrux.rpc.heliusAPIKey"
    }

    enum Defaults {
        static let ethereumRPC = EVMNetwork.mainnet.defaultRPC
        static let bitcoinAPI = BitcoinNetwork.mainnet.defaultAPI
        static let solanaRPC = SolanaNetwork.mainnet.defaultRPC
    }
}

// MARK: - Provider templates (for API-key users)

/// URL templates with `{KEY}` placeholder for popular paid providers.
/// The key itself lives in Keychain via `NetworkConfig.alchemyAPIKey` /
/// `heliusAPIKey` and is substituted in at RPC-call time.
enum RPCProviderTemplate {
    /// Alchemy EVM template for the given chain. `{KEY}` is substituted at RPC time.
    static func alchemy(evm: EVMNetwork) -> String? {
        switch evm {
        case .mainnet: return "https://eth-mainnet.g.alchemy.com/v2/{KEY}"
        case .sepolia: return "https://eth-sepolia.g.alchemy.com/v2/{KEY}"
        case .polygon: return "https://polygon-mainnet.g.alchemy.com/v2/{KEY}"
        case .arbitrumOne: return "https://arb-mainnet.g.alchemy.com/v2/{KEY}"
        case .base: return "https://base-mainnet.g.alchemy.com/v2/{KEY}"
        }
    }

    static func helius(mainnet: Bool) -> String {
        mainnet
            ? "https://mainnet.helius-rpc.com/?api-key={KEY}"
            : "https://devnet.helius-rpc.com/?api-key={KEY}"
    }
}

// MARK: - Fallback RPC endpoints

/// Public fallback endpoints tried in order when the primary fails with a
/// transport-level error. Keeps read-path available even when llamarpc or
/// mainnet-beta goes down.
enum RPCFallbacks {
    static func endpoints(for chain: Chain, config: NetworkConfig) -> [String] {
        switch chain {
        case .ethereum:
            guard let net = EVMNetwork(rawValue: config.evmChainId) else { return [] }
            switch net {
            case .mainnet:
                return [
                    "https://eth.llamarpc.com",
                    "https://ethereum.publicnode.com",
                    "https://rpc.ankr.com/eth"
                ]
            case .sepolia:
                return [
                    "https://eth-sepolia.public.blastapi.io",
                    "https://ethereum-sepolia.publicnode.com"
                ]
            case .polygon:
                return [
                    "https://polygon-rpc.com",
                    "https://polygon.llamarpc.com",
                    "https://polygon.publicnode.com"
                ]
            case .arbitrumOne:
                return [
                    "https://arb1.arbitrum.io/rpc",
                    "https://arbitrum.llamarpc.com",
                    "https://arbitrum.publicnode.com"
                ]
            case .base:
                return [
                    "https://mainnet.base.org",
                    "https://base.llamarpc.com",
                    "https://base.publicnode.com"
                ]
            }
        case .bitcoin:
            return config.btcTestnet
                ? ["https://blockstream.info/testnet/api", "https://mempool.space/testnet/api"]
                : ["https://blockstream.info/api", "https://mempool.space/api"]
        case .solana:
            return config.solDevnet
                ? ["https://api.devnet.solana.com"]
                : [
                    "https://api.mainnet-beta.solana.com",
                    "https://solana.publicnode.com"
                ]
        }
    }

    /// Build the actual ordered attempt list starting from the user's
    /// configured URL, then any public fallbacks (deduplicated).
    static func orderedAttempts(for chain: Chain, config: NetworkConfig) -> [String] {
        let primary = config.rpcURL(for: chain)
        let fallbacks = endpoints(for: chain, config: config)
        var seen = Set<String>()
        var out: [String] = []
        for url in [primary] + fallbacks where !seen.contains(url) {
            seen.insert(url)
            out.append(url)
        }
        return out
    }
}

