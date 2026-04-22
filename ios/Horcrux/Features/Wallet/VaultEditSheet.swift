import SwiftUI

/// Modal sheet that lets the user rename an account, attach a short note,
/// and pick a role tag. All three fields are optional — empty values clear
/// the respective store entry. Identity is the DKG group public key
/// (accountId); nothing here touches the MPC material.
struct VaultEditSheet: View {
    let accountId: String
    /// Deterministic fallback name shown in the TextField placeholder when
    /// the user has never customised this vault.
    let fallbackName: String

    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = AccountStore.shared

    @State private var name: String = ""
    @State private var note: String = ""
    @State private var tag: VaultTag? = nil
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(fallbackName, text: $name)
                        .focused($nameFocused)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .accessibilityIdentifier("vaultEdit_nameField")
                } header: {
                    Text(NSLocalizedString("vaultEdit.nameHeader", value: "NAME", comment: "Vault edit: name field header"))
                } footer: {
                    Text(NSLocalizedString("vaultEdit.nameFooter",
                                           value: "Leave empty to restore the default label.",
                                           comment: "Vault edit: name field footer hint"))
                }

                Section {
                    TextField(NSLocalizedString("vaultEdit.notePlaceholder",
                                                value: "e.g. quarterly rebalance, signers: A, B",
                                                comment: "Vault edit: note placeholder"),
                              text: $note, axis: .vertical)
                        .lineLimit(2...4)
                        .accessibilityIdentifier("vaultEdit_noteField")
                    // Character counter — notes are capped at 120 chars.
                    HStack {
                        Spacer()
                        Text("\(note.count)/120")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(note.count >= 120 ? HorcruxTheme.dangerRed : HorcruxTheme.subtleText)
                    }
                } header: {
                    Text(NSLocalizedString("vaultEdit.noteHeader", value: "NOTE", comment: "Vault edit: note field header"))
                } footer: {
                    Text(NSLocalizedString("vaultEdit.noteFooter",
                                           value: "Shown as a subtitle under the vault name. Up to 120 characters.",
                                           comment: "Vault edit: note field footer hint"))
                }

                Section {
                    tagPicker
                } header: {
                    Text(NSLocalizedString("vaultEdit.tagHeader", value: "TAG", comment: "Vault edit: tag picker header"))
                } footer: {
                    Text(NSLocalizedString("vaultEdit.tagFooter",
                                           value: "Optional colored chip identifying this vault's role.",
                                           comment: "Vault edit: tag footer hint"))
                }
            }
            .scrollContentBackground(.hidden)
            .background(HorcruxTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle(NSLocalizedString("vaultEdit.title",
                                               value: "Edit Vault",
                                               comment: "Vault edit sheet title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("common.cancel", value: "Cancel", comment: "")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("common.save", value: "Save", comment: "")) {
                        save()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                name = store.names[accountId] ?? ""
                note = store.note(for: accountId) ?? ""
                tag  = store.tag(for: accountId)
                // Tiny delay so the text field actually focuses after the sheet
                // transition — otherwise the keyboard fights the presentation.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    nameFocused = true
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    private var tagPicker: some View {
        // Wrapped chip layout: 2 columns feel right on an iPhone form row.
        let columns = [GridItem(.adaptive(minimum: 120), spacing: 8)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            tagChip(nil, label: NSLocalizedString("vaultEdit.tagNone",
                                                  value: "None",
                                                  comment: "Vault tag: clear selection"),
                    icon: "circle.dashed",
                    color: HorcruxTheme.subtleText)
            ForEach(VaultTag.allCases) { t in
                tagChip(t, label: t.displayName, icon: t.systemIcon, color: t.color)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func tagChip(_ value: VaultTag?, label: String, icon: String, color: Color) -> some View {
        let isSelected = (tag == value)
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { tag = value }
            Haptics.selection()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                Text(label)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.heavy))
                }
            }
            .foregroundStyle(isSelected ? color : HorcruxTheme.subtleText)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? color.opacity(0.18) : HorcruxTheme.cardSurface.opacity(0.35))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? color.opacity(0.6) : HorcruxTheme.cardBorder.opacity(0.4), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("vaultEdit_tagChip_\(value?.rawValue ?? "none")")
    }

    private func save() {
        store.setName(name, for: accountId)
        store.setNote(note, for: accountId)
        store.setTag(tag, for: accountId)
    }
}
