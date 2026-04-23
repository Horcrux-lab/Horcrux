import XCTest
@testable import Horcrux

/// Audit C1 round-16 follow-up — AccountBackup migration tests.
/// Verifies that the `peerRegistry` field (introduced in this round)
/// survives encode→decode round-trips, and that legacy v3 backup
/// JSON (produced before the registry existed) still decodes with
/// `peerRegistry == nil` so existing users can continue importing.
final class AccountBackupMigrationTests: XCTestCase {

    private func makeEntry() -> AccountBackup.WalletEntry {
        AccountBackup.WalletEntry(
            id: "w-1",
            name: "ETH Wallet",
            chain: .ethereum,
            address: "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: - Legacy v3 backup (no peerRegistry key) decodes with nil

    func testLegacyV3BackupDecodesWithNilRegistry() throws {
        // Representative v3 JSON as produced by builds shipped before
        // round 16. peerRegistry key is absent; Swift's Optional
        // decoding must default to nil.
        let json = """
        {
          "version": 3,
          "accountId": "abc123",
          "accountName": "My Account",
          "partyIndex": 1,
          "threshold": 2,
          "totalParties": 3,
          "encryptedShard": "AAECAw==",
          "groupPublicKey": "AgME",
          "wallets": [
            {
              "id": "w-1",
              "name": "ETH Wallet",
              "chain": "Ethereum",
              "address": "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
              "createdAt": "2023-11-14T22:13:20Z"
            }
          ],
          "exportedAt": "2023-11-14T22:13:20Z"
        }
        """.data(using: .utf8)!

        let decoded = try decoder().decode(AccountBackup.self, from: json)
        XCTAssertEqual(decoded.version, 3)
        XCTAssertEqual(decoded.accountId, "abc123")
        XCTAssertEqual(decoded.wallets.count, 1)
        XCTAssertNil(decoded.peerRegistry,
                     "legacy v3 backup (no peerRegistry key) must decode as nil")
    }

    // MARK: - v4 backup with registry round-trips cleanly

    func testBackupWithRegistryRoundTrips() throws {
        let registry: [String: UInt16] = ["peer-A": 2, "peer-B": 3]
        let backup = AccountBackup(
            version: 4,
            accountId: "abc123",
            accountName: "Round-16 Account",
            partyIndex: 1,
            threshold: 2,
            totalParties: 3,
            encryptedShard: Data([0x00, 0x01, 0x02, 0x03]),
            groupPublicKey: Data([0x02, 0x03, 0x04]),
            wallets: [makeEntry()],
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            peerRegistry: registry
        )

        let data = try encoder().encode(backup)
        let decoded = try decoder().decode(AccountBackup.self, from: data)

        XCTAssertEqual(decoded.version, 4)
        XCTAssertEqual(decoded.partyIndex, 1)
        XCTAssertEqual(decoded.peerRegistry, registry,
                       "round-trip must preserve the registry verbatim")
    }

    // MARK: - Nil registry encodes and decodes symmetrically

    func testNilRegistryRoundTrip() throws {
        let backup = AccountBackup(
            version: 3,
            accountId: "legacy",
            accountName: "Legacy",
            partyIndex: 1,
            threshold: 2,
            totalParties: 3,
            encryptedShard: Data([0x00]),
            groupPublicKey: Data([0x01]),
            wallets: [makeEntry()],
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            peerRegistry: nil
        )

        let data = try encoder().encode(backup)
        let decoded = try decoder().decode(AccountBackup.self, from: data)
        XCTAssertNil(decoded.peerRegistry)
    }

    // MARK: - BackupPreview exposes registry only on account backups

    func testBackupPreviewRegistryAccessor() throws {
        let registry: [String: UInt16] = ["peer-X": 2]
        let account = AccountBackup(
            version: 4,
            accountId: "abc",
            accountName: "A",
            partyIndex: 1,
            threshold: 2,
            totalParties: 3,
            encryptedShard: Data(),
            groupPublicKey: Data(),
            wallets: [makeEntry()],
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            peerRegistry: registry
        )
        let accountPreview: BackupPreview = .account(account)
        XCTAssertEqual(accountPreview.peerRegistry, registry)

        let legacy = ShardBackup(
            version: 2,
            walletId: "leg",
            walletName: "Legacy",
            chain: .ethereum,
            address: "0xBB",
            partyIndex: 1,
            threshold: 2,
            totalParties: 3,
            encryptedShard: Data(),
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            groupPublicKey: nil
        )
        let legacyPreview: BackupPreview = .legacy(legacy)
        XCTAssertNil(legacyPreview.peerRegistry,
                     "legacy v2 preview must report nil registry")
    }
}
