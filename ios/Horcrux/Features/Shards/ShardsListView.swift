import SwiftUI

/// Lists all key shards stored on this device.
struct ShardsListView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = ShardsViewModel()

    var body: some View {
        NavigationStack {
            List {
                if appState.wallets.isEmpty {
                    ContentUnavailableView(
                        "No Shards",
                        systemImage: "shield.slash",
                        description: Text("Create a wallet to generate your first key shard.")
                    )
                } else {
                    ForEach(appState.wallets) { wallet in
                        NavigationLink {
                            ShardDetailView(wallet: wallet, viewModel: viewModel)
                        } label: {
                            ShardRow(wallet: wallet)
                        }
                    }
                }
            }
            .navigationTitle("Shards")
        }
    }
}

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

struct ShardBackupView: View {
    let wallet: Wallet
    @ObservedObject var viewModel: ShardsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var pin: String = ""
    @State private var isExporting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Your shard will be encrypted with a PIN before export.")
                        .foregroundStyle(.secondary)
                }

                Section("Encryption PIN") {
                    SecureField("Enter PIN (min 6 digits)", text: $pin)
                        .keyboardType(.numberPad)
                }

                Section {
                    Button {
                        isExporting = true
                        viewModel.backupShard(wallet: wallet, pin: pin)
                        dismiss()
                    } label: {
                        if isExporting {
                            ProgressView()
                        } else {
                            Text("Export Encrypted Shard")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(pin.count < 6)
                }
            }
            .navigationTitle("Backup Shard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
