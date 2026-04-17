import SwiftUI

/// Lists past transactions for a wallet — dark glass card design.
struct TransactionHistoryView: View {
    let wallet: Wallet
    @EnvironmentObject private var appState: AppState
    @State private var isSyncing = false
    @State private var syncResult: String?

    private var transactions: [TransactionRecord] {
        appState.transactionStore.records(for: wallet.id)
    }

    var body: some View {
        ZStack {
            HorcruxTheme.backgroundGradient.ignoresSafeArea()

            Group {
                if transactions.isEmpty {
                    emptyState
                } else {
                    transactionList
                }
            }
        }
        .navigationTitle(L10n.TxHistory.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await sync() }
                } label: {
                    if isSyncing {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isSyncing)
                .accessibilityIdentifier("txHistory_syncButton")
            }
        }
        .refreshable { await sync() }
        .overlay(alignment: .bottom) {
            if let syncResult {
                Text(syncResult)
                    .font(.caption)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .padding(.bottom, 20)
                    .transition(.opacity)
            }
        }
    }

    @MainActor
    private func sync() async {
        guard !isSyncing else { return }
        isSyncing = true
        let syncer = TransactionHistorySyncer(
            store: appState.transactionStore,
            service: appState.blockchainService,
            config: appState.networkConfig
        )
        let inserted = await syncer.sync(wallet: wallet)
        isSyncing = false
        if inserted > 0 {
            syncResult = "已同步 \(inserted) 条新记录"
        } else {
            syncResult = "已是最新"
        }
        try? await Task.sleep(nanoseconds: 1_800_000_000)
        withAnimation { syncResult = nil }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            VaultEmptyState(
                icon: "clock.arrow.circlepath",
                title: L10n.TxHistory.noTransactionsTitle,
                subtitle: L10n.TxHistory.noTransactionsSubtitle,
                iconSize: 48
            )
            Spacer()
        }
    }

    private var transactionList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(transactions) { tx in
                    NavigationLink {
                        TransactionDetailView(transaction: tx)
                    } label: {
                        TransactionRow(transaction: tx)
                            .glassCard()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Row

struct TransactionRow: View {
    let transaction: TransactionRecord
    @State private var ensName: String?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.15))
                    .frame(width: 36, height: 36)

                Image(systemName: transaction.statusIcon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(statusColor)

                if transaction.status == .broadcast {
                    ProgressView()
                        .scaleEffect(0.5)
                        .tint(statusColor)
                        .offset(x: 14, y: 12)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(L10n.TxHistory.sendSymbol(transaction.chain.symbol))
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                    if transaction.status == .broadcast {
                        Text(L10n.TxHistory.confirming)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(HorcruxTheme.accentBlue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(HorcruxTheme.accentBlue.opacity(0.15), in: Capsule())
                    }
                    Spacer()
                    Text(CurrencyFormatter.crypto(Double(transaction.amount) ?? 0, symbol: transaction.chain.symbol))
                        .font(.subheadline.bold().monospacedDigit())
                        .foregroundStyle(.white)
                }

                HStack {
                    Group {
                        if let ens = ensName {
                            Text("→ " + ens)
                                .foregroundStyle(HorcruxTheme.accentBlue)
                        } else {
                            Text("→ " + shortAddress(transaction.toAddress))
                                .foregroundStyle(HorcruxTheme.subtleText)
                                .monospaced()
                        }
                    }
                    .font(.caption)
                    Spacer()
                    Text(transaction.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(HorcruxTheme.subtleText)
                }
            }
        }
        .task(id: transaction.toAddress) {
            // Only Ethereum mainnet has ENS. Kick off a best-effort reverse
            // lookup once per row; results are memoised in ENSResolver so
            // this won't hammer the RPC on re-renders.
            guard transaction.chain == .ethereum else { return }
            ensName = await ENSResolver.reverse(transaction.toAddress)
        }
    }

    private var statusColor: Color {
        switch transaction.status {
        case .signed:    return HorcruxTheme.warningAmber
        case .broadcast: return HorcruxTheme.accentBlue
        case .confirmed: return HorcruxTheme.successGreen
        case .failed:    return HorcruxTheme.dangerRed
        }
    }

    private func shortAddress(_ address: String) -> String {
        guard address.count > 12 else { return address }
        return "\(address.prefix(6))…\(address.suffix(4))"
    }
}

