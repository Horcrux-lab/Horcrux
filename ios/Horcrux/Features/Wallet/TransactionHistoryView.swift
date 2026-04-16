import SwiftUI

/// Lists past transactions for a wallet with status indicators.
struct TransactionHistoryView: View {
    let wallet: Wallet
    @EnvironmentObject private var appState: AppState
    @ScaledMetric(relativeTo: .largeTitle) private var emptyIconSize: CGFloat = 48

    private var transactions: [TransactionRecord] {
        appState.transactionStore.records(for: wallet.id)
    }

    var body: some View {
        Group {
            if transactions.isEmpty {
                emptyState
            } else {
                transactionList
            }
        }
        .navigationTitle(L10n.TxHistory.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: emptyIconSize))
                .foregroundStyle(.tertiary)
            Text(L10n.TxHistory.noTransactionsTitle)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(L10n.TxHistory.noTransactionsSubtitle)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
    }

    private var transactionList: some View {
        List(transactions) { tx in
            NavigationLink {
                TransactionDetailView(transaction: tx)
            } label: {
                TransactionRow(transaction: tx)
            }
        }
    }
}

// MARK: - Row

struct TransactionRow: View {
    let transaction: TransactionRecord

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Image(systemName: transaction.statusIcon)
                    .font(.title3)
                    .foregroundStyle(statusColor)
                    .frame(width: 32)

                if transaction.status == .broadcast {
                    ProgressView()
                        .scaleEffect(0.6)
                        .offset(x: 12, y: 10)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(L10n.TxHistory.sendSymbol(transaction.chain.symbol))
                        .font(.subheadline.bold())
                    if transaction.status == .broadcast {
                        Text(L10n.TxHistory.confirming)
                            .font(.caption2)
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.1), in: Capsule())
                    }
                    Spacer()
                    Text(CurrencyFormatter.crypto(Double(transaction.amount) ?? 0, symbol: transaction.chain.symbol))
                        .font(.subheadline.bold())
                }

                HStack {
                    Text("→ " + shortAddress(transaction.toAddress))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospaced()
                    Spacer()
                    Text(transaction.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var statusColor: Color {
        switch transaction.status {
        case .signed:    return .orange
        case .broadcast: return .blue
        case .confirmed: return .green
        case .failed:    return .red
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
    @ScaledMetric(relativeTo: .largeTitle) private var statusIconSize: CGFloat = 48

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: transaction.statusIcon)
                        .font(.system(size: statusIconSize))
                        .foregroundStyle(detailStatusColor)

                    Text(CurrencyFormatter.crypto(Double(transaction.amount) ?? 0, symbol: transaction.chain.symbol))
                        .font(.title2.bold())

                    statusBadge
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical)
            }

            Section(L10n.TxDetail.details) {
                LabeledContent(L10n.TxDetail.chain, value: transaction.chain.rawValue)

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.TxDetail.from)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(transaction.fromAddress)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.TxDetail.to)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(transaction.toAddress)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }

                if let fee = transaction.fee {
                    LabeledContent(L10n.TxDetail.fee, value: fee)
                }

                LabeledContent(L10n.TxDetail.signed, value: transaction.createdAt.formatted(date: .abbreviated, time: .standard))

                if let broadcastAt = transaction.broadcastAt {
                    LabeledContent(L10n.TxDetail.broadcast, value: broadcastAt.formatted(date: .abbreviated, time: .standard))
                }
            }

            if let txHash = transaction.txHash, !txHash.isEmpty {
                Section(L10n.TxDetail.transactionHash) {
                    Text(txHash)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)

                    Button {
                        SecureClipboard.copy(txHash)
                        copiedHash = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedHash = false }
                    } label: {
                        Label(copiedHash ? L10n.TxDetail.copied : L10n.TxDetail.copyHash, systemImage: copiedHash ? "checkmark" : "doc.on.doc")
                    }

                    if let url = transaction.explorerURL {
                        Link(destination: url) {
                            Label(L10n.TxDetail.viewOnExplorer, systemImage: "safari")
                        }
                    }
                }
            }
        }
        .navigationTitle(L10n.TxDetail.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var detailStatusColor: Color {
        switch transaction.status {
        case .signed:    return .orange
        case .broadcast: return .blue
        case .confirmed: return .green
        case .failed:    return .red
        }
    }

    private var statusBadge: some View {
        Text(transaction.status.rawValue.capitalized)
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(detailStatusColor.opacity(0.15), in: Capsule())
            .foregroundStyle(detailStatusColor)
    }
}
