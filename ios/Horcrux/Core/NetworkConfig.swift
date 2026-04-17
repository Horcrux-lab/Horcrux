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

    private init() {
        let ud = UserDefaults.standard
        self.ethereumRPC = ud.string(forKey: Keys.ethereumRPC) ?? Defaults.ethereumRPC
        self.bitcoinAPI = ud.string(forKey: Keys.bitcoinAPI) ?? Defaults.bitcoinAPI
        self.solanaRPC = ud.string(forKey: Keys.solanaRPC) ?? Defaults.solanaRPC
        let storedChainId = ud.integer(forKey: Keys.evmChainId)
        self.evmChainId = UInt64(storedChainId == 0 ? 1 : storedChainId)
        self.btcTestnet = ud.bool(forKey: Keys.btcTestnet)
        self.solDevnet = ud.bool(forKey: Keys.solDevnet)
    }

    func rpcURL(for chain: Chain) -> String {
        switch chain {
        case .ethereum: return ethereumRPC
        case .bitcoin: return bitcoinAPI
        case .solana: return solanaRPC
        }
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

    private func invalidateBalances() {
        Task { @MainActor in
            BalanceCache.shared.invalidateAll()
        }
    }

    // MARK: - Auto-swap helpers

    /// Swap `ethereumRPC` to the new chain's default when the previous value was
    /// a recognized default for *any* known chain. User-customized URLs are
    /// preserved untouched (the UI surfaces a mismatch warning separately).
    private func autoSwapEthereumRPCIfDefault(previousChainId: UInt64) {
        guard previousChainId != evmChainId else { return }
        let known = Set(EVMNetwork.allCases.map(\.defaultRPC))
        guard known.contains(ethereumRPC) else { return }
        if let network = EVMNetwork(rawValue: evmChainId) {
            ethereumRPC = network.defaultRPC
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
    }

    enum Defaults {
        static let ethereumRPC = EVMNetwork.mainnet.defaultRPC
        static let bitcoinAPI = BitcoinNetwork.mainnet.defaultAPI
        static let solanaRPC = SolanaNetwork.mainnet.defaultRPC
    }
}

