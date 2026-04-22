import XCTest
@testable import Horcrux

/// Unit tests for `AuditExport`. These cover the parts of the contract
/// downstream tools (Excel, auditor scripts) actually depend on:
///
///   • CSV: UTF-8 BOM header, RFC-4180 quoting, CRLF line endings
///   • JSON: pretty-printed, sorted keys, ISO-8601 dates
///   • Filename pattern: `horcrux_<kind>_<yyyyMMdd-HHmmss>.<ext>`
///
/// The view layer (AuditExportView) is intentionally not tested — it's
/// a thin wrapper over `ShareLink`.
final class AuditExportTests: XCTestCase {

    // MARK: - Fixtures

    private func makeTx(
        id: String = "tx-1",
        amount: String = "0.5",
        toAddress: String = "0xabc",
        broadcastAt: Date? = nil
    ) -> TransactionRecord {
        TransactionRecord(
            id: id,
            walletId: "wallet-1",
            chain: .ethereum,
            fromAddress: "0xfrom",
            toAddress: toAddress,
            amount: amount,
            fee: "0.0001",
            txHash: "0xdeadbeef",
            status: .broadcast,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            broadcastAt: broadcastAt,
            confirmedAt: nil
        )
    }

    // MARK: - CSV: structural invariants

    func testCSVStartsWithUTF8BOM() {
        let file = AuditExport.transactions([makeTx()], as: .csv)
        XCTAssertEqual(file.data.prefix(3), Data([0xEF, 0xBB, 0xBF]),
                       "Excel on Windows mojibakes non-ASCII without a BOM.")
    }

    func testCSVUsesCRLFLineEndings() {
        let file = AuditExport.transactions([makeTx()], as: .csv)
        let body = String(data: file.data, encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("\r\n"),
                      "RFC-4180 requires CRLF; some parsers reject LF-only.")
    }

    func testCSVHasHeaderRow() {
        let file = AuditExport.transactions([makeTx()], as: .csv)
        let body = String(data: file.data, encoding: .utf8) ?? ""
        let firstLine = body.split(separator: "\r\n", maxSplits: 1).first ?? ""
        XCTAssertTrue(firstLine.contains("id"))
        XCTAssertTrue(firstLine.contains("wallet_id"))
        XCTAssertTrue(firstLine.contains("chain"))
        XCTAssertTrue(firstLine.contains("created_at"))
    }

    // MARK: - CSV: RFC-4180 quoting

    func testCSVQuotesCellsContainingComma() {
        let tx = makeTx(toAddress: "Smith, John")
        let file = AuditExport.transactions([tx], as: .csv)
        let body = String(data: file.data, encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("\"Smith, John\""),
                      "Cells containing ',' must be wrapped in double quotes.")
    }

    func testCSVDoublesUpInternalQuotes() {
        let tx = makeTx(toAddress: "alias \"foo\"")
        let file = AuditExport.transactions([tx], as: .csv)
        let body = String(data: file.data, encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("\"alias \"\"foo\"\"\""),
                      "Per RFC-4180, internal \" must become \"\" inside a quoted cell.")
    }

    func testCSVQuotesCellsContainingNewlines() {
        let tx = makeTx(toAddress: "line1\nline2")
        let file = AuditExport.transactions([tx], as: .csv)
        let body = String(data: file.data, encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("\"line1\nline2\""))
    }

    func testCSVDoesNotQuotePlainCells() {
        let file = AuditExport.transactions([makeTx(toAddress: "0xabc")], as: .csv)
        let body = String(data: file.data, encoding: .utf8) ?? ""
        // 0xabc has no special chars → must appear unquoted
        XCTAssertTrue(body.contains(",0xabc,"))
        XCTAssertFalse(body.contains("\"0xabc\""))
    }

    // MARK: - CSV: ISO-8601 dates and nil handling

    func testCSVEmitsISO8601ForDates() {
        let file = AuditExport.transactions([makeTx()], as: .csv)
        let body = String(data: file.data, encoding: .utf8) ?? ""
        // 1_700_000_000 → 2023-11-14T22:13:20.000Z
        XCTAssertTrue(body.contains("2023-11-14T22:13:20"),
                      "createdAt must serialize as ISO-8601, found body=\(body)")
    }

    func testCSVEmitsEmptyStringForNilDates() {
        let file = AuditExport.transactions([makeTx(broadcastAt: nil)], as: .csv)
        let body = String(data: file.data, encoding: .utf8) ?? ""
        // Two consecutive commas around the broadcast_at column = nil rendered as empty
        XCTAssertTrue(body.contains(",,"),
                      "Nil dates should be empty cells, not the literal string 'nil'.")
    }

    // MARK: - JSON: structural invariants

    func testJSONIsValidAndDecodableRoundTrip() throws {
        let original = makeTx()
        let file = AuditExport.transactions([original], as: .json)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([TransactionRecord].self, from: file.data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].id, original.id)
        XCTAssertEqual(decoded[0].amount, original.amount)
        XCTAssertEqual(decoded[0].createdAt, original.createdAt)
    }

    func testJSONIsPrettyPrinted() {
        let file = AuditExport.transactions([makeTx()], as: .json)
        let body = String(data: file.data, encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("\n"),
                      "Pretty-printed JSON should have newlines for human review.")
    }

    func testJSONKeysAreSorted() {
        let file = AuditExport.transactions([makeTx()], as: .json)
        let body = String(data: file.data, encoding: .utf8) ?? ""
        // 'amount' < 'chain' < 'createdAt' < 'fee' alphabetically
        let amountIdx = body.range(of: "\"amount\"")?.lowerBound
        let chainIdx = body.range(of: "\"chain\"")?.lowerBound
        let createdIdx = body.range(of: "\"createdAt\"")?.lowerBound
        XCTAssertNotNil(amountIdx)
        XCTAssertNotNil(chainIdx)
        XCTAssertNotNil(createdIdx)
        if let a = amountIdx, let c = chainIdx, let cr = createdIdx {
            XCTAssertLessThan(a, c)
            XCTAssertLessThan(c, cr)
        }
    }

    // MARK: - Filename pattern

    func testCSVFilenameFollowsConvention() {
        let file = AuditExport.transactions([], as: .csv)
        XCTAssertTrue(file.filename.hasPrefix("horcrux_transactions_"))
        XCTAssertTrue(file.filename.hasSuffix(".csv"))
        // YYYYMMDD-HHMMSS = 15 chars between prefix and extension
        let stamp = file.filename
            .dropFirst("horcrux_transactions_".count)
            .dropLast(".csv".count)
        XCTAssertEqual(stamp.count, 15, "Stamp '\(stamp)' isn't yyyyMMdd-HHmmss")
        XCTAssertEqual(stamp[stamp.index(stamp.startIndex, offsetBy: 8)], "-")
    }

    func testJSONFilenameUsesJSONExtension() {
        let file = AuditExport.transactions([], as: .json)
        XCTAssertTrue(file.filename.hasSuffix(".json"))
    }

    // MARK: - Empty inputs

    func testEmptyRecordListProducesHeaderOnlyCSV() {
        let file = AuditExport.transactions([], as: .csv)
        let body = String(data: file.data, encoding: .utf8) ?? ""
        // BOM + header line + CRLF, no data rows
        let lines = body
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .split(separator: "\r\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 1, "Empty list should produce header only.")
    }

    func testEmptyRecordListProducesEmptyJSONArray() throws {
        let file = AuditExport.transactions([], as: .json)
        let decoded = try JSONDecoder().decode([TransactionRecord].self, from: file.data)
        XCTAssertTrue(decoded.isEmpty)
    }
}
