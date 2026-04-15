import XCTest
@testable import Horcrux

/// Tests for TransactionStore — CRUD, persistence, filtering.
final class TransactionStoreTests: XCTestCase {
    private var store: TransactionStore!
    private var tempURL: URL!

    @MainActor
    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("horcrux_test_txs_\(UUID().uuidString).json")
        store = TransactionStore(fileURL: tempURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        super.tearDown()
    }

    private func makeTx(id: String = UUID().uuidString,
                         walletId: String = "wallet-1",
                         chain: Chain = .ethereum,
                         status: TransactionRecord.TxStatus = .signed) -> TransactionRecord {
        TransactionRecord(
            id: id,
            walletId: walletId,
            chain: chain,
            fromAddress: "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            toAddress: "0xBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
            amount: "1.5",
            fee: "0.001 ETH",
            txHash: "0xdeadbeef",
            status: status,
            createdAt: Date(),
            broadcastAt: nil
        )
    }

    @MainActor
    func testAddAndRetrieve() {
        let tx = makeTx()
        store.add(tx)
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records.first?.id, tx.id)
    }

    @MainActor
    func testNewestFirst() {
        let tx1 = makeTx(id: "tx-1")
        let tx2 = makeTx(id: "tx-2")
        store.add(tx1)
        store.add(tx2)
        // tx2 was added second but should be first (newest)
        XCTAssertEqual(store.records.first?.id, "tx-2")
    }

    @MainActor
    func testFilterByWallet() {
        store.add(makeTx(walletId: "w1"))
        store.add(makeTx(walletId: "w2"))
        store.add(makeTx(walletId: "w1"))
        XCTAssertEqual(store.records(for: "w1").count, 2)
        XCTAssertEqual(store.records(for: "w2").count, 1)
        XCTAssertEqual(store.records(for: "w3").count, 0)
    }

    @MainActor
    func testUpdateStatus() {
        let tx = makeTx(id: "tx-update", status: .signed)
        store.add(tx)
        store.updateStatus(id: "tx-update", status: .broadcast, txHash: "0xnewhash")
        XCTAssertEqual(store.records.first?.status, .broadcast)
        XCTAssertEqual(store.records.first?.txHash, "0xnewhash")
        XCTAssertNotNil(store.records.first?.broadcastAt)
    }

    @MainActor
    func testUpdateStatusFailed() {
        let tx = makeTx(id: "tx-fail", status: .signed)
        store.add(tx)
        store.updateStatus(id: "tx-fail", status: .failed)
        XCTAssertEqual(store.records.first?.status, .failed)
    }

    @MainActor
    func testUpdateNonexistentId() {
        store.add(makeTx(id: "tx-1"))
        store.updateStatus(id: "nonexistent", status: .broadcast)
        // Should not crash; original record unchanged
        XCTAssertEqual(store.records.first?.status, .signed)
    }

    @MainActor
    func testRemoveAllForWallet() {
        store.add(makeTx(walletId: "w1"))
        store.add(makeTx(walletId: "w1"))
        store.add(makeTx(walletId: "w2"))
        store.removeAll(for: "w1")
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records.first?.walletId, "w2")
    }

    @MainActor
    func testWipeAll() {
        store.add(makeTx())
        store.add(makeTx())
        store.wipeAll()
        XCTAssertTrue(store.records.isEmpty)
    }

    @MainActor
    func testPersistence() {
        store.add(makeTx(id: "persisted"))
        // Create a new store from the same file
        let store2 = TransactionStore(fileURL: tempURL)
        XCTAssertEqual(store2.records.count, 1)
        XCTAssertEqual(store2.records.first?.id, "persisted")
    }

    @MainActor
    func testExplorerURLs() {
        let ethTx = makeTx(chain: .ethereum)
        XCTAssertTrue(ethTx.explorerURL?.absoluteString.contains("etherscan.io") ?? false)

        let btcTx = TransactionRecord(
            id: "btc", walletId: "w", chain: .bitcoin,
            fromAddress: "bc1q...", toAddress: "bc1q...", amount: "0.1",
            fee: nil, txHash: "abc123", status: .broadcast, createdAt: Date()
        )
        XCTAssertTrue(btcTx.explorerURL?.absoluteString.contains("blockstream.info") ?? false)

        let solTx = TransactionRecord(
            id: "sol", walletId: "w", chain: .solana,
            fromAddress: "1111...", toAddress: "2222...", amount: "1.0",
            fee: nil, txHash: "sig123", status: .broadcast, createdAt: Date()
        )
        XCTAssertTrue(solTx.explorerURL?.absoluteString.contains("solscan.io") ?? false)
    }

    @MainActor
    func testExplorerURLNilWhenNoHash() {
        let tx = TransactionRecord(
            id: "nohash", walletId: "w", chain: .ethereum,
            fromAddress: "0x...", toAddress: "0x...", amount: "1",
            fee: nil, txHash: nil, status: .signed, createdAt: Date()
        )
        XCTAssertNil(tx.explorerURL)
    }
}
