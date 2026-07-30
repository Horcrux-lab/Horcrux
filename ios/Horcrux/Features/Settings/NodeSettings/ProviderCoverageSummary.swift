import Foundation

/// A snapshot that partitions all fourteen chains into three disjoint groups.
///
/// **Invariant:** `overridden ∪ providerCovered ∪ publicDefault == Set(Chain.allCases)`.
/// The three groups are exhaustive and mutually exclusive — a chain never
/// appears in two buckets, and every chain appears in exactly one.
///
/// `provider` is optional. When nil (the user selected "Public defaults"),
/// `providerCovered` is empty and the no-key caption paths handle all
/// combinations of override state — so the view has a single caption path
/// and cannot grow a divergent branch that drifts out of sync.
///
/// The initializer is pure: all inputs are explicit parameters. The view
/// passes the live override set from `ChainEndpointOverrides`; tests pass
/// whatever they need without touching global state.
struct ProviderCoverageSummary {
    let provider: NodeProvider?
    /// Whether an API key is set for the active provider. False by definition
    /// when `provider` is nil; normalised in the initializer so `formattedCaption`
    /// can gate on `hasKey` alone.
    let hasKey: Bool
    /// Chains with a user-set endpoint. The provider may cover these too —
    /// the override takes precedence either way.
    let overridden: Set<Chain>
    /// Chains the provider serves (key is set) that are not overridden.
    let providerCovered: Set<Chain>
    /// Chains served by neither provider nor override. They use the public
    /// endpoint — this is the gap the coverage line exists to name.
    let publicDefault: Set<Chain>

    init(provider: NodeProvider?,
         hasKey: Bool,
         overriddenChains: Set<Chain>,
         evmChainId: UInt64,
         solanaMainnet: Bool) {
        let covered: Set<Chain>
        if let provider = provider, hasKey {
            covered = provider.coveredChains(evmChainId: evmChainId, solanaMainnet: solanaMainnet)
        } else {
            covered = []
        }
        self.provider = provider
        // Normalise: a nil provider has no key by definition.
        self.hasKey = provider != nil && hasKey
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
        // hasKey true → provider is non-nil (enforced by the normalisation above).
        let name = provider?.displayName ?? ""
        guard !publicDefault.isEmpty else {
            if overridden.isEmpty {
                return L10n.NodeSettings.coverageAllCovered(name, Chain.allCases.count)
            }
            return L10n.NodeSettings.coverageAllWithOverrides(name, providerCovered.count, overridden.count)
        }
        let names = publicDefault
            .sorted { $0.displayName < $1.displayName }
            .map(\.displayName)
            .joined(separator: L10n.NodeSettings.chainListSeparator)
        if overridden.isEmpty {
            return L10n.NodeSettings.coveragePartial(name, providerCovered.count, Chain.allCases.count, names)
        }
        return L10n.NodeSettings.coveragePartialWithOverrides(
            name, providerCovered.count, Chain.allCases.count, names, overridden.count)
    }
}
