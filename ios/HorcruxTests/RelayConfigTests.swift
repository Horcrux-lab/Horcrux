import XCTest
@testable import Horcrux

/// Tests for `RelayConfig` URL resolution.
///
/// `effectiveURL` consults three sources in order: Keychain-stored custom
/// URL (gated by `useCustom`), the `HORCRUX_RELAY_URL` scheme env var, and
/// the build-config default. Keychain-backed storage is shared with the
/// real keychain, so each test cleans up after itself.
final class RelayConfigTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Guarantee a clean slate even if a previous test crashed before
        // cleanup — otherwise a stale keychain entry leaks state across
        // test runs.
        RelayConfig.resetToDefault()
        try? KeychainManager.shared.delete(key: RelayConfig.customURLKey)
    }

    override func tearDown() {
        RelayConfig.resetToDefault()
        try? KeychainManager.shared.delete(key: RelayConfig.customURLKey)
        super.tearDown()
    }

    // MARK: - Defaults

    func testDefault_useCustomIsFalse() {
        XCTAssertFalse(RelayConfig.useCustom)
    }

    func testDefault_returnsBuildConfigURL() {
        // Debug build → localDevelopmentURL; Release → officialURL.
        // Either way it must be one of the two documented defaults.
        let url = RelayConfig.effectiveURL
        XCTAssertTrue(
            url == RelayConfig.localDevelopmentURL || url == RelayConfig.officialURL,
            "effectiveURL (\(url)) should fall back to a documented default"
        )
    }

    func testOfficialURL_usesWSS() {
        // Corporate / carrier proxies often only allow 443 out; WSS over
        // 443 keeps the relay reachable from locked-down networks.
        XCTAssertTrue(RelayConfig.officialURL.hasPrefix("wss://"))
    }

    // MARK: - Custom URL persistence

    func testSetCustom_enablesCustomAndPersists() throws {
        try RelayConfig.setCustom("wss://my.relay.example.com")
        XCTAssertTrue(RelayConfig.useCustom)
        XCTAssertEqual(RelayConfig.effectiveURL, "wss://my.relay.example.com")
    }

    func testResetToDefault_disablesCustomFlag() throws {
        try RelayConfig.setCustom("wss://my.relay.example.com")
        XCTAssertTrue(RelayConfig.useCustom)
        RelayConfig.resetToDefault()
        XCTAssertFalse(RelayConfig.useCustom)
        // The keychain entry may still be present, but effectiveURL must
        // ignore it once the flag is off.
        XCTAssertNotEqual(RelayConfig.effectiveURL, "wss://my.relay.example.com")
    }

    func testUseCustomWithoutKeychainEntry_fallsBackToDefault() {
        // Simulate the case where the flag got flipped on but the stored
        // value was wiped (e.g. after keychain reset / device restore).
        RelayConfig.useCustom = true
        try? KeychainManager.shared.delete(key: RelayConfig.customURLKey)

        let url = RelayConfig.effectiveURL
        XCTAssertTrue(
            url == RelayConfig.localDevelopmentURL || url == RelayConfig.officialURL,
            "Missing keychain entry must fall back to a build default, got \(url)"
        )
    }
}
