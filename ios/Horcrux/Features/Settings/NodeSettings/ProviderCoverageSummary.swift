import Foundation

/// A snapshot that partitions all fourteen chains into three disjoint groups.
///
/// **Invariant:** `overridden ∪ providerCovered ∪ publicDefault == Set(Chain.allCases)`.
/// The three groups are exhaustive and mutually exclusive — a chain never
/// appears in two buckets, and every chain appears in exactly one.
///
/// The initializer is pure: all inputs are explicit parameters. The view
/// passes the live override set from `ChainEndpointOverrides`; tests pass
/// whatever they need without touching global state.
struct ProviderCoverageSummary {
    let provider: NodeProvider
    /// Whether an API key is set. Determines whether the provider URL is
    /// actually substituted; without it `providerCovered` is empty.
    let hasKey: Bool
    /// Chains with a user-set endpoint. The provider may cover these too —
    /// the override takes precedence either way.
    let overridden: Set<Chain>
    /// Chains the provider serves (key is set) that are not overridden.
    let providerCovered: Set<Chain>
    /// Chains served by neither provider nor override. They use the public
    /// endpoint — this is the gap the coverage line exists to name.
    let publicDefault: Set<Chain>

    init(provider: NodeProvider,
         hasKey: Bool,
         overriddenChains: Set<Chain>,
         evmChainId: UInt64,
         solanaMainnet: Bool) {
        let covered: Set<Chain> = hasKey
            ? provider.coveredChains(evmChainId: evmChainId, solanaMainnet: solanaMainnet)
            : []
        self.provider = provider
        self.hasKey = hasKey
        self.overridden = overriddenChains
        let effective = covered.subtracting(overriddenChains)
        self.providerCovered = effective
        self.publicDefault = Set(Chain.allCases).subtracting(overriddenChains).subtracting(effective)
    }

    var formattedCaption: String {
        if !hasKey {
            guard !overridden.isEmpty else {
                return L10n.NodeSettings.coverageNoKey
            }
            return L10n.NodeSettings.coverageNoKeyWithOverrides(overridden.count, publicDefault.count)
        }
        guard !publicDefault.isEmpty else {
            if overridden.isEmpty {
                return L10n.NodeSettings.coverageAllCovered(provider.displayName, Chain.allCases.count)
            }
            return L10n.NodeSettings.coverageAllWithOverrides(
                provider.displayName, providerCovered.count, overridden.count)
        }
        let names = publicDefault
            .sorted { $0.displayName < $1.displayName }
            .map(\.displayName)
            .joined(separator: ", ")
        if overridden.isEmpty {
            return L10n.NodeSettings.coveragePartial(
                provider.displayName, providerCovered.count, Chain.allCases.count, names)
        }
        return L10n.NodeSettings.coveragePartialWithOverrides(
            provider.displayName, providerCovered.count, Chain.allCases.count, names, overridden.count)
    }
}
