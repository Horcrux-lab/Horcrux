import XCTest
@testable import Horcrux

final class NodeProviderTests: XCTestCase {

    func test_alchemy_servesPolygon_withItsOwnTemplate() {
        let url = NodeProvider.alchemy.template(for: .polygon, evmChainId: 1)
        XCTAssertEqual(url, "https://polygon-mainnet.g.alchemy.com/v2/{KEY}")
    }

    /// Alchemy has no BNB product. Returning a wrong-chain URL here would
    /// send Ethereum traffic to a BNB address, so the gap must be nil.
    func test_alchemy_doesNotServeBNB() {
        XCTAssertNil(NodeProvider.alchemy.template(for: .bnb, evmChainId: 1))
    }

    /// Ethereum is the one EVM chain whose network is user-selectable.
    func test_ethereumTemplate_followsTheEVMChainIdToggle() {
        XCTAssertEqual(NodeProvider.alchemy.template(for: .ethereum, evmChainId: 1),
                       "https://eth-mainnet.g.alchemy.com/v2/{KEY}")
        XCTAssertEqual(NodeProvider.alchemy.template(for: .ethereum, evmChainId: 11_155_111),
                       "https://eth-sepolia.g.alchemy.com/v2/{KEY}")
    }

    /// No provider in this enum serves the non-EVM, non-Solana chains.
    func test_noProvider_claimsBitcoinLitecoinOrTron() {
        for provider in NodeProvider.allCases {
            for chain in [Chain.bitcoin, .litecoin, .tron] {
                XCTAssertNil(provider.template(for: chain, evmChainId: 1),
                             "\(provider) must not claim \(chain)")
            }
        }
    }

    /// Every template must carry the placeholder, or substituteAPIKey
    /// silently returns it unchanged and the key is never applied.
    func test_everyTemplate_containsTheKeyPlaceholder() {
        var checked = 0
        for provider in NodeProvider.allCases {
            for chain in Chain.allCases {
                guard let t = provider.template(for: chain, evmChainId: 1) else { continue }
                checked += 1
                XCTAssertTrue(t.contains("{KEY}"), "\(provider)/\(chain): \(t)")
            }
        }
        XCTAssertGreaterThan(checked, 0)
    }

    func test_coveredChains_matchesTheDocumentedMatrix() {
        let covered = NodeProvider.alchemy.coveredChains(evmChainId: 1)
        XCTAssertTrue(covered.contains(.polygon))
        XCTAssertTrue(covered.contains(.solana))
        XCTAssertFalse(covered.contains(.bnb))
        XCTAssertFalse(covered.contains(.bitcoin))
    }

    func test_uncoveredChains_isTheComplementOverAllChains() {
        let uncovered = NodeProvider.alchemy.uncoveredChains(evmChainId: 1)
        XCTAssertTrue(uncovered.contains(.bnb))
        XCTAssertTrue(uncovered.contains(.bitcoin))
        XCTAssertFalse(uncovered.contains(.polygon))
        XCTAssertEqual(uncovered.count, Chain.allCases.count
                       - NodeProvider.alchemy.coveredChains(evmChainId: 1).count)
    }
}
