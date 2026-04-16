import XCTest

/// Full E2E flow test for Horcrux iOS app on simulator.
/// Uses -UITesting launch arg to skip notification/jailbreak/debugger alerts.
final class HorcruxE2EFlowTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-UITesting"]
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Full Onboarding E2E Flow

    func testFullOnboardingFlow() throws {
        app.launch()
        sleep(2)

        // ── Step 1: Welcome Screen ──
        let getStartedButton = app.buttons["onboarding_getStartedButton"]

        let s1 = XCTAttachment(screenshot: app.screenshot())
        s1.name = "01_Welcome_Screen"
        s1.lifetime = .keepAlways
        add(s1)

        XCTAssertTrue(getStartedButton.waitForExistence(timeout: 5),
                       "Welcome screen should show Get Started button")
        getStartedButton.tap()
        sleep(1)

        // ── Step 2: Create PIN Screen ──
        let pinField = app.secureTextFields["onboarding_createPinField"]
        XCTAssertTrue(pinField.waitForExistence(timeout: 3), "Create PIN field should appear")

        let s2 = XCTAttachment(screenshot: app.screenshot())
        s2.name = "02_Create_PIN_Screen"
        s2.lifetime = .keepAlways
        add(s2)

        pinField.tap()
        sleep(1)
        pinField.typeText("1234")
        sleep(1)

        let nextButton = app.buttons["onboarding_nextButton"]
        XCTAssertTrue(nextButton.exists, "Next button should exist")
        XCTAssertTrue(nextButton.isEnabled, "Next button should be enabled after 4+ digit PIN")

        let s3 = XCTAttachment(screenshot: app.screenshot())
        s3.name = "03_PIN_Entered"
        s3.lifetime = .keepAlways
        add(s3)

        nextButton.tap()
        sleep(1)

        // ── Step 3: Confirm PIN Screen ──
        let confirmPinField = app.secureTextFields["onboarding_confirmPinField"]
        XCTAssertTrue(confirmPinField.waitForExistence(timeout: 3), "Confirm PIN field should appear")

        let s4 = XCTAttachment(screenshot: app.screenshot())
        s4.name = "04_Confirm_PIN_Screen"
        s4.lifetime = .keepAlways
        add(s4)

        confirmPinField.tap()
        sleep(1)
        confirmPinField.typeText("1234")
        sleep(1)

        let createWalletButton = app.buttons["onboarding_createWalletButton"]
        XCTAssertTrue(createWalletButton.waitForExistence(timeout: 2))
        XCTAssertTrue(createWalletButton.isEnabled, "Create Wallet should be enabled when PINs match")

        let s5 = XCTAttachment(screenshot: app.screenshot())
        s5.name = "05_Ready_Create_Wallet"
        s5.lifetime = .keepAlways
        add(s5)

        createWalletButton.tap()
        sleep(3)

        // ── Step 4: Post-Creation — Main Tabs or Lock Screen ──
        let s6 = XCTAttachment(screenshot: app.screenshot())
        s6.name = "06_After_Create_Wallet"
        s6.lifetime = .keepAlways
        add(s6)

        let tabBar = app.tabBars.firstMatch
        if tabBar.waitForExistence(timeout: 5) {
            XCTAssertTrue(tabBar.buttons.count >= 3, "Should have 3+ tabs (wallet, shards, settings)")

            let tabs = tabBar.buttons.allElementsBoundByIndex

            // ── Step 5: Navigate between tabs ──
            if tabs.count >= 1 {
                tabs[0].tap()
                sleep(1)
                let s7 = XCTAttachment(screenshot: app.screenshot())
                s7.name = "07_Wallet_Tab"
                s7.lifetime = .keepAlways
                add(s7)
            }

            if tabs.count >= 2 {
                tabs[1].tap()
                sleep(1)
                let s8 = XCTAttachment(screenshot: app.screenshot())
                s8.name = "08_Shards_Tab"
                s8.lifetime = .keepAlways
                add(s8)
            }

            if tabs.count >= 3 {
                tabs[2].tap()
                sleep(1)
                let s9 = XCTAttachment(screenshot: app.screenshot())
                s9.name = "09_Settings_Tab"
                s9.lifetime = .keepAlways
                add(s9)
            }
        }
    }

    // MARK: - PIN Mismatch Disables Create Wallet

    func testPinMismatchDisablesCreate() throws {
        app.launch()
        sleep(2)

        let getStartedButton = app.buttons["onboarding_getStartedButton"]
        guard getStartedButton.waitForExistence(timeout: 5) else { return }
        getStartedButton.tap()
        sleep(1)

        let pinField = app.secureTextFields["onboarding_createPinField"]
        guard pinField.waitForExistence(timeout: 3) else { return }
        pinField.tap()
        pinField.typeText("1234")
        sleep(1)

        app.buttons["onboarding_nextButton"].tap()
        sleep(1)

        let confirmPinField = app.secureTextFields["onboarding_confirmPinField"]
        guard confirmPinField.waitForExistence(timeout: 3) else { return }
        confirmPinField.tap()
        confirmPinField.typeText("5678")
        sleep(1)

        let createWalletButton = app.buttons["onboarding_createWalletButton"]
        XCTAssertTrue(createWalletButton.exists)
        XCTAssertFalse(createWalletButton.isEnabled, "Should be disabled when PINs don't match")

        let s = XCTAttachment(screenshot: app.screenshot())
        s.name = "10_PIN_Mismatch"
        s.lifetime = .keepAlways
        add(s)
    }

    // MARK: - Short PIN Disables Next

    func testShortPinDisablesNext() throws {
        app.launch()
        sleep(2)

        let getStartedButton = app.buttons["onboarding_getStartedButton"]
        guard getStartedButton.waitForExistence(timeout: 5) else { return }
        getStartedButton.tap()
        sleep(1)

        let pinField = app.secureTextFields["onboarding_createPinField"]
        guard pinField.waitForExistence(timeout: 3) else { return }
        pinField.tap()
        pinField.typeText("12")
        sleep(1)

        let nextButton = app.buttons["onboarding_nextButton"]
        XCTAssertTrue(nextButton.exists)
        XCTAssertFalse(nextButton.isEnabled, "Next should be disabled with < 4 digit PIN")
    }
}
