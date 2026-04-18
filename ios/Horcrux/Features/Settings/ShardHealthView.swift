import SwiftUI

/// Periodic self-check that each account's key share is readable from the
/// keychain. Surfaces corruption / missing shards before the user tries
/// to sign and fails midway through a ceremony.
struct ShardHealthView: View {
    @EnvironmentObject private var appState: AppState
    @State private var results: [(accountId: String, status: WalletStore.ShardHealth, walletNames: [String])] = []
    @State private var lastCheck: Date?
    @State private var isChecking = false

    var body: some View {
        ZStack {
            HorcruxTheme.backgroundGradient.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryCard

                    if results.isEmpty && !isChecking {
                        VaultEmptyState(
                            icon: "checkmark.shield",
                            title: L10n.ShardHealth.noWalletsTitle,
                            subtitle: L10n.ShardHealth.noWalletsSubtitle,
                            iconSize: 48
                        )
                        .frame(maxWidth: .infinity)
                        .glassCard()
                    } else {
                        ForEach(results, id: \.accountId) { result in
                            resultRow(result)
                        }
                    }

                    Button {
                        runCheck()
                    } label: {
                        HStack {
                            if isChecking {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(isChecking ? L10n.ShardHealth.checking : L10n.ShardHealth.recheck)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(HorcruxTheme.accentPurple)
                    .disabled(isChecking)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .navigationTitle(L10n.ShardHealth.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear { if results.isEmpty { runCheck() } }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: overallIcon)
                    .font(.title2)
                    .foregroundStyle(overallColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(overallTitle).font(.headline).foregroundStyle(.white)
                    Text(overallSubtitle).font(.caption).foregroundStyle(HorcruxTheme.subtleText)
                }
            }
            if let lastCheck {
                Text(L10n.ShardHealth.lastCheck(lastCheck.formatted(date: .numeric, time: .shortened)))
                    .font(.caption2)
                    .foregroundStyle(HorcruxTheme.subtleText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    @ViewBuilder
    private func resultRow(_ r: (accountId: String, status: WalletStore.ShardHealth, walletNames: [String])) -> some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon(r.status))
                .font(.title3)
                .foregroundStyle(statusColor(r.status))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(r.walletNames.joined(separator: " · "))
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                Text(statusText(r.status))
                    .font(.caption)
                    .foregroundStyle(HorcruxTheme.subtleText)
                Text("account: \(r.accountId.prefix(12))…")
                    .font(.caption2.monospaced())
                    .foregroundStyle(HorcruxTheme.subtleText.opacity(0.7))
            }
            Spacer()
        }
        .glassCard()
    }

    private func runCheck() {
        isChecking = true
        // Keychain reads are fast (<10ms for small blobs) — sync is fine.
        results = appState.walletStore.verifyShardHealth()
        lastCheck = Date()
        isChecking = false
    }

    // MARK: - Derived

    private var overallBad: Bool {
        results.contains {
            switch $0.status {
            case .ok: return false
            default: return true
            }
        }
    }

    private var overallIcon: String {
        if results.isEmpty { return "questionmark.circle" }
        return overallBad ? "exclamationmark.triangle.fill" : "checkmark.seal.fill"
    }

    private var overallColor: Color {
        if results.isEmpty { return HorcruxTheme.subtleText }
        return overallBad ? HorcruxTheme.dangerRed : HorcruxTheme.successGreen
    }

    private var overallTitle: String {
        if results.isEmpty { return L10n.ShardHealth.statusNotChecked }
        return overallBad ? L10n.ShardHealth.statusAbnormal : L10n.ShardHealth.statusAllOK
    }

    private var overallSubtitle: String {
        if results.isEmpty { return L10n.ShardHealth.tapToStart }
        if overallBad {
            return L10n.ShardHealth.someUnreadable
        }
        return L10n.ShardHealth.allReadable
    }

    private func statusIcon(_ s: WalletStore.ShardHealth) -> String {
        switch s {
        case .ok: return "checkmark.circle.fill"
        case .missing: return "xmark.octagon.fill"
        case .empty: return "exclamationmark.circle.fill"
        case .unreadable: return "lock.trianglebadge.exclamationmark"
        }
    }

    private func statusColor(_ s: WalletStore.ShardHealth) -> Color {
        switch s {
        case .ok: return HorcruxTheme.successGreen
        case .missing, .unreadable: return HorcruxTheme.dangerRed
        case .empty: return HorcruxTheme.warningAmber
        }
    }

    private func statusText(_ s: WalletStore.ShardHealth) -> String {
        switch s {
        case .ok(let n): return L10n.ShardHealth.resOK(n)
        case .missing: return L10n.ShardHealth.resMissing
        case .empty: return L10n.ShardHealth.resEmpty
        case .unreadable(let err): return L10n.ShardHealth.resUnreadable(err)
        }
    }
}
