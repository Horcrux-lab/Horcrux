import Foundation

/// Audit export for transaction history and approval queue.
///
/// Produces two formats per store:
///
///   • **CSV** — UTF-8, RFC-4180 quoted. Opens straight in Numbers /
///     Excel / Google Sheets. ISO-8601 timestamps for easy sorting.
///   • **JSON** — pretty-printed, ISO-8601 dates. Field names match
///     the on-disk persistence schema so an auditor's tool can diff
///     against the raw store files.
///
/// Output is emitted via `File` structs carrying both the bytes and a
/// suggested filename; callers hand these to SwiftUI's `ShareLink`
/// which takes care of the Files / Mail / AirDrop share sheet.
enum AuditExport {

    // MARK: - Public file wrappers

    struct File: Identifiable, Hashable {
        let id = UUID()
        let filename: String
        let data: Data
        /// Best-effort hint for the share sheet — both CSV and JSON
        /// happen to be UTF-8 text, so consumer apps auto-preview.
        let utiHint: String
    }

    enum Format: String {
        case csv
        case json
    }

    // MARK: - Transactions

    static func transactions(_ records: [TransactionRecord], as format: Format) -> File {
        let stamp = timestampSuffix()
        switch format {
        case .csv:
            let header = [
                "id", "wallet_id", "chain", "from_address", "to_address",
                "amount", "fee", "tx_hash", "status",
                "created_at", "broadcast_at", "confirmed_at"
            ]
            var rows: [[String]] = [header]
            for r in records {
                rows.append([
                    r.id,
                    r.walletId,
                    r.chain.rawValue,
                    r.fromAddress,
                    r.toAddress,
                    r.amount,
                    r.fee ?? "",
                    r.txHash ?? "",
                    r.status.rawValue,
                    iso(r.createdAt),
                    iso(r.broadcastAt),
                    iso(r.confirmedAt)
                ])
            }
            return File(
                filename: "horcrux_transactions_\(stamp).csv",
                data: csvBytes(rows),
                utiHint: "public.comma-separated-values-text"
            )
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = (try? encoder.encode(records)) ?? Data("[]".utf8)
            return File(
                filename: "horcrux_transactions_\(stamp).json",
                data: data,
                utiHint: "public.json"
            )
        }
    }

    // MARK: - Approval queue

    static func approvals(_ requests: [ApprovalRequest], as format: Format) -> File {
        let stamp = timestampSuffix()
        switch format {
        case .csv:
            let header = [
                "id", "session_id", "group_public_key", "chain",
                "recipient", "amount", "token_symbol", "fee",
                "initiator_device", "status", "created_at", "resolved_at"
            ]
            var rows: [[String]] = [header]
            for r in requests {
                rows.append([
                    r.id,
                    r.sessionId,
                    r.groupPublicKey,
                    r.chain,
                    r.recipient,
                    r.amount,
                    r.tokenSymbol ?? "",
                    r.feeDisplay ?? "",
                    r.initiatorDeviceName,
                    r.status.rawValue,
                    iso(r.createdAt),
                    iso(r.resolvedAt)
                ])
            }
            return File(
                filename: "horcrux_approvals_\(stamp).csv",
                data: csvBytes(rows),
                utiHint: "public.comma-separated-values-text"
            )
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = (try? encoder.encode(requests)) ?? Data("[]".utf8)
            return File(
                filename: "horcrux_approvals_\(stamp).json",
                data: data,
                utiHint: "public.json"
            )
        }
    }

    // MARK: - Helpers

    /// RFC-4180 CSV encoder. Quote cells that contain `,`, `"`, CR or
    /// LF; double-up internal quotes. UTF-8 BOM prepended so Excel on
    /// Windows doesn't mojibake non-ASCII names.
    private static func csvBytes(_ rows: [[String]]) -> Data {
        var out = Data([0xEF, 0xBB, 0xBF]) // UTF-8 BOM
        for row in rows {
            let line = row.map(quote).joined(separator: ",")
            out.append(Data(line.utf8))
            out.append(Data("\r\n".utf8))
        }
        return out
    }

    private static func quote(_ cell: String) -> String {
        if cell.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            let escaped = cell.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return cell
    }

    private static func iso(_ date: Date?) -> String {
        guard let date else { return "" }
        return Self.isoFormatter.string(from: date)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func timestampSuffix() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}
