import SwiftUI

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
    // Two bugs the original @State draft + .onSubmit + .onAppear pattern
    // introduces (see the comment in NodeProviderSection.swift):
    //
    // 1. Input lost on navigate-back without pressing Return:
    //    Fixed by committing in .onDisappear as well as .onSubmit.
    //
    // 2. Lazy-row re-appear clobbering in-progress input via .onAppear:
    //    Fixed by seeding via State(initialValue:) in init. SwiftUI only
    //    honours the initialValue the first time the view is composed at
    //    its identity position in the tree; subsequent re-appears leave the
    //    state untouched. ChainEndpointDetailView is a full-screen Form
    //    pushed by NavigationStack, not a lazy-list row, so the
    //    "scroll-away and back recreates the row" scenario does not apply —
    //    but init-based seeding removes the dependency on that assumption.
    //
    // Whitespace:
    // ChainEndpointOverrides.set already trims and treats an
    // empty/whitespace-only string as a clear. We trim explicitly in
    // commitDraft so the contract is visible at the call site rather than
    // being a silent side effect of the store.
    @State private var draft: String

    init(chain: Chain) {
        self.chain = chain
        _draft = State(initialValue: ChainEndpointOverrides.shared.url(for: chain) ?? "")
    }

    var body: some View {
        Form {
            Section(L10n.NodeSettings.effectiveEndpointSection) {
                Text(config.resolveRawURL(for: chain))
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                Text(L10n.NodeSettings.sourceLabel(config.endpointSource(for: chain).label))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.NodeSettings.customURLSection) {
                TextField(config.publicDefault(for: chain), text: $draft)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("nodeSettings_overrideField")
                    .onSubmit { commitDraft() }

                Button(L10n.NodeSettings.useDefault) {
                    draft = ""
                    overrides.clear(chain)
                }
                .disabled(overrides.url(for: chain) == nil)
            }

            Section {
                NodeStatusRow(chain: chain)
            }
        }
        .navigationTitle(chain.displayName)
        .onDisappear { commitDraft() }
    }

    private func commitDraft() {
        // Trim explicitly so callers see the behaviour rather than relying
        // on ChainEndpointOverrides.set treating whitespace-only as a clear.
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Skip the write when nothing has changed: set("") routes to clear →
        // mutate → UserDefaults write + objectWillChange, re-rendering all
        // fourteen badges even for an untouched row.
        guard trimmed != (overrides.url(for: chain) ?? "") else { return }
        overrides.set(trimmed, for: chain)
    }
}
