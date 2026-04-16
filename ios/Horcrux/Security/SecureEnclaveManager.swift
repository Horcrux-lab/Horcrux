import Foundation
import Security
import LocalAuthentication
import CryptoKit

/// Manages a Secure Enclave–backed P-256 key for envelope encryption of the device key.
///
/// Architecture:
/// ```
///   Secure Enclave (P-256 private key, non-exportable)
///          │
///          ├─ ECDH shared secret with ephemeral key
///          │         │
///          │         └─ HKDF-SHA256 → AES-256 wrapping key
///          │                   │
///          │                   └─ AES-GCM encrypt(device_key) → sealed blob
///          │
///          └─ Biometric required to use private key
/// ```
///
/// The SE private key **never leaves the chip**. Even if Keychain is dumped,
/// the sealed device key cannot be decrypted without biometric + SE hardware.
final class SecureEnclaveManager {
    static let shared = SecureEnclaveManager()
    private init() {}

    private let keyTag = "com.horcrux.se.devicekey.v1"

    /// Whether the current device supports Secure Enclave.
    var isAvailable: Bool {
        SecureEnclave.isAvailable
    }

    // MARK: - Key Lifecycle

    /// Get or create the SE-backed P-256 private key.
    /// The key requires biometric authentication for every use.
    func getOrCreateKey() throws -> SecKey {
        if let existing = try? loadKey() {
            return existing
        }
        return try generateKey()
    }

