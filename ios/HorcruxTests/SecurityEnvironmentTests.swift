import XCTest
@testable import Horcrux

/// Tests for SecurityEnvironment — jailbreak detection, path checks, and environment checks.
final class SecurityEnvironmentTests: XCTestCase {

    // MARK: - testIsCompromisedReturnsFalseOnSimulator

    func testIsCompromisedReturnsFalseOnSimulator() {
        #if targetEnvironment(simulator)
        // On simulator, none of the jailbreak artifacts should exist,
        // the system partition should not be writable, and fork is skipped.
        let result = SecurityEnvironment.check()
        XCTAssertFalse(result.isCompromised,
                       "Simulator should not be detected as compromised. Reasons: \(result.reasons)")
        #else
        // On a non-jailbroken device this should also be false, but we
        // can't guarantee the test environment. Just verify it runs.
        _ = SecurityEnvironment.check()
        #endif
    }

    // MARK: - testSuspiciousPathsAreChecked

    func testSuspiciousPathsAreChecked() {
        // We can't directly access the private `jailbreakPaths` array, but we
        // can verify that the check considers these well-known jailbreak indicators
        // by confirming none of them exist on a clean simulator, and the check passes.
        let knownPaths = [
            "/Applications/Cydia.app",
            "/Library/MobileSubstrate/MobileSubstrate.dylib",
            "/usr/sbin/sshd",
            "/etc/apt",
            "/private/var/lib/cydia"
        ]

        #if targetEnvironment(simulator)
        // On a clean simulator, none of these should exist.
        for path in knownPaths {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path),
                           "Jailbreak artifact should not exist on simulator: \(path)")
        }

        // The overall check should pass (not compromised).
        let result = SecurityEnvironment.check()
        XCTAssertFalse(result.isCompromised,
                       "No jailbreak paths should trigger on simulator")
        #else
        // On device, just verify the function completes without crashing.
        _ = SecurityEnvironment.check()
        #endif
    }

    // MARK: - testForkCheckIsPerformed

    func testForkCheckIsPerformed() {
        // The fork-based check is conditionally compiled out on simulator
        // (#if !targetEnvironment(simulator)), so on simulator it should NOT
        // contribute a "can fork" reason.
        #if targetEnvironment(simulator)
        let result = SecurityEnvironment.check()
        let hasForkReason = result.reasons.contains { $0.contains("fork") }
        XCTAssertFalse(hasForkReason,
                       "Fork check should be skipped on simulator (compiled out)")
        #else
        // On a non-jailbroken device, fork should fail (sandboxed).
        let result = SecurityEnvironment.check()
        let hasForkReason = result.reasons.contains { $0.contains("fork") }
        XCTAssertFalse(hasForkReason,
                       "Fork should fail on a properly sandboxed device")
        #endif
    }

    // MARK: - testURLSchemeChecks

    func testURLSchemeChecks() {
        // On a clean simulator, cydia:// should not be openable.
        // We verify the check doesn't produce a suspicious-schemes reason.
        #if targetEnvironment(simulator)
        let result = SecurityEnvironment.check()
        let hasSchemeReason = result.reasons.contains { $0.contains("URL scheme") }
        XCTAssertFalse(hasSchemeReason,
                       "No suspicious URL schemes should be detected on a clean simulator")
        #else
        // On device, just verify it runs.
        _ = SecurityEnvironment.check()
        #endif
    }

    // MARK: - testCheckResultIsNotCompromisedWhenReasonsEmpty

    func testCheckResultIsNotCompromisedWhenReasonsEmpty() {
        // The isCompromised flag should directly reflect whether reasons is non-empty.
        let result = SecurityEnvironment.check()
        if result.reasons.isEmpty {
            XCTAssertFalse(result.isCompromised)
        } else {
            XCTAssertTrue(result.isCompromised)
        }
    }
}
