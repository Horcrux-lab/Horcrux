import SwiftUI

/// Primary node configuration: pick a provider, paste one key, and see
/// exactly which chains that covers.
struct NodeProviderSection: View {
    @ObservedObject private var config = NetworkConfig.shared

    var body: some View {
        Section("Node provider") {
            Picker("Provider", selection: providerSelection) {
                Text("Public defaults").tag(nil as NodeProvider?)
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
                SecureField("\(provider.displayName) API key", text: keyBinding(for: provider))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("nodeSettings_providerKeyField")

                Text(coverageText(for: provider))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("nodeSettings_coverageLine")
            } else {
                Text("Every chain uses its public endpoint. Add a provider key for a dedicated rate limit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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

    /// Names the gaps explicitly. A user who binds a key and assumes it
    /// covers everything, when it does not, has no reason to look again —
    /// so the silent gap is worse than having no key at all.
    private func coverageText(for provider: NodeProvider) -> String {
        if config.apiKey(for: provider).isEmpty {
            return "No key set — using public endpoints."
        }
        let uncovered = provider.uncoveredChains(evmChainId: config.evmChainId,
                                                 solanaMainnet: !config.solDevnet)
        let covered = Chain.allCases.count - uncovered.count
        if uncovered.isEmpty {
            return "\(provider.displayName) covers all \(Chain.allCases.count) chains."
        }
        let names = uncovered
            .sorted { $0.displayName < $1.displayName }
            .map(\.displayName)
            .joined(separator: ", ")
        return "\(provider.displayName) covers \(covered) of \(Chain.allCases.count) chains. "
            + "\(names) stay on public endpoints."
    }
}
