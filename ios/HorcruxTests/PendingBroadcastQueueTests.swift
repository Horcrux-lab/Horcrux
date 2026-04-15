import XCTest
@testable import Horcrux

/// Tests for PendingBroadcastQueue — enqueue, dequeue, persistence, wipe.
final class PendingBroadcastQueueTests: XCTestCase {

    // MARK: - Helpers

    private func makeTx(
        id: String = UUID().uuidString,
        walletId: String = "wallet-1",
        chain: Chain = .ethereum
    ) -> PendingBroadcastQueue.PendingTransaction {
        PendingBroadcastQueue.PendingTransaction(
            id: id,
            walletId: walletId,
            chain: chain,
            signedPayload: "0xdeadbeef",
            toAddress: "0xBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
            amount: "1.0",
            createdAt: Date()
        )
    }

    // MARK: - Enqueue

    @MainActor
    func test_enqueue_addsToPending() {
        let queue = PendingBroadcastQueue()
        queue.wipeAll() // start clean

        let tx = makeTx(id: "tx-1")
        queue.enqueue(tx)

        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.pending.first?.id, "tx-1")
        XCTAssertFalse(queue.isEmpty)

        queue.wipeAll()
    }

    @MainActor
    func test_enqueue_multipleTransactions() {
        let queue = PendingBroadcastQueue()
        queue.wipeAll()

        queue.enqueue(makeTx(id: "a"))
        queue.enqueue(makeTx(id: "b"))
        queue.enqueue(makeTx(id: "c"))

        XCTAssertEqual(queue.count, 3)

        queue.wipeAll()
    }

    // MARK: - Dequeue

    @MainActor
    func test_dequeue_removesById() {
        let queue = PendingBroadcastQueue()
        queue.wipeAll()

        queue.enqueue(makeTx(id: "keep"))
        queue.enqueue(makeTx(id: "remove"))

        queue.dequeue(id: "remove")

        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.pending.first?.id, "keep")

        queue.wipeAll()
    }

    @MainActor
    func test_dequeue_nonexistentId_noEffect() {
        let queue = PendingBroadcastQueue()
        queue.wipeAll()

        queue.enqueue(makeTx(id: "only"))
        queue.dequeue(id: "nonexistent")

        XCTAssertEqual(queue.count, 1)

        queue.wipeAll()
    }

    // MARK: - markAttempt

    @MainActor
    func test_markAttempt_incrementsCount() {
        let queue = PendingBroadcastQueue()
        queue.wipeAll()

        queue.enqueue(makeTx(id: "retry-tx"))
        queue.markAttempt(id: "retry-tx", error: "timeout")

        XCTAssertEqual(queue.pending.first?.attempts, 1)
        XCTAssertEqual(queue.pending.first?.lastError, "timeout")

        queue.markAttempt(id: "retry-tx", error: nil)
        XCTAssertEqual(queue.pending.first?.attempts, 2)
        XCTAssertNil(queue.pending.first?.lastError)

        queue.wipeAll()
    }

    // MARK: - pendingFor(walletId:)

    @MainActor
    func test_pendingForWallet_filtersCorrectly() {
        let queue = PendingBroadcastQueue()
        queue.wipeAll()

        queue.enqueue(makeTx(id: "w1-a", walletId: "w1"))
        queue.enqueue(makeTx(id: "w2-a", walletId: "w2"))
        queue.enqueue(makeTx(id: "w1-b", walletId: "w1"))

        let w1Txs = queue.pendingFor(walletId: "w1")
        XCTAssertEqual(w1Txs.count, 2)

        let w2Txs = queue.pendingFor(walletId: "w2")
        XCTAssertEqual(w2Txs.count, 1)

        let w3Txs = queue.pendingFor(walletId: "w3")
        XCTAssertTrue(w3Txs.isEmpty)

        queue.wipeAll()
    }

    // MARK: - isEmpty / count

    @MainActor
    func test_isEmpty_whenEmpty() {
        let queue = PendingBroadcastQueue()
        queue.wipeAll()
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.count, 0)
    }

    // MARK: - wipeAll

    @MainActor
    func test_wipeAll_clearsAllPending() {
        let queue = PendingBroadcastQueue()
        queue.wipeAll()

        queue.enqueue(makeTx(id: "a"))
        queue.enqueue(makeTx(id: "b"))
        XCTAssertEqual(queue.count, 2)

        queue.wipeAll()
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.count, 0)
    }

    // MARK: - Persistence

    @MainActor
    func test_persistence_surviveReinitialization() {
        let queue = PendingBroadcastQueue()
        queue.wipeAll()

        queue.enqueue(makeTx(id: "persist-1", walletId: "w1", chain: .bitcoin))
        queue.enqueue(makeTx(id: "persist-2", walletId: "w2", chain: .solana))

        // Create a new instance which loads from disk
        let queue2 = PendingBroadcastQueue()
        XCTAssertEqual(queue2.count, 2)

        let ids = queue2.pending.map(\.id)
        XCTAssertTrue(ids.contains("persist-1"))
        XCTAssertTrue(ids.contains("persist-2"))

        // Verify chain was persisted correctly
        let btcTx = queue2.pending.first(where: { $0.id == "persist-1" })
        XCTAssertEqual(btcTx?.chain, .bitcoin)
        XCTAssertEqual(btcTx?.walletId, "w1")

        queue2.wipeAll()
    }

    // MARK: - PendingTransaction fields

    @MainActor
    func test_pendingTransaction_fieldsAreCorrect() {
        let queue = PendingBroadcastQueue()
        queue.wipeAll()

        let tx = PendingBroadcastQueue.PendingTransaction(
            id: "tx-fields",
            walletId: "w-test",
            chain: .solana,
            signedPayload: "base64payload==",
            toAddress: "SolAddress123",
            amount: "42.5",
            createdAt: Date(timeIntervalSince1970: 1000)
        )
        queue.enqueue(tx)

        let stored = queue.pending.first
        XCTAssertEqual(stored?.id, "tx-fields")
        XCTAssertEqual(stored?.walletId, "w-test")
        XCTAssertEqual(stored?.chain, .solana)
        XCTAssertEqual(stored?.signedPayload, "base64payload==")
        XCTAssertEqual(stored?.toAddress, "SolAddress123")
        XCTAssertEqual(stored?.amount, "42.5")
        XCTAssertEqual(stored?.attempts, 0)
        XCTAssertNil(stored?.lastError)

        queue.wipeAll()
    }
}
