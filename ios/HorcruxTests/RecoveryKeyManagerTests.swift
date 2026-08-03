import XCTest
import CryptoKit
import Security
@testable import Horcrux

/// Tests for `RecoveryKeyManager`, the iCloud-Keychain-synced 32-byte secret
/// that serves as the password for v5 portable backup envelopes.
///
/// The load-bearing property is **idempotence**: `getOrCreate()` must return
/// the same key for the lifetime of the Keychain item. If it ever minted a
/// fresh key, every previously written v5 backup would become permanently
/// undecryptable — silent, total wallet loss on restore.
///
/// These tests mutate real Keychain state under the app's service, so each
/// test deletes the recovery key before and after to keep runs hermetic.
/// The simulator's Keychain is per-simulator, so this cannot touch a real
/// user's iCloud Keychain.
final class RecoveryKeyManagerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        try? RecoveryKeyManager.deleteLocal()
    }

    override func tearDown() {
        RecoveryKeyManager.addItemForTesting = nil
        try? RecoveryKeyManager.deleteLocal()
        super.tearDown()
    }

    private func bytes(of key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    // MARK: - Generation

    func testGetOrCreateReturns32ByteKey() throws {
        let key = try RecoveryKeyManager.getOrCreate()
        XCTAssertEqual(key.bitCount, 256)
        XCTAssertEqual(bytes(of: key).count, 32)
    }

    func testGeneratedKeyIsNotAllZeros() throws {
        let key = try RecoveryKeyManager.getOrCreate()
        XCTAssertNotEqual(bytes(of: key), Data(repeating: 0, count: 32),
                          "recovery key must come from SecRandomCopyBytes, not zero-fill")
    }

    /// The single most important guarantee in this file.
    func testGetOrCreateIsIdempotent() throws {
        let first = try RecoveryKeyManager.getOrCreate()
        let second = try RecoveryKeyManager.getOrCreate()
        XCTAssertEqual(bytes(of: first), bytes(of: second),
                       "getOrCreate must reuse the stored key; a fresh key orphans every v5 backup")
    }

    func testGetOrCreateIsStableAcrossManyCalls() throws {
        let baseline = bytes(of: try RecoveryKeyManager.getOrCreate())
        for _ in 0..<5 {
            XCTAssertEqual(bytes(of: try RecoveryKeyManager.getOrCreate()), baseline)
        }
    }

    func testGetOrCreatePersistsMaterialToKeychain() throws {
        let key = try RecoveryKeyManager.getOrCreate()
        let loaded = try RecoveryKeyManager.load()
        XCTAssertEqual(loaded, bytes(of: key))
    }

    func testFreshKeysAfterDeleteAreDistinct() throws {
        let first = bytes(of: try RecoveryKeyManager.getOrCreate())
        try RecoveryKeyManager.deleteLocal()
        let second = bytes(of: try RecoveryKeyManager.getOrCreate())
        XCTAssertNotEqual(first, second,
                          "a regenerated key must be freshly random, not a cached constant")
    }

    // MARK: - load()

    func testLoadReturnsNilWhenNotProvisioned() throws {
        XCTAssertNil(try RecoveryKeyManager.load())
    }

    func testLoadReturnsStoredMaterial() throws {
        _ = try RecoveryKeyManager.getOrCreate()
        let loaded = try RecoveryKeyManager.load()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.count, 32)
    }

    func testLoadIsRepeatableWithoutMutating() throws {
        _ = try RecoveryKeyManager.getOrCreate()
        let a = try RecoveryKeyManager.load()
        let b = try RecoveryKeyManager.load()
        XCTAssertEqual(a, b)
    }

    // MARK: - isProvisioned

    func testIsProvisionedFalseBeforeCreation() {
        XCTAssertFalse(RecoveryKeyManager.isProvisioned)
    }

    func testIsProvisionedTrueAfterCreation() throws {
        _ = try RecoveryKeyManager.getOrCreate()
        XCTAssertTrue(RecoveryKeyManager.isProvisioned)
    }

    func testIsProvisionedFalseAfterDelete() throws {
        _ = try RecoveryKeyManager.getOrCreate()
        try RecoveryKeyManager.deleteLocal()
        XCTAssertFalse(RecoveryKeyManager.isProvisioned)
    }

    /// `isProvisioned` must not have the side effect of minting a key —
    /// the UI reads it on every render of the shard list.
    func testIsProvisionedDoesNotProvision() {
        XCTAssertFalse(RecoveryKeyManager.isProvisioned)
        XCTAssertNil(try? RecoveryKeyManager.load() ?? nil)
    }

    // MARK: - deleteLocal()

    func testDeleteLocalRemovesKey() throws {
        _ = try RecoveryKeyManager.getOrCreate()
        XCTAssertNotNil(try RecoveryKeyManager.load())
        try RecoveryKeyManager.deleteLocal()
        XCTAssertNil(try RecoveryKeyManager.load())
    }

    /// `errSecItemNotFound` is a success case — factory-reset flows call this
    /// unconditionally and must not surface a spurious error.
    func testDeleteLocalOnAbsentKeyDoesNotThrow() {
        XCTAssertNoThrow(try RecoveryKeyManager.deleteLocal())
        XCTAssertNoThrow(try RecoveryKeyManager.deleteLocal())
    }

    // MARK: - Keychain item hygiene

    /// `store()` deletes stale copies before adding. Without that, repeated
    /// provisioning would leave duplicate items and `kSecMatchLimitOne` would
    /// return an arbitrary one — two devices could disagree on the key.
    func testExactlyOneKeychainItemExistsAfterProvisioning() throws {
        _ = try RecoveryKeyManager.getOrCreate()
        _ = try RecoveryKeyManager.getOrCreate()
        XCTAssertEqual(try recoveryKeyItemCount(), 1)
    }

    /// The item must be marked synchronizable or it will never reach peer
    /// devices, defeating the entire "restore without a PIN" design.
    func testStoredItemIsMarkedSynchronizable() throws {
        _ = try RecoveryKeyManager.getOrCreate()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.horcrux.wallet",
            kSecAttrAccount as String: "recoveryKey.v1",
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        XCTAssertEqual(status, errSecSuccess,
                       "recovery key was not stored as synchronizable (status \(status))")
        XCTAssertEqual((item as? Data)?.count, 32)
    }

    /// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` items are excluded from
    /// iCloud Keychain sync by design. Hardening the accessibility class to
    /// "ThisDeviceOnly" looks like a safe tightening but would silently break
    /// cross-device restore, the entire reason this type exists.
    func testStoredItemIsAccessibleWhenUnlockedAndNotDeviceOnly() throws {
        _ = try RecoveryKeyManager.getOrCreate()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.horcrux.wallet",
            kSecAttrAccount as String: "recoveryKey.v1",
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: AnyObject?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &item), errSecSuccess)
        let accessible = (item as? [String: Any])?[kSecAttrAccessible as String] as? String
        XCTAssertEqual(accessible, kSecAttrAccessibleWhenUnlocked as String,
                       "recovery key must use WhenUnlocked; ThisDeviceOnly never syncs to peers")
    }

    private func recoveryKeyItemCount() throws -> Int {        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.horcrux.wallet",
            kSecAttrAccount as String: "recoveryKey.v1",
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var items: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound { return 0 }
        guard status == errSecSuccess else {
            XCTFail("unexpected Keychain status \(status)")
            return -1
        }
        return (items as? [Any])?.count ?? 0
    }

    // MARK: - Contract with PortableBackupCrypto (v5 envelopes)

    func testRecoveryKeyRoundTripsAPortableBackupEnvelope() throws {
        let plaintext = Data("shard-material".utf8)
        let envelope = try PortableBackupCrypto.encrypt(
            plaintext: plaintext,
            recoveryKey: try RecoveryKeyManager.getOrCreate()
        )
        let recovered = try PortableBackupCrypto.decrypt(
            envelope: envelope,
            recoveryKey: try RecoveryKeyManager.getOrCreate()
        )
        XCTAssertEqual(recovered, plaintext)
    }

    /// Documents the blast radius of losing the recovery key: a v5 envelope
    /// sealed under the old key cannot be opened by a regenerated one.
    func testEnvelopeIsUnrecoverableAfterKeyRegeneration() throws {
        let envelope = try PortableBackupCrypto.encrypt(
            plaintext: Data("shard-material".utf8),
            recoveryKey: try RecoveryKeyManager.getOrCreate()
        )
        try RecoveryKeyManager.deleteLocal()
        let regenerated = try RecoveryKeyManager.getOrCreate()
        XCTAssertThrowsError(
            try PortableBackupCrypto.decrypt(envelope: envelope, recoveryKey: regenerated)
        )
    }

    // MARK: - Keychain write failures

    /// The worst silent failure this type can have: returning a key that was
    /// never persisted. The caller would seal a v5 backup under it, and the
    /// next launch would mint a different key — orphaning the backup forever.
    /// `getOrCreate` must therefore fail loudly when the Keychain write fails.
    func testGetOrCreateThrowsWhenKeychainWriteFails() throws {
        XCTAssertNil(try RecoveryKeyManager.load(), "precondition: no key")
        var hookCalls = 0
        RecoveryKeyManager.addItemForTesting = { _ in hookCalls += 1; return errSecMissingEntitlement }
        XCTAssertThrowsError(try RecoveryKeyManager.getOrCreate()) { error in
            guard case RecoveryKeyManager.Error.storeFailed(let status) = error else {
                XCTFail("expected .storeFailed, got \(error)")
                return
            }
            XCTAssertEqual(status, errSecMissingEntitlement)
        }
        XCTAssertEqual(hookCalls, 1, "seam was not consulted")
    }

    func testFailedKeychainWriteLeavesNoKeyBehind() throws {
        XCTAssertNil(try RecoveryKeyManager.load(), "precondition: no key")
        RecoveryKeyManager.addItemForTesting = { _ in errSecMissingEntitlement }
        XCTAssertThrowsError(try RecoveryKeyManager.getOrCreate())
        RecoveryKeyManager.addItemForTesting = nil
        XCTAssertNil(try RecoveryKeyManager.load())
        XCTAssertFalse(RecoveryKeyManager.isProvisioned)
    }

    // MARK: - Error descriptions

    func testErrorDescriptionsIncludeStatusCode() {
        XCTAssertEqual(RecoveryKeyManager.Error.generationFailed(-25291).errorDescription,
                       "Recovery key generation failed (-25291)")
        XCTAssertEqual(RecoveryKeyManager.Error.storeFailed(-34018).errorDescription,
                       "Recovery key store failed (-34018)")
        XCTAssertEqual(RecoveryKeyManager.Error.loadFailed(-25300).errorDescription,
                       "Recovery key load failed (-25300)")
    }
}
