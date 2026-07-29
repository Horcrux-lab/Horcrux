import XCTest
@testable import Horcrux

/// Tests for CertificatePinner — SPKI pinning, TOFU, and pin validation.
final class CertificatePinnerTests: XCTestCase {

    // MARK: - testRegisterKnownPinsPopulatesHashes

    func testRegisterKnownPinsPopulatesHashes() {
        let pinner = CertificatePinner.shared

        // After init, known hosts should have pins registered.
        XCTAssertTrue(pinner.hasPins(for: "ethereum-rpc.publicnode.com"),
                       "PublicNode (default Ethereum RPC) should have pinned hashes after init")
        XCTAssertTrue(pinner.hasPins(for: "blockstream.info"),
                       "Blockstream should have pinned hashes after init")
        XCTAssertTrue(pinner.hasPins(for: "api.mainnet-beta.solana.com"),
                       "Solana mainnet should have pinned hashes after init")
    }

    // MARK: - testSPKIHashExtraction

    func testSPKIHashExtraction() {
        // Create a self-signed certificate via Security framework.
        guard let (_, cert) = Self.makeSelfSignedCert() else {
            XCTFail("Could not create a self-signed certificate for testing")
            return
        }

        let hash = CertificatePinner.shared.spkiHash(of: cert)
        XCTAssertNotNil(hash, "spkiHash should return a non-nil value for a valid certificate")

        if let hash {
            // Base64-encoded SHA-256 is always 44 characters.
            XCTAssertEqual(hash.count, 44,
                           "Base64-encoded SHA-256 hash should be 44 characters, got \(hash.count)")
            // Should only contain valid base64 characters.
            let base64Chars = CharacterSet(charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
            XCTAssertTrue(hash.unicodeScalars.allSatisfy { base64Chars.contains($0) },
                          "Hash should be valid base64")
        }
    }

    // MARK: - testPinValidationRejectsUnknownHost

    func testPinValidationRejectsUnknownHash() {
        let pinner = CertificatePinner.shared

        // ethereum-rpc.publicnode.com has known pins. Build a SecTrust with our
        // self-signed cert whose SPKI hash won't match the registered pins.
        guard let (_, cert) = Self.makeSelfSignedCert(),
              let trust = Self.makeTrust(certificate: cert, host: "ethereum-rpc.publicnode.com") else {
            XCTFail("Could not create test certificate / trust")
            return
        }

        let result = pinner.validate(serverTrust: trust, host: "ethereum-rpc.publicnode.com")
        XCTAssertFalse(result,
                       "Validation should reject a certificate whose SPKI hash doesn't match known pins")
    }

    // MARK: - testTOFUAcceptsFirstConnection

    func testTOFUAcceptsFirstConnection() {
        let pinner = CertificatePinner.shared
        let tofuHost = "tofu-test-\(UUID().uuidString).example.com"

        // No pins should exist for a brand-new host.
        XCTAssertFalse(pinner.hasPins(for: tofuHost),
                       "New host should have no pins before first connection")

        guard let (_, cert) = Self.makeSelfSignedCert(),
              let trust = Self.makeTrust(certificate: cert, host: tofuHost) else {
            XCTFail("Could not create test certificate / trust")
            return
        }

        let result = pinner.validate(serverTrust: trust, host: tofuHost)
        XCTAssertTrue(result, "TOFU should accept the first connection for an unknown host")

        // After TOFU, pins should now exist.
        XCTAssertTrue(pinner.hasPins(for: tofuHost),
                      "Pins should be stored after TOFU acceptance")

        // Clean up so we don't pollute the singleton between test runs.
        pinner.removePins(for: tofuHost)
    }

    // MARK: - testPinValidationAcceptsMatchingHash

    func testPinValidationAcceptsMatchingHash() {
        let pinner = CertificatePinner.shared
        let testHost = "matching-pin-\(UUID().uuidString).example.com"

        guard let (_, cert) = Self.makeSelfSignedCert(),
              let hash = pinner.spkiHash(of: cert) else {
            XCTFail("Could not create test certificate or extract hash")
            return
        }

        // Pre-register the hash for our test host.
        pinner.addPin(host: testHost, spkiHashBase64: hash)
        XCTAssertTrue(pinner.hasPins(for: testHost))

        guard let trust = Self.makeTrust(certificate: cert, host: testHost) else {
            XCTFail("Could not create SecTrust")
            return
        }

        let result = pinner.validate(serverTrust: trust, host: testHost)
        XCTAssertTrue(result, "Validation should accept a certificate whose SPKI hash matches a registered pin")

        // Clean up.
        pinner.removePins(for: testHost)
    }

    // MARK: - Helpers

    /// Create a self-signed EC P-256 identity (SecKey + SecCertificate) entirely
    /// in software. Works on simulator and device.
    private static func makeSelfSignedCert() -> (SecKey, SecCertificate)? {
        // Generate an EC P-256 key pair in software (not SE).
        let keyAttrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(keyAttrs as CFDictionary, &error) else {
            return nil
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else { return nil }

        // Build a minimal self-signed X.509 v1 certificate using the DER bytes.
        // We use SecCertificateCreateWithData with a hand-crafted DER blob.
        guard let certData = selfSignedDER(privateKey: privateKey, publicKey: publicKey) else {
            return nil
        }
        guard let cert = SecCertificateCreateWithData(nil, certData as CFData) else {
            return nil
        }
        return (privateKey, cert)
    }

    /// Build a minimal self-signed X.509 DER certificate.
    private static func selfSignedDER(privateKey: SecKey, publicKey: SecKey) -> Data? {
        guard let pubData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            return nil
        }

        // TBS (To-Be-Signed) certificate structure (simplified X.509 v1)
        var tbs = Data()

        // Version: v1 (default, omitted for v1)
        // Serial number
        let serial: [UInt8] = [0x02, 0x01, 0x01] // INTEGER 1
        tbs.append(contentsOf: serial)

        // Signature algorithm: ecdsaWithSHA256
        let sigAlg: [UInt8] = [
            0x30, 0x0A, 0x06, 0x08,
            0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02
        ]
        tbs.append(contentsOf: sigAlg)

        // Issuer: CN=Test
        let issuer: [UInt8] = [
            0x30, 0x0F, 0x31, 0x0D, 0x30, 0x0B,
            0x06, 0x03, 0x55, 0x04, 0x03,
            0x0C, 0x04, 0x54, 0x65, 0x73, 0x74 // "Test"
        ]
        tbs.append(contentsOf: issuer)

        // Validity: not-before / not-after (UTCTime)
        let validity: [UInt8] = [
            0x30, 0x1E,
            0x17, 0x0D, 0x32, 0x34, 0x30, 0x31, 0x30, 0x31, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x5A, // 240101000000Z
            0x17, 0x0D, 0x33, 0x34, 0x30, 0x31, 0x30, 0x31, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x5A  // 340101000000Z
        ]
        tbs.append(contentsOf: validity)

        // Subject: same as issuer
        tbs.append(contentsOf: issuer)

        // SubjectPublicKeyInfo for EC P-256
        let spkiHeader: [UInt8] = [
            0x30, 0x59,
            0x30, 0x13,
            0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
            0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07,
            0x03, 0x42, 0x00
        ]
        tbs.append(contentsOf: spkiHeader)
        tbs.append(pubData)

        // Wrap TBS in a SEQUENCE
        let tbsSequence = wrapSequence(tbs)

        // Sign the TBS
        var signError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            tbsSequence as CFData,
            &signError
        ) as Data? else {
            return nil
        }

        // Build the full certificate: SEQUENCE { tbsCert, sigAlg, signature }
        var certBody = Data()
        certBody.append(tbsSequence)
        certBody.append(contentsOf: sigAlg)

        // Signature as BIT STRING
        var bitString = Data([0x03, UInt8(signature.count + 1), 0x00])
        bitString.append(signature)
        certBody.append(bitString)

        return wrapSequence(certBody)
    }

    private static func wrapSequence(_ data: Data) -> Data {
        var result = Data()
        result.append(0x30) // SEQUENCE tag
        let length = data.count
        if length < 128 {
            result.append(UInt8(length))
        } else if length < 256 {
            result.append(0x81)
            result.append(UInt8(length))
        } else {
            result.append(0x82)
            result.append(UInt8((length >> 8) & 0xFF))
            result.append(UInt8(length & 0xFF))
        }
        result.append(data)
        return result
    }

    /// Create a SecTrust from a certificate for a given host.
    private static func makeTrust(certificate: SecCertificate, host: String) -> SecTrust? {
        let policy = SecPolicyCreateSSL(true, host as CFString)
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(certificate, policy, &trust)
        guard status == errSecSuccess else { return nil }
        return trust
    }
}
