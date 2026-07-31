import Foundation

/// Sparse per-chain endpoint overrides.
///
/// Absence is meaningful: a chain with no entry follows the active
/// provider, or the public default when no provider covers it. That is
/// what allows a shipped default change to reach existing users. Storing
/// an entry for every chain would freeze each user on whatever the
/// defaults happened to be the day they migrated — the same failure mode
/// `NetworkConfig.migrateDeadEndpoints` exists to clean up after.
///
/// Reads happen off the main thread. `BlockchainService` is an `actor` and
/// calls `NetworkConfig.rpcURL(for:)` from its own executor, so once the
/// resolver consults this store an RPC thread will be reading the
/// dictionary while a settings screen mutates it on main. A `Dictionary`
/// reallocates its buffer as it grows, so that race can hand a reader
/// freed storage. Hence the lock. Marking the type `@MainActor` instead —
/// as `NodeHealthStore` is — is not available: it would make the
/// synchronous read from the actor-isolated RPC path impossible.
final class ChainEndpointOverrides: ObservableObject, @unchecked Sendable {
    static let shared = ChainEndpointOverrides()

    /// Not private: tests assert against the real stored payload, and a
    /// duplicated string literal there would silently start testing
    /// nothing the day this key is renamed.
    static let storageKey = "com.horcrux.rpc.chainOverrides"

    private let lock = NSLock()

    /// The authoritative store, guarded by `lock`. Keyed by
    /// `Chain.rawValue` rather than `Chain` so the dictionary can go
    /// straight into `UserDefaults`, which only accepts property-list types.
    private var storage: [String: String] = [:]

    /// Main-thread mirror, for SwiftUI only. Do not read this from the RPC
    /// path — it is updated asynchronously and may lag `storage`. Use
    /// `url(for:)` or `snapshot()`, which take the lock.
    @Published private(set) var overrides: [String: String] = [:]

    private init() {
        reloadFromDisk()
    }

    func url(for chain: Chain) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[chain.rawValue]
    }

    /// Storing an empty string clears the entry rather than persisting "",
    /// so a user who selects-all-and-deletes in the text field returns to
    /// the default instead of pinning an unusable empty endpoint.
    func set(_ url: String, for chain: Chain) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            clear(chain)
            return
        }
        mutate { $0[chain.rawValue] = trimmed }
    }

    func clear(_ chain: Chain) {
        mutate { $0.removeValue(forKey: chain.rawValue) }
    }

    func removeAll() {
        mutate { $0.removeAll() }
    }

    /// Atomically replaces the entire override store with the contents of
    /// `raw`, applying the same per-entry normalisation that `reloadFromDisk`
    /// applies: each value is trimmed of whitespace; entries that trim to
    /// empty are dropped. One lock acquisition, one `UserDefaults` write, one
    /// mirror publish — no intermediate observable states.
    ///
    /// Takes a raw `[String: String]` rather than `[Chain: String]` so that
    /// keys belonging to chains this build does not recognise are preserved
    /// verbatim. A newer build's overrides must survive a downgrade, round-trip
    /// through export/import, and come back to life after an upgrade.  This is
    /// a deliberate counterpart to the per-entry filtering in `reloadFromDisk`;
    /// both keep the invariant that `storage` never holds an empty-string value.
    func replaceAll(with raw: [String: String]) {
        let cleaned = raw.compactMapValues { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        mutate { $0 = cleaned }
    }

    /// Chains that currently carry an override, for the settings list.
    /// Unknown keys are dropped: a stored value for a chain this build no
    /// longer has must not crash the list or resurrect a dead case.
    func allChains() -> Set<Chain> {
        Set(snapshot().keys.compactMap(Chain.init(rawValue:)))
    }

    /// A consistent copy for callers that need the whole map, such as
    /// config export.
    func snapshot() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func reloadFromDisk() {
        // Filtered per entry rather than cast wholesale. `as? [String: String]`
        // on the container is all-or-nothing: one non-String value — from a
        // newer build's payload after a downgrade, managed app config, or
        // plain plist corruption — would nil the whole dictionary and drop
        // every hand-entered self-hosted address the user has. The next
        // write would then make that loss permanent.
        let raw = UserDefaults.standard.dictionary(forKey: Self.storageKey) ?? [:]
        let cleaned = raw.compactMapValues { value -> String? in
            guard let text = value as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        lock.lock()
        storage = cleaned
        lock.unlock()
        publishMirror(cleaned)
    }

    /// Empty values are dropped at the disk boundary above, so `storage`
    /// never holds one. That keeps `url(for:)`, `allChains()` and
    /// `snapshot()` agreeing on what "has an override" means — a store
    /// whose whole semantics rest on "absent means follow the default"
    /// cannot afford two answers to that question.
    private func mutate(_ body: (inout [String: String]) -> Void) {
        lock.lock()
        body(&storage)
        let updated = storage
        // Write to UserDefaults while holding the lock so two concurrent
        // mutations cannot reorder: without this, the slower writer's
        // lock.unlock() returns first, both proceed to set(), and the older
        // snapshot lands last, leaving UserDefaults diverged from storage
        // until the next reloadFromDisk().
        UserDefaults.standard.set(updated, forKey: Self.storageKey)
        lock.unlock()
        // publishMirror deliberately runs outside the lock. On the main
        // thread it assigns `overrides` synchronously, which can drive
        // SwiftUI observers that call back into url(for:). The lock is
        // not recursive, so publishing inside would deadlock.
        publishMirror(updated)
    }

    private func publishMirror(_ value: [String: String]) {
        if Thread.isMainThread {
            overrides = value
        } else {
            DispatchQueue.main.async { [weak self] in self?.overrides = value }
        }
    }
}
