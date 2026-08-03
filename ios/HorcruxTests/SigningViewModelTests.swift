import XCTest
@testable import Horcrux

/// Tests for SigningViewModel — initial state, signing lifecycle, jailbreak gate.
@MainActor
final class SigningViewModelTests: XCTestCase {

    // MARK: - Helpers

    private func makeWallet(chain: Chain = .ethereum) -> Wallet {
        Wallet(
            id: "test-wallet",
            name: "Test Wallet",
            chain: chain,
            address: "0x742D35CC6634C0532925a3B844Bc9E7595F2bD18",
            groupPublicKey: Data([0x02, 0x03, 0x04]),
            threshold: 2,
            totalParties: 3,
            partyIndex: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            isHidden: nil
        )
    }

    // MARK: - testInitialState

    func testInitialState() {
        let wallet = makeWallet()
        let vm = SigningViewModel(wallet: wallet)

        XCTAssertEqual(vm.step, .compose, "Initial step should be .compose")
        XCTAssertEqual(vm.recipientAddress, "", "recipientAddress should start empty")
        XCTAssertEqual(vm.amount, "", "amount should start empty")
        XCTAssertEqual(vm.signingProgress, 0, "Progress should start at 0")
        XCTAssertEqual(vm.signingStatusMessage, "", "Status message should start empty")
        XCTAssertEqual(vm.currentRound, 0, "currentRound should start at 0")
        XCTAssertEqual(vm.totalRounds, 4, "ETH signing should default to 4 rounds (CGGMP21)")
        XCTAssertNil(vm.txHash, "txHash should be nil initially")
        XCTAssertEqual(vm.errorMessage, "", "errorMessage should start empty")
        XCTAssertTrue(vm.joinedSigners.isEmpty, "No signers should be joined initially")
        XCTAssertEqual(vm.estimatedGas, "—", "estimatedGas should show placeholder")
        XCTAssertEqual(vm.estimatedFee, "—", "estimatedFee should show placeholder")
        XCTAssertFalse(vm.isEstimatingGas, "Should not be estimating gas initially")
        XCTAssertFalse(vm.isBroadcasting, "Should not be broadcasting initially")
        XCTAssertNil(vm.broadcastStatus, "broadcastStatus should be nil initially")
    }

    // MARK: - Replace-by-fee gating (issue #32)

    /// `rbfConflictsWithOriginal` is what authorises marking the original
    /// as superseded. Setting `rbfReplacing` alone must not be enough: the
    /// original is only really replaced once the rebuild has been made to
    /// spend its outpoints, and before #32 a broadcast that spent an
    /// entirely different UTXO still flipped the still-live original to
    /// `.failed`.
    func testSettingRbfReplacingAloneDoesNotAuthoriseMarkingTheOriginalReplaced() {
        let vm = SigningViewModel(wallet: makeWallet(chain: .bitcoin))
        vm.rbfReplacing = String(repeating: "aa", count: 32)
        XCTAssertFalse(vm.rbfConflictsWithOriginal)
    }

    // MARK: - testStartSigningSetsIsRunning
    func testStartSigningSetsIsRunning() {
        let vm = SigningViewModel(wallet: makeWallet())

        guard !SecurityEnvironment.isCompromised else { return }

        // Without bind(), bridge/deviceKey are nil — startSigning transitions to .signing
        // then the async task quickly errors. We verify the synchronous step change.
        // setPin removed — lives on AppState now, not SigningViewModel.
        vm.amount = "0.1"
        vm.startSigning()

        XCTAssertEqual(vm.step, .signing, "startSigning should transition step to .signing")
    }

    // MARK: - testJailbreakBlocksSigning

    func testJailbreakBlocksSigning() {
        let vm = SigningViewModel(wallet: makeWallet())
        // setPin removed — lives on AppState now, not SigningViewModel.
        vm.startSigning()

        if SecurityEnvironment.isCompromised {
            XCTAssertEqual(vm.step, .error, "Step should be .error on compromised device")
            XCTAssertTrue(
                vm.errorMessage.lowercased().contains("compromised") ||
                vm.errorMessage.lowercased().contains("disabled"),
                "Error message should mention compromised/disabled"
            )
        } else {
            // On a safe device, should NOT produce a jailbreak error
            XCTAssertFalse(
                vm.errorMessage.lowercased().contains("compromised"),
                "Should not report compromised on a safe device"
            )
        }
    }

