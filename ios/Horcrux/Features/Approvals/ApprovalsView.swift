import SwiftUI

/// Approval-queue landing screen. Three sections:
///   • Pending — requests scanned but not yet approved / rejected.
///   • Stale — pending entries older than `ApprovalRequest.pendingTTL`.
///     Their relay sessions are almost certainly gone.
///   • Recent — approved / rejected / expired. Audit tail.
///
/// There is no "Resume" action in this MVP: MPC signing requires the
/// counterparty to still be live on the same relay session, which we
/// can't guarantee from a persisted snapshot. The queue's value is
/// **tracking** decisions + future auditability.
struct ApprovalsView: View {
    @ObservedObject private var store = ApprovalRequestStore.shared
    @State private var showClearConfirm = false
    @State private var selected: ApprovalRequest?

    var body: some View {
        NavigationStack {
            Group {
                if store.requests.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .background(HorcruxTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle(L10n.Approvals.navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                if !store.recent.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showClearConfirm = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .tint(HorcruxTheme.subtleText)
                    }
                }
            }
            .confirmationDialog(
                L10n.Approvals.actionClearHistory,
                isPresented: $showClearConfirm,
                titleVisibility: .visible
            ) {
                Button(L10n.Approvals.actionClearHistory, role: .destructive) {
                    store.clearResolved()
                }
                Button(L10n.Common.cancel, role: .cancel) {}
            }
            .sheet(item: $selected) { req in
                ApprovalDetailSheet(request: req)
                    .presentationDetents([.medium, .large])
            }
        }
        .preferredColorScheme(.dark)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 18) {
                if !store.pending.isEmpty {
                    section(title: L10n.Approvals.pendingSection,
                            count: store.pending.count,
                            tint: HorcruxTheme.warningAmber,
                            items: store.pending,
                            stale: false)
                }
                if !store.stalePending.isEmpty {
                    section(title: L10n.Approvals.staleSection,
                            count: store.stalePending.count,
                            tint: HorcruxTheme.dangerRed,
                            items: store.stalePending,
                            stale: true)
                }
                if !store.recent.isEmpty {
                    section(title: L10n.Approvals.recentSection,
                            count: store.recent.count,
                            tint: HorcruxTheme.subtleText,
                            items: store.recent,
                            stale: false)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func section(title: String,
                         count: Int,
                         tint: Color,
                         items: [ApprovalRequest],
                         stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(HorcruxTheme.subtleText)
                Text("\(count)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(tint.opacity(0.18)))
                    .foregroundStyle(tint)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 8) {
                ForEach(items) { req in
                    ApprovalRowView(request: req, stale: stale)
                        .contentShape(Rectangle())
                        .onTapGesture { selected = req }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(HorcruxTheme.subtleText)
            Text(L10n.Approvals.emptyTitle)
                .font(.headline)
                .foregroundStyle(.white)
            Text(L10n.Approvals.emptyMessage)
                .font(.footnote)
                .foregroundStyle(HorcruxTheme.subtleText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Row

private struct ApprovalRowView: View {
    let request: ApprovalRequest
    let stale: Bool

    @ObservedObject private var store = ApprovalRequestStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                chainBadge
                VStack(alignment: .leading, spacing: 2) {
                    Text(amountLine)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(recipientShort)
                        .font(.caption.monospaced())
                        .foregroundStyle(HorcruxTheme.subtleText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                statusPill
            }
            if stale {
                Text(L10n.Approvals.staleWarning)
                    .font(.caption2)
                    .foregroundStyle(HorcruxTheme.dangerRed)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 4) {
                Text(String(format: L10n.Approvals.fromInitiator, request.initiatorDeviceName))
                    .font(.caption2)
                    .foregroundStyle(HorcruxTheme.subtleText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Text(relativeTimeLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(HorcruxTheme.subtleText)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .opacity(stale ? 0.75 : 1.0)
        .contextMenu {
            if request.status == .pending {
                Button(role: .destructive) {
                    store.resolve(id: request.id, as: .rejected)
                    Haptics.success()
                } label: {
                    Label(L10n.Approvals.actionReject, systemImage: "xmark.circle")
                }
            }
            Button(role: .destructive) {
                store.delete(id: request.id)
                Haptics.success()
            } label: {
                Label(L10n.Approvals.actionDismiss, systemImage: "trash")
            }
        }
    }

    private var amountLine: String {
        let sym = request.tokenSymbol ?? chainSymbol
        return "\(request.amount) \(sym)"
    }

    private var chainSymbol: String {
        Chain(rawValue: request.chain)?.symbol ?? request.chain.uppercased()
    }

    private var recipientShort: String {
        let a = request.recipient
        guard a.count > 14 else { return a }
        return a.prefix(6) + "…" + a.suffix(6)
    }

    private var chainBadge: some View {
        ZStack {
            Circle()
                .fill(HorcruxTheme.accentPurple.opacity(0.2))
                .overlay(Circle().stroke(HorcruxTheme.accentPurple.opacity(0.55), lineWidth: 1))
            Text(String(chainSymbol.prefix(2)))
                .font(.caption.weight(.bold).monospaced())
                .foregroundStyle(.white)
        }
        .frame(width: 32, height: 32)
    }

    private var statusPill: some View {
        let (label, color, icon) = statusMeta
        return HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2.weight(.heavy))
            Text(label).font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.18)))
        .overlay(Capsule().stroke(color.opacity(0.5), lineWidth: 1))
        .foregroundStyle(color)
    }

    private var statusMeta: (String, Color, String) {
        switch request.status {
        case .pending:
            return (L10n.Approvals.statusPending, HorcruxTheme.warningAmber, "clock")
        case .approved:
            return (L10n.Approvals.statusApproved, HorcruxTheme.successGreen, "checkmark.seal")
        case .rejected:
            return (L10n.Approvals.statusRejected, HorcruxTheme.dangerRed, "xmark.circle")
        case .expired:
            return (L10n.Approvals.statusExpired, HorcruxTheme.subtleText, "hourglass")
        }
    }

    private var relativeTimeLabel: String {
        let ts = request.resolvedAt ?? request.createdAt
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: ts, relativeTo: Date())
    }
}

// MARK: - Detail Sheet

private struct ApprovalDetailSheet: View {
    let request: ApprovalRequest

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = ApprovalRequestStore.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    row(L10n.Approvals.detailChain, chainLabel)
                    row(L10n.Approvals.detailAmount, "\(request.amount) \(request.tokenSymbol ?? chainLabel)")
                    row(L10n.Approvals.detailRecipient, request.recipient, mono: true)
                    row(L10n.Approvals.detailInitiator, request.initiatorDeviceName)
                    row(L10n.Approvals.detailStatus, statusLabel)
                    row(L10n.Approvals.detailCreated, dateLabel(request.createdAt))
                    if let r = request.resolvedAt {
                        row(L10n.Approvals.detailResolved, dateLabel(r))
                    }
                    row(L10n.Approvals.detailSession, request.sessionId, mono: true)

                    if request.status == .pending {
                        if request.isStale {
                            Text(L10n.Approvals.detailResumeUnavailable)
                                .font(.caption)
                                .foregroundStyle(HorcruxTheme.subtleText)
                                .padding(.top, 4)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(L10n.Approvals.resumeHint)
                                .font(.caption)
                                .foregroundStyle(HorcruxTheme.subtleText)
                                .padding(.top, 4)
                                .fixedSize(horizontal: false, vertical: true)

                            Button {
                                Haptics.success()
                                DeepLinkRouter.shared.handle(.joinSession(sessionId: request.sessionId))
                                dismiss()
                            } label: {
                                Label(L10n.Approvals.actionResume, systemImage: "signature")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(HorcruxTheme.accentCyan)
                            .padding(.top, 4)
                        }

                        Button(role: .destructive) {
                            store.resolve(id: request.id, as: .rejected)
                            Haptics.success()
                            dismiss()
                        } label: {
                            Label(L10n.Approvals.actionReject, systemImage: "xmark.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(HorcruxTheme.dangerRed)
                        .padding(.top, 8)
                    }

                    Button(role: .destructive) {
                        store.delete(id: request.id)
                        Haptics.success()
                        dismiss()
                    } label: {
                        Label(L10n.Approvals.actionDismiss, systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(HorcruxTheme.subtleText)
                }
                .padding(16)
            }
            .background(HorcruxTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle(L10n.Approvals.detailTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.Common.cancel) { dismiss() }
                        .tint(HorcruxTheme.subtleText)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(HorcruxTheme.subtleText)
            Text(value)
                .font(mono ? .footnote.monospaced() : .subheadline)
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chainLabel: String {
        Chain(rawValue: request.chain)?.symbol ?? request.chain.uppercased()
    }

    private var statusLabel: String {
        switch request.status {
        case .pending:  return L10n.Approvals.statusPending
        case .approved: return L10n.Approvals.statusApproved
        case .rejected: return L10n.Approvals.statusRejected
        case .expired:  return L10n.Approvals.statusExpired
        }
    }

    private func dateLabel(_ d: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: d)
    }
}
