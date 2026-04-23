import XCTest
@testable import Horcrux

/// Audit C1 (round 12) — unit tests for the signing peer-binding
/// decision extracted from `SigningViewModel`'s mpcMessageStream
/// loop. These tests exercise every branch of the C1 second-gate
/// enforcement without needing to spin up a signing ceremony.
final class SigningPeerBindingTests: XCTestCase {

    func testAcceptsMatchingPresenceClaim() {
        let d = SigningViewModel.decideSigningBinding(
            peerId: "peer-A",
            claimedFromParty: 2,
            presenceMap: ["peer-A": 2]
        )
        XCTAssertEqual(d, .acceptAuthenticated(partyIndex: 2))
    }

    func testRejectsMissingPresenceClaim() {
        // peer.id has not yet registered a SignPresenceDTO — we
        // have no basis to authenticate any MPC message from them.
        let d = SigningViewModel.decideSigningBinding(
            peerId: "peer-B",
            claimedFromParty: 2,
            presenceMap: ["peer-A": 2]
        )
        XCTAssertEqual(d, .rejectNoPresenceClaim)
    }

    func testRejectsIndexMismatch() {
        // peer-A registered as party 2 via presence; MPC msg now
        // claims from=3. Rogue-party attack — reject.
        let d = SigningViewModel.decideSigningBinding(
            peerId: "peer-A",
            claimedFromParty: 3,
            presenceMap: ["peer-A": 2]
        )
        XCTAssertEqual(d, .rejectIndexMismatch(pinned: 2, claimed: 3))
    }

    func testEmptyPresenceMapRejectsAll() {
        // Before any SignPresenceDTO is received (e.g. the listener
        // task hasn't fired yet), every MPC message must be dropped.
        let d = SigningViewModel.decideSigningBinding(
            peerId: "peer-A",
            claimedFromParty: 2,
            presenceMap: [:]
        )
        XCTAssertEqual(d, .rejectNoPresenceClaim)
    }

    func testKnownPeerCannotStealOtherPartyIndex() {
        // peer-A (authenticated as party 2) claims to be party 3,
        // which belongs to a legitimate sibling peer in the same
        // roster. The decision must still be reject, not accept.
        let d = SigningViewModel.decideSigningBinding(
            peerId: "peer-A",
            claimedFromParty: 3,
            presenceMap: ["peer-A": 2, "peer-B": 3]
        )
        XCTAssertEqual(d, .rejectIndexMismatch(pinned: 2, claimed: 3))
    }
}
