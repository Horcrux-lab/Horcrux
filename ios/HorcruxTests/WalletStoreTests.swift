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
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            isHidden: nil
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

    // MARK: - testSetPeerRegistryIfAbsentUpgradesLegacyWallet (Audit C1 round-16)

    @MainActor
    func testSetPeerRegistryIfAbsentUpgradesLegacyWallet() {
        let store = WalletStore()
        let gpk = Data([0xAA, 0xBB, 0xCC, 0xDD])
        let legacy = Wallet(
            id: "legacy-registry-upgrade",
            name: "Legacy",
            chain: .ethereum,
            address: "0x1111111111111111111111111111111111111111",
            groupPublicKey: gpk,
            threshold: 2,
            totalParties: 3,
            partyIndex: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            isHidden: nil
        )
        XCTAssertNil(legacy.peerRegistry, "makeWallet default must not populate registry")
        store.add(legacy)

        let observed: [String: UInt16] = ["peer-A": 2, "peer-B": 3]
        store.setPeerRegistryIfAbsent(accountId: legacy.accountId, registry: observed)

        let upgraded = store.wallet(for: "legacy-registry-upgrade")
        XCTAssertEqual(upgraded?.peerRegistry, observed, "legacy wallet should be upgraded with observed map")

        // Second call MUST NOT overwrite an already-populated registry.
        let tamper: [String: UInt16] = ["peer-A": 99]
        store.setPeerRegistryIfAbsent(accountId: legacy.accountId, registry: tamper)
        let reread = store.wallet(for: "legacy-registry-upgrade")
        XCTAssertEqual(reread?.peerRegistry, observed, "existing registry must not be overwritten")

        // Empty registry is a no-op on a legacy wallet — we never
        // persist an empty roster because it would silently accept
        // any peer.id on the next refresh.
        let legacy2 = Wallet(
            id: "legacy-registry-empty",
            name: "Legacy2",
            chain: .ethereum,
            address: "0x2222222222222222222222222222222222222222",
            groupPublicKey: Data([0xEE, 0xFF]),
            threshold: 2,
            totalParties: 3,
            partyIndex: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            isHidden: nil
        )
        store.add(legacy2)
        store.setPeerRegistryIfAbsent(accountId: legacy2.accountId, registry: [:])
        XCTAssertNil(store.wallet(for: "legacy-registry-empty")?.peerRegistry,
                     "empty registry must not be persisted")

        store.remove(id: "legacy-registry-upgrade")
        store.remove(id: "legacy-registry-empty")
    }

    // MARK: - testSetPeerRegistryIfAbsentAppliesToSiblings (Audit C1 round-16)

    @MainActor
    func testSetPeerRegistryIfAbsentAppliesToSiblings() {
        // Two wallets sharing a groupPublicKey (same accountId) must
        // both receive the registry, since the DKG roster is an
        // account-level property.
        let store = WalletStore()
        let gpk = Data([0x11, 0x22, 0x33, 0x44, 0x55])
        let ethW = Wallet(
            id: "sibling-eth", name: "ETH sibling", chain: .ethereum,
            address: "0xAAA0000000000000000000000000000000000000",
            groupPublicKey: gpk, threshold: 2, totalParties: 3, partyIndex: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), isHidden: nil
        )
        let bnbW = Wallet(
            id: "sibling-bnb", name: "BNB sibling", chain: .bnb,
            address: "0xAAA0000000000000000000000000000000000000",
            groupPublicKey: gpk, threshold: 2, totalParties: 3, partyIndex: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), isHidden: nil
        )
        store.add(ethW)
        store.add(bnbW)

        let reg: [String: UInt16] = ["peer-X": 2, "peer-Y": 3]
        store.setPeerRegistryIfAbsent(accountId: ethW.accountId, registry: reg)

        XCTAssertEqual(store.wallet(for: "sibling-eth")?.peerRegistry, reg)
        XCTAssertEqual(store.wallet(for: "sibling-bnb")?.peerRegistry, reg,
                       "sibling wallet sharing same accountId must also upgrade")

        store.remove(id: "sibling-eth")
        store.remove(id: "sibling-bnb")
    }
}
