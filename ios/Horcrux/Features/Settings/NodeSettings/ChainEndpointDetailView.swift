import SwiftUI

/// Owns the draft URL for a single chain, exposing mutations as methods that
/// update both the in-field draft and `ChainEndpointOverrides` atomically.
///
/// The invariant is structural, not conventional: because every override
/// mutation goes through these methods, and each method updates `draft` and
/// storage together, `commit()` can never resurrect a URL that `reset()` just
/// cleared. There is no way to leave the two out of sync.
final class ChainEndpointEditor: ObservableObject {
    let chain: Chain
    /// Current value displayed in the text field. Initialised from storage.
    /// Direct writes are for the TextField binding only; use the methods below
    /// for any programmatic mutation.
    @Published var draft: String

    init(chain: Chain) {
        self.chain = chain
        draft = ChainEndpointOverrides.shared.url(for: chain) ?? ""
    }

    // MARK: - Atomic mutations

    /// Select a known candidate URL. Updates draft and storage together.
    func select(url: String) {
        draft = url
        ChainEndpointOverrides.shared.set(url, for: chain)
    }

    /// Clear the override and reset draft to empty. Updates draft and storage together.
    func reset() {
        draft = ""
        ChainEndpointOverrides.shared.clear(chain)
    }

    /// Commit the current draft to storage if it differs from what is stored.
    /// Trims whitespace; an empty trimmed value clears the override.
    /// Call on form dismiss (`.onDisappear`) and Return key (`.onSubmit`).
    func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = ChainEndpointOverrides.shared.url(for: chain) ?? ""
        guard trimmed != stored else { return }
        ChainEndpointOverrides.shared.set(trimmed, for: chain)
        // Normalise the displayed value to its trimmed form.
        if draft != trimmed { draft = trimmed }
    }
}

struct ChainEndpointDetailView: View {
    let chain: Chain

    @ObservedObject private var config = NetworkConfig.shared
    /// Held for reactivity — see `ChainEndpointList.swift` for the rationale.
    @ObservedObject private var overrides = ChainEndpointOverrides.shared

    // MARK: - Draft-URL design
    //
    // Why not direct binding (as NodeProviderSection does for API keys):
    // Binding directly would persist every keystroke as a live RPC endpoint,
    // breaking resolution while the user types "htt". API-key writes are
    // harmless mid-type (a half-key simply fails auth and falls through);
    // a half-typed URL is a live misconfiguration. So draft state is kept.
    //
    // ChainEndpointEditor owns the draft and exposes mutations as atomic
    // methods (select/reset/commit). The invariant is structural: any
    // mutation of the stored override goes through the editor, so commit()
    // on .onDisappear can never find a stale draft and resurrect a cleared
    // override.
    @StateObject private var editor: ChainEndpointEditor

    init(chain: Chain) {
        self.chain = chain
        _editor = StateObject(wrappedValue: ChainEndpointEditor(chain: chain))
    }

    var body: some View {
        Form {
            Section(L10n.NodeSettings.effectiveEndpointSection) {
                let display = config.effectiveDisplayURL(for: chain)
                Text(display.url)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                if display.isKeyFallback {
                    // The override URL uses a {KEY} template but the API key
                    // slot is empty, so routing falls through to the public
                    // fallback. Without this label the user would see the
                    // paid-provider host above and believe their traffic was
                    // being routed through that provider when it is not.
                    Label(L10n.NodeSettings.overrideKeyMissing,
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(HorcruxTheme.warningAmber)
                }
                Text(L10n.NodeSettings.sourceLabel(config.endpointSource(for: chain).label))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Ethereum mainnet / Sepolia toggle. Only mainnet and Sepolia are
            // offered here — Polygon, Base, Arbitrum, etc. are independent
            // first-class chains now; offering them inside the Ethereum detail
            // would recreate the "two different Polygons" ambiguity this
            // provider-first design removes.
            if chain == .ethereum {
                Section(L10n.NodeSettings.networkPicker) {
                    Picker(L10n.NodeSettings.networkPicker, selection: $config.evmChainId) {
                        Text(L10n.NodeSettings.mainnet).tag(EVMNetwork.mainnet.rawValue)
                        Text(L10n.NodeSettings.sepolia).tag(EVMNetwork.sepolia.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("nodeSettings_ethereumNetworkPicker")
                }
            }

            Section(L10n.NodeSettings.customURLSection) {
                TextField(config.publicDefault(for: chain), text: $editor.draft)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("nodeSettings_overrideField")
                    .onSubmit { editor.commit() }

                Button(L10n.NodeSettings.useDefault) {
                    editor.reset()
                }
                .disabled(overrides.url(for: chain) == nil)

                EndpointSwitcher(editor: editor)
                ChainFieldActions(editor: editor)
            }

            // WebSocket endpoint for chains that support it (Ethereum, Solana).
            if chain == .ethereum || chain == .solana {
                Section {
                    WSSField(
                        url: chain == .ethereum ? $config.ethereumWSS : $config.solanaWSS,
                        kind: chain == .ethereum ? .evm : .solana
                    )
                }
            }

            Section {
                NodeStatusRow(chain: chain)
            }
        }
        .navigationTitle(chain.displayName)
        .onDisappear { editor.commit() }
    }
}
