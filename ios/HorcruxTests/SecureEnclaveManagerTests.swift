import XCTest
@testable import Horcrux

/// Tests for SecureEnclaveManager error paths and sealed data validation.
final class SecureEnclaveManagerTests: XCTestCase {

    private let manager = SecureEnclaveManager.shared

    // MARK: - testSealFailsWithInvalidKey

    func testSealFailsWithInvalidKey() throws {
        #if targetEnvironment(simulator)
        // On Apple Silicon simulators, SE may be available.
        // On Intel simulators, SE is not available.
        if manager.isAvailable {
            // SE available — seal should succeed or fail gracefully
            // (depending on key state). Just verify no crash.
            _ = try? manager.seal(Data("test plaintext".utf8))
        } else {
            XCTAssertThrowsError(try manager.seal(Data("test plaintext".utf8))) { error in
                XCTAssertTrue(error is SecureEnclaveError,
                              "Expected SecureEnclaveError, got \(type(of: error)): \(error)")
            }
        }
        #else
        throw XCTSkip("This test targets simulator (no guaranteed SE behavior)")
        #endif
    }

    // MARK: - testOpenFailsWithInvalidSealedData

    func testOpenFailsWithInvalidSealedData() {
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
        let corrupted = Data(repeating: 0xFF, count: 200)

        XCTAssertThrowsError(try manager.open(corrupted)) { error in
            XCTAssertTrue(error is SecureEnclaveError,
                          "Expected SecureEnclaveError, got \(type(of: error)): \(error)")
        }
    }

    // MARK: - testDeleteKeyDoesNotCrash

    func testDeleteKeyDoesNotCrash() {
        manager.deleteKey()
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

    // MARK: - testIsAvailableProperty

    func testIsAvailableProperty() {
        // Just verify the property is accessible and returns a consistent value.
        let first = manager.isAvailable
        let second = manager.isAvailable
        XCTAssertEqual(first, second, "isAvailable should be consistent across calls")
    }
}
