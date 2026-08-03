import Foundation

/// Tracks locally-signed but not-yet-mined EVM nonces so that rapid
/// back-to-back sends don't collide on the same value.
///
/// Public RPCs are eventually-consistent: after we broadcast a tx with nonce
/// N, a subsequent `eth_getTransactionCount(..., "latest")` can still return
/// N for tens of seconds while the tx propagates. Without tracking, a second
/// send within that window would reuse nonce N and get "already known" /
/// "replacement underpriced" errors.
///
/// Strategy: remember the highest nonce we've signed for each
/// (chainId, address) pair. When asked for the next nonce, return
/// `max(rpcNonce, lastSigned + 1)`. Entries auto-expire after 10 minutes
/// to avoid permanent drift if a tx gets dropped from the mempool.
@MainActor
final class PendingNonceTracker {
    static let shared = PendingNonceTracker()

    private struct Entry {
        let nonce: UInt64
        let timestamp: Date
    }

    private var entries: [String: Entry] = [:]
    private let ttl: TimeInterval = 600 // 10 minutes
    private let now: () -> Date

    /// `now` exists so the ten-minute expiry is reachable in a test
    /// without waiting ten minutes.
    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    private func key(chainId: UInt64, address: String) -> String {
        "\(chainId):\(address.lowercased())"
    }

    /// Return the nonce to use for the next tx. Prefer whichever is
    /// higher: the RPC's view of the account, or `localLastSigned + 1`.
    func nextNonce(chainId: UInt64, address: String, rpcNonce: UInt64) -> UInt64 {
        let k = key(chainId: chainId, address: address)
        if let entry = entries[k],
           now().timeIntervalSince(entry.timestamp) < ttl {
            return max(rpcNonce, entry.nonce + 1)
        }
        // Expired or never used — trust the RPC.
        entries.removeValue(forKey: k)
        return rpcNonce
    }

    /// Record that we've just broadcast (or attempted to broadcast) a tx
    /// with `nonce` for the given account.
    func record(chainId: UInt64, address: String, nonce: UInt64) {
        let k = key(chainId: chainId, address: address)
        // Only bump; don't regress if called with a stale value.
        if let existing = entries[k], existing.nonce >= nonce {
            entries[k] = Entry(nonce: existing.nonce, timestamp: now())
        } else {
            entries[k] = Entry(nonce: nonce, timestamp: now())
        }
    }

    /// Forget the tracked nonce once we've confirmed that the RPC has
    /// caught up (or the user reset the account).
    func clear(chainId: UInt64, address: String) {
        entries.removeValue(forKey: key(chainId: chainId, address: address))
    }
}
