import XCTest
@testable import Horcrux

/// Tests for PendingNonceTracker — the guard against reusing an EVM nonce
/// while a broadcast transaction is still propagating.
@MainActor
final class PendingNonceTrackerTests: XCTestCase {

    private let chainId: UInt64 = 1
    private let address = "0x742D35CC6634C0532925a3B844Bc9E7595F2bD18"

    /// A tracker whose clock the test controls, so the ten-minute expiry
    /// is reachable without waiting ten minutes.
    private func tracker(_ clock: @escaping () -> Date = Date.init) -> PendingNonceTracker {
        PendingNonceTracker(now: clock)
    }

    // MARK: - Nothing recorded

    func testAnUntrackedAccountTrustsTheRpc() {
        let t = tracker()
        XCTAssertEqual(t.nextNonce(chainId: chainId, address: address, rpcNonce: 7), 7)
    }

    // MARK: - The defect it exists for

    /// The RPC's view of an account lags behind our own broadcasts by
    /// tens of seconds. Handing out the same nonce twice inside that
    /// window produces "already known" or "replacement underpriced" — the
    /// second send fails after a full signing ceremony.
    func testASecondSendDoesNotReuseTheNonceTheRpcHasNotSeenYet() {
        let t = tracker()
        let first = t.nextNonce(chainId: chainId, address: address, rpcNonce: 5)
        t.record(chainId: chainId, address: address, nonce: first)

        // The RPC still reports the pre-broadcast count.
        let second = t.nextNonce(chainId: chainId, address: address, rpcNonce: 5)
        XCTAssertEqual(first, 5)
        XCTAssertEqual(second, 6)
    }

    func testARunOfSendsHandsOutConsecutiveNonces() {
        let t = tracker()
        var issued: [UInt64] = []
        for _ in 0..<4 {
            let n = t.nextNonce(chainId: chainId, address: address, rpcNonce: 5)
            t.record(chainId: chainId, address: address, nonce: n)
            issued.append(n)
        }
        XCTAssertEqual(issued, [5, 6, 7, 8])
    }

    /// Once the chain catches up, the RPC is the better source: it also
    /// accounts for transactions sent from another device.
    func testTheRpcWinsOnceItHasCaughtUp() {
        let t = tracker()
        t.record(chainId: chainId, address: address, nonce: 5)
        XCTAssertEqual(t.nextNonce(chainId: chainId, address: address, rpcNonce: 9), 9)
    }

    // MARK: - Recording

    func testRecordingAStaleNonceDoesNotRegressTheTrackedValue() {
        let t = tracker()
        t.record(chainId: chainId, address: address, nonce: 9)
        t.record(chainId: chainId, address: address, nonce: 3)
        XCTAssertEqual(t.nextNonce(chainId: chainId, address: address, rpcNonce: 0), 10)
    }

    func testRecordingTheSameNonceTwiceDoesNotAdvanceIt() {
        let t = tracker()
        t.record(chainId: chainId, address: address, nonce: 4)
        t.record(chainId: chainId, address: address, nonce: 4)
        XCTAssertEqual(t.nextNonce(chainId: chainId, address: address, rpcNonce: 0), 5)
    }

    // MARK: - Key identity

    /// EVM addresses are compared case-insensitively; the same account
    /// written checksummed and lowercased must share one entry, or a send
    /// from a screen that lowercases would reuse a live nonce.
    func testTheSameAccountInDifferentCasesSharesOneEntry() {
        let t = tracker()
        t.record(chainId: chainId, address: address, nonce: 5)
        XCTAssertEqual(
            t.nextNonce(chainId: chainId, address: address.lowercased(), rpcNonce: 0), 6)
        XCTAssertEqual(
            t.nextNonce(chainId: chainId, address: address.uppercased(), rpcNonce: 0), 6)
    }

    func testDifferentAccountsAreTrackedSeparately() {
        let t = tracker()
        t.record(chainId: chainId, address: address, nonce: 5)
        XCTAssertEqual(
            t.nextNonce(
                chainId: chainId,
                address: "0xde709f2102306220921060314715629080e2fb77",
                rpcNonce: 0),
            0)
    }

    /// The same key controls the same address on every EVM chain, but the
    /// nonce sequences are independent. Sharing them would skip nonces on
    /// one chain and reuse them on another.
    func testTheSameAccountOnDifferentChainsIsTrackedSeparately() {
        let t = tracker()
        t.record(chainId: 1, address: address, nonce: 5)
        XCTAssertEqual(t.nextNonce(chainId: 137, address: address, rpcNonce: 0), 0)
        XCTAssertEqual(t.nextNonce(chainId: 1, address: address, rpcNonce: 0), 6)
    }

