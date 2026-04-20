import SwiftUI
import UniformTypeIdentifiers
import CoreImage.CIFilterBuiltins

// MARK: - Account grouping helper

/// A logical MPC account: all wallets sharing the same groupPublicKey share
/// a single encrypted key share and one party index.
struct ShardAccount: Identifiable {
    let id: String          // accountId (hex groupPublicKey)
    let name: String        // derived "display" name — first wallet's name stripped
    let wallets: [Wallet]   // sorted by chain
    let partyIndex: UInt16
    let threshold: UInt16
    let totalParties: UInt16

    static func group(_ wallets: [Wallet]) -> [ShardAccount] {
        let buckets = Dictionary(grouping: wallets, by: { $0.accountId })
        return buckets
            .map { (key, list) -> ShardAccount in
                let sorted = list.sorted { $0.chain.rawValue < $1.chain.rawValue }
                let first = sorted.first!
                let displayName = first.name
                    .replacingOccurrences(of: " (\(first.chain.rawValue))", with: "")
                    .replacingOccurrences(of: " (\(first.chain.symbol))", with: "")
                return ShardAccount(
                    id: key,
                    name: displayName,
                    wallets: sorted,
                    partyIndex: first.partyIndex,
                    threshold: first.threshold,
                    totalParties: first.totalParties
                )
            }
            .sorted { $0.name < $1.name }
    }
}

// MARK: - Shard List

/// One card per MPC account — a single DKG ceremony may derive multiple
/// chain wallets but they all share the same key share on this device.
struct ShardsListView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var walletStore: WalletStore
    @StateObject private var viewModel = ShardsViewModel()
    @State private var showImportSheet = false

    var body: some View {
        NavigationStack {
            ZStack {
                HorcruxTheme.backgroundGradient.ignoresSafeArea()

                if walletStore.wallets.isEmpty {
                    emptyState
                } else {
                    accountList
                }
            }
            .navigationTitle(L10n.Shards.title)
            .navigationBarTitleDisplayMode(.large)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showImportSheet = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(HorcruxTheme.accentPurple)
                    }
                    .accessibilityLabel(L10n.Shards.restoreFromBackupA11y)
                }
            }
            .sheet(isPresented: $showImportSheet) {
                AccountImportView(viewModel: viewModel)
            }
            .onAppear { viewModel.bind(to: appState) }
            .preferredColorScheme(.dark)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 28) {
            Spacer()
            VaultEmptyState(
                icon: "shield.slash",
                title: L10n.Shards.noShards,
                subtitle: L10n.Shards.noShardsDescription
            )
            Button {
                showImportSheet = true
            } label: {
                Label(L10n.Shards.restoreFromBackupButton, systemImage: "square.and.arrow.down.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(HorcruxTheme.accentPurple.opacity(0.2))
                    .foregroundStyle(HorcruxTheme.accentPurple)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 32)
            Spacer()
        }
    }

    private var accountList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                SecurityHealthCard()

                ForEach(ShardAccount.group(walletStore.wallets)) { account in
                    NavigationLink {
                        ShardAccountDetailView(account: account, viewModel: viewModel)
                    } label: {
                        ShardAccountRow(account: account)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
    }
}

// MARK: - Account Row

struct ShardAccountRow: View {
    let account: ShardAccount

    /// Unique chains on this account, preserving the input sort order
    /// (wallets are already sorted by chain.rawValue).
    private var uniqueChains: [Chain] {
        var seen = Set<Chain>()
        var out: [Chain] = []
        for w in account.wallets where !seen.contains(w.chain) {
            seen.insert(w.chain)
            out.append(w.chain)
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.title2)
                    .foregroundStyle(HorcruxTheme.shieldGradient)
                    .shadow(color: HorcruxTheme.accentPurple.opacity(0.3), radius: 4)

                VStack(alignment: .leading, spacing: 3) {
                    Text(account.name)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(L10n.Shards.myShardFraction(Int(account.partyIndex), Int(account.totalParties)))
                        .font(.caption)
                        .foregroundStyle(HorcruxTheme.subtleText)
                }

                Spacer()

                ShardStatusBadge(threshold: account.threshold, total: account.totalParties)

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(HorcruxTheme.subtleText)
            }

            ChainChipWrap(chains: uniqueChains)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 4)
        .glassCard()
    }
}

/// Wrapping flow of chain short-code chips. Shows up to 8 inline, then
/// a "+N" overflow pill so cards never balloon past two rows.
private struct ChainChipWrap: View {
    let chains: [Chain]
    private let maxInline = 8

