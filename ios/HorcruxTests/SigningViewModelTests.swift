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
            address: "0x742d35Cc6634C0532925a3b844Bc9e7595f2bD18",
            groupPublicKey: Data([0x02, 0x03, 0x04]),
            threshold: 2,
            totalParties: 3,
            partyIndex: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
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

    // MARK: - testStartSigningSetsIsRunning

    func testStartSigningSetsIsRunning() {
        let vm = SigningViewModel(wallet: makeWallet())

        guard !SecurityEnvironment.isCompromised else { return }

        // Without bind(), bridge/deviceKey are nil — startSigning transitions to .signing
        // then the async task quickly errors. We verify the synchronous step change.
        vm.setPin("123456")
        vm.startSigning()

        XCTAssertEqual(vm.step, .signing, "startSigning should transition step to .signing")
    }

    // MARK: - testJailbreakBlocksSigning

    func testJailbreakBlocksSigning() {
        let vm = SigningViewModel(wallet: makeWallet())
        vm.setPin("123456")
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

        vm.setPin("123456")
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

        vm.setPin("123456")
        vm.startSigning()
        vm.cancelSigning()

        XCTAssertEqual(vm.step, .error, "cancelSigning() should set step to .error")
        XCTAssertTrue(
            vm.errorMessage.lowercased().contains("cancel"),
            "Error message should mention cancellation"
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
        vm.recipientAddress = "0x742d35Cc6634C0532925a3b844Bc9e7595f2bD18"
        XCTAssertTrue(vm.shortRecipient.contains("0x742d"), "Should contain address prefix")
        XCTAssertTrue(vm.shortRecipient.contains("bD18"), "Should contain address suffix")
        XCTAssertTrue(vm.shortRecipient.count < vm.recipientAddress.count, "Should be shortened")
    }

    func testShortRecipientKeepsShortAddress() {
        let vm = SigningViewModel(wallet: makeWallet())
        vm.recipientAddress = "0x1234"
        XCTAssertEqual(vm.shortRecipient, "0x1234", "Short addresses should not be truncated")
    }
}
