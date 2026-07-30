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

                EndpointSwitcher(chain: chain, draft: $draft)
                ChainFieldActions(chain: chain, draft: $draft)
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
        .onDisappear { commitDraft() }
    }

    // MARK: - Draft commit

    /// Pure decision function for commitDraft — extracted so it can be
    /// unit-tested without SwiftUI lifecycle dependencies.
    ///
    /// - Parameters:
    ///   - draft:  The current TextField value (may have leading/trailing whitespace).
    ///   - stored: The current value in ChainEndpointOverrides, or nil if none.
    /// - Returns: The trimmed URL to persist, or nil when draft already matches
    ///   storage and no write is needed. An empty return value means "clear".
    ///
    /// The `@Binding`-based fix in `EndpointSwitcher` and `ChainFieldActions`
    /// ensures draft and storage always move together, so this function should
    /// never receive a stale `draft` that differs from `stored` due to an
    /// external storage mutation. This pure function remains the authoritative
    /// guard against unnecessary writes.
    static func commitDecision(draft: String, stored: String?) -> String? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (stored ?? "") else { return nil }
        return trimmed
    }

    private func commitDraft() {
        if let value = Self.commitDecision(draft: draft, stored: overrides.url(for: chain)) {
            overrides.set(value, for: chain)
        }
    }
}