    var body: some View {
        let visible = Array(chains.prefix(maxInline))
        let overflow = max(0, chains.count - maxInline)

        FlowHStack(spacing: 6, rowSpacing: 6) {
            ForEach(visible, id: \.self) { chain in
                Text(chain.shortCode)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .foregroundStyle(HorcruxTheme.accentPurple)
                    .background(
                        Capsule()
                            .fill(HorcruxTheme.accentPurple.opacity(0.12))
                            .overlay(Capsule().stroke(HorcruxTheme.accentPurple.opacity(0.25), lineWidth: 0.5))
                    )
            }
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .foregroundStyle(HorcruxTheme.subtleText)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.06))
                            .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 0.5))
                    )
            }
        }
    }
}

/// Minimal wrapping HStack that flows children onto new rows when they
/// exceed the container width. Uses iOS 16 `Layout`.
private struct FlowHStack: Layout {
    var spacing: CGFloat = 6
    var rowSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                totalWidth = max(totalWidth, x - spacing)
                y += rowHeight + rowSpacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalWidth = max(totalWidth, x - spacing)
        return CGSize(width: totalWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth, x > bounds.minX {
                y += rowHeight + rowSpacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: size.width, height: size.height))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Account Detail

struct ShardAccountDetailView: View {
    let account: ShardAccount
    @ObservedObject var viewModel: ShardsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showBackupSheet = false
    @State private var showDeleteConfirm = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Hero
                VStack(spacing: 16) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 48, weight: .thin))
                        .foregroundStyle(HorcruxTheme.shieldGradient)
                        .shadow(color: HorcruxTheme.accentPurple.opacity(0.4), radius: 8)

                    Text(L10n.Shards.myShardHash(Int(account.partyIndex)))
                        .font(.title2.bold())
                        .foregroundStyle(.white)

                    Text(L10n.Shards.accountThresholdDesc(Int(account.totalParties), Int(account.threshold)))
                        .font(.caption)
                        .foregroundStyle(HorcruxTheme.subtleText)

                    ShardStatusBadge(threshold: account.threshold, total: account.totalParties)
                }
                .frame(maxWidth: .infinity)
                .glassCard(padding: 24)

                // Derived wallets
                VStack(alignment: .leading, spacing: 10) {
                    VaultSectionHeader(L10n.Shards.derivedAddresses, icon: "link")
                        .padding(.horizontal, 4)

                    VStack(spacing: 0) {
                        ForEach(account.wallets) { wallet in
                            HStack(spacing: 12) {
                                ChainIcon(chain: wallet.chain, size: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(wallet.chain.displayName)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.white)
                                    Text(shortAddress(wallet.address))
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(HorcruxTheme.subtleText)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 10)
                            if wallet.id != account.wallets.last?.id {
                                Divider().background(HorcruxTheme.hairline)
                            }
                        }
                    }
                    .glassCard()
                }

                // Actions
                VStack(alignment: .leading, spacing: 10) {
                    VaultSectionHeader(L10n.Shards.actions, icon: "bolt.circle")
                        .padding(.horizontal, 4)

                    VStack(spacing: 1) {
                        Button { showBackupSheet = true } label: {
                            HStack {
                                VaultSettingsRow(
                                    icon: "arrow.down.doc.fill",
                                    iconColor: HorcruxTheme.accentBlue,
                                    title: L10n.Shards.backupEntireAccount
                                )
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(HorcruxTheme.subtleText)
                            }
                        }
                        .glassCard()

                        Button { showDeleteConfirm = true } label: {
                            HStack {
                                VaultSettingsRow(
                                    icon: "trash.fill",
                                    iconColor: HorcruxTheme.dangerRed,
                                    title: L10n.Shards.deleteThisAccount
                                )
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(HorcruxTheme.subtleText)
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
        .navigationTitle(account.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .sheet(isPresented: $showBackupSheet) {
            AccountBackupView(account: account, viewModel: viewModel)
        }
        .sheet(isPresented: $showDeleteConfirm) {
            DeleteAccountConfirmView(account: account, viewModel: viewModel) {
                // Account was deleted — pop back to the shards list so the
                // user isn't stranded on a detail page for a missing account.
                dismiss()
            }
        }
    }

    private func shortAddress(_ address: String) -> String {
        guard address.count > 12 else { return address }
        return "\(address.prefix(6))…\(address.suffix(4))"
    }
}

// MARK: - Account Backup

struct AccountBackupView: View {
    let account: ShardAccount
    @ObservedObject var viewModel: ShardsViewModel
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var pin: String = ""
    @State private var isExporting = false
    @State private var showFileExporter = false
    @State private var copiedToClipboard = false
    @State private var showPinSheet = false

    private var backupFilename: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let safeName = account.name
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()
        return "horcrux-account-\(safeName)-\(fmt.string(from: Date())).json"
    }

    private var needsPin: Bool { appState.cachedShardKey() == nil }

    var body: some View {
        NavigationStack {
            Form {
                if viewModel.exportData == nil {
                    inputSection
                } else {
                    resultsSection
                }
                if let error = viewModel.error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(L10n.ShardBackup.sheetNavTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.cancel) {
                        viewModel.clearExport()
                        dismiss()
                    }
                }
                if viewModel.exportData != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.Common.done) {
                            viewModel.clearExport()
                            dismiss()
                        }
                    }
                }
            }
            .fileExporter(
                isPresented: $showFileExporter,
                document: ShardBackupDocument(data: viewModel.exportData ?? Data()),
                contentType: .json,
                defaultFilename: backupFilename
            ) { result in
                if case .failure(let err) = result {
                    viewModel.error = err.localizedDescription
                }
            }
            .sheet(isPresented: $showPinSheet) {
                PinUnlockSheet(
                    title: L10n.ShardBackup.sheetNavTitle,
                    subtitle: RecoveryKeyManager.isProvisioned
                        ? L10n.ShardBackup.pinFooterRkReady
                        : L10n.ShardBackup.pinFooterExportEncrypts
                ) { entered in
                    guard appState.verifyPin(entered) else {
                        return L10n.ShardsVM.pinWrong
                    }
                    pin = entered
                    DispatchQueue.main.async {
                        isExporting = true
                        viewModel.backupAccount(accountId: account.id, pin: entered)
                        isExporting = false
                    }
                    return nil
                }
                .presentationDetents([.medium, .large])
            }
        }
    }

    @ViewBuilder
    private var inputSection: some View {
        Section {
            Text(L10n.ShardBackup.exportIntro(account.name))
                .foregroundStyle(.secondary)
            Text(L10n.ShardBackup.exportIncludesChains(account.wallets.count))
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        let rkReady = RecoveryKeyManager.isProvisioned
        if rkReady {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.ShardBackup.rkWillEncrypt)
                            .font(.subheadline)
                        Text(L10n.ShardBackup.rkWillEncryptBody)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "icloud.fill")
                        .foregroundStyle(.blue)
                }
            }
        }

        // PIN is still needed in two cases:
        // 1. SWK isn't cached (app was biometric-unlocked, but biometric
        //    path didn't populate the shard key) — we need PIN to decrypt
        //    the device-resident shard.
        // 2. RK isn't yet provisioned on this device (rare first-run race).
        // When required, we collect it via PinUnlockSheet (custom keypad)
        // rather than a system-keyboard SecureField so the UX matches the
        // lock screen.

        Section {
            Button {
                if needsPin || !rkReady {
                    showPinSheet = true
                } else {
                    isExporting = true
                    viewModel.backupAccount(accountId: account.id, pin: "")
                    isExporting = false
                }
            } label: {
                if isExporting {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text(L10n.ShardBackup.exportEncrypted)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var resultsSection: some View {
        Section {
            Label(L10n.ShardBackup.ready, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            if let status = viewModel.backupStatus {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }

        Section(L10n.ShardBackup.exportOptions) {
            Button { showFileExporter = true } label: {
                Label(L10n.ShardBackup.saveToFiles, systemImage: "folder.fill")
            }
            Button {
                if let data = viewModel.exportData,
                   let str = String(data: data, encoding: .utf8) {
                    SecureClipboard.copy(str)
                    copiedToClipboard = true
                }
            } label: {
                Label(
                    copiedToClipboard
                        ? L10n.ShardBackup.copiedAutoClears(Int(SecureClipboard.defaultExpireSeconds))
                        : L10n.ShardBackup.copyToClipboard,
                    systemImage: copiedToClipboard ? "checkmark" : "doc.on.doc"
                )
            }
            .disabled(copiedToClipboard)
        }

        if let data = viewModel.exportData, data.count < 2048 {
            Section(L10n.ShardBackup.qrCode) {
                if let img = Self.generateQRCode(from: data) {
                    Image(uiImage: img)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 250, maxHeight: 250)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .accessibilityLabel(L10n.ShardBackup.shardBackupQR)
                } else {
                    Text(L10n.ShardBackup.unableToGenerateQR).foregroundStyle(.secondary)
                }
            }
        }
    }

    static func generateQRCode(from data: Data) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 4, y: 4))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - File Document

struct ShardBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let d = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = d
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Account Import

struct AccountImportView: View {
    @ObservedObject var viewModel: ShardsViewModel
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var importData: Data?
    @State private var preview: BackupPreview?
    @State private var pin: String = ""
    @State private var showFileImporter = false
    @State private var showQRScanner = false
    @State private var importError: String?
    @State private var isImporting = false
    @State private var importSuccess = false
    @State private var showPinSheet = false

    private var needsPin: Bool { appState.cachedShardKey() == nil }

    var body: some View {
        NavigationStack {
            Form {
                if importSuccess {
                    successSection
                } else if let preview {
                    previewSection(preview)
                } else {
                    sourceSection
                }
                if let err = importError {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(L10n.ShardImport.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(importSuccess ? L10n.Common.done : L10n.Common.cancel) { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { handleFileImport($0) }
            .sheet(isPresented: $showQRScanner) {
                QRScannerSheet { scanned in handleScannedData(scanned) }
            }
            .sheet(isPresented: $showPinSheet) {
                PinUnlockSheet(
                    title: L10n.ShardBackup.devicePin,
                    subtitle: L10n.ShardImport.pinEncryptsBackup
                ) { entered in
                    guard appState.verifyPin(entered) else {
                        return L10n.ShardsVM.pinWrong
                    }
                    pin = entered
                    DispatchQueue.main.async { performImport(pin: entered) }
                    return nil
                }
                .presentationDetents([.medium, .large])
            }
        }
    }

    @ViewBuilder
    private var sourceSection: some View {
        Section {
            Text(L10n.ShardImport.description).foregroundStyle(.secondary)
        }
        Section(L10n.ShardImport.importSource) {
            Button { showFileImporter = true } label: {
                Label(L10n.ShardImport.chooseFile, systemImage: "doc.fill")
            }
            Button { pasteFromClipboard() } label: {
                Label(L10n.ShardImport.pasteFromClipboard, systemImage: "doc.on.clipboard")
            }
            Button { showQRScanner = true } label: {
                Label(L10n.ShardImport.scanQRCode, systemImage: "qrcode.viewfinder")
            }
        }
    }

    /// v5 backups can be decrypted with the iCloud-synced Recovery Key
    /// alone; v4/v3 need a PIN. The "need PIN for local SWK unlock"
    /// consideration still applies even on v5.
    private func backupUsesRecoveryKey(_ preview: BackupPreview) -> Bool {
        if case .account(let b) = preview { return b.version >= 5 }
        return false
    }

    @ViewBuilder
    private func previewSection(_ preview: BackupPreview) -> some View {
        Section(L10n.ShardImport.backupInfo) {
            LabeledContent(L10n.ShardImport.accountLabel, value: preview.name)
            LabeledContent(L10n.ShardImport.chainLabel, value: preview.chainLabel)
            LabeledContent(L10n.ShardImport.partyIndex, value: L10n.ShardImport.partyIndexValue(Int(preview.partyIndex)))
            LabeledContent(L10n.Shards.threshold, value: L10n.Shards.thresholdValue(Int(preview.threshold.t), Int(preview.threshold.total)))
            if case .account(let b) = preview {
                LabeledContent(L10n.ShardImport.derivedWalletsLabel, value: L10n.ShardImport.chainsCount(b.wallets.count))
                LabeledContent(L10n.ShardImport.encryptionMethod, value: b.version >= 5 ? L10n.ShardImport.encryptionICloud : L10n.ShardImport.encryptionPin)
            } else if case .legacy = preview {
                LabeledContent(L10n.ShardImport.backupVersion, value: L10n.ShardImport.legacyFormatValue)
            }
        }

        let usesRK = backupUsesRecoveryKey(preview)
        if usesRK {
            Section {
                Label {
                    Text(L10n.ShardImport.rkInfoBanner)
                        .font(.caption)
                } icon: {
                    Image(systemName: "icloud.fill").foregroundStyle(.blue)
                }
            }
        }

        if !usesRK || needsPin {
            Section {
                Label {
                    Text(usesRK
                         ? L10n.ShardImport.pinStillNeededForLocal
                         : L10n.ShardImport.pinEncryptsBackup)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary)
                }
            } header: {
                Text(L10n.ShardBackup.devicePin)
            }
        }

        Section {
            Button {
                if !usesRK || needsPin {
                    showPinSheet = true
                } else {
                    performImport(pin: "")
                }
            } label: {
                if isImporting {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text(L10n.ShardImport.restoreAccountButton).frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isImporting)
        }

        Section {
            Button(L10n.ShardImport.chooseDifferent, role: .cancel) {
                importData = nil
                self.preview = nil
                pin = ""
                importError = nil
            }
        }
    }

    @ViewBuilder
    private var successSection: some View {
        Section {
            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
                Text(L10n.ShardImport.shardImported).font(.title2.bold())
                if case .success(let name, let count) = viewModel.importStatus {
                    Text(L10n.ShardImport.restoredAccount(name, count))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        importError = nil
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                importError = L10n.ShardImport.unableToAccessFile
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            do {
                let data = try Data(contentsOf: url)
                loadBackup(from: data)
            } catch {
                importError = L10n.ShardImport.readFailed(error.localizedDescription)
            }
        case .failure(let err):
            importError = err.localizedDescription
        }
    }

    private func pasteFromClipboard() {
        importError = nil
        guard let s = UIPasteboard.general.string, let data = s.data(using: .utf8) else {
            importError = L10n.ShardImport.noClipboardData
            return
        }
        loadBackup(from: data)
    }

    private func handleScannedData(_ s: String) {
        importError = nil
        guard let data = s.data(using: .utf8) else {
            importError = L10n.ShardImport.invalidQRData
            return
        }
        loadBackup(from: data)
    }

    private func loadBackup(from data: Data) {
        guard let p = viewModel.previewBackup(from: data) else {
            importError = L10n.ShardImport.failedToParseBackup
            return
        }
        importData = data
        preview = p
        importError = nil
    }

    private func performImport(pin: String) {
        guard let data = importData else { return }
        isImporting = true
        importError = nil
        do {
            try viewModel.importBackup(from: data, pin: pin, appState: appState)
            importSuccess = true
        } catch {
            importError = error.localizedDescription
        }
        isImporting = false
    }
}

// MARK: - Delete Account Confirm

struct DeleteAccountConfirmView: View {
    let account: ShardAccount
    @ObservedObject var viewModel: ShardsViewModel
    var onDeleted: (() -> Void)? = nil
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var pin: String = ""
    @State private var ackBackup: Bool = false
    @State private var ackLoss: Bool = false
    @State private var errorMessage: String?
    @State private var showPinSheet: Bool = false

    private var canConfirm: Bool {
        ackBackup && ackLoss
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(L10n.Shards.deleteIrreversible, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(HorcruxTheme.dangerRed)
                            .font(.headline)
                        Text(L10n.Shards.deleteBody(account.name))
                            .font(.subheadline)
                        Text(L10n.Shards.deleteShardLine(Int(account.partyIndex), Int(account.totalParties)))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(L10n.Shards.deleteChainsLine(account.wallets.count, account.wallets.map(\.chain.symbol).joined(separator: " · ")))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(L10n.Shards.deleteConsequence(Int(account.threshold)))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section(L10n.Shards.deleteConfirmBoth) {
                    Toggle(L10n.Shards.deleteAckBackup, isOn: $ackBackup)
                        .font(.footnote)
                    Toggle(L10n.Shards.deleteAckLoss(Int(account.threshold)), isOn: $ackLoss)
                        .font(.footnote)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showPinSheet = true
                    } label: {
                        HStack {
                            Spacer()
                            Text(L10n.Shards.deletePermanent)
                                .font(.headline)
                            Spacer()
                        }
                    }
                    .disabled(!canConfirm)
                }
            }
            .navigationTitle(L10n.Shards.deleteTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.cancel) { dismiss() }
                }
            }
            .sheet(isPresented: $showPinSheet) {
                PinUnlockSheet(
                    title: L10n.Shards.deleteEnterPin,
                    subtitle: L10n.Shards.deleteIrreversible
                ) { entered in
                    guard appState.verifyPin(entered) else {
                        return L10n.Shards.pinWrongRetry
                    }
                    pin = entered
                    DispatchQueue.main.async { handleDelete() }
                    return nil
                }
                .presentationDetents([.medium, .large])
            }
        }
    }

    private func handleDelete() {
        // PIN already verified in PinUnlockSheet closure; proceed to delete.
        viewModel.deleteAccount(accountId: account.id)
        dismiss()
        // Defer slightly so the sheet-dismiss animation doesn't fight the
        // navigation pop; SwiftUI otherwise drops one of the two transitions.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            onDeleted?()
        }
    }
}
