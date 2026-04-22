import XCTest
@testable import Horcrux

/// Tests for `NodeErrorMapper` — substring classification of raw RPC
/// error strings into user-facing messages and suggested actions.
///
/// These tests pin the *action* and *diagnostic* contract. The exact
/// user-visible copy is localized (`L10n.NodeErr.*`) so we only assert
/// it is non-empty; action routing is what the retry / "bump fee" UI
/// keys off, and is the behaviourally important part.
final class NodeErrorMapperTests: XCTestCase {

    private func assertAction(_ raw: String, _ expected: NodeErrorMapper.SuggestedAction,
                              file: StaticString = #filePath, line: UInt = #line) {
        let mapped = NodeErrorMapper.map(raw)
        XCTAssertEqual(mapped.action, expected, "raw=\"\(raw)\"", file: file, line: line)
        XCTAssertFalse(mapped.message.isEmpty, "message empty for \"\(raw)\"", file: file, line: line)
    }

    // MARK: - Ethereum classes

    func testEthereum_nonceErrors() {
        assertAction("nonce too low", .refreshNonce)
        assertAction("invalid nonce", .refreshNonce)
        assertAction("nonce has already been used", .refreshNonce)
    }

    func testEthereum_replacementUnderpriced() {
        assertAction("replacement transaction underpriced", .raiseFee)
        assertAction("replacement underpriced", .raiseFee)
    }

    func testEthereum_transactionUnderpriced() {
        assertAction("transaction underpriced", .raiseFee)
        assertAction("fee too low", .raiseFee)
        assertAction("gas price too low", .raiseFee)
    }

    func testEthereum_insufficientFunds() {
        assertAction("insufficient funds for gas * price + value", .fundAccount)
        assertAction("insufficient balance", .fundAccount)
    }

    func testEthereum_alreadyKnown() {
        assertAction("already known", .waitForConfirm)
        assertAction("known transaction: 0xabc", .waitForConfirm)
    }

    func testEthereum_gasTooLow() {
        assertAction("intrinsic gas too low", .raiseFee)
    }

    // MARK: - Bitcoin classes

    func testBitcoin_minRelayFee() {
        assertAction("min relay fee not met", .raiseFee)
        assertAction("mempool min fee not met", .raiseFee)
    }

    func testBitcoin_inputMissingOrSpent() {
        assertAction("txn-mempool-conflict", .refreshNonce)
        assertAction("bad-txns-inputs-missingorspent", .refreshNonce)
    }

    func testBitcoin_absurdlyHighFee() {
        assertAction("absurdly-high-fee", .raiseFee)
        assertAction("bad-txns-in-belowout", .raiseFee)
    }

    // MARK: - Solana classes

    func testSolana_blockhashExpired() {
        assertAction("Blockhash not found", .refreshNonce)
        assertAction("block height exceeded", .refreshNonce)
    }

    func testSolana_insufficientForRent() {
        assertAction("insufficient funds for rent", .fundAccount)
    }

    // MARK: - Transport classes

    func testTransport_timeout() {
        assertAction("The request timed out.", .retry)
        assertAction("connection timeout", .retry)
    }

    func testTransport_cannotConnect() {
        assertAction("cannot find host", .checkNetwork)
        assertAction("could not connect to the server", .checkNetwork)
        assertAction("the device is offline", .checkNetwork)
        assertAction("The network connection was lost.", .checkNetwork)
    }

    func testTransport_rateLimited() {
        assertAction("HTTP 429", .retry)
        assertAction("Too Many Requests", .retry)
        assertAction("rate limit exceeded", .retry)
    }

    func testTransport_unauthorized() {
        assertAction("HTTP 401", .checkNetwork)
        assertAction("HTTP 403", .checkNetwork)
        assertAction("unauthorized", .checkNetwork)
    }

    // MARK: - Fallback + diagnostic behaviour

    func testUnknownRawFallsBackToRetryWithMessage() {
        let mapped = NodeErrorMapper.map("completely unknown error xyz")
        XCTAssertEqual(mapped.action, .retry)
        XCTAssertFalse(mapped.message.isEmpty)
    }

    func testLongUnknownRawSetsDiagnosticTail() {
        let long = String(repeating: "x", count: 200)
        let mapped = NodeErrorMapper.map(long)
        XCTAssertNotNil(mapped.diagnostic)
        XCTAssertEqual(mapped.diagnostic?.count, 80)
    }

    func testShortUnknownRawHasNoDiagnostic() {
        let mapped = NodeErrorMapper.map("boom")
        XCTAssertEqual(mapped.action, .retry)
        XCTAssertNil(mapped.diagnostic)
    }

    func testClassifiedErrorsAlwaysExposeDiagnosticTail() {
        // Every classified branch should preserve a trimmed tail so the
        // user can report the underlying failure if the high-level copy
        // isn't enough to debug.
        let mapped = NodeErrorMapper.map("nonce too low: current 5, got 3")
        XCTAssertNotNil(mapped.diagnostic)
        XCTAssertFalse(mapped.diagnostic!.isEmpty)
    }

    func testMap_isCaseInsensitive() {
        // Mixed-case input must match the same lowercase substring rules.
        assertAction("Insufficient Funds", .fundAccount)
        assertAction("NONCE TOO LOW", .refreshNonce)
    }

    func testMap_fromErrorUsesLocalizedDescription() {
        struct Boom: LocalizedError { var errorDescription: String? { "rate limit hit" } }
        let mapped = NodeErrorMapper.map(Boom())
        XCTAssertEqual(mapped.action, .retry)
    }
}
