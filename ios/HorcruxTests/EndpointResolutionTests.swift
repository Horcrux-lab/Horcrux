import XCTest
@testable import Horcrux

final class EndpointResolutionTests: XCTestCase {

    /// `TEST_HOST` is `Horcrux.app`, so this store is the user's real one.
    /// Snapshot and restore it rather than blanking it, or running the
    /// tests on a device deletes every endpoint they configured by hand.
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

    func test_overrides_startEmpty() {
        XCTAssertNil(ChainEndpointOverrides.shared.url(for: .polygon))
        XCTAssertTrue(ChainEndpointOverrides.shared.allChains().isEmpty)
    }

    func test_setAndReadBack_roundTrips() {
        ChainEndpointOverrides.shared.set("https://my-node.example", for: .polygon)
        XCTAssertEqual(ChainEndpointOverrides.shared.url(for: .polygon),
                       "https://my-node.example")
        XCTAssertNil(ChainEndpointOverrides.shared.url(for: .base),
                     "setting one chain must not affect another")
    }

    /// The bug this design replaces: one shared field meant a custom
    /// Polygon URL silently applied to Base.
    func test_overridesAreIndependentPerChain() {
        ChainEndpointOverrides.shared.set("https://poly.example", for: .polygon)
        ChainEndpointOverrides.shared.set("https://base.example", for: .base)
        XCTAssertEqual(ChainEndpointOverrides.shared.url(for: .polygon), "https://poly.example")
        XCTAssertEqual(ChainEndpointOverrides.shared.url(for: .base), "https://base.example")
    }

    func test_settingEmptyString_clearsTheOverride() {
        ChainEndpointOverrides.shared.set("https://my-node.example", for: .polygon)
        ChainEndpointOverrides.shared.set("", for: .polygon)
        XCTAssertNil(ChainEndpointOverrides.shared.url(for: .polygon),
                     "an emptied field must fall back to provider/public, not store \"\"")
        // url(for:) alone cannot tell "cleared" from "stored empty string".
        // Without these, an implementation that persisted "" would pass.
        XCTAssertFalse(ChainEndpointOverrides.shared.allChains().contains(.polygon))
        XCTAssertNil(ChainEndpointOverrides.shared.snapshot()[Chain.polygon.rawValue])
    }

    /// Whitespace-only input is the same user intent as an empty field.
    func test_settingWhitespaceOnly_clearsTheOverride() {
        ChainEndpointOverrides.shared.set("https://my-node.example", for: .polygon)
        ChainEndpointOverrides.shared.set("   \n ", for: .polygon)
        XCTAssertNil(ChainEndpointOverrides.shared.url(for: .polygon))
        XCTAssertFalse(ChainEndpointOverrides.shared.allChains().contains(.polygon))
        XCTAssertNil(ChainEndpointOverrides.shared.snapshot()[Chain.polygon.rawValue])
    }

    func test_setTrimsSurroundingWhitespace() {
        ChainEndpointOverrides.shared.set("  https://padded.example  ", for: .linea)
        XCTAssertEqual(ChainEndpointOverrides.shared.url(for: .linea), "https://padded.example")
    }

    func test_clear_removesOnlyThatChain() {
        ChainEndpointOverrides.shared.set("https://poly.example", for: .polygon)
        ChainEndpointOverrides.shared.set("https://base.example", for: .base)
        ChainEndpointOverrides.shared.clear(.polygon)
        XCTAssertNil(ChainEndpointOverrides.shared.url(for: .polygon))
        XCTAssertEqual(ChainEndpointOverrides.shared.url(for: .base), "https://base.example")
    }

    func test_allChains_reportsExactlyTheOverriddenChains() {
        ChainEndpointOverrides.shared.set("https://poly.example", for: .polygon)
        ChainEndpointOverrides.shared.set("https://sol.example", for: .solana)
        XCTAssertEqual(ChainEndpointOverrides.shared.allChains(), [.polygon, .solana])
    }

    /// Chains whose raw value contains spaces must survive the round trip
    /// through UserDefaults keys.
    func test_chainsWithSpacesInRawValue_roundTrip() {
        ChainEndpointOverrides.shared.set("https://bnb.example", for: .bnb)
        ChainEndpointOverrides.shared.reloadFromDisk()
        XCTAssertEqual(ChainEndpointOverrides.shared.url(for: .bnb), "https://bnb.example")
        XCTAssertEqual(ChainEndpointOverrides.shared.allChains(), [.bnb])
    }

