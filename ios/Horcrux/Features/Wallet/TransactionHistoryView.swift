import SwiftUI
import UniformTypeIdentifiers

/// Lists past transactions for a wallet — dark glass card design.
struct TransactionHistoryView: View {
    let wallet: Wallet
    @EnvironmentObject private var appState: AppState
    @State private var isSyncing = false
    @State private var syncResult: String?
    @State private var searchText = ""
    @State private var statusFilter: StatusFilter = .all
    @State private var showExporter = false
    @State private var exportDoc: CSVDocument?

    enum StatusFilter: String, CaseIterable, Identifiable {
        case all, pending, confirmed, failed
        var id: Self { self }
        var label: String {
            switch self {
            case .all: return L10n.TxHistory.filterAll
            case .pending: return L10n.TxHistory.filterPending
            case .confirmed: return L10n.TxHistory.filterConfirmed
            case .failed: return L10n.TxHistory.filterFailed
            }
        }
    }

    private var transactions: [TransactionRecord] {
        let base = appState.transactionStore.records(for: wallet.id)
        let filtered = base.filter { rec in
            switch statusFilter {
            case .all: return true
            case .pending: return rec.status == .signed || rec.status == .broadcast
            case .confirmed: return rec.status == .confirmed
            case .failed: return rec.status == .failed
            }
        }
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return filtered }
        return filtered.filter {
            $0.toAddress.lowercased().contains(needle)
                || $0.fromAddress.lowercased().contains(needle)
                || ($0.txHash ?? "").lowercased().contains(needle)
                || $0.amount.lowercased().contains(needle)
        }
    }

    var body: some View {
        ZStack {
            HorcruxTheme.backgroundGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                Picker(L10n.TxHistory.statusPickerLabel, selection: $statusFilter) {
                    ForEach(StatusFilter.allCases) { f in
                        Text(f.label).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 12)

                Group {
                    if transactions.isEmpty {
                        emptyState
                    } else {
                        transactionList
                    }
                }
            }
        }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: Text(L10n.TxHistory.searchPrompt))
        .navigationTitle(L10n.TxHistory.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task { await sync() }
                    } label: {
                        Label(L10n.TxHistory.refresh, systemImage: "arrow.clockwise")
                    }
                    Button {
                        exportDoc = CSVDocument(csv: buildCSV())
                        showExporter = true
                    } label: {
                        Label(L10n.TxHistory.exportCSV, systemImage: "square.and.arrow.up")
                    }
                    .disabled(transactions.isEmpty)
                } label: {
                    if isSyncing {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                .disabled(isSyncing)
                .accessibilityIdentifier("txHistory_syncButton")
            }
        }
        .fileExporter(
            isPresented: $showExporter,
            document: exportDoc,
            contentType: .commaSeparatedText,
            defaultFilename: "horcrux-\(wallet.chain.symbol.lowercased())-\(Int(Date().timeIntervalSince1970))"
        ) { _ in }
        .refreshable { await sync() }
        .task {
            // Auto-sync on first open so the user sees fresh data without
            // needing pull-to-refresh. `sync()` is guarded by `isSyncing`,
            // so subsequent re-entries won't double-fire.
            await sync()
        }
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
            syncResult = L10n.TxHistory.syncedNew(inserted)
        } else {
            syncResult = L10n.TxHistory.syncUpToDate
        }
        try? await Task.sleep(nanoseconds: 1_800_000_000)
        withAnimation { syncResult = nil }
    }

    /// Build a CSV of the currently-filtered transactions.
    private func buildCSV() -> String {
        let df = ISO8601DateFormatter()
        var lines = ["date,status,chain,from,to,amount,fee,tx_hash"]
        for rec in transactions {
            let date = df.string(from: rec.createdAt)
            let row = [
                date,
                rec.status.rawValue,
                rec.chain.symbol,
                rec.fromAddress,
                rec.toAddress,
                rec.amount,
                rec.fee ?? "",
                rec.txHash ?? ""
            ].map { csvEscape($0) }.joined(separator: ",")
            lines.append(row)
        }
        return lines.joined(separator: "\n")
    }

    private func csvEscape(_ s: String) -> String {
        guard s.contains(",") || s.contains("\"") || s.contains("\n") else { return s }
        return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
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
                        TransactionRow(transaction: tx, walletAddress: wallet.address)
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
    let walletAddress: String
    @State private var ensName: String?

    /// A record counts as incoming when its `toAddress` matches our
    /// wallet address (case-insensitive — EVM checksummed hex + Solana
    /// base58 are both safe to lowercase for equality). Locally-signed
    /// outgoing records always take the opposite branch because we
    /// record `fromAddress = wallet.address` when we sign.
    private var isIncoming: Bool {
        transaction.toAddress.lowercased() == walletAddress.lowercased()
            && transaction.fromAddress.lowercased() != walletAddress.lowercased()
    }

    private var counterparty: String {
        isIncoming ? transaction.fromAddress : transaction.toAddress
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.15))
                    .frame(width: 36, height: 36)

                Image(systemName: iconName)
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
                    Text(isIncoming
                         ? L10n.Receive.receiveSymbol(transaction.chain.symbol)
                         : L10n.TxHistory.sendSymbol(transaction.chain.symbol))
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
                    Text((isIncoming ? "+" : "-") + CurrencyFormatter.crypto(Double(transaction.amount) ?? 0, symbol: transaction.chain.symbol))
                        .font(.subheadline.bold().monospacedDigit())
                        .foregroundStyle(isIncoming ? HorcruxTheme.successGreen : .white)
                }

                HStack {
                    Group {
                        if let ens = ensName {
                            Text((isIncoming ? "← " : "→ ") + ens)
                                .foregroundStyle(HorcruxTheme.accentBlue)
                        } else {
                            Text((isIncoming ? "← " : "→ ") + shortAddress(AddressFormatter.canonical(counterparty, chain: transaction.chain)))
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
        .task(id: counterparty) {
            // Only Ethereum mainnet has ENS. Kick off a best-effort reverse
            // lookup once per row; results are memoised in ENSResolver so
            // this won't hammer the RPC on re-renders.
            guard transaction.chain == .ethereum else { return }
            ensName = await ENSResolver.reverse(counterparty)
        }
    }

    /// Override the status icon for confirmed incoming records — the
    /// default `checkmark.seal.fill` reads as "I sent this"; an arrow
    /// down into a tray reads as "received". Other statuses keep the
    /// existing icon so pending/failed semantics stay unchanged.
    private var iconName: String {
        if isIncoming && transaction.status == .confirmed {
            return "arrow.down.circle.fill"
        }
        return transaction.statusIcon
    }

    private var statusColor: Color {
        if isIncoming && transaction.status == .confirmed {
            return HorcruxTheme.successGreen
        }
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
    @EnvironmentObject private var appState: AppState
    let transaction: TransactionRecord
    @State private var copiedHash = false
    @State private var showRBFSigner = false

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

                    if let fiat = fiatAmount {
                        Text(fiat)
                            .font(.subheadline.weight(.medium).monospacedDigit())
                            .foregroundStyle(HorcruxTheme.subtleText)
                    }

                    statusBadge
                }
                .frame(maxWidth: .infinity)
                .glassCard(padding: 24)

                // Details
                VStack(alignment: .leading, spacing: 10) {
                    VaultSectionHeader(L10n.TxDetail.details, icon: "doc.text")
                        .padding(.horizontal, 4)

                    VStack(spacing: 0) {
                        detailRow(L10n.TxDetail.chain, value: transaction.chain.displayName)
                        Divider().background(HorcruxTheme.hairline)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.TxDetail.from)
                                .font(.caption)
                                .foregroundStyle(HorcruxTheme.subtleText)
                            Text(AddressFormatter.chunked(AddressFormatter.canonical(transaction.fromAddress, chain: transaction.chain)))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.white)
                                .textSelection(.enabled)
                                .accessibilityValue(transaction.fromAddress)
                        }
                        .padding(.vertical, 10)
                        Divider().background(HorcruxTheme.hairline)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.TxDetail.to)
                                .font(.caption)
                                .foregroundStyle(HorcruxTheme.subtleText)
                            Text(AddressFormatter.chunked(AddressFormatter.canonical(transaction.toAddress, chain: transaction.chain)))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.white)
                                .textSelection(.enabled)
                                .accessibilityValue(transaction.toAddress)
                        }
                        .padding(.vertical, 10)

                        if let fee = transaction.fee {
                            Divider().background(HorcruxTheme.hairline)
                            detailRow(L10n.TxDetail.fee, value: fee)
                        }

                        Divider().background(HorcruxTheme.hairline)
                        detailRow(L10n.TxDetail.signed, value: transaction.createdAt.formatted(date: .abbreviated, time: .standard))

                        if let broadcastAt = transaction.broadcastAt {
                            Divider().background(HorcruxTheme.hairline)
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

                        if canRBF {
                            Button {
                                showRBFSigner = true
                            } label: {
                                Label(L10n.TxHistory.speedUpRBF, systemImage: "hare.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(HorcruxTheme.accentCyan)

                            Text(L10n.TxHistory.speedUpRBFBody)
                                .font(.caption)
                                .foregroundStyle(HorcruxTheme.subtleText)
                                .padding(.horizontal, 4)
                        }
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
        .sheet(isPresented: $showRBFSigner) {
            if let wallet = rbfWallet {
                SigningView(wallet: wallet, rbfFrom: transaction)
            }
        }
    }

    private var rbfWallet: Wallet? {
        appState.walletStore.wallets.first { $0.id == transaction.walletId }
    }

    /// Best-effort USD conversion using PriceService's cached quotes.
    /// Returns nil if no price is cached (caller shouldn't block on network).
    private var fiatAmount: String? {
        let raw = transaction.amount.split(separator: " ").first.map(String.init) ?? transaction.amount
        guard let value = Double(raw) else { return nil }
        return PriceService.shared.fiatString(amount: value, symbol: transaction.chain.symbol)
    }

    /// Only BTC/LTC broadcast-but-not-confirmed txs are eligible for RBF.
    /// We also require a wallet still exists to re-drive signing.
    private var canRBF: Bool {
        guard transaction.chain == .bitcoin || transaction.chain == .litecoin else { return false }
        guard transaction.status == .broadcast else { return false }
        guard transaction.txHash != nil, !(transaction.txHash ?? "").isEmpty else { return false }
        return rbfWallet != nil
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
        Text(statusLabel)
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(detailStatusColor.opacity(0.15), in: Capsule())
            .foregroundStyle(detailStatusColor)
    }

    private var statusLabel: String {
        switch transaction.status {
        case .signed:    return L10n.TxDetail.statusSigned
        case .broadcast: return L10n.TxDetail.statusBroadcast
        case .confirmed: return L10n.TxDetail.statusConfirmed
        case .failed:    return L10n.TxDetail.statusFailed
        }
    }
}

/// Wraps CSV text for `.fileExporter`. Text is UTF-8 with a BOM so Excel
/// opens non-ASCII characters correctly.
struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var csv: String

    init(csv: String) { self.csv = csv }

    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents,
           let s = String(data: data, encoding: .utf8) {
            csv = s
        } else {
            csv = ""
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(csv.data(using: .utf8) ?? Data())
        return FileWrapper(regularFileWithContents: data)
    }
}
