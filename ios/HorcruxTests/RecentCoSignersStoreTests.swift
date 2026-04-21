import XCTest
@testable import Horcrux

/// Tests for `RecentCoSignersStore` (dev.93).
///
/// Store is a `@MainActor` singleton backed by `UserDefaults.standard`
/// key `signing.recentCoSigners.v1`. We use the real singleton and wipe
/// state in `setUp` / `tearDown` so each test runs in isolation without
/// leaking into the app bundle under test.
@MainActor
final class RecentCoSignersStoreTests: XCTestCase {

    private let storageKey = "signing.recentCoSigners.v1"

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: storageKey)
        // Force the singleton to reload the (now empty) storage.
        RecentCoSignersStore.shared.forget(peerId: "x", walletId: "x")
        for e in RecentCoSignersStore.shared.entries {
            RecentCoSignersStore.shared.forget(peerId: e.id, walletId: e.walletId)
        }
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: storageKey)
        for e in RecentCoSignersStore.shared.entries {
            RecentCoSignersStore.shared.forget(peerId: e.id, walletId: e.walletId)
        }
        try await super.tearDown()
    }

    func testRecordAndMostRecent() {
        let store = RecentCoSignersStore.shared
        store.record(peerId: "peer-1", name: "Alice's iPhone", walletId: "w1")
        XCTAssertEqual(store.mostRecent(for: "w1")?.id, "peer-1")
        XCTAssertEqual(store.mostRecent(for: "w1")?.name, "Alice's iPhone")
        XCTAssertNil(store.mostRecent(for: "other-wallet"),
                     "Different wallet must not see peers from w1")
    }

    func testRecordUpdatesTimestampForExistingPeer() {
        let store = RecentCoSignersStore.shared
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let t1 = Date(timeIntervalSince1970: 1_000_500)
        store.record(peerId: "p", name: "Phone", walletId: "w1", at: t0)
        store.record(peerId: "p", name: "Phone", walletId: "w1", at: t1)
        XCTAssertEqual(store.recent(for: "w1").count, 1, "Same peer must not duplicate")
        XCTAssertEqual(store.mostRecent(for: "w1")?.lastSeenAt, t1)
    }

    func testMostRecentOrdersByTimestamp() {
        let store = RecentCoSignersStore.shared
        let old = Date(timeIntervalSince1970: 1_000_000)
        let new = Date(timeIntervalSince1970: 2_000_000)
        store.record(peerId: "old-peer", name: "Old", walletId: "w1", at: old)
        store.record(peerId: "new-peer", name: "New", walletId: "w1", at: new)
        XCTAssertEqual(store.mostRecent(for: "w1")?.id, "new-peer")
        XCTAssertEqual(store.recent(for: "w1").map(\.id), ["new-peer", "old-peer"])
    }

    func testEvictionCapsAtFivePerWallet() {
        let store = RecentCoSignersStore.shared
        // Insert 7 distinct peers on the same wallet with increasing
        // timestamps. Only the 5 most recent should survive.
        for i in 0..<7 {
            store.record(
                peerId: "p-\(i)",
                name: "Phone \(i)",
                walletId: "w1",
                at: Date(timeIntervalSince1970: TimeInterval(1_000 + i))
            )
        }
        let ids = store.recent(for: "w1").map(\.id)
        XCTAssertEqual(ids.count, 5, "Cap must be 5 per wallet")
        XCTAssertEqual(ids, ["p-6", "p-5", "p-4", "p-3", "p-2"])
    }

    func testEvictionIsScopedPerWallet() {
        let store = RecentCoSignersStore.shared
        // 5 peers on w1 (at cap) + 5 on w2 should coexist.
        for i in 0..<5 {
            store.record(peerId: "w1-p\(i)", name: "A\(i)", walletId: "w1",
                         at: Date(timeIntervalSince1970: TimeInterval(1_000 + i)))
            store.record(peerId: "w2-p\(i)", name: "B\(i)", walletId: "w2",
                         at: Date(timeIntervalSince1970: TimeInterval(2_000 + i)))
        }
        XCTAssertEqual(store.recent(for: "w1").count, 5)
        XCTAssertEqual(store.recent(for: "w2").count, 5)
    }

    func testForgetRemovesPeer() {
        let store = RecentCoSignersStore.shared
        store.record(peerId: "keep", name: "Keep", walletId: "w1")
        store.record(peerId: "drop", name: "Drop", walletId: "w1")
        store.forget(peerId: "drop", walletId: "w1")
        let ids = store.recent(for: "w1").map(\.id)
        XCTAssertEqual(ids, ["keep"])
    }

    func testForgetIsWalletScoped() {
        let store = RecentCoSignersStore.shared
        store.record(peerId: "shared", name: "Phone", walletId: "w1")
        store.record(peerId: "shared", name: "Phone", walletId: "w2")
        store.forget(peerId: "shared", walletId: "w1")
        XCTAssertNil(store.mostRecent(for: "w1"))
        XCTAssertEqual(store.mostRecent(for: "w2")?.id, "shared",
                       "Forget on w1 must not touch w2 even with same peerId")
    }

    func testEmptyPeerIdIsIgnored() {
        let store = RecentCoSignersStore.shared
        store.record(peerId: "", name: "Nameless", walletId: "w1")
        XCTAssertNil(store.mostRecent(for: "w1"),
                     "Empty peerId must not create a ghost entry")
    }

    func testPersistenceRoundTripsAcrossSaveLoad() {
        let store = RecentCoSignersStore.shared
        store.record(peerId: "p1", name: "Phone 1", walletId: "w1",
                     at: Date(timeIntervalSince1970: 1_234_567))
        // Verify raw UserDefaults state matches what we encoded. The
        // store writes on every mutation; no explicit flush needed.
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return XCTFail("Expected persisted data under \(storageKey)")
        }
        let decoded = try? JSONDecoder().decode([RecentCoSigner].self, from: data)
        XCTAssertEqual(decoded?.count, 1)
        XCTAssertEqual(decoded?.first?.id, "p1")
    }
}
