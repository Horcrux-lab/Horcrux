import XCTest

/// E2E test for the 2-of-2 relay DKG ceremony.
///
/// Run on two simulators simultaneously:
///   Device 1 (party 1): xcodebuild test -only-testing:HorcruxUITests/RelayDKGTests/testRelayDKGParty1 -destination 'id=DEVICE_1_UDID'
///   Device 2 (party 2): xcodebuild test -only-testing:HorcruxUITests/RelayDKGTests/testRelayDKGParty2 -destination 'id=DEVICE_2_UDID'
///
/// Prerequisites:
///   - Relay server running on localhost:3210
///   - Both simulators booted
final class RelayDKGTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-UITesting", "-UITestingResetState"]
    }

    override func tearDownWithError() throws {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "final_state"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app = nil
    }

    // MARK: - Device 1 (Party Index 1)

    func testRelayDKGParty1() throws {
        try runRelayDKG(partyIndex: 1)
    }

    // MARK: - Device 2 (Party Index 2)

    func testRelayDKGParty2() throws {
        try runRelayDKG(partyIndex: 2)
    }

    // MARK: - Shared Flow

    private func runRelayDKG(partyIndex: Int) throws {
        app.launch()
        sleep(2)
        screenshot("00_Launch")

        // ── Onboarding ──
        let getStarted = app.buttons["onboarding_getStartedButton"]
        if getStarted.waitForExistence(timeout: 3) {
            // Fresh app — complete onboarding
            getStarted.tap()
            sleep(1)

            let pinField = app.secureTextFields["onboarding_createPinField"]
            XCTAssertTrue(pinField.waitForExistence(timeout: 3))
            pinField.tap()
            usleep(500000)
            pinField.typeText("1234")
            usleep(500000)

            app.buttons["onboarding_nextButton"].tap()
            sleep(1)

            let confirmField = app.secureTextFields["onboarding_confirmPinField"]
            XCTAssertTrue(confirmField.waitForExistence(timeout: 3))
            confirmField.tap()
            usleep(500000)
            confirmField.typeText("1234")
            usleep(500000)

            let createWallet = app.buttons["onboarding_createWalletButton"]
            XCTAssertTrue(createWallet.waitForExistence(timeout: 2))
            createWallet.tap()
            sleep(2)
            screenshot("01_Onboarding_Complete")
        }

        // ── Unlock if needed ──
        let unlockButton = app.buttons["lockScreen_unlockButton"]
        if unlockButton.waitForExistence(timeout: 2) {
            let pinField = app.secureTextFields["lockScreen_pinField"]
            XCTAssertTrue(pinField.exists)
            pinField.tap()
            usleep(500000)
            pinField.typeText("1234")
            usleep(500000)
            unlockButton.tap()
            sleep(2)
            screenshot("01_Unlocked")
        }

        // ── Should be on main tab screen ──
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5), "Should see tab bar")
        screenshot("02_Main_Screen")

        // ── Tap + to create new shard ──
        let createButton = app.buttons["walletHome_createButton"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 3), "Create wallet button should exist")
        createButton.tap()
        sleep(1)
        screenshot("03_Create_Shard_Configure")

        // ── Configure 2-of-2 ──
        // Set wallet name
        let walletNameField = app.textFields["configure_walletNameField"]
        XCTAssertTrue(walletNameField.waitForExistence(timeout: 3))
        walletNameField.tap()
        usleep(500000)
        walletNameField.typeText("Test Vault")
        // Dismiss keyboard
        app.keyboards.buttons["return"].tap()
        sleep(1)

        // Total parties should default to 2, threshold to 2
        // Set party index if needed (default is 1, party 2 needs increment)
        if partyIndex == 2 {
            let stepper = app.steppers["configure_partyIndexStepper"]
            if stepper.waitForExistence(timeout: 2) {
                // Tap the right side of the stepper (increment)
                stepper.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
                usleep(500000)
            }
        }
        screenshot("04_Configured_Party\(partyIndex)")

        // ── Enable Relay transport and set room code ──
        // Default transport is relay only, but ensure it's set
        app.swipeUp()
        sleep(1)

        // Enter room code (relay toggle should already be on)
        let roomCodeField = app.textFields["configure_roomCodeField"]
        if !roomCodeField.waitForExistence(timeout: 3) {
            // Relay might not be enabled — find and enable it
            let relayToggle = app.switches.matching(NSPredicate(format: "label CONTAINS 'Relay'")).firstMatch
            if relayToggle.waitForExistence(timeout: 2) {
                if relayToggle.value as? String == "0" {
                    relayToggle.tap()
                    sleep(1)
                }
            }
            XCTAssertTrue(roomCodeField.waitForExistence(timeout: 3), "Room code field should appear")
        }
        roomCodeField.tap()
        usleep(500000)
        roomCodeField.typeText("test-dkg-room")
        // Dismiss keyboard
        if app.keyboards.buttons["return"].exists {
            app.keyboards.buttons["return"].tap()
        }
        sleep(1)
        screenshot("05_Relay_Configured")

        // ── Tap "Find Peers" ──
        let nextButton = app.buttons["configure_nextButton"]
        // Scroll down to find it
        app.swipeUp()
        usleep(500000)
        XCTAssertTrue(nextButton.waitForExistence(timeout: 3))
        XCTAssertTrue(nextButton.isEnabled, "Next button should be enabled")
        nextButton.tap()
        sleep(2)
        screenshot("06_Peer_Discovery")

        // ── Wait for peer discovery ──
        // The other device should join the same room. Wait up to 60 seconds.
        let startDKG = app.buttons["discover_startDKGButton"]
        let peerFound = startDKG.waitForExistence(timeout: 60)
        screenshot("07_Peers_Found_\(peerFound)")

        if peerFound {
            // ── Start DKG ──
            startDKG.tap()
            sleep(2)
            screenshot("08_DKG_In_Progress")

            // Wait for DKG to complete (up to 120 seconds for CGGMP21)
            let saveButton = app.buttons["dkgComplete_saveButton"]
            let dkgComplete = saveButton.waitForExistence(timeout: 120)
            screenshot("09_DKG_Result_\(dkgComplete)")

            if dkgComplete {
                XCTAssertTrue(true, "DKG ceremony completed successfully!")
            } else {
                // Check if we're on error screen
                let retryButton = app.buttons["dkgError_retryButton"]
                if retryButton.exists {
                    screenshot("09_DKG_Error")
                    XCTFail("DKG ceremony failed — see error screenshot")
                } else {
                    screenshot("09_DKG_Timeout")
                    XCTFail("DKG ceremony timed out after 120 seconds")
                }
            }
        } else {
            screenshot("07_Peer_Discovery_Timeout")
            XCTFail("Peer discovery timed out — other device not found within 60 seconds")
        }
    }

    // MARK: - Helpers

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