    func test_overridesSurviveAReload() {
        ChainEndpointOverrides.shared.set("https://persisted.example", for: .scroll)
        ChainEndpointOverrides.shared.reloadFromDisk()
        XCTAssertEqual(ChainEndpointOverrides.shared.url(for: .scroll),
                       "https://persisted.example")
    }

    /// A key that no longer maps to a Chain (a renamed or removed case)
    /// must be ignored rather than crashing the settings list.
    func test_unknownStoredKeys_areIgnored() {
        UserDefaults.standard.set(["NotAChain": "https://ghost.example"],
                                  forKey: ChainEndpointOverrides.storageKey)
        ChainEndpointOverrides.shared.reloadFromDisk()
        XCTAssertTrue(ChainEndpointOverrides.shared.allChains().isEmpty)
    }

    /// clear() must reach disk. If it only mutated memory, a user's
    /// cleared override would come back on next launch — and setUp's
    /// removeAll() would stop isolating tests from each other.
    func test_clearIsPersisted() {
        ChainEndpointOverrides.shared.set("https://gone.example", for: .optimism)
        ChainEndpointOverrides.shared.clear(.optimism)
        ChainEndpointOverrides.shared.reloadFromDisk()
        XCTAssertNil(ChainEndpointOverrides.shared.url(for: .optimism))
    }

    func test_removeAllIsPersisted() {
        ChainEndpointOverrides.shared.set("https://a.example", for: .polygon)
        ChainEndpointOverrides.shared.set("https://b.example", for: .base)
        ChainEndpointOverrides.shared.removeAll()
        ChainEndpointOverrides.shared.reloadFromDisk()
        XCTAssertTrue(ChainEndpointOverrides.shared.allChains().isEmpty)
    }

    /// One unreadable value must not take the rest of the user's
    /// hand-entered node addresses with it. A wholesale
    /// `as? [String: String]` cast would return nil here and wipe all three.
    func test_oneCorruptValue_doesNotDiscardTheGoodOnes() {
        UserDefaults.standard.set([Chain.polygon.rawValue: "https://poly.example",
                                   Chain.base.rawValue: "https://base.example",
                                   Chain.solana.rawValue: 42],
                                  forKey: ChainEndpointOverrides.storageKey)
        ChainEndpointOverrides.shared.reloadFromDisk()
        XCTAssertEqual(ChainEndpointOverrides.shared.url(for: .polygon), "https://poly.example")
        XCTAssertEqual(ChainEndpointOverrides.shared.url(for: .base), "https://base.example")
        XCTAssertNil(ChainEndpointOverrides.shared.url(for: .solana))
    }

    /// An empty value on disk must be adopted as "no override", so the
    /// settings list and the resolver cannot disagree about whether a
    /// chain is overridden.
    func test_emptyValueOnDisk_isTreatedAsNoOverride() {
        UserDefaults.standard.set([Chain.linea.rawValue: "  "],
                                  forKey: ChainEndpointOverrides.storageKey)
        ChainEndpointOverrides.shared.reloadFromDisk()
        XCTAssertNil(ChainEndpointOverrides.shared.url(for: .linea))
        XCTAssertTrue(ChainEndpointOverrides.shared.allChains().isEmpty)
    }

