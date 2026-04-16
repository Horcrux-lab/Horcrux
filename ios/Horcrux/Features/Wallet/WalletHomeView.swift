import SwiftUI

private enum UXTiming {
    static let clipboardFeedback: TimeInterval = 2.0
    static let retryButtonReset: TimeInterval = 3.0
}

/// Wallet home screen — shows all wallets with balances and quick actions.
struct WalletHomeView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showCreateShard = false
    @State private var networkReachable: [Chain: Bool] = [:]
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 64
    @ScaledMetric(relativeTo: .title3) private var smallIconSize: CGFloat = 28

    var body: some View {
        NavigationStack {
            Group {
                if appState.walletStore.wallets.isEmpty {
                    emptyState
                } else {
                    walletList
                }
            }
            .navigationTitle(L10n.WalletHome.title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showCreateShard = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .accessibilityLabel(L10n.WalletHome.createNewWallet)
                    .accessibilityHint(L10n.WalletHome.opensCreationFlow)
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
                        Text(offlineChains.contains(",")
                             ? L10n.WalletHome.nodesUnreachable(offlineChains)
                             : L10n.WalletHome.nodeUnreachable(offlineChains))
                            .font(.caption)
                    }
                    .foregroundStyle(.white)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(.orange.gradient)
                    .accessibilityLabel(L10n.WalletHome.networkWarning(offlineChains))
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: iconSize))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(L10n.WalletHome.noWalletsTitle)
                    .font(.title2.bold())
                Text(L10n.WalletHome.noWalletsSubtitle)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            Button {
                showCreateShard = true
            } label: {
                Label(L10n.WalletHome.createWallet, systemImage: "plus.circle.fill")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint(L10n.WalletHome.startMPCHint)
            .accessibilityIdentifier("walletHome_createWalletButton")

            Spacer()
        }
        .padding()
    }

    private var walletList: some View {
        List {
            // Pending broadcasts section
            if !appState.pendingBroadcastQueue.pending.isEmpty {
                Section {
                    ForEach(appState.pendingBroadcastQueue.pending) { tx in
                        PendingBroadcastRow(
                            transaction: tx,
                            onRetry: {
                                Task { await retryBroadcast(tx) }
                            },
                            onDiscard: {
                                appState.pendingBroadcastQueue.dequeue(id: tx.id)
                            }
                        )
                    }
                } header: {
                    Label(L10n.WalletHome.pendingBroadcasts, systemImage: "arrow.up.circle.badge.clock")
                }
            }

            ForEach(appState.walletStore.wallets) { wallet in
                NavigationLink {
                    WalletDetailView(wallet: wallet)
                } label: {
                    WalletRow(wallet: wallet)
                }
                .accessibilityLabel("\(wallet.name), \(wallet.chain.rawValue) wallet")
                .accessibilityHint(L10n.WalletHome.viewDetailsHint)
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
                    .accessibilityLabel(L10n.WalletHome.editWalletList)
            }
        }
    }

    private func retryBroadcast(_ tx: PendingBroadcastQueue.PendingTransaction) async {
        do {
            let result: String
            switch tx.chain {
            case .ethereum:
                result = try await appState.blockchainService.ethSendRawTransaction(
                    signedTxHex: tx.signedPayload, rpcURL: appState.networkConfig.ethereumRPC)
            case .bitcoin:
                result = try await appState.blockchainService.btcBroadcast(
                    signedTxHex: tx.signedPayload, apiURL: appState.networkConfig.bitcoinAPI)
            case .solana:
                result = try await appState.blockchainService.solSendTransaction(
                    signedTxBase64: tx.signedPayload, rpcURL: appState.networkConfig.solanaRPC)
            }
            appState.transactionStore.updateStatus(id: tx.id, status: .broadcast, txHash: result)
            appState.pendingBroadcastQueue.dequeue(id: tx.id)
        } catch {
            appState.pendingBroadcastQueue.markAttempt(id: tx.id, error: error.localizedDescription)
        }
    }
}

// MARK: - Pending Broadcast Row