    // MARK: - Expiry

    /// A dropped transaction would otherwise hold the local nonce above
    /// the chain's forever, and every later send would be rejected as
    /// "nonce too high". Ten minutes is the ceiling on that drift.
    func testATrackedNonceIsForgottenAfterTenMinutes() {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let t = tracker { now }
        t.record(chainId: chainId, address: address, nonce: 5)

        now = now.addingTimeInterval(599)
        XCTAssertEqual(t.nextNonce(chainId: chainId, address: address, rpcNonce: 0), 6)

        now = now.addingTimeInterval(2)
        XCTAssertEqual(t.nextNonce(chainId: chainId, address: address, rpcNonce: 0), 0)
    }

    /// Each broadcast restarts the clock; a steady stream of sends must
    /// not expire mid-stream.
    func testRecordingRefreshesTheExpiry() {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let t = tracker { now }
        t.record(chainId: chainId, address: address, nonce: 5)

        now = now.addingTimeInterval(500)
        t.record(chainId: chainId, address: address, nonce: 6)

        now = now.addingTimeInterval(500)
        XCTAssertEqual(t.nextNonce(chainId: chainId, address: address, rpcNonce: 0), 7)
    }

    /// A rebroadcast records the same nonce again. That is still evidence
    /// the transaction is live, so it must restart the clock too.
    func testRecordingTheSameNonceAgainRefreshesTheExpiry() {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let t = tracker { now }
        t.record(chainId: chainId, address: address, nonce: 5)

        now = now.addingTimeInterval(500)
        t.record(chainId: chainId, address: address, nonce: 5)

        now = now.addingTimeInterval(500)
        XCTAssertEqual(t.nextNonce(chainId: chainId, address: address, rpcNonce: 0), 6)
    }

    /// An expired entry must be dropped, not merely ignored. `record`
    /// refuses to lower a tracked nonce, so an entry left lying around
    /// would come back to life the next time one was recorded — and the
    /// drift the expiry exists to bound would be permanent after all.
    func testAnExpiredEntryIsNotResurrectedByALaterRecord() {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let t = tracker { now }
        t.record(chainId: chainId, address: address, nonce: 9)

        now = now.addingTimeInterval(601)
        XCTAssertEqual(t.nextNonce(chainId: chainId, address: address, rpcNonce: 0), 0)

        t.record(chainId: chainId, address: address, nonce: 0)
        XCTAssertEqual(t.nextNonce(chainId: chainId, address: address, rpcNonce: 0), 1)
    }

    // MARK: - Clearing

    func testClearingForgetsTheTrackedNonce() {
        let t = tracker()
        t.record(chainId: chainId, address: address, nonce: 5)
        t.clear(chainId: chainId, address: address)
        XCTAssertEqual(t.nextNonce(chainId: chainId, address: address, rpcNonce: 0), 0)
    }

    func testClearingOneAccountLeavesTheOthers() {
        let t = tracker()
        t.record(chainId: 1, address: address, nonce: 5)
        t.record(chainId: 137, address: address, nonce: 8)
        t.clear(chainId: 1, address: address)
        XCTAssertEqual(t.nextNonce(chainId: 1, address: address, rpcNonce: 0), 0)
        XCTAssertEqual(t.nextNonce(chainId: 137, address: address, rpcNonce: 0), 9)
    }

    func testClearingIsCaseInsensitive() {
        let t = tracker()
        t.record(chainId: chainId, address: address, nonce: 5)
        t.clear(chainId: chainId, address: address.lowercased())
        XCTAssertEqual(t.nextNonce(chainId: chainId, address: address, rpcNonce: 0), 0)
    }

    // MARK: - The shared instance

    func testTheSharedInstanceIsUsable() {
        let shared = PendingNonceTracker.shared
        let scratch = "0x0000000000000000000000000000000000000001"
        shared.clear(chainId: 999, address: scratch)
        shared.record(chainId: 999, address: scratch, nonce: 3)
        XCTAssertEqual(shared.nextNonce(chainId: 999, address: scratch, rpcNonce: 0), 4)
        shared.clear(chainId: 999, address: scratch)
        XCTAssertEqual(shared.nextNonce(chainId: 999, address: scratch, rpcNonce: 0), 0)
    }
}