    /// Concurrent reads during writes must not crash. Dictionary
    /// reallocates as it grows, which is the race the lock exists for.
    func test_concurrentReadsAndWrites_doNotCrash() {
        let done = expectation(description: "concurrent access")
        done.expectedFulfillmentCount = 2

        DispatchQueue.global().async {
            for i in 0..<500 {
                ChainEndpointOverrides.shared.set("https://w\(i).example", for: .polygon)
                ChainEndpointOverrides.shared.set("https://x\(i).example", for: .base)
            }
            done.fulfill()
        }
        DispatchQueue.global().async {
            for _ in 0..<500 {
                _ = ChainEndpointOverrides.shared.url(for: .polygon)
                _ = ChainEndpointOverrides.shared.allChains()
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
    }

    func test_publicDefault_isNonEmptyAndPlaceholderFreeForEveryChain() {
        let config = NetworkConfig.shared
        for chain in Chain.allCases {
            let url = config.publicDefault(for: chain)
            XCTAssertFalse(url.isEmpty, "\(chain) has no public default")
            XCTAssertFalse(url.contains("{KEY}"),
                           "\(chain) public default must need no key: \(url)")
        }
    }

    func test_publicDefault_forPreviouslyUnconfigurableChains() {
        let config = NetworkConfig.shared
        XCTAssertEqual(config.publicDefault(for: .base), "https://mainnet.base.org")
        XCTAssertEqual(config.publicDefault(for: .scroll), "https://rpc.scroll.io")
        XCTAssertEqual(config.publicDefault(for: .bnb), "https://bsc-dataseed.bnbchain.org")
    }

    func test_publicDefault_forEthereum_followsTheNetworkToggle() {
        let config = NetworkConfig.shared
        let original = config.evmChainId
        defer { config.evmChainId = original }

        config.evmChainId = 1
        XCTAssertEqual(config.publicDefault(for: .ethereum),
                       "https://ethereum-rpc.publicnode.com")
        config.evmChainId = 11_155_111
        XCTAssertEqual(config.publicDefault(for: .ethereum),
                       "https://ethereum-sepolia-rpc.publicnode.com")
    }

    func test_activeProvider_persistsTheChoice() {
        let config = NetworkConfig.shared
        let original = config.activeProvider
        defer { config.activeProvider = original }

        config.activeProvider = .infura
        XCTAssertEqual(config.activeProvider, .infura)
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: "com.horcrux.rpc.activeProvider"),
            "infura",
            "not persisted, so the choice is lost on next launch")
    }

    func test_activeProvider_nilClearsTheStoredValue() {
        let config = NetworkConfig.shared
        let original = config.activeProvider
        defer { config.activeProvider = original }

        config.activeProvider = .alchemy
        config.activeProvider = nil

        XCTAssertNil(config.activeProvider)
        XCTAssertNil(
            UserDefaults.standard.string(forKey: "com.horcrux.rpc.activeProvider"),
            "going back to public must remove the key, not leave the old provider on disk")
    }

    func test_activeProvider_unknownStoredValue_readsAsPublic() {
        // A provider dropped in a later version must degrade to public
        // defaults, not crash and not resurrect as some other vendor.
        XCTAssertNil(NodeProvider(rawValue: "quicknode"))
    }

    /// `alchemyAPIKey.didSet` runs `autoSwapPaidPublicDefaultsOnKeyChange`,
    /// which rewrites `ethereumRPC` and `solanaRPC` — and it is *edge*
    /// triggered on empty↔non-empty. Clearing the key and then setting one
    /// crosses two edges, but restoring a non-empty key crosses none, so
    /// the swap is never undone. `TEST_HOST` is `Horcrux.app`, so those two
    /// URLs are the user's real settings. Restore them explicitly, and
    /// after the key, since assigning the key is what perturbs them.
    private func withCleanConfig(_ body: (NetworkConfig) -> Void) {
        let config = NetworkConfig.shared
        let provider = config.activeProvider
        let chainId = config.evmChainId
        let devnet = config.solDevnet
        let alchemy = config.alchemyAPIKey
        let ankr = config.ankrAPIKey
        let ethereumRPC = config.ethereumRPC
        let solanaRPC = config.solanaRPC
        defer {
            config.activeProvider = provider
            config.evmChainId = chainId
            config.solDevnet = devnet
            config.alchemyAPIKey = alchemy
            config.ankrAPIKey = ankr
            config.ethereumRPC = ethereumRPC
            config.solanaRPC = solanaRPC
        }
        config.activeProvider = nil
        config.alchemyAPIKey = ""
        config.ankrAPIKey = ""
        ChainEndpointOverrides.shared.removeAll()
        body(config)
    }

    func test_resolve_withNothingConfigured_returnsThePublicDefault() {
        withCleanConfig { config in
            XCTAssertEqual(config.resolveRawURL(for: .base), "https://mainnet.base.org")
        }
    }

    func test_resolve_prefersTheProviderTemplateOverPublic() {
        withCleanConfig { config in
            config.activeProvider = .alchemy
            config.alchemyAPIKey = "k"
            XCTAssertEqual(config.resolveRawURL(for: .base),
                           "https://base-mainnet.g.alchemy.com/v2/{KEY}")
        }
    }

