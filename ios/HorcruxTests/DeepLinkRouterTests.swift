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
        router.pendingConfirmation = nil
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

    /// A `joinSession` link must not auto-activate: `handle` parks it in
    /// `pendingConfirmation` for the alert in `HorcruxApp`, and `pendingLink`
    /// — the property the app actually navigates off — stays nil until the
    /// user agrees. This is audit finding M7's user-presence gate against a
    /// page opening `horcrux://join?...` to pull the wallet into an
    /// attacker's ceremony.
    ///
    /// Until now this test asserted `pendingLink == link`, the behaviour from
    /// before the gate existed, and so failed on every single run. It was
    /// never noticed because the iOS CI job could not report a failure (see
    /// 441811f) and no test covered the gate at all.
    @MainActor
    func test_handle_joinSession_parksForConfirmationAndDoesNotActivate() {
        let link = DeepLink.joinSession(sessionId: "s1")
        router.handle(link)
        XCTAssertEqual(router.pendingConfirmation, link)
        XCTAssertNil(router.pendingLink)
    }

    /// Read-only destinations bypass the gate. Without this the assertion
    /// above would also hold for an implementation that confirmed *every*
    /// link, which would be a different bug — a confirmation prompt on every
    /// `horcrux://tx` tap — that the joinSession test alone cannot see.
    @MainActor
    func test_handle_readOnlyLinks_activateWithoutConfirmation() {
        router.handle(.transactionDetail(txHash: "0xabc"))
        XCTAssertEqual(router.pendingLink, .transactionDetail(txHash: "0xabc"))
        XCTAssertNil(router.pendingConfirmation)

        router.pendingLink = nil
        router.handle(.receive(address: "0xdead", chain: "ETH"))
        XCTAssertEqual(router.pendingLink, .receive(address: "0xdead", chain: "ETH"))
        XCTAssertNil(router.pendingConfirmation)
    }

    @MainActor
    func test_confirmPending_activatesTheLinkAndClearsTheConfirmation() {
        let link = DeepLink.joinSession(sessionId: "s1")
        router.handle(link)
        router.confirmPending()
        XCTAssertEqual(router.pendingLink, link)
        XCTAssertNil(router.pendingConfirmation)
    }

    /// Declining must discard the link outright. If `cancelPending` cleared
    /// only the prompt and left `pendingLink` set, saying "no" would still
    /// join the ceremony — the exact outcome the gate exists to prevent.
    @MainActor
    func test_cancelPending_discardsWithoutActivating() {
        router.handle(.joinSession(sessionId: "s1"))
        router.cancelPending()
        XCTAssertNil(router.pendingConfirmation)
        XCTAssertNil(router.pendingLink)
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
