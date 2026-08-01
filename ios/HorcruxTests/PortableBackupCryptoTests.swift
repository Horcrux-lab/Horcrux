import XCTest
import CryptoKit
@testable import Horcrux

/// Tests for `PortableBackupCrypto`, the envelope format used for off-device
/// shard backups.
///
/// This file exists because the type had **zero** test references while sitting
/// on the wallet-recovery path: `ShardsViewModel.importBackup(from:)` hands it
/// bytes that came out of a file the user picked, so every field in the
/// envelope is attacker-controlled. A backup that cannot be decrypted, or a
/// crash on import, is indistinguishable from lost funds to the person holding
/// the file.
///
/// The envelope is JSON, so the malformed-input cases are built by encrypting
/// something real and then editing one field. That keeps them honest: the
/// tampered envelopes differ from a valid one in exactly the way named by the
/// test, and nothing else.
final class PortableBackupCryptoTests: XCTestCase {

    private let plaintext = Data("shard-material-not-really-secret".utf8)
    private let password = "123456"

    /// A valid v1 (PBKDF2/PIN) envelope decoded to a mutable dictionary.
    private func passwordEnvelopeObject() throws -> [String: Any] {
        let data = try PortableBackupCrypto.encrypt(plaintext: plaintext, password: password)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw XCTSkip("envelope was not a JSON object")
        }
        return obj
    }

    private func encode(_ obj: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }

    // MARK: - Round trips

    func testPasswordRoundTripRecoversThePlaintext() throws {
        let envelope = try PortableBackupCrypto.encrypt(plaintext: plaintext, password: password)
        let recovered = try PortableBackupCrypto.decrypt(envelope: envelope, password: password)
        XCTAssertEqual(recovered, plaintext)
    }

    func testRecoveryKeyRoundTripRecoversThePlaintext() throws {
        let rk = SymmetricKey(size: .bits256)
        let envelope = try PortableBackupCrypto.encrypt(plaintext: plaintext, recoveryKey: rk)
        let recovered = try PortableBackupCrypto.decrypt(envelope: envelope, recoveryKey: rk)
        XCTAssertEqual(recovered, plaintext)
    }

    func testTwoExportsOfTheSameShardDiffer() throws {
        let a = try PortableBackupCrypto.encrypt(plaintext: plaintext, password: password)
        let b = try PortableBackupCrypto.encrypt(plaintext: plaintext, password: password)
        XCTAssertNotEqual(a, b, "a fixed salt or nonce would make exports comparable")
    }

    // MARK: - Wrong key

    func testWrongPasswordFailsToDecrypt() throws {
        let envelope = try PortableBackupCrypto.encrypt(plaintext: plaintext, password: password)
        XCTAssertThrowsError(try PortableBackupCrypto.decrypt(envelope: envelope, password: "654321")) {
            guard case PortableBackupCrypto.Error.decryptFailed = $0 else {
                return XCTFail("expected .decryptFailed, got \($0)")
            }
        }
    }

    func testWrongRecoveryKeyFailsToDecrypt() throws {
        let envelope = try PortableBackupCrypto.encrypt(
            plaintext: plaintext,
            recoveryKey: SymmetricKey(size: .bits256)
        )
        XCTAssertThrowsError(
            try PortableBackupCrypto.decrypt(envelope: envelope, recoveryKey: SymmetricKey(size: .bits256))
        ) {
            guard case PortableBackupCrypto.Error.decryptFailed = $0 else {
                return XCTFail("expected .decryptFailed, got \($0)")
            }
        }
    }

    func testPasswordEnvelopeIsNotOpenedByTheRecoveryKeyPath() throws {
        let envelope = try PortableBackupCrypto.encrypt(plaintext: plaintext, password: password)
        XCTAssertThrowsError(
            try PortableBackupCrypto.decrypt(envelope: envelope, recoveryKey: SymmetricKey(size: .bits256))
        ) {
            guard case PortableBackupCrypto.Error.decryptFailed = $0 else {
                return XCTFail("expected .decryptFailed, got \($0)")
            }
        }
    }

    // MARK: - Attacker-controlled iteration count

    // `iter` is read straight out of the file. `UInt32(env.iter ?? ...)` traps
    // on a negative value, and a trap is not a Swift error — the `do/catch` in
    // ShardsViewModel cannot see it, so importing a one-line-edited backup
    // terminates the process.
    func testNegativeIterationCountIsRejectedInsteadOfTrapping() throws {
        var obj = try passwordEnvelopeObject()
        obj["iter"] = -1
        XCTAssertThrowsError(try PortableBackupCrypto.decrypt(envelope: try encode(obj), password: password)) {
            guard case PortableBackupCrypto.Error.malformed = $0 else {
                return XCTFail("expected .malformed, got \($0)")
            }
        }
    }

    // Still a legal UInt32, so no trap — it just runs PBKDF2 two billion times
    // on the main thread. The wallet is wedged rather than killed.
    func testAbsurdIterationCountIsRejectedRatherThanRun() throws {
        var obj = try passwordEnvelopeObject()
        obj["iter"] = 2_000_000_000
        XCTAssertThrowsError(try PortableBackupCrypto.decrypt(envelope: try encode(obj), password: password)) {
            guard case PortableBackupCrypto.Error.malformed = $0 else {
                return XCTFail("expected .malformed, got \($0)")
            }
        }
    }

    func testZeroIterationCountIsRejected() throws {
        var obj = try passwordEnvelopeObject()
        obj["iter"] = 0
        XCTAssertThrowsError(try PortableBackupCrypto.decrypt(envelope: try encode(obj), password: password)) {
            guard case PortableBackupCrypto.Error.malformed = $0 else {
                return XCTFail("expected .malformed, got \($0)")
            }
        }
    }

    // The shipped iteration count has to keep working, or this fix would make
    // every existing backup unreadable — a far worse bug than the one above.
    func testShippedIterationCountStillDecrypts() throws {
        let obj = try passwordEnvelopeObject()
        XCTAssertEqual(obj["iter"] as? Int, 600_000, "envelopes are written with the OWASP figure")
        let recovered = try PortableBackupCrypto.decrypt(envelope: try encode(obj), password: password)
        XCTAssertEqual(recovered, plaintext)
    }

    // MARK: - Malformed envelopes

    func testTruncatedCiphertextFailsToDecrypt() throws {
        var obj = try passwordEnvelopeObject()
        let ct = Data(base64Encoded: obj["ct"] as! String)!
        obj["ct"] = ct.dropLast(4).base64EncodedString()
        XCTAssertThrowsError(try PortableBackupCrypto.decrypt(envelope: try encode(obj), password: password))
    }

    func testFlippedCiphertextBitFailsToDecrypt() throws {
        var obj = try passwordEnvelopeObject()
        var ct = Data(base64Encoded: obj["ct"] as! String)!
        ct[0] ^= 0x01
        obj["ct"] = ct.base64EncodedString()
        XCTAssertThrowsError(try PortableBackupCrypto.decrypt(envelope: try encode(obj), password: password)) {
            guard case PortableBackupCrypto.Error.decryptFailed = $0 else {
                return XCTFail("expected .decryptFailed, got \($0)")
            }
        }
    }

    func testShortNonceIsRejected() throws {
        var obj = try passwordEnvelopeObject()
        obj["nonce"] = Data(repeating: 0, count: 8).base64EncodedString()
        XCTAssertThrowsError(try PortableBackupCrypto.decrypt(envelope: try encode(obj), password: password)) {
            guard case PortableBackupCrypto.Error.malformed = $0 else {
                return XCTFail("expected .malformed, got \($0)")
            }
        }
    }

    func testShortSaltIsRejected() throws {
        var obj = try passwordEnvelopeObject()
        obj["salt"] = Data(repeating: 0, count: 4).base64EncodedString()
        XCTAssertThrowsError(try PortableBackupCrypto.decrypt(envelope: try encode(obj), password: password)) {
            guard case PortableBackupCrypto.Error.malformed = $0 else {
                return XCTFail("expected .malformed, got \($0)")
            }
        }
    }

    func testNonBase64FieldIsRejected() throws {
        var obj = try passwordEnvelopeObject()
        obj["salt"] = "not base64 !!!"
        XCTAssertThrowsError(try PortableBackupCrypto.decrypt(envelope: try encode(obj), password: password)) {
            guard case PortableBackupCrypto.Error.malformed = $0 else {
                return XCTFail("expected .malformed, got \($0)")
            }
        }
    }

    func testUnknownVersionIsReportedAsUnsupported() throws {
        var obj = try passwordEnvelopeObject()
        obj["v"] = 99
        XCTAssertThrowsError(try PortableBackupCrypto.decrypt(envelope: try encode(obj), password: password)) {
            guard case PortableBackupCrypto.Error.unsupportedVersion(let v) = $0 else {
                return XCTFail("expected .unsupportedVersion, got \($0)")
            }
            XCTAssertEqual(v, 99)
        }
    }

    func testNonJSONInputIsRejected() {
        XCTAssertThrowsError(
            try PortableBackupCrypto.decrypt(envelope: Data("not json at all".utf8), password: password)
        ) {
            guard case PortableBackupCrypto.Error.malformed = $0 else {
                return XCTFail("expected .malformed, got \($0)")
            }
        }
    }

    // MARK: - Envelope sniffing

    func testEnvelopeVersionReadsWithoutDecrypting() throws {
        let pw = try PortableBackupCrypto.encrypt(plaintext: plaintext, password: password)
        let rk = try PortableBackupCrypto.encrypt(plaintext: plaintext, recoveryKey: SymmetricKey(size: .bits256))
        XCTAssertEqual(PortableBackupCrypto.envelopeVersion(pw), 1)
        XCTAssertEqual(PortableBackupCrypto.envelopeVersion(rk), 2)
        XCTAssertNil(PortableBackupCrypto.envelopeVersion(Data("nope".utf8)))
    }

    func testIsEnvelopeDistinguishesEncryptedFromPlaintextBackups() throws {
        let envelope = try PortableBackupCrypto.encrypt(plaintext: plaintext, password: password)
        XCTAssertTrue(PortableBackupCrypto.isEnvelope(envelope))
        // A pre-encryption v3 backup carried the shard bytes directly.
        XCTAssertFalse(PortableBackupCrypto.isEnvelope(plaintext))
        XCTAssertFalse(PortableBackupCrypto.isEnvelope(Data(#"{"v":1}"#.utf8)))
    }
}
