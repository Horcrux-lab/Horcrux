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

    /// Current-format (v2) PIN-wrapped SWK blob. Uses 600k PBKDF2 iterations
    /// per OWASP 2023 guidance (up from 100k in v1).
    static let keychainPinWrapped = "com.horcrux.swk.pin.v2"

    /// Legacy (v1) PIN-wrapped SWK blob — 100k PBKDF2 iterations. Kept only
    /// for transparent migration when a user returns after the upgrade; we
    /// unwrap with v1 iters, rewrap as v2, and delete v1 in one step.
    static let keychainPinWrappedLegacy = "com.horcrux.swk.pin.v1"

    static let keychainSESealed   = "com.horcrux.swk.se.v1"

    // MARK: PBKDF2 params (must match across wrap / unwrap)

    /// OWASP 2023 recommendation for PBKDF2-HMAC-SHA256.
    /// https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html
    private static let pbkdf2Iterations: UInt32 = 600_000
    /// Iteration count used by pre-upgrade (v1) wrap blobs. Only referenced
    /// by the legacy-unwrap path.
    private static let pbkdf2IterationsLegacy: UInt32 = 100_000
    private static let saltSize = 16

    // MARK: - State

    /// Whether the PIN-wrapped SWK exists. Used to decide between first-time
    /// provisioning (onboarding) and existing-install unlock. Returns true
    /// for both the current v2 format and the legacy v1 format (which is
    /// migrated on first successful unwrap).
    static var hasPinWrapped: Bool {
        (try? KeychainManager.shared.retrieve(key: keychainPinWrapped)) != nil
            || (try? KeychainManager.shared.retrieve(key: keychainPinWrappedLegacy)) != nil
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
    ///
    /// Transparently migrates legacy (v1 / 100k PBKDF2) blobs to v2 (600k)
    /// the first time they're unwrapped after install.
    static func unwrapWithPin(_ pin: String) throws -> Data {
        if let blob = try KeychainManager.shared.retrieve(key: keychainPinWrapped),
           blob.count > saltSize {
            return try decryptPinBlob(blob, pin: pin, iterations: pbkdf2Iterations)
        }

        // Fall back to legacy v1 wrap (100k PBKDF2). If it unwraps cleanly,
        // rewrap as v2 and delete v1 so future unlocks use the stronger KDF.
        guard let legacyBlob = try KeychainManager.shared.retrieve(key: keychainPinWrappedLegacy),
              legacyBlob.count > saltSize else {
            throw VaultError.notProvisioned
        }
        let swk = try decryptPinBlob(legacyBlob, pin: pin, iterations: pbkdf2IterationsLegacy)
        do {
            try storePinWrapped(swk: swk, pin: pin)
            try? KeychainManager.shared.delete(key: keychainPinWrappedLegacy)
        } catch {
            // Migration failed — leave v1 in place so the next unlock retries.
            // The caller still gets a valid SWK.
        }
        return swk
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

    /// Delete both wraps (current and legacy). Called from `wipeAllData()`.
    static func wipe() {
        try? KeychainManager.shared.delete(key: keychainPinWrapped)
        try? KeychainManager.shared.delete(key: keychainPinWrappedLegacy)
        try? KeychainManager.shared.delete(key: keychainSESealed)
    }

    // MARK: - Private helpers

    private static func storePinWrapped(swk: Data, pin: String) throws {
        var saltBytes = [UInt8](repeating: 0, count: saltSize)
        guard SecRandomCopyBytes(kSecRandomDefault, saltBytes.count, &saltBytes) == errSecSuccess else {
            throw VaultError.randomFailed
        }
        let salt = Data(saltBytes)
        let wrapKey = try deriveWrapKey(pin: pin, salt: salt, iterations: pbkdf2Iterations)
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

    private static func decryptPinBlob(_ blob: Data, pin: String, iterations: UInt32) throws -> Data {
        let salt = blob.prefix(saltSize)
        let sealedData = blob.dropFirst(saltSize)
        let wrapKey = try deriveWrapKey(pin: pin, salt: Data(salt), iterations: iterations)
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

    private static func storeSealed(swk: Data) throws {
        let sealed = try SecureEnclaveManager.shared.seal(swk)
        try KeychainManager.shared.storeSecure(key: keychainSESealed, data: sealed)
    }

    private static func deriveWrapKey(pin: String, salt: Data, iterations: UInt32) throws -> Data {
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
                        iterations,
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
            case .notProvisioned:       return NSLocalizedString("vaultError.notProvisioned", comment: "")
            case .randomFailed:         return NSLocalizedString("vaultError.randomFailed", comment: "")
            case .deriveFailed:         return NSLocalizedString("vaultError.deriveFailed", comment: "")
            case .wrapFailed:           return NSLocalizedString("vaultError.wrapFailed", comment: "")
            case .biometricUnavailable: return NSLocalizedString("vaultError.biometricUnavailable", comment: "")
            case .simulatorUnsupported: return NSLocalizedString("vaultError.simulatorUnsupported", comment: "")
            }
        }
    }
}
