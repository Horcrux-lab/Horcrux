import XCTest
@testable import Horcrux

/// Tests for SecureEnclaveManager — error paths, sealed data validation, and error descriptions.
/// Most happy-path operations require real SE hardware; these tests focus on
/// deterministic error paths that work on the simulator.
final class SecureEnclaveManagerTests: XCTestCase {

    private let manager = SecureEnclaveManager.shared

    // MARK: - testSealFailsWithInvalidKey

    func testSealFailsWithInvalidKey() {
        #if targetEnvironment(simulator)
        // On simulator, Secure Enclave is not available. Attempting to seal
        // should fail because no SE key can be generated.
        XCTAssertFalse(manager.isAvailable,
                       "SE should not be available on simulator")

        XCTAssertThrowsError(try manager.seal(Data("test plaintext".utf8))) { error in
            // Should throw a SecureEnclaveError (keyGenerationFailed or similar).
            XCTAssertTrue(error is SecureEnclaveError,
                          "Expected SecureEnclaveError, got \(type(of: error)): \(error)")
        }
        #else
        // On device with SE, seal may succeed — skip this test.
        throw XCTSkip("This test targets simulator (no SE hardware)")
        #endif
    }

    // MARK: - testOpenFailsWithInvalidSealedData

    func testOpenFailsWithInvalidSealedData() {
        // Data shorter than the minimum (65 + 12 + 16 = 93 bytes) should throw
        // invalidSealedData immediately, before any crypto operation.
        let tooShort = Data(repeating: 0xAB, count: 50)

        XCTAssertThrowsError(try manager.open(tooShort)) { error in
            guard let seError = error as? SecureEnclaveError else {
                XCTFail("Expected SecureEnclaveError, got \(type(of: error))")
                return
            }
            if case .invalidSealedData = seError {
                // Expected
            } else {
                XCTFail("Expected .invalidSealedData, got \(seError)")
            }
        }
    }

    // MARK: - testOpenFailsWithCorruptedData

    func testOpenFailsWithCorruptedData() {
        // Data of valid length but random content should fail during decryption.
        let corrupted = Data(repeating: 0xFF, count: 200)

        XCTAssertThrowsError(try manager.open(corrupted)) { error in
            // Should throw a SecureEnclaveError — either decryptionFailed or
            // keyLoadFailed (since there's no SE key on simulator).
            XCTAssertTrue(error is SecureEnclaveError,
                          "Expected SecureEnclaveError, got \(type(of: error)): \(error)")
        }
    }

    // MARK: - testDeleteKeyDoesNotCrash

    func testDeleteKeyDoesNotCrash() {
        // Calling deleteKey when no key exists should be a no-op (not crash).
        // SecItemDelete returns errSecItemNotFound which is silently ignored.
        manager.deleteKey()
        // If we reach here, the test passes — no crash or exception.
    }

    // MARK: - testErrorDescriptions

    func testErrorDescriptions() {
        let errors: [SecureEnclaveError] = [
            .notAvailable,
            .keyGenerationFailed("test"),
            .keyLoadFailed(errSecItemNotFound),
            .publicKeyUnavailable,
            .invalidSealedData,
            .sealFailed,
            .decryptionFailed("test"),
            .accessControlFailed("test")
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription,
                            "Error \(error) should have a non-nil errorDescription")
            XCTAssertFalse(error.errorDescription!.isEmpty,
                           "Error \(error) should have a non-empty errorDescription")
        }
    }

    // MARK: - testIsAvailableReturnsFalseOnSimulator

    func testIsAvailableReturnsFalseOnSimulator() {
        #if targetEnvironment(simulator)
        XCTAssertFalse(manager.isAvailable,
                       "Secure Enclave should not be available on simulator")
        #else
        // On device, SE is typically available.
        XCTAssertTrue(manager.isAvailable,
                      "Secure Enclave should be available on a real device")
        #endif
    }
}
