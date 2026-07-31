import XCTest
@testable import Horcrux

/// Tests for RPC endpoint routing: the curated fallback tables, cooldown
/// filtering, and health-aware ordering.
///
/// Context: on 2026-07-29 a live probe of every endpoint in the fallback
/// tables found six dead — five of them LlamaRPC, which had been the *first*
/// fallback for Ethereum, Polygon, Arbitrum, Base and Optimism. The table had
/// rotted silently for months. These tests exist so the same rot fails loudly
/// instead of degrading the app.
///
/// Deliberately offline: no test here performs a live network call. Endpoint
/// liveness is a property of the internet, not of this build, and is checked
/// by the scheduled probe workflow instead.
final class RPCRoutingTests: XCTestCase {

    /// Hosts removed after being measured dead. Re-adding any of these should
    /// fail the build until someone re-verifies them.
    private static let knownDeadHosts = [
        "llamarpc.com",                    // whole provider down: 521 / connection refused
        "polygon-rpc.com",                 // HTTP 401 "API key disabled, tenant disabled"
        "eth-sepolia.public.blastapi.io"   // "Blast API is no longer available"
    ]

    /// Hosts that answer from some vantage points and not others. These are
    /// worse than dead hosts, because they pass a developer's local check and
    /// then fail for a subset of users.
    ///
    /// `1rpc.io` serves residential clients normally but returns "unknown
    /// network" to datacenter egress — caught by the probe workflow running on
    /// Azure-hosted runners minutes after these URLs were added. A large share
    /// of wallet users reach the internet through commercial VPNs, which are
    /// datacenter IPs, so this is a real user-facing failure and not a CI
    /// artefact. Keyed 1RPC access remains available as a provider template,
    /// where it is the user's explicit, visible choice.
    ///
    /// Mechanism aside — geo-routing or IP policy — an endpoint whose
    /// availability depends on who is asking cannot be a silent fallback.
    private static let vantageDependentHosts = ["1rpc.io"]

    /// Endpoints that do not broadcast to the public mempool. Private relays
    /// answer reads correctly, so they look healthy to every probe, but a
    /// transaction sent through one does not propagate normally and can sit
    /// unmined without any error surfacing. They must never appear in a
    /// fallback path the user did not choose.
    private static let privateRelayHosts = [
        "rpc.flashbots.net",
        "rpc.mevblocker.io",
        "rpc.titanbuilder.xyz",
        "rpc.beaverbuild.org"
    ]

    private static var bannedHosts: [(host: String, reason: String)] {
        knownDeadHosts.map { ($0, "measured dead") }
            + vantageDependentHosts.map { ($0, "unavailable from datacenter egress") }
            + privateRelayHosts.map { ($0, "private mempool, does not broadcast publicly") }
    }

    override func setUp() {
        super.setUp()
        RPCEndpointHealth.resetForTests()
        NetworkConfig.shared.resetToDefaults()
    }

    override func tearDown() {
        RPCEndpointHealth.resetForTests()
        NetworkConfig.shared.resetToDefaults()
        super.tearDown()
    }

    // MARK: - Curated table hygiene

    func test_noFallbackTable_containsABannedHost() {
        let config = NetworkConfig.shared
        var checked = 0

        for chain in Chain.allCases {
            for url in RPCFallbacks.endpoints(for: chain, config: config) {
                checked += 1
                for banned in Self.bannedHosts {
                    XCTAssertFalse(url.contains(banned.host),
                                   "\(chain) fallback lists \(banned.host) — \(banned.reason): \(url)")
                }
            }
        }

        // Sweep every EVM network too — `endpoints(for:config:)` picks the
        // Ethereum table off `config.evmChainId`, so the default config only
        // exercises mainnet.
        for net in EVMNetwork.allCases {
            config.evmChainId = net.rawValue
            for url in RPCFallbacks.endpoints(for: .ethereum, config: config) {
                checked += 1
                for banned in Self.bannedHosts {
                    XCTAssertFalse(url.contains(banned.host),
                                   "\(net) fallback lists \(banned.host) — \(banned.reason): \(url)")
                }
            }
        }

        XCTAssertGreaterThan(checked, 0, "the sweep should have inspected some endpoints")
    }

    func test_everyMainnetEVMNetwork_keepsAtLeastTwoIndependentProviders() {
        let config = NetworkConfig.shared

        for net in EVMNetwork.allCases where net != .sepolia {
            config.evmChainId = net.rawValue
            let attempts = RPCFallbacks.orderedAttempts(for: .ethereum, config: config)
            let families = Set(attempts.compactMap(Self.providerFamily))
            XCTAssertGreaterThanOrEqual(
                families.count, 2,
                "\(net) has only \(families.count) independent provider(s): \(attempts). "
                + "One operator going down would take out the whole chain."
            )
        }
    }