struct PendingBroadcastRow: View {
    let transaction: PendingBroadcastQueue.PendingTransaction
    let onRetry: () -> Void
    let onDiscard: () -> Void
    @State private var isRetrying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ChainIcon(chain: transaction.chain, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(CurrencyFormatter.crypto(Double(transaction.amount) ?? 0, symbol: transaction.chain.symbol))
                        .font(.subheadline.bold())
                    Text("→ \(shortAddress(transaction.toAddress))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospaced()
                }
                Spacer()
                if isRetrying {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Button(L10n.Pending.retry, systemImage: "arrow.clockwise") {
                        isRetrying = true
                        onRetry()
                        DispatchQueue.main.asyncAfter(deadline: .now() + UXTiming.retryButtonReset) { isRetrying = false }
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .tint(.blue)
                }
            }
            if let error = transaction.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
            HStack {
                Text(L10n.Pending.attempts(transaction.attempts))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(L10n.Pending.discard, role: .destructive) { onDiscard() }
                    .font(.caption2)
            }
        }
        .padding(.vertical, 4)
    }

    private func shortAddress(_ address: String) -> String {
        guard address.count > 12 else { return address }
        return "\(address.prefix(6))…\(address.suffix(4))"
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
                        .accessibilityLabel(L10n.WalletHome.loadingBalance)
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
                .accessibilityLabel(L10n.Shards.thresholdValue(Int(wallet.threshold), Int(wallet.totalParties)))
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
    @ScaledMetric(relativeTo: .title3) private var smallIconSize: CGFloat = 28
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
                            .accessibilityLabel(L10n.WalletHome.loadingBalance)
                    } else if let balance {
                        Text(balance)
                            .font(.title2.bold())
                            .accessibilityLabel("Balance: \(balance)")
                            .accessibilityIdentifier("walletDetail_balance")
                    }

                    Text(wallet.address)
                        .font(.system(.caption, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .accessibilityLabel(L10n.WalletDetail.walletAddress)
                        .accessibilityValue(wallet.address)

                    Button {
                        SecureClipboard.copy(wallet.address)
                        copiedAddress = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + UXTiming.clipboardFeedback) { copiedAddress = false }
                    } label: {
                        Label(copiedAddress ? L10n.Receive.copiedClears(Int(SecureClipboard.defaultExpireSeconds)) : L10n.WalletDetail.copyAddress,
                              systemImage: copiedAddress ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                    }
                    .accessibilityLabel(copiedAddress ? L10n.WalletDetail.addressCopied : L10n.WalletDetail.copyWalletAddress)
                    .accessibilityHint(L10n.WalletDetail.copiesAddressHint)
                    .accessibilityIdentifier("walletDetail_copyAddressButton")

                    ShardStatusBadge(
                        threshold: wallet.threshold,
                        total: wallet.totalParties
                    )
                    .accessibilityLabel(L10n.Shards.shardThreshold(Int(wallet.threshold), Int(wallet.totalParties)))
                }
                .frame(maxWidth: .infinity)
                .padding()
            }

            Section(L10n.WalletDetail.actions) {
                Button {
                    showSigning = true
                } label: {
                    Label(L10n.WalletDetail.sendTransaction, systemImage: "arrow.up.circle.fill")
                }
                .accessibilityHint(L10n.WalletDetail.openSigningHint)
                .accessibilityIdentifier("walletDetail_sendButton")

                Button {
                    showReceive = true
                } label: {
                    Label(L10n.WalletDetail.receive, systemImage: "qrcode")
                }
                .accessibilityHint(L10n.WalletDetail.showQRHint)
                .accessibilityIdentifier("walletDetail_receiveButton")
            }

            // Token balances (ERC-20 / SPL)
            if wallet.chain != .bitcoin {
                Section(L10n.WalletDetail.tokens) {
                    if isLoadingTokens {
                        HStack {
                            ProgressView().scaleEffect(0.7)
                            Text(L10n.WalletDetail.loadingTokens).font(.caption).foregroundStyle(.secondary)
                        }
                    } else if tokenBalances.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "plus.circle")
                                .font(.system(size: smallIconSize))
                                .foregroundStyle(.tertiary)
                            Text(L10n.WalletDetail.noTokens)
                                .font(.subheadline.bold())
                                .foregroundStyle(.secondary)
                            Text(L10n.WalletDetail.noTokensDescription)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
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
                Section(L10n.WalletDetail.recentTransactions) {
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
                        Text(L10n.WalletDetail.viewAllHistory)
                            .font(.subheadline)
                            .foregroundStyle(.blue)
                    }
                }
            } else {
                Section(L10n.WalletDetail.transactions) {
                    NavigationLink {
                        TransactionHistoryView(wallet: wallet)
                    } label: {
                        Label(L10n.WalletDetail.transactionHistory, systemImage: "clock.arrow.circlepath")
                    }
                }
            }

            Section(L10n.WalletDetail.details) {
                LabeledContent(L10n.WalletDetail.chain, value: wallet.chain.rawValue)
                LabeledContent(L10n.WalletDetail.threshold, value: L10n.WalletDetail.thresholdValue(Int(wallet.threshold), Int(wallet.totalParties)))
                LabeledContent(L10n.WalletDetail.yourShard, value: L10n.WalletDetail.shardNumber(Int(wallet.partyIndex)))
                LabeledContent(L10n.WalletDetail.created, value: wallet.createdAt.formatted(date: .abbreviated, time: .shortened))
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
