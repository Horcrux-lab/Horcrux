import XCTest
@testable import Horcrux

/// Regression tests for the provider-first node settings refactor.
///
/// These tests prove that the settings screen now writes to things that are
/// actually read, and that the dead legacy path (`config.ethereumRPC` etc.)
/// has no effect on `config.rpcURL(for:)`.
///
/// Hygiene rules (matching the rest of this suite):
/// - Snapshot and restore ChainEndpointOverrides; never blank it.
/// - Snapshot and restore every API key that is mutated; never write "".
/// - Snapshot and restore config toggles (evmChainId, btcTestnet, solDevnet).
/// - The URL fields (ethereumRPC, solanaRPC, bitcoinAPI) are restored because
///   mutating them may trigger autoSwap side-effects that persist beyond the test.
final class NodeSettingsV2RegressionTests: XCTestCase {

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

    // MARK: - Regression: dead field path

    /// The bug this refactor fixes: writing to `config.ethereumRPC` used to be
    /// the only way the settings screen could change what `rpcURL(for:)` returned.
    /// Now that `resolveRawURL` goes through `ChainEndpointOverrides → provider →
    /// publicDefault`, writing to `ethereumRPC` must have NO effect on routing.
    ///
    /// This test would have caught the regression if it had existed before.
    func test_writingToEthereumRPC_doesNotAffectRPCURL() {
        let config = NetworkConfig.shared
        let savedEthRPC = config.ethereumRPC
        let savedChainId = config.evmChainId
        let savedProvider = config.activeProvider
        defer {
            config.ethereumRPC = savedEthRPC
            config.evmChainId = savedChainId
            config.activeProvider = savedProvider
        }

        config.activeProvider = nil
        config.evmChainId = 1  // mainnet
        ChainEndpointOverrides.shared.removeAll()

        // Write a sentinel to the legacy field.
        config.ethereumRPC = "https://legacy-dead-field.example"

        // The routing layer must NOT return the legacy field value.
        let resolved = config.rpcURL(for: .ethereum)
        XCTAssertFalse(
            resolved.contains("legacy-dead-field.example"),
            "rpcURL must not route through the legacy ethereumRPC field. Got: \(resolved)"
        )
    }

    /// The positive case: writing through the correct path (ChainEndpointOverrides)
    /// MUST be reflected by `rpcURL(for:)`.
    func test_overridePathTakesEffect_onRPCURL() {
        let config = NetworkConfig.shared
        let savedProvider = config.activeProvider
        defer {
            config.activeProvider = savedProvider
        }

        config.activeProvider = nil
        ChainEndpointOverrides.shared.removeAll()

        // Write through the new correct path.
        ChainEndpointOverrides.shared.set("https://my-own-ethereum.example", for: .ethereum)

        // The resolved URL must reflect the override.
        let resolved = config.resolveRawURL(for: .ethereum)
        XCTAssertEqual(resolved, "https://my-own-ethereum.example",
                       "resolveRawURL must return the ChainEndpointOverride, not a legacy field")

        // rpcURL may substitute {KEY} but the host must be present.
        let rpc = config.rpcURL(for: .ethereum)
        XCTAssertTrue(rpc.contains("my-own-ethereum.example"),
                      "rpcURL must route through the override. Got: \(rpc)")
    }

    /// Dead-field writes for all five chains that used to have dedicated fields.
    /// Each must be ignored by the routing layer.
    func test_legacyFields_areIgnoredByRouting_forAllFiveChains() {
        let config = NetworkConfig.shared
        let savedEthRPC = config.ethereumRPC
        let savedBtcAPI = config.bitcoinAPI
        let savedLtcAPI = config.litecoinAPI
        let savedSolRPC = config.solanaRPC
        let savedTronAPI = config.tronAPI
        let savedProvider = config.activeProvider
        let savedChainId = config.evmChainId
        let savedBtcTestnet = config.btcTestnet
        let savedSolDevnet = config.solDevnet
        defer {
            config.ethereumRPC = savedEthRPC
            config.bitcoinAPI = savedBtcAPI
            config.litecoinAPI = savedLtcAPI
            config.solanaRPC = savedSolRPC
            config.tronAPI = savedTronAPI
            config.activeProvider = savedProvider
            config.evmChainId = savedChainId
            config.btcTestnet = savedBtcTestnet
            config.solDevnet = savedSolDevnet
        }

        config.activeProvider = nil
        config.evmChainId = 1
        config.btcTestnet = false
        config.solDevnet = false
        ChainEndpointOverrides.shared.removeAll()

        let sentinel = "not-used"
        config.ethereumRPC = "https://\(sentinel).eth"
        config.bitcoinAPI = "https://\(sentinel).btc"
        config.litecoinAPI = "https://\(sentinel).ltc"
        config.solanaRPC = "https://\(sentinel).sol"
        config.tronAPI = "https://\(sentinel).tron"

        let legacyChains: [(Chain, String)] = [
            (.ethereum, config.ethereumRPC),
            (.bitcoin, config.bitcoinAPI),
            (.litecoin, config.litecoinAPI),
            (.solana, config.solanaRPC),
            (.tron, config.tronAPI)
        ]

        for (chain, _) in legacyChains {
            let resolved = config.rpcURL(for: chain)
            XCTAssertFalse(
                resolved.contains(sentinel),
                "\(chain): rpcURL must not return the legacy field value. Got: \(resolved)"
            )
        }
    }

