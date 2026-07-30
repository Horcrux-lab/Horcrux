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
}
