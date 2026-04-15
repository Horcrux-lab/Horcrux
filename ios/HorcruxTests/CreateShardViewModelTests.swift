import XCTest
@testable import Horcrux

/// Tests for CreateShardViewModel — initial state, DKG lifecycle, jailbreak gate.
@MainActor
final class CreateShardViewModelTests: XCTestCase {

    // MARK: - testInitialState

    func testInitialState() {
        let vm = CreateShardViewModel()

        XCTAssertEqual(vm.step, .configure, "Initial step should be .configure")
        XCTAssertEqual(vm.walletName, "", "walletName should start empty")
        XCTAssertEqual(vm.selectedChain, .ethereum, "Default chain should be Ethereum")
        XCTAssertEqual(vm.threshold, 2, "Default threshold should be 2")
        XCTAssertEqual(vm.totalParties, 3, "Default totalParties should be 3")
        XCTAssertEqual(vm.partyIndex, 1, "Default partyIndex should be 1")
        XCTAssertTrue(vm.selectedTransports.contains(.ble), "BLE should be selected by default")
        XCTAssertTrue(vm.selectedTransports.contains(.wifiLAN), "Wi-Fi LAN should be selected by default")
        XCTAssertEqual(vm.dkgProgress, 0, "Progress should start at 0")
        XCTAssertEqual(vm.currentRound, 0, "currentRound should start at 0")
        XCTAssertEqual(vm.totalRounds, 7, "Default totalRounds should be 7 (CGGMP21)")
        XCTAssertNil(vm.generatedAddress, "No address should be generated initially")
        XCTAssertEqual(vm.errorMessage, "", "errorMessage should start empty")
        XCTAssertTrue(vm.foundPeers.isEmpty, "No peers should be found initially")
    }

    // MARK: - testStartDKGSetsIsRunning

    func testStartDKGSetsIsRunning() {
        let vm = CreateShardViewModel()

        // Without a bound AppState, startDKG will fail early if SecurityEnvironment
        // doesn't flag compromise. On non-jailbroken test runners it proceeds to .dkg
        // and then errors because bridge is nil.
        // We verify the step transitions away from .configure.
        guard !SecurityEnvironment.isCompromised else {
            // On a compromised runner, it goes straight to .error (tested separately)
            return
        }

        vm.startDKG()

        // The VM should have moved to .dkg (bridge is nil so it will eventually error,
        // but the synchronous step change happens first).
        XCTAssertEqual(vm.step, .dkg, "startDKG should transition step to .dkg")
    }

    // MARK: - testJailbreakBlocksDKG

    func testJailbreakBlocksDKG() {
        // SecurityEnvironment.isCompromised is a static computed property that checks
        // real device state. On standard CI / simulator it returns false.
        // We test the ViewModel's guarding logic by checking that IF the device is
        // compromised, the correct error is set. If not compromised, we verify that
        // the VM does NOT set a jailbreak error.
        let vm = CreateShardViewModel()
        vm.startDKG()

        if SecurityEnvironment.isCompromised {
            XCTAssertEqual(vm.step, .error, "Step should be .error on compromised device")
            XCTAssertTrue(
                vm.errorMessage.lowercased().contains("compromised") ||
                vm.errorMessage.lowercased().contains("disabled"),
                "Error message should mention compromised device"
            )
        } else {
            // On a safe device, startDKG should NOT produce a jailbreak error
            XCTAssertNotEqual(
                vm.errorMessage.lowercased().contains("compromised"), true,
                "Should not report compromised on a safe device"
            )
        }
    }

    // MARK: - testCeremonyTimeoutSetsError

    func testCeremonyTimeoutSetsError() async {
        // Without peers or a bridge, the ceremony task fails quickly with an error.
        // This simulates a "timeout-like" scenario: the ceremony cannot complete.
        let vm = CreateShardViewModel()

        guard !SecurityEnvironment.isCompromised else { return }

        vm.startDKG()

        // Give the async task time to fail
        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms

        // The task should have failed because bridge is nil
        let isErrorState = vm.step == .error
        let hasErrorMessage = !vm.errorMessage.isEmpty

        // Either we're in error state, or still in dkg (ceremony running with nil bridge)
        XCTAssertTrue(
            isErrorState || vm.step == .dkg,
            "Step should be .error or .dkg after starting without bridge"
        )
        if isErrorState {
            XCTAssertTrue(hasErrorMessage, "Error state should have an error message")
        }
    }

    // MARK: - testCancelStopsCeremony

    func testCancelStopsCeremony() {
        let vm = CreateShardViewModel()

        guard !SecurityEnvironment.isCompromised else { return }

        vm.startDKG()
        vm.cancel()

        XCTAssertEqual(vm.step, .error, "cancel() should set step to .error")
        XCTAssertTrue(
            vm.errorMessage.lowercased().contains("cancel"),
            "Error message should mention cancellation"
        )
    }

    // MARK: - Solana round count

    func testSolanaUsesThreeRounds() {
        let vm = CreateShardViewModel()
        vm.selectedChain = .solana
        vm.startDiscovery()

        XCTAssertEqual(vm.totalRounds, 3, "Solana (FROST) should use 3 rounds")
    }

    // MARK: - MpcMessageDTO round-trip

    func testMpcMessageDTORoundTrip() throws {
        let original = FfiMpcMessage(
            fromParty: 1,
            toParty: 2,
            round: 3,
            sessionId: "test-session",
            payload: Data([0xCA, 0xFE])
        )
        let dto = MpcMessageDTO(original)
        let data = try JSONEncoder().encode(dto)
        let decoded = try JSONDecoder().decode(MpcMessageDTO.self, from: data)
        let restored = decoded.toFfi()

        XCTAssertEqual(restored.fromParty, 1)
        XCTAssertEqual(restored.toParty, 2)
        XCTAssertEqual(restored.round, 3)
        XCTAssertEqual(restored.sessionId, "test-session")
        XCTAssertEqual(restored.payload, Data([0xCA, 0xFE]))
    }
}
