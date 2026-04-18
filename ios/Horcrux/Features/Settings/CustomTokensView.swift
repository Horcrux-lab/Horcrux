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
                            title: "还没有自定义代币",
                            subtitle: "点右上角 + 添加合约地址",
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
                                            Label("删除", systemImage: "trash")
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
        .navigationTitle("自定义代币")
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
                Section("链") {
                    Picker("链", selection: $chain) {
                        ForEach(supportedChains, id: \.self) { c in
                            Text(c.rawValue).tag(c)
                        }
                    }
                }
                Section("合约地址") {
                    TextField(chain.isEVM ? "0x…" : (chain == .solana ? "mint 地址" : "T…"), text: $contract)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                        .accessibilityIdentifier("addToken_contract")
                }
                Section("元数据") {
                    TextField("符号 (USDT)", text: $symbol)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("addToken_symbol")
                    TextField("名称 (Tether USD)", text: $name)
                        .accessibilityIdentifier("addToken_name")
                    TextField("小数位 (18)", text: $decimalsText)
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
                            Text("自动查询链上元数据")
                        }
                    }
                    .disabled(contract.trimmingCharacters(in: .whitespaces).isEmpty || isResolving)
                    .accessibilityIdentifier("addToken_autofillButton")
                }
            }
            .navigationTitle("添加代币")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
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
                errorMsg = "自动查询仅支持 EVM 链"
            }
        } catch {
            errorMsg = "查询失败：\(error.localizedDescription)"
        }
    }
}