    /// Two hostnames belonging to the same operator are not redundancy.
    /// Collapses `ethereum-rpc.publicnode.com` and `polygon.publicnode.com`
    /// to a single `publicnode.com` family.
    private static func providerFamily(_ urlString: String) -> String? {
        guard let host = URL(string: urlString)?.host else { return nil }
        let parts = host.split(separator: ".")
        guard parts.count >= 2 else { return host }
        return parts.suffix(2).joined(separator: ".")
    }

    // MARK: - Cooldown filtering

    func test_resolvedAttempts_excludesACoolingEndpoint() {
        let config = NetworkConfig.shared
        let baseline = RPCFallbacks.resolvedAttempts(for: .ethereum, config: config)
        guard baseline.count >= 2 else {
            return XCTFail("need at least two endpoints to test exclusion, got \(baseline)")
        }

        let victim = baseline[1]
        RPCEndpointHealth.markAuthFailed(victim)

        let after = RPCFallbacks.resolvedAttempts(for: .ethereum, config: config)
        XCTAssertFalse(after.contains(victim),
                       "an auth-failed endpoint must not be offered again while cooling")
    }

    func test_resolvedAttempts_returnsEverythingWhenAllEndpointsAreCooling() {
        let config = NetworkConfig.shared
        let all = RPCFallbacks.orderedAttempts(for: .ethereum, config: config)
        all.forEach { RPCEndpointHealth.markAuthFailed($0) }

        // A cooling endpoint still beats no endpoint at all.
        XCTAssertEqual(RPCFallbacks.resolvedAttempts(for: .ethereum, config: config), all)
    }

    // MARK: - Health-aware ordering

    func test_resolvedAttempts_keepsThePrimaryPinnedFirst() {
        let config = NetworkConfig.shared
        let baseline = RPCFallbacks.resolvedAttempts(for: .ethereum, config: config)
        guard let primary = baseline.first, baseline.count >= 3 else {
            return XCTFail("need a primary plus two fallbacks, got \(baseline)")
        }

        // Give the *last* fallback a fresh success. It should be promoted
        // above the other fallbacks but must never displace the primary,
        // which is the user's explicit choice.
        RPCEndpointHealth.markOk(baseline[baseline.count - 1])

        let reordered = RPCFallbacks.resolvedAttempts(for: .ethereum, config: config)
        XCTAssertEqual(reordered.first, primary,
                       "the configured primary must stay first regardless of measurements")
    }

    func test_resolvedAttempts_promotesARecentlySuccessfulFallback() {
        let config = NetworkConfig.shared
        let baseline = RPCFallbacks.resolvedAttempts(for: .ethereum, config: config)
        guard baseline.count >= 3 else {
            return XCTFail("need a primary plus two fallbacks, got \(baseline)")
        }

        let lastFallback = baseline[baseline.count - 1]
        RPCEndpointHealth.markOk(lastFallback)

        let reordered = RPCFallbacks.resolvedAttempts(for: .ethereum, config: config)
        XCTAssertEqual(reordered[1], lastFallback,
                       "a fallback with a recent success should sort ahead of untried ones")
        XCTAssertEqual(Set(reordered), Set(baseline),
                       "reordering must not add or drop candidates")
    }

    func test_resolvedAttempts_isStableWithinATier() {
        let config = NetworkConfig.shared
        let first = RPCFallbacks.resolvedAttempts(for: .ethereum, config: config)
        let second = RPCFallbacks.resolvedAttempts(for: .ethereum, config: config)
        XCTAssertEqual(first, second,
                       "with no health signal the curated order must be preserved exactly")
    }

    // MARK: - Tier classification

    func test_tier_ranksSuccessAboveUntriedAboveFailure() {
        RPCEndpointHealth.markOk("https://ok.example")
        RPCEndpointHealth.markTransientFailed("https://bad.example")

        XCTAssertEqual(RPCEndpointHealth.tier("https://ok.example"), 0)
        XCTAssertEqual(RPCEndpointHealth.tier("https://untried.example"), 1,
                       "an endpoint we know nothing about is a better bet than one we watched fail")
        XCTAssertEqual(RPCEndpointHealth.tier("https://bad.example"), 2)
    }

