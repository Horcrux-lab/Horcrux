import Foundation

/// Lightweight persistence for "when did each MPC account last rotate its
/// shard?". Backed by UserDefaults so it survives relaunches but deliberately
/// NOT on iCloud — rotation cadence is per-device bookkeeping, not wallet
/// metadata. Keyed by `wallet.accountId` (hex of the group public key) so all
/// chain-aliases of a single DKG account share one timestamp.
///
/// Threshold for the "it's been a while, consider rotating" nudge:
/// - `recommendedRotationInterval` = 90 days.
///   CGGMP21 proactive refresh is cheap; rotating quarterly gives a healthy
///   compromise window without annoying users.
enum RefreshTracker {
    static let recommendedRotationInterval: TimeInterval = 60 * 60 * 24 * 90
    private static let storageKey = "horcrux.lastRefreshedAt.v1"

    /// Accountable via a nested `[accountId: ISO8601 timestamp]` dictionary.
    private static func read() -> [String: Date] {
        guard let raw = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: TimeInterval] else {
            return [:]
        }
        return raw.mapValues { Date(timeIntervalSince1970: $0) }
    }

    private static func write(_ map: [String: Date]) {
        let raw = map.mapValues { $0.timeIntervalSince1970 }
        UserDefaults.standard.set(raw, forKey: storageKey)
    }

    /// Returns the last refresh timestamp for this account, or nil if it has
    /// never been rotated (typical for freshly-created wallets).
    static func lastRefresh(accountId: String) -> Date? {
        read()[accountId]
    }

    /// Records a successful refresh. Called from `RefreshShardCoordinator`
    /// after the Keychain swap completes.
    static func recordRefresh(accountId: String, at date: Date = Date()) {
        var map = read()
        map[accountId] = date
        write(map)
    }

    /// True when `lastRefresh` is either missing OR older than the
    /// recommended interval. Fresh wallets (< 7 days old) get a grace
    /// period so we don't nag immediately after DKG.
    static func needsRotation(accountId: String, walletCreatedAt: Date) -> Bool {
        let gracePeriod: TimeInterval = 60 * 60 * 24 * 7
        guard Date().timeIntervalSince(walletCreatedAt) > gracePeriod else { return false }
        guard let last = lastRefresh(accountId: accountId) else { return true }
        return Date().timeIntervalSince(last) > recommendedRotationInterval
    }

    /// Clear all timestamps. Invoked by `WalletStore.wipeAll()` so a full
    /// reset leaves no stale per-account bookkeeping behind.
    static func wipeAll() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}
