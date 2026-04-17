import Foundation
import CryptoKit
import CommonCrypto

/// Portable, password-protected envelope for off-device shard backups.
///
/// The device-level encryption (`HorcruxBridge.encryptShard`) binds the
/// ciphertext to *this* device's random `deviceKey` + `SWK`, which means
/// those ciphertexts cannot be decrypted on another device. For a shard
/// to be usable as a **backup**, the exported file has to be re-encrypted
/// with a key the user can reproduce on any device — typically from a
/// password they remember.
///
/// Wire format (JSON inside the `encryptedShard` field of the backup):
/// ```
/// {
///   "v": 1,
///   "kdf": "pbkdf2-hmac-sha256",
///   "iter": 600000,
///   "salt": "<base64 16B>",
///   "nonce": "<base64 12B>",
///   "ct": "<base64 ciphertext || tag>"
/// }
/// ```
///
/// Key derivation: PBKDF2-HMAC-SHA256 with a random 16-byte salt and
/// 600 000 iterations, yielding a 32-byte AES-256 key. Encryption is
/// AES-GCM with a random 12-byte nonce; the 16-byte tag is appended to
/// the ciphertext (the standard CryptoKit combined representation).
enum PortableBackupCrypto {

    private static let version = 1
    private static let iterations: UInt32 = 600_000
    private static let saltSize = 16
    private static let keySize = 32

    enum Error: LocalizedError {
        case unsupportedVersion(Int)
        case malformed(String)
        case decryptFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let v): return "不支持的备份版本 v\(v)"
            case .malformed(let m): return "备份文件已损坏：\(m)"
            case .decryptFailed: return "密码错误或备份已损坏"
            }
        }
    }

    /// Encrypt `plaintext` with a password. Returns the encoded JSON
    /// envelope bytes, suitable for writing into the `encryptedShard`
    /// field of an `AccountBackup`.
    static func encrypt(plaintext: Data, password: String) throws -> Data {
        var saltBytes = [UInt8](repeating: 0, count: saltSize)
        let status = SecRandomCopyBytes(kSecRandomDefault, saltBytes.count, &saltBytes)
        guard status == errSecSuccess else {
            throw Error.malformed("salt generation failed")
        }
        let salt = Data(saltBytes)

        let key = try deriveKey(password: password, salt: salt)
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)

        // CryptoKit's `combined` = nonce || ciphertext || tag. We store the
        // nonce separately (it's a fixed 12 bytes) and the ciphertext||tag
        // as `ct` so on-disk format matches the schema doc above.
        guard let combined = sealed.combined else {
            throw Error.malformed("seal produced no combined output")
        }
        let nonceBytes = combined.prefix(12)
        let ctAndTag = combined.dropFirst(12)

        let envelope = Envelope(
            v: version,
            kdf: "pbkdf2-hmac-sha256",
            iter: Int(iterations),
            salt: salt.base64EncodedString(),
            nonce: Data(nonceBytes).base64EncodedString(),
            ct: Data(ctAndTag).base64EncodedString()
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try enc.encode(envelope)
    }

    /// Decrypt a portable envelope previously produced by `encrypt`.
    /// Throws `Error.decryptFailed` on wrong password or tampering.
    static func decrypt(envelope data: Data, password: String) throws -> Data {
        let dec = JSONDecoder()
        let env: Envelope
        do {
            env = try dec.decode(Envelope.self, from: data)
        } catch {
            throw Error.malformed("envelope JSON invalid")
        }
        guard env.v == version else {
            throw Error.unsupportedVersion(env.v)
        }
        guard let salt = Data(base64Encoded: env.salt),
              let nonceData = Data(base64Encoded: env.nonce),
              let ct = Data(base64Encoded: env.ct) else {
            throw Error.malformed("base64 field invalid")
        }
        guard nonceData.count == 12, salt.count == saltSize else {
            throw Error.malformed("field sizes invalid")
        }

        let key = try deriveKey(password: password, salt: salt, iterations: UInt32(env.iter))
        let nonce = try AES.GCM.Nonce(data: nonceData)

        // Rebuild the combined form CryptoKit expects on open.
        var combined = Data(capacity: nonceData.count + ct.count)
        combined.append(nonceData)
        combined.append(ct)

        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw Error.decryptFailed
        }
    }

    /// True when `data` parses as an envelope (by peeking at JSON keys).
    /// Used by the import path to distinguish v3+ encrypted backups from
    /// pre-encryption v3 backups that shipped the shard in plaintext.
    static func isEnvelope(_ data: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return obj["v"] != nil && obj["kdf"] != nil && obj["ct"] != nil
    }

    private static func deriveKey(
        password: String,
        salt: Data,
        iterations: UInt32 = iterations
    ) throws -> SymmetricKey {
        let passwordData = Data(password.utf8)
        var derived = Data(count: keySize)
        let result: Int32 = derived.withUnsafeMutableBytes { outBuf in
            passwordData.withUnsafeBytes { passBuf in
                salt.withUnsafeBytes { saltBuf in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passBuf.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordData.count,
                        saltBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        outBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        keySize
                    )
                }
            }
        }
        guard result == kCCSuccess else {
            throw Error.malformed("PBKDF2 failed")
        }
        return SymmetricKey(data: derived)
    }

    private struct Envelope: Codable {
        let v: Int
        let kdf: String
        let iter: Int
        let salt: String
        let nonce: String
        let ct: String
    }
}
