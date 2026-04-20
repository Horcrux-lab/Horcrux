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
    @State private var expandedGroups: Set<String> = []
    /// Account groups folded by the user (session-local). Collapsed state
    /// is opt-in: empty set = every group expanded (today's behaviour).
    @State private var collapsedGroups: Set<String> = []
    @ObservedObject private var balanceCache = BalanceCache.shared
    @State private var receiveWallet: Wallet?
    @State private var offlineBannerExpanded = false
    @State private var lastReachabilityCheck: Date?
    @State private var rotationTarget: Wallet?
    @State private var rotationNudgeDismissedAt: Date?
    @State private var avatarEditTarget: AvatarEditTarget?

    private struct AvatarEditTarget: Identifiable {
        let id: String  // == accountId
        let label: String
    }

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
            .sheet(item: $receiveWallet) { wallet in
                ReceiveView(wallet: wallet)
            }
            .sheet(item: $rotationTarget) { wallet in
                RefreshShardSheet(wallet: wallet, appState: appState)
                    .environmentObject(appState)
            }
            .sheet(item: $avatarEditTarget) { target in
                WalletAvatarPickerSheet(accountId: target.id, fallbackLabel: target.label)
            }
            .task {
                networkReachable = await NetworkStatus.shared.checkAll(config: appState.networkConfig)
                lastReachabilityCheck = Date()
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
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    offlineBannerExpanded.toggle()
                }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "wifi.slash")
                            .font(.caption.weight(.semibold))
                        Text(offlineBannerExpanded ? label : "\(offline.count) \(offline.count > 1 ? "chains" : "chain") offline")
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: offlineBannerExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.semibold))
                    }
                    if offlineBannerExpanded, let checked = lastReachabilityCheck {
                        Text(relativeTimeDescription(checked))
                            .font(.caption2)
                            .foregroundStyle(HorcruxTheme.warningAmber.opacity(0.75))
                    }
                }
                .foregroundStyle(HorcruxTheme.warningAmber)
                .padding(.vertical, 8)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Capsule().fill(HorcruxTheme.warningAmber.opacity(0.12))
                )
                .overlay(
                    Capsule().stroke(HorcruxTheme.warningAmber.opacity(0.35), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.WalletHome.networkWarning(chainList))
        }
    }

    private func relativeTimeDescription(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Checked \(formatter.localizedString(for: date, relativeTo: Date()))"
    }

    /// First refreshable wallet (n-of-n CGGMP21 ECDSA) whose last rotation
    /// exceeds the recommended interval. Mirrors the filter in
    /// `ReplaceDeviceInfoView.refreshable` so the Rotate Shards entry point
    /// in Settings and this nudge stay consistent.
    private var staleWallet: Wallet? {
        walletStore.wallets.first { w in
            w.threshold == w.totalParties &&
            w.chain.curveType == .secp256k1 &&
            !w.hidden &&
            RefreshTracker.needsRotation(accountId: w.accountId, walletCreatedAt: w.createdAt)
        }
    }

    /// Days since last rotation, or nil if never rotated. Used purely for
    /// the nudge copy — the actual "is it stale?" gate is in
    /// `RefreshTracker.needsRotation`.
    private func daysSinceRotation(_ wallet: Wallet) -> Int? {
        guard let last = RefreshTracker.lastRefresh(accountId: wallet.accountId) else { return nil }
        return Calendar.current.dateComponents([.day], from: last, to: Date()).day
    }

    @ViewBuilder
    private var rotationNudge: some View {
        // Session-local snooze: once dismissed, hide for 24h so the nudge
        // isn't a persistent eyesore; the next launch will re-surface it.
        let snoozed = rotationNudgeDismissedAt.map { Date().timeIntervalSince($0) < 24 * 3600 } ?? false
        if let w = staleWallet, !snoozed {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.title3)
                    .foregroundStyle(HorcruxTheme.accentCyan)

                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.Rotate.nudgeTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(daysSinceRotation(w).map { L10n.Rotate.nudgeBodyDays($0) } ?? L10n.Rotate.nudgeBodyNever)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 12) {
                        Button {
                            rotationTarget = w
                        } label: {
                            Text(L10n.Rotate.nudgeCTA)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(HorcruxTheme.accentCyan))
                                .foregroundStyle(.black)
                        }
                        .accessibilityIdentifier("walletHome_rotateNudgeCTA")

                        Button {
                            withAnimation { rotationNudgeDismissedAt = Date() }
                        } label: {
                            Text(L10n.Rotate.nudgeDismiss)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(HorcruxTheme.accentCyan.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(HorcruxTheme.accentCyan.opacity(0.35), lineWidth: 1)
            )
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
                    Label(L10n.WalletHome.createFirstWallet, systemImage: "plus.circle.fill")
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
            .padding(.horizontal, 24)

            Spacer()
        }
        .padding()
    }

    private var walletList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                offlineBanner
                    .padding(.top, 4)

                rotationNudge

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
                    walletGroupSection(group)
                }

                if !hiddenWallets.isEmpty {
                    hiddenSection
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 96)  // reserve space for the floating + FAB
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

    /// Returns the EVM address shared across ≥2 EVM wallets in the group, if any.
    /// Used by the account header so we don't repeat "0xce82…dae2" on every EVM row.
    private func sharedEVMAddress(in group: WalletGroup) -> String? {
        let evm = group.wallets.filter { $0.chain.isEVM }
        guard evm.count >= 2, let first = evm.first?.address,
              evm.dropFirst().allSatisfy({ $0.address == first }) else { return nil }
        return first
    }

    /// True when the cached balance for this wallet parses to zero. If the
    /// balance hasn't loaded yet we conservatively return false so pending
    /// rows stay visible during the initial fetch.
    private func isEmptyBalance(_ wallet: Wallet) -> Bool {
        guard let raw = balanceCache.cachedRaw(walletId: wallet.id) else { return false }
        let first = raw.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        let amount = Double(first.replacingOccurrences(of: ",", with: "")) ?? 0
        return amount == 0
    }

    /// Partitions a group's wallets into (funded, empty) and decides which
    /// wallets to show now based on the per-group expand state. Rule of thumb:
    /// collapse empty rows only when there are ≥2 of them AND at least one
    /// funded wallet exists — otherwise the user needs to see something.
    private func visibleWallets(in group: WalletGroup) -> (visible: [Wallet], hiddenCount: Int) {
        let funded = group.wallets.filter { !isEmptyBalance($0) }
        let empty = group.wallets.filter { isEmptyBalance($0) }
        let expanded = expandedGroups.contains(group.accountId)
        if expanded || empty.count < 2 || funded.isEmpty {
            return (group.wallets, 0)
        }
        return (funded, empty.count)
    }

    @ViewBuilder
    private func walletGroupSection(_ group: WalletGroup) -> some View {
        let evmAddress = sharedEVMAddress(in: group)
        let partition = visibleWallets(in: group)
        let expanded = expandedGroups.contains(group.accountId)
        let isCollapsible = walletGroups.count > 1
        let isCollapsed = isCollapsible && collapsedGroups.contains(group.accountId)
        VStack(alignment: .leading, spacing: 8) {
            if walletGroups.count > 1 || group.wallets.count > 1 || evmAddress != nil {
                let header = WalletGroupHeader(
                    label: group.label,
                    threshold: Int(group.wallets.first?.threshold ?? 0),
                    total: Int(group.wallets.first?.totalParties ?? 0),
                    accountId: group.accountId,
                    sharedAddress: isCollapsed ? nil : evmAddress,
                    isCollapsed: isCollapsible ? isCollapsed : nil,
                    collapsedSummary: isCollapsed ? collapsedSummary(for: group) : nil
                )
                .padding(.horizontal, 6)

                if isCollapsible {
                    Button {
                        Haptics.selection()
                        withAnimation(.easeInOut(duration: 0.22)) {
                            if isCollapsed {
                                collapsedGroups.remove(group.accountId)
                            } else {
                                collapsedGroups.insert(group.accountId)
                            }
                        }
                    } label: {
                        header
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(group.label), \(isCollapsed ? L10n.Common.expand : L10n.Common.collapse)")
                    .accessibilityIdentifier("walletHome_groupToggle_\(group.accountId)")
                    .contextMenu {
                        Button {
                            avatarEditTarget = .init(id: group.accountId, label: group.label)
                        } label: {
                            Label(L10n.WalletAvatar.editMenu, systemImage: "paintpalette")
                        }
                    }
                } else {
                    header
                        .contextMenu {
                            Button {
                                avatarEditTarget = .init(id: group.accountId, label: group.label)
                            } label: {
                                Label(L10n.WalletAvatar.editMenu, systemImage: "paintpalette")
                            }
                        }
                }
            }

            if !isCollapsed {
                VStack(spacing: 8) {
                    ForEach(partition.visible) { wallet in
                        NavigationLink {
                        WalletDetailView(wallet: wallet)
                    } label: {
                        WalletRow(
                            wallet: wallet,
                            showThresholdBadge: group.wallets.count == 1 && walletGroups.count == 1,
                            hideAddress: false
                        )
                    }
                    .accessibilityLabel("\(wallet.name), \(wallet.chain.displayName) wallet")
                    .accessibilityHint(L10n.WalletHome.viewDetailsHint)
                    .accessibilityIdentifier("walletHome_walletRow_\(wallet.id)")
                    .contextMenu {
                        Button {
                            SecureClipboard.copy(wallet.address)
                            Haptics.success()
                        } label: {
                            Label(L10n.WalletDetail.copyAddress, systemImage: "doc.on.doc")
                        }
                        Button {
                            receiveWallet = wallet
                        } label: {
                            Label(L10n.Receive.title, systemImage: "qrcode")
                        }
                        Divider()
                        Button {
                            walletStore.setHidden(id: wallet.id, hidden: true)
                        } label: {
                            Label(L10n.Common.hide, systemImage: "eye.slash")
                        }
                    }
                }

                if empty(group).count >= 2 && !funded(group).isEmpty {
                    Button {
                        withAnimation {
                        if expanded {
                            expandedGroups.remove(group.accountId)
                        } else {
                            expandedGroups.insert(group.accountId)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.semibold))
                        Text(expanded
                             ? L10n.WalletHome.hideEmptyChains
                             : L10n.WalletHome.showMoreChains(empty(group).count))
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(HorcruxTheme.accentPurple)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        HorcruxTheme.accentPurple.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("walletHome_expandToggle_\(group.accountId)")
                }
                }
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .top)),
                    removal: .opacity.combined(with: .move(edge: .top))
                ))
            }
        }
    }

    private func funded(_ group: WalletGroup) -> [Wallet] {
        group.wallets.filter { !isEmptyBalance($0) }
    }

    private func empty(_ group: WalletGroup) -> [Wallet] {
        group.wallets.filter { isEmptyBalance($0) }
    }

    /// One-liner shown under the group header when it's collapsed.
    /// Funded/empty counts give the user enough signal to decide whether
    /// the group is worth expanding without scanning every row.
    private func collapsedSummary(for group: WalletGroup) -> String {
        let funded = funded(group).count
        let total = group.wallets.count
        if funded == 0 {
            return L10n.WalletHome.collapsedAllEmpty(total)
        }
        return L10n.WalletHome.collapsedFundedOfTotal(funded, total)
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

struct WalletGroupHeader: View {
    let label: String
    let threshold: Int
    let total: Int
    /// Stable account identity — used by WalletAvatarView to look up the
    /// user-chosen emoji/color. Falls back to a deterministic gradient
    /// monogram when no avatar is set.
    var accountId: String = ""
    /// Non-nil when every EVM wallet in the group shares the same address;
    /// shown as a copy-able chip so each row doesn't repeat the hex string.
    let sharedAddress: String?
    /// When non-nil the header renders a chevron and flips it based on
    /// `isCollapsed`. The tap handler lives on the caller's Button.
    var isCollapsed: Bool? = nil
    /// Optional summary shown when the group is collapsed — replaces the
    /// shared-address chip so a folded row stays one line tall.
    var collapsedSummary: String? = nil

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if !accountId.isEmpty {
                    WalletAvatarView(accountId: accountId, fallbackText: label, size: 32)
                } else {
                    Image(systemName: "key.horizontal.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(HorcruxTheme.accentPurple)
                }
                Text(label)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if threshold > 0 && total > 0 {
                    Text(L10n.Shards.thresholdValue(threshold, total))
                        .font(.caption2.weight(.medium).monospacedDigit())
                        .foregroundStyle(HorcruxTheme.subtleText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(HorcruxTheme.subtleText.opacity(0.12))
                        )
                }
                Spacer(minLength: 8)
                if isCollapsed == true, let summary = collapsedSummary {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(HorcruxTheme.subtleText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let collapsed = isCollapsed {
                    Image(systemName: "chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(HorcruxTheme.subtleText)
                        .frame(width: 28, height: 28)
                        .background(
                            Circle().fill(HorcruxTheme.subtleText.opacity(0.08))
                        )
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                        .animation(.easeInOut(duration: 0.22), value: collapsed)
                        .accessibilityHidden(true)
                }
            }
            if isCollapsed != true, let addr = sharedAddress {
                Button {
                    SecureClipboard.copy(addr)
                    Haptics.success()
                    withAnimation { copied = true }
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        await MainActor.run { withAnimation { copied = false } }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "link.circle.fill")
                            .font(.caption)
                            .foregroundStyle(HorcruxTheme.accentCyan)
                        Text(shortAddress(addr))
                            .font(.caption.monospaced())
                            .foregroundStyle(.white.opacity(0.85))
                        Spacer()
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption2)
                            .foregroundStyle(copied ? HorcruxTheme.successGreen : HorcruxTheme.subtleText)
                        Text(L10n.WalletHome.sharedAddressHint)
                            .font(.caption2)
                            .foregroundStyle(HorcruxTheme.subtleText)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        HorcruxTheme.accentCyan.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(HorcruxTheme.cardSurface.opacity(isCollapsed == true ? 0.55 : 0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(HorcruxTheme.cardBorder.opacity(0.4), lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    private func shortAddress(_ a: String) -> String {
        guard a.count > 12 else { return a }
        return "\(a.prefix(6))…\(a.suffix(4))"
    }
}

struct WalletRow: View {
    let wallet: Wallet
    /// When true, render the N-of-M shard badge on the row. Usually false:
    /// the group header above the row already shows threshold, so rendering
    /// it again per row is redundant. Only shown for solo wallets that
    /// don't have a group header.
    var showThresholdBadge: Bool = false
    /// When true, suppress the per-row address line. Used for EVM rows
    /// inside a group whose header already advertises the shared address.
    var hideAddress: Bool = false
    @EnvironmentObject private var appState: AppState
    @StateObject private var priceService = PriceService.shared
    @ObservedObject private var balanceCache = BalanceCache.shared
    @State private var isLoading = false

    private var balance: String? { balanceCache.cachedRaw(walletId: wallet.id) }

    /// Returns true when we have a cached balance and it parses to 0.
    /// Used to visually demote empty rows so the list shows a clear
    /// hierarchy between funded and untouched chains.
    private var isZeroBalance: Bool {
        guard let balance else { return false }
        let parts = balance.split(separator: " ", maxSplits: 1).map(String.init)
        guard let amount = Double(parts.first?.replacingOccurrences(of: ",", with: "") ?? "") else { return false }
        return amount == 0
    }

    var body: some View {
        HStack(spacing: 14) {
            ChainIcon(chain: wallet.chain, size: 44)
                .saturation(isZeroBalance ? 0.5 : 1.0)
                .opacity(isZeroBalance ? 0.6 : 1.0)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(wallet.chain.displayName)
                    .font(.headline)
                    .foregroundStyle(isZeroBalance ? HorcruxTheme.subtleText : .white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                if !hideAddress {
                    Text(shortAddress(wallet.address))
                        .font(.caption)
                        .foregroundStyle(HorcruxTheme.subtleText)
                        .monospaced()
                        .opacity(isZeroBalance ? 0.7 : 1.0)
                        .lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                if isLoading {
                    ProgressView().scaleEffect(0.7).tint(HorcruxTheme.accentPurple)
                        .accessibilityLabel(L10n.WalletHome.loadingBalance)
                } else if let balance {
                    Text(balance)
                        .font(.subheadline.bold().monospacedDigit())
                        .foregroundStyle(isZeroBalance ? HorcruxTheme.subtleText : .white)
                        .lineLimit(1)
                        .accessibilityLabel("Balance: \(balance)")
                    HStack(spacing: 6) {
                        if let fiat = fiatEstimate(from: balance) {
                            Text(fiat)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(HorcruxTheme.subtleText)
                                .opacity(isZeroBalance ? 0.7 : 1.0)
                                .lineLimit(1)
                        }
                        if let change = priceService.change24h(symbol: wallet.chain.symbol) {
                            PriceChangeBadge(percent: change)
                                .opacity(isZeroBalance ? 0.6 : 1.0)
                                .fixedSize()
                        }
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
        .tintedGlassCard(color: wallet.chain.color)
        .opacity(isZeroBalance ? 0.82 : 1.0)
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
    @StateObject private var priceService = PriceService.shared
    @ObservedObject private var balanceCache = BalanceCache.shared
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
                            .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white)
                            .minimumScaleFactor(0.55)
                            .lineLimit(1)
                            .accessibilityLabel("Balance: \(balance)")
                            .accessibilityIdentifier("walletDetail_balance")

                        HStack(spacing: 8) {
                            if let fiat = fiatString(from: balance) {
                                Text(fiat)
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(HorcruxTheme.subtleText)
                            }
                            if let change = priceService.change24h(symbol: wallet.chain.symbol) {
                                PriceChangeBadge(percent: change)
                            }
                        }

                        if let spark = priceService.sparkline24h(symbol: wallet.chain.symbol), spark.count >= 2 {
                            Sparkline(values: spark, height: 36)
                                .frame(maxWidth: 220)
                        }
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
                .tintedGlassCard(color: wallet.chain.color, padding: 24)

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
                                .fill(wallet.chain.color.opacity(wallet.chain.signingSupported ? 0.22 : 0.06))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(wallet.chain.color.opacity(wallet.chain.signingSupported ? 0.45 : 0.12), lineWidth: 1))
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
                        detailRow(L10n.WalletDetail.chain, value: wallet.chain.displayName)
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
            priceService.refreshIfNeeded()
            priceService.refreshSparklinesIfNeeded()
        }
        .refreshable {
            await fetchBalance()
            await fetchTokenBalances()
            priceService.refreshIfNeeded()
            priceService.refreshSparklinesIfNeeded()
        }
    }

    /// Extracts the numeric portion of a balance string like "1.234 ETH"
    /// and converts it to a USD estimate via PriceService. Returns nil
    /// when the quote or parse fails.
    private func fiatString(from balance: String) -> String? {
        let parts = balance.split(separator: " ", maxSplits: 1).map(String.init)
        guard let numericPart = parts.first,
              let amount = Double(numericPart.replacingOccurrences(of: ",", with: "")) else { return nil }
        return priceService.fiatString(amount: amount, symbol: wallet.chain.symbol)
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
    @AppStorage("portfolio.valueHidden") private var valueHidden: Bool = false
    @State private var showBreakdown = false

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
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { valueHidden.toggle() }
                    Haptics.selection()
                } label: {
                    Image(systemName: valueHidden ? "eye.slash.fill" : "eye.fill")
                        .font(.subheadline)
                        .foregroundStyle(HorcruxTheme.subtleText)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(valueHidden ? "Show balance" : "Hide balance")
            }
            HStack(alignment: .firstTextBaseline) {
                Text(valueHidden ? "••••••" : totalFiatString)
                    .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.55)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Sparkline(values: portfolioSparkline, height: 32)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(valueHidden ? 0.25 : 1.0)
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
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .opacity(valueHidden ? 0.0 : 1.0)
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
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.selection()
            showBreakdown = true
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Show per-chain breakdown")
        .accessibilityIdentifier("portfolio_summaryCard")
        .task {
            await refreshAll()
        }
        .sheet(isPresented: $showBreakdown) {
            PortfolioBreakdownSheet(wallets: wallets)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    /// Weighted 24h portfolio sparkline. For each of the 24 hourly buckets,
    /// multiplies per-chain historical price by the wallet's current native
    /// amount (we don't track historical balances, only historical prices —
    /// this approximates 'how the portfolio's current composition moved').
    private var portfolioSparkline: [Double] {
        var holdings: [String: Double] = [:]
        for w in wallets {
            let amount = balanceCache.nativeAmount(walletId: w.id) ?? 0
            holdings[w.chain.symbol, default: 0] += amount
        }
        var bucketValues = Array(repeating: 0.0, count: 24)
        var anyData = false
        for (symbol, amount) in holdings where amount > 0 {
            guard let spark = priceService.sparkline24h(symbol: symbol) else { continue }
            anyData = true
            let padded: [Double] = spark.count >= 24
                ? Array(spark.suffix(24))
                : Array(repeating: spark.first ?? 0, count: 24 - spark.count) + spark
            for i in 0..<24 {
                bucketValues[i] += padded[i] * amount
            }
        }
        return anyData ? bucketValues : []
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
        priceService.refreshSparklinesIfNeeded()
        isLoading = true
        defer { isLoading = false }
        await BalanceCache.shared.refreshAll(
            wallets: wallets,
            service: appState.blockchainService,
            config: appState.networkConfig
        )
    }
}

// MARK: - Portfolio Breakdown Sheet

/// Per-chain allocation sheet shown when the portfolio summary card is
/// tapped. Groups wallets by chain, sums USD values across accounts, and
/// renders a tinted row per chain with amount, value, 24h change, and
/// percentage share of the portfolio (visualised as a filled bar).
struct PortfolioBreakdownSheet: View {
    let wallets: [Wallet]
    @Environment(\.dismiss) private var dismiss
    @StateObject private var priceService = PriceService.shared
    @ObservedObject private var balanceCache = BalanceCache.shared

    /// Collapses wallets by chain and computes per-chain allocation data.
    private struct Slice: Identifiable {
        let chain: Chain
        let nativeAmount: Double
        let usdValue: Double
        let change24h: Double?
        var id: Chain { chain }
    }

    private var slices: [Slice] {
        var bucket: [Chain: Double] = [:]
        for w in wallets {
            guard let amount = balanceCache.nativeAmount(walletId: w.id) else { continue }
            bucket[w.chain, default: 0] += amount
        }
        let rows: [Slice] = bucket.compactMap { chain, amount in
            let price = priceService.usdPrice(symbol: chain.symbol) ?? 0
            let usd = amount * price
            return Slice(
                chain: chain,
                nativeAmount: amount,
                usdValue: usd,
                change24h: priceService.change24h(symbol: chain.symbol)
            )
        }
        return rows.sorted { $0.usdValue > $1.usdValue }
    }

    private var totalUSD: Double {
        slices.reduce(0) { $0 + $1.usdValue }
    }

    private static let fiatFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.maximumFractionDigits = 2
        return f
    }()

    var body: some View {
        NavigationStack {
            ZStack {
                HorcruxTheme.backgroundGradient.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 12) {
                        header
                        if slices.filter({ $0.usdValue > 0 }).isEmpty {
                            emptyState
                        } else {
                            ForEach(slices) { slice in
                                sliceRow(slice)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
            .navigationTitle("Portfolio Breakdown")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(HorcruxTheme.accentBlue)
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text("Total Across All Chains")
                .font(.caption)
                .foregroundStyle(HorcruxTheme.subtleText)
            Text(Self.fiatFormatter.string(from: NSNumber(value: totalUSD)) ?? "$—")
                .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.pie")
                .font(.largeTitle)
                .foregroundStyle(HorcruxTheme.subtleText)
            Text("No balances yet")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
            Text("Pull to refresh on the main screen once your wallets are funded.")
                .font(.caption)
                .foregroundStyle(HorcruxTheme.subtleText)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .glassCard()
    }

    @ViewBuilder
    private func sliceRow(_ slice: Slice) -> some View {
        let pct: Double = totalUSD > 0 ? (slice.usdValue / totalUSD) : 0
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ChainIcon(chain: slice.chain, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(slice.chain.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(CurrencyFormatter.crypto(slice.nativeAmount, symbol: slice.chain.symbol))
                        .font(.caption)
                        .foregroundStyle(HorcruxTheme.subtleText)
                        .monospacedDigit()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Self.fiatFormatter.string(from: NSNumber(value: slice.usdValue)) ?? "—")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                    if let change = slice.change24h {
                        HStack(spacing: 3) {
                            Image(systemName: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                                .font(.caption2.weight(.bold))
                            Text(String(format: "%@%.2f%%", change >= 0 ? "+" : "", change))
                                .font(.caption2.weight(.medium).monospacedDigit())
                        }
                        .foregroundStyle(change >= 0 ? HorcruxTheme.successGreen : HorcruxTheme.dangerRed)
                    }
                }
            }

            // Allocation bar: chain-tinted fill proportional to share of total.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.06))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [slice.chain.color, slice.chain.color.opacity(0.6)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(6, geo.size.width * pct))
                }
            }
            .frame(height: 6)

            HStack {
                Text(String(format: "%.1f%% of portfolio", pct * 100))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(HorcruxTheme.subtleText)
                Spacer()
            }
        }
        .tintedGlassCard(color: slice.chain.color, padding: 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(slice.chain.displayName): \(Self.fiatFormatter.string(from: NSNumber(value: slice.usdValue)) ?? ""), \(String(format: "%.1f", pct * 100)) percent of portfolio")
    }
}
