import XCTest
@testable import Horcrux

/// Audit C1 — unit tests for the DKG peer-binding decision extracted
/// from `CreateShardViewModel`. Mirrors the Refresh/Signing test
/// surfaces so every branch of the ceremony-roster gate is exercised
/// without standing up an actual DKG.
final class DkgPeerBindingTests: XCTestCase {

    func testAcceptsRosterPeerWithMatchingClaim() {
        let d = CreateShardViewModel.decideDkgBinding(
            channelKey: "peer-A",
            claimedFromParty: 2,
            roster: ["peer-A": 2, "peer-B": 3]
        )
        XCTAssertEqual(d, .acceptAuthenticated(partyIndex: 2))
    }

    func testRejectsPeerOutsideRoster() {
        // peer wasn't part of autoAssignPartyIndex's deterministic
        // ordering — no basis to accept any MPC packet from them.
        let d = CreateShardViewModel.decideDkgBinding(
            channelKey: "peer-X",
            claimedFromParty: 2,
            roster: ["peer-A": 2, "peer-B": 3]
        )
        XCTAssertEqual(d, .rejectUnknownPeer)
    }

    func testRejectsIndexMismatch() {
        // peer-A is pinned to party 2 by roster; MPC msg claims
        // from=3. Rogue-party attack, reject.
        let d = CreateShardViewModel.decideDkgBinding(
            channelKey: "peer-A",
            claimedFromParty: 3,
            roster: ["peer-A": 2, "peer-B": 3]
        )
        XCTAssertEqual(d, .rejectIndexMismatch(pinned: 2, claimed: 3))
    }

    func testEmptyRosterRejectsEveryone() {
        // Before autoAssignPartyIndex runs (or if it was cleared on
        // reset), no message is acceptable from any peer.
        let d = CreateShardViewModel.decideDkgBinding(
            channelKey: "peer-A",
            claimedFromParty: 2,
            roster: [:]
        )
        XCTAssertEqual(d, .rejectUnknownPeer)
    }

    func testRosterPeerCannotStealSiblingIndex() {
        // peer-A is pinned to party 2, but claims to be party 3
        // (which belongs to peer-B). Must be rejected, not accepted
        // (the C1 attack).
        let d = CreateShardViewModel.decideDkgBinding(
            channelKey: "peer-A",
            claimedFromParty: 3,
            roster: ["peer-A": 2, "peer-B": 3, "peer-C": 4]
        )
        XCTAssertEqual(d, .rejectIndexMismatch(pinned: 2, claimed: 3))
    }

    func testDecisionIsPureAndDoesNotMutateRoster() {
        var roster: [String: UInt16] = ["peer-A": 2, "peer-B": 3]
        _ = CreateShardViewModel.decideDkgBinding(
            channelKey: "peer-A",
            claimedFromParty: 2,
            roster: roster
        )
        _ = CreateShardViewModel.decideDkgBinding(
            channelKey: "peer-A",
            claimedFromParty: 3,
            roster: roster
        )
        XCTAssertEqual(roster, ["peer-A": 2, "peer-B": 3])
    }
}
