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
    /// Branch order mirrors `resolveRawURL` exactly.
    ///
    /// - Parameters:
    ///   - isOverridden: Whether `ChainEndpointOverrides.url(for: chain)` is non-nil.
    ///   - provider: The active `NodeProvider`, or nil for public defaults.
    ///   - hasKey: Whether a non-empty API key is configured for `provider`.
    ///   - solanaMainnet: `true` when the Solana cluster is mainnet (`!solDevnet`).
    ///     The `!` inversion exists in exactly one place — the instance convenience below.
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

    /// Instance convenience for the UI. Reads live singletons once and
    /// delegates to the pure classifier.
    ///
    /// Reads `url(for:)` (lock-guarded storage), **not** the `overrides`
    /// mirror — the mirror is there to drive SwiftUI reactivity but may lag.
    func endpointSource(for chain: Chain) -> EndpointSource {
        let provider = activeProvider
        return Self.endpointSource(
            for: chain,
            isOverridden: ChainEndpointOverrides.shared.url(for: chain) != nil,
            provider: provider,
            hasKey: provider.map { !apiKey(for: $0).isEmpty } ?? false,
            evmChainId: evmChainId,
            solanaMainnet: !solDevnet)       // the ONLY place !solDevnet is computed
    }
}
