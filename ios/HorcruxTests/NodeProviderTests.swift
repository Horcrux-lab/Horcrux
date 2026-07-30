import XCTest
@testable import Horcrux

final class NodeProviderTests: XCTestCase {

    func test_alchemy_servesPolygon_withItsOwnTemplate() {
        let url = NodeProvider.alchemy.template(for: .polygon, evmChainId: 1, solanaMainnet: true)
        XCTAssertEqual(url, "https://polygon-mainnet.g.alchemy.com/v2/{KEY}")
    }

    /// Alchemy has no BNB product. Returning a wrong-chain URL here would
    /// send Ethereum traffic to a BNB address, so the gap must be nil.
    func test_alchemy_doesNotServeBNB() {
        XCTAssertNil(NodeProvider.alchemy.template(for: .bnb, evmChainId: 1, solanaMainnet: true))
    }

    /// Ethereum occupies the app's one user-selectable EVM slot, so it is
    /// the only chain whose template follows evmChainId.
    func test_ethereumTemplate_followsTheEVMChainIdToggle() {
        XCTAssertEqual(NodeProvider.alchemy.template(for: .ethereum, evmChainId: 1, solanaMainnet: true),
                       "https://eth-mainnet.g.alchemy.com/v2/{KEY}")
        XCTAssertEqual(NodeProvider.alchemy.template(for: .ethereum, evmChainId: 11_155_111, solanaMainnet: true),
                       "https://eth-sepolia.g.alchemy.com/v2/{KEY}")
    }

    /// The Ethereum slot accepts any of the eleven EVMNetwork values, not
    /// just mainnet and Sepolia. Pinned so nobody "simplifies" the
    /// `?? .mainnet` fallback into a wrong-chain bug.
    func test_ethereumSlot_followsAnyEVMNetworkSelection() {
        XCTAssertEqual(NodeProvider.alchemy.template(for: .ethereum, evmChainId: 137, solanaMainnet: true),
                       "https://polygon-mainnet.g.alchemy.com/v2/{KEY}")
    }

    /// An unrecognised stored chain ID must land somewhere real rather
    /// than returning nil and stranding the Ethereum slot.
    func test_unknownEVMChainId_fallsBackToMainnet() {
        XCTAssertEqual(NodeProvider.alchemy.template(for: .ethereum, evmChainId: 999_999, solanaMainnet: true),
                       "https://eth-mainnet.g.alchemy.com/v2/{KEY}")
    }

    /// No provider in this enum serves the non-EVM, non-Solana chains.
    func test_noProvider_claimsBitcoinLitecoinOrTron() {
        for provider in NodeProvider.allCases {
            for chain in [Chain.bitcoin, .litecoin, .tron] {
                for solanaMainnet in [true, false] {
                    XCTAssertNil(provider.template(for: chain, evmChainId: 1,
                                                   solanaMainnet: solanaMainnet),
                                 "\(provider) must not claim \(chain)")
                }
            }
        }
    }

    /// Every template must carry the placeholder, or substituteAPIKey
    /// silently returns it unchanged and the key is never applied.
    func test_everyTemplate_containsTheKeyPlaceholder() {
        var checked = 0
        for provider in NodeProvider.allCases {
            for chain in Chain.allCases {
                guard let t = provider.template(for: chain, evmChainId: 1,
                                                solanaMainnet: true) else { continue }
                checked += 1
                XCTAssertTrue(t.contains("{KEY}"), "\(provider)/\(chain): \(t)")
            }
        }
        // Exact, not `> 0`: a regression that nils out most providers would
        // otherwise still report green on the placeholder invariant.
        XCTAssertEqual(checked, expectedMainnetTemplateCount)
    }

    /// Alchemy's exact coverage on mainnet. An exact set fails loudly if
    /// the matrix drifts; a `contains` spot-check would not.
    func test_coveredChains_matchesTheDocumentedMatrix() {
        let uncovered = NodeProvider.alchemy.uncoveredChains(evmChainId: 1, solanaMainnet: true)
        XCTAssertEqual(uncovered, [.bnb, .bitcoin, .litecoin, .tron])
    }

    // MARK: - Solana cluster safety

