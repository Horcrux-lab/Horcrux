import Foundation
import CryptoKit
import Security

/// iCloud-Keychain-synced recovery key. Provides a 32-byte secret that
/// automatically propagates to all devices signed into the same Apple ID,
/// **without requiring a user-visible password**. This replaces the PIN
/// as the password for portable backup envelopes so that restoring a
/// backup on another Apple device "just works" (no PIN matching) as long
/// as iCloud Keychain is enabled.
///
/// Security model (matches Apple Passwords):
/// - Apple end-to-end encrypts iCloud Keychain with a device-bound key
///   derived from the user's iCloud security code; Apple cannot read it.
/// - On-device, access is gated by device unlock (`WhenUnlocked`).
/// - A thief with a signed-in unlocked device can extract the key, but
///   they can already operate the wallet at that point — no net loss.
///
/// This is NOT a WebAuthn passkey (those require associated-domains and
/// AASA hosting, which this app does not yet have). It is the pragmatic
/// equivalent for the two user-facing goals: no PIN prompt on backup and
/// frictionless cross-device restore.
enum RecoveryKeyManager {

    private static let service = "com.horcrux.wallet"
    private static let account = "recoveryKey.v1"

    enum Error: LocalizedError {
        case generationFailed(OSStatus)
        case storeFailed(OSStatus)
        case loadFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .generationFailed(let s): return "Recovery key generation failed (\(s))"
            case .storeFailed(let s): return "Recovery key store failed (\(s))"
            case .loadFailed(let s): return "Recovery key load failed (\(s))"
            }
        }
    }

    /// Whether a recovery key is present in the local Keychain view.
    /// (iCloud Keychain will eventually populate it on freshly signed-in
    /// devices; callers should treat absence as "not yet synced" rather
    /// than "user has no key".)
    static var isProvisioned: Bool {
        (try? load()) != nil
    }

    /// Returns the recovery key, generating and persisting a fresh one
    /// if none exists on this device. The write is tagged as iCloud
    /// synchronizable so peer devices receive the same key.
    static func getOrCreate() throws -> SymmetricKey {
        if let existing = try load() {
            return SymmetricKey(data: existing)
        }
        // Generate 32 cryptographically random bytes.
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw Error.generationFailed(status)
        }
        let material = Data(bytes)
        try store(material)
        return SymmetricKey(data: material)
    }

    /// Returns the recovery key if it's already present. Does not
    /// generate a new one.
    static func load() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw Error.loadFailed(status)
        }
        return data
    }

    /// Remove the recovery key from this device. Does **not** delete
    /// peer copies; iCloud Keychain will re-sync this device next time.
    /// Only used for factory-reset-style flows.
    static func deleteLocal() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw Error.storeFailed(status)
        }
    }

    // MARK: - Private

    private static func store(_ data: Data) throws {
        // Remove any stale local copy first. We must pass
        // `kSecAttrSynchronizableAny` in the delete query so that both
        // synced and non-synced duplicates get cleaned up.
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // `WhenUnlocked` (not `…ThisDeviceOnly`) is required for
            // iCloud Keychain sync to pick the item up.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
            kSecAttrSynchronizable as String: kCFBooleanTrue!
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw Error.storeFailed(status)
        }
    }
}
