import SwiftUI

private enum UXTiming {
    static let clipboardFeedback: TimeInterval = 2.0
    static let retryButtonReset: TimeInterval = 3.0
}

/// Wallet home screen — dark-tech card layout with balances and quick actions.
struct WalletHomeView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var walletStore: WalletStore
    @StateObject private var accountStore = AccountStore.shared
    @State private var showCreateShard = false
    @State private var showRestoreSheet = false
    @State private var networkReachable: [Chain: Bool] = [:]

    var body: some View {
        NavigationStack {
            ZStack {
                HorcruxTheme.backgroundGradient.ignoresSafeArea()

                Group {
                    if walletStore.wallets.isEmpty {
                        emptyState
                    } else {
                        walletList
                    }
                }
            }
            .navigationTitle(L10n.WalletHome.title)
            .navigationBarTitleDisplayMode(.large)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showCreateShard = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(HorcruxTheme.accentPurple)
                            .frame(width: 32, height: 32)
                            .background(HorcruxTheme.accentPurple.opacity(0.15), in: Circle())
                    }
                    .accessibilityLabel(L10n.WalletHome.createNewWallet)
                    .accessibilityHint(L10n.WalletHome.opensCreationFlow)
                    .accessibilityIdentifier("walletHome_createButton")
                }
            }
            .sheet(isPresented: $showCreateShard) {
                CreateShardFlow()
            }
            .sheet(isPresented: $showRestoreSheet) {
                AccountImportView(viewModel: ShardsViewModel())
            }
            .task {
                networkReachable = await NetworkStatus.shared.checkAll(config: appState.networkConfig)
            }
            .safeAreaInset(edge: .top) {
                if !networkReachable.isEmpty, networkReachable.values.contains(false) {
                    let offlineChains = networkReachable.filter { !$0.value }.map(\.key.symbol).sorted().joined(separator: ", ")
                    HStack(spacing: 8) {
                        Image(systemName: "wifi.slash")
                            .font(.caption.weight(.semibold))
                        Text(offlineChains.contains(",")
                             ? L10n.WalletHome.nodesUnreachable(offlineChains)
                             : L10n.WalletHome.nodeUnreachable(offlineChains))
                            .font(.caption)
                    }
                    .foregroundStyle(.white)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(HorcruxTheme.warningAmber.opacity(0.85).gradient)
                    .accessibilityLabel(L10n.WalletHome.networkWarning(offlineChains))
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            Spacer()

            VaultEmptyState(
                icon: "shield.lefthalf.filled",
                title: L10n.WalletHome.noWalletsTitle,
                subtitle: L10n.WalletHome.noWalletsSubtitle
            )

            VStack(spacing: 12) {
                Button {
                    showCreateShard = true
                } label: {
                    Label(L10n.WalletHome.createWallet, systemImage: "plus.circle.fill")
                }
                .buttonStyle(GradientButtonStyle())
                .accessibilityHint(L10n.WalletHome.startMPCHint)
                .accessibilityIdentifier("walletHome_createWalletButton")

                Button {
                    showRestoreSheet = true
                } label: {
                    Label("从备份恢复", systemImage: "square.and.arrow.down")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(HorcruxTheme.accentPurple)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(HorcruxTheme.accentPurple.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                }
                .accessibilityIdentifier("walletHome_restoreButton")
            }
            .padding(.horizontal, 48)

            Spacer()
        }
        .padding()
    }

    private var walletList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                // Portfolio summary (IA: root → chain → asset)
                PortfolioSummaryCard(wallets: walletStore.wallets)

                // Pending broadcasts
                if !appState.pendingBroadcastQueue.pending.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        VaultSectionHeader(L10n.WalletHome.pendingBroadcasts, icon: "arrow.up.circle.badge.clock")
                            .padding(.horizontal, 4)

                        ForEach(appState.pendingBroadcastQueue.pending) { tx in
                            PendingBroadcastRow(
                                transaction: tx,
                                onRetry: { Task { await retryBroadcast(tx) } },
                                onDiscard: { appState.pendingBroadcastQueue.dequeue(id: tx.id) }
                            )
                            .glassCard()
                        }
                    }
                    .padding(.bottom, 8)
                }

                // Wallets grouped by MPC account (same groupPublicKey → one account spanning multiple chains)
                ForEach(walletGroups, id: \.accountId) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        if walletGroups.count > 1 || group.wallets.count > 1 {
                            HStack(spacing: 6) {
                                Image(systemName: "key.horizontal")
                                    .font(.caption)
                                    .foregroundStyle(HorcruxTheme.accentPurple)
                                Text(group.label)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(HorcruxTheme.subtleText)
                                Spacer()
                                Text(L10n.Shards.thresholdValue(Int(group.wallets.first?.threshold ?? 0), Int(group.wallets.first?.totalParties ?? 0)))
                                    .font(.caption2)
                                    .foregroundStyle(HorcruxTheme.subtleText)
                            }
                            .padding(.horizontal, 6)
                        }

                        ForEach(group.wallets) { wallet in
                            NavigationLink {
                                WalletDetailView(wallet: wallet)
                            } label: {
                                WalletRow(wallet: wallet, showThresholdBadge: group.wallets.count == 1 && walletGroups.count == 1)
                            }
                            .accessibilityLabel("\(wallet.name), \(wallet.chain.rawValue) wallet")
                            .accessibilityHint(L10n.WalletHome.viewDetailsHint)
                            .accessibilityIdentifier("walletHome_walletRow_\(wallet.id)")
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
    }

    /// Group wallets by accountId (derived from groupPublicKey). Each group
    /// is a single MPC account; label is user-set via AccountStore with a
    /// deterministic fallback based on the first wallet's name (stripped of
    /// any "(SYMBOL)" chain suffix).
    private var walletGroups: [WalletGroup] {
        let wallets = walletStore.wallets
        let buckets = Dictionary(grouping: wallets, by: { $0.accountId })
        return buckets
            .map { (accountId, list) -> WalletGroup in
                let first = list.first!
                let fallback = first.name.replacingOccurrences(of: " (\(first.chain.symbol))", with: "")
                let label = accountStore.name(for: accountId, fallback: fallback)
                return WalletGroup(
                    accountId: accountId,
                    label: label,
                    wallets: list.sorted { $0.chain.rawValue < $1.chain.rawValue }
                )
            }
            .sorted { $0.label < $1.label }
    }

    private struct WalletGroup {
        let accountId: String
        let label: String
        let wallets: [Wallet]
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
            case .litecoin, .tron:
                // Broadcast not implemented — should never be reachable because
                // signing is blocked for these chains.
                throw BlockchainError.invalidURL("Broadcast not supported for \(tx.chain.rawValue)")
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
    @State private var showRBFInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ChainIcon(chain: transaction.chain, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(CurrencyFormatter.crypto(Double(transaction.amount) ?? 0, symbol: transaction.chain.symbol))
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                    Text("→ \(shortAddress(transaction.toAddress))")
                        .font(.caption)
                        .foregroundStyle(HorcruxTheme.subtleText)
                        .monospaced()
                }
                Spacer()
                if isRetrying {
                    ProgressView().scaleEffect(0.7).tint(HorcruxTheme.accentPurple)
                } else {
                    Button(L10n.Pending.retry, systemImage: "arrow.clockwise") {
                        isRetrying = true
                        onRetry()
                        DispatchQueue.main.asyncAfter(deadline: .now() + UXTiming.retryButtonReset) { isRetrying = false }
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(HorcruxTheme.accentBlue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(HorcruxTheme.accentBlue.opacity(0.15), in: Capsule())
                }
            }
            if let error = transaction.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(HorcruxTheme.dangerRed)
                    .lineLimit(1)
            }
            HStack(spacing: 10) {
                Text(L10n.Pending.attempts(transaction.attempts))
                    .font(.caption2)
                    .foregroundStyle(HorcruxTheme.subtleText)
                Spacer()
                // Speed-up / cancel buttons for stuck ETH transactions (RBF explainer)
                if transaction.chain == .ethereum {
                    Button {
                        showRBFInfo = true
                    } label: {
                        Label("加速", systemImage: "hare.fill")
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(HorcruxTheme.accentCyan)
                }
                Button(L10n.Pending.discard, role: .destructive) { onDiscard() }
                    .font(.caption2)
                    .foregroundStyle(HorcruxTheme.dangerRed)
            }
        }
        .sheet(isPresented: $showRBFInfo) {
            RBFInfoSheet(
                onCancel: {
                    onDiscard()
                    showRBFInfo = false
                }
            )
            .presentationDetents([.medium])
        }
    }

    private func shortAddress(_ address: String) -> String {
        guard address.count > 12 else { return address }
        return "\(address.prefix(6))…\(address.suffix(4))"
    }
}

