import Foundation

/// An account-scoped RPC provider: one key from this provider works
/// across every chain it serves.
///
/// GetBlock and Helius are deliberately absent. GetBlock issues a token
/// bound to a single chain in its dashboard, and Helius serves only
/// Solana, so neither satisfies the account-scoped contract this type
/// represents. Both remain available as per-chain overrides.
enum NodeProvider: String, CaseIterable, Identifiable, Codable {
    case alchemy, infura, ankr, blockpi, drpc, nodeReal, tenderly, oneRPC

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .alchemy: return "Alchemy"
        case .infura: return "Infura"
        case .ankr: return "Ankr"
        case .blockpi: return "BlockPI"
        case .drpc: return "dRPC"
        case .nodeReal: return "NodeReal"
        case .tenderly: return "Tenderly"
        case .oneRPC: return "1RPC"
        }
    }

    /// The `{KEY}`-bearing URL template this provider serves `chain` on,
    /// or nil when it does not serve that chain at all.
    ///
    /// `evmChainId` is consulted only for `.ethereum`, whose network is
    /// user-selectable between mainnet and Sepolia. Every other EVM chain
    /// maps to exactly one `EVMNetwork`.
    func template(for chain: Chain, evmChainId: UInt64) -> String? {
        if chain.isEVM {
            guard let net = evmNetwork(for: chain, evmChainId: evmChainId) else { return nil }
            switch self {
            case .alchemy:  return RPCProviderTemplate.alchemy(evm: net)
            case .infura:   return RPCProviderTemplate.infura(evm: net)
            case .ankr:     return RPCProviderTemplate.ankr(evm: net)
            case .blockpi:  return RPCProviderTemplate.blockpi(evm: net)
            case .drpc:     return RPCProviderTemplate.drpc(evm: net)
            case .nodeReal: return RPCProviderTemplate.nodeReal(evm: net)
            case .tenderly: return RPCProviderTemplate.tenderly(evm: net)
            case .oneRPC:   return RPCProviderTemplate.oneRPC(evm: net)
            }
        }

        guard chain == .solana else { return nil }
        // Bitcoin, Litecoin and Tron are served by no provider in this
        // enum; they fall through to public defaults or a user override.
        let mainnet = !NetworkConfig.shared.solDevnet
        switch self {
        case .alchemy:  return RPCProviderTemplate.alchemySolana(mainnet: mainnet)
        case .infura:   return RPCProviderTemplate.infuraSolana(mainnet: mainnet)
        case .ankr:     return RPCProviderTemplate.ankrSolana()
        case .drpc:     return RPCProviderTemplate.drpcSolana()
        case .oneRPC:   return RPCProviderTemplate.oneRPCSolana(mainnet: mainnet)
        case .blockpi, .nodeReal, .tenderly: return nil
        }
    }

    private func evmNetwork(for chain: Chain, evmChainId: UInt64) -> EVMNetwork? {
        if chain == .ethereum {
            return EVMNetwork(rawValue: evmChainId) ?? .mainnet
        }
        return chain.defaultEVMNetwork
    }

    func coveredChains(evmChainId: UInt64) -> Set<Chain> {
        Set(Chain.allCases.filter { template(for: $0, evmChainId: evmChainId) != nil })
    }

    func uncoveredChains(evmChainId: UInt64) -> Set<Chain> {
        Set(Chain.allCases).subtracting(coveredChains(evmChainId: evmChainId))
    }
}
