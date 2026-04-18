import Foundation
import Combine

/// A saved contact: label + address + chain scope.
/// Persisted as JSON in UserDefaults. Addresses are stored canonicalized.
struct AddressBookEntry: Identifiable, Codable, Hashable {
    let id: UUID
    var label: String
    var address: String
    var chain: Chain
    var note: String?
    var createdAt: Date

    init(id: UUID = UUID(), label: String, address: String, chain: Chain, note: String? = nil, createdAt: Date = .now) {
        self.id = id
        self.label = label
        self.address = address
        self.chain = chain
        self.note = note
        self.createdAt = createdAt
    }
}

/// In-memory store that syncs to UserDefaults on every mutation.
/// Keep this lightweight — contacts are not sensitive, but they are personal.
@MainActor
final class AddressBookStore: ObservableObject {
    static let shared = AddressBookStore()
    private static let storageKey = "addressBook.v1"

    @Published private(set) var entries: [AddressBookEntry] = []

    private init() {
        load()
    }

    func add(_ entry: AddressBookEntry) {
        entries.append(entry)
        save()
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func update(_ entry: AddressBookEntry) {
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx] = entry
            save()
        }
    }

    func entries(for chain: Chain) -> [AddressBookEntry] {
        entries.filter { $0.chain == chain }
    }

    /// Export all entries to pretty-printed JSON data suitable for sharing.
    func exportJSON() -> Data? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? enc.encode(entries)
    }

    /// Import entries from JSON. Deduplicates by (chain, address lowercased)
    /// — existing entries take precedence. Returns count imported.
    @discardableResult
    func importJSON(_ data: Data) throws -> Int {
        let incoming = try JSONDecoder().decode([AddressBookEntry].self, from: data)
        var known = Set(entries.map { "\($0.chain.rawValue)|\($0.address.lowercased())" })
        var added = 0
        for entry in incoming {
            let key = "\(entry.chain.rawValue)|\(entry.address.lowercased())"
            if known.contains(key) { continue }
            entries.append(entry)
            known.insert(key)
            added += 1
        }
        if added > 0 { save() }
        return added
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey) else { return }
        if let decoded = try? JSONDecoder().decode([AddressBookEntry].self, from: data) {
            entries = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
