import SwiftUI

/// Lists past transactions for a wallet with status indicators.
struct TransactionHistoryView: View {
    let wallet: Wallet
    @EnvironmentObject private var appState: AppState

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
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No Transactions Yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Signed and broadcast transactions\nwill appear here.")
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
                    Text("Send \(transaction.chain.symbol)")
                        .font(.subheadline.bold())
                    if transaction.status == .broadcast {
                        Text("Confirming…")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.1), in: Capsule())
                    }
                    Spacer()
                    Text(transaction.amount + " " + transaction.chain.symbol)
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

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: transaction.statusIcon)
                        .font(.system(size: 48))
                        .foregroundStyle(detailStatusColor)

                    Text(transaction.amount + " " + transaction.chain.symbol)
                        .font(.title2.bold())

                    statusBadge
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical)
            }

            Section("Details") {
                LabeledContent("Chain", value: transaction.chain.rawValue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("From")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(transaction.fromAddress)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("To")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(transaction.toAddress)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }

                if let fee = transaction.fee {
                    LabeledContent("Fee", value: fee)
                }

                LabeledContent("Signed", value: transaction.createdAt.formatted(date: .abbreviated, time: .standard))

                if let broadcastAt = transaction.broadcastAt {
                    LabeledContent("Broadcast", value: broadcastAt.formatted(date: .abbreviated, time: .standard))
                }
            }

            if let txHash = transaction.txHash, !txHash.isEmpty {
                Section("Transaction Hash") {
                    Text(txHash)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)

                    Button {
                        SecureClipboard.copy(txHash)
                        copiedHash = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedHash = false }
                    } label: {
                        Label(copiedHash ? "Copied" : "Copy Hash", systemImage: copiedHash ? "checkmark" : "doc.on.doc")
                    }

                    if let url = transaction.explorerURL {
                        Link(destination: url) {
                            Label("View on Explorer", systemImage: "safari")
                        }
                    }
                }
            }
        }
        .navigationTitle("Transaction")
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