    func test_tier_recoversAfterASuccessFollowingAFailure() {
        RPCEndpointHealth.markTransientFailed("https://flaky.example")
        XCTAssertEqual(RPCEndpointHealth.tier("https://flaky.example"), 2)

        RPCEndpointHealth.markOk("https://flaky.example")
        XCTAssertEqual(RPCEndpointHealth.tier("https://flaky.example"), 0,
                       "a fresh success must clear the demotion, not just the cooldown")
    }

    func test_clear_returnsAFailedEndpointToNeutral() {
        RPCEndpointHealth.markAuthFailed("https://fixed-my-key.example")
        XCTAssertEqual(RPCEndpointHealth.tier("https://fixed-my-key.example"), 2)

        // "I fixed my key, stop avoiding this URL" — should undo the
        // demotion as well as the cooldown, otherwise the affordance only
        // half works.
        RPCEndpointHealth.clear("https://fixed-my-key.example")
        XCTAssertFalse(RPCEndpointHealth.isCoolingDown("https://fixed-my-key.example"))
        XCTAssertEqual(RPCEndpointHealth.tier("https://fixed-my-key.example"), 1)
    }

    // MARK: - Keyless fallbacks must stay keyless

    /// The Tenderly public gateways added as free fallbacks share a host
    /// family with the Tenderly *paid provider template*
    /// (`https://{chain}.gateway.tenderly.co/{KEY}`), and
    /// `substituteAPIKey` selects a key by host substring. Only the
    /// `{KEY}` guard keeps the two apart.
    ///
    /// If that guard were ever relaxed into "append the key when the host
    /// matches", every free fallback on a provider the user happens to
    /// hold a key for would start spending that key's quota, and would
    /// bind anonymous fallback traffic to the user's billing identity —
    /// the exact privacy property the free tier is there to preserve.
    func test_keylessFallbackURLs_areNeverRewrittenWithAConfiguredKey() {
        let config = NetworkConfig.shared
        config.tenderlyAPIKey = "test-tenderly-key"
        config.drpcAPIKey = "test-drpc-key"
        defer {
            config.tenderlyAPIKey = ""
            config.drpcAPIKey = ""
        }

        var checked = 0
        for net in EVMNetwork.allCases {
            config.evmChainId = net.rawValue
            for url in RPCFallbacks.endpoints(for: .ethereum, config: config) {
                checked += 1
                let substituted = config.substituteAPIKey(in: url, chain: .ethereum)
                XCTAssertEqual(substituted, url,
                               "curated fallback \(url) was rewritten to \(substituted)")
                XCTAssertFalse(substituted.contains("test-tenderly-key"))
                XCTAssertFalse(substituted.contains("test-drpc-key"))
            }
        }

        XCTAssertGreaterThan(checked, 0, "the sweep should have inspected some endpoints")
    }

    /// The same guard, one layer out: a *user-typed override* carries no
    /// `{KEY}`, so no stored key may be spliced into it even when its host
    /// matches a provider the user holds a key for.
    ///
    /// This is a distinct path from the fallback sweep above. That one calls
    /// `substituteAPIKey` directly; this one goes through the whole resolver
    /// (`rpcURL` → `resolveRawURL` → `ChainEndpointOverrides`), so it also
    /// pins the property against a future change that rewrites URLs somewhere
    /// between the override store and the substitution step.
    ///
    /// Were it to fail, a hand-entered self-hosted endpoint would start
    /// spending that key's quota and bind the traffic to a billing identity
    /// the user never chose for it.
    func test_overrideURLs_areNeverRewrittenWithAConfiguredKey() {
        let config = NetworkConfig.shared
        let previousKey = config.tenderlyAPIKey
        let previousOverrides = ChainEndpointOverrides.shared.snapshot()
        config.tenderlyAPIKey = "test-tenderly-key"
        defer {
            config.tenderlyAPIKey = previousKey
            ChainEndpointOverrides.shared.replaceAll(with: previousOverrides)
        }

        for chain in Chain.allCases {
            ChainEndpointOverrides.shared.set("https://mainnet.gateway.tenderly.co", for: chain)
            let url = config.rpcURL(for: chain)
            XCTAssertEqual(url, "https://mainnet.gateway.tenderly.co", "\(chain)")
            XCTAssertFalse(url.contains("test-tenderly-key"), "\(chain)")
        }
    }

    // MARK: - API key slot routing

