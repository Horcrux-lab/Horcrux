import SwiftUI

/// Full security breakdown — pushed from the home `SecurityHealthCard`.
/// Intentionally read-only except for the per-wallet Rotate CTA: this screen
/// is a "status & explanation" surface, not a settings screen. Actual toggles
/// live under Settings (biometric) and per-wallet detail (rotate).
struct SecurityDetailView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var walletStore: WalletStore
    @State private var rotationTarget: Wallet?
    @State private var isEnablingBackup = false
    @State private var backupErrorMessage: String?
    @State private var backupRefreshToken = 0

    var body: some View {
        ZStack {
            HorcruxTheme.backgroundGradient.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    overallCard
                    rotationSection
                    backupSection
                    mpcTipsSection
                }
                .padding(16)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle(L10n.SecurityDetail.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $rotationTarget) { w in
            RefreshShardSheet(wallet: w, appState: appState)
                .environmentObject(appState)
        }
        .alert(
            backupErrorTitle,
            isPresented: Binding(
                get: { backupErrorMessage != nil },
                set: { if !$0 { backupErrorMessage = nil } }
            ),
            actions: { Button("OK", role: .cancel) { backupErrorMessage = nil } },
            message: { Text(backupErrorMessage ?? "") }
        )
    }

    private var backupErrorTitle: String {
        backupErrorMessage == L10n.SecurityDetail.backupRelockedMsg
            ? L10n.SecurityDetail.backupRelockedTitle
            : L10n.SecurityDetail.backupEnableFailedTitle
    }

    // MARK: - Aggregate

    private struct Aggregate {
        let overall: Level
        let rotationNeeds: [Wallet]   // wallets with stale rotation
        let sealed: Bool
        let bioAvailable: Bool
    }

    private enum Level: Int, Comparable {
        case safe = 0, attention = 1, risk = 2
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

        var tint: Color {
            switch self {
            case .safe:      return HorcruxTheme.successGreen
            case .attention: return HorcruxTheme.accentCyan
            case .risk:      return HorcruxTheme.warningAmber
            }
        }
        var icon: String {
            switch self {
            case .safe:      return "checkmark.shield.fill"
            case .attention: return "exclamationmark.shield.fill"
            case .risk:      return "xmark.shield.fill"
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

    private func aggregate() -> Aggregate {
        let refreshable = walletStore.wallets.filter {
            !$0.hidden && $0.threshold == $0.totalParties && $0.chain.curveType == .secp256k1
        }
        var stale: [Wallet] = []
        var worstRotation: Level = .safe
        for w in refreshable {
            if let last = RefreshTracker.lastRefresh(accountId: w.accountId) {
                let d = Calendar.current.dateComponents([.day], from: last, to: Date()).day ?? 0
                if d >= 180 { worstRotation = max(worstRotation, .risk); stale.append(w) }
                else if d >= 90 { worstRotation = max(worstRotation, .attention); stale.append(w) }
            } else {
                // Never rotated — flag as attention only.
                worstRotation = max(worstRotation, .attention)
                stale.append(w)
            }
        }
        let sealed = SecureKeyVault.hasSESealed
        let bioAvailable = BiometricAuth.shared.availableType != .none
        let backupLvl: Level = (!sealed && bioAvailable && !refreshable.isEmpty) ? .attention : .safe
        let overall = max(worstRotation, backupLvl)
        return Aggregate(overall: overall, rotationNeeds: stale, sealed: sealed, bioAvailable: bioAvailable)
    }

    // MARK: - Sections

    @ViewBuilder
    private var overallCard: some View {
        let agg = aggregate()
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: agg.overall.icon)
                    .font(.title2)
                    .foregroundStyle(agg.overall.tint)
                Text(agg.overall.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
            }
            Text(L10n.SecurityDetail.overallBlurb)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(agg.overall.tint.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(agg.overall.tint.opacity(0.35), lineWidth: 1))
    }

    @ViewBuilder
    private var rotationSection: some View {
        // Group refreshable wallets by accountId (= same DKG ceremony = same
        // key share). One rotation ceremony refreshes the whole account, so
        // we show one row per account instead of per chain.
        let refreshable = walletStore.wallets.filter {
            !$0.hidden && $0.threshold == $0.totalParties && $0.chain.curveType == .secp256k1
        }
        let accounts = ShardAccount.group(refreshable)
        sectionHeader(
            icon: "arrow.triangle.2.circlepath",
            title: L10n.SecurityDetail.rotationTitle,
            subtitle: L10n.SecurityDetail.rotationSubtitle
        )
        if accounts.isEmpty {
            infoRow(text: L10n.SecurityDetail.rotationNone)
        } else {
            VStack(spacing: 8) {
                ForEach(accounts) { acct in
                    rotationRow(for: acct)
                }
            }
        }
    }

    @ViewBuilder
    private func rotationRow(for acct: ShardAccount) -> some View {
        let representative = acct.wallets.first!
        let last = RefreshTracker.lastRefresh(accountId: acct.id)
        let days = last.map { Calendar.current.dateComponents([.day], from: $0, to: Date()).day ?? 0 }
        let lvl: Level = {
            guard let d = days else { return .attention }
            if d >= 180 { return .risk }
            if d >= 90 { return .attention }
            return .safe
        }()
        let valueText: String = days.map { L10n.WalletHome.securityRotationAgo($0) } ?? L10n.WalletHome.securityRotationNever

        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(acct.name.isEmpty ? L10n.SecurityDetail.shardGenericName : acct.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                Text(valueText)
                    .font(.caption)
                    .foregroundStyle(lvl == .safe ? .white.opacity(0.6) : lvl.tint)
            }
            Spacer()
            if lvl != .safe {
                Button {
                    rotationTarget = representative
                } label: {
                    Text(L10n.Rotate.nudgeCTA)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(HorcruxTheme.accentCyan))
                        .foregroundStyle(.black)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
    }

    @ViewBuilder
    private var backupSection: some View {
        let agg = aggregate()
        sectionHeader(
            icon: "faceid",
            title: L10n.SecurityDetail.backupTitle,
            subtitle: L10n.SecurityDetail.backupSubtitle
        )
        HStack(spacing: 10) {
            Image(systemName: agg.sealed ? "checkmark.shield.fill" : "exclamationmark.shield")
                .foregroundStyle(agg.sealed ? HorcruxTheme.successGreen : (agg.bioAvailable ? HorcruxTheme.accentCyan : .white.opacity(0.5)))
            Text(agg.sealed
                 ? L10n.WalletHome.securityBackupOn
                 : (agg.bioAvailable
                    ? L10n.WalletHome.securityBackupOff
                    : L10n.SecurityDetail.backupUnavailable))
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))

        if !agg.sealed && agg.bioAvailable {
            Text(L10n.SecurityDetail.backupHint)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)

            Button {
                enableBiometricBackup()
            } label: {
                HStack {
                    if isEnablingBackup {
                        ProgressView().controlSize(.small).tint(.white)
                        Text(L10n.SecurityDetail.backupEnabling)
                    } else {
                        Image(systemName: "faceid")
                        Text(L10n.SecurityDetail.backupEnable)
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(HorcruxTheme.accentCyan.opacity(isEnablingBackup ? 0.4 : 0.7))
                )
            }
            .disabled(isEnablingBackup)
            .accessibilityIdentifier("securityDetail_enableBiometricBackup")
        }
    }

    private func enableBiometricBackup() {
        guard !isEnablingBackup else { return }
        guard let swk = appState.cachedShardKey() else {
            backupErrorMessage = L10n.SecurityDetail.backupRelockedMsg
            return
        }
        isEnablingBackup = true
        Task.detached {
            let result: Result<Void, Error> = {
                do {
                    try SecureKeyVault.sealBackupNow(swk: swk)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }()
            await MainActor.run {
                isEnablingBackup = false
                switch result {
                case .success:
                    backupRefreshToken &+= 1
                case .failure(let err):
                    SecureLog.error("Manual SE backup seal failed: \(err.localizedDescription)")
                    let detail = err.localizedDescription
                    backupErrorMessage = "\(L10n.SecurityDetail.backupEnableFailedGeneric)\n\n\(detail)"
                }
            }
        }
    }

    @ViewBuilder
    private var mpcTipsSection: some View {
        sectionHeader(
            icon: "lock.shield",
            title: L10n.SecurityDetail.mpcTitle,
            subtitle: nil
        )
        VStack(alignment: .leading, spacing: 10) {
            bullet(L10n.SecurityDetail.mpcTip1)
            bullet(L10n.SecurityDetail.mpcTip2)
            bullet(L10n.SecurityDetail.mpcTip3)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sectionHeader(icon: String, title: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.footnote)
                    .foregroundStyle(HorcruxTheme.accentCyan)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func infoRow(text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.7))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
    }

    @ViewBuilder
    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 4))
                .foregroundStyle(HorcruxTheme.accentCyan)
                .padding(.top, 8)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
