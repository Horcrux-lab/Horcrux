import XCTest
@testable import Horcrux

/// Tests for `SecureKeyVault`: PIN-wrap / unwrap roundtrip, wrong-PIN failure,
/// PIN-rewrap, transparent v1 (100k PBKDF2) → v2 (600k) migration, and wipe.
///
/// These tests exercise only the PIN-wrap path; the Secure Enclave seal path
/// cannot be tested on the simulator. They mutate Keychain state under the
/// app's service, so each test deletes both v1 and v2 SWK entries before and
/// after to keep runs hermetic.
final class SecureKeyVaultTests: XCTestCase {

    private let v2Key = SecureKeyVault.keychainPinWrapped
    private let v1Key = SecureKeyVault.keychainPinWrappedLegacy
    private let seKey = SecureKeyVault.keychainSESealed

    override func setUp() {
        super.setUp()
        clearVault()
    }

    override func tearDown() {
        clearVault()
        super.tearDown()
    }

    private func clearVault() {
        try? KeychainManager.shared.delete(key: v2Key)
        try? KeychainManager.shared.delete(key: v1Key)
        try? KeychainManager.shared.delete(key: seKey)
    }

    // MARK: - Provision + unwrap

    func testProvisionAndUnwrapRoundtrip() throws {
        let swk = try SecureKeyVault.provision(pin: "123456")
        XCTAssertEqual(swk.count, 32)
        XCTAssertTrue(SecureKeyVault.hasPinWrapped)

        let recovered = try SecureKeyVault.unwrapWithPin("123456")
        XCTAssertEqual(recovered, swk)
    }

    func testUnwrapWithWrongPinFails() throws {
        _ = try SecureKeyVault.provision(pin: "123456")
        XCTAssertThrowsError(try SecureKeyVault.unwrapWithPin("000000"))
    }

    func testUnwrapWithoutProvisioningThrowsNotProvisioned() {
        XCTAssertFalse(SecureKeyVault.hasPinWrapped)
        XCTAssertThrowsError(try SecureKeyVault.unwrapWithPin("123456")) { error in
            guard let vaultError = error as? SecureKeyVault.VaultError else {
                XCTFail("expected VaultError, got \(error)")
                return
            }
            if case .notProvisioned = vaultError {
                // ok
            } else {
                XCTFail("expected .notProvisioned, got \(vaultError)")
            }
        }
    }

    // MARK: - Rewrap

    func testRewrapWithNewPin() throws {
        let swk = try SecureKeyVault.provision(pin: "oldpin")
        try SecureKeyVault.rewrapPinWrapped(swk: swk, newPin: "newpin")

        XCTAssertEqual(try SecureKeyVault.unwrapWithPin("newpin"), swk)
        XCTAssertThrowsError(try SecureKeyVault.unwrapWithPin("oldpin"))
    }

    // MARK: - Byte-based API (C2 zeroize path)

    func testProvisionAndUnwrapWithPinBytes() throws {
        var pinBytes: [UInt8] = [0x31, 0x32, 0x33, 0x34, 0x35, 0x36] // "123456"
        let swk = try SecureKeyVault.provision(pinBytes: pinBytes)
        XCTAssertEqual(swk.count, 32)

        let recovered = try SecureKeyVault.unwrapWithPin(pinBytes: pinBytes)
        XCTAssertEqual(recovered, swk)

        // String API should interoperate with bytes API (same UTF-8).
        XCTAssertEqual(try SecureKeyVault.unwrapWithPin("123456"), swk)

        SecureKeyVault.zeroize(&pinBytes)
        XCTAssertTrue(pinBytes.allSatisfy { $0 == 0 })
    }

    func testZeroizeClearsBuffer() {
        var bytes: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        SecureKeyVault.zeroize(&bytes)
        XCTAssertEqual(bytes, Array(repeating: 0, count: 8))
    }

    // MARK: - v1 cleanup on successful v2 unwrap (C3)

    func testV2UnwrapDeletesLingeringV1Blob() throws {
        // Provision v2.
        _ = try SecureKeyVault.provision(pin: "123456")

        // Plant an unrelated v1 blob that simulates a partial migration
        // where v2 was created but v1 was not deleted (e.g., a prior
        // keychain delete failure).
        let legacyBlob = try makeLegacyPinWrappedBlob(
            swk: Data(repeating: 0x77, count: 32),
            pin: "unrelated"
        )
        try KeychainManager.shared.storeSecure(key: v1Key, data: legacyBlob)
        XCTAssertNotNil(try KeychainManager.shared.retrieve(key: v1Key))

        // A successful v2 unwrap with the correct PIN should proactively
        // clean up the lingering v1 blob.
        _ = try SecureKeyVault.unwrapWithPin("123456")
        XCTAssertNil(try KeychainManager.shared.retrieve(key: v1Key))
    }

    // MARK: - v1 → v2 migration

