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

    /// For every combination of (provider, hasKey, solDevnet, overridden) the
    /// instance `endpointSource(for:)` must agree with `resolveRawURL(for:)`:
    /// - `.override`    → resolveRawURL == stored override URL
    /// - `.provider(p)` → resolveRawURL == provider template
    /// - `.publicDefault` → resolveRawURL == publicDefault(for:)
    func test_endpointSource_agreesWithResolveRawURL_sweepAll() {
        withCleanConfig { config in
            let providers: [NodeProvider?] = [nil] + NodeProvider.allCases.map(Optional.some)
            for provider in providers {
                for hasKey in [false, true] {
                    for solDevnet in [false, true] {
                        for isOverridden in [false, true] {
                            self.assertAgreement(
                                config: config,
                                provider: provider,
                                hasKey: hasKey,
                                solDevnet: solDevnet,
                                isOverridden: isOverridden)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func assertAgreement(
        config: NetworkConfig,
        provider: NodeProvider?,
        hasKey: Bool,
        solDevnet: Bool,
        isOverridden: Bool,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        config.activeProvider = provider
        if let provider {
            config.setAPIKey(hasKey ? "test-key" : "", for: provider)
        }
        defer {
            // Restore key so the next call starts from the same baseline.
            if let provider { config.setAPIKey("", for: provider) }
        }
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
            let ctx = "provider=\(String(describing: provider)) hasKey=\(hasKey) "
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

    /// Snapshot and restore all global state touched during the agreement sweep.
    ///
    /// Follows the pattern from `EndpointResolutionTests.withCleanConfig`:
    /// keys are restored before `ethereumRPC`/`solanaRPC` because setting a key
    /// can trigger `autoSwapPaidPublicDefaultsOnKeyChange`; restoring the RPC
    /// URLs last undoes any auto-swap side effect.
    private func withCleanConfig(_ body: (NetworkConfig) -> Void) {
        let config = NetworkConfig.shared
        let savedProvider = config.activeProvider
        let savedChainId = config.evmChainId
        let savedDevnet = config.solDevnet
        let savedEthRPC = config.ethereumRPC
        let savedSolRPC = config.solanaRPC
        let savedKeys: [(NodeProvider, String)] = NodeProvider.allCases.map { ($0, config.apiKey(for: $0)) }
        defer {
            config.activeProvider = savedProvider
            config.evmChainId = savedChainId
            config.solDevnet = savedDevnet
            // Restore keys before RPC URLs — the key didSet may auto-swap them.
            restoreKeys(savedKeys, on: config)
            config.ethereumRPC = savedEthRPC
            config.solanaRPC = savedSolRPC
            ChainEndpointOverrides.shared.removeAll()
        }
        config.activeProvider = nil
        for provider in NodeProvider.allCases {
            config.setAPIKey("", for: provider)
        }
        ChainEndpointOverrides.shared.removeAll()
        body(config)
    }

    private func restoreKeys(_ saved: [(NodeProvider, String)], on config: NetworkConfig) {
        for (provider, value) in saved {
            config.setAPIKey(value, for: provider)
        }
    }
}