/// Explains the RBF (Replace-By-Fee) concept for users whose ETH broadcasts are stuck,
/// and offers the one path we can safely take today: cancel the stuck tx, then re-sign
/// a new one with higher gas via the normal signing flow.
struct RBFInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label {
                        Text("加速被卡住的交易").font(.headline)
                    } icon: {
                        Image(systemName: "hare.fill").foregroundStyle(.cyan)
                    }
                    Text("这笔交易的矿工费可能偏低，导致节点一直不收录。在以太坊上，你可以通过“替换费用（RBF）”用同一个 nonce 发一笔更高矿工费的交易覆盖它。")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("目前可用的操作：").font(.subheadline.weight(.semibold))
                        bullet("丢弃当前待广播交易")
                        bullet("回到钱包重新发起签名，手动提高矿工费（gas price）至少 +10%")
                        bullet("下一版本会自动构建 RBF 替换交易，无需手动重签")
                    }
                    .font(.callout)

                    Button(role: .destructive, action: onCancel) {
                        Label("丢弃此交易并重新发起", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                            .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                .padding()
            }
            .navigationTitle("加速（RBF）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.cyan)
                .padding(.top, 4)
            Text(text)
        }
    }
}

struct WalletRow: View {
    let wallet: Wallet
    /// When true, render the N-of-M shard badge on the row. Usually false:
    /// the group header above the row already shows threshold, so rendering
    /// it again per row is redundant. Only shown for solo wallets that
    /// don't have a group header.
    var showThresholdBadge: Bool = false
    @EnvironmentObject private var appState: AppState
    @StateObject private var priceService = PriceService.shared
    @ObservedObject private var balanceCache = BalanceCache.shared
    @State private var isLoading = false