    /// GetBlock issues a token bound to a single chain in its dashboard, so it
    /// cannot be an account-wide `NodeProvider` and is absent from the picker.
    /// The picker used to be the only UI that wrote `getblockAPIKey`; the
    /// override editor's key field is now the only one, and it must write the
    /// same slot the resolver reads.
    func test_apiKeySlot_routesGetBlockToItsOwnField() {
        let config = NetworkConfig.shared
        let slot = config.apiKeySlot(forHost: "go.getblock.io", chain: .polygon)
        XCTAssertEqual(slot?.keyPath, \NetworkConfig.getblockAPIKey,
                       "A GetBlock override must write the GetBlock key slot, "
                       + "not the Alchemy catch-all.")
        XCTAssertEqual(slot?.displayName, "GetBlock")
    }

    /// Unknown EVM hosts must land on the same slot `substituteAPIKey` uses,
    /// or the field would write a key the resolver never reads.
    func test_apiKeySlot_fallsBackToAlchemyForUnknownEVMHost() {
        let config = NetworkConfig.shared
        let slot = config.apiKeySlot(forHost: "rpc.example.invalid", chain: .base)
        XCTAssertEqual(slot?.keyPath, \NetworkConfig.alchemyAPIKey,
                       "Unknown EVM hosts must resolve to the same slot "
                       + "substituteAPIKey uses, or the field would write a "
                       + "key the resolver never reads.")
    }

    /// Solana's catch-all is Helius, not Alchemy — the non-EVM branch has its
    /// own default and swapping the two would silently misroute the key.
    func test_apiKeySlot_fallsBackToHeliusForUnknownSolanaHost() {
        let config = NetworkConfig.shared
        let slot = config.apiKeySlot(forHost: "rpc.example.invalid", chain: .solana)
        XCTAssertEqual(slot?.keyPath, \NetworkConfig.heliusAPIKey)
        XCTAssertEqual(slot?.displayName, "Helius")
    }

    /// Chains with no `{KEY}` provider must return nil so the detail view does
    /// not offer a key field that goes nowhere.
    func test_apiKeySlot_isNilForChainsWithNoKeyedProvider() {
        let config = NetworkConfig.shared
        for chain in Chain.allCases where !chain.isEVM && chain != .solana {
            XCTAssertNil(config.apiKeySlot(forHost: "example.invalid", chain: chain),
                         "\(chain) has no {KEY} provider; the detail view must "
                         + "not offer a key field that goes nowhere.")
        }
    }

    /// The resolver and the UI must not keep two copies of the host switch:
    /// a drift between them means the field writes a key the resolver never
    /// reads. This pins substituteAPIKey to the slot accessor's routing.
    func test_substituteAPIKey_usesTheSlotRouting() {
        let config = NetworkConfig.shared
        let previous = config.getblockAPIKey
        defer { config.getblockAPIKey = previous }
        config.getblockAPIKey = "gb-test"
        let out = config.substituteAPIKey(in: "https://go.getblock.io/{KEY}/",
                                          chain: .polygon)
        XCTAssertEqual(out, "https://go.getblock.io/gb-test/")
    }

    /// Every keyed slot must round-trip through substituteAPIKey, so a slot
    /// the editor can write is always one the resolver reads back.
    ///
    /// Scope: this is a *drift* guard, not a routing-correctness guard. It
    /// derives the expected slot from `apiKeySlot` itself, so it stays green
    /// if a host is routed to the wrong-but-consistent slot — verified by
    /// mutation: deleting the getblock.io branch left this test passing, and
    /// `test_apiKeySlot_routesGetBlockToItsOwnField` is what caught it. What
    /// this does catch is `substituteAPIKey` growing a second copy of the host
    /// switch that disagrees with the accessor, which is the failure that
    /// would make the editor write a key the resolver never reads.
    func test_everyEVMSlot_isReadBackBySubstituteAPIKey() {
        let config = NetworkConfig.shared
        let hosts = ["mainnet.infura.io", "rpc.ankr.com", "base.blockpi.network",
                     "lb.drpc.org", "eth-mainnet.nodereal.io", "go.getblock.io",
                     "mainnet.gateway.tenderly.co", "1rpc.io", "rpc.example.invalid"]
        for host in hosts {
            guard let slot = config.apiKeySlot(forHost: host, chain: .ethereum) else {
                return XCTFail("EVM hosts always have a slot: \(host)")
            }
            let previous = config[keyPath: slot.keyPath]
            defer { config[keyPath: slot.keyPath] = previous }
            config[keyPath: slot.keyPath] = "slot-probe-\(slot.displayName)"
            let out = config.substituteAPIKey(in: "https://\(host)/{KEY}", chain: .ethereum)
            XCTAssertEqual(out, "https://\(host)/slot-probe-\(slot.displayName)",
                           "\(host) resolved to a different slot than the editor writes")
        }
    }
}
