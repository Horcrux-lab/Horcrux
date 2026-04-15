import SwiftUI

/// Wallet home screen — shows all wallets with balances and quick actions.
struct WalletHomeView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showCreateShard = false
    @State private var networkReachable: [Chain: Bool] = [:]

    var body: some View {
        NavigationStack {
            Group {
                if appState.walletStore.wallets.isEmpty {
                    emptyState
                } else {
                    walletList
                }
            }
            .navigationTitle("Horcrux")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showCreateShard = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .accessibilityLabel("Create new wallet")
                    .accessibilityHint("Opens the wallet creation flow")
                    .accessibilityIdentifier("walletHome_createButton")
                }
            }
            .sheet(isPresented: $showCreateShard) {
                CreateShardFlow()
            }
            .task {
                networkReachable = await NetworkStatus.shared.checkAll(config: appState.networkConfig)
            }
            .safeAreaInset(edge: .top) {
                if !networkReachable.isEmpty, networkReachable.values.contains(false) {
                    let offlineChains = networkReachable.filter { !$0.value }.map(\.key.symbol).sorted().joined(separator: ", ")
                    HStack(spacing: 6) {
                        Image(systemName: "wifi.slash")
                            .font(.caption)
                        Text("\(offlineChains) node\(offlineChains.contains(",") ? "s" : "") unreachable")
                            .font(.caption)
                    }
                    .foregroundStyle(.white)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(.orange.gradient)
                    .accessibilityLabel("Network warning: \(offlineChains) nodes are unreachable")
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("No Wallets Yet")
                    .font(.title2.bold())
                Text("Create your first MPC wallet by\nsplitting a key across devices.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            Button {
                showCreateShard = true
            } label: {
                Label("Create Wallet", systemImage: "plus.circle.fill")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Start the multi-party key generation process")
            .accessibilityIdentifier("walletHome_createWalletButton")

            Spacer()
        }
        .padding()
    }

    private var walletList: some View {
        List {
            ForEach(appState.walletStore.wallets) { wallet in
                NavigationLink {
                    WalletDetailView(wallet: wallet)
                } label: {
                    WalletRow(wallet: wallet)
                }
                .accessibilityLabel("\(wallet.name), \(wallet.chain.rawValue) wallet")
                .accessibilityHint("View wallet details, send, and receive")
                .accessibilityIdentifier("walletHome_walletRow_\(wallet.id)")
            }
            .onDelete { indexSet in
                for index in indexSet {
                    appState.walletStore.remove(id: appState.walletStore.wallets[index].id)
                }
            }
            .onMove { source, destination in
                appState.walletStore.move(from: source, to: destination)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                EditButton()
                    .accessibilityLabel("Edit wallet list")
            }
        }
    }
}

struct WalletRow: View {
    let wallet: Wallet
    @EnvironmentObject private var appState: AppState
    @State private var balance: String?
    @State private var isLoading = false

    var body: some View {
        HStack(spacing: 12) {
            ChainIcon(chain: wallet.chain, size: 44)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(wallet.name)
                    .font(.headline)

                Text(shortAddress(wallet.address))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospaced()
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                        .accessibilityLabel("Loading balance")
                } else if let balance {
                    Text(balance)
                        .font(.subheadline.bold())
                        .accessibilityLabel("Balance: \(balance)")
                } else {
                    Text(wallet.chain.symbol)
                        .font(.subheadline.bold())
                }

                ShardStatusBadge(
                    threshold: wallet.threshold,
                    total: wallet.totalParties
                )
                .accessibilityLabel("\(wallet.threshold) of \(wallet.totalParties) threshold")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .task {
            await fetchBalance()
        }
    }

    private func fetchBalance() async {
        isLoading = true
        defer { isLoading = false }
        do {
            balance = try await appState.blockchainService.balance(
                for: wallet,
                config: appState.networkConfig
            )
        } catch {
            balance = wallet.chain.symbol
        }
    }

    private func shortAddress(_ address: String) -> String {
        guard address.count > 12 else { return address }
        let prefix = address.prefix(6)
        let suffix = address.suffix(4)
        return "\(prefix)…\(suffix)"
    }
}

struct WalletDetailView: View {
    @EnvironmentObject private var appState: AppState
    let wallet: Wallet
    @State private var showSigning = false
    @State private var showReceive = false
    @State private var balance: String?
    @State private var isLoadingBalance = false
    @State private var copiedAddress = false
    @State private var tokenBalances: [TokenBalance] = []
    @State private var isLoadingTokens = false

