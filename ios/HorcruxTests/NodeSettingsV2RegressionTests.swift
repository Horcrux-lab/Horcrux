import XCTest
@testable import Horcrux

/// Regression tests for the provider-first node settings refactor.
///
/// These tests prove that the settings screen now writes to things that are
/// actually read, and that the dead legacy path (`config.legacyEthereumRPC` etc.)
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

    /// The bug this refactor fixes: writing to `config.legacyEthereumRPC` used to be
    /// the only way the settings screen could change what `rpcURL(for:)` returned.
    /// Now that `resolveRawURL` goes through `ChainEndpointOverrides → provider →
    /// publicDefault`, writing to `ethereumRPC` must have NO effect on routing.
    ///
    /// This test would have caught the regression if it had existed before.
    func test_writingToEthereumRPC_doesNotAffectRPCURL() {
        let config = NetworkConfig.shared
        let savedEthRPC = config.legacyEthereumRPC
        let savedChainId = config.evmChainId
        let savedProvider = config.activeProvider
        defer {
            config.legacyEthereumRPC = savedEthRPC
            config.evmChainId = savedChainId
            config.activeProvider = savedProvider
        }

        config.activeProvider = nil
        config.evmChainId = 1  // mainnet
        ChainEndpointOverrides.shared.removeAll()

        // Write a sentinel to the legacy field.
        config.legacyEthereumRPC = "https://legacy-dead-field.example"

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
        let savedEthRPC = config.legacyEthereumRPC
        let savedBtcAPI = config.legacyBitcoinAPI
        let savedLtcAPI = config.legacyLitecoinAPI
        let savedSolRPC = config.legacySolanaRPC
        let savedTronAPI = config.legacyTronAPI
        let savedProvider = config.activeProvider
        let savedChainId = config.evmChainId
        let savedBtcTestnet = config.btcTestnet
        let savedSolDevnet = config.solDevnet
        defer {
            config.legacyEthereumRPC = savedEthRPC
            config.legacyBitcoinAPI = savedBtcAPI
            config.legacyLitecoinAPI = savedLtcAPI
            config.legacySolanaRPC = savedSolRPC
            config.legacyTronAPI = savedTronAPI
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
        config.legacyEthereumRPC = "https://\(sentinel).eth"
        config.legacyBitcoinAPI = "https://\(sentinel).btc"
        config.legacyLitecoinAPI = "https://\(sentinel).ltc"
        config.legacySolanaRPC = "https://\(sentinel).sol"
        config.legacyTronAPI = "https://\(sentinel).tron"

        let legacyChains: [(Chain, String)] = [
            (.ethereum, config.legacyEthereumRPC),
            (.bitcoin, config.legacyBitcoinAPI),
            (.litecoin, config.legacyLitecoinAPI),
            (.solana, config.legacySolanaRPC),
            (.tron, config.legacyTronAPI)
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
    /// `config.legacySolanaRPC`. After the override is set, `rpcURL(for: .solana)`
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
        let savedEthRPC = config.legacyEthereumRPC
        let savedBtcAPI = config.legacyBitcoinAPI
        let savedSolRPC = config.legacySolanaRPC
        let savedChainId = config.evmChainId
        let savedBtcTestnet = config.btcTestnet
        let savedSolDevnet = config.solDevnet
        let savedProvider = config.activeProvider
        defer {
            config.activeProvider = savedProvider
            config.evmChainId = savedChainId
            config.btcTestnet = savedBtcTestnet
            config.solDevnet = savedSolDevnet
            config.legacyEthereumRPC = savedEthRPC
            config.legacyBitcoinAPI = savedBtcAPI
            config.legacySolanaRPC = savedSolRPC
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
        let savedEthRPC = config.legacyEthereumRPC
        let savedBtcAPI = config.legacyBitcoinAPI
        let savedSolRPC = config.legacySolanaRPC
        defer {
            config.activeProvider = savedProvider
            config.evmChainId = savedChainId
            config.btcTestnet = savedBtcTestnet
            config.solDevnet = savedDevnet
            config.legacyEthereumRPC = savedEthRPC
            config.legacyBitcoinAPI = savedBtcAPI
            config.legacySolanaRPC = savedSolRPC
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

    // MARK: - Read-side regression: legacy fields are not the money path

    /// Setting an override updates `rpcURL(for:)` for ALL four non-EVM chains
    /// that had dedicated legacy fields. The second assertion in each case
    /// documents that the legacy stored property is now a stale shadow:
    /// any code reading it directly is reading the wrong thing.
    ///
    /// This test would have caught the read-side regression that was
    /// introduced when the write side was fixed (Task 12 follow-up).
    func test_overrideReflected_inRPCURL_forAllFourLegacyChains() {
        let config = NetworkConfig.shared
        let savedBtcAPI = config.legacyBitcoinAPI
        let savedLtcAPI = config.legacyLitecoinAPI
        let savedSolRPC = config.legacySolanaRPC
        let savedTronAPI = config.legacyTronAPI
        let savedProvider = config.activeProvider
        let savedBtcTestnet = config.btcTestnet
        let savedSolDevnet = config.solDevnet
        defer {
            config.activeProvider = savedProvider
            config.btcTestnet = savedBtcTestnet
            config.solDevnet = savedSolDevnet
            config.legacyBitcoinAPI = savedBtcAPI
            config.legacyLitecoinAPI = savedLtcAPI
            config.legacySolanaRPC = savedSolRPC
            config.legacyTronAPI = savedTronAPI
        }

        config.activeProvider = nil
        config.btcTestnet = false
        config.solDevnet = false
        ChainEndpointOverrides.shared.removeAll()

        let cases: [(Chain, String, KeyPath<NetworkConfig, String>)] = [
            (.bitcoin,  "https://btc-sentinel.example",  \.legacyBitcoinAPI),
            (.litecoin, "https://ltc-sentinel.example",  \.legacyLitecoinAPI),
            (.solana,   "https://sol-sentinel.example",  \.legacySolanaRPC),
            (.tron,     "https://tron-sentinel.example", \.legacyTronAPI),
        ]

        for (chain, sentinel, legacyKP) in cases {
            // Write through the correct new path.
            ChainEndpointOverrides.shared.set(sentinel, for: chain)

            // rpcURL must reflect the override.
            let resolved = config.rpcURL(for: chain)
            XCTAssertTrue(resolved.contains(sentinel.replacingOccurrences(of: "https://", with: "")),
                "[\(chain)] rpcURL must return the override URL. Got: \(resolved)")

            // The legacy stored property must NOT equal the override —
            // it is a stale shadow. Code that reads it directly is reading
            // the wrong thing. Do NOT simplify away this assertion.
            let legacyValue = config[keyPath: legacyKP]
            XCTAssertNotEqual(legacyValue, sentinel,
                "[\(chain)] legacy field \(legacyKP) must not equal the override — " +
                "it is a stale shadow; any caller reading it is on the wrong path. " +
                "Got: \(legacyValue)")

            ChainEndpointOverrides.shared.clear(chain)
        }
    }

    /// Bitcoin and Solana separately: override takes effect where a clear
    /// returns to the public default. Covers the two chains used in mutation
    /// verification below.
    func test_bitcoinOverride_resolves_andLegacyFieldIsStale() {
        let config = NetworkConfig.shared
        let savedBtcAPI = config.legacyBitcoinAPI
        let savedBtcTestnet = config.btcTestnet
        let savedProvider = config.activeProvider
        defer {
            config.activeProvider = savedProvider
            config.btcTestnet = savedBtcTestnet
            config.legacyBitcoinAPI = savedBtcAPI
        }

        config.activeProvider = nil
        config.btcTestnet = false
        ChainEndpointOverrides.shared.removeAll()

        let sentinel = "https://btc-override-test.example"
        ChainEndpointOverrides.shared.set(sentinel, for: .bitcoin)

        // The money path must use the override.
        XCTAssertTrue(config.rpcURL(for: .bitcoin).contains("btc-override-test.example"),
            "rpcURL(for: .bitcoin) must return the override. Got: \(config.rpcURL(for: .bitcoin))")

        // The legacy field is a stale shadow — do NOT read it on the money path.
        XCTAssertNotEqual(config.legacyBitcoinAPI, sentinel,
            "bitcoinAPI must not equal the override — it is a stale shadow. Got: \(config.legacyBitcoinAPI)")
    }

    func test_solanaOverride_resolves_andLegacyFieldIsStale() {
        let config = NetworkConfig.shared
        let savedSolRPC = config.legacySolanaRPC
        let savedSolDevnet = config.solDevnet
        let savedProvider = config.activeProvider
        defer {
            config.activeProvider = savedProvider
            config.solDevnet = savedSolDevnet
            config.legacySolanaRPC = savedSolRPC
        }

        config.activeProvider = nil
        config.solDevnet = false
        ChainEndpointOverrides.shared.removeAll()

        let sentinel = "https://sol-override-test.example"
        ChainEndpointOverrides.shared.set(sentinel, for: .solana)

        XCTAssertTrue(config.rpcURL(for: .solana).contains("sol-override-test.example"),
            "rpcURL(for: .solana) must return the override. Got: \(config.rpcURL(for: .solana))")

        // The legacy field is a stale shadow — do NOT read it on the money path.
        XCTAssertNotEqual(config.legacySolanaRPC, sentinel,
            "solanaRPC must not equal the override — it is a stale shadow. Got: \(config.legacySolanaRPC)")
    }

    // MARK: - Critical 1: ChainEndpointEditor structural invariant

    /// `ChainEndpointEditor` owns the draft URL and exposes mutations as
    /// atomic methods. The invariant is structural: any override mutation goes
    /// through the editor, so draft and storage are always consistent. This test
    /// proves the core guarantee: reset() + commit() cannot resurrect a cleared
    /// override, because reset() leaves draft == "" == stored.
    ///
    /// Mutation target: remove `draft = ""` from `reset()` to verify this test
    /// goes RED (commit() would find draft="old" != stored="" and write it back).
    func test_editor_resetThenCommit_doesNotResurrectOverride() {
        let overrides = ChainEndpointOverrides.shared
        overrides.set("https://old.example", for: .bitcoin)
        defer { overrides.clear(.bitcoin) }

        let editor = ChainEndpointEditor(chain: .bitcoin)
        XCTAssertEqual(editor.draft, "https://old.example",
                       "editor must seed draft from stored override")

        editor.reset()
        XCTAssertEqual(editor.draft, "",
                       "reset() must set draft to empty")
        XCTAssertNil(overrides.url(for: .bitcoin),
                     "reset() must clear the stored override")

        // Without the atomicity guarantee, commit() would see draft="old.example"
        // != stored="" and write the stale value straight back. With the editor,
        // both are "" so commit() is a no-op.
        editor.commit()
        XCTAssertNil(overrides.url(for: .bitcoin),
                     "commit() after reset() must not resurrect the override")
    }

    func test_editor_select_updatesDraftAndOverrideAtomically() {
        let overrides = ChainEndpointOverrides.shared
        defer { overrides.clear(.bitcoin) }

        let editor = ChainEndpointEditor(chain: .bitcoin)
        editor.select(url: "https://new.example")

        XCTAssertEqual(editor.draft, "https://new.example",
                       "select() must update draft")
        XCTAssertEqual(overrides.url(for: .bitcoin), "https://new.example",
                       "select() must update stored override")
    }

    func test_editor_commit_trimsAndPersistsDraft() {
        let overrides = ChainEndpointOverrides.shared
        defer { overrides.clear(.bitcoin) }

        let editor = ChainEndpointEditor(chain: .bitcoin)
        editor.draft = "  https://trimmed.example  "
        editor.commit()

        XCTAssertEqual(overrides.url(for: .bitcoin), "https://trimmed.example",
                       "commit() must trim and persist changed draft")
        XCTAssertEqual(editor.draft, "https://trimmed.example",
                       "commit() must normalise whitespace in the displayed draft")
    }

    func test_editor_commit_isNoOp_whenDraftMatchesStored() {
        let overrides = ChainEndpointOverrides.shared
        overrides.set("https://existing.example", for: .bitcoin)
        defer { overrides.clear(.bitcoin) }

        let editor = ChainEndpointEditor(chain: .bitcoin)
        // Draft is seeded from storage — commit() should find no diff.
        editor.commit()

        XCTAssertEqual(overrides.url(for: .bitcoin), "https://existing.example",
                       "commit() must not write when draft already matches stored URL")
    }

    // MARK: - Critical 2: resetToDefaults clears overrides and provider

    /// `resetToDefaults` must clear ALL per-chain overrides and set
    /// `activeProvider = nil`. Without this, routing still goes through
    /// overrides/provider after the "Reset to Defaults" confirmation —
    /// the UI promises "all RPC URLs to default public nodes" but traffic
    /// continues to flow through the user's custom endpoint or paid provider.
    ///
    /// API keys must NOT be cleared — keys are credentials, not routing
    /// state. The provider is deactivated (routing falls through to public
    /// default), but the key is preserved for re-activation.
    func test_resetToDefaults_clearsOverridesAndProvider_preservesKeys() {
        let config = NetworkConfig.shared
        let savedProvider = config.activeProvider
        let savedEthRPC = config.legacyEthereumRPC
        let savedBtcAPI = config.legacyBitcoinAPI
        let savedSolRPC = config.legacySolanaRPC
        let savedEvmChainId = config.evmChainId
        let savedBtcTestnet = config.btcTestnet
        let savedSolDevnet = config.solDevnet
        // Save a key value to verify it survives the reset. We read but
        // never write "" — that would delete the Keychain item.
        let savedEtherscanKey = config.etherscanAPIKey
        defer {
            config.activeProvider = savedProvider
            config.evmChainId = savedEvmChainId
            config.btcTestnet = savedBtcTestnet
            config.solDevnet = savedSolDevnet
            config.legacyEthereumRPC = savedEthRPC
            config.legacyBitcoinAPI = savedBtcAPI
            config.legacySolanaRPC = savedSolRPC
            // Restore original key only if it was non-empty (to avoid Keychain
            // write with "" which deletes the item).
            if !savedEtherscanKey.isEmpty {
                config.etherscanAPIKey = savedEtherscanKey
            }
        }

        // Arrange: set overrides and a provider.
        ChainEndpointOverrides.shared.set("https://btc-custom.example", for: .bitcoin)
        ChainEndpointOverrides.shared.set("https://eth-custom.example", for: .ethereum)
        ChainEndpointOverrides.shared.set("https://sol-custom.example", for: .solana)
        config.activeProvider = .drpc

        // Act.
        config.resetToDefaults()

        // Assert overrides cleared.
        XCTAssertNil(ChainEndpointOverrides.shared.url(for: .bitcoin),
                     "resetToDefaults must clear bitcoin override")
        XCTAssertNil(ChainEndpointOverrides.shared.url(for: .ethereum),
                     "resetToDefaults must clear ethereum override")
        XCTAssertNil(ChainEndpointOverrides.shared.url(for: .solana),
                     "resetToDefaults must clear solana override")

        // Assert provider deactivated.
        XCTAssertNil(config.activeProvider,
                     "resetToDefaults must set activeProvider to nil")

        // Assert all chains route to public default.
        for chain in Chain.allCases {
            let rpc = config.rpcURL(for: chain)
            let pub = config.publicDefault(for: chain)
            XCTAssertEqual(rpc, pub,
                "[\(chain)] rpcURL must equal publicDefault after resetToDefaults. Got: \(rpc)")
        }

        // Assert key is preserved (value may be empty if not set in test env —
        // the important thing is we did not assign "" to it, which would delete
        // the Keychain item).
        XCTAssertEqual(config.etherscanAPIKey, savedEtherscanKey,
                       "resetToDefaults must not modify API keys")
    }

    // MARK: - Critical 3b: testnetBadge matches host only, returns "Custom" for unknown

    /// `testnetBadge` must:
    ///   1. Match on the URL host only — path/query segments must not trigger badges.
    ///   2. Return `L10n.NodeSettings.customBadge` ("Custom") when an override is
    ///      present but the host carries no recognised network marker. `nil` must
    ///      be reserved for "positively mainnet".
    func test_testnetBadge_bitcoin_hostOnly_andCustomForUnrecognised() {
        let config = NetworkConfig.shared
        let savedBtcTestnet = config.btcTestnet
        defer {
            config.btcTestnet = savedBtcTestnet
            ChainEndpointOverrides.shared.clear(.bitcoin)
        }

        // "testnet" in HOST → badge = "Testnet"
        config.btcTestnet = false
        ChainEndpointOverrides.shared.set("https://testnet.bitcoin-node.example/api", for: .bitcoin)
        XCTAssertEqual(config.testnetBadge(for: .bitcoin), "Testnet",
            "badge must be 'Testnet' when override host contains 'testnet'")

        // "testnet" in PATH only (e.g. mempool.space/testnet) → "Custom" not "Testnet"
        // This is the canonical false-positive the host-only fix prevents.
        ChainEndpointOverrides.shared.set("https://mempool.space/testnet/api", for: .bitcoin)
        XCTAssertEqual(config.testnetBadge(for: .bitcoin), L10n.NodeSettings.customBadge,
            "badge must be 'Custom' when 'testnet' appears in path only — host check prevents false positive")

        // Opaque hostname, no network marker, flag says testnet → "Custom" not nil.
        // nil would silently imply mainnet; an opaque custom endpoint could be testnet.
        config.btcTestnet = true
        ChainEndpointOverrides.shared.set("https://my-bitcoin-proxy.example", for: .bitcoin)
        XCTAssertEqual(config.testnetBadge(for: .bitcoin), L10n.NodeSettings.customBadge,
            "badge must be 'Custom' for opaque override host — nil would falsely imply mainnet")

        // No override, flag says testnet → "Testnet" (flag still governs without override)
        ChainEndpointOverrides.shared.clear(.bitcoin)
        config.btcTestnet = true
        XCTAssertEqual(config.testnetBadge(for: .bitcoin), "Testnet",
            "without override, btcTestnet flag determines badge")
    }

    func test_testnetBadge_ethereum_hostOnly_andCustomForUnrecognised() {
        let config = NetworkConfig.shared
        let savedEvmChainId = config.evmChainId
        defer {
            config.evmChainId = savedEvmChainId
            ChainEndpointOverrides.shared.clear(.ethereum)
        }

        // "sepolia" in HOST → badge = "Sepolia"
        config.evmChainId = 1
        ChainEndpointOverrides.shared.set("https://ethereum-sepolia-rpc.publicnode.com", for: .ethereum)
        XCTAssertEqual(config.testnetBadge(for: .ethereum), "Sepolia",
            "badge must be 'Sepolia' when override host contains 'sepolia'")

        // Opaque host, no network marker, flag says Sepolia → "Custom" not "Sepolia".
        // Also proves the old `u.contains("11155111")` full-URL scan is gone —
        // the chain ID in the path would no longer trigger a badge.
        config.evmChainId = 11155111
        ChainEndpointOverrides.shared.set("https://rpc.example.com/0xaa36a7", for: .ethereum)
        XCTAssertEqual(config.testnetBadge(for: .ethereum), L10n.NodeSettings.customBadge,
            "badge must be 'Custom' for opaque override — chain ID in path must not decide network")

        // No override, evmChainId = Sepolia → "Sepolia"
        ChainEndpointOverrides.shared.clear(.ethereum)
        config.evmChainId = 11155111
        XCTAssertEqual(config.testnetBadge(for: .ethereum), "Sepolia",
            "without override, evmChainId determines badge")
    }

    func test_testnetBadge_solana_hostOnly_andCustomForUnrecognised() {
        let config = NetworkConfig.shared
        let savedSolDevnet = config.solDevnet
        defer {
            config.solDevnet = savedSolDevnet
            ChainEndpointOverrides.shared.clear(.solana)
        }

        // "devnet" in HOST → badge = "Devnet"
        config.solDevnet = false
        ChainEndpointOverrides.shared.set("https://api.devnet.solana.com", for: .solana)
        XCTAssertEqual(config.testnetBadge(for: .solana), "Devnet",
            "badge must be 'Devnet' when override host contains 'devnet'")

        // "devnet" in PATH only → "Custom" not "Devnet"
        ChainEndpointOverrides.shared.set("https://rpc.example.com/proxy/devnet-migration", for: .solana)
        XCTAssertEqual(config.testnetBadge(for: .solana), L10n.NodeSettings.customBadge,
            "badge must be 'Custom' when 'devnet' appears in path only")

        // Opaque mainnet-like host, flag says devnet → "Custom"
        config.solDevnet = true
        ChainEndpointOverrides.shared.set("https://solana-mainnet.example.com", for: .solana)
        XCTAssertEqual(config.testnetBadge(for: .solana), L10n.NodeSettings.customBadge,
            "badge must be 'Custom' for opaque override — 'devnet' not in host, nil would be misleading")

        // No override, flag says devnet → "Devnet"
        ChainEndpointOverrides.shared.clear(.solana)
        config.solDevnet = true
        XCTAssertEqual(config.testnetBadge(for: .solana), "Devnet",
            "without override, solDevnet flag determines badge")
    }

    // MARK: - Important 3: litecoin and tron badge coverage

    func test_testnetBadge_litecoin_overrideAndNoOverride() {
        let overrides = ChainEndpointOverrides.shared
        defer { overrides.clear(.litecoin) }

        // "testnet" in HOST → "Testnet"
        overrides.set("https://testnet.litecoinspace.org/api", for: .litecoin)
        XCTAssertEqual(NetworkConfig.shared.testnetBadge(for: .litecoin), "Testnet",
            "badge must be 'Testnet' when litecoin override host contains 'testnet'")

        // "testnet" in PATH only → "Custom" (host-only rule)
        overrides.set("https://litecoinspace.org/testnet/api", for: .litecoin)
        XCTAssertEqual(NetworkConfig.shared.testnetBadge(for: .litecoin), L10n.NodeSettings.customBadge,
            "badge must be 'Custom' when 'testnet' is in path only")

        // Opaque host → "Custom"
        overrides.set("https://my-litecoin-node.example", for: .litecoin)
        XCTAssertEqual(NetworkConfig.shared.testnetBadge(for: .litecoin), L10n.NodeSettings.customBadge,
            "badge must be 'Custom' for opaque litecoin override host")

        // No override, public default has no 'testnet' in host → nil
        overrides.clear(.litecoin)
        XCTAssertNil(NetworkConfig.shared.testnetBadge(for: .litecoin),
            "without override, litecoin public default has no testnet marker → nil")
    }

    /// Mutation target: break tron host matching so it can never return "Shasta"
    /// or "Nile" → both assertions below must go RED.
    func test_testnetBadge_tron_overrideAndNoOverride() {
        let overrides = ChainEndpointOverrides.shared
        defer { overrides.clear(.tron) }

        // "shasta" in HOST → "Shasta"
        overrides.set("https://api.shasta.trongrid.io", for: .tron)
        XCTAssertEqual(NetworkConfig.shared.testnetBadge(for: .tron), "Shasta",
            "badge must be 'Shasta' when override host contains 'shasta'")

        // "nile" in HOST → "Nile" (distinct from Shasta — different testnet)
        overrides.set("https://nile.trongrid.io", for: .tron)
        XCTAssertEqual(NetworkConfig.shared.testnetBadge(for: .tron), "Nile",
            "badge must be 'Nile' when override host contains 'nile' — Nile and Shasta are distinct testnets")

        // Opaque host → "Custom"
        overrides.set("https://my-tron-node.example", for: .tron)
        XCTAssertEqual(NetworkConfig.shared.testnetBadge(for: .tron), L10n.NodeSettings.customBadge,
            "badge must be 'Custom' for opaque tron override host")

        // No override, public default trongrid has no testnet marker → nil
        overrides.clear(.tron)
        XCTAssertNil(NetworkConfig.shared.testnetBadge(for: .tron),
            "without override, tron public default has no testnet marker → nil")
    }

    // MARK: - Important 2: NetworkPreset.governedChains matches applyPreset domain

    /// `governedChains` must include exactly the chains that `applyPreset` writes.
    /// Mutation target: reduce `governedChains` to `[.ethereum]` → bitcoin and
    /// solana assertions go RED, proving the governance set is load-bearing.
    func test_presetGoverningChains_matchApplyPresetDomain() {
        // applyPreset writes evmChainId → ethereum
        XCTAssertTrue(NetworkPreset.governedChains.contains(.ethereum),
            "ethereum must be governed — applyPreset writes evmChainId")
        // applyPreset writes btcTestnet → bitcoin
        XCTAssertTrue(NetworkPreset.governedChains.contains(.bitcoin),
            "bitcoin must be governed — applyPreset writes btcTestnet")
        // applyPreset writes solDevnet → solana
        XCTAssertTrue(NetworkPreset.governedChains.contains(.solana),
            "solana must be governed — applyPreset writes solDevnet")
        // Exactly three chains — if applyPreset gains a new flag, update governedChains too
        XCTAssertEqual(NetworkPreset.governedChains.count, 3,
            "governedChains must have exactly 3 members (eth/btc/sol)")
        // Other chains are untouched by presets
        XCTAssertFalse(NetworkPreset.governedChains.contains(.litecoin))
        XCTAssertFalse(NetworkPreset.governedChains.contains(.tron))
    }

    // MARK: - Important 1: effectiveDisplayURL — no key leak, fallback disclosed

    func test_effectiveDisplayURL_plainOverride_showsOverrideURLAndNoFallback() {
        let overrides = ChainEndpointOverrides.shared
        overrides.set("https://my-custom-solana.example/rpc", for: .solana)
        defer { overrides.clear(.solana) }

        let (url, isKeyFallback) = NetworkConfig.shared.effectiveDisplayURL(for: .solana)
        XCTAssertEqual(url, "https://my-custom-solana.example/rpc",
            "plain override (no {KEY}) must be returned as-is")
        XCTAssertFalse(isKeyFallback,
            "isKeyFallback must be false when override has no {KEY}")
    }

    func test_effectiveDisplayURL_keyTemplate_noKeySet_showsFallbackAndSetsFlag() {
        // Proves that when a {KEY} template is set but the Alchemy key is empty,
        // the display shows the public fallback host, not the template host.
        // In a clean simulator environment (CODE_SIGNING_ALLOWED=NO) API keys
        // are always empty.
        let config = NetworkConfig.shared
        let overrides = ChainEndpointOverrides.shared
        // Alchemy is the default EVM key slot — empty in a clean test environment.
        overrides.set("https://eth-mainnet.g.alchemy.com/v2/{KEY}", for: .ethereum)
        defer { overrides.clear(.ethereum) }

        guard config.alchemyAPIKey.isEmpty else { return }  // skip if key is set

        let (url, isKeyFallback) = config.effectiveDisplayURL(for: .ethereum)
        XCTAssertTrue(isKeyFallback,
            "isKeyFallback must be true when {KEY} template has no key set")
        XCTAssertFalse(url.contains("alchemy"),
            "display must show the fallback host, not the Alchemy template host")
        XCTAssertFalse(url.contains("{KEY}"),
            "fallback URL must not contain the {KEY} placeholder")
    }

    func test_effectiveDisplayURL_keyTemplate_keyPresent_showsTemplateSafelyNotKey() {
        // Proves that when a key IS present, {KEY} is shown on screen rather
        // than the real key value. Only runs when a key is actually set.
        let config = NetworkConfig.shared
        let savedKey = config.alchemyAPIKey
        guard !savedKey.isEmpty else { return }  // only testable when key is present

        let overrides = ChainEndpointOverrides.shared
        overrides.set("https://eth-mainnet.g.alchemy.com/v2/{KEY}", for: .ethereum)
        defer { overrides.clear(.ethereum) }

        let (url, isKeyFallback) = config.effectiveDisplayURL(for: .ethereum)
        XCTAssertFalse(isKeyFallback,
            "isKeyFallback must be false when key is set")
        XCTAssertFalse(url.contains(savedKey),
            "display URL must never contain the real API key")
        XCTAssertTrue(url.contains("{KEY}"),
            "display URL must show the {KEY} placeholder, not the substituted value")
    }
}
