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

                if !walletStore.wallets.isEmpty {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Button {
                                showCreateShard = true
                            } label: {
                                Image(systemName: "plus")
                                    .font(.title2.weight(.bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 56, height: 56)
                                    .background(
                                        LinearGradient(
                                            colors: [HorcruxTheme.accentPurple, HorcruxTheme.accentBlue],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                        in: Circle()
                                    )
                                    .shadow(color: HorcruxTheme.accentPurple.opacity(0.5), radius: 12, y: 6)
                            }
                            .padding(.trailing, 20)
                            .padding(.bottom, 20)
                            .accessibilityLabel(L10n.WalletHome.createNewWallet)
                            .accessibilityHint(L10n.WalletHome.opensCreationFlow)
                            .accessibilityIdentifier("walletHome_fabCreateButton")
                        }
                    }
                }
            }
            .navigationTitle(L10n.WalletHome.title)
            .navigationBarTitleDisplayMode(.large)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    // Top-right + is only shown when the user already has
                    // wallets; in empty state the centered primary CTA is
                    // the single source of truth (avoids 3x redundant CTAs).
                    EmptyView()
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
            .preferredColorScheme(.dark)
        }
    }

    @ViewBuilder
    private var offlineBanner: some View {
        if !networkReachable.isEmpty, networkReachable.values.contains(false) {
            let offline = networkReachable.filter { !$0.value }.map(\.key.symbol).sorted()
            let chainList = offline.joined(separator: "、")
            let label = offline.count > 1
                ? L10n.WalletHome.nodesUnreachable(chainList)
                : L10n.WalletHome.nodeUnreachable(chainList)
            HStack(spacing: 8) {
                Image(systemName: "wifi.slash")
                    .font(.caption.weight(.semibold))
                Text(label)
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(HorcruxTheme.warningAmber)
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .background(
                Capsule().fill(HorcruxTheme.warningAmber.opacity(0.12))
            )
            .overlay(
                Capsule().stroke(HorcruxTheme.warningAmber.opacity(0.35), lineWidth: 1)
            )
            .accessibilityLabel(L10n.WalletHome.networkWarning(chainList))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            offlineBanner
                .padding(.top, 8)

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
                    Label(L10n.WalletHome.restoreFromBackup, systemImage: "square.and.arrow.down")
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
                offlineBanner
                    .padding(.top, 4)

                // Portfolio summary (IA: root → chain → asset)
                PortfolioSummaryCard(wallets: walletStore.wallets.filter { !$0.hidden })

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
                            .contextMenu {
                                Button {
                                    walletStore.setHidden(id: wallet.id, hidden: true)
                                } label: {
                                    Label(L10n.Common.hide, systemImage: "eye.slash")
                                }
                            }
                        }
                    }
                }

                if !hiddenWallets.isEmpty {
                    hiddenSection
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .refreshable {
            // Pull-to-refresh: force-bypass the 30s TTL so pulling actually
            // hits the RPC. BalanceCache still coalesces concurrent fetches
            // per wallet, so the hero card and rows share one round trip.
            await BalanceCache.shared.refreshAll(
                wallets: walletStore.wallets.filter { !$0.hidden },
                service: appState.blockchainService,
                config: appState.networkConfig,
                force: true
            )
            PriceService.shared.refreshIfNeeded()
        }
    }

    /// Group wallets by accountId (derived from groupPublicKey). Each group
    /// is a single MPC account; label is user-set via AccountStore with a
    /// deterministic fallback based on the first wallet's name (stripped of
    /// any "(SYMBOL)" chain suffix).
    private var walletGroups: [WalletGroup] {
        let wallets = walletStore.wallets.filter { !$0.hidden }
        let buckets = Dictionary(grouping: wallets, by: { $0.accountId })
        return buckets
            .map { (accountId, list) -> WalletGroup in
                let first = list.first!
                let fallback = first.name.replacingOccurrences(of: " (\(first.chain.rawValue))", with: "")
                let label = accountStore.name(for: accountId, fallback: fallback)
                return WalletGroup(
                    accountId: accountId,
                    label: label,
                    wallets: list.sorted { $0.chain.rawValue < $1.chain.rawValue }
                )
            }
            .sorted { $0.label < $1.label }
    }

    private var hiddenWallets: [Wallet] {
        walletStore.wallets.filter { $0.hidden }.sorted { $0.chain.rawValue < $1.chain.rawValue }
    }

    @State private var hiddenExpanded = false

    private var hiddenSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation { hiddenExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "eye.slash")
                        .font(.caption)
                        .foregroundStyle(HorcruxTheme.subtleText)
                    Text(L10n.WalletHome.hiddenCount(hiddenWallets.count))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(HorcruxTheme.subtleText)
                    Spacer()
                    Image(systemName: hiddenExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(HorcruxTheme.subtleText)
                }
                .padding(.horizontal, 6)
                .padding(.top, 12)
            }
            .buttonStyle(.plain)

            if hiddenExpanded {
                ForEach(hiddenWallets) { wallet in
                    NavigationLink {
                        WalletDetailView(wallet: wallet)
                    } label: {
                        WalletRow(wallet: wallet, showThresholdBadge: false)
                            .opacity(0.55)
                    }
                    .contextMenu {
                        Button {
                            walletStore.setHidden(id: wallet.id, hidden: false)
                        } label: {
                            Label(L10n.Common.unhide, systemImage: "eye")
                        }
                    }
                }
            }
        }
    }

    private struct WalletGroup {
        let accountId: String
        let label: String
        let wallets: [Wallet]
    }

    private func retryBroadcast(_ tx: PendingBroadcastQueue.PendingTransaction) async {
        do {
            let result: String
            if tx.chain.isEVM {
                result = try await appState.blockchainService.ethSendRawTransaction(
                    signedTxHex: tx.signedPayload, rpcURL: appState.networkConfig.rpcURL(for: tx.chain))
            } else {
                switch tx.chain {
                case .bitcoin:
                    result = try await appState.blockchainService.btcBroadcast(
                        signedTxHex: tx.signedPayload, apiURL: appState.networkConfig.bitcoinAPI)
                case .litecoin:
                    result = try await appState.blockchainService.btcBroadcast(
                        signedTxHex: tx.signedPayload, apiURL: appState.networkConfig.litecoinAPI)
                case .solana:
                    result = try await appState.blockchainService.solSendTransaction(
                        signedTxBase64: tx.signedPayload, rpcURL: appState.networkConfig.solanaRPC)
                case .tron:
                    // TRON broadcast is still pending.
                    throw BlockchainError.invalidURL("Broadcast not supported for \(tx.chain.rawValue)")
                default:
                    throw BlockchainError.invalidURL("Broadcast not supported for \(tx.chain.rawValue)")
                }
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
                        Label(L10n.WalletHome.speedUp, systemImage: "hare.fill")
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
                        Text(L10n.RBFSheet.title).font(.headline)
                    } icon: {
                        Image(systemName: "hare.fill").foregroundStyle(.cyan)
                    }
                    Text(L10n.RBFSheet.explain)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.RBFSheet.availableOps).font(.subheadline.weight(.semibold))
                        bullet(L10n.RBFSheet.op1)
                        bullet(L10n.RBFSheet.op2)
                        bullet(L10n.RBFSheet.op3)
                    }
                    .font(.callout)

                    Button(role: .destructive, action: onCancel) {
                        Label(L10n.RBFSheet.discardAndResign, systemImage: "trash")
                            .frame(maxWidth: .infinity)
                            .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                .padding()
            }
            .navigationTitle(L10n.RBFSheet.navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.RBFSheet.close) { dismiss() }
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
                Text(wallet.chain.rawValue)
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
    @State private var showRenameSheet = false
    @State private var renameText = ""
    @State private var showDeleteConfirm = false
    @Environment(\.dismiss) private var dismiss

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
                if !wallet.chain.signingSupported {
                    HStack(spacing: 8) {
                        Image(systemName: "eye.fill")
                            .font(.caption)
                        Text("Read-only chain — send/receive QR works, signing + broadcast will land in a later release.")
                            .font(.caption2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(HorcruxTheme.subtleText)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.yellow.opacity(0.08))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.yellow.opacity(0.25), lineWidth: 1))
                    )
                }

                HStack(spacing: 12) {
                    Button {
                        showSigning = true
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: wallet.chain.signingSupported ? "arrow.up.circle.fill" : "lock.fill")
                                .font(.title2)
                            Text(L10n.WalletDetail.sendTransaction)
                                .font(.caption.weight(.medium))
                        }
                        .foregroundStyle(wallet.chain.signingSupported ? .white : HorcruxTheme.subtleText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(HorcruxTheme.accentPurple.opacity(wallet.chain.signingSupported ? 0.2 : 0.06))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(HorcruxTheme.accentPurple.opacity(wallet.chain.signingSupported ? 0.3 : 0.12), lineWidth: 1))
                        )
                    }
                    .disabled(!wallet.chain.signingSupported)
                    .accessibilityHint(wallet.chain.signingSupported ? L10n.WalletDetail.openSigningHint : "Signing not yet supported for this chain")
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

                if isEmptyWallet {
                    emptyWalletCTA
                }

                // Tokens (only for chains that have a token list or user-added customs)
                if !appState.customTokenStore.effectiveTokens(for: wallet.chain).isEmpty {
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
                            VaultEmptyState(icon: "circle.dashed", title: L10n.WalletDetail.noTokens, subtitle: L10n.WalletDetail.noTokensDescription, iconSize: 32)
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
                                        Divider().background(HorcruxTheme.hairline)
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
                                    Divider().background(HorcruxTheme.hairline)
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
                        Divider().background(HorcruxTheme.hairline)
                        detailRow(L10n.WalletDetail.threshold, value: L10n.WalletDetail.thresholdValue(Int(wallet.threshold), Int(wallet.totalParties)))
                        Divider().background(HorcruxTheme.hairline)
                        detailRow(L10n.WalletDetail.yourShard, value: L10n.WalletDetail.shardNumber(Int(wallet.partyIndex)))
                        Divider().background(HorcruxTheme.hairline)
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        renameText = wallet.name
                        showRenameSheet = true
                    } label: {
                        Label(L10n.Common.rename, systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label(L10n.WalletHome.deleteWallet, systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .accessibilityIdentifier("walletDetail_menu")
                }
            }
        }
        .sheet(isPresented: $showSigning) { SigningView(wallet: wallet) }
        .sheet(isPresented: $showReceive) { ReceiveView(wallet: wallet) }
        .alert(L10n.WalletHome.renameTitle, isPresented: $showRenameSheet) {
            TextField(L10n.WalletHome.walletNamePlaceholder, text: $renameText)
                .autocorrectionDisabled()
            Button(L10n.Common.cancel, role: .cancel) {}
            Button(L10n.Common.save) {
                let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                appState.walletStore.rename(id: wallet.id, newName: trimmed)
            }
        }
        .alert(L10n.WalletHome.deleteWallet, isPresented: $showDeleteConfirm) {
            Button(L10n.Common.cancel, role: .cancel) {}
            Button(L10n.Common.delete, role: .destructive) {
                // Remove the wallet record + its tx history. Shard shares
                // are preserved (they may be tied to other chains).
                appState.transactionStore.removeAll(for: wallet.id)
                appState.walletStore.remove(id: wallet.id)
                dismiss()
            }
        } message: {
            Text(L10n.WalletEmpty.removeFromDevice)
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

    /// Heuristic: balance has loaded, it parses to ≤ 0, and no non-zero
    /// tokens are present. Prompts the user to receive first funds.
    private var isEmptyWallet: Bool {
        guard !isLoadingBalance, !isLoadingTokens else { return false }
        guard let balance else { return false }
        let numeric = balance.split(separator: " ").first.map(String.init) ?? ""
        let amount = Double(numeric.replacingOccurrences(of: ",", with: "")) ?? 0
        if amount > 0 { return false }
        let nonZeroTokens = tokenBalances.contains { tb in
            let s = tb.displayBalance.split(separator: " ").first.map(String.init) ?? ""
            return (Double(s.replacingOccurrences(of: ",", with: "")) ?? 0) > 0
        }
        return !nonZeroTokens
    }

    @ViewBuilder
    private var emptyWalletCTA: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.title3)
                    .foregroundStyle(HorcruxTheme.accentCyan)
                Text(L10n.WalletEmpty.startUsing)
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            Text(L10n.WalletEmpty.recvHint(wallet.chain.symbol))
                .font(.caption)
                .foregroundStyle(HorcruxTheme.subtleText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    SecureClipboard.copy(wallet.address)
                    copiedAddress = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + UXTiming.clipboardFeedback) { copiedAddress = false }
                } label: {
                    Label(copiedAddress ? L10n.WalletEmpty.copied : L10n.WalletEmpty.copyAddress, systemImage: copiedAddress ? "checkmark" : "doc.on.doc")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(HorcruxTheme.accentPurple.opacity(0.8))

                Button {
                    showReceive = true
                } label: {
                    Label(L10n.WalletEmpty.showQR, systemImage: "qrcode")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(HorcruxTheme.accentBlue)
            }

            if wallet.chain.isEVM {
                NavigationLink {
                    CustomTokensView()
                } label: {
                    HStack {
                        Image(systemName: "plus.circle")
                        Text(L10n.WalletEmpty.addCustomToken)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(HorcruxTheme.accentCyan)
                    .padding(.vertical, 6)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(HorcruxTheme.accentCyan.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(HorcruxTheme.accentCyan.opacity(0.25), lineWidth: 1))
        )
    }

    private func fetchBalance() async {
        isLoadingBalance = true
        defer { isLoadingBalance = false }
        // Route through BalanceCache so the hero Portfolio card, the wallet
        // list row, and this detail view all read the same source of truth
        // and don't trigger three parallel RPC calls on navigation.
        balance = await BalanceCache.shared.balance(for: wallet,
                                                    service: appState.blockchainService,
                                                    config: appState.networkConfig,
                                                    force: true)
    }

    private func fetchTokenBalances() async {
        guard wallet.chain != .bitcoin else { return }
        isLoadingTokens = true
        defer { isLoadingTokens = false }
        tokenBalances = await appState.blockchainService.tokenBalances(
            for: wallet,
            config: appState.networkConfig,
            extraTokens: appState.customTokenStore.tokens
        )
        // Seed each token into BalanceCache so the Max button in the
        // signing compose form can honour cached balances without
        // re-fetching them from the RPC.
        for tb in tokenBalances {
            let amt: Double? = {
                let first = tb.displayBalance.split(separator: " ").first.map(String.init) ?? ""
                return Double(first.replacingOccurrences(of: ",", with: ""))
            }()
            if let amt {
                BalanceCache.shared.seedTokenBalance(walletId: wallet.id, tokenId: tb.token.id, value: amt)
            }
        }
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
                Text(L10n.WalletEmpty.totalAssets)
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
            if let (percent, absolute) = total24hChange() {
                HStack(spacing: 6) {
                    Image(systemName: percent >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption2.weight(.bold))
                    Text(String(format: "%@%.2f%%  (%@$%.2f)  24h",
                                percent >= 0 ? "+" : "",
                                percent,
                                absolute >= 0 ? "+" : "-",
                                abs(absolute)))
                        .font(.caption.weight(.medium).monospacedDigit())
                }
                .foregroundStyle(percent >= 0 ? HorcruxTheme.successGreen : HorcruxTheme.dangerRed)
            }
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
            return L10n.WalletEmpty.summaryOneAccount(chainCount)
        }
        return L10n.WalletEmpty.summaryMultiAccount(accountCount, chainCount)
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

    /// Combined 24h change across all wallets as (percentDelta, absoluteUsd).
    /// Returns nil if no quotes carry a change figure yet. The percent is
    /// weighted by each wallet's current USD value so a wallet with $100
    /// of ETH at -2% and $10 of BTC at +5% yields roughly -1.4%.
    private func total24hChange() -> (percent: Double, absolute: Double)? {
        var weightedChange = 0.0
        var totalNow = 0.0
        var totalAbs = 0.0
        var hadAny = false
        for w in wallets {
            guard let amount = balanceCache.nativeAmount(walletId: w.id),
                  let price = priceService.usdPrice(symbol: w.chain.symbol) else { continue }
            let valueNow = amount * price
            guard let change = priceService.change24h(symbol: w.chain.symbol) else { continue }
            hadAny = true
            // Derive "24 hours ago" value from now and change: v_now = v_old * (1 + change/100)
            let valueThen = valueNow / (1 + change / 100)
            weightedChange += change * valueNow
            totalNow += valueNow
            totalAbs += (valueNow - valueThen)
        }
        guard hadAny, totalNow > 0 else { return nil }
        return (percent: weightedChange / totalNow, absolute: totalAbs)
    }

    private func refreshAll() async {
        priceService.refreshIfNeeded()
        isLoading = true
        defer { isLoading = false }
        await BalanceCache.shared.refreshAll(
            wallets: wallets,
            service: appState.blockchainService,
            config: appState.networkConfig
        )
    }
}
