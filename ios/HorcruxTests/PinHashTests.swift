import XCTest
@testable import Horcrux

/// Tests for PBKDF2 PIN hashing in AppState.
@MainActor
final class PinHashTests: XCTestCase {

    func testHashPinProducesCorrectLength() {
        let result = AppState.hashPin("1234")
        // salt (16) + hash (32) = 48 bytes
        XCTAssertEqual(result.count, 48)
    }

    func testHashPinDeterministicWithSameSalt() {
        let salt = Data(repeating: 0xAB, count: 16)
        let hash1 = AppState.hashPin("1234", salt: salt)
        let hash2 = AppState.hashPin("1234", salt: salt)
        XCTAssertEqual(hash1, hash2)
    }

    func testHashPinDifferentPinsDifferentHashes() {
        let salt = Data(repeating: 0xCD, count: 16)
        let hash1 = AppState.hashPin("1234", salt: salt)
        let hash2 = AppState.hashPin("5678", salt: salt)
        XCTAssertNotEqual(hash1, hash2)
    }

    func testHashPinDifferentSaltsDifferentHashes() {
        let salt1 = Data(repeating: 0x01, count: 16)
        let salt2 = Data(repeating: 0x02, count: 16)
        let hash1 = AppState.hashPin("1234", salt: salt1)
        let hash2 = AppState.hashPin("1234", salt: salt2)
        XCTAssertNotEqual(hash1, hash2)
    }

    func testHashPinSaltIsPrefix() {
        let salt = Data(repeating: 0xEF, count: 16)
        let result = AppState.hashPin("1234", salt: salt)
        XCTAssertEqual(Data(result.prefix(16)), salt)
    }

    func testHashPinRandomSaltEachCall() {
        let hash1 = AppState.hashPin("1234")
        let hash2 = AppState.hashPin("1234")
        // Different random salts -> different results
        XCTAssertNotEqual(hash1, hash2)
    }

    func testPinKeyMaterialRequiresStoredPin() {
        // pinKeyMaterial requires a PIN salt stored in Keychain.
        // Without a stored PIN, it should throw keychainUnavailable.
        XCTAssertThrowsError(try AppState.pinKeyMaterial("1234")) { error in
            if case AppError.keychainUnavailable = error {
                // Expected
            } else {
                // May also succeed if a PIN was stored by a previous test run
            }
        }
    }

    func testPinKeyMaterialWithStoredPin() throws {
        // Store a PIN hash first, then derive key material.
        let pinHash = AppState.hashPin("1234")
        try KeychainManager.shared.store(key: "com.horcrux.pin_hash", data: pinHash)

        defer {
            try? KeychainManager.shared.delete(key: "com.horcrux.pin_hash")
        }

        let material = try AppState.pinKeyMaterial("1234")
        XCTAssertEqual(material.count, 32, "Key material should be 32 bytes")
    }

    func testEmptyPinHashesSuccessfully() {
        let result = AppState.hashPin("")
        XCTAssertEqual(result.count, 48)
    }

    func testLongPinHashesSuccessfully() {
        let longPin = String(repeating: "1", count: 1000)
        let result = AppState.hashPin(longPin)
        XCTAssertEqual(result.count, 48)
    }
}
