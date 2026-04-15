import XCTest
@testable import Horcrux

/// Tests for NetworkConfig, NetworkPreset, and rpcURL routing.
final class NetworkConfigTests: XCTestCase {

    // MARK: - rpcURL(for:)

    @MainActor
    func test_rpcURL_forEthereum_returnsEthereumRPC() {
        let config = NetworkConfig.shared
        XCTAssertEqual(config.rpcURL(for: .ethereum), config.ethereumRPC)
    }

    @MainActor
    func test_rpcURL_forBitcoin_returnsBitcoinAPI() {
        let config = NetworkConfig.shared
        XCTAssertEqual(config.rpcURL(for: .bitcoin), config.bitcoinAPI)
    }

    @MainActor
    func test_rpcURL_forSolana_returnsSolanaRPC() {
        let config = NetworkConfig.shared
        XCTAssertEqual(config.rpcURL(for: .solana), config.solanaRPC)
    }

    // MARK: - NetworkPreset.mainnet

    func test_mainnetPreset_hasCorrectValues() {
        let p = NetworkPreset.mainnet
        XCTAssertEqual(p.id, "mainnet")
        XCTAssertEqual(p.name, "Mainnet")
        XCTAssertEqual(p.ethereumRPC, "https://eth.llamarpc.com")
        XCTAssertEqual(p.bitcoinAPI, "https://blockstream.info/api")
        XCTAssertEqual(p.solanaRPC, "https://api.mainnet-beta.solana.com")
        XCTAssertEqual(p.evmChainId, 1)
        XCTAssertFalse(p.btcTestnet)
        XCTAssertFalse(p.solDevnet)
    }

    // MARK: - NetworkPreset.testnet

    func test_testnetPreset_hasCorrectValues() {
        let p = NetworkPreset.testnet
        XCTAssertEqual(p.id, "testnet")
        XCTAssertEqual(p.name, "Testnet")
        XCTAssertEqual(p.ethereumRPC, "https://eth-sepolia.public.blastapi.io")
        XCTAssertEqual(p.bitcoinAPI, "https://blockstream.info/testnet/api")
        XCTAssertEqual(p.solanaRPC, "https://api.devnet.solana.com")
        XCTAssertEqual(p.evmChainId, 11155111)
        XCTAssertTrue(p.btcTestnet)
        XCTAssertTrue(p.solDevnet)
    }

    // MARK: - NetworkPreset.all

    func test_allPresets_containsMainnetAndTestnet() {
        XCTAssertEqual(NetworkPreset.all.count, 2)
        XCTAssertEqual(NetworkPreset.all.map(\.id), ["mainnet", "testnet"])
    }

    // MARK: - applyPreset

    @MainActor
    func test_applyPreset_testnet_updatesConfig() {
        let config = NetworkConfig.shared
        let originalETH = config.ethereumRPC

        config.applyPreset(.testnet)
        XCTAssertEqual(config.ethereumRPC, NetworkPreset.testnet.ethereumRPC)
        XCTAssertEqual(config.bitcoinAPI, NetworkPreset.testnet.bitcoinAPI)
        XCTAssertEqual(config.solanaRPC, NetworkPreset.testnet.solanaRPC)
        XCTAssertEqual(config.evmChainId, 11155111)
        XCTAssertTrue(config.btcTestnet)
        XCTAssertTrue(config.solDevnet)

        // Restore mainnet to avoid polluting other tests
        config.applyPreset(.mainnet)
        XCTAssertEqual(config.ethereumRPC, NetworkPreset.mainnet.ethereumRPC)
    }

    // MARK: - resetToDefaults

    @MainActor
    func test_resetToDefaults_restoresMainnetValues() {
        let config = NetworkConfig.shared
        config.applyPreset(.testnet)

        config.resetToDefaults()
        XCTAssertEqual(config.ethereumRPC, "https://eth.llamarpc.com")
        XCTAssertEqual(config.bitcoinAPI, "https://blockstream.info/api")
        XCTAssertEqual(config.solanaRPC, "https://api.mainnet-beta.solana.com")
        XCTAssertEqual(config.evmChainId, 1)
        XCTAssertFalse(config.btcTestnet)
        XCTAssertFalse(config.solDevnet)
    }

    // MARK: - NetworkPreset Identifiable

    func test_presetIdentifiable_idIsUnique() {
        let ids = NetworkPreset.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "Preset IDs should be unique")
    }

    // MARK: - rpcURL after preset change

    @MainActor
    func test_rpcURL_afterTestnetPreset_returnsTestnetURLs() {
        let config = NetworkConfig.shared
        config.applyPreset(.testnet)

        XCTAssertEqual(config.rpcURL(for: .ethereum), "https://eth-sepolia.public.blastapi.io")
        XCTAssertEqual(config.rpcURL(for: .bitcoin), "https://blockstream.info/testnet/api")
        XCTAssertEqual(config.rpcURL(for: .solana), "https://api.devnet.solana.com")

        // Restore
        config.resetToDefaults()
    }
}
