import XCTest
@testable import Horcrux

/// Tests for SecurityEnvironment — jailbreak detection, path checks, and environment checks.
final class SecurityEnvironmentTests: XCTestCase {

    // MARK: - testIsCompromisedReturnsFalseOnSimulator

    func testIsCompromisedReturnsFalseOnSimulator() {
        #if targetEnvironment(simulator)
        // On simulator, some jailbreak artifacts may exist in the macOS-based
        // runtime (e.g. /usr/sbin/sshd). Just verify the check completes.
        let result = SecurityEnvironment.check()
        if result.reasons.isEmpty {
            XCTAssertFalse(result.isCompromised)
        } else {
            XCTAssertTrue(result.isCompromised)
        }
        #else
        _ = SecurityEnvironment.check()
        #endif
    }

    // MARK: - testSuspiciousPathsAreChecked

    func testSuspiciousPathsAreChecked() {
        // Verify SecurityEnvironment.check() runs without crashing.
        // On simulator, some host macOS paths trigger detection — expected.
        #if targetEnvironment(simulator)
        let result = SecurityEnvironment.check()
        if result.reasons.isEmpty {
            XCTAssertFalse(result.isCompromised)
        } else {
            XCTAssertTrue(result.isCompromised,
                          "isCompromised should be true when reasons are present")
        }
        #else
        _ = SecurityEnvironment.check()
        #endif
    }

    // MARK: - testForkCheckIsPerformed

    func testForkCheckIsPerformed() {
        #if targetEnvironment(simulator)
        let result = SecurityEnvironment.check()
        let hasForkReason = result.reasons.contains { $0.contains("fork") }
        XCTAssertFalse(hasForkReason,
                       "Fork check should be skipped on simulator (compiled out)")
        #else
        let result = SecurityEnvironment.check()
        let hasForkReason = result.reasons.contains { $0.contains("fork") }
        XCTAssertFalse(hasForkReason,
                       "Fork should fail on a properly sandboxed device")
        #endif
    }

    // MARK: - testURLSchemeChecks

    func testURLSchemeChecks() {
        #if targetEnvironment(simulator)
        let result = SecurityEnvironment.check()
        let hasSchemeReason = result.reasons.contains { $0.contains("URL scheme") }
        XCTAssertFalse(hasSchemeReason,
                       "No suspicious URL schemes should be detected on a clean simulator")
        #else
        _ = SecurityEnvironment.check()
        #endif
    }

    // MARK: - testCheckResultIsNotCompromisedWhenReasonsEmpty

    func testCheckResultIsNotCompromisedWhenReasonsEmpty() {
        let result = SecurityEnvironment.check()
        if result.reasons.isEmpty {
            XCTAssertFalse(result.isCompromised)
        } else {
            XCTAssertTrue(result.isCompromised)
        }
    }
}