    // MARK: - testSigningTimeoutSetsError

    func testSigningTimeoutSetsError() async {
        let vm = SigningViewModel(wallet: makeWallet())

        guard !SecurityEnvironment.isCompromised else { return }

        // setPin removed — lives on AppState now, not SigningViewModel.
        vm.startSigning()

        // Give the async task time to fail (bridge/deviceKey are nil)
        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms

        let isErrorState = vm.step == .error
        let hasErrorMessage = !vm.errorMessage.isEmpty

        XCTAssertTrue(
            isErrorState || vm.step == .signing,
            "Step should be .error or .signing after starting without deps"
        )
        if isErrorState {
            XCTAssertTrue(hasErrorMessage, "Error state should include an error message")
        }
    }

    // MARK: - testCancelStopsSigning

    func testCancelStopsSigning() {
        let vm = SigningViewModel(wallet: makeWallet())

        guard !SecurityEnvironment.isCompromised else { return }

        // setPin removed — lives on AppState now, not SigningViewModel.
        vm.amount = "0.1"
        vm.startSigning()
        vm.cancelSigning()

        XCTAssertEqual(vm.step, .error, "cancelSigning() should set step to .error")
        let msg = vm.errorMessage.lowercased()
        XCTAssertTrue(
            msg.contains("cancel") || msg.contains("取消"),
            "Error message should mention cancellation (got: \(vm.errorMessage))"
        )
    }

    // MARK: - Solana round count

    func testSolanaUsesTwoRounds() {
        let wallet = makeWallet(chain: .solana)
        let vm = SigningViewModel(wallet: wallet)
        XCTAssertEqual(vm.totalRounds, 2, "Solana (FROST) signing should use 2 rounds")
    }

    // MARK: - shortRecipient formatting

    func testShortRecipientFormatsLongAddress() {
        let vm = SigningViewModel(wallet: makeWallet())
        vm.recipientAddress = "0x742D35CC6634C0532925a3B844Bc9E7595F2bD18"
        XCTAssertTrue(vm.shortRecipient.contains("0x742D"), "Should contain address prefix")
        XCTAssertTrue(vm.shortRecipient.contains("bD18"), "Should contain address suffix")
        XCTAssertTrue(vm.shortRecipient.count < vm.recipientAddress.count, "Should be shortened")
    }

    func testShortRecipientKeepsShortAddress() {
        let vm = SigningViewModel(wallet: makeWallet())
        vm.recipientAddress = "0x1234"
        XCTAssertEqual(vm.shortRecipient, "0x1234", "Short addresses should not be truncated")
    }

    // MARK: - dev.92 kickPeer

    func testKickPeerBlocklistsAndRemovesFromJoined() {
        let vm = SigningViewModel(wallet: makeWallet())
        let a = Peer(id: "peer-a", name: "Alice", channel: "relay")
        let b = Peer(id: "peer-b", name: "Bob", channel: "relay")
        vm.joinedSigners = [a, b]
        vm.peerPartyIndex[a.id] = 2

        vm.kickPeer(a)

        XCTAssertTrue(vm.kickedPeerIds.contains(a.id),
                      "Kicked peer id must go onto the local blocklist")
        XCTAssertNil(vm.peerPartyIndex[a.id],
                     "Kicked peer's party index must be released")
        XCTAssertFalse(vm.joinedSigners.contains(where: { $0.id == a.id }),
                       "Kicked peer must be gone from joinedSigners")
        XCTAssertTrue(vm.joinedSigners.contains(where: { $0.id == b.id }),
                      "Other peers must stay")
    }

    // MARK: - dev.91 regenerateRoomCode