    // MARK: - Helius override round-trip

    /// The "Use Helius" button now writes a Solana override instead of
    /// `config.solanaRPC`. After the override is set, `rpcURL(for: .solana)`
    /// must contain the Helius host and must NOT contain a literal `{KEY}`.
    ///
    /// This matches the UI path: the button calls
    /// `ChainEndpointOverrides.shared.set(RPCProviderTemplate.helius(mainnet:), for: .solana)`
    /// and `substituteAPIKey` recognises the helius-rpc.com host and pulls
    /// `heliusAPIKey` from Keychain (or in-memory when unsigned).
    func test_heliusOverrideRoundTrip_hostPresentKeySubstituted() {
        let config = NetworkConfig.shared
        let savedKey = config.heliusAPIKey
        let savedDevnet = config.solDevnet
        // Do NOT write "" — that deletes the Keychain item.
        // Use a non-empty sentinel: Keychain write fails silently under the
        // unsigned simulator, but the in-memory @Published value is set.
        defer {
            // Restore original value only if it was non-empty; otherwise
            // restoring the original empty state is fine.
            if !savedKey.isEmpty {
                config.heliusAPIKey = savedKey
            } else {
                // Set any non-empty value temporarily then delete via Keychain
                // path — but since Keychain fails -34018 anyway, just ensure
                // in-memory is back to empty by setting the saved empty value.
                config.heliusAPIKey = savedKey  // ""
            }
            config.solDevnet = savedDevnet
        }

        config.solDevnet = false  // mainnet
        config.heliusAPIKey = "test-helius-sentinel"

        // Simulate the "Use Helius" button action.
        ChainEndpointOverrides.shared.set(
            RPCProviderTemplate.helius(mainnet: !config.solDevnet),
            for: .solana)

        let rawURL = config.resolveRawURL(for: .solana)
        XCTAssertTrue(rawURL.contains("helius-rpc.com"),
                      "resolveRawURL must return the Helius template. Got: \(rawURL)")
        XCTAssertTrue(rawURL.contains("{KEY}"),
                      "resolveRawURL should contain the placeholder before substitution: \(rawURL)")

        let rpcURL = config.rpcURL(for: .solana)
        XCTAssertTrue(rpcURL.contains("helius-rpc.com"),
                      "rpcURL must route to Helius host. Got: \(rpcURL)")
        XCTAssertFalse(rpcURL.contains("{KEY}"),
                       "rpcURL must not contain a literal {KEY} — substituteAPIKey must have run. Got: \(rpcURL)")
    }

    /// Helius devnet path works the same way.
    func test_heliusDevnetOverrideRoundTrip() {
        let config = NetworkConfig.shared
        let savedKey = config.heliusAPIKey
        let savedDevnet = config.solDevnet
        defer {
            config.heliusAPIKey = savedKey
            config.solDevnet = savedDevnet
        }

        config.solDevnet = true  // devnet
        config.heliusAPIKey = "test-helius-devnet"

        ChainEndpointOverrides.shared.set(
            RPCProviderTemplate.helius(mainnet: !config.solDevnet),
            for: .solana)

        let rpcURL = config.rpcURL(for: .solana)
        XCTAssertTrue(rpcURL.contains("devnet.helius-rpc.com"),
                      "devnet path must point at the devnet host. Got: \(rpcURL)")
        XCTAssertFalse(rpcURL.contains("{KEY}"),
                       "rpcURL must not contain literal {KEY}. Got: \(rpcURL)")
    }

    // MARK: - Preset behaviour