    /// Generate a new SE-backed P-256 key with biometric protection.
    private func generateKey() throws -> SecKey {
        let access = try makeAccessControl()

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: Data(keyTag.utf8),
                kSecAttrAccessControl as String: access
            ] as [String: Any]
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let err = error?.takeRetainedValue()
            throw SecureEnclaveError.keyGenerationFailed(err?.localizedDescription ?? "Unknown error")
        }
        return privateKey
    }

    /// Load the existing SE key from Keychain.
    private func loadKey() throws -> SecKey? {
        let context = LAContext()
        context.localizedReason = "Authenticate to access your key shard"
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrApplicationTag as String: Data(keyTag.utf8),
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecReturnRef as String: true,
            kSecUseAuthenticationContext as String: context
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        context.invalidate()

        switch status {
        case errSecSuccess:
            guard let key = item as? SecKey else {
                throw SecureEnclaveError.keyLoadFailed(errSecInternalError)
            }
            return key
        case errSecItemNotFound:
            return nil
        default:
            throw SecureEnclaveError.keyLoadFailed(status)
        }
    }

    /// Delete the SE key (used during wipe).
    func deleteKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(keyTag.utf8),
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Envelope Encryption (ECIES-like)

    /// Seal (encrypt) data using the SE key.
    /// Uses ECIES: ephemeral ECDH → HKDF → AES-GCM.
    /// Returns: ephemeral public key (65 bytes) || nonce (12 bytes) || ciphertext+tag
    func seal(_ plaintext: Data) throws -> Data {
        let seKey = try getOrCreateKey()
        guard let sePubKey = SecKeyCopyPublicKey(seKey) else {
            throw SecureEnclaveError.publicKeyUnavailable
        }

        // Generate ephemeral P-256 key pair (software, not SE)
        let ephemeralKey = P256.KeyAgreement.PrivateKey()
        let ephemeralPubData = ephemeralKey.publicKey.x963Representation // 65 bytes

        // Convert SE public key to CryptoKit format
        guard let sePubData = SecKeyCopyExternalRepresentation(sePubKey, nil) as Data? else {
            throw SecureEnclaveError.publicKeyUnavailable
        }
        let seCryptoKitPub = try P256.KeyAgreement.PublicKey(x963Representation: sePubData)

        // ECDH: ephemeral private × SE public → shared secret
        let sharedSecret = try ephemeralKey.sharedSecretFromKeyAgreement(with: seCryptoKitPub)

        // HKDF → AES-256 symmetric key
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("horcrux-se-envelope-v1".utf8),
            sharedInfo: ephemeralPubData,
            outputByteCount: 32
        )

        // AES-GCM encrypt
        let sealedBox = try AES.GCM.seal(plaintext, using: symmetricKey)
        guard let combined = sealedBox.combined else { // nonce (12) || ciphertext || tag (16)
            throw SecureEnclaveError.sealFailed
        }

        // Output: ephemeralPub (65) || combined
        return ephemeralPubData + combined
    }

    /// Open (decrypt) data sealed with `seal()`.
    /// Triggers biometric prompt because SE private key is used for ECDH.
    func open(_ sealed: Data, context: LAContext? = nil) throws -> Data {
        guard sealed.count > 65 + 12 + 16 else {
            throw SecureEnclaveError.invalidSealedData
        }

        let ephemeralPubData = Data(sealed.prefix(65))
        let combined = Data(sealed.dropFirst(65))

        // Load SE private key (will trigger biometric)
        let seKey = try loadKeyWithContext(context)

        // Reconstruct ephemeral public key as a SecKey
        let ephAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 256
        ]
        var secKeyError: Unmanaged<CFError>?
        guard let ephemeralSecKey = SecKeyCreateWithData(
            ephemeralPubData as CFData,
            ephAttributes as CFDictionary,
            &secKeyError
        ) else {
            let err = secKeyError?.takeRetainedValue()
            throw SecureEnclaveError.decryptionFailed(err?.localizedDescription ?? "Failed to import ephemeral key")
        }

        // ECDH: SE private × ephemeral public → shared secret
        let params: [String: Any] = [:]
        var ecdhError: Unmanaged<CFError>?
        guard let sharedSecretData = SecKeyCopyKeyExchangeResult(
            seKey,
            .ecdhKeyExchangeStandard,
            ephemeralSecKey,
            params as CFDictionary,
            &ecdhError
        ) as Data? else {
            let err = ecdhError?.takeRetainedValue()
            throw SecureEnclaveError.decryptionFailed(err?.localizedDescription ?? "ECDH failed")
        }

        // Reconstruct the same symmetric key via HKDF
        let symmetricKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedSecretData),
            salt: Data("horcrux-se-envelope-v1".utf8),
            info: ephemeralPubData,
            outputByteCount: 32
        )

        // AES-GCM decrypt
        let sealedBox = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(sealedBox, using: symmetricKey)
    }

    // MARK: - Private Helpers

    private func loadKeyWithContext(_ context: LAContext?) throws -> SecKey {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrApplicationTag as String: Data(keyTag.utf8),
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecReturnRef as String: true
        ]
        if let context {
            query[kSecUseAuthenticationContext as String] = context
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let key = item as? SecKey else {
            throw SecureEnclaveError.keyLoadFailed(status)
        }
        return key
    }

    private func makeAccessControl() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            [.privateKeyUsage, .biometryCurrentSet],
            &error
        ) else {
            let err = error?.takeRetainedValue()
            throw SecureEnclaveError.accessControlFailed(err?.localizedDescription ?? "Unknown")
        }
        return access
    }
}

// MARK: - Errors

enum SecureEnclaveError: LocalizedError {
    case notAvailable
    case keyGenerationFailed(String)
    case keyLoadFailed(OSStatus)
    case publicKeyUnavailable
    case invalidSealedData
    case sealFailed
    case decryptionFailed(String)
    case accessControlFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAvailable: return "Secure Enclave not available on this device"
        case .keyGenerationFailed(let m): return "SE key generation failed: \(m)"
        case .keyLoadFailed(let s): return "SE key load failed: \(s)"
        case .publicKeyUnavailable: return "SE public key unavailable"
        case .invalidSealedData: return "Invalid sealed data format"
        case .sealFailed: return "AES-GCM seal produced no combined output"
        case .decryptionFailed(let m): return "SE decryption failed: \(m)"
        case .accessControlFailed(let m): return "SE access control failed: \(m)"
        }
    }
}