    var body: some View {
        List {
            Section {
                VStack(spacing: 16) {
                    ChainIcon(chain: wallet.chain, size: 64)
                        .accessibilityHidden(true)

                    if isLoadingBalance {
                        ProgressView()
                            .accessibilityLabel("Loading balance")
                    } else if let balance {
                        Text(balance)
                            .font(.title2.bold())
                            .accessibilityLabel("Balance: \(balance)")
                            .accessibilityIdentifier("walletDetail_balance")
                    }

                    Text(wallet.address)
                        .font(.system(.caption, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .accessibilityLabel("Wallet address")
                        .accessibilityValue(wallet.address)

                    Button {
                        SecureClipboard.copy(wallet.address)
                        copiedAddress = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedAddress = false }
                    } label: {
                        Label(copiedAddress ? "Copied (clears in 60s)" : "Copy Address",
                              systemImage: copiedAddress ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                    }
                    .accessibilityLabel(copiedAddress ? "Address copied" : "Copy wallet address")
                    .accessibilityHint("Copies the wallet address to clipboard")
                    .accessibilityIdentifier("walletDetail_copyAddressButton")

                    ShardStatusBadge(
                        threshold: wallet.threshold,
                        total: wallet.totalParties
                    )
                    .accessibilityLabel("\(wallet.threshold) of \(wallet.totalParties) shard threshold")
                }
                .frame(maxWidth: .infinity)
                .padding()
            }

            Section("Actions") {
                Button {
                    showSigning = true
                } label: {
                    Label("Send Transaction", systemImage: "arrow.up.circle.fill")
                }
                .accessibilityHint("Open the transaction signing flow")
                .accessibilityIdentifier("walletDetail_sendButton")

                Button {
                    showReceive = true
                } label: {
                    Label("Receive", systemImage: "qrcode")
                }
                .accessibilityHint("Show your QR code and address to receive funds")
                .accessibilityIdentifier("walletDetail_receiveButton")
            }

            // Token balances (ERC-20 / SPL)
            if wallet.chain != .bitcoin {
                Section("Tokens") {
                    if isLoadingTokens {
                        HStack {
                            ProgressView().scaleEffect(0.7)
                            Text("Loading tokens…").font(.caption).foregroundStyle(.secondary)
                        }
                    } else if tokenBalances.isEmpty {
                        Text("No token balances found")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(tokenBalances) { tb in
                            HStack {
                                Text(tb.token.symbol)
                                    .font(.subheadline.bold())
                                Spacer()
                                Text(tb.displayBalance)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            // Recent transactions
            let recentTxs = appState.transactionStore.records(for: wallet.id).prefix(5)
            if !recentTxs.isEmpty {
                Section("Recent Transactions") {
                    ForEach(Array(recentTxs)) { tx in
                        NavigationLink {
                            TransactionDetailView(transaction: tx)
                        } label: {
                            TransactionRow(transaction: tx)
                        }
                    }

                    NavigationLink {
                        TransactionHistoryView(wallet: wallet)
                    } label: {
                        Text("View All History")
                            .font(.subheadline)
                            .foregroundStyle(.blue)
                    }
                }
            } else {
                Section("Transactions") {
                    NavigationLink {
                        TransactionHistoryView(wallet: wallet)
                    } label: {
                        Label("Transaction History", systemImage: "clock.arrow.circlepath")
                    }
                }
            }

            Section("Details") {
                LabeledContent("Chain", value: wallet.chain.rawValue)
                LabeledContent("Threshold", value: "\(wallet.threshold) of \(wallet.totalParties)")
                LabeledContent("Your Shard", value: "#\(wallet.partyIndex)")
                LabeledContent("Created", value: wallet.createdAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .navigationTitle(wallet.name)
        .sheet(isPresented: $showSigning) {
            SigningView(wallet: wallet)
        }
        .sheet(isPresented: $showReceive) {
            ReceiveView(wallet: wallet)
        }
        .task {
            await fetchBalance()
            await fetchTokenBalances()
        }
        .refreshable {
            await fetchBalance()
            await fetchTokenBalances()
        }
    }

    private func fetchBalance() async {
        isLoadingBalance = true
        defer { isLoadingBalance = false }
        do {
            balance = try await appState.blockchainService.balance(
                for: wallet,
                config: appState.networkConfig
            )
        } catch {
            balance = nil
        }
    }

    private func fetchTokenBalances() async {
        guard wallet.chain != .bitcoin else { return }
        isLoadingTokens = true
        defer { isLoadingTokens = false }
        tokenBalances = await appState.blockchainService.tokenBalances(
            for: wallet,
            config: appState.networkConfig
        )
    }
}
