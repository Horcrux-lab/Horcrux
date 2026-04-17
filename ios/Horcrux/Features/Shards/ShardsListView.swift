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
                    .accessibilityLabel("从备份恢复")
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
                Label("从备份恢复账户", systemImage: "square.and.arrow.down.fill")
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

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.title2)
                .foregroundStyle(HorcruxTheme.shieldGradient)
                .shadow(color: HorcruxTheme.accentPurple.opacity(0.3), radius: 4)

            VStack(alignment: .leading, spacing: 6) {
                Text(account.name)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text("我的分片 #\(Int(account.partyIndex)) / \(Int(account.totalParties))")
                        .font(.caption)
                        .foregroundStyle(HorcruxTheme.subtleText)
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(HorcruxTheme.subtleText.opacity(0.5))
                    Text(account.wallets.map(\.chain.symbol).joined(separator: " · "))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(HorcruxTheme.accentPurple)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                ShardStatusBadge(threshold: account.threshold, total: account.totalParties)
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(HorcruxTheme.subtleText)
        }
        .padding(.vertical, 12)
        .glassCard()
    }
}

// MARK: - Account Detail

struct ShardAccountDetailView: View {
    let account: ShardAccount
    @ObservedObject var viewModel: ShardsViewModel
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

                    Text("我的分片 #\(Int(account.partyIndex))")
                        .font(.title2.bold())
                        .foregroundStyle(.white)

                    Text("此账户共 \(Int(account.totalParties)) 份分片，签名需 \(Int(account.threshold)) 份")
                        .font(.caption)
                        .foregroundStyle(HorcruxTheme.subtleText)

                    ShardStatusBadge(threshold: account.threshold, total: account.totalParties)
                }
                .frame(maxWidth: .infinity)
                .glassCard(padding: 24)

                // Derived wallets
                VStack(alignment: .leading, spacing: 10) {
                    VaultSectionHeader("派生地址", icon: "link")
                        .padding(.horizontal, 4)

                    VStack(spacing: 0) {
                        ForEach(account.wallets) { wallet in
                            HStack(spacing: 12) {
                                ChainIcon(chain: wallet.chain, size: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(wallet.chain.rawValue)
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
                                Divider().background(Color.white.opacity(0.06))
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
                                    title: "备份整个账户"
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
                                    title: "删除此账户"
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
            DeleteAccountConfirmView(account: account, viewModel: viewModel)
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
            .navigationTitle("备份账户")
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
        }
    }

    @ViewBuilder
    private var inputSection: some View {
        Section {
            Text("将账户「\(account.name)」在本设备上的加密分片导出为一份可跨设备恢复的文件。")
                .foregroundStyle(.secondary)
            Text("包含派生的 \(account.wallets.count) 条链地址，所有链共享同一份密钥材料。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if needsPin {
            Section(L10n.ShardBackup.devicePin) {
                SecureField(L10n.ShardBackup.enterPin, text: $pin)
                    .keyboardType(.numberPad)
            }
        }

        Section {
            Button {
                isExporting = true
                viewModel.backupAccount(accountId: account.id, pin: pin)
                isExporting = false
            } label: {
                if isExporting {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text(L10n.ShardBackup.exportEncrypted)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(needsPin && pin.count < 6)
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

    @ViewBuilder
    private func previewSection(_ preview: BackupPreview) -> some View {
        Section(L10n.ShardImport.backupInfo) {
            LabeledContent("账户", value: preview.name)
            LabeledContent("链", value: preview.chainLabel)
            LabeledContent(L10n.ShardImport.partyIndex, value: L10n.ShardImport.partyIndexValue(Int(preview.partyIndex)))
            LabeledContent(L10n.Shards.threshold, value: L10n.Shards.thresholdValue(Int(preview.threshold.t), Int(preview.threshold.total)))
            if case .account(let b) = preview {
                LabeledContent("派生钱包", value: "\(b.wallets.count) 条链")
            } else if case .legacy = preview {
                LabeledContent(L10n.ShardImport.backupVersion, value: "旧格式 (单链)")
            }
        }

        if needsPin {
            Section(L10n.ShardBackup.devicePin) {
                SecureField(L10n.ShardImport.enterDevicePin, text: $pin)
                    .keyboardType(.numberPad)
                Text(L10n.ShardImport.reEncryptNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        Section {
            Button { performImport() } label: {
                if isImporting {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("恢复账户").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled((needsPin && pin.count < 6) || isImporting)
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
                    Text("已恢复账户「\(name)」· \(count) 条链")
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
                importError = "读取失败: \(error.localizedDescription)"
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
            importError = "无法解析备份文件"
            return
        }
        importData = data
        preview = p
        importError = nil
    }

    private func performImport() {
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
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var pin: String = ""
    @State private var ackBackup: Bool = false
    @State private var ackLoss: Bool = false
    @State private var errorMessage: String?

    private var canDelete: Bool {
        pin.count >= 4 && ackBackup && ackLoss
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("不可逆操作", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(HorcruxTheme.dangerRed)
                            .font(.headline)
                        Text("即将删除账户「\(account.name)」在本设备上的所有数据：")
                            .font(.subheadline)
                        Text("· 共享分片 #\(Int(account.partyIndex)) / \(Int(account.totalParties))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("· 派生的 \(account.wallets.count) 条链钱包：\(account.wallets.map(\.chain.symbol).joined(separator: " · "))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("删除后本机无法参与此账户的任何链签名。若其他设备持有的分片不足 \(Int(account.threshold)) 份，整个账户将永久不可用。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("请确认以下两项") {
                    Toggle("我已备份此账户分片 / 或确认无需保留", isOn: $ackBackup)
                        .font(.footnote)
                    Toggle("我已确认其他设备上的分片足够达到 \(Int(account.threshold)) 份阈值", isOn: $ackLoss)
                        .font(.footnote)
                }

                Section("输入 PIN 以执行删除") {
                    SecureField(L10n.Common.pin, text: $pin)
                        .keyboardType(.numberPad)
                        .font(.title3.monospacedDigit())
                        .multilineTextAlignment(.center)
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
                        handleDelete()
                    } label: {
                        HStack {
                            Spacer()
                            Text("永久删除此账户")
                                .font(.headline)
                            Spacer()
                        }
                    }
                    .disabled(!canDelete)
                }
            }
            .navigationTitle("删除账户")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.cancel) { dismiss() }
                }
            }
        }
    }

    private func handleDelete() {
        guard appState.verifyPin(pin) else {
            errorMessage = "PIN 错误，请重新输入"
            pin = ""
            return
        }
        viewModel.deleteAccount(accountId: account.id)
        dismiss()
    }
}
