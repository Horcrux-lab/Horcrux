import Foundation

/// Where a chain's RPC traffic actually goes. The three cases map directly
/// to the precedence order in `NetworkConfig.resolveRawURL`: override wins,
/// then a key-bearing provider template, then the public default.
///
/// Kept in its own file so `L10n` stays outside the RPC path. The UI badge
/// label lives in `ChainEndpointList.swift`, which is imported only by
/// Settings screens.
enum EndpointSource: Equatable, Hashable {
    case override
    case provider(NodeProvider)
    case publicDefault
}

extension NetworkConfig {
    /// Pure single source of truth for endpoint precedence. No singleton reads.
    /// Branch order is the canonical definition; `resolved(for:)` drives it.
    ///
    /// - Parameters:
    ///   - isOverridden: Whether `ChainEndpointOverrides.url(for: chain)` is non-nil.
    ///   - provider: The active `NodeProvider`, or nil for public defaults.
    ///   - hasKey: Whether a non-empty API key is configured for `provider`.
    ///   - solanaMainnet: `true` when the Solana cluster is mainnet (`!solDevnet`).
    ///     The `!` inversion exists in exactly one place — `resolved(for:)`.
    static func endpointSource(
        for chain: Chain,
        isOverridden: Bool,
        provider: NodeProvider?,
        hasKey: Bool,
        evmChainId: UInt64,
        solanaMainnet: Bool
    ) -> EndpointSource {
        if isOverridden { return .override }
        if let provider, hasKey,
           provider.template(for: chain, evmChainId: evmChainId,
                             solanaMainnet: solanaMainnet) != nil {
            return .provider(provider)
        }
        return .publicDefault
    }

    /// Reads live state **once** and returns both the source classification and
    /// the resolved URL in a single pass.
    ///
    /// This is the single adapter between live state and the pure classifier.
    /// `endpointSource(for:)` and `resolveRawURL(for:)` both project out of it,
    /// so they are structurally incapable of disagreeing. The `!solDevnet`
    /// inversion and the `ChainEndpointOverrides` lock acquire each happen
    /// exactly once per call here, eliminating the TOCTOU window where an
    /// override could change between two independent reads.
    func resolved(for chain: Chain) -> (source: EndpointSource, url: String) {
        let overrideURL = ChainEndpointOverrides.shared.url(for: chain)
        let provider = activeProvider
        let solanaMainnet = !solDevnet                  // the ONLY place !solDevnet is computed
        let source = Self.endpointSource(
            for: chain,
            isOverridden: overrideURL != nil,
            provider: provider,
            hasKey: provider.map { !apiKey(for: $0).isEmpty } ?? false,
            evmChainId: evmChainId,
            solanaMainnet: solanaMainnet)
        switch source {
        case .override:
            // ?? arm unreachable by construction; guards against future classifier changes.
            return (source, overrideURL ?? publicDefault(for: chain))
        case .provider(let p):
            return (source, p.template(for: chain, evmChainId: evmChainId,
                                       solanaMainnet: solanaMainnet) ?? publicDefault(for: chain))
        case .publicDefault:
            return (source, publicDefault(for: chain))
        }
    }

    func endpointSource(for chain: Chain) -> EndpointSource { resolved(for: chain).source }
}

