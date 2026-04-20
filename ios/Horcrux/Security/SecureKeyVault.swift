import Foundation
import Security
import CryptoKit
import CommonCrypto

/// Manages the **Shard Wrap Key (SWK)** — a random 256-bit key that all
/// shard ciphertexts are encrypted under.
///
/// ## Why this exists
/// Previously shards were encrypted directly with a key derived from the
/// user's PIN. That meant:
///   1. Every signing operation required re-entering the PIN (UX).
///   2. Changing the PIN required decrypting and re-encrypting every shard
///      (risky data-migration every time).
///   3. Biometric unlock could not release the shard key material at all.
///
/// ## Architecture
/// ```
///                     ┌────────────────┐
///     Face ID ──────▶ │  SE-sealed SWK │ ─┐
///                     └────────────────┘  │
///                                         ▼
///                                  ┌─────────────┐
///                                  │ SWK (32 B)  │ ──▶ encrypt/decrypt shards
///                                  └─────────────┘
///                                         ▲
///                     ┌────────────────┐  │
///     PIN ──PBKDF2──▶ │  PIN-wrapped SWK│─┘
///                     └────────────────┘
/// ```
///
/// Both wraps live in the Keychain and point to the **same** SWK. Unwrapping
/// via either path yields identical key material, so shards survive a PIN
/// change (only the PIN wrap is rewritten).
///
/// Storage formats:
/// * PIN-wrapped: `salt(16) || AES-GCM.combined(nonce 12 || ciphertext || tag 16)`
/// * SE-sealed: opaque blob produced by `SecureEnclaveManager.seal(_:)`
enum SecureKeyVault {

    // MARK: Keychain keys

    static let keychainPinWrapped = "com.horcrux.swk.pin.v1"
    static let keychainSESealed   = "com.horcrux.swk.se.v1"

    // MARK: PBKDF2 params (must match across wrap / unwrap)

    private static let pbkdf2Iterations: UInt32 = 100_000
    private static let saltSize = 16

    // MARK: - State

    /// Whether the PIN-wrapped SWK exists. Used to decide between first-time
    /// provisioning (onboarding) and existing-install unlock.
    static var hasPinWrapped: Bool {
        (try? KeychainManager.shared.retrieve(key: keychainPinWrapped)) != nil
    }

    /// Whether the biometric-sealed SWK exists.
    static var hasSESealed: Bool {
        (try? KeychainManager.shared.retrieve(key: keychainSESealed)) != nil
    }

    // MARK: - Provision