// MARK: - Detail

struct TransactionDetailView: View {
    let transaction: TransactionRecord
    @State private var copiedHash = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Hero
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(detailStatusColor.opacity(0.15))
                            .frame(width: 64, height: 64)

                        Image(systemName: transaction.statusIcon)
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(detailStatusColor)
                    }
                    .shadow(color: detailStatusColor.opacity(0.3), radius: 8)

                    Text(CurrencyFormatter.crypto(Double(transaction.amount) ?? 0, symbol: transaction.chain.symbol))
                        .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)

                    statusBadge
                }
                .frame(maxWidth: .infinity)
                .glassCard(padding: 24)

                // Details
                VStack(alignment: .leading, spacing: 10) {
                    VaultSectionHeader(L10n.TxDetail.details, icon: "doc.text")
                        .padding(.horizontal, 4)

                    VStack(spacing: 0) {
                        detailRow(L10n.TxDetail.chain, value: transaction.chain.rawValue)
                        Divider().background(Color.white.opacity(0.06))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.TxDetail.from)
                                .font(.caption)
                                .foregroundStyle(HorcruxTheme.subtleText)
                            Text(transaction.fromAddress)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.white)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 10)
                        Divider().background(Color.white.opacity(0.06))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.TxDetail.to)
                                .font(.caption)
                                .foregroundStyle(HorcruxTheme.subtleText)
                            Text(transaction.toAddress)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.white)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 10)

                        if let fee = transaction.fee {
                            Divider().background(Color.white.opacity(0.06))
                            detailRow(L10n.TxDetail.fee, value: fee)
                        }

                        Divider().background(Color.white.opacity(0.06))
                        detailRow(L10n.TxDetail.signed, value: transaction.createdAt.formatted(date: .abbreviated, time: .standard))

                        if let broadcastAt = transaction.broadcastAt {
                            Divider().background(Color.white.opacity(0.06))
                            detailRow(L10n.TxDetail.broadcast, value: broadcastAt.formatted(date: .abbreviated, time: .standard))
                        }
                    }
                    .glassCard()
                }

                if let txHash = transaction.txHash, !txHash.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        VaultSectionHeader(L10n.TxDetail.transactionHash, icon: "number")
                            .padding(.horizontal, 4)

                        VStack(spacing: 12) {
                            Text(txHash)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(HorcruxTheme.subtleText)
                                .textSelection(.enabled)

                            HStack(spacing: 12) {
                                Button {
                                    SecureClipboard.copy(txHash)
                                    copiedHash = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedHash = false }
                                } label: {
                                    Label(copiedHash ? L10n.TxDetail.copied : L10n.TxDetail.copyHash, systemImage: copiedHash ? "checkmark" : "doc.on.doc")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(HorcruxTheme.accentPurple)
                                }

                                if let url = transaction.explorerURL {
                                    Link(destination: url) {
                                        Label(L10n.TxDetail.viewOnExplorer, systemImage: "safari")
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(HorcruxTheme.accentBlue)
                                    }
                                }
                            }
                        }
                        .glassCard()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .darkBackground()
        .navigationTitle(L10n.TxDetail.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
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

    private var detailStatusColor: Color {
        switch transaction.status {
        case .signed:    return HorcruxTheme.warningAmber
        case .broadcast: return HorcruxTheme.accentBlue
        case .confirmed: return HorcruxTheme.successGreen
        case .failed:    return HorcruxTheme.dangerRed
        }
    }

    private var statusBadge: some View {
        Text(transaction.status.rawValue.capitalized)
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(detailStatusColor.opacity(0.15), in: Capsule())
            .foregroundStyle(detailStatusColor)
    }
}
