import SwiftUI

/// Aggregate security health pill. Shown at the top of the Shards tab
/// (not on the wallet home — home stays focused on balances/actions).
///
/// Signals folded into a single three-state traffic light:
/// - **Rotation**: attention when any CGGMP21 account is past the
///   recommended interval; risk when it's been ≥180d since last rotation.
/// - **Local biometric backup (SE-sealed SWK)**: attention when biometric
///   is available but the user never sealed an SWK copy.
///
/// Tap the footer to push `SecurityDetailView`.
struct SecurityHealthCard: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var walletStore: WalletStore
    @State private var rotationTarget: Wallet?
    @State private var snoozedAt: Date?

    var body: some View {
        let snoozed = snoozedAt.map { Date().timeIntervalSince($0) < 24 * 3600 } ?? false
        let health = computeHealth()
        let visibleWallets = walletStore.wallets.filter { !$0.hidden }

        if !visibleWallets.isEmpty, health.overall != .safe || !snoozed {
            VStack(alignment: .leading, spacing: 12) {
                header(health: health)
                if let daysText = health.rotationDaysText {
                    row(
                        icon: "arrow.triangle.2.circlepath",
                        label: L10n.WalletHome.securityRotationRow,
                        value: daysText,
                        valueLevel: health.rotation,
                        cta: health.staleWalletForCTA.map { w in
                            (L10n.Rotate.nudgeCTA, { rotationTarget = w })
                        }
                    )
                }
                row(
                    icon: health.hasSealedBackup ? "checkmark.shield.fill" : "exclamationmark.shield",
                    label: L10n.WalletHome.securityBackupRow,
                    value: health.hasSealedBackup
                        ? L10n.WalletHome.securityBackupOn
                        : L10n.WalletHome.securityBackupOff,
                    valueLevel: health.backupAttention ? .attention : .safe,
                    cta: nil
                )
                NavigationLink {
                    SecurityDetailView()
                } label: {
                    HStack(spacing: 4) {
                        Spacer()
                        Text(L10n.WalletHome.securityViewDetails)
                            .font(.caption.weight(.medium))
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.top, 2)
                }
                .accessibilityIdentifier("securityHealth_details")
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(health.overall.tint.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(health.overall.tint.opacity(0.35), lineWidth: 1))
            .sheet(item: $rotationTarget) { w in
                RefreshShardSheet(wallet: w, appState: appState)
                    .environmentObject(appState)
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func header(health: Health) -> some View {
        HStack(spacing: 10) {
            Image(systemName: health.overall.iconName)
                .font(.title3)
                .foregroundStyle(health.overall.tint)
            Text(health.overall.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            Spacer()
            if health.overall != .safe {
                Button {
                    withAnimation { snoozedAt = Date() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(L10n.Rotate.nudgeDismiss)
            }
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func row(
        icon: String,
        label: String,
        value: String,
        valueLevel: Level,
        cta: (title: String, action: () -> Void)?
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(valueLevel.tint.opacity(0.9))
                .frame(width: 18)
            Text(label)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
            Text(value)
                .font(.caption.weight(.medium))
                .foregroundStyle(valueLevel == .safe ? .white.opacity(0.85) : valueLevel.tint)
            if let cta {
                Button(action: cta.action) {
                    Text(cta.title)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(HorcruxTheme.accentCyan))
                        .foregroundStyle(.black)
                }
                .accessibilityIdentifier("securityHealth_rotateCTA")
            }
        }
    }

    // MARK: - Model

    enum Level: Int, Comparable {
        case safe = 0, attention = 1, risk = 2
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

        var iconName: String {
            switch self {
            case .safe:      return "checkmark.shield.fill"
            case .attention: return "exclamationmark.shield.fill"
            case .risk:      return "xmark.shield.fill"
            }
        }
        var tint: Color {
            switch self {
            case .safe:      return HorcruxTheme.successGreen
            case .attention: return HorcruxTheme.accentCyan
            case .risk:      return HorcruxTheme.warningAmber
            }
        }
        var title: String {
            switch self {
            case .safe:      return L10n.WalletHome.securityTitleSafe
            case .attention: return L10n.WalletHome.securityTitleAttention
            case .risk:      return L10n.WalletHome.securityTitleRisk
            }
        }
    }

    private struct Health {
        let overall: Level
        let rotation: Level
        let rotationDaysText: String?
        let hasSealedBackup: Bool
        let backupAttention: Bool
        let staleWalletForCTA: Wallet?
    }

    private func computeHealth() -> Health {
        let firstRefreshable = walletStore.wallets.first { w in
            !w.hidden && w.threshold == w.totalParties && w.chain.curveType == .secp256k1
        }
        let stale = walletStore.wallets.first { w in
            w.threshold == w.totalParties &&
            w.chain.curveType == .secp256k1 &&
            !w.hidden &&
            RefreshTracker.needsRotation(accountId: w.accountId, walletCreatedAt: w.createdAt)
        }

        var daysText: String? = nil
        var rotationLvl: Level = .safe
        if let w = firstRefreshable {
            if let last = RefreshTracker.lastRefresh(accountId: w.accountId) {
                let d = Calendar.current.dateComponents([.day], from: last, to: Date()).day ?? 0
                daysText = L10n.WalletHome.securityRotationAgo(d)
                if d >= 180 {
                    rotationLvl = .risk
                } else if stale != nil {
                    rotationLvl = .attention
                }
            } else {
                daysText = L10n.WalletHome.securityRotationNever
                rotationLvl = stale != nil ? .attention : .safe
            }
        }

        let sealed = SecureKeyVault.hasSESealed
        let bioAvailable = BiometricAuth.shared.availableType != .none
        let backupAttention = !sealed && bioAvailable && firstRefreshable != nil
        let overall = max(rotationLvl, backupAttention ? .attention : .safe)

        return Health(
            overall: overall,
            rotation: rotationLvl,
            rotationDaysText: daysText,
            hasSealedBackup: sealed,
            backupAttention: backupAttention,
            staleWalletForCTA: stale
        )
    }
}
