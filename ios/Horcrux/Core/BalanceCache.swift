import Foundation
import Combine

/// Shared in-memory cache for wallet native balances.
///
/// Both `PortfolioSummaryCard` and `WalletRow` need each wallet's balance to
/// render — historically they fetched independently, duplicating RPC traffic
/// and producing inconsistent values between the hero card and the list rows.
///
/// This cache coalesces concurrent fetches per wallet and publishes results,
/// so the summary card and rows read from the same source of truth. Entries
/// carry a short TTL (30s) to keep balances reasonably fresh without hammering
/// the RPC on every view appearance.
@MainActor
final class BalanceCache: ObservableObject {
    static let shared = BalanceCache()

    struct Entry {
        let raw: String          // e.g. "1.234 ETH"
        let fetchedAt: Date
    }

    @Published private(set) var entries: [String: Entry] = [:]

    private var inflight: [String: Task<String?, Never>] = [:]
    private let ttl: TimeInterval = 30

    private init() {}

    /// Returns the cached raw balance string for a wallet, or nil if absent.
    func cachedRaw(walletId: String) -> String? {
        entries[walletId]?.raw
    }

    /// Fetch (or reuse) the balance for a wallet. Concurrent callers for the
    /// same wallet share a single in-flight task. Returns nil on failure.
    @discardableResult
    func balance(for wallet: Wallet,
                 service: BlockchainService,
                 config: NetworkConfig,
                 force: Bool = false) async -> String? {
        if !force, let e = entries[wallet.id],
           Date().timeIntervalSince(e.fetchedAt) < ttl {
            return e.raw
        }
        if let existing = inflight[wallet.id] {
            return await existing.value
        }
        let id = wallet.id
        let task = Task<String?, Never> { [weak self] in
            let raw: String?
            do {
                raw = try await service.balance(for: wallet, config: config)
            } catch {
                raw = nil
            }
            await MainActor.run {
                guard let self else { return }
                if let raw {
                    self.entries[id] = Entry(raw: raw, fetchedAt: Date())
                }
                self.inflight[id] = nil
            }
            return raw
        }
        inflight[id] = task
        return await task.value
    }

    /// Numeric native amount parsed from the cached "1.234 ETH" string.
    func nativeAmount(walletId: String) -> Double? {
        guard let raw = entries[walletId]?.raw else { return nil }
        let first = raw.split(separator: " ").first.map(String.init) ?? ""
        return Double(first.replacingOccurrences(of: ",", with: ""))
    }

    /// Drop all cached entries. Useful when the network config changes.
    func invalidateAll() {
        entries.removeAll()
    }
}
