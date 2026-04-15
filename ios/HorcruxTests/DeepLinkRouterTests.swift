import XCTest
@testable import Horcrux

/// Tests for DeepLinkRouter URL parsing and deep link handling.
final class DeepLinkRouterTests: XCTestCase {

    private var router: DeepLinkRouter!

    @MainActor
    override func setUp() {
        super.setUp()
        router = DeepLinkRouter.shared
        router.pendingLink = nil
    }

    // MARK: - parseURL: sign / join

    @MainActor
    func test_parseURL_signHost_returnsJoinSession() {
        let url = URL(string: "horcrux://sign?session=abc123")!
        let result = router.parseURL(url)
        XCTAssertEqual(result, .joinSession(sessionId: "abc123"))
    }

    @MainActor
    func test_parseURL_joinHost_returnsJoinSession() {
        let url = URL(string: "horcrux://join?session=abc123")!
        let result = router.parseURL(url)
        XCTAssertEqual(result, .joinSession(sessionId: "abc123"))
    }

    // MARK: - parseURL: tx

    @MainActor
    func test_parseURL_txHost_returnsTransactionDetail() {
        let url = URL(string: "horcrux://tx?hash=0xabc")!
        let result = router.parseURL(url)
        XCTAssertEqual(result, .transactionDetail(txHash: "0xabc"))
    }

    // MARK: - parseURL: receive

    @MainActor
    func test_parseURL_receiveHost_returnsReceiveWithChain() {
        let url = URL(string: "horcrux://receive?address=0x123&chain=ETH")!
        let result = router.parseURL(url)
        XCTAssertEqual(result, .receive(address: "0x123", chain: "ETH"))
    }

    @MainActor
    func test_parseURL_receiveHost_chainIsOptional() {
        let url = URL(string: "horcrux://receive?address=0x456")!
        let result = router.parseURL(url)
        XCTAssertEqual(result, .receive(address: "0x456", chain: nil))
    }

    // MARK: - Invalid URLs

    @MainActor
    func test_parseURL_invalidScheme_returnsNil() {
        let url = URL(string: "https://sign?session=abc123")!
        XCTAssertNil(router.parseURL(url))
    }

    @MainActor
    func test_parseURL_unknownHost_returnsNil() {
        let url = URL(string: "horcrux://unknown?foo=bar")!
        XCTAssertNil(router.parseURL(url))
    }

    // MARK: - Missing / empty required params

    @MainActor
    func test_parseURL_signMissingSession_returnsNil() {
        let url = URL(string: "horcrux://sign")!
        XCTAssertNil(router.parseURL(url))
    }

    @MainActor
    func test_parseURL_signEmptySession_returnsNil() {
        let url = URL(string: "horcrux://sign?session=")!
        XCTAssertNil(router.parseURL(url))
    }

    @MainActor
    func test_parseURL_txMissingHash_returnsNil() {
        let url = URL(string: "horcrux://tx")!
        XCTAssertNil(router.parseURL(url))
    }

    @MainActor
    func test_parseURL_txEmptyHash_returnsNil() {
        let url = URL(string: "horcrux://tx?hash=")!
        XCTAssertNil(router.parseURL(url))
    }

    @MainActor
    func test_parseURL_receiveMissingAddress_returnsNil() {
        let url = URL(string: "horcrux://receive?chain=ETH")!
        XCTAssertNil(router.parseURL(url))
    }

    @MainActor
    func test_parseURL_receiveEmptyAddress_returnsNil() {
        let url = URL(string: "horcrux://receive?address=&chain=ETH")!
        XCTAssertNil(router.parseURL(url))
    }

    // MARK: - handle / consumePendingLink

    @MainActor
    func test_handle_setsPendingLink() {
        let link = DeepLink.joinSession(sessionId: "s1")
        router.handle(link)
        XCTAssertEqual(router.pendingLink, link)
    }

    @MainActor
    func test_consumePendingLink_returnsAndClears() {
        router.handle(.transactionDetail(txHash: "0xabc"))
        let consumed = router.consumePendingLink()
        XCTAssertEqual(consumed, .transactionDetail(txHash: "0xabc"))
        XCTAssertNil(router.pendingLink)
    }

    @MainActor
    func test_consumePendingLink_whenNoPending_returnsNil() {
        XCTAssertNil(router.consumePendingLink())
    }

    // MARK: - DeepLink Equatable

    func test_deepLinkEquatable_sameValues() {
        XCTAssertEqual(
            DeepLink.joinSession(sessionId: "x"),
            DeepLink.joinSession(sessionId: "x")
        )
        XCTAssertNotEqual(
            DeepLink.joinSession(sessionId: "x"),
            DeepLink.joinSession(sessionId: "y")
        )
    }

    func test_deepLinkEquatable_differentCases() {
        XCTAssertNotEqual(
            DeepLink.joinSession(sessionId: "abc"),
            DeepLink.transactionDetail(txHash: "abc")
        )
    }
}
