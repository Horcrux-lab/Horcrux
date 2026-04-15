import SwiftUI

/// Wallet home screen — shows all wallets with balances and quick actions.
struct WalletHomeView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showCreateShard = false

    var body: some View {
        NavigationStack {
            Group {
                if appState.walletStore.wallets.isEmpty {
                    emptyState
                } else {
                    walletList
                }
            }
            .navigationTitle("Horcrux")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showCreateShard = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                }
            }
            .sheet(isPresented: $showCreateShard) {
                CreateShardFlow()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)

            VStack(spacing: 8) {
                Text("No Wallets Yet")
                    .font(.title2.bold())
                Text("Create your first MPC wallet by\nsplitting a key across devices.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            Button {
                showCreateShard = true
            } label: {
                Label("Create Wallet", systemImage: "plus.circle.fill")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
        .padding()
    }

    private var walletList: some View {
        List {
            ForEach(appState.walletStore.wallets) { wallet in
                NavigationLink {
                    WalletDetailView(wallet: wallet)
                } label: {
                    WalletRow(wallet: wallet)
                }
            }
        }
    }
}

struct WalletRow: View {
    let wallet: Wallet

    var body: some View {
        HStack(spacing: 12) {
            ChainIcon(chain: wallet.chain, size: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(wallet.name)
                    .font(.headline)

                Text(shortAddress(wallet.address))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospaced()
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(wallet.chain.symbol)
                    .font(.subheadline.bold())

                ShardStatusBadge(
                    threshold: wallet.threshold,
                    total: wallet.totalParties
                )
            }
        }
        .padding(.vertical, 4)
    }

    private func shortAddress(_ address: String) -> String {
        guard address.count > 12 else { return address }
        let prefix = address.prefix(6)
        let suffix = address.suffix(4)
        return "\(prefix)…\(suffix)"
    }
}

struct WalletDetailView: View {
    @EnvironmentObject private var appState: AppState
    let wallet: Wallet
    @State private var showSigning = false

    var body: some View {
        List {
            Section {
                VStack(spacing: 16) {
                    ChainIcon(chain: wallet.chain, size: 64)

                    Text(wallet.address)
                        .font(.system(.caption, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)

                    ShardStatusBadge(
                        threshold: wallet.threshold,
                        total: wallet.totalParties
                    )
                }
                .frame(maxWidth: .infinity)
                .padding()
            }

            Section("Actions") {
                Button {
                    showSigning = true
                } label: {
                    Label("Send Transaction", systemImage: "arrow.up.circle.fill")
                }

                Button {
                    UIPasteboard.general.string = wallet.address
                } label: {
                    Label("Copy Address", systemImage: "doc.on.doc")
                }
            }

            Section("Details") {
                LabeledContent("Chain", value: wallet.chain.rawValue)
                LabeledContent("Threshold", value: "\(wallet.threshold) of \(wallet.totalParties)")
                LabeledContent("Your Shard", value: "#\(wallet.partyIndex)")
                LabeledContent("Created", value: wallet.createdAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .navigationTitle(wallet.name)
        .sheet(isPresented: $showSigning) {
            SigningView(wallet: wallet)
        }
    }
}
