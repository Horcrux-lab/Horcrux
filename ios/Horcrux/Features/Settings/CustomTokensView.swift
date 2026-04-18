import SwiftUI

/// Lets the user add / remove ERC-20 or SPL custom tokens. Persisted in
/// `CustomTokenStore` (merged into token list reads at runtime).
struct CustomTokensView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showAddSheet = false

    var body: some View {
        ZStack {
            HorcruxTheme.backgroundGradient.ignoresSafeArea()

            List {
                if appState.customTokenStore.tokens.isEmpty {
                    Section {
                        VaultEmptyState(
                            icon: "plus.circle",
                            title: L10n.CustomTokens.emptyTitle,
                            subtitle: L10n.CustomTokens.emptyHint,
                            iconSize: 40
                        )
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                    }
                } else {
                    ForEach(Chain.allCases, id: \.self) { chain in
                        let byChain = appState.customTokenStore.tokens.filter { $0.chain == chain }
                        if !byChain.isEmpty {
                            Section(chain.rawValue) {
                                ForEach(byChain, id: \.id) { token in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(token.symbol).font(.headline).foregroundStyle(.white)
                                            Spacer()
                                            Text("\(token.decimals) decimals")
                                                .font(.caption)
                                                .foregroundStyle(HorcruxTheme.subtleText)
                                        }
                                        Text(token.name).font(.caption).foregroundStyle(HorcruxTheme.subtleText)
                                        Text(token.id)
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(HorcruxTheme.subtleText)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    .listRowBackground(HorcruxTheme.cardSurface)
                                    .swipeActions {
                                        Button(role: .destructive) {
                                            appState.customTokenStore.remove(token)
                                        } label: {
                                            Label(L10n.CustomTokens.deleteLabel, systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(L10n.CustomTokens.navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                        .accessibilityIdentifier("customTokens_addButton")
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddCustomTokenSheet()
                .environmentObject(appState)
        }
    }
}

private struct AddCustomTokenSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var chain: Chain = .ethereum
    @State private var contract: String = ""
    @State private var symbol: String = ""
    @State private var name: String = ""
    @State private var decimalsText: String = "18"
    @State private var errorMsg: String?
    @State private var isResolving = false

    // Token-capable chains: EVM, Solana, TRON.
    private var supportedChains: [Chain] {
        Chain.allCases.filter { $0.isEVM || $0 == .solana || $0 == .tron }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.CustomTokens.chainSection) {
                    Picker(L10n.CustomTokens.chainPickerLabel, selection: $chain) {
                        ForEach(supportedChains, id: \.self) { c in
                            Text(c.rawValue).tag(c)
                        }
                    }
                }
                Section(L10n.CustomTokens.contractSection) {
                    TextField(chain.isEVM ? "0x…" : (chain == .solana ? L10n.CustomTokensExtra.solanaMintPlaceholder : "T…"), text: $contract)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                        .accessibilityIdentifier("addToken_contract")
                }
                Section(L10n.CustomTokens.metadataSection) {
                    TextField(L10n.CustomTokens.symbolPlaceholder, text: $symbol)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("addToken_symbol")
                    TextField(L10n.CustomTokens.namePlaceholder, text: $name)
                        .accessibilityIdentifier("addToken_name")
                    TextField(L10n.CustomTokens.decimalsPlaceholder, text: $decimalsText)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("addToken_decimals")
                }
                if let errorMsg {
                    Section { Text(errorMsg).foregroundStyle(.red).font(.caption) }
                }
                Section {
                    Button {
                        Task { await autofill() }
                    } label: {
                        HStack {
                            if isResolving { ProgressView().scaleEffect(0.7) }
                            Text(L10n.CustomTokens.autoResolve)
                        }
                    }
                    .disabled(contract.trimmingCharacters(in: .whitespaces).isEmpty || isResolving)
                    .accessibilityIdentifier("addToken_autofillButton")
                }
            }
            .navigationTitle(L10n.CustomTokens.addTokenTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.AddressBook.saveButton) { save() }
                        .disabled(!canSave)
                        .accessibilityIdentifier("addToken_saveButton")
                }
            }
        }
    }

    private var canSave: Bool {
        let c = contract.trimmingCharacters(in: .whitespaces)
        let s = symbol.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty, !s.isEmpty else { return false }
        guard let d = UInt8(decimalsText), d <= 36 else { return false }
        return true
    }

    private func save() {
        guard let dec = UInt8(decimalsText) else { return }
        let token = Token(
            id: contract.trimmingCharacters(in: .whitespaces),
            chain: chain,
            symbol: symbol.trimmingCharacters(in: .whitespaces),
            name: name.trimmingCharacters(in: .whitespaces).isEmpty
                ? symbol.trimmingCharacters(in: .whitespaces)
                : name,
            decimals: dec,
            iconURL: nil
        )
        appState.customTokenStore.add(token)
        dismiss()
    }

    private func autofill() async {
        isResolving = true
        defer { isResolving = false }
        errorMsg = nil
        let addr = contract.trimmingCharacters(in: .whitespaces)
        guard !addr.isEmpty else { return }
        do {
            if chain.isEVM {
                let meta = try await appState.blockchainService.erc20Metadata(
                    contract: addr,
                    rpcURL: appState.networkConfig.rpcURL(for: chain)
                )
                symbol = meta.symbol
                name = meta.name
                decimalsText = String(meta.decimals)
            } else {
                errorMsg = L10n.CustomTokens.errEvmOnly
            }
        } catch {
            errorMsg = L10n.CustomTokens.queryFailed(error.localizedDescription)
        }
    }
}
