import XCTest
@testable import Horcrux

/// Tests for `EndpointSource` and `NetworkConfig.endpointSource(for:)`.
///
/// Two sections:
/// 1. **Pure classifier** — calls the static function only; no singletons, no
///    Keychain reads. Safe to run offline and in any order.
/// 2. **Agreement sweep** — verifies that `config.endpointSource(for:)` agrees
///    with what `config.resolveRawURL(for:)` actually returns, swept over
///    provider ∈ {nil} ∪ all 8, hasKey ∈ {false, true},
///    solDevnet ∈ {false, true}, overridden ∈ {false, true}.
final class EndpointSourceTests: XCTestCase {

    // MARK: - State hygiene

    private var savedOverrides: [String: String] = [:]

    override func setUp() {
        super.setUp()
        savedOverrides = ChainEndpointOverrides.shared.snapshot()
        ChainEndpointOverrides.shared.removeAll()
    }

    override func tearDown() {
        ChainEndpointOverrides.shared.removeAll()
        for (raw, url) in savedOverrides {
            guard let chain = Chain(rawValue: raw) else { continue }
            ChainEndpointOverrides.shared.set(url, for: chain)
        }
        super.tearDown()
    }

    // MARK: - Pure classifier (no singletons)

    func test_classifier_overrideBeatsProvider() {
        let source = NetworkConfig.endpointSource(
            for: .ethereum,
            isOverridden: true,
            provider: .alchemy,
            hasKey: true,
            evmChainId: 1,
            solanaMainnet: true)
        XCTAssertEqual(source, .override)
    }

    func test_classifier_overrideBeatsMissingKey() {
        // An override wins even when no key is configured.
        let source = NetworkConfig.endpointSource(
            for: .ethereum,
            isOverridden: true,
            provider: .alchemy,
            hasKey: false,
            evmChainId: 1,
            solanaMainnet: true)
        XCTAssertEqual(source, .override)
    }

    func test_classifier_overrideBeatsNilProvider() {
        // An override wins even when no provider is selected.
        let source = NetworkConfig.endpointSource(
            for: .bitcoin,
            isOverridden: true,
            provider: nil,
            hasKey: false,
            evmChainId: 1,
            solanaMainnet: true)
        XCTAssertEqual(source, .override)
    }

    func test_classifier_missingKeyFallsToPublicDefault() {
        let source = NetworkConfig.endpointSource(
            for: .ethereum,
            isOverridden: false,
            provider: .alchemy,
            hasKey: false,
            evmChainId: 1,
            solanaMainnet: true)
        XCTAssertEqual(source, .publicDefault)
    }

    func test_classifier_nilProviderFallsToPublicDefault() {
        let source = NetworkConfig.endpointSource(
            for: .ethereum,
            isOverridden: false,
            provider: nil,
            hasKey: false,
            evmChainId: 1,
            solanaMainnet: true)
        XCTAssertEqual(source, .publicDefault)
    }

    func test_classifier_providerThatDoesNotServeChainFallsToPublicDefault() {
        // Alchemy has no BNB product; it must not shadow the public default.
        let sourceBNB = NetworkConfig.endpointSource(
            for: .bnb,
            isOverridden: false,
            provider: .alchemy,
            hasKey: true,
            evmChainId: 1,
            solanaMainnet: true)
        XCTAssertEqual(sourceBNB, .publicDefault)

        // No provider in the enum serves Bitcoin, Litecoin, or Tron.
        for chain in [Chain.bitcoin, .litecoin, .tron] {
            for provider in NodeProvider.allCases {
                let source = NetworkConfig.endpointSource(
                    for: chain,
                    isOverridden: false,
                    provider: provider,
                    hasKey: true,
                    evmChainId: 1,
                    solanaMainnet: true)
                XCTAssertEqual(source, .publicDefault,
                    "\(provider) must not claim \(chain)")
            }
        }
    }

