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

    /// Token-balance cache keyed by "<walletId>:<tokenId>" → numeric amount
    /// (in whole-token units, already decimal-adjusted). Populated lazily
    /// when a view explicitly asks for a token balance; used by the Max
    /// button on the signing compose form.
    @Published private(set) var tokenEntries: [String: Double] = [:]
    private var tokenFetchedAt: [String: Date] = [:]

    private var inflight: [String: Task<String?, Never>] = [:]
    private var tokenInflight: [String: Task<Double?, Never>] = [:]
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

    /// Force-refresh native balances for a list of wallets in parallel.
    /// Concurrent in-flight tasks per wallet are still coalesced inside
    /// `balance(for:)`, so triggering this from one view while another
    /// view is mid-fetch will reuse the same RPC. Used by the Home pull-
    /// to-refresh and by `PortfolioSummaryCard`'s initial `.task`.
    func refreshAll(wallets: [Wallet],
                    service: BlockchainService,
                    config: NetworkConfig,
                    force: Bool = false) async {
        await withTaskGroup(of: Void.self) { group in
            for wallet in wallets {
                group.addTask { @MainActor in
                    _ = await self.balance(for: wallet,
                                           service: service,
                                           config: config,
                                           force: force)
                }
            }
        }
    }

    /// Drop all cached entries. Useful when the network config changes.
    func invalidateAll() {
        entries.removeAll()
        tokenEntries.removeAll()
        tokenFetchedAt.removeAll()
    }

    /// Synchronously record a token balance that was fetched through another
    /// code path (e.g. the wallet detail view fetching every supported token
    /// at once). Lets other views — especially the Max button in signing —
    /// read the value without triggering their own RPC call.
    func seedTokenBalance(walletId: String, tokenId: String, value: Double) {
        let key = "\(walletId):\(tokenId)"
        tokenEntries[key] = value
        tokenFetchedAt[key] = Date()
    }

    /// Returns the cached whole-token balance (e.g. 42.5 for 42.5 USDC),
    /// or nil if we haven't fetched it yet / it's stale.
    func cachedTokenBalance(walletId: String, tokenId: String) -> Double? {
        let k = "\(walletId):\(tokenId)"
        if let ts = tokenFetchedAt[k], Date().timeIntervalSince(ts) < ttl * 4 {
            return tokenEntries[k]
        }
        return tokenEntries[k] // stale value still useful for Max; poller refreshes
    }

    /// Fetch a single token's balance for the wallet. Coalesces concurrent
    /// callers for the same (wallet, token) pair. Uses the chain's already-
    /// wired balance-fetch path (`service.tokenBalances`) and extracts the
    /// single matching entry.
    @discardableResult
    func tokenBalance(wallet: Wallet, token: Token,
                      service: BlockchainService,
                      config: NetworkConfig,
                      force: Bool = false) async -> Double? {
        let key = "\(wallet.id):\(token.id)"
        if !force, let cached = tokenEntries[key],
           let ts = tokenFetchedAt[key],
           Date().timeIntervalSince(ts) < ttl {
            return cached
        }
        if let existing = tokenInflight[key] {
            return await existing.value
        }
        let task = Task<Double?, Never> { [weak self] in
            let snapshots = await service.tokenBalances(for: wallet, config: config)
            let match = snapshots.first(where: { $0.token.id == token.id })
            let value: Double? = match.flatMap {
                // displayBalance is e.g. "42.5 USDC" — strip the symbol.
                let first = $0.displayBalance.split(separator: " ").first.map(String.init) ?? ""
                return Double(first.replacingOccurrences(of: ",", with: ""))
            }
            await MainActor.run {
                guard let self else { return }
                if let value { self.tokenEntries[key] = value }
                self.tokenFetchedAt[key] = Date()
                self.tokenInflight[key] = nil
            }
            return value
        }
        tokenInflight[key] = task
        return await task.value
    }
}