    func testRegenerateRoomCodeMintsFreshCodeAndClearsKickList() {
        let vm = SigningViewModel(wallet: makeWallet())
        let p = Peer(id: "peer-x", name: "X", channel: "relay")
        vm.joinedSigners = [p]
        vm.kickedPeerIds = ["peer-x"]
        vm.peerPartyIndex = ["peer-x": 2]
        let oldCode = "ABCD12"
        vm.roomCode = oldCode
        vm.roomCodeExpiresAt = Date(timeIntervalSince1970: 0)
        vm.roomCodeExpired = true

        vm.regenerateRoomCode()

        XCTAssertFalse(vm.roomCode.isEmpty, "A fresh room code must be generated")
        XCTAssertNotEqual(vm.roomCode, oldCode, "Room code must rotate")
        XCTAssertEqual(vm.sessionId, vm.roomCode,
                       "sessionId must follow the new roomCode for a new ceremony")
        XCTAssertFalse(vm.roomCodeExpired, "New code must start un-expired")
        XCTAssertNotNil(vm.roomCodeExpiresAt, "New TTL must be set")
        if let exp = vm.roomCodeExpiresAt {
            XCTAssertGreaterThan(exp, Date(), "TTL must be in the future")
        }
        XCTAssertTrue(vm.kickedPeerIds.isEmpty,
                      "Rotating the room code clears the blocklist — fresh ceremony, fresh slate")
        XCTAssertTrue(vm.peerPartyIndex.isEmpty,
                      "Party index assignments reset with the room code")
    }

    // MARK: - dev.91 tickRoomCodeExpiry

    func testTickRoomCodeExpiryFlipsToExpired() {
        let vm = SigningViewModel(wallet: makeWallet())
        vm.step = .invite
        vm.roomCodeExpiresAt = Date().addingTimeInterval(-1)
        vm.roomCodeExpired = false

        vm.tickRoomCodeExpiry()

        XCTAssertTrue(vm.roomCodeExpired,
                      "TTL passed → expired flag must flip on tick")
    }

    func testTickRoomCodeExpiryStaysFreshWhenTTLInFuture() {
        let vm = SigningViewModel(wallet: makeWallet())
        vm.step = .invite
        vm.roomCodeExpiresAt = Date().addingTimeInterval(120)
        vm.roomCodeExpired = false

        vm.tickRoomCodeExpiry()

        XCTAssertFalse(vm.roomCodeExpired,
                       "TTL in future → still fresh")
    }

    // MARK: - dev.94 resignToSameRecipient

    func testResignToSameRecipientKeepsRecipientAndTokenResetsRest() {
        let vm = SigningViewModel(wallet: makeWallet())
        vm.step = .complete
        vm.recipientAddress = "0x742D35CC6634C0532925a3B844Bc9E7595F2bD18"
        vm.amount = "1.5"
        vm.estimatedFee = "0.0012 ETH"
        vm.txHash = "0xdeadbeef"
        vm.roomCode = "XYZ123"
        vm.sessionId = "XYZ123"
        vm.joinedSigners = [Peer(id: "p1", name: "P1", channel: "relay")]
        vm.kickedPeerIds = ["someone"]
        vm.peerPartyIndex = ["p1": 2]
        vm.signingProgress = 1.0
        vm.signingStatusMessage = "Done"
        vm.currentRound = 4
        vm.errorMessage = "stale"
        vm.roomCodeExpiresAt = Date()
        vm.roomCodeExpired = true
        vm.isBroadcasting = false
        vm.broadcastStatus = nil

        vm.resignToSameRecipient()

        // Sticky fields kept.
        XCTAssertEqual(vm.recipientAddress,
                       "0x742D35CC6634C0532925a3B844Bc9E7595F2bD18",
                       "Recipient must stick so the user can re-send")
        // Everything else cleared back to compose-fresh defaults.
        XCTAssertEqual(vm.step, .compose)
        XCTAssertEqual(vm.amount, "", "Amount must reset — new transfer, new amount")
        XCTAssertEqual(vm.estimatedFee, "—", "Stale fee estimate must clear")
        XCTAssertNil(vm.txHash, "Previous tx hash must clear")
        XCTAssertEqual(vm.roomCode, "", "Old room code must clear")
        XCTAssertNil(vm.sessionId, "Old session must clear")
        XCTAssertTrue(vm.joinedSigners.isEmpty, "Old peers must clear")
        XCTAssertTrue(vm.kickedPeerIds.isEmpty, "Kick list must clear")
        XCTAssertTrue(vm.peerPartyIndex.isEmpty, "Party assignments must clear")
        XCTAssertEqual(vm.signingProgress, 0)
        XCTAssertEqual(vm.signingStatusMessage, "")
        XCTAssertEqual(vm.currentRound, 0)
        XCTAssertEqual(vm.errorMessage, "")
        XCTAssertNil(vm.roomCodeExpiresAt, "New ceremony will mint its own TTL")
        XCTAssertFalse(vm.roomCodeExpired)
    }
}
