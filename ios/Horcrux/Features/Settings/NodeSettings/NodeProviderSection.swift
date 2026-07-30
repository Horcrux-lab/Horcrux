import SwiftUI

/// Primary node configuration: pick a provider, paste one key, and see
/// exactly which chains that covers.
struct NodeProviderSection: View {
    @ObservedObject private var config = NetworkConfig.shared
    @ObservedObject private var chainOverrides = ChainEndpointOverrides.shared

    var body: some View {
        Section(L10n.NodeSettings.providerSection) {
            Picker(L10n.NodeSettings.providerPicker, selection: providerSelection) {
                Text(L10n.NodeSettings.providerPublicDefaults).tag(nil as NodeProvider?)
                ForEach(NodeProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider as NodeProvider?)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("nodeSettings_providerPicker")

            if let provider = config.activeProvider {
                // Direct binding — every keystroke writes through to NetworkConfig.
                // Matches SettingsView.swift:1040 and avoids two failure modes that
                // @State draftKey + .onSubmit introduces: (1) the key is lost if the
                // user navigates away before pressing return, and (2) lazy-row
                // .onAppear fires on scroll-back, silently discarding a typed draft.
                SecureField(L10n.NodeSettings.providerKeyLabel(provider.displayName),
                            text: keyBinding(for: provider))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("nodeSettings_providerKeyField")
            }

            Text(coverageSummary.formattedCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("nodeSettings_coverageLine")
        }
    }

    private var providerSelection: Binding<NodeProvider?> {
        Binding(get: { config.activeProvider },
                set: { config.activeProvider = $0 })
    }

    private func keyBinding(for provider: NodeProvider) -> Binding<String> {
        Binding(get: { config.apiKey(for: provider) },
                set: { config.setAPIKey($0, for: provider) })
    }

    private var coverageSummary: ProviderCoverageSummary {
        let provider = config.activeProvider
        return ProviderCoverageSummary(
            provider: provider,
            hasKey: provider.map { !config.apiKey(for: $0).isEmpty } ?? false,
            overriddenChains: chainOverrides.allChains(),
            evmChainId: config.evmChainId,
            solanaMainnet: !config.solDevnet)
    }
}

