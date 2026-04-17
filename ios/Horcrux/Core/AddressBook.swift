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
