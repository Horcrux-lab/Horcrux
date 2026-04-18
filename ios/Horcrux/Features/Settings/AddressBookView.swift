import SwiftUI
import UniformTypeIdentifiers

/// User-facing address book management. Lists saved contacts, supports add/edit/delete.
struct AddressBookView: View {
    @StateObject private var store = AddressBookStore.shared
    @State private var showAdd = false
    @State private var editing: AddressBookEntry?
    @State private var showImporter = false
    @State private var exportDoc: AddressBookDocument?
    @State private var showExporter = false
    @State private var importResult: String?

    var body: some View {
        List {
            if store.entries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text(L10n.AddressBook.empty)
                        .font(.headline)
                    Text(L10n.AddressBook.emptyHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .listRowBackground(Color.clear)
            } else {
                ForEach(Chain.allCases) { chain in
                    let entries = store.entries(for: chain)
                    if !entries.isEmpty {
                        Section(chain.rawValue) {
                            ForEach(entries) { entry in
                                Button {
                                    editing = entry
                                } label: {
                                    AddressBookRow(entry: entry)
                                }
                                .buttonStyle(.plain)
                            }
                            .onDelete { idx in
                                idx.forEach { i in store.remove(entries[i].id) }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(L10n.AddressBook.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showAdd = true
                    } label: { Label(L10n.AddressBook.newContact, systemImage: "person.badge.plus") }
                    Button {
                        if let data = store.exportJSON() {
                            exportDoc = AddressBookDocument(data: data)
                            showExporter = true
                        }
                    } label: { Label(L10n.AddressBook.export, systemImage: "square.and.arrow.up") }
                        .disabled(store.entries.isEmpty)
                    Button {
                        showImporter = true
                    } label: { Label(L10n.AddressBook.importLabel, systemImage: "square.and.arrow.down") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .accessibilityIdentifier("addressBook_menu")
                }
            }
        }
        .sheet(isPresented: $showAdd) {
            AddressBookEditor(store: store)
        }
        .sheet(item: $editing) { entry in
            AddressBookEditor(store: store, existing: entry)
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.json]
        ) { result in
            switch result {
            case .success(let url):
                // Security-scoped URL: must request access for user-picked files.
                let gotAccess = url.startAccessingSecurityScopedResource()
                defer { if gotAccess { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    let n = try store.importJSON(data)
                    importResult = n > 0 ? L10n.AddressBook.importedCount(n) : L10n.AddressBook.allExisted
                } catch {
                    importResult = L10n.AddressBook.importFailed(error.localizedDescription)
                }
            case .failure(let err):
                importResult = err.localizedDescription
            }
        }
        .fileExporter(
            isPresented: $showExporter,
            document: exportDoc,
            contentType: .json,
            defaultFilename: "horcrux-addressbook"
        ) { _ in }
        .alert(L10n.AddressBook.importResultTitle, isPresented: .constant(importResult != nil)) {
            Button("OK") { importResult = nil }
        } message: {
            Text(importResult ?? "")
        }
    }
}

/// Minimal FileDocument wrapper so SwiftUI's `.fileExporter` can write the
/// JSON blob to a user-chosen location.
struct AddressBookDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct AddressBookRow: View {
    let entry: AddressBookEntry
    var body: some View {
        HStack(spacing: 12) {
            ChainIcon(chain: entry.chain, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.label).font(.headline)
                Text(entry.address)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }
}

struct AddressBookEditor: View {
    @ObservedObject var store: AddressBookStore
    var existing: AddressBookEntry?
    @Environment(\.dismiss) private var dismiss

    @State private var label: String = ""
    @State private var address: String = ""
    @State private var chain: Chain = .ethereum
    @State private var note: String = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.AddressBook.contactSection) {
                    TextField(L10n.AddressBook.labelPlaceholder, text: $label)
                    Picker(L10n.AddressBook.chainPickerLabel, selection: $chain) {
                        ForEach(Chain.allCases) { c in
                            Text(c.rawValue).tag(c)
                        }
                    }
                    TextField(L10n.AddressBook.addressPlaceholder, text: $address)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField(L10n.AddressBook.notePlaceholder, text: $note)
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .navigationTitle(existing == nil ? L10n.AddressBook.navNew : L10n.AddressBook.navEdit)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.AddressBook.saveButton) { save() }.disabled(label.isEmpty || address.isEmpty)
                }
            }
            .onAppear {
                if let e = existing {
                    label = e.label; address = e.address; chain = e.chain; note = e.note ?? ""
                }
            }
        }
    }

    private func save() {
        if let msg = AddressValidator.errorMessage(for: address, chain: chain) {
            error = msg
            return
        }
        if var e = existing {
            e.label = label; e.address = address; e.chain = chain; e.note = note.isEmpty ? nil : note
            store.update(e)
        } else {
            store.add(.init(label: label, address: address, chain: chain, note: note.isEmpty ? nil : note))
        }
        dismiss()
    }
}

/// Lightweight picker used inside ComposeTransactionView — presents entries
/// for the active chain and returns the selected address.
struct AddressBookPicker: View {
    @StateObject private var store = AddressBookStore.shared
    @Environment(\.dismiss) private var dismiss
    let chain: Chain
    let onPick: (AddressBookEntry) -> Void

    var body: some View {
        NavigationStack {
            let entries = store.entries(for: chain)
            List {
                if entries.isEmpty {
                    Text(L10n.AddressBook.emptyOnChain)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(entries) { entry in
                        Button {
                            onPick(entry)
                            dismiss()
                        } label: {
                            AddressBookRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle(L10n.AddressBook.pickContactTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.cancel) { dismiss() }
                }
            }
        }
    }
}
