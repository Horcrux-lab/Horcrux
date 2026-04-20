import Foundation
import SwiftUI
import Combine

/// Per-account visual identity (emoji + gradient color). Lets users tell
/// apart multiple MPC accounts at a glance in the wallet list. Stored in
/// UserDefaults keyed by `accountId` (DKG group public key hex) so the
/// look survives rename / rotation / chain addition. Entirely cosmetic —
/// never read by any crypto path.
@MainActor
final class WalletAvatarStore: ObservableObject {
    static let shared = WalletAvatarStore()

    struct Avatar: Codable, Equatable {
        var emoji: String
        var colorKey: String
    }

    /// Curated gradient palette. Keys are stored in UserDefaults; the
    /// gradient itself is recomputed client-side so we can tune the
    /// colors without a migration.
    static let palette: [(key: String, top: Color, bottom: Color)] = [
        ("purple",  Color(red: 0.54, green: 0.35, blue: 0.97), Color(red: 0.31, green: 0.20, blue: 0.76)),
        ("cyan",    Color(red: 0.20, green: 0.75, blue: 0.95), Color(red: 0.08, green: 0.45, blue: 0.78)),
        ("teal",    Color(red: 0.18, green: 0.80, blue: 0.67), Color(red: 0.06, green: 0.50, blue: 0.45)),
        ("emerald", Color(red: 0.25, green: 0.76, blue: 0.45), Color(red: 0.08, green: 0.48, blue: 0.28)),
        ("amber",   Color(red: 0.98, green: 0.70, blue: 0.22), Color(red: 0.80, green: 0.44, blue: 0.08)),
        ("coral",   Color(red: 0.98, green: 0.45, blue: 0.46), Color(red: 0.80, green: 0.20, blue: 0.28)),
        ("magenta", Color(red: 0.90, green: 0.35, blue: 0.72), Color(red: 0.60, green: 0.15, blue: 0.55)),
        ("slate",   Color(red: 0.42, green: 0.47, blue: 0.58), Color(red: 0.22, green: 0.26, blue: 0.34))
    ]

    /// Popular emoji picks. We deliberately keep the set small — too many
    /// choices make the picker feel like a keyboard. Most are neutral
    /// shapes/animals; avoid faces that read as "profile photo" since the
    /// avatar represents an account, not a person.
    static let emojiChoices: [String] = [
        "🔐", "🗝️", "🛡️", "⭐️", "✨", "🌙", "☀️",
        "🌊", "🔥", "🌱", "🌲", "🍀", "🎯", "🎲",
        "💎", "⚡️", "🧿", "🪩", "🦊", "🦉", "🐳",
        "🦄", "🚀", "🛸"
    ]

    @Published private(set) var avatars: [String: Avatar] = [:]

    private let defaultsKey = "com.horcrux.wallet_avatars.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([String: Avatar].self, from: data) {
            self.avatars = decoded
        }
    }

    func avatar(for accountId: String) -> Avatar? { avatars[accountId] }

    func set(_ avatar: Avatar, for accountId: String) {
        avatars[accountId] = avatar
        persist()
    }

    func clear(accountId: String) {
        avatars.removeValue(forKey: accountId)
        persist()
    }

    /// Deterministic default color for an account that hasn't been
    /// customised yet — keeps every group visually distinct without the
    /// user lifting a finger. Hashes the accountId into the palette index.
    func defaultColorKey(for accountId: String) -> String {
        let idx = abs(accountId.hashValue) % Self.palette.count
        return Self.palette[idx].key
    }

    func gradient(for colorKey: String) -> LinearGradient {
        let pair = Self.palette.first { $0.key == colorKey } ?? Self.palette[0]
        return LinearGradient(
            colors: [pair.top, pair.bottom],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(avatars) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    /// Invoked by `WalletStore.wipeAll()` so a reset leaves no stale
    /// per-account cosmetic state.
    func wipeAll() {
        avatars.removeAll()
        defaults.removeObject(forKey: defaultsKey)
    }
}
