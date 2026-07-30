import Foundation

/// One-time migration from the legacy five-URL-field model to
/// provider + per-chain overrides.
///
/// `plan` is a pure function of its arguments — it reads no singleton and
/// no UserDefaults — so every rule below is table-testable. `apply` and
/// `runIfNeeded` do the writes.
enum NodeSettingsMigration {

    struct Plan: Equatable {
        var activeProvider: NodeProvider?
        var overrides: [Chain: String]
        var evmChainId: UInt64
    }

    static let versionKey = "com.horcrux.rpc.settingsMigrationVersion"
    static let currentVersion = 1

    static func plan(
        ethereumRPC: String,
        bitcoinAPI: String,
        litecoinAPI: String,
        solanaRPC: String,
        tronAPI: String,
        evmChainId: UInt64
    ) -> Plan {
        var overrides: [Chain: String] = [:]
        var provider: NodeProvider?
        var resolvedChainId = evmChainId

        // The Ethereum slot could be pointed at any EVM network. When it
        // pointed somewhere other than Ethereum's own mainnet/Sepolia, the
        // value belongs to that first-class chain instead.
        let evmNetwork = EVMNetwork(rawValue: evmChainId) ?? .mainnet
        let evmTargetChain: Chain
        if evmNetwork == .mainnet || evmNetwork == .sepolia {
            evmTargetChain = .ethereum
        } else {
            evmTargetChain = Chain.allCases.first { $0.defaultEVMNetwork == evmNetwork } ?? .ethereum
            resolvedChainId = EVMNetwork.mainnet.rawValue
        }

        if let matched = detectProvider(in: ethereumRPC) {
            provider = matched
        } else if !isShipped(ethereumRPC, for: evmTargetChain) {
            overrides[evmTargetChain] = ethereumRPC
        }

        if let solProvider = detectProvider(in: solanaRPC) {
            if provider == nil {
                provider = solProvider
            } else if solProvider != provider {
                // Only one vendor can be the account provider. Dropping the
                // other would silently downgrade that chain to a public
                // endpoint, so it survives as an override. The `{KEY}` stays
                // in it; substituteAPIKey resolves it by hostname.
                overrides[.solana] = solanaRPC
            }
        } else if !isShipped(solanaRPC, for: .solana) {
            overrides[.solana] = solanaRPC
        }

        for (value, chain) in [(bitcoinAPI, Chain.bitcoin),
                               (litecoinAPI, Chain.litecoin),
                               (tronAPI, Chain.tron)] {
            if !isShipped(value, for: chain) {
                overrides[chain] = value
            }
        }

        return Plan(activeProvider: provider,
                    overrides: overrides,
                    evmChainId: resolvedChainId)
    }

    /// True when `value` is an endpoint we ship for `chain`, in which case
    /// it must NOT become an override — the user stays on the default and
    /// keeps receiving default changes.
    ///
    /// The lookup spans both network selections on purpose; see
    /// `RPCFallbacks.allShippedEndpoints(for:)`.
    private static func isShipped(_ value: String, for chain: Chain) -> Bool {
        if value.isEmpty { return true }
        return RPCFallbacks.allShippedEndpoints(for: chain).contains(value)
    }

    private static func detectProvider(in url: String) -> NodeProvider? {
        guard url.contains("{KEY}") else { return nil }
        return NodeProvider.allCases.first { templates(of: $0).contains(url) }
    }

    /// Every `{KEY}` template `provider` can produce, across every chain
    /// and both Solana clusters. Pure: no singleton reads.
    private static func templates(of provider: NodeProvider) -> Set<String> {
        var out: Set<String> = []
        let mainnetId = EVMNetwork.mainnet.rawValue

        for net in EVMNetwork.allCases {
            if let t = provider.template(for: .ethereum, evmChainId: net.rawValue,
                                         solanaMainnet: true) {
                out.insert(t)
            }
        }
        for chain in Chain.allCases where chain.isEVM && chain != .ethereum {
            if let t = provider.template(for: chain, evmChainId: mainnetId,
                                         solanaMainnet: true) {
                out.insert(t)
            }
        }
        for solanaMainnet in [true, false] {
            if let t = provider.template(for: .solana, evmChainId: mainnetId,
                                         solanaMainnet: solanaMainnet) {
                out.insert(t)
            }
        }
        return out
    }

    static func apply(_ plan: Plan, to config: NetworkConfig) {
        config.activeProvider = plan.activeProvider
        config.evmChainId = plan.evmChainId
        for (chain, url) in plan.overrides {
            ChainEndpointOverrides.shared.set(url, for: chain)
        }
    }

    /// Entry point called once at launch. The version gate matters: the
    /// legacy fields are never cleared, so without it every launch would
    /// re-derive the same plan and resurrect overrides the user deleted.
    static func runIfNeeded(config: NetworkConfig,
                            defaults: UserDefaults = .standard) {
        guard defaults.integer(forKey: versionKey) < currentVersion else { return }
        let plan = plan(
            ethereumRPC: config.legacyEthereumRPC,
            bitcoinAPI: config.legacyBitcoinAPI,
            litecoinAPI: config.legacyLitecoinAPI,
            solanaRPC: config.legacySolanaRPC,
            tronAPI: config.legacyTronAPI,
            evmChainId: config.evmChainId
        )
        apply(plan, to: config)
        defaults.set(currentVersion, forKey: versionKey)
    }
}
