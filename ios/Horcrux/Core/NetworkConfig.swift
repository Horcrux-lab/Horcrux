import Foundation

/// Per-chain RPC endpoint configuration with sensible public defaults.
final class NetworkConfig: ObservableObject, @unchecked Sendable {
    static let shared = NetworkConfig()

    @Published var ethereumRPC: String {
        didSet { save(ethereumRPC, forKey: Keys.ethereumRPC) }
    }
    @Published var bitcoinAPI: String {
        didSet { save(bitcoinAPI, forKey: Keys.bitcoinAPI) }
    }
    @Published var solanaRPC: String {
        didSet { save(solanaRPC, forKey: Keys.solanaRPC) }
    }
    @Published var evmChainId: UInt64 {
        didSet { UserDefaults.standard.set(evmChainId, forKey: Keys.evmChainId) }
    }
    @Published var btcTestnet: Bool {
        didSet { UserDefaults.standard.set(btcTestnet, forKey: Keys.btcTestnet) }
    }
    @Published var solDevnet: Bool {
        didSet { UserDefaults.standard.set(solDevnet, forKey: Keys.solDevnet) }
    }

    private init() {
        let ud = UserDefaults.standard
        self.ethereumRPC = ud.string(forKey: Keys.ethereumRPC) ?? Defaults.ethereumRPC
        self.bitcoinAPI = ud.string(forKey: Keys.bitcoinAPI) ?? Defaults.bitcoinAPI
        self.solanaRPC = ud.string(forKey: Keys.solanaRPC) ?? Defaults.solanaRPC
        self.evmChainId = UInt64(ud.integer(forKey: Keys.evmChainId) == 0 ? 1 : ud.integer(forKey: Keys.evmChainId))
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
        ethereumRPC = Defaults.ethereumRPC
        bitcoinAPI = Defaults.bitcoinAPI
        solanaRPC = Defaults.solanaRPC
        evmChainId = 1
        btcTestnet = false
        solDevnet = false
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
        ethereumRPC: "https://eth.llamarpc.com",
        bitcoinAPI: "https://blockstream.info/api",
        solanaRPC: "https://api.mainnet-beta.solana.com",
        evmChainId: 1, btcTestnet: false, solDevnet: false
    )

    static let testnet = NetworkPreset(
        id: "testnet", name: "Testnet",
        ethereumRPC: "https://eth-sepolia.public.blastapi.io",
        bitcoinAPI: "https://blockstream.info/testnet/api",
        solanaRPC: "https://api.devnet.solana.com",
        evmChainId: 11155111, btcTestnet: true, solDevnet: true
    )

    static let all: [NetworkPreset] = [.mainnet, .testnet]
}

// MARK: - Network Reachability

actor NetworkStatus {
    static let shared = NetworkStatus()

    /// Check if a given RPC endpoint is reachable.
    func checkEndpoint(_ urlString: String, timeout: TimeInterval = 5) async -> Bool {
        guard let url = URL(string: urlString) else { return false }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await PinnedURLSession.shared.session.data(for: request)
            if let http = response as? HTTPURLResponse {
                return (200...499).contains(http.statusCode)
            }
            return true
        } catch {
            return false
        }
    }

    /// Check if the active chain endpoints are reachable.
    func checkAll(config: NetworkConfig) async -> [Chain: Bool] {
        async let ethOk = checkEndpoint(config.ethereumRPC)
        async let btcOk = checkEndpoint(config.bitcoinAPI)
        async let solOk = checkEndpoint(config.solanaRPC)
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
        static let ethereumRPC = "https://eth.llamarpc.com"
        static let bitcoinAPI = "https://blockstream.info/api"
        static let solanaRPC = "https://api.mainnet-beta.solana.com"
    }
}
