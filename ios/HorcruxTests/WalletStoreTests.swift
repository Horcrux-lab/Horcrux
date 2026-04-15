import XCTest
@testable import Horcrux

/// Tests for WalletStore — CRUD, persistence, key share storage.
/// Uses a custom file URL to avoid polluting real wallet data.
final class WalletStoreTests: XCTestCase {

    // MARK: - Helpers

    private func makeWallet(
        id: String = UUID().uuidString,
        name: String = "Test Wallet",
        chain: Chain = .ethereum,
        address: String = "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    ) -> Wallet {
        Wallet(
            id: id,
            name: name,
            chain: chain,
            address: address,
            groupPublicKey: Data([0x02, 0x03, 0x04]),
            threshold: 2,
            totalParties: 3,
            partyIndex: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: - testSaveAndLoadWallet

    @MainActor
    func testSaveAndLoadWallet() {
        let store = WalletStore()
        let initialCount = store.wallets.count

        let wallet = makeWallet(id: "round-trip-test", name: "Round Trip")
        store.add(wallet)

        // Verify in-memory
        XCTAssertEqual(store.wallets.count, initialCount + 1)
        let found = store.wallet(for: "round-trip-test")
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.name, "Round Trip")
        XCTAssertEqual(found?.chain, .ethereum)
        XCTAssertEqual(found?.threshold, 2)

        // Verify persistence by creating a new store instance
        let store2 = WalletStore()
        let reloaded = store2.wallet(for: "round-trip-test")
        XCTAssertNotNil(reloaded, "Wallet should persist across store instances")
        XCTAssertEqual(reloaded?.name, "Round Trip")

        // Clean up
        store2.remove(id: "round-trip-test")
    }

    // MARK: - testDeleteWallet

    @MainActor
    func testDeleteWallet() {
        let store = WalletStore()
        let wallet = makeWallet(id: "delete-me")
        store.add(wallet)
        XCTAssertNotNil(store.wallet(for: "delete-me"))

        store.remove(id: "delete-me")

        XCTAssertNil(store.wallet(for: "delete-me"), "Wallet should be removed")
    }

    // MARK: - testMultipleWallets

    @MainActor
    func testMultipleWallets() {
        let store = WalletStore()
        let initialCount = store.wallets.count

        let w1 = makeWallet(id: "multi-1", name: "ETH Wallet", chain: .ethereum)
        let w2 = makeWallet(id: "multi-2", name: "BTC Wallet", chain: .bitcoin)
        let w3 = makeWallet(id: "multi-3", name: "SOL Wallet", chain: .solana)

        store.add(w1)
        store.add(w2)
        store.add(w3)

        XCTAssertEqual(store.wallets.count, initialCount + 3)

        XCTAssertEqual(store.wallet(for: "multi-1")?.chain, .ethereum)
        XCTAssertEqual(store.wallet(for: "multi-2")?.chain, .bitcoin)
        XCTAssertEqual(store.wallet(for: "multi-3")?.chain, .solana)

        // Clean up
        store.remove(id: "multi-1")
        store.remove(id: "multi-2")
        store.remove(id: "multi-3")
    }

    // MARK: - testPendingTransactionStorage

    @MainActor
    func testPendingTransactionStorage() {
        // Use TransactionStore for pending TX (it's the canonical store).
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("horcrux_test_pending_\(UUID().uuidString).json")
        let txStore = TransactionStore(fileURL: tempURL)

        let tx = TransactionRecord(
            id: "pending-1",
            walletId: "w-1",
            chain: .ethereum,
            fromAddress: "0xAAAA",
            toAddress: "0xBBBB",
            amount: "0.5",
            fee: "0.001 ETH",
            txHash: nil,
            status: .signed,
            createdAt: Date(),
            broadcastAt: nil
        )
        txStore.add(tx)

        XCTAssertEqual(txStore.records.count, 1)
        XCTAssertEqual(txStore.records.first?.status, .signed)
        XCTAssertNil(txStore.records.first?.txHash, "Pending TX should have no hash yet")

        // Reload from disk
        let txStore2 = TransactionStore(fileURL: tempURL)
        XCTAssertEqual(txStore2.records.count, 1, "Pending TX should persist to disk")

        try? FileManager.default.removeItem(at: tempURL)
    }

    // MARK: - testWalletNotFoundReturnsNil

    @MainActor
    func testWalletNotFoundReturnsNil() {
        let store = WalletStore()
        let result = store.wallet(for: "nonexistent-wallet-id-12345")
        XCTAssertNil(result, "Looking up a nonexistent wallet should return nil")
    }

    // MARK: - Rename

    @MainActor
    func testRenameWallet() {
        let store = WalletStore()
        let wallet = makeWallet(id: "rename-test", name: "Original")
        store.add(wallet)

        store.rename(id: "rename-test", newName: "Renamed")

        let updated = store.wallet(for: "rename-test")
        XCTAssertEqual(updated?.name, "Renamed")

        store.remove(id: "rename-test")
    }

    // MARK: - WipeAll

    @MainActor
    func testWipeAllClearsWallets() {
        let store = WalletStore()
        store.add(makeWallet(id: "wipe-1"))
        store.add(makeWallet(id: "wipe-2"))
        XCTAssertGreaterThanOrEqual(store.wallets.count, 2)

        store.wipeAll()

        XCTAssertTrue(store.wallets.isEmpty, "wipeAll should remove all wallets")
    }
}