    /// Solana addresses are byte-identical across clusters, so a provider
    /// that only has a mainnet host must return nil on devnet rather than
    /// hand back the mainnet URL. Ankr and dRPC are exactly that case.
    func test_ankrAndDRPC_returnNilOnSolanaDevnet() {
        XCTAssertEqual(NodeProvider.ankr.template(for: .solana, evmChainId: 1, solanaMainnet: true),
                       "https://rpc.ankr.com/solana/{KEY}")
        XCTAssertNil(NodeProvider.ankr.template(for: .solana, evmChainId: 1, solanaMainnet: false))

        XCTAssertEqual(NodeProvider.drpc.template(for: .solana, evmChainId: 1, solanaMainnet: true),
                       "https://lb.drpc.org/ogrpc?network=solana&dkey={KEY}")
        XCTAssertNil(NodeProvider.drpc.template(for: .solana, evmChainId: 1, solanaMainnet: false))
    }

    /// No Solana template may point at a mainnet host while the caller
    /// asked for devnet. This is the invariant that matters most here.
    func test_noSolanaDevnetTemplate_pointsAtAMainnetHost() {
        for provider in NodeProvider.allCases {
            guard let t = provider.template(for: .solana, evmChainId: 1,
                                            solanaMainnet: false) else { continue }
            XCTAssertFalse(t.contains("mainnet"), "\(provider) devnet template: \(t)")
            XCTAssertFalse(t.contains("rpc.ankr.com/solana"), "\(provider) devnet template: \(t)")
            XCTAssertFalse(t.contains("network=solana"), "\(provider) devnet template: \(t)")
        }
    }

    func test_solanaMainnetTemplates_areExact() {
        XCTAssertEqual(NodeProvider.alchemy.template(for: .solana, evmChainId: 1, solanaMainnet: true),
                       "https://solana-mainnet.g.alchemy.com/v2/{KEY}")
        XCTAssertNil(NodeProvider.blockpi.template(for: .solana, evmChainId: 1, solanaMainnet: true))
        XCTAssertNil(NodeProvider.nodeReal.template(for: .solana, evmChainId: 1, solanaMainnet: true))
        XCTAssertNil(NodeProvider.tenderly.template(for: .solana, evmChainId: 1, solanaMainnet: true))
    }

    /// Coverage must depend only on its arguments. If this ever fails,
    /// something started reading NetworkConfig.shared again.
    func test_coverage_isPureAcrossTheDevnetToggle() {
        let previous = NetworkConfig.shared.solDevnet
        defer { NetworkConfig.shared.solDevnet = previous }

        NetworkConfig.shared.solDevnet = false
        let a = NodeProvider.ankr.coveredChains(evmChainId: 1, solanaMainnet: true)
        NetworkConfig.shared.solDevnet = true
        let b = NodeProvider.ankr.coveredChains(evmChainId: 1, solanaMainnet: true)
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.contains(.solana))

        XCTAssertFalse(NodeProvider.ankr
            .coveredChains(evmChainId: 1, solanaMainnet: false).contains(.solana))
    }

    /// Derived from the matrix rather than hand-counted, so the assertion
    /// above stays honest when a provider or chain is added.
    private var expectedMainnetTemplateCount: Int {
        NodeProvider.allCases.reduce(0) {
            $0 + $1.coveredChains(evmChainId: 1, solanaMainnet: true).count
        }
    }

    func test_keyLookup_readsTheProvidersOwnKeychainField() {
        let config = NetworkConfig.shared
        let previous = NodeProvider.allCases.map { ($0, config.apiKey(for: $0)) }
        defer { restoreKeys(previous, on: config) }

        config.alchemyAPIKey = "alchemy-test"
        config.infuraAPIKey = "infura-test"
        config.ankrAPIKey = ""

        XCTAssertEqual(config.apiKey(for: .alchemy), "alchemy-test")
        XCTAssertEqual(config.apiKey(for: .infura), "infura-test")
        XCTAssertEqual(config.apiKey(for: .ankr), "")
    }

    /// Restores rather than blanks: leaking "" into the shared config would
    /// be the same class of cross-test contamination that made the Solana
    /// assertions cluster-dependent before Task 1 was fixed.
    private func restoreKeys(_ saved: [(NodeProvider, String)], on config: NetworkConfig) {
        for (provider, value) in saved {
            switch provider {
            case .alchemy:  config.alchemyAPIKey = value
            case .infura:   config.infuraAPIKey = value
            case .ankr:     config.ankrAPIKey = value
            case .blockpi:  config.blockpiAPIKey = value
            case .drpc:     config.drpcAPIKey = value
            case .nodeReal: config.nodeRealAPIKey = value
            case .tenderly: config.tenderlyAPIKey = value
            case .oneRPC:   config.oneRPCAPIKey = value
            }
        }
    }
}
