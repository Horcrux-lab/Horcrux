import XCTest
@testable import Horcrux

final class NodeSettingsMigrationTests: XCTestCase {

    /// Captured before each test so tearDown can restore it. Tests that call
    /// removeAll() or replaceAll() during their body don't need to clean up
    /// ChainEndpointOverrides themselves — tearDown handles it atomically.
    private var savedOverrides: [String: String] = [:]

    override func setUp() {
        super.setUp()
        savedOverrides = ChainEndpointOverrides.shared.snapshot()
        ChainEndpointOverrides.shared.removeAll()
    }

    override func tearDown() {
        ChainEndpointOverrides.shared.replaceAll(with: savedOverrides)
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

    // MARK: - RPCConfigSnapshot versioning

    func test_snapshot_roundTripsOverridesAndProvider() {
        let config = NetworkConfig.shared
        let origProvider = config.activeProvider
        let origEthWSS = config.ethereumWSS
        let origSolWSS = config.solanaWSS
        defer {
            config.activeProvider = origProvider
            config.ethereumWSS = origEthWSS
            config.solanaWSS = origSolWSS
        }

        // Snapshot contains only one override so apply can be shown to wipe stale entries.
        // (setUp already cleared overrides; we start from an empty store.)
        config.activeProvider = .drpc
        ChainEndpointOverrides.shared.set("https://mine.example", for: .scroll)

        let snapshot = RPCConfigSnapshot(from: config)
        guard let json = snapshot.jsonString(),
              let decoded = RPCConfigSnapshot.decode(json) else {
            return XCTFail("snapshot did not round-trip")
        }
        XCTAssertEqual(decoded.activeProvider, .drpc)
        XCTAssertEqual(decoded.chainOverrides?["Scroll"], "https://mine.example")

        // Seed stale overrides that the snapshot does not contain; apply must wipe them.
        ChainEndpointOverrides.shared.set("https://stale.eth.example", for: .ethereum)
        ChainEndpointOverrides.shared.set("https://stale.btc.example", for: .bitcoin)

        decoded.apply(to: config)

        XCTAssertEqual(ChainEndpointOverrides.shared.url(for: .scroll), "https://mine.example",
                       "imported override must be present after apply")
        XCTAssertNil(ChainEndpointOverrides.shared.url(for: .ethereum),
                     "stale ethereum override must be wiped by replaceAll in apply")
        XCTAssertNil(ChainEndpointOverrides.shared.url(for: .bitcoin),
                     "stale bitcoin override must be wiped by replaceAll in apply")
        XCTAssertEqual(config.activeProvider, .drpc,
                       "provider must be applied")
    }

    /// An older export has no version field and must still import.
    func test_snapshot_decodesALegacyExportWithNoVersion() {
        let legacy = """
        {"bitcoinAPI":"https://blockstream.info/api",\
        "btcTestnet":false,\
        "ethereumRPC":"https://ethereum-rpc.publicnode.com",\
        "evmChainId":1,\
        "litecoinAPI":"https://litecoinspace.org/api",\
        "solDevnet":false,\
        "solanaRPC":"https://solana-rpc.publicnode.com",\
        "tronAPI":"https://api.trongrid.io"}
        """
        let decoded = RPCConfigSnapshot.decode(legacy)
        XCTAssertNotNil(decoded)
        XCTAssertNil(decoded?.activeProvider)
    }

    /// A newer export must be refused rather than silently losing fields.
    func test_snapshot_refusesAFutureVersion() {
        let future = """
        {"version":99,\
        "bitcoinAPI":"https://blockstream.info/api",\
        "btcTestnet":false,\
        "ethereumRPC":"https://ethereum-rpc.publicnode.com",\
        "evmChainId":1,\
        "litecoinAPI":"https://litecoinspace.org/api",\
        "solDevnet":false,\
        "solanaRPC":"https://solana-rpc.publicnode.com",\
        "tronAPI":"https://api.trongrid.io"}
        """
        XCTAssertNil(RPCConfigSnapshot.decode(future),
                     "importing a newer format must fail loudly, not drop fields")
    }

    /// A legacy import (no version field) must not wipe a provider the user
    /// has already configured. We cannot distinguish nil-from-absence from
    /// nil-by-value in Codable optionals, so the safe rule is: if no version
    /// field is present, leave activeProvider untouched.
    func test_snapshot_applyLegacy_doesNotClearExistingProvider() {
        let config = NetworkConfig.shared
        let origProvider = config.activeProvider
        let origEth = config.legacyEthereumRPC
        let origBtc = config.legacyBitcoinAPI
        let origLtc = config.legacyLitecoinAPI
        let origSol = config.legacySolanaRPC
        let origTron = config.legacyTronAPI
        let origChainId = config.evmChainId
        let origBtcTestnet = config.btcTestnet
        let origSolDevnet = config.solDevnet
        let origEthWSS = config.ethereumWSS
        let origSolWSS = config.solanaWSS
        defer {
            config.activeProvider = origProvider
            config.legacyEthereumRPC = origEth
            config.legacyBitcoinAPI = origBtc
            config.legacyLitecoinAPI = origLtc
            config.legacySolanaRPC = origSol
            config.legacyTronAPI = origTron
            config.evmChainId = origChainId
            config.btcTestnet = origBtcTestnet
            config.solDevnet = origSolDevnet
            config.ethereumWSS = origEthWSS
            config.solanaWSS = origSolWSS
        }

        config.activeProvider = .alchemy

        let legacy = """
        {"bitcoinAPI":"https://blockstream.info/api","btcTestnet":false,\
        "ethereumRPC":"https://ethereum-rpc.publicnode.com","evmChainId":1,\
        "litecoinAPI":"https://litecoinspace.org/api","solDevnet":false,\
        "solanaRPC":"https://solana-rpc.publicnode.com","tronAPI":"https://api.trongrid.io"}
        """
        guard let snap = RPCConfigSnapshot.decode(legacy) else {
            return XCTFail("legacy export must decode")
        }
        snap.apply(to: config)
        XCTAssertEqual(config.activeProvider, .alchemy,
                       "a legacy import must not wipe the active provider")
    }

    /// diffRows must include a provider row when the snapshot has a version
    /// field and the provider differs. Deleting the provider row from diffRows
    /// makes this test go RED (mutation 1).
    func test_diffRows_includesProviderRow() {
        let config = NetworkConfig.shared
        let origProvider = config.activeProvider
        defer { config.activeProvider = origProvider }

        config.activeProvider = nil

        var snap = RPCConfigSnapshot(from: config)
        snap.activeProvider = .infura

        let rows = snap.diffRows(against: config)
        XCTAssertTrue(rows.contains(where: { $0.after == NodeProvider.infura.displayName }),
                      "diffRows must include a provider row when the provider changes")
    }

    /// diffRows must include per-chain override rows when the snapshot has a
    /// version field and the overrides differ. Deleting the override rows from
    /// diffRows makes this test go RED (mutation 2).
    func test_diffRows_includesOverrideRows() {
        let config = NetworkConfig.shared
        let origProvider = config.activeProvider
        defer { config.activeProvider = origProvider }

        // setUp already cleared overrides; no live overrides needed.
        config.activeProvider = .drpc

        var snap = RPCConfigSnapshot(from: config)
        snap.chainOverrides = ["Scroll": "https://my-scroll.example"]

        let rows = snap.diffRows(against: config)
        XCTAssertTrue(rows.contains(where: { $0.label == "Scroll" }),
                      "diffRows must include a row for each differing chain override")
    }

    /// An unrecognised chain key must survive a full export → apply → export
    /// cycle. Fails if replaceAll(with:) drops keys it cannot map to Chain.
    func test_snapshot_unrecognisedKeyPreservedThroughRoundTrip() {
        let config = NetworkConfig.shared
        let origProvider = config.activeProvider
        let origEthWSS = config.ethereumWSS
        let origSolWSS = config.solanaWSS
        defer {
            config.activeProvider = origProvider
            config.ethereumWSS = origEthWSS
            config.solanaWSS = origSolWSS
        }

        // Inject a raw unknown key directly into storage via replaceAll.
        ChainEndpointOverrides.shared.replaceAll(with: ["FutureChain": "https://future.example"])
        config.activeProvider = nil

        // First export.
        guard let json1 = RPCConfigSnapshot(from: config).jsonString(),
              let snap1 = RPCConfigSnapshot.decode(json1) else {
            return XCTFail("first export failed to round-trip")
        }
        XCTAssertEqual(snap1.chainOverrides?["FutureChain"], "https://future.example",
                       "unknown key must appear in the exported chainOverrides")

        // Apply into a clean store.
        ChainEndpointOverrides.shared.removeAll()
        snap1.apply(to: config)

        XCTAssertEqual(ChainEndpointOverrides.shared.snapshot()["FutureChain"],
                       "https://future.example",
                       "unknown key must survive apply — replaceAll must not drop it")

        // Second export: key must still be present.
        guard let json2 = RPCConfigSnapshot(from: config).jsonString(),
              let snap2 = RPCConfigSnapshot.decode(json2) else {
            return XCTFail("second export failed to round-trip")
        }
        XCTAssertEqual(snap2.chainOverrides?["FutureChain"], "https://future.example",
                       "unknown key must appear in the second export")
    }

    /// An import whose only changes are on unrecognised chains must still
    /// produce non-empty diffRows. Fails if unknown-key rows are filtered
    /// out of diffRows (mutation 3).
    func test_snapshot_unrecognisedOnlyImport_hasNonEmptyDiffRows() {
        let config = NetworkConfig.shared
        let origProvider = config.activeProvider
        defer { config.activeProvider = origProvider }

        // No live overrides (setUp cleared them); no active provider.
        config.activeProvider = nil

        // Snapshot matches live config except for one unrecognised chain.
        var snap = RPCConfigSnapshot(from: config)
        snap.chainOverrides = ["FutureChain": "https://future.example"]

        let rows = snap.diffRows(against: config)
        XCTAssertFalse(rows.isEmpty,
                       "an import with only unrecognised chains must not produce an empty diff")
        XCTAssertTrue(rows.contains(where: { $0.label == "FutureChain" }),
                      "diffRows must include a row for the unrecognised chain key")
    }

    /// replaceAll(with:) must trim whitespace from values. Fails if trimming
    /// is removed (mutation 2 for replaceAll).
    func test_snapshot_applyTrimsOverrideURLWhitespace() {
        let config = NetworkConfig.shared
        let origProvider = config.activeProvider
        let origEthWSS = config.ethereumWSS
        let origSolWSS = config.solanaWSS
        defer {
            config.activeProvider = origProvider
            config.ethereumWSS = origEthWSS
            config.solanaWSS = origSolWSS
        }

        var snap = RPCConfigSnapshot(from: config)
        snap.chainOverrides = ["Scroll": "  https://trimmed.example  "]

        snap.apply(to: config)

        XCTAssertEqual(ChainEndpointOverrides.shared.url(for: .scroll), "https://trimmed.example",
                       "replaceAll must trim whitespace from URL values")
    }

    // MARK: - decodeWithReason failure classification (Items 1 & 3)

    /// A future-version payload must yield .versionTooNew, not .malformed.
    /// Changing .versionTooNew to .malformed in decodeWithReason makes this RED.
    func test_decodeWithReason_futureVersionGivesVersionTooNew() {
        let future = """
        {"version":99,\
        "bitcoinAPI":"https://blockstream.info/api","btcTestnet":false,\
        "ethereumRPC":"https://ethereum-rpc.publicnode.com","evmChainId":1,\
        "litecoinAPI":"https://litecoinspace.org/api","solDevnet":false,\
        "solanaRPC":"https://solana-rpc.publicnode.com","tronAPI":"https://api.trongrid.io"}
        """
        guard case .failure(let reason) = RPCConfigSnapshot.decodeWithReason(future) else {
            return XCTFail("expected failure for future-version payload")
        }
        XCTAssertEqual(reason, .versionTooNew,
                       "a future-version payload must yield .versionTooNew, not .malformed")
    }

    /// Malformed JSON must yield .malformed, not .versionTooNew.
    func test_decodeWithReason_malformedJSONGivesMalformed() {
        guard case .failure(let reason) = RPCConfigSnapshot.decodeWithReason("not json {{") else {
            return XCTFail("expected failure for malformed JSON")
        }
        XCTAssertEqual(reason, .malformed,
                       "malformed JSON must yield .malformed")
    }

    // MARK: - chainOverrides size limits

    /// A payload at exactly the entry-count ceiling must be accepted.
    func test_decodeWithReason_atEntryLimitIsAccepted() {
        let overrides = (0..<RPCConfigSnapshot.maxChainOverrides)
            .map { "\"Key\($0)\":\"https://example.com/\($0)\"" }
            .joined(separator: ",")
        let json = minimalV2JSON(extraFields: "\"chainOverrides\":{\(overrides)}")
        XCTAssertNotNil(RPCConfigSnapshot.decode(json),
                        "a payload at the entry-count ceiling must be accepted")
    }

    /// One entry over the ceiling must be rejected with .oversized.
    func test_decodeWithReason_overEntryLimitIsRejected() {
        let overrides = (0...RPCConfigSnapshot.maxChainOverrides) // count = limit + 1
            .map { "\"Key\($0)\":\"https://example.com/\($0)\"" }
            .joined(separator: ",")
        let json = minimalV2JSON(extraFields: "\"chainOverrides\":{\(overrides)}")
        guard case .failure(let reason) = RPCConfigSnapshot.decodeWithReason(json) else {
            return XCTFail("expected failure for over-limit entry count")
        }
        XCTAssertEqual(reason, .oversized)
    }

    /// A value at exactly the value-length ceiling must be accepted.
    func test_decodeWithReason_atValueLengthLimitIsAccepted() {
        let longURL = "https://example.com/" + String(repeating: "a", count: RPCConfigSnapshot.maxOverrideValueLength - 20)
        let json = minimalV2JSON(extraFields: "\"chainOverrides\":{\"Scroll\":\"\(longURL)\"}")
        XCTAssertNotNil(RPCConfigSnapshot.decode(json),
                        "a value at the length ceiling must be accepted")
    }

    /// One character over the value-length ceiling must be rejected with .oversized.
    func test_decodeWithReason_overValueLengthLimitIsRejected() {
        let tooLong = "https://example.com/" + String(repeating: "a", count: RPCConfigSnapshot.maxOverrideValueLength)
        let json = minimalV2JSON(extraFields: "\"chainOverrides\":{\"Scroll\":\"\(tooLong)\"}")
        guard case .failure(let reason) = RPCConfigSnapshot.decodeWithReason(json) else {
            return XCTFail("expected failure for over-limit value length")
        }
        XCTAssertEqual(reason, .oversized)
    }

    /// A key at exactly the key-length ceiling must be accepted.
    func test_decodeWithReason_atKeyLengthLimitIsAccepted() {
        let longKey = String(repeating: "K", count: RPCConfigSnapshot.maxOverrideKeyLength)
        let json = minimalV2JSON(extraFields: "\"chainOverrides\":{\"\(longKey)\":\"https://example.com\"}")
        XCTAssertNotNil(RPCConfigSnapshot.decode(json),
                        "a key at the length ceiling must be accepted")
    }

    /// One character over the key-length ceiling must be rejected with .oversized.
    func test_decodeWithReason_overKeyLengthLimitIsRejected() {
        let tooLong = String(repeating: "K", count: RPCConfigSnapshot.maxOverrideKeyLength + 1)
        let json = minimalV2JSON(extraFields: "\"chainOverrides\":{\"\(tooLong)\":\"https://example.com\"}")
        guard case .failure(let reason) = RPCConfigSnapshot.decodeWithReason(json) else {
            return XCTFail("expected failure for over-limit key length")
        }
        XCTAssertEqual(reason, .oversized)
    }

    // MARK: - unrecognisedChainKeys

    /// A snapshot with mixed known/unknown keys returns only the unknown ones, sorted.
    /// Hard-coding unrecognisedChainKeys to [] makes this RED (reviewer's mutation 2).
    func test_unrecognisedChainKeys_returnsOnlyUnknownKeysSorted() {
        var snap = RPCConfigSnapshot(from: NetworkConfig.shared)
        snap.chainOverrides = [
            "Ethereum": "https://eth.example",   // known
            "ZFuture":  "https://future.example", // unknown
            "AAFuture":  "https://a.example",     // unknown — sorts before ZFuture
        ]
        let keys = snap.unrecognisedChainKeys
        XCTAssertEqual(keys, ["AAFuture", "ZFuture"],
                       "only unrecognised keys, sorted ascending")
    }

    /// A snapshot with only known chain keys returns empty.
    func test_unrecognisedChainKeys_emptyWhenAllKnown() {
        var snap = RPCConfigSnapshot(from: NetworkConfig.shared)
        snap.chainOverrides = ["Ethereum": "https://eth.example", "Scroll": "https://scroll.example"]
        XCTAssertTrue(snap.unrecognisedChainKeys.isEmpty,
                      "no unrecognised keys when all chains are known")
    }

    /// A snapshot with nil overrides returns empty.
    func test_unrecognisedChainKeys_emptyWhenNilOverrides() {
        var snap = RPCConfigSnapshot(from: NetworkConfig.shared)
        snap.chainOverrides = nil
        XCTAssertTrue(snap.unrecognisedChainKeys.isEmpty,
                      "no unrecognised keys when overrides is nil")
    }

    // MARK: - apply / diffRows lockstep (Item 4)
    //
    // (a) No false promises: apply all changes, then diffRows must be empty.
    //     Catches rows diffRows displays that apply does NOT write —
    //     such a row would still appear after the apply.
    //
    // (b) No invisible changes (two sub-cases, one field each):
    //     For a given field that apply writes, diffRows must include a row.
    //     Catches fields apply writes that diffRows omits.
    //     Direction (a) cannot detect this: if diffRows omits the field, the
    //     result is empty before AND after apply, so (a) passes vacuously.

    /// (a) After apply, diffRows must be empty — no false promises.
    func test_applyAndDiffRows_noFalsePromises() {
        let config = NetworkConfig.shared
        let origProvider = config.activeProvider
        let origEth = config.legacyEthereumRPC
        let origBtc = config.legacyBitcoinAPI
        let origLtc = config.legacyLitecoinAPI
        let origSol = config.legacySolanaRPC
        let origTron = config.legacyTronAPI
        let origChainId = config.evmChainId
        let origBtcTestnet = config.btcTestnet
        let origSolDevnet = config.solDevnet
        let origEthWSS = config.ethereumWSS
        let origSolWSS = config.solanaWSS
        defer {
            config.activeProvider = origProvider
            config.legacyEthereumRPC = origEth
            config.legacyBitcoinAPI = origBtc
            config.legacyLitecoinAPI = origLtc
            config.legacySolanaRPC = origSol
            config.legacyTronAPI = origTron
            config.evmChainId = origChainId
            config.btcTestnet = origBtcTestnet
            config.solDevnet = origSolDevnet
            config.ethereumWSS = origEthWSS
            config.solanaWSS = origSolWSS
        }

        // Build a snapshot that differs from live in every field.
        var snap = RPCConfigSnapshot(from: config)
        snap.version = RPCConfigSnapshot.currentVersion
        snap.ethereumRPC = "https://eth2.example"
        snap.bitcoinAPI  = "https://btc2.example"
        snap.litecoinAPI = "https://ltc2.example"
        snap.solanaRPC   = "https://sol2.example"
        snap.tronAPI     = "https://tron2.example"
        snap.evmChainId  = (config.evmChainId == 1) ? 137 : 1
        snap.btcTestnet  = !config.btcTestnet
        snap.solDevnet   = !config.solDevnet
        snap.ethereumWSS = "wss://eth-ws.example"
        snap.solanaWSS   = "wss://sol-ws.example"
        snap.activeProvider = (config.activeProvider == .alchemy) ? .infura : .alchemy
        snap.chainOverrides = ["Scroll": "https://scroll.example"]

        snap.apply(to: config)

        let remaining = snap.diffRows(against: config)
        XCTAssertTrue(remaining.isEmpty,
                      "diffRows must be empty after applying: \(remaining.map(\.label))")
    }

    /// (b) No invisible changes — activeProvider alone triggers a diff row.
    /// Deleting the provider row from diffRows makes this RED (mutation 4).
    func test_applyAndDiffRows_providerFieldIsVisible() {
        let config = NetworkConfig.shared
        let origProvider = config.activeProvider
        defer { config.activeProvider = origProvider }

        config.activeProvider = nil
        var snap = RPCConfigSnapshot(from: config)
        snap.activeProvider = (origProvider == .alchemy) ? .infura : .alchemy

        let rows = snap.diffRows(against: config)
        XCTAssertFalse(rows.isEmpty,
                       "a differing activeProvider must produce at least one diff row")
        XCTAssertTrue(rows.contains(where: { $0.label == L10n.NodeSettings.providerPicker }),
                      "the diff row must be labelled with the provider picker label")
    }

    /// (b) No invisible changes — a chain override alone triggers a diff row.
    func test_applyAndDiffRows_chainOverrideFieldIsVisible() {
        let config = NetworkConfig.shared
        let origProvider = config.activeProvider
        let origEthWSS = config.ethereumWSS
        let origSolWSS = config.solanaWSS
        defer {
            config.activeProvider = origProvider
            config.ethereumWSS = origEthWSS
            config.solanaWSS = origSolWSS
        }

        // Start from a clean state (setUp cleared overrides).
        config.activeProvider = nil
        var snap = RPCConfigSnapshot(from: config)
        snap.chainOverrides = ["Scroll": "https://scroll-only.example"]

        let rows = snap.diffRows(against: config)
        XCTAssertFalse(rows.isEmpty,
                       "a differing chain override must produce at least one diff row")
        XCTAssertTrue(rows.contains(where: { $0.label == "Scroll" }),
                      "the diff row must be labelled with the chain key")
    }

    // MARK: - Helpers

    /// Builds a minimal version-2 JSON string with extra fields injected.
    private func minimalV2JSON(extraFields: String) -> String {
        """
        {"version":2,\
        "bitcoinAPI":"https://blockstream.info/api","btcTestnet":false,\
        "ethereumRPC":"https://ethereum-rpc.publicnode.com","evmChainId":1,\
        "litecoinAPI":"https://litecoinspace.org/api","solDevnet":false,\
        "solanaRPC":"https://solana-rpc.publicnode.com","tronAPI":"https://api.trongrid.io",\
        \(extraFields)}
        """
    }
}
