import Foundation

/// Sparse per-chain endpoint overrides.
///
/// Absence is meaningful: a chain with no entry follows the active
/// provider, or the public default when no provider covers it. That is
/// what allows a shipped default change to reach existing users. Storing
/// an entry for every chain would freeze each user on whatever the
/// defaults happened to be the day they migrated — the same failure mode
/// `NetworkConfig.migrateDeadEndpoints` exists to clean up after.
final class ChainEndpointOverrides: ObservableObject, @unchecked Sendable {
    static let shared = ChainEndpointOverrides()

    private static let storageKey = "com.horcrux.rpc.chainOverrides"

    /// Keyed by `Chain.rawValue` rather than `Chain` so the dictionary can
    /// go straight into `UserDefaults`, which only accepts property-list
    /// types.
    @Published private(set) var overrides: [String: String] = [:]

    private init() {
        reloadFromDisk()
    }

    func url(for chain: Chain) -> String? {
        guard let value = overrides[chain.rawValue], !value.isEmpty else { return nil }
        return value
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
        overrides[chain.rawValue] = trimmed
        persist()
    }

    func clear(_ chain: Chain) {
        overrides.removeValue(forKey: chain.rawValue)
        persist()
    }

    func removeAll() {
        overrides = [:]
        persist()
    }

    /// Chains that currently carry an override, for the settings list.
    /// Unknown keys are dropped: a stored value for a chain this build no
    /// longer has must not crash the list or resurrect a dead case.
    func allChains() -> Set<Chain> {
        Set(overrides.keys.compactMap(Chain.init(rawValue:)))
    }

    func reloadFromDisk() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.storageKey) as? [String: String]
        overrides = stored ?? [:]
    }

    private func persist() {
        UserDefaults.standard.set(overrides, forKey: Self.storageKey)
    }
}