    /// `applyPreset` sets the three network toggles. URL fields update
    /// via their `didSet` auto-swap helpers (not via explicit writes in
    /// `applyPreset` any more).
    func test_applyPreset_testnet_setsTogglesAndRPCURLsFollowForUnoverriddenChains() {
        let config = NetworkConfig.shared
        let savedEthRPC = config.ethereumRPC
        let savedBtcAPI = config.bitcoinAPI
        let savedSolRPC = config.solanaRPC
        let savedChainId = config.evmChainId
        let savedBtcTestnet = config.btcTestnet
        let savedSolDevnet = config.solDevnet
        let savedProvider = config.activeProvider
        defer {
            config.activeProvider = savedProvider
            config.evmChainId = savedChainId
            config.btcTestnet = savedBtcTestnet
            config.solDevnet = savedSolDevnet
            config.ethereumRPC = savedEthRPC
            config.bitcoinAPI = savedBtcAPI
            config.solanaRPC = savedSolRPC
        }

        config.activeProvider = nil
        ChainEndpointOverrides.shared.removeAll()
        // Start from mainnet
        config.applyPreset(.mainnet)

        config.applyPreset(.testnet)

        // Toggles must match testnet preset.
        XCTAssertEqual(config.evmChainId, NetworkPreset.testnet.evmChainId)
        XCTAssertTrue(config.btcTestnet)
        XCTAssertTrue(config.solDevnet)

        // rpcURL for un-overridden chains must reflect the new network.
        // Ethereum: Sepolia public default (no key in test env).
        let ethURL = config.rpcURL(for: .ethereum)
        XCTAssertTrue(
            ethURL.contains("sepolia") || ethURL.contains("11155111"),
            "Ethereum rpcURL after testnet preset must be a Sepolia URL. Got: \(ethURL)"
        )
        XCTAssertFalse(ethURL.isEmpty)

        // Bitcoin: testnet API
        XCTAssertEqual(config.rpcURL(for: .bitcoin), "https://mempool.space/testnet/api")

        // Solana: devnet public default
        let solURL = config.rpcURL(for: .solana)
        XCTAssertTrue(
            solURL.contains("devnet"),
            "Solana rpcURL after testnet preset must be a devnet URL. Got: \(solURL)"
        )
    }

    /// Pin the override-wins decision: if the user has a Solana override and
    /// taps the Testnet preset, the override survives and traffic still goes
    /// to the overridden URL (not silently cleared).
    ///
    /// The badge correctly shows "Custom" for that chain, which is honest:
    /// the user has an explicit custom URL that may or may not match the
    /// selected network. They can clear it manually from the chain detail view.
    func test_applyPreset_leavesExistingOverridesIntact() {
        let config = NetworkConfig.shared
        let savedChainId = config.evmChainId
        let savedDevnet = config.solDevnet
        let savedBtcTestnet = config.btcTestnet
        let savedProvider = config.activeProvider
        let savedEthRPC = config.ethereumRPC
        let savedBtcAPI = config.bitcoinAPI
        let savedSolRPC = config.solanaRPC
        defer {
            config.activeProvider = savedProvider
            config.evmChainId = savedChainId
            config.btcTestnet = savedBtcTestnet
            config.solDevnet = savedDevnet
            config.ethereumRPC = savedEthRPC
            config.bitcoinAPI = savedBtcAPI
            config.solanaRPC = savedSolRPC
        }

        config.activeProvider = nil
        ChainEndpointOverrides.shared.removeAll()
        config.applyPreset(.mainnet)

        // User explicitly sets a Solana override (mainnet custom node).
        let customSolURL = "https://my-self-hosted-solana.example"
        ChainEndpointOverrides.shared.set(customSolURL, for: .solana)

        // User taps "Testnet" preset.
        config.applyPreset(.testnet)

        // The preset must not clear the override.
        XCTAssertEqual(
            ChainEndpointOverrides.shared.url(for: .solana), customSolURL,
            "applyPreset must not silently clear existing chain overrides"
        )

        // Traffic for the overridden chain still goes to the custom URL.
        let solRPCAfterPreset = config.rpcURL(for: .solana)
        XCTAssertTrue(
            solRPCAfterPreset.contains("my-self-hosted-solana.example"),
            "rpcURL must follow the override, not the preset. Got: \(solRPCAfterPreset)"
        )

        // The endpoint source for the overridden chain must be .override.
        XCTAssertEqual(config.endpointSource(for: .solana), .override,
                       "Source must be .override when an override is set, regardless of preset")
    }

    // MARK: - Chain-level reset via overrides

    /// "Reset this chain" in the UI calls `ChainEndpointOverrides.shared.clear(chain)`.
    /// After clearing, `resolveRawURL` must fall back to provider or public default.
    func test_clearOverride_fallsBackToPublicDefault() {
        let config = NetworkConfig.shared
        let savedProvider = config.activeProvider
        defer {
            config.activeProvider = savedProvider
        }

        config.activeProvider = nil

        ChainEndpointOverrides.shared.set("https://custom.example", for: .polygon)
        XCTAssertEqual(config.endpointSource(for: .polygon), .override)

        ChainEndpointOverrides.shared.clear(.polygon)
        let source = config.endpointSource(for: .polygon)
        XCTAssertEqual(source, .publicDefault,
                       "After clearing, source must fall back to publicDefault (no key configured). Got: \(source)")
    }
}
