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
                    Text("还没有联系人")
                        .font(.headline)
                    Text("添加常用地址后，签名时可以一键填入并减少输错的风险。")
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
        .navigationTitle("地址簿")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showAdd = true
                    } label: { Label("新建联系人", systemImage: "person.badge.plus") }
                    Button {
                        if let data = store.exportJSON() {
                            exportDoc = AddressBookDocument(data: data)
                            showExporter = true
                        }
                    } label: { Label("导出", systemImage: "square.and.arrow.up") }
                        .disabled(store.entries.isEmpty)
                    Button {
                        showImporter = true
                    } label: { Label("导入", systemImage: "square.and.arrow.down") }
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
                    importResult = n > 0 ? "已导入 \(n) 条" : "全部已存在"
                } catch {
                    importResult = "导入失败：\(error.localizedDescription)"
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
        .alert("导入结果", isPresented: .constant(importResult != nil)) {
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
                Section("联系人") {
                    TextField("标签（如：Binance 主钱包）", text: $label)
                    Picker("链", selection: $chain) {
                        ForEach(Chain.allCases) { c in
                            Text(c.rawValue).tag(c)
                        }
                    }
                    TextField("地址", text: $address)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("备注（可选）", text: $note)
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .navigationTitle(existing == nil ? "新建联系人" : "编辑联系人")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(label.isEmpty || address.isEmpty)
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
                    Text("这条链上还没有保存的联系人。")
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
            .navigationTitle("选择联系人")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}
