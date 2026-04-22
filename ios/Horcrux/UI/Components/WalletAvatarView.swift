import SwiftUI

/// Small circular badge representing an MPC account. Falls back to a
/// monogram (first grapheme of the account label) when the user hasn't
/// picked an emoji yet. Color is deterministic from accountId so even
/// the fallback looks intentional.
struct WalletAvatarView: View {
    let accountId: String
    let fallbackText: String
    var size: CGFloat = 36

    @ObservedObject private var store = WalletAvatarStore.shared

    private var colorKey: String {
        store.avatar(for: accountId)?.colorKey ?? store.defaultColorKey(for: accountId)
    }

    private var monogram: String {
        String(fallbackText.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(store.gradient(for: colorKey))
                .overlay(
                    Circle().stroke(.white.opacity(0.15), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)

            if let emoji = store.avatar(for: accountId)?.emoji, !emoji.isEmpty {
                Text(emoji)
                    .font(.system(size: size * 0.52))
            } else {
                Text(monogram)
                    .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Sheet for customising a single account's avatar. Grid of emojis + a
/// swatch strip for palette colors. Dismisses on selection so the user
/// always sees the change applied immediately in the list behind the sheet.
struct WalletAvatarPickerSheet: View {
    let accountId: String
    let fallbackLabel: String
    var onDismiss: () -> Void = {}

    @ObservedObject private var store = WalletAvatarStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selectedEmoji: String?
    @State private var selectedColor: String = ""

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 6)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    previewBadge
                        .padding(.top, 8)

                    colorStrip

                    emojiGrid
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .background(HorcruxTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle(L10n.WalletAvatar.pickerTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.Common.cancel) { dismiss() }
                        .tint(HorcruxTheme.accentCyan)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.WalletAvatar.reset) {
                        store.clear(accountId: accountId)
                        selectedEmoji = nil
                        selectedColor = store.defaultColorKey(for: accountId)
                    }
                    .tint(HorcruxTheme.subtleText)
                }
            }
        }
        .onAppear {
            let existing = store.avatar(for: accountId)
            selectedEmoji = existing?.emoji
            selectedColor = existing?.colorKey ?? store.defaultColorKey(for: accountId)
        }
        .preferredColorScheme(.dark)
    }

    private var previewBadge: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(store.gradient(for: selectedColor))
                    .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                if let emoji = selectedEmoji, !emoji.isEmpty {
                    Text(emoji).font(.system(size: 52))
                } else {
                    Text(String(fallbackLabel.prefix(1)).uppercased())
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 96, height: 96)

            Text(fallbackLabel)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    private var colorStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.WalletAvatar.color)
                .font(.caption.weight(.semibold))
                .foregroundStyle(HorcruxTheme.subtleText)
            HStack(spacing: 12) {
                ForEach(WalletAvatarStore.palette, id: \.key) { entry in
                    Button {
                        Haptics.selection()
                        selectedColor = entry.key
                        persistIfNeeded()
                    } label: {
                        Circle()
                            .fill(store.gradient(for: entry.key))
                            .frame(width: 32, height: 32)
                            .overlay(
                                Circle()
                                    .stroke(.white, lineWidth: selectedColor == entry.key ? 2.5 : 0)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emojiGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.WalletAvatar.icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(HorcruxTheme.subtleText)
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(WalletAvatarStore.emojiChoices, id: \.self) { emoji in
                    Button {
                        Haptics.selection()
                        selectedEmoji = emoji
                        persistIfNeeded()
                    } label: {
                        Text(emoji)
                            .font(.system(size: 30))
                            .frame(width: 48, height: 48)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.white.opacity(selectedEmoji == emoji ? 0.18 : 0.06))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(HorcruxTheme.accentCyan, lineWidth: selectedEmoji == emoji ? 2 : 0)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func persistIfNeeded() {
        // Only persist once the user has picked at least an emoji; a
        // bare color change alone is also valid (use the monogram).
        store.set(
            .init(emoji: selectedEmoji ?? "", colorKey: selectedColor),
            for: accountId
        )
    }
}
