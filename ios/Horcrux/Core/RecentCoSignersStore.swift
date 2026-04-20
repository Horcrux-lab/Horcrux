import Foundation
import Combine

/// A cosigner we've signed with before, scoped to a specific wallet.
/// Persisted as JSON in UserDefaults (non-sensitive: just a display
/// name + opaque peer id + last-seen timestamp). Used on the invite
/// screen to show a "Last signed with" hint so returning users can
/// mentally confirm "yes, Alice's iPhone" before sharing the room
/// code, instead of watching an unnamed peer pop in.
struct RecentCoSigner: Codable, Hashable, Identifiable {
    let id: String          // peer.id (stable across sessions for the same device)
    var name: String
    var walletId: String
    var lastSeenAt: Date
}

/// Thin store on top of UserDefaults. Entries are keyed by
/// (walletId, peer.id) so the same device used on two different
/// wallets produces two entries — what matters to the user is
/// "who I last signed *this wallet* with".
@MainActor
final class RecentCoSignersStore: ObservableObject {
    static let shared = RecentCoSignersStore()
    private static let storageKey = "signing.recentCoSigners.v1"
    /// Hard cap per wallet so a noisy user doesn't balloon defaults.
    /// Oldest entries evicted on insert.
    private static let maxEntriesPerWallet = 5

    @Published private(set) var entries: [RecentCoSigner] = []

    private init() {
        load()
    }

    /// Record that we successfully completed a signing ceremony with `peer`
    /// on `walletId`. Called from `SigningViewModel` right after
    /// `finishSigning` / tx broadcast. Updates the timestamp if the
    /// entry already exists.
    func record(peerId: String, name: String, walletId: String, at date: Date = .now) {
        guard !peerId.isEmpty else { return }
        if let idx = entries.firstIndex(where: { $0.id == peerId && $0.walletId == walletId }) {
            entries[idx].name = name.isEmpty ? entries[idx].name : name
            entries[idx].lastSeenAt = date
        } else {
            entries.append(RecentCoSigner(id: peerId, name: name, walletId: walletId, lastSeenAt: date))
        }
        evictOldest(for: walletId)
        save()
    }

    /// Most-recent-first list of peers we've signed this wallet with.
    func recent(for walletId: String) -> [RecentCoSigner] {
        entries
            .filter { $0.walletId == walletId }
            .sorted { $0.lastSeenAt > $1.lastSeenAt }
    }

    /// Single most recent peer for a wallet, or nil if we've never
    /// signed anything on it yet. Drives the "Last signed with" hint.
    func mostRecent(for walletId: String) -> RecentCoSigner? {
        recent(for: walletId).first
    }

    /// Forget a specific peer (user-initiated, e.g. from a long-press
    /// on the recent-peer chip in the invite UI — not wired yet, but
    /// we expose the API so the future chip can clear stale entries).
    func forget(peerId: String, walletId: String) {
        entries.removeAll { $0.id == peerId && $0.walletId == walletId }
        save()
    }

    private func evictOldest(for walletId: String) {
        let walletEntries = entries
            .enumerated()
            .filter { $0.element.walletId == walletId }
            .sorted { $0.element.lastSeenAt > $1.element.lastSeenAt }
        if walletEntries.count <= Self.maxEntriesPerWallet { return }
        let toDrop = walletEntries.dropFirst(Self.maxEntriesPerWallet).map(\.offset)
        // Drop from highest index first so earlier offsets stay valid.
        for idx in toDrop.sorted(by: >) {
            entries.remove(at: idx)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey) else { return }
        if let decoded = try? JSONDecoder().decode([RecentCoSigner].self, from: data) {
            entries = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
