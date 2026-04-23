import XCTest
@testable import Horcrux

/// Audit C1 round-16 — unit tests for the Refresh peer-binding
/// decision function. Extracted from the async loop in
/// `RefreshShardCoordinator.runRounds` so every branch can be
/// exercised deterministically without spinning up a ceremony.
final class RefreshPeerBindingTests: XCTestCase {

    // MARK: - Legacy wallet (no persisted registry)

    func testLegacyWalletBindsUnknownPeerViaTOFU() {
        let d = RefreshShardCoordinator.decidePeerBinding(
            peerId: "peer-A",
            claimedFromParty: 2,
            currentMap: [:],
            hasPersistedRegistry: false
        )
        XCTAssertEqual(d, .acceptTOFU)
    }

    func testLegacyWalletAcceptsConsistentClaim() {
        let d = RefreshShardCoordinator.decidePeerBinding(
            peerId: "peer-A",
            claimedFromParty: 2,
            currentMap: ["peer-A": 2],
            hasPersistedRegistry: false
        )
        XCTAssertEqual(d, .acceptAlreadyBound)
    }

    func testLegacyWalletRejectsIndexFlip() {
        // TOFU was established earlier in the session — a flip from
        // party 2 → 3 is a same-session impersonation attempt.
        let d = RefreshShardCoordinator.decidePeerBinding(
            peerId: "peer-A",
            claimedFromParty: 3,
            currentMap: ["peer-A": 2],
            hasPersistedRegistry: false
        )
        XCTAssertEqual(d, .rejectIndexMismatch(pinned: 2, claimed: 3))
    }

    // MARK: - Round-16 wallet (persisted registry, strict mode)

    func testStrictModeAcceptsKnownPeerWithCorrectIndex() {
        let registry: [String: UInt16] = ["peer-A": 2, "peer-B": 3]
        let d = RefreshShardCoordinator.decidePeerBinding(
            peerId: "peer-A",
            claimedFromParty: 2,
            currentMap: registry,
            hasPersistedRegistry: true
        )
        XCTAssertEqual(d, .acceptAlreadyBound)
    }

    func testStrictModeRejectsKnownPeerWithWrongIndex() {
        // peer-A was pinned to 2 at DKG time — any other claim is
        // an impersonation attempt, including claiming an index
        // that belongs to a legitimate sibling peer.
        let registry: [String: UInt16] = ["peer-A": 2, "peer-B": 3]
        let d = RefreshShardCoordinator.decidePeerBinding(
            peerId: "peer-A",
            claimedFromParty: 3,
            currentMap: registry,
            hasPersistedRegistry: true
        )
        XCTAssertEqual(d, .rejectIndexMismatch(pinned: 2, claimed: 3))
    }

    func testStrictModeRejectsUnknownPeer() {
        // Intruder who wasn't in the DKG roster is refused binding.
        let registry: [String: UInt16] = ["peer-A": 2, "peer-B": 3]
        let d = RefreshShardCoordinator.decidePeerBinding(
            peerId: "peer-C-intruder",
            claimedFromParty: 2,
            currentMap: registry,
            hasPersistedRegistry: true
        )
        XCTAssertEqual(d, .rejectUnknownPeer)
    }

    func testStrictModeTreatsEmptyRegistryAsTOFU() {
        // If a round-16 wallet somehow ships with an empty registry
        // and hasPersistedRegistry=false (as the call-site does when
        // `wallet.peerRegistry == nil`), we behave like a legacy
        // wallet. Guards the "registry not yet captured" boundary.
        let d = RefreshShardCoordinator.decidePeerBinding(
            peerId: "peer-A",
            claimedFromParty: 2,
            currentMap: [:],
            hasPersistedRegistry: false
        )
        XCTAssertEqual(d, .acceptTOFU)
    }
}