    /// Create a fresh random SWK and persist both wraps.
    /// Used by onboarding (first PIN set) and by the legacy-install migration path.
    @discardableResult
    static func provision(pin: String) throws -> Data {
        var swk = Data(count: 32)
        let status = swk.withUnsafeMutableBytes { buf -> Int32 in
            guard let base = buf.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, buf.count, base)
        }
        guard status == errSecSuccess else {
            throw VaultError.randomFailed
        }
        try storePinWrapped(swk: swk, pin: pin)
        if SecureEnclaveManager.shared.isAvailable {
            try? storeSealed(swk: swk) // non-fatal; PIN wrap is enough
        }
        return swk
    }

    // MARK: - Unwrap

    /// Unwrap the SWK using a plaintext PIN. Caller must have already
    /// validated the PIN via `AppState.verifyPin` — this routine does NOT
    /// rate-limit incorrect PINs on its own.
    static func unwrapWithPin(_ pin: String) throws -> Data {
        guard let blob = try KeychainManager.shared.retrieve(key: keychainPinWrapped),
              blob.count > saltSize else {
            throw VaultError.notProvisioned
        }
        let salt = blob.prefix(saltSize)
        let sealedData = blob.dropFirst(saltSize)
        let wrapKey = try deriveWrapKey(pin: pin, salt: Data(salt))
        defer {
            var k = wrapKey
            k.withUnsafeMutableBytes { buf in
                if let base = buf.baseAddress {
                    memset_s(base, buf.count, 0, buf.count)
                }
            }
        }
        let box = try AES.GCM.SealedBox(combined: sealedData)
        return try AES.GCM.open(box, using: SymmetricKey(data: wrapKey))
    }

    /// Unwrap the SWK via Secure Enclave (triggers Face ID / Touch ID).
    static func unwrapWithBiometric() throws -> Data {
        guard let sealed = try KeychainManager.shared.retrieve(key: keychainSESealed) else {
            throw VaultError.biometricUnavailable
        }
        return try SecureEnclaveManager.shared.open(sealed)
    }

    // MARK: - Rewrap

    /// Replace the PIN-wrapped copy (e.g. after PIN change). SE-sealed copy
    /// is untouched — the SWK itself does not change.
    static func rewrapPinWrapped(swk: Data, newPin: String) throws {
        try storePinWrapped(swk: swk, pin: newPin)
    }

    /// Ensure an SE-sealed copy exists. No-op if it already does or SE is
    /// unavailable. Call after unlock on devices that didn't previously have
    /// one (e.g. biometry set up after initial onboarding).
    static func ensureSealed(swk: Data) {
        guard SecureEnclaveManager.shared.isAvailable else { return }
        guard !hasSESealed else { return }
        try? storeSealed(swk: swk)
    }

    /// Create the SE-sealed backup copy right now, surfacing any error.
    /// Used by the Security detail "Enable now" CTA when the silent
    /// `ensureSealed` path failed on earlier unlocks (e.g. biometric was
    /// enrolled after onboarding, or SE sealing threw on a prior attempt).
    /// No-op if the sealed copy already exists.
    static func sealBackupNow(swk: Data) throws {
        #if targetEnvironment(simulator)
        throw VaultError.simulatorUnsupported
        #else
        guard SecureEnclaveManager.shared.isAvailable else {
            throw VaultError.biometricUnavailable
        }
        if hasSESealed { return }
        try storeSealed(swk: swk)
        #endif
    }

    // MARK: - Teardown

    /// Delete both wraps. Called from `wipeAllData()`.
    static func wipe() {
        try? KeychainManager.shared.delete(key: keychainPinWrapped)
        try? KeychainManager.shared.delete(key: keychainSESealed)
    }

    // MARK: - Private helpers

    private static func storePinWrapped(swk: Data, pin: String) throws {
        var saltBytes = [UInt8](repeating: 0, count: saltSize)
        guard SecRandomCopyBytes(kSecRandomDefault, saltBytes.count, &saltBytes) == errSecSuccess else {
            throw VaultError.randomFailed
        }
        let salt = Data(saltBytes)
        let wrapKey = try deriveWrapKey(pin: pin, salt: salt)
        defer {
            var k = wrapKey
            k.withUnsafeMutableBytes { buf in
                if let base = buf.baseAddress {
                    memset_s(base, buf.count, 0, buf.count)
                }
            }
        }
        let box = try AES.GCM.seal(swk, using: SymmetricKey(data: wrapKey))
        guard let combined = box.combined else { throw VaultError.wrapFailed }
        let blob = salt + combined
        try KeychainManager.shared.storeSecure(key: keychainPinWrapped, data: blob)
    }

    private static func storeSealed(swk: Data) throws {
        let sealed = try SecureEnclaveManager.shared.seal(swk)
        try KeychainManager.shared.storeSecure(key: keychainSESealed, data: sealed)
    }

    private static func deriveWrapKey(pin: String, salt: Data) throws -> Data {
        let pinData = Data(pin.utf8)
        var out = Data(count: 32)
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
                        pbkdf2Iterations,
                        outBase.assumingMemoryBound(to: UInt8.self),
                        32
                    ))
                }
            }
        }
        guard status == kCCSuccess else { throw VaultError.deriveFailed }
        return out
    }

    enum VaultError: LocalizedError {
        case notProvisioned
        case randomFailed
        case deriveFailed
        case wrapFailed
        case biometricUnavailable
        case simulatorUnsupported

        var errorDescription: String? {
            switch self {
            case .notProvisioned:       return "SWK vault not provisioned"
            case .randomFailed:         return "Failed to generate random key"
            case .deriveFailed:         return "PBKDF2 key derivation failed"
            case .wrapFailed:           return "AES-GCM wrap failed"
            case .biometricUnavailable: return "Secure Enclave not available on this device"
            case .simulatorUnsupported: return "iOS Simulator does not support Secure Enclave biometric sealing. Build to a real device to test biometric backup."
            }
        }
    }
}
