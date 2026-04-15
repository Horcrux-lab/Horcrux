import Foundation

/// Per-chain RPC endpoint configuration with sensible public defaults.
final class NetworkConfig: ObservableObject {
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

    private func save(_ value: String, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
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