    func test_resolve_prefersAnOverrideOverTheProvider() {
        withCleanConfig { config in
            config.activeProvider = .alchemy
            config.alchemyAPIKey = "k"
            ChainEndpointOverrides.shared.set("https://mine.example", for: .base)
            XCTAssertEqual(config.resolveRawURL(for: .base), "https://mine.example")
        }
    }

    /// A provider that does not serve a chain must not shadow the public
    /// default for it, and must never return another chain's URL.
    func test_resolve_fallsBackToPublicForAnUncoveredChain() {
        withCleanConfig { config in
            config.activeProvider = .alchemy
            config.alchemyAPIKey = "k"
            XCTAssertEqual(config.resolveRawURL(for: .bnb),
                           "https://bsc-dataseed.bnbchain.org")
            XCTAssertEqual(config.resolveRawURL(for: .bitcoin),
                           config.publicDefault(for: .bitcoin))
        }
    }

    /// Selecting a provider without pasting its key must not strand the
    /// user on a template that resolves to a literal "{KEY}" request.
    func test_resolve_ignoresTheProviderWhenItsKeyIsEmpty() {
        withCleanConfig { config in
            config.activeProvider = .alchemy
            config.alchemyAPIKey = ""
            XCTAssertEqual(config.resolveRawURL(for: .base), "https://mainnet.base.org")
        }
    }

    /// Ethereum is the one chain whose EVM network the user can change, so
    /// the resolver has to thread `evmChainId` through to the provider. If
    /// it ever hardcodes mainnet, a Sepolia user silently talks to mainnet.
    func test_resolve_forEthereum_followsTheNetworkToggleThroughTheProvider() {
        withCleanConfig { config in
            config.activeProvider = .alchemy
            config.alchemyAPIKey = "k"

            config.evmChainId = 1
            XCTAssertEqual(config.resolveRawURL(for: .ethereum),
                           "https://eth-mainnet.g.alchemy.com/v2/{KEY}")
            config.evmChainId = 11_155_111
            XCTAssertEqual(config.resolveRawURL(for: .ethereum),
                           "https://eth-sepolia.g.alchemy.com/v2/{KEY}")
        }
    }

    /// The single highest-consequence argument in `resolveRawURL`. Nothing
    /// else in the suite can distinguish `solanaMainnet: !solDevnet` from
    /// `true`, `false`, or the inverted `solDevnet`: the parameter is dead
    /// for every non-Solana chain, and the only test that reaches `.solana`
    /// runs with no provider selected, so it short-circuits before the
    /// template is ever consulted.
    ///
    /// Getting it wrong hands a Devnet user a mainnet endpoint. Solana
    /// addresses are byte-identical across clusters, so it answers normally
    /// and a "test" transfer spends real SOL. `detectMismatch` only fires
    /// on the node-health screen; the send path has no guard at all.
    /// Commit e76d329 on this branch fixed exactly this bug one layer down.
    func test_resolve_forSolana_followsTheClusterToggleThroughTheProvider() {
        withCleanConfig { config in
            config.activeProvider = .alchemy
            config.alchemyAPIKey = "k"

            config.solDevnet = false
            XCTAssertEqual(config.resolveRawURL(for: .solana),
                           "https://solana-mainnet.g.alchemy.com/v2/{KEY}")
            config.solDevnet = true
            XCTAssertEqual(config.resolveRawURL(for: .solana),
                           "https://solana-devnet.g.alchemy.com/v2/{KEY}")
        }
    }

    /// Ankr and dRPC have no devnet Solana host, so on devnet they must
    /// fall through to the public devnet endpoint rather than serve their
    /// mainnet one.
    func test_resolve_forSolanaOnDevnet_skipsAProviderWithNoDevnetHost() {
        withCleanConfig { config in
            config.activeProvider = .ankr
            config.ankrAPIKey = "k"

            config.solDevnet = true
            XCTAssertEqual(config.resolveRawURL(for: .solana),
                           SolanaNetwork.devnet.publicDefaultRPC)
        }
    }

    func test_resolve_neverReturnsEmptyForAnyChain() {
        withCleanConfig { config in
            for chain in Chain.allCases {
                XCTAssertFalse(config.resolveRawURL(for: chain).isEmpty, "\(chain)")
            }
        }
    }
}
