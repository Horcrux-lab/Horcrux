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
                            title: "还没有钱包",
                            subtitle: "创建钱包后可以在这里自检分片是否完好。",
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
                            Text(isChecking ? "检查中…" : "重新检查")
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
        .navigationTitle("分片健康自检")
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
                Text("上次检查：\(lastCheck.formatted(date: .numeric, time: .shortened))")
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
        if results.isEmpty { return "尚未检查" }
        return overallBad ? "发现异常" : "一切正常"
    }

    private var overallSubtitle: String {
        if results.isEmpty { return "点击下方按钮开始自检。" }
        if overallBad {
            return "至少一个分片无法读取。请立即前往备份页面导出健康分片，或在另一台设备上补签重建。"
        }
        return "所有分片都可以正常读取。"
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
        case .ok(let n): return "完好 · \(n) 字节"
        case .missing: return "分片缺失（Keychain 中找不到）"
        case .empty: return "分片为空（可能写入失败）"
        case .unreadable(let err): return "无法读取：\(err)"
        }
    }
}