    func test_classifier_keyedProviderThatCoversChainReturnsProvider() {
        let source = NetworkConfig.endpointSource(
            for: .base,
            isOverridden: false,
            provider: .alchemy,
            hasKey: true,
            evmChainId: 1,
            solanaMainnet: true)
        XCTAssertEqual(source, .provider(.alchemy))
    }

    func test_classifier_solanaMainnet_usesAnkr() {
        // Ankr has a Solana mainnet host.
        let source = NetworkConfig.endpointSource(
            for: .solana,
            isOverridden: false,
            provider: .ankr,
            hasKey: true,
            evmChainId: 1,
            solanaMainnet: true)
        XCTAssertEqual(source, .provider(.ankr))
    }

    func test_classifier_solanaDevnet_fallsToPublicDefaultForAnkr() {
        // Ankr has no devnet Solana host — it must not route devnet users to mainnet.
        let source = NetworkConfig.endpointSource(
            for: .solana,
            isOverridden: false,
            provider: .ankr,
            hasKey: true,
            evmChainId: 1,
            solanaMainnet: false)           // devnet
        XCTAssertEqual(source, .publicDefault,
            "Ankr has no devnet Solana host; must fall through to public default")
    }

    func test_classifier_solanaDevnet_usesAlchemy() {
        // Alchemy has both mainnet and devnet Solana hosts.
        let source = NetworkConfig.endpointSource(
            for: .solana,
            isOverridden: false,
            provider: .alchemy,
            hasKey: true,
            evmChainId: 1,
            solanaMainnet: false)           // devnet
        XCTAssertEqual(source, .provider(.alchemy),
            "Alchemy has a devnet Solana host; must return .provider(.alchemy)")
    }

    func test_classifier_solanaMainnetVsDevnet_differ_forAnkr() {
        // Regression: confirms the two Solana cluster paths produce different results.
        let mainnet = NetworkConfig.endpointSource(
            for: .solana, isOverridden: false, provider: .ankr,
            hasKey: true, evmChainId: 1, solanaMainnet: true)
        let devnet = NetworkConfig.endpointSource(
            for: .solana, isOverridden: false, provider: .ankr,
            hasKey: true, evmChainId: 1, solanaMainnet: false)
        XCTAssertNotEqual(mainnet, devnet,
            "Ankr mainnet vs devnet must produce different EndpointSource values")
    }

    // MARK: - Agreement sweep: endpointSource must agree with resolveRawURL

