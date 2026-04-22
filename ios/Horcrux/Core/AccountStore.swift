import Foundation
import SwiftUI
import Combine

/// Predefined vault tag chips — user picks a label/color to identify the
/// vault's role (Treasury / Hot / Cold / ops / personal). Kept as a small
/// fixed enum so the visual language stays consistent and localized.
enum VaultTag: String, CaseIterable, Codable, Identifiable {
    case treasury
    case hot
    case cold
    case operating
    case personal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .treasury:  return NSLocalizedString("vaultTag.treasury",  value: "Treasury",  comment: "Vault role tag")
        case .hot:       return NSLocalizedString("vaultTag.hot",       value: "Hot",       comment: "Vault role tag")
        case .cold:      return NSLocalizedString("vaultTag.cold",      value: "Cold",      comment: "Vault role tag")
        case .operating: return NSLocalizedString("vaultTag.operating", value: "Operating", comment: "Vault role tag")
        case .personal:  return NSLocalizedString("vaultTag.personal",  value: "Personal",  comment: "Vault role tag")
        }
    }

    var color: Color {
        switch self {
        case .treasury:  return HorcruxTheme.accentPurple
        case .hot:       return HorcruxTheme.dangerRed
        case .cold:      return HorcruxTheme.accentCyan
        case .operating: return HorcruxTheme.warningAmber
        case .personal:  return HorcruxTheme.successGreen
        }
    }

    var systemIcon: String {
        switch self {
        case .treasury:  return "building.columns.fill"
        case .hot:       return "flame.fill"
        case .cold:      return "snowflake"
        case .operating: return "gearshape.fill"
        case .personal:  return "person.fill"
        }
    }
}

/// Persists user-editable per-account display metadata — name, short notes,
/// and an optional `VaultTag` — keyed by accountId. Backed by UserDefaults
/// because this is non-sensitive presentation data; the canonical identity
/// remains the DKG group public key.
@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    @Published private(set) var names: [String: String] = [:]
    @Published private(set) var notes: [String: String] = [:]
    @Published private(set) var tags: [String: VaultTag] = [:]

    private let namesKey = "com.horcrux.account_names.v1"
    private let notesKey = "com.horcrux.account_notes.v1"
    private let tagsKey  = "com.horcrux.account_tags.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: namesKey),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            self.names = decoded
        }
        if let data = defaults.data(forKey: notesKey),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            self.notes = decoded
        }
        if let data = defaults.data(forKey: tagsKey),
           let decoded = try? JSONDecoder().decode([String: VaultTag].self, from: data) {
            self.tags = decoded
        }
    }

    // MARK: Name

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
        persistNames()
    }

    // MARK: Notes

    func note(for accountId: String) -> String? {
        notes[accountId]
    }

    func setNote(_ note: String, for accountId: String) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            notes.removeValue(forKey: accountId)
        } else {
            // Keep notes short — they render as a subtitle in the group header.
            notes[accountId] = String(trimmed.prefix(120))
        }
        persistNotes()
    }

    // MARK: Tag

    func tag(for accountId: String) -> VaultTag? {
        tags[accountId]
    }

    func setTag(_ tag: VaultTag?, for accountId: String) {
        if let tag {
            tags[accountId] = tag
        } else {
            tags.removeValue(forKey: accountId)
        }
        persistTags()
    }

    func clear(accountId: String) {
        names.removeValue(forKey: accountId)
        notes.removeValue(forKey: accountId)
        tags.removeValue(forKey: accountId)
        persistNames(); persistNotes(); persistTags()
    }

    private func persistNames() {
        guard let data = try? JSONEncoder().encode(names) else { return }
        defaults.set(data, forKey: namesKey)
    }

    private func persistNotes() {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        defaults.set(data, forKey: notesKey)
    }

    private func persistTags() {
        guard let data = try? JSONEncoder().encode(tags) else { return }
        defaults.set(data, forKey: tagsKey)
    }
}
