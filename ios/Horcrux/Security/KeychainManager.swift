import Foundation
import Security
import LocalAuthentication

/// Secure shard storage using iOS Keychain.
final class KeychainManager: @unchecked Sendable {
    static let shared = KeychainManager()
    private init() {}

    private let service = "com.horcrux.wallet"

    /// Store data in keychain (standard protection: WhenUnlockedThisDeviceOnly).
    func store(key: String, data: Data) throws {
        // Delete any existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.storeFailed(status)
        }
    }

    /// Store with enhanced protection (AfterFirstUnlockThisDeviceOnly).
    /// Suitable for data that needs to be available early in boot (e.g., TOFU pins)
    /// but should not migrate to other devices.
    func storeProtected(key: String, data: Data) throws {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.storeFailed(status)
        }
    }

    /// Store sensitive data (shard keys, device key) with SecAccessControl.
    /// Requires device passcode; won't migrate to other devices.
    /// On devices without a passcode (e.g. simulator or a user who never
    /// set one), falls back to `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
    /// so writes still succeed.
    func storeSecure(key: String, data: Data) throws {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // First attempt: passcode-gated access control.
        var aclError: Unmanaged<CFError>?
        if let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            [],
            &aclError
        ) {
            let context = LAContext()
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
                kSecValueData as String: data,
                kSecAttrAccessControl as String: access,
                kSecUseAuthenticationContext as String: context
            ]
            let status = SecItemAdd(query as CFDictionary, nil)
            context.invalidate()
            if status == errSecSuccess { return }
            // errSecAuthFailed (-25293) is what we see on simulators / devices
            // without a passcode. Fall through to the softer path.
            if status != errSecAuthFailed && status != errSecDecode {
                throw KeychainError.storeFailed(status)
            }
        }

        // Fallback: no ACL, just `WhenUnlockedThisDeviceOnly`. Still safe
        // (can't be extracted while device is locked, doesn't leave device)
        // but doesn't require the user to have set a passcode.
        let fallbackQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(fallbackQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.storeFailed(status)
        }
    }

    /// Retrieve data from keychain.
    func retrieve(key: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.retrieveFailed(status)
        }
    }

    /// Delete data from keychain.
    func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    /// Delete all items for this service.
    func deleteAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum KeychainError: LocalizedError {
    case storeFailed(OSStatus)
    case retrieveFailed(OSStatus)
    case deleteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .storeFailed(let s): return "Keychain store failed: \(s)"
        case .retrieveFailed(let s): return "Keychain retrieve failed: \(s)"
        case .deleteFailed(let s): return "Keychain delete failed: \(s)"
        }
    }
}