    /// For the nil-provider path and every keyed-provider path, the pair
    /// `(config.endpointSource(for:), config.resolveRawURL(for:))` must agree:
    /// - `.override`      → resolveRawURL == stored override URL
    /// - `.provider(p)`   → resolveRawURL == provider template
    /// - `.publicDefault` → resolveRawURL == publicDefault(for:)
    ///
    /// After Fix 1 these two functions project from a single `resolved(for:)`
    /// call, so disagreement is structurally impossible. The sweep remains
    /// valuable as an integration guard: it verifies that the URL returned by
    /// `resolved` equals the *independently recomputed* template, catching bugs
    /// in the template wiring or the `solanaMainnet` inversion.
    ///
    /// Keychain hygiene:
    /// - The **nil-provider pass** requires no key writes at all.
    /// - The **keyed pass** overwrites one provider's key at a time (never
    ///   blanks it to "") and restores it immediately before the next provider,
    ///   so at most one key differs from the developer's real value at any instant.
    /// - `(provider ≠ nil, hasKey == false)` is not swept here because it
    ///   classifies identically to `provider == nil` for every chain; that
    ///   logic is already covered by the pure-classifier tests above and
    ///   blanking all keys to prove it adds no new coverage.
    func test_endpointSource_agreesWithResolveRawURL_sweepAll() {
        let config = NetworkConfig.shared
        let savedProvider = config.activeProvider
        let savedChainId  = config.evmChainId
        let savedDevnet   = config.solDevnet
        let savedEthRPC   = config.ethereumRPC
        let savedSolRPC   = config.solanaRPC
        let savedKeys: [(NodeProvider, String)] = NodeProvider.allCases.map { ($0, config.apiKey(for: $0)) }
        defer {
            config.activeProvider = savedProvider
            config.evmChainId     = savedChainId
            config.solDevnet      = savedDevnet
            // Keys before RPC URLs: key didSet may trigger autoSwap.
            restoreKeys(savedKeys, on: config)
            config.ethereumRPC = savedEthRPC
            config.solanaRPC   = savedSolRPC
            ChainEndpointOverrides.shared.removeAll()
        }
        config.evmChainId = 1   // mainnet; predictable Ethereum behaviour

        // --- Pass A: no provider — no key writes at all ---
        config.activeProvider = nil
        for solDevnet in [false, true] {
            for isOverridden in [false, true] {
                assertAgreement(config: config, provider: nil, solDevnet: solDevnet, isOverridden: isOverridden)
            }
        }

        // --- Pass B: each provider keyed; one key overwritten at a time ---
        for (provider, savedKey) in savedKeys {
            // Overwrite this provider's key with a test sentinel.
            // The real value is in `savedKey`; we restore it synchronously
            // at the end of the iteration so only one key ever differs from
            // the developer's real state at a time.
            config.setAPIKey("test-key", for: provider)
            config.activeProvider = provider
            for solDevnet in [false, true] {
                for isOverridden in [false, true] {
                    assertAgreement(config: config, provider: provider, solDevnet: solDevnet, isOverridden: isOverridden)
                }
            }
            config.setAPIKey(savedKey, for: provider)   // restore before next iteration
        }
        config.activeProvider = nil
    }

    // MARK: - Helpers

    /// Asserts agreement between `endpointSource(for:)` and `resolveRawURL(for:)`
    /// across all 14 chains. Caller is responsible for setting `activeProvider`
    /// and the associated API key; this function only manages `solDevnet` and
    /// per-chain overrides.
    private func assertAgreement(
        config: NetworkConfig,
        provider: NodeProvider?,
        solDevnet: Bool,
        isOverridden: Bool,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        config.solDevnet = solDevnet

        for chain in Chain.allCases {
            ChainEndpointOverrides.shared.removeAll()
            if isOverridden {
                // Use shortCode to keep the URL free of spaces.
                ChainEndpointOverrides.shared.set(
                    "https://test-override.\(chain.shortCode.lowercased()).example",
                    for: chain)
            }

            let source = config.endpointSource(for: chain)
            let rawURL = config.resolveRawURL(for: chain)
            let ctx = "provider=\(String(describing: provider)) "
                + "solDevnet=\(solDevnet) overridden=\(isOverridden) chain=\(chain)"

            switch source {
            case .override:
                let stored = ChainEndpointOverrides.shared.url(for: chain)
                XCTAssertNotNil(stored,
                    "\(ctx): source=.override but url(for:) is nil",
                    file: file, line: line)
                XCTAssertEqual(rawURL, stored,
                    "\(ctx): .override → resolveRawURL must equal the stored override URL",
                    file: file, line: line)
            case .provider(let p):
                let template = p.template(for: chain,
                                           evmChainId: config.evmChainId,
                                           solanaMainnet: !config.solDevnet)
                XCTAssertNotNil(template,
                    "\(ctx): source=.provider(\(p)) but template(for:) is nil",
                    file: file, line: line)
                XCTAssertEqual(rawURL, template,
                    "\(ctx): .provider → resolveRawURL must equal the provider template",
                    file: file, line: line)
            case .publicDefault:
                XCTAssertEqual(rawURL, config.publicDefault(for: chain),
                    "\(ctx): .publicDefault → resolveRawURL must equal publicDefault(for:)",
                    file: file, line: line)
            }
        }
    }

    private func restoreKeys(_ saved: [(NodeProvider, String)], on config: NetworkConfig) {
        for (provider, value) in saved {
            config.setAPIKey(value, for: provider)
        }
    }
}
