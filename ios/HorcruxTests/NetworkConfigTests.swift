import XCTest
@testable import Horcrux

/// Tests for NetworkConfig, NetworkPreset, and rpcURL routing.
final class NetworkConfigTests: XCTestCase {

    // MARK: - rpcURL(for:)

    @MainActor
    func test_rpcURL_forEthereum_returnsEthereumRPC() {
        let config = NetworkConfig.shared
        // `rpcURL` may substitute a `{KEY}` placeholder or fall back to
        // a public endpoint when no key is set, so the two values are
        // allowed to differ — but the returned URL must never contain
        // an unsubstituted placeholder (which would be sent to the
        // server literally and 404).
        let resolved = config.rpcURL(for: .ethereum)
        XCTAssertFalse(resolved.contains("{KEY}"))
        XCTAssertFalse(resolved.isEmpty)
    }

    @MainActor
    func test_rpcURL_forBitcoin_returnsBitcoinAPI() {
        let config = NetworkConfig.shared
        XCTAssertEqual(config.rpcURL(for: .bitcoin), config.bitcoinAPI)
    }

    @MainActor
    func test_rpcURL_forSolana_returnsSolanaRPC() {
        let config = NetworkConfig.shared
        let resolved = config.rpcURL(for: .solana)
        XCTAssertFalse(resolved.contains("{KEY}"))
        XCTAssertFalse(resolved.isEmpty)
    }

    // MARK: - NetworkPreset.mainnet

    func test_mainnetPreset_hasCorrectValues() {
        let p = NetworkPreset.mainnet
        XCTAssertEqual(p.id, "mainnet")
        XCTAssertEqual(p.name, "Mainnet")
        // Defaults now point at the Alchemy paid-provider template — the
        // free public URL is used only as a last-resort fallback inside
        // `substituteAPIKey` when no API key is configured.
        XCTAssertEqual(p.ethereumRPC, "https://eth-mainnet.g.alchemy.com/v2/{KEY}")
        XCTAssertEqual(p.bitcoinAPI, "https://mempool.space/api")
        XCTAssertEqual(p.solanaRPC, "https://solana-mainnet.g.alchemy.com/v2/{KEY}")
        XCTAssertEqual(p.evmChainId, 1)
        XCTAssertFalse(p.btcTestnet)
        XCTAssertFalse(p.solDevnet)
    }

    // MARK: - NetworkPreset.testnet

    func test_testnetPreset_hasCorrectValues() {
        let p = NetworkPreset.testnet
        XCTAssertEqual(p.id, "testnet")
        XCTAssertEqual(p.name, "Testnet")
        XCTAssertEqual(p.ethereumRPC, "https://eth-sepolia.g.alchemy.com/v2/{KEY}")
        XCTAssertEqual(p.bitcoinAPI, "https://mempool.space/testnet/api")
        XCTAssertEqual(p.solanaRPC, "https://solana-devnet.g.alchemy.com/v2/{KEY}")
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
        XCTAssertEqual(config.ethereumRPC, "https://eth-mainnet.g.alchemy.com/v2/{KEY}")
        XCTAssertEqual(config.bitcoinAPI, "https://mempool.space/api")
        XCTAssertEqual(config.solanaRPC, "https://solana-mainnet.g.alchemy.com/v2/{KEY}")
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

        // Stored URLs are the Alchemy paid templates; the resolved URL
        // used by actual RPC calls falls back to the public endpoint when
        // no key is present. Both are valid outputs — assert on the
        // fallback since that's what unit tests see.
        XCTAssertEqual(config.ethereumRPC, "https://eth-sepolia.g.alchemy.com/v2/{KEY}")
        let ethResolved = config.rpcURL(for: .ethereum)
        XCTAssertTrue(
            ethResolved == "https://ethereum-sepolia-rpc.publicnode.com"
                || ethResolved.hasPrefix("https://eth-sepolia.g.alchemy.com/v2/"),
            "Unexpected resolved Ethereum URL: \(ethResolved)"
        )
        XCTAssertEqual(config.rpcURL(for: .bitcoin), "https://mempool.space/testnet/api")
        let solResolved = config.rpcURL(for: .solana)
        XCTAssertTrue(
            solResolved == "https://api.devnet.solana.com"
                || solResolved.hasPrefix("https://solana-devnet.g.alchemy.com/v2/"),
            "Unexpected resolved Solana URL: \(solResolved)"
        )

        // Restore
        config.resetToDefaults()
    }
}
