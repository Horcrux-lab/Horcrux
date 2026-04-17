import Foundation
import Combine

/// Persists user-editable per-account display names (keyed by accountId).
/// Backed by UserDefaults because names are non-sensitive; the canonical
/// identity remains the DKG group public key.
@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    @Published private(set) var names: [String: String] = [:]

    private let defaultsKey = "com.horcrux.account_names.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            self.names = decoded
        }
    }

    /// Returns the user-chosen name if set, otherwise falls back to a sensible
    /// default derived from the first wallet in the group.
    func name(for accountId: String, fallback: @autoclosure () -> String) -> String {
        names[accountId] ?? fallback()
    }

    func setName(_ name: String, for accountId: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            names.removeValue(forKey: accountId)
        } else {
            names[accountId] = trimmed
        }
        persist()
    }

    func clear(accountId: String) {
        names.removeValue(forKey: accountId)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(names) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
