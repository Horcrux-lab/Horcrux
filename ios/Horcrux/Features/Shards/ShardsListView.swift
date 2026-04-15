import SwiftUI
import UniformTypeIdentifiers
import CoreImage.CIFilterBuiltins

// MARK: - Shard List

/// Lists all key shards stored on this device.
struct ShardsListView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = ShardsViewModel()
    @State private var showImportSheet = false

    var body: some View {
        NavigationStack {
            List {
                if appState.walletStore.wallets.isEmpty {
                    ContentUnavailableView(
                        "No Shards",
                        systemImage: "shield.slash",
                        description: Text("Create a wallet to generate your first key shard.")
                    )
                } else {
                    ForEach(appState.walletStore.wallets) { wallet in
                        NavigationLink {
                            ShardDetailView(wallet: wallet, viewModel: viewModel)
                        } label: {
                            ShardRow(wallet: wallet)
                        }
                    }
                }
            }
            .navigationTitle("Shards")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showImportSheet = true
                    } label: {
                        Label("Import Shard", systemImage: "square.and.arrow.down")
                    }
                }
            }
            .sheet(isPresented: $showImportSheet) {
                ShardImportView(viewModel: viewModel)
            }
            .onAppear {
                viewModel.bind(to: appState)
            }
        }
    }
}

// MARK: - Shard Row

struct ShardRow: View {
    let wallet: Wallet

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.title2)
                .foregroundStyle(wallet.chain.color)

            VStack(alignment: .leading, spacing: 4) {
                Text("Shard #\(wallet.partyIndex)")
                    .font(.headline)

                Text(wallet.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(wallet.chain.symbol)
                    .font(.caption.bold())

                ShardStatusBadge(
                    threshold: wallet.threshold,
                    total: wallet.totalParties
                )
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Shard Detail

struct ShardDetailView: View {
    let wallet: Wallet
    @ObservedObject var viewModel: ShardsViewModel
    @State private var showBackupSheet = false
    @State private var showDeleteAlert = false

    var body: some View {
        List {
            Section {
                VStack(spacing: 16) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 48))
                        .foregroundStyle(wallet.chain.color)

                    Text("Shard #\(wallet.partyIndex)")
                        .font(.title2.bold())

                    ShardStatusBadge(
                        threshold: wallet.threshold,
                        total: wallet.totalParties
                    )
                }
                .frame(maxWidth: .infinity)
                .padding()
            }

            Section("Wallet Info") {
                LabeledContent("Wallet", value: wallet.name)
                LabeledContent("Chain", value: wallet.chain.rawValue)
                LabeledContent("Address") {
                    Text(wallet.address)
                        .font(.caption2)
                        .monospaced()
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                LabeledContent("Threshold", value: "\(wallet.threshold) of \(wallet.totalParties)")
            }

            Section("Actions") {
                Button {
                    showBackupSheet = true
                } label: {
                    Label("Backup Shard", systemImage: "arrow.down.doc.fill")
                }

                Button(role: .destructive) {
                    showDeleteAlert = true
                } label: {
                    Label("Delete Shard", systemImage: "trash.fill")
                }
            }
        }
        .navigationTitle("Shard Details")
        .sheet(isPresented: $showBackupSheet) {
            ShardBackupView(wallet: wallet, viewModel: viewModel)
        }
        .alert("Delete Shard?", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) {
                viewModel.deleteShard(wallet: wallet)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This shard will be permanently removed from this device. Make sure you have a backup.")
        }
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
            .navigationTitle("Backup Shard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.clearExport()
                        dismiss()
                    }
                }
                if viewModel.exportData != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
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
            Text("Your shard will be decrypted and exported as a portable backup file. Keep this file safe.")
                .foregroundStyle(.secondary)
        }

        Section("Device PIN") {
            SecureField("Enter PIN (min 6 digits)", text: $pin)
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
                    Text("Export Encrypted Shard")
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
            Label("Shard backup ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)

            if let status = viewModel.backupStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        Section("Export Options") {
            Button {
                showFileExporter = true
            } label: {
                Label("Save to Files", systemImage: "folder.fill")
            }

            Button {
                if let data = viewModel.exportData,
                   let jsonString = String(data: data, encoding: .utf8) {
                    SecureClipboard.copy(jsonString)
                    copiedToClipboard = true
                }
            } label: {
                Label(
                    copiedToClipboard ? "Copied! (auto-clears in \(Int(SecureClipboard.defaultExpireSeconds))s)" : "Copy to Clipboard",
                    systemImage: copiedToClipboard ? "checkmark" : "doc.on.doc"
                )
            }
            .disabled(copiedToClipboard)
        }

        if let data = viewModel.exportData, data.count < 2048 {
            Section("QR Code") {
                if let qrImage = Self.generateQRCode(from: data) {
                    Image(uiImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 250, maxHeight: 250)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .accessibilityLabel("Shard backup QR code")
                } else {
                    Text("Unable to generate QR code")
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
            .navigationTitle("Import Shard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(importSuccess ? "Done" : "Cancel") { dismiss() }
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
            Text("Import a shard backup from a file, clipboard, or QR code.")
                .foregroundStyle(.secondary)
        }

        Section("Import Source") {
            Button {
                showFileImporter = true
            } label: {
                Label("Choose File", systemImage: "doc.fill")
            }

            Button {
                pasteFromClipboard()
            } label: {
                Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
            }

            Button {
                showQRScanner = true
            } label: {
                Label("Scan QR Code", systemImage: "qrcode.viewfinder")
            }
        }
    }

    // MARK: - Preview Phase

    @ViewBuilder
    private func previewSection(_ backup: ShardBackup) -> some View {
        Section("Backup Info") {
            LabeledContent("Wallet", value: backup.walletName)
            LabeledContent("Chain", value: backup.chain.rawValue)
            LabeledContent("Party Index", value: "#\(backup.partyIndex)")
            LabeledContent("Threshold", value: "\(backup.threshold) of \(backup.totalParties)")
            LabeledContent("Address") {
                Text(backup.address)
                    .font(.caption2)
                    .monospaced()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if backup.version > 0 {
                LabeledContent("Backup Version", value: "v\(backup.version)")
            }
        }

        Section("Device PIN") {
            SecureField("Enter device PIN (min 6 digits)", text: $pin)
                .keyboardType(.numberPad)

            Text("The shard will be re-encrypted with this device's credentials.")
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
                    Text("Import Shard")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(pin.count < 6 || isImporting)
        }

        Section {
            Button("Choose Different Source", role: .cancel) {
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
                    .font(.system(size: 48))
                    .foregroundStyle(.green)

                Text("Shard Imported!")
                    .font(.title2.bold())

                if let backup = parsedBackup {
                    Text("'\(backup.walletName)' has been added to this device.")
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
                importError = "Unable to access the selected file"
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
            importError = "No valid backup data found on clipboard"
            return
        }
        loadBackup(from: data)
    }

    private func handleScannedData(_ scannedString: String) {
        importError = nil
        guard let data = scannedString.data(using: .utf8) else {
            importError = "Invalid QR code data"
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