    func testLegacyV1BlobIsMigratedToV2OnUnwrap() throws {
        // Provision under v2, then move it to the legacy key to simulate an
        // install that predates the PBKDF2 iteration bump. Since v1 used the
        // same (salt || AES-GCM.combined) blob format, only the key it lives
        // under and the derived wrap-key iteration count differ.
        //
        // To construct a realistic legacy blob we *can't* just copy a v2 blob
        // into v1 — the iteration counts wouldn't match, so unwrap would fail.
        // Instead we rely on SecureKeyVault's own unwrap codepath: we stage a
        // blob that v1 unwraps cleanly, provisioned via a helper that only
        // this test file reaches into.
        let legacyBlob = try makeLegacyPinWrappedBlob(
            swk: Data(repeating: 0xAB, count: 32),
            pin: "654321"
        )
        try KeychainManager.shared.storeSecure(key: v1Key, data: legacyBlob)
        XCTAssertTrue(SecureKeyVault.hasPinWrapped, "legacy blob should count as provisioned")
        XCTAssertNil(try KeychainManager.shared.retrieve(key: v2Key))

        let swk = try SecureKeyVault.unwrapWithPin("654321")
        XCTAssertEqual(swk, Data(repeating: 0xAB, count: 32))

        // After migration: v2 exists, v1 is gone.
        XCTAssertNotNil(try KeychainManager.shared.retrieve(key: v2Key))
        XCTAssertNil(try KeychainManager.shared.retrieve(key: v1Key))

        // And the new v2 blob is unwrappable with the same PIN.
        let again = try SecureKeyVault.unwrapWithPin("654321")
        XCTAssertEqual(again, swk)
    }

    // MARK: - Wipe

    func testWipeRemovesBothV1AndV2() throws {
        _ = try SecureKeyVault.provision(pin: "123456")
        let legacyBlob = try makeLegacyPinWrappedBlob(
            swk: Data(repeating: 0x01, count: 32),
            pin: "999999"
        )
        try KeychainManager.shared.storeSecure(key: v1Key, data: legacyBlob)

        XCTAssertTrue(SecureKeyVault.hasPinWrapped)
        SecureKeyVault.wipe()

        XCTAssertFalse(SecureKeyVault.hasPinWrapped)
        XCTAssertNil(try KeychainManager.shared.retrieve(key: v2Key))
        XCTAssertNil(try KeychainManager.shared.retrieve(key: v1Key))
    }

    // MARK: - Fixture helper

    /// Builds a byte-for-byte compatible v1 PIN-wrapped blob using 100k PBKDF2.
    /// Mirrors the private `storePinWrapped` but with the legacy iteration
    /// count, so we can prove that `unwrapWithPin` migrates v1 blobs produced
    /// by the shipped v1 code.
    private func makeLegacyPinWrappedBlob(swk: Data, pin: String) throws -> Data {
        let saltSize = 16
        var saltBytes = [UInt8](repeating: 0, count: saltSize)
        _ = SecRandomCopyBytes(kSecRandomDefault, saltBytes.count, &saltBytes)
        let salt = Data(saltBytes)

        let wrapKey = try LegacyPBKDF2.derive(
            pin: pin,
            salt: salt,
            iterations: 100_000,
            length: 32
        )
        let symmetric = CryptoKitSymmetricKey(data: wrapKey)
        let box = try AESGCMSeal.seal(swk, using: symmetric)
        return salt + box
    }
}

// MARK: - Local crypto helpers (mirror SecureKeyVault internals for fixture gen)

import CryptoKit
import CommonCrypto

/// Type aliases keep the fixture helper readable without polluting the global
/// namespace with `import AES.GCM` style imports.
private typealias CryptoKitSymmetricKey = SymmetricKey

private enum AESGCMSeal {
    static func seal(_ plaintext: Data, using key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let combined = box.combined else {
            throw NSError(domain: "HorcruxTests.AESGCMSeal", code: -1)
        }
        return combined
    }
}

private enum LegacyPBKDF2 {
    static func derive(pin: String, salt: Data, iterations: UInt32, length: Int) throws -> Data {
        let pinData = Data(pin.utf8)
        var out = Data(count: length)
        let status = out.withUnsafeMutableBytes { outBuf -> Int32 in
            pinData.withUnsafeBytes { pinBuf -> Int32 in
                salt.withUnsafeBytes { saltBuf -> Int32 in
                    guard let outBase = outBuf.baseAddress,
                          let pinBase = pinBuf.baseAddress,
                          let saltBase = saltBuf.baseAddress else {
                        return Int32(errSecAllocate)
                    }
                    return Int32(CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pinBase.assumingMemoryBound(to: Int8.self),
                        pinData.count,
                        saltBase.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        outBase.assumingMemoryBound(to: UInt8.self),
                        length
                    ))
                }
            }
        }
        if status != kCCSuccess {
            throw NSError(domain: "HorcruxTests.LegacyPBKDF2", code: Int(status))
        }
        return out
    }
}
