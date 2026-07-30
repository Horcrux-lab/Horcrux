import XCTest
@testable import Horcrux

final class NodeSettingsMigrationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ChainEndpointOverrides.shared.removeAll()
    }

    override func tearDown() {
        ChainEndpointOverrides.shared.removeAll()
        super.tearDown()
    }

    // MARK: - Shipped-endpoint table

    /// The whole point: the answer must not move when the user flips a
    /// network toggle. If it does, a devnet user sitting on the mainnet
    /// default gets that mainnet URL frozen into an override, and nothing
    /// downstream can detect it.
    func test_shippedEndpoints_includeBothClusters() {
        let sol = RPCFallbacks.allShippedEndpoints(for: .solana)
        XCTAssertTrue(sol.contains(SolanaNetwork.mainnet.publicDefaultRPC))
        XCTAssertTrue(sol.contains(SolanaNetwork.devnet.publicDefaultRPC))

        let btc = RPCFallbacks.allShippedEndpoints(for: .bitcoin)
        XCTAssertTrue(btc.contains(BitcoinNetwork.mainnet.defaultAPI))
        XCTAssertTrue(btc.contains(BitcoinNetwork.testnet.defaultAPI))

        let eth = RPCFallbacks.allShippedEndpoints(for: .ethereum)
        XCTAssertTrue(eth.contains(EVMNetwork.mainnet.publicDefaultRPC))
        XCTAssertTrue(eth.contains(EVMNetwork.sepolia.publicDefaultRPC))
    }

    /// It must not depend on the live singleton at all.
    func test_shippedEndpoints_areIndependentOfTheLiveToggles() {
        let config = NetworkConfig.shared
        let devnet = config.solDevnet
        let testnet = config.btcTestnet
        defer { config.solDevnet = devnet; config.btcTestnet = testnet }

        config.solDevnet = false
        config.btcTestnet = false
        let solOff = RPCFallbacks.allShippedEndpoints(for: .solana)
        let btcOff = RPCFallbacks.allShippedEndpoints(for: .bitcoin)

        config.solDevnet = true
        config.btcTestnet = true
        XCTAssertEqual(RPCFallbacks.allShippedEndpoints(for: .solana), solOff)
        XCTAssertEqual(RPCFallbacks.allShippedEndpoints(for: .bitcoin), btcOff)
    }

    /// Every fallback we would actually dial must be in the table, or the
    /// migration would treat a shipped fallback as a hand-typed URL.
    func test_shippedEndpoints_supersetOfTheLiveFallbackList() {
        let config = NetworkConfig.shared
        for chain in Chain.allCases {
            let live = Set(RPCFallbacks.endpoints(for: chain, config: config))
            let all = RPCFallbacks.allShippedEndpoints(for: chain)
            XCTAssertTrue(live.isSubset(of: all),
                          "\(chain): \(live.subtracting(all)) missing from the shipped table")
        }
    }

    func test_shippedEndpoints_doNotLeakAcrossChains() {
        XCTAssertFalse(RPCFallbacks.allShippedEndpoints(for: .bitcoin)
            .contains(EVMNetwork.mainnet.publicDefaultRPC))
        XCTAssertFalse(RPCFallbacks.allShippedEndpoints(for: .tron)
            .contains(SolanaNetwork.mainnet.publicDefaultRPC))
    }

    // MARK: - plan()

    private func plan(ethereum: String = EVMNetwork.mainnet.publicDefaultRPC,
                      bitcoin: String = "https://mempool.space/api",
                      litecoin: String = "https://litecoinspace.org/api",
                      solana: String = "https://solana-rpc.publicnode.com",
                      tron: String = "https://api.trongrid.io",
                      evmChainId: UInt64 = 1) -> NodeSettingsMigration.Plan {
        NodeSettingsMigration.plan(
            ethereumRPC: ethereum, bitcoinAPI: bitcoin, litecoinAPI: litecoin,
            solanaRPC: solana, tronAPI: tron, evmChainId: evmChainId
        )
    }

    /// A value equal to something we ship must produce no override, or the
    /// user is frozen on it and future default fixes never arrive.
    func test_shippedValues_produceNoOverride() {
        let result = plan()
        XCTAssertTrue(result.overrides.isEmpty, "got \(result.overrides)")
        XCTAssertNil(result.activeProvider)
        XCTAssertEqual(result.evmChainId, 1)
    }

    /// The defect this replaces: plan() used to read solDevnet from the
    /// singleton, so a devnet user holding the mainnet Solana default
    /// would have had it written into a permanent mainnet override.
    func test_planIsIndependentOfTheLiveToggles() {
        let config = NetworkConfig.shared
        let devnet = config.solDevnet
        let testnet = config.btcTestnet
        defer { config.solDevnet = devnet; config.btcTestnet = testnet }

        config.solDevnet = false
        config.btcTestnet = false
        let mainnetSide = plan()

        config.solDevnet = true
        config.btcTestnet = true
        XCTAssertEqual(plan(), mainnetSide,
                       "plan() must be a pure function of its arguments")
    }

    func test_devnetDefault_alsoProducesNoOverride() {
        let result = plan(solana: SolanaNetwork.devnet.publicDefaultRPC)
        XCTAssertNil(result.overrides[.solana],
                     "the devnet default is ours too; freezing it would pin the cluster")
    }

    func test_providerTemplate_becomesTheActiveProvider() {
        let result = plan(ethereum: "https://eth-mainnet.g.alchemy.com/v2/{KEY}")
        XCTAssertEqual(result.activeProvider, .alchemy)
        XCTAssertTrue(result.overrides.isEmpty,
                      "a recognised template is a provider, not an override")
    }

    func test_customURL_becomesAnOverrideForItsChain() {
        let result = plan(ethereum: "https://my-own-node.example/eth")
        XCTAssertNil(result.activeProvider)
        XCTAssertEqual(result.overrides[.ethereum], "https://my-own-node.example/eth")
        XCTAssertEqual(result.overrides.count, 1)
    }

    /// The Ethereum slot was being used as Polygon. The URL belongs to
    /// the first-class Polygon chain, and the toggle returns to mainnet.
    func test_evmChainIdPointingAtPolygon_movesTheURLToPolygon() {
        let result = plan(ethereum: "https://my-own-node.example/polygon",
                          evmChainId: 137)
        XCTAssertEqual(result.overrides[.polygon], "https://my-own-node.example/polygon")
        XCTAssertNil(result.overrides[.ethereum])
        XCTAssertEqual(result.evmChainId, 1)
    }

    /// Same relocation, but the value was a default, so nothing is stored.
    func test_evmChainIdPointingAtPolygon_withDefaultURL_storesNothing() {
        let result = plan(ethereum: EVMNetwork.polygon.publicDefaultRPC, evmChainId: 137)
        XCTAssertTrue(result.overrides.isEmpty, "got \(result.overrides)")
        XCTAssertEqual(result.evmChainId, 1)
    }

    func test_sepoliaToggle_isPreserved() {
        let result = plan(ethereum: EVMNetwork.sepolia.publicDefaultRPC,
                          evmChainId: 11_155_111)
        XCTAssertEqual(result.evmChainId, 11_155_111,
                       "Sepolia is a valid Ethereum testnet toggle, not a second chain")
        XCTAssertTrue(result.overrides.isEmpty, "got \(result.overrides)")
    }

    func test_customNonEVMURLs_becomeTheirOwnOverrides() {
        let result = plan(bitcoin: "https://my-esplora.example/api",
                          solana: "https://my-solana.example",
                          tron: "https://my-tron.example")
        XCTAssertEqual(result.overrides[.bitcoin], "https://my-esplora.example/api")
        XCTAssertEqual(result.overrides[.solana], "https://my-solana.example")
        XCTAssertEqual(result.overrides[.tron], "https://my-tron.example")
        XCTAssertNil(result.overrides[.litecoin], "litecoin was on its default")
    }

    /// Two different vendors across the two slots. Only one can become the
    /// account provider, so the other must survive as an override rather
    /// than be silently dropped back to a public endpoint. The template
    /// keeps its `{KEY}`; substituteAPIKey resolves it by hostname.
    func test_aSecondVendorOnSolana_survivesAsAnOverride() {
        let result = plan(ethereum: "https://mainnet.infura.io/v3/{KEY}",
                          solana: "https://solana-mainnet.g.alchemy.com/v2/{KEY}")
        XCTAssertEqual(result.activeProvider, .infura)
        XCTAssertEqual(result.overrides[.solana],
                       "https://solana-mainnet.g.alchemy.com/v2/{KEY}")
    }

    /// One vendor across both slots is the common case and must not
    /// produce a redundant override.
    func test_sameVendorOnBothSlots_producesNoOverride() {
        let result = plan(ethereum: "https://eth-mainnet.g.alchemy.com/v2/{KEY}",
                          solana: "https://solana-mainnet.g.alchemy.com/v2/{KEY}")
        XCTAssertEqual(result.activeProvider, .alchemy)
        XCTAssertTrue(result.overrides.isEmpty, "got \(result.overrides)")
    }

    func test_emptyFields_produceNoOverrides() {
        let result = plan(ethereum: "", bitcoin: "", litecoin: "", solana: "", tron: "")
        XCTAssertTrue(result.overrides.isEmpty, "got \(result.overrides)")
        XCTAssertNil(result.activeProvider)
    }

    // MARK: - runIfNeeded()

    /// The version gate is the whole reason runIfNeeded exists. Without
    /// it, every launch would re-derive the plan from the legacy fields —
    /// which are never cleared — and resurrect an override the user has
    /// since deleted.
    func test_runIfNeeded_doesNotResurrectAnOverrideTheUserDeleted() {
        let suite = "com.horcrux.tests.migration"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let config = NetworkConfig.shared
        let originalETH = config.legacyEthereumRPC
        let originalChainId = config.evmChainId
        let originalProvider = config.activeProvider
        defer {
            config.legacyEthereumRPC = originalETH
            config.evmChainId = originalChainId
            config.activeProvider = originalProvider
            ChainEndpointOverrides.shared.removeAll()
        }

        config.evmChainId = 1
        config.legacyEthereumRPC = "https://my-own-node.example/eth"

        NodeSettingsMigration.runIfNeeded(config: config, defaults: defaults)
        XCTAssertEqual(ChainEndpointOverrides.shared.url(for: .ethereum),
                       "https://my-own-node.example/eth")

        // The user changes their mind and deletes it.
        ChainEndpointOverrides.shared.clear(.ethereum)

        NodeSettingsMigration.runIfNeeded(config: config, defaults: defaults)
        XCTAssertNil(ChainEndpointOverrides.shared.url(for: .ethereum),
                     "the version gate did not hold; migration ran a second time")
    }

    func test_runIfNeeded_recordsTheVersionEvenWhenThereIsNothingToMigrate() {
        let suite = "com.horcrux.tests.migration.noop"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let config = NetworkConfig.shared
        let originalProvider = config.activeProvider
        let originalChainId = config.evmChainId
        defer {
            config.activeProvider = originalProvider
            config.evmChainId = originalChainId
        }

        NodeSettingsMigration.runIfNeeded(config: config, defaults: defaults)
        XCTAssertGreaterThan(
            defaults.integer(forKey: "com.horcrux.rpc.settingsMigrationVersion"), 0,
            "a no-op migration must still record its version or it reruns forever")
    }

    func test_runIfNeeded_isSkippedOnceTheVersionIsRecorded() {
        let suiteName = "migration-test-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("could not create a test defaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let config = NetworkConfig.shared
        let originalChainId = config.evmChainId
        let originalProvider = config.activeProvider
        let originalEthRPC = config.legacyEthereumRPC
        defer {
            config.evmChainId = originalChainId
            config.legacyEthereumRPC = originalEthRPC
            config.activeProvider = originalProvider
            ChainEndpointOverrides.shared.removeAll()
        }

        // Seed a legacy Alchemy-template URL. plan() detects the {KEY}
        // pattern and resolves it to NodeProvider.alchemy, so the first
        // runIfNeeded produces a non-nil activeProvider. That makes the
        // second-run assertion discriminating: a broken version gate would
        // re-derive .alchemy and fail XCTAssertNil below.
        config.evmChainId = 1
        config.legacyEthereumRPC = "https://eth-mainnet.g.alchemy.com/v2/{KEY}"
        config.activeProvider = nil

        NodeSettingsMigration.runIfNeeded(config: config, defaults: defaults)
        XCTAssertEqual(config.activeProvider, .alchemy,
                       "the first run must derive the provider from the seeded legacy URL")

        config.activeProvider = nil
        NodeSettingsMigration.runIfNeeded(config: config, defaults: defaults)
        XCTAssertNil(config.activeProvider,
                     "a second run must be a no-op, not re-derive state the user has since changed")
    }
}
