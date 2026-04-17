import SwiftUI
import UniformTypeIdentifiers
import CoreImage.CIFilterBuiltins

// MARK: - Shard List

/// Lists all key shards stored on this device — dark-tech glass card layout.
struct ShardsListView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = ShardsViewModel()
    @State private var showImportSheet = false

    var body: some View {
        NavigationStack {
            ZStack {
                HorcruxTheme.backgroundGradient.ignoresSafeArea()

                if appState.walletStore.wallets.isEmpty {
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
                            Label("从备份恢复钱包", systemImage: "square.and.arrow.down.fill")
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
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(appState.walletStore.wallets) { wallet in
                                NavigationLink {
                                    ShardDetailView(wallet: wallet, viewModel: viewModel)
                                } label: {
                                    ShardRow(wallet: wallet)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                    }
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
                }
            }
            .sheet(isPresented: $showImportSheet) {
                ShardImportView(viewModel: viewModel)
            }
            .onAppear {
                viewModel.bind(to: appState)
            }
            .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Shard Row

struct ShardRow: View {
    let wallet: Wallet

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.title2)
                .foregroundStyle(HorcruxTheme.shieldGradient)
                .shadow(color: HorcruxTheme.accentPurple.opacity(0.3), radius: 4)

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.Shards.shardNumber(Int(wallet.partyIndex)))
                    .font(.headline)
                    .foregroundStyle(.white)

                Text(wallet.name)
                    .font(.subheadline)
                    .foregroundStyle(HorcruxTheme.subtleText)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Text(wallet.chain.symbol)
                    .font(.caption.bold())
                    .foregroundStyle(wallet.chain.color)

                ShardStatusBadge(threshold: wallet.threshold, total: wallet.totalParties)
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(HorcruxTheme.subtleText)
        }
        .padding(.vertical, 12)
        .glassCard()
    }
}

// MARK: - Shard Detail