    private var balance: String? { balanceCache.cachedRaw(walletId: wallet.id) }

    var body: some View {
        HStack(spacing: 14) {
            ChainIcon(chain: wallet.chain, size: 44)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(wallet.name)
                    .font(.headline)
                    .foregroundStyle(.white)

                Text(shortAddress(wallet.address))
                    .font(.caption)
                    .foregroundStyle(HorcruxTheme.subtleText)
                    .monospaced()
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                if isLoading {
                    ProgressView().scaleEffect(0.7).tint(HorcruxTheme.accentPurple)
                        .accessibilityLabel(L10n.WalletHome.loadingBalance)
                } else if let balance {
                    Text(balance)
                        .font(.subheadline.bold().monospacedDigit())
                        .foregroundStyle(.white)
                        .accessibilityLabel("Balance: \(balance)")
                    if let fiat = fiatEstimate(from: balance) {
                        Text(fiat)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(HorcruxTheme.subtleText)
                    }
                } else {
                    Text(wallet.chain.symbol)
                        .font(.subheadline.bold())
                        .foregroundStyle(HorcruxTheme.subtleText)
                }

                if showThresholdBadge {
                    ShardStatusBadge(threshold: wallet.threshold, total: wallet.totalParties)
                        .accessibilityLabel(L10n.Shards.thresholdValue(Int(wallet.threshold), Int(wallet.totalParties)))
                }
            }
        }
        .padding(.vertical, 12)
        .glassCard()
        .accessibilityElement(children: .combine)
        .task {
            await fetchBalance()
            priceService.refreshIfNeeded()
        }
    }

    private func fetchBalance() async {
        if balanceCache.cachedRaw(walletId: wallet.id) != nil { return }
        isLoading = true
        defer { isLoading = false }
        _ = await balanceCache.balance(for: wallet,
                                       service: appState.blockchainService,
                                       config: appState.networkConfig)
    }

    /// Attempts to extract the numeric portion of a balance string like "1.234 ETH"
    /// and convert it to a USD estimate via PriceService.
    private func fiatEstimate(from balance: String) -> String? {
        let parts = balance.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, let amount = Double(parts[0].replacingOccurrences(of: ",", with: "")) else {
            return nil
        }
        return priceService.fiatString(amount: amount, symbol: parts[1])
    }

    private func shortAddress(_ address: String) -> String {
        guard address.count > 12 else { return address }
        return "\(address.prefix(6))…\(address.suffix(4))"
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
        ScrollView {
            VStack(spacing: 20) {
                // Hero card
                VStack(spacing: 16) {
                    ChainIcon(chain: wallet.chain, size: 56)

                    if isLoadingBalance {
                        ProgressView().tint(HorcruxTheme.accentPurple)
                            .accessibilityLabel(L10n.WalletHome.loadingBalance)
                    } else if let balance {
                        Text(balance)
                            .font(.system(size: 32, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white)
                            .accessibilityLabel("Balance: \(balance)")
                            .accessibilityIdentifier("walletDetail_balance")
                    }

                    Text(wallet.address)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(HorcruxTheme.subtleText)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .accessibilityLabel(L10n.WalletDetail.walletAddress)
                        .accessibilityValue(wallet.address)

                    Button {
                        SecureClipboard.copy(wallet.address)
                        copiedAddress = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + UXTiming.clipboardFeedback) { copiedAddress = false }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: copiedAddress ? "checkmark" : "doc.on.doc")
                                .font(.caption2)
                            Text(copiedAddress ? L10n.Receive.copiedClears(Int(SecureClipboard.defaultExpireSeconds)) : L10n.WalletDetail.copyAddress)
                                .font(.caption.weight(.medium))
                        }
                        .foregroundStyle(HorcruxTheme.accentPurple)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(HorcruxTheme.accentPurple.opacity(0.12), in: Capsule())
                    }
                    .accessibilityLabel(copiedAddress ? L10n.WalletDetail.addressCopied : L10n.WalletDetail.copyWalletAddress)
                    .accessibilityHint(L10n.WalletDetail.copiesAddressHint)
                    .accessibilityIdentifier("walletDetail_copyAddressButton")

                    ShardStatusBadge(threshold: wallet.threshold, total: wallet.totalParties)
                        .accessibilityLabel(L10n.Shards.shardThreshold(Int(wallet.threshold), Int(wallet.totalParties)))
                }
                .frame(maxWidth: .infinity)
                .glassCard(padding: 24)

                // Action buttons
                HStack(spacing: 12) {
                    Button {
                        showSigning = true
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                            Text(L10n.WalletDetail.sendTransaction)
                                .font(.caption.weight(.medium))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(HorcruxTheme.accentPurple.opacity(0.2))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(HorcruxTheme.accentPurple.opacity(0.3), lineWidth: 1))
                        )
                    }
                    .accessibilityHint(L10n.WalletDetail.openSigningHint)
                    .accessibilityIdentifier("walletDetail_sendButton")

                    Button {
                        showReceive = true
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "qrcode")
                                .font(.title2)
                            Text(L10n.WalletDetail.receive)
                                .font(.caption.weight(.medium))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(HorcruxTheme.accentBlue.opacity(0.2))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(HorcruxTheme.accentBlue.opacity(0.3), lineWidth: 1))
                        )
                    }
                    .accessibilityHint(L10n.WalletDetail.showQRHint)
                    .accessibilityIdentifier("walletDetail_receiveButton")
                }

                // Tokens
                if wallet.chain != .bitcoin {
                    VStack(alignment: .leading, spacing: 10) {
                        VaultSectionHeader(L10n.WalletDetail.tokens, icon: "circle.grid.2x2")
                            .padding(.horizontal, 4)

                        if isLoadingTokens {
                            HStack {
                                ProgressView().scaleEffect(0.7).tint(HorcruxTheme.accentPurple)
                                Text(L10n.WalletDetail.loadingTokens).font(.caption).foregroundStyle(HorcruxTheme.subtleText)
                            }
                            .glassCard()
                        } else if tokenBalances.isEmpty {
                            VaultEmptyState(icon: "plus.circle", title: L10n.WalletDetail.noTokens, subtitle: L10n.WalletDetail.noTokensDescription, iconSize: 32)
                                .frame(maxWidth: .infinity)
                                .glassCard()
                        } else {
                            VStack(spacing: 0) {
                                ForEach(tokenBalances) { tb in
                                    HStack {
                                        Text(tb.token.symbol)
                                            .font(.subheadline.bold())
                                            .foregroundStyle(.white)
                                        Spacer()
                                        Text(tb.displayBalance)
                                            .font(.subheadline.monospacedDigit())
                                            .foregroundStyle(HorcruxTheme.subtleText)
                                    }
                                    .padding(.vertical, 10)
                                    if tb.id != tokenBalances.last?.id {
                                        Divider().background(Color.white.opacity(0.06))
                                    }
                                }
                            }
                            .glassCard()
                        }
                    }
                }

                // Recent transactions
                let recentTxs = Array(appState.transactionStore.records(for: wallet.id).prefix(5))
                VStack(alignment: .leading, spacing: 10) {
                    VaultSectionHeader(L10n.WalletDetail.recentTransactions, icon: "clock.arrow.circlepath")
                        .padding(.horizontal, 4)

                    if recentTxs.isEmpty {
                        NavigationLink {
                            TransactionHistoryView(wallet: wallet)
                        } label: {
                            HStack {
                                VaultSettingsRow(icon: "clock.arrow.circlepath", iconColor: HorcruxTheme.accentBlue, title: L10n.WalletDetail.transactionHistory)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(HorcruxTheme.subtleText)
                            }
                        }
                        .glassCard()
                    } else {
                        VStack(spacing: 0) {
                            ForEach(recentTxs) { tx in
                                NavigationLink {
                                    TransactionDetailView(transaction: tx)
                                } label: {
                                    TransactionRow(transaction: tx)
                                }
                                .padding(.vertical, 8)
                                if tx.id != recentTxs.last?.id {
                                    Divider().background(Color.white.opacity(0.06))
                                }
                            }
                        }
                        .glassCard()

                        NavigationLink {
                            TransactionHistoryView(wallet: wallet)
                        } label: {
                            Text(L10n.WalletDetail.viewAllHistory)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(HorcruxTheme.accentPurple)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(HorcruxTheme.accentPurple.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }

                // Details
                VStack(alignment: .leading, spacing: 10) {
                    VaultSectionHeader(L10n.WalletDetail.details, icon: "info.circle")
                        .padding(.horizontal, 4)

                    VStack(spacing: 0) {
                        detailRow(L10n.WalletDetail.chain, value: wallet.chain.rawValue)
                        Divider().background(Color.white.opacity(0.06))
                        detailRow(L10n.WalletDetail.threshold, value: L10n.WalletDetail.thresholdValue(Int(wallet.threshold), Int(wallet.totalParties)))
                        Divider().background(Color.white.opacity(0.06))
                        detailRow(L10n.WalletDetail.yourShard, value: L10n.WalletDetail.shardNumber(Int(wallet.partyIndex)))
                        Divider().background(Color.white.opacity(0.06))
                        detailRow(L10n.WalletDetail.created, value: wallet.createdAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    .glassCard()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .darkBackground()
        .navigationTitle(wallet.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .sheet(isPresented: $showSigning) { SigningView(wallet: wallet) }
        .sheet(isPresented: $showReceive) { ReceiveView(wallet: wallet) }
        .task {
            await fetchBalance()
            await fetchTokenBalances()
        }
        .refreshable {
            await fetchBalance()
            await fetchTokenBalances()
        }
    }

    private func detailRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(HorcruxTheme.subtleText)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
        }
        .padding(.vertical, 10)
    }

    private func fetchBalance() async {
        isLoadingBalance = true
        defer { isLoadingBalance = false }
        do {
            balance = try await appState.blockchainService.balance(for: wallet, config: appState.networkConfig)
        } catch {
            balance = nil
        }
    }

    private func fetchTokenBalances() async {
        guard wallet.chain != .bitcoin else { return }
        isLoadingTokens = true
        defer { isLoadingTokens = false }
        tokenBalances = await appState.blockchainService.tokenBalances(for: wallet, config: appState.networkConfig)
    }
}

// MARK: - Portfolio Summary

/// Top-of-home hero card that shows the total fiat value across all wallets.
/// Kicks PriceService to refresh and combines fiat sums using the current quotes.
struct PortfolioSummaryCard: View {
    let wallets: [Wallet]
    @EnvironmentObject private var appState: AppState
    @StateObject private var priceService = PriceService.shared
    @ObservedObject private var balanceCache = BalanceCache.shared
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "chart.pie.fill")
                    .foregroundStyle(HorcruxTheme.accentPurple)
                Text("总资产")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                if isLoading {
                    ProgressView().scaleEffect(0.7).tint(HorcruxTheme.accentPurple)
                }
            }
            Text(totalFiatString)
                .font(.system(size: 32, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .contentTransition(.numericText())
            Text(summarySubtitle)
                .font(.caption2)
                .foregroundStyle(HorcruxTheme.subtleText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard()
        .task {
            await refreshAll()
        }
    }

    private var summarySubtitle: String {
        let accountCount = Set(wallets.map { $0.accountId }).count
        let chainCount = Set(wallets.map { $0.chain }).count
        if accountCount <= 1 {
            return "\(chainCount) 条链 · 实时 USD 报价（来源：CoinGecko）"
        }
        return "跨 \(accountCount) 个账户 · \(chainCount) 条链 · 实时 USD 报价（来源：CoinGecko）"
    }

    private var totalFiatString: String {
        let total = wallets.reduce(0.0) { acc, w in
            let amount = balanceCache.nativeAmount(walletId: w.id) ?? 0
            return acc + amount * (priceService.usdPrice(symbol: w.chain.symbol) ?? 0)
        }
        let fmt = NumberFormatter()
        fmt.numberStyle = .currency
        fmt.currencyCode = "USD"
        fmt.maximumFractionDigits = 2
        return fmt.string(from: NSNumber(value: total)) ?? "$—"
    }

    private func refreshAll() async {
        priceService.refreshIfNeeded()
        isLoading = true
        defer { isLoading = false }
        await withTaskGroup(of: Void.self) { group in
            for wallet in wallets {
                group.addTask { @MainActor in
                    _ = await BalanceCache.shared.balance(for: wallet,
                                                          service: appState.blockchainService,
                                                          config: appState.networkConfig)
                }
            }
        }
    }
}
