import SwiftUI
import UniformTypeIdentifiers

/// Audit export: writes the transaction history + approval queue to
/// CSV or JSON and hands the file off via the system share sheet.
///
/// Kept deliberately simple — no server roundtrip, no redaction
/// toggles. The raw stores are already only stored on-device, and the
/// user asked for an audit trail, not a sanitised one. If a compliance
/// flow later needs redaction (drop recipient, hash sessionId, etc.)
/// add a toggle here and branch inside `AuditExport`.
struct AuditExportView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var approvalStore = ApprovalRequestStore.shared
    /// Temp files retained for the lifetime of this view so `ShareLink`
    /// targets stay valid while the share sheet is open. Cleaned up on
    /// disappear. Keyed by `(kind, format)` so repeated taps reuse.
    @State private var cachedURLs: [String: URL] = [:]

    private var transactionCount: Int { appState.transactionStore.records.count }
    private var approvalCount: Int { approvalStore.requests.count }

    var body: some View {
        ZStack {
            HorcruxTheme.backgroundGradient.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    card(
                        title: NSLocalizedString("auditExport.transactions.title",
                                                 value: "Transaction history",
                                                 comment: ""),
                        subtitle: String(format: NSLocalizedString("auditExport.transactions.subtitle",
                                                                    value: "%d signed / broadcast records",
                                                                    comment: ""),
                                         transactionCount),
                        icon: "list.bullet.clipboard",
                        iconColor: HorcruxTheme.accentCyan,
                        isEmpty: transactionCount == 0,
                        csvURL: url(for: "tx", format: .csv),
                        jsonURL: url(for: "tx", format: .json)
                    )
                    card(
                        title: NSLocalizedString("auditExport.approvals.title",
                                                 value: "Approval queue",
                                                 comment: ""),
                        subtitle: String(format: NSLocalizedString("auditExport.approvals.subtitle",
                                                                    value: "%d approve / reject entries",
                                                                    comment: ""),
                                         approvalCount),
                        icon: "checkmark.seal",
                        iconColor: HorcruxTheme.accentPurple,
                        isEmpty: approvalCount == 0,
                        csvURL: url(for: "approvals", format: .csv),
                        jsonURL: url(for: "approvals", format: .json)
                    )
                    footer
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .navigationTitle(NSLocalizedString("auditExport.title",
                                            value: "Export Audit Log",
                                            comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .onDisappear { cleanupTempFiles() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(NSLocalizedString("auditExport.header.title",
                                   value: "On-device audit trail",
                                   comment: ""))
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text(NSLocalizedString("auditExport.header.body",
                                   value: "Export both stores for offline review, compliance reporting, or backup. Files never leave this device unless you share them.",
                                   comment: ""))
                .font(.caption)
                .foregroundStyle(HorcruxTheme.subtleText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func card(title: String, subtitle: String, icon: String,
                      iconColor: Color, isEmpty: Bool,
                      csvURL: URL?, jsonURL: URL?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(iconColor)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(iconColor.opacity(0.15)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(HorcruxTheme.subtleText)
                }
            }

            if isEmpty {
                Text(NSLocalizedString("auditExport.emptyHint",
                                       value: "Nothing to export yet.",
                                       comment: ""))
                    .font(.caption)
                    .foregroundStyle(HorcruxTheme.subtleText)
                    .padding(.vertical, 6)
            } else {
                HStack(spacing: 10) {
                    if let csvURL {
                        ShareLink(item: csvURL, preview: SharePreview(csvURL.lastPathComponent)) {
                            exportButton(label: "CSV", icon: "tablecells")
                        }
                        .accessibilityLabel(String(format: NSLocalizedString("auditExport.share.csv",
                                                                              value: "Share %@ as CSV",
                                                                              comment: ""), title))
                    }
                    if let jsonURL {
                        ShareLink(item: jsonURL, preview: SharePreview(jsonURL.lastPathComponent)) {
                            exportButton(label: "JSON", icon: "curlybraces")
                        }
                        .accessibilityLabel(String(format: NSLocalizedString("auditExport.share.json",
                                                                              value: "Share %@ as JSON",
                                                                              comment: ""), title))
                    }
                }
            }
        }
        .padding(14)
        .glassCard()
    }

    private func exportButton(label: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
            Text(label)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule().fill(HorcruxTheme.accentBlue.opacity(0.24))
        )
        .overlay(
            Capsule().stroke(HorcruxTheme.accentBlue.opacity(0.5), lineWidth: 0.5)
        )
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(NSLocalizedString("auditExport.footer.privacy",
                                     value: "Exports include wallet addresses, transaction amounts, and counterparty addresses in cleartext. Store them like you would any financial statement.",
                                     comment: ""),
                  systemImage: "lock.shield")
                .font(.caption2)
                .foregroundStyle(HorcruxTheme.subtleText)
                .labelStyle(.titleAndIcon)
        }
        .padding(.top, 4)
    }

    // MARK: - Temp-file pipeline

    /// Materialise the export bytes as a temp file and return its URL
    /// so `ShareLink(item: URL)` can present the share sheet. Files
    /// live under `NSTemporaryDirectory()/horcrux-audit/` and are
    /// swept on view dismissal.
    private func url(for kind: String, format: AuditExport.Format) -> URL? {
        let key = "\(kind).\(format.rawValue)"
        if let cached = cachedURLs[key], FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }

        let file: AuditExport.File?
        switch kind {
        case "tx":
            guard !appState.transactionStore.records.isEmpty else { return nil }
            file = AuditExport.transactions(appState.transactionStore.records, as: format)
        case "approvals":
            guard !approvalStore.requests.isEmpty else { return nil }
            file = AuditExport.approvals(approvalStore.requests, as: format)
        default:
            file = nil
        }
        guard let file else { return nil }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("horcrux-audit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(file.filename)
        do {
            try file.data.write(to: url, options: [.atomic])
            cachedURLs[key] = url
            return url
        } catch {
            SecureLog.error("AuditExportView: failed to stage \(file.filename): \(error)")
            return nil
        }
    }

    private func cleanupTempFiles() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("horcrux-audit", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        cachedURLs.removeAll()
    }
}