struct ShardDetailView: View {
    let wallet: Wallet
    @ObservedObject var viewModel: ShardsViewModel
    @State private var showBackupSheet = false
    @State private var showDeleteAlert = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Hero
                VStack(spacing: 16) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 48, weight: .thin))
                        .foregroundStyle(HorcruxTheme.shieldGradient)
                        .shadow(color: HorcruxTheme.accentPurple.opacity(0.4), radius: 8)

                    Text(L10n.Shards.shardNumber(Int(wallet.partyIndex)))
                        .font(.title2.bold())
                        .foregroundStyle(.white)

                    ShardStatusBadge(threshold: wallet.threshold, total: wallet.totalParties)
                }
                .frame(maxWidth: .infinity)
                .glassCard(padding: 24)

                // Info
                VStack(alignment: .leading, spacing: 10) {
                    VaultSectionHeader(L10n.Shards.walletInfo, icon: "info.circle")
                        .padding(.horizontal, 4)

                    VStack(spacing: 0) {
                        infoRow(L10n.Shards.wallet, value: wallet.name)
                        Divider().background(Color.white.opacity(0.06))
                        infoRow(L10n.Shards.chain, value: wallet.chain.rawValue)
                        Divider().background(Color.white.opacity(0.06))
                        HStack {
                            Text(L10n.Shards.address)
                                .font(.subheadline)
                                .foregroundStyle(HorcruxTheme.subtleText)
                            Spacer()
                            Text(wallet.address)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(.vertical, 10)
                        Divider().background(Color.white.opacity(0.06))
                        infoRow(L10n.Shards.threshold, value: L10n.Shards.thresholdValue(Int(wallet.threshold), Int(wallet.totalParties)))
                    }
                    .glassCard()
                }

                // Actions
                VStack(alignment: .leading, spacing: 10) {
                    VaultSectionHeader(L10n.Shards.actions, icon: "bolt.circle")
                        .padding(.horizontal, 4)

                    VStack(spacing: 1) {
                        Button {
                            showBackupSheet = true
                        } label: {
                            HStack {
                                VaultSettingsRow(icon: "arrow.down.doc.fill", iconColor: HorcruxTheme.accentBlue, title: L10n.Shards.backupShard)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(HorcruxTheme.subtleText)
                            }
                        }
                        .glassCard()

                        Button {
                            showDeleteAlert = true
                        } label: {
                            HStack {
                                VaultSettingsRow(icon: "trash.fill", iconColor: HorcruxTheme.dangerRed, title: L10n.Shards.deleteShard)
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
        .navigationTitle(L10n.Shards.shardDetails)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .sheet(isPresented: $showBackupSheet) {
            ShardBackupView(wallet: wallet, viewModel: viewModel)
        }
        .alert(L10n.Shards.deleteShardConfirm, isPresented: $showDeleteAlert) {
            Button(L10n.Common.delete, role: .destructive) {
                viewModel.deleteShard(wallet: wallet)
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.Shards.deleteShardMessage)
        }
    }

    private func infoRow(_ label: String, value: String) -> some View {
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
}

// MARK: - Shard Backup

struct ShardBackupView: View {
    let wallet: Wallet
    @ObservedObject var viewModel: ShardsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var pin: String = ""
    @State private var isExporting = false
    @State private var showFileExporter = false
    @State private var copiedToClipboard = false

    private var backupFilename: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateStr = formatter.string(from: Date())
        let safeName = wallet.name
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()
        return "horcrux-shard-\(safeName)-\(dateStr).json"
    }

    var body: some View {
        NavigationStack {
            Form {
                if viewModel.exportData == nil {
                    pinEntrySection
                } else {
                    exportResultsSection
                }

                if let error = viewModel.error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(L10n.ShardBackup.title)
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

    // MARK: - PIN Entry Phase

    @ViewBuilder
    private var pinEntrySection: some View {
        Section {
            Text(L10n.ShardBackup.description)
                .foregroundStyle(.secondary)
        }

        Section(L10n.ShardBackup.devicePin) {
            SecureField(L10n.ShardBackup.enterPin, text: $pin)
                .keyboardType(.numberPad)
        }

        Section {
            Button {
                isExporting = true
                viewModel.backupShard(wallet: wallet, pin: pin)
                isExporting = false
            } label: {
                if isExporting {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text(L10n.ShardBackup.exportEncrypted)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(pin.count < 6)
        }
    }

    // MARK: - Export Results Phase

    @ViewBuilder
    private var exportResultsSection: some View {
        Section {
            Label(L10n.ShardBackup.ready, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)

            if let status = viewModel.backupStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        Section(L10n.ShardBackup.exportOptions) {
            Button {
                showFileExporter = true
            } label: {
                Label(L10n.ShardBackup.saveToFiles, systemImage: "folder.fill")
            }

            Button {
                if let data = viewModel.exportData,
                   let jsonString = String(data: data, encoding: .utf8) {
                    SecureClipboard.copy(jsonString)
                    copiedToClipboard = true
                }
            } label: {
                Label(
                    copiedToClipboard ? L10n.ShardBackup.copiedAutoClears(Int(SecureClipboard.defaultExpireSeconds)) : L10n.ShardBackup.copyToClipboard,
                    systemImage: copiedToClipboard ? "checkmark" : "doc.on.doc"
                )
            }
            .disabled(copiedToClipboard)
        }

        if let data = viewModel.exportData, data.count < 2048 {
            Section(L10n.ShardBackup.qrCode) {
                if let qrImage = Self.generateQRCode(from: data) {
                    Image(uiImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 250, maxHeight: 250)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .accessibilityLabel(L10n.ShardBackup.shardBackupQR)
                } else {
                    Text(L10n.ShardBackup.unableToGenerateQR)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - QR Code Generation

    static func generateQRCode(from data: Data) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 4, y: 4))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - File Document for Export

struct ShardBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Shard Import

struct ShardImportView: View {
    @ObservedObject var viewModel: ShardsViewModel
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var importData: Data?
    @State private var parsedBackup: ShardBackup?
    @State private var pin: String = ""
    @State private var showFileImporter = false
    @State private var showQRScanner = false
    @State private var importError: String?
    @State private var isImporting = false
    @State private var importSuccess = false
    @ScaledMetric(relativeTo: .largeTitle) private var resultIconSize: CGFloat = 48

    var body: some View {
        NavigationStack {
            Form {
                if importSuccess {
                    successSection
                } else if let backup = parsedBackup {
                    previewSection(backup)
                } else {
                    sourceSelectionSection
                }

                if let error = importError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
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
            ) { result in
                handleFileImport(result)
            }
            .sheet(isPresented: $showQRScanner) {
                QRScannerSheet { scannedString in
                    handleScannedData(scannedString)
                }
            }
        }
    }

    // MARK: - Source Selection Phase

    @ViewBuilder
    private var sourceSelectionSection: some View {
        Section {
            Text(L10n.ShardImport.description)
                .foregroundStyle(.secondary)
        }

        Section(L10n.ShardImport.importSource) {
            Button {
                showFileImporter = true
            } label: {
                Label(L10n.ShardImport.chooseFile, systemImage: "doc.fill")
            }

            Button {
                pasteFromClipboard()
            } label: {
                Label(L10n.ShardImport.pasteFromClipboard, systemImage: "doc.on.clipboard")
            }

            Button {
                showQRScanner = true
            } label: {
                Label(L10n.ShardImport.scanQRCode, systemImage: "qrcode.viewfinder")
            }
        }
    }

    // MARK: - Preview Phase

    @ViewBuilder
    private func previewSection(_ backup: ShardBackup) -> some View {
        Section(L10n.ShardImport.backupInfo) {
            LabeledContent(L10n.Shards.wallet, value: backup.walletName)
            LabeledContent(L10n.Shards.chain, value: backup.chain.rawValue)
            LabeledContent(L10n.ShardImport.partyIndex, value: L10n.ShardImport.partyIndexValue(Int(backup.partyIndex)))
            LabeledContent(L10n.Shards.threshold, value: L10n.Shards.thresholdValue(Int(backup.threshold), Int(backup.totalParties)))
            LabeledContent(L10n.Shards.address) {
                Text(backup.address)
                    .font(.caption2)
                    .monospaced()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if backup.version > 0 {
                LabeledContent(L10n.ShardImport.backupVersion, value: L10n.ShardImport.backupVersionValue(backup.version))
            }
        }

        Section(L10n.ShardBackup.devicePin) {
            SecureField(L10n.ShardImport.enterDevicePin, text: $pin)
                .keyboardType(.numberPad)

            Text(L10n.ShardImport.reEncryptNote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section {
            Button {
                performImport()
            } label: {
                if isImporting {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text(L10n.ShardImport.importShard)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(pin.count < 6 || isImporting)
        }

        Section {
            Button(L10n.ShardImport.chooseDifferent, role: .cancel) {
                importData = nil
                parsedBackup = nil
                pin = ""
                importError = nil
            }
        }
    }

    // MARK: - Success Phase

    @ViewBuilder
    private var successSection: some View {
        Section {
            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: resultIconSize))
                    .foregroundStyle(.green)

                Text(L10n.ShardImport.shardImported)
                    .font(.title2.bold())

                if let backup = parsedBackup {
                    Text(L10n.ShardImport.addedToDevice(backup.walletName))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
    }

    // MARK: - Import Actions

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
                importError = "Failed to read file: \(error.localizedDescription)"
            }

        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private func pasteFromClipboard() {
        importError = nil
        guard let clipString = UIPasteboard.general.string,
              let data = clipString.data(using: .utf8) else {
            importError = L10n.ShardImport.noClipboardData
            return
        }
        loadBackup(from: data)
    }

    private func handleScannedData(_ scannedString: String) {
        importError = nil
        guard let data = scannedString.data(using: .utf8) else {
            importError = L10n.ShardImport.invalidQRData
            return
        }
        loadBackup(from: data)
    }

    private func loadBackup(from data: Data) {
        do {
            let backup = try viewModel.parseBackup(from: data)
            importData = data
            parsedBackup = backup
            importError = nil
        } catch {
            importError = "Invalid backup file: \(error.localizedDescription)"
        }
    }

    private func performImport() {
        guard let data = importData else { return }
        isImporting = true
        importError = nil

        do {
            try viewModel.importShard(from: data, pin: pin, appState: appState)
            importSuccess = true
        } catch {
            importError = error.localizedDescription
        }

        isImporting = false
    }
}
