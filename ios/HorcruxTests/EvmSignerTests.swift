import XCTest
@testable import Horcrux

/// `EvmSigner` turns the unsigned EIP-1559 envelope Rust builds plus the MPC
/// (r, s, y_parity) into the hex a node accepts from
/// `eth_sendRawTransaction`. Every assertion here is on exact bytes, because
/// RLP has no redundancy: a length prefix that is one byte off, or a zero
/// encoded as `0x00` instead of the empty string, changes the transaction
/// hash and the address `ecrecover` returns. It had no tests at all.
final class EvmSignerTests: XCTestCase {

    private func data(_ hex: String) -> Data {
        var out = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    private func hex(_ d: Data) -> String {
        d.map { String(format: "%02x", $0) }.joined()
    }

    /// chainId 1, nonce 42, 1 gwei tip, 50 gwei cap, 21000 gas, 1 ETH to
    /// 0xaaaa…aa, no calldata, empty access list. 48-byte payload, so a
    /// short list header (0xf0).
    private let unsignedEnvelope =
        "02f0012a843b9aca00850ba43b740082520894"
        + "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        + "880de0b6b3a764000080c0"

    /// Two leading zero bytes, so canonical RLP must drop them (30 bytes,
    /// prefix 0x9e) rather than encode 32.
    private let sigR = "0000" + String(repeating: "11", count: 30)
    /// Top byte 0x7f — a full 32 bytes with nothing to trim (prefix 0xa0).
    private let sigS = "7f" + String(repeating: "22", count: 31)

    // MARK: - The assembled transaction, byte for byte

    /// y_parity 0 is the empty RLP string `0x80`, never `0x00`. Encoding it
    /// as a zero byte is valid RLP for a different value and yields a
    /// different transaction hash, which no node will accept.
    func testAssemblesTheSignedEnvelopeWithEvenYParity() throws {
        let signed = try EvmSigner.assembleSignedTx(
            rawUnsigned: data(unsignedEnvelope), r: data(sigR), s: data(sigS), yParity: 0)
        XCTAssertEqual(
            signed,
            "0x02f871012a843b9aca00850ba43b740082520894"
                + "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                + "880de0b6b3a764000080c0"
                + "80"
                + "9e" + String(repeating: "11", count: 30)
                + "a0" + "7f" + String(repeating: "22", count: 31))
    }

    func testAssemblesTheSignedEnvelopeWithOddYParity() throws {
        let signed = try EvmSigner.assembleSignedTx(
            rawUnsigned: data(unsignedEnvelope), r: data(sigR), s: data(sigS), yParity: 1)
        XCTAssertEqual(
            signed,
            "0x02f871012a843b9aca00850ba43b740082520894"
                + "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                + "880de0b6b3a764000080c0"
                + "01"
                + "9e" + String(repeating: "11", count: 30)
                + "a0" + "7f" + String(repeating: "22", count: 31))
    }

    /// The nine items the sighash committed to must come through untouched;
    /// only the list header in front of them may change.
    func testKeepsTheUnsignedItemsByteForByte() throws {
        let signed = try EvmSigner.assembleSignedTx(
            rawUnsigned: data(unsignedEnvelope), r: data(sigR), s: data(sigS), yParity: 1)
        let items = String(unsignedEnvelope.dropFirst(4)) // strip the 0x02 type and 0xf0 header
        XCTAssertTrue(
            signed.dropFirst(2).hasPrefix("02f871" + items),
            "the nine signed items changed under the splice")
    }

    /// The unsigned payload is 48 bytes — short form. Adding y_parity, r and
    /// s pushes it to 113, which needs the long form (0xf8 + one length
    /// byte). Reusing the original header here would truncate the list.
    func testRewritesAShortListHeaderAsLongWhenTheSignatureOverflowsIt() throws {
        XCTAssertTrue(unsignedEnvelope.hasPrefix("02f0"), "fixture is not short-form")
        let signed = try EvmSigner.assembleSignedTx(
            rawUnsigned: data(unsignedEnvelope), r: data(sigR), s: data(sigS), yParity: 1)
        XCTAssertTrue(signed.hasPrefix("0x02f871"))
    }

    /// …and a payload that stays under 56 bytes must keep the short form.
    func testKeepsAShortListHeaderShortWhenItStillFits() throws {
        let signed = try EvmSigner.assembleSignedTx(
            rawUnsigned: data("02c3010203"), r: data("2a"), s: data("2b"), yParity: 1)
        XCTAssertEqual(signed, "0x02c6010203012a2b")
    }

    /// A long-form unsigned header must be read back correctly, not assumed
    /// to be one byte.
    func testReadsALongFormListHeaderOnTheWayIn() throws {
        // 60-byte payload: 0xf8 0x3c, then 60 bytes of 0x01 items.
        let payload = String(repeating: "01", count: 60)
        let signed = try EvmSigner.assembleSignedTx(
            rawUnsigned: data("02f83c" + payload), r: data("2a"), s: data("2b"), yParity: 0)
        XCTAssertEqual(signed, "0x02f83f" + payload + "80" + "2a" + "2b")
    }

    func testTrimsLeadingZerosFromRAndS() throws {
        let signed = try EvmSigner.assembleSignedTx(
            rawUnsigned: data("02c3010203"),
            r: data("00000000000000000000000000000000000000000000000000000000000000ff"),
            s: data("0000000000000000000000000000000000000000000000000000000000000001"),
            yParity: 0)
        XCTAssertEqual(signed, "0x02c7" + "010203" + "80" + "81ff" + "01")
    }

    // MARK: - Rejections

    func testRejectsAnEnvelopeThatIsNotAType2Transaction() {
        XCTAssertThrowsError(
            try EvmSigner.assembleSignedTx(
                rawUnsigned: data("01c3010203"), r: data("2a"), s: data("2b"), yParity: 0))
    }

    func testRejectsAnEmptyEnvelope() {
        XCTAssertThrowsError(
            try EvmSigner.assembleSignedTx(
                rawUnsigned: Data(), r: data("2a"), s: data("2b"), yParity: 0))
    }

    /// The byte after the type must open a list. A string header there means
    /// the envelope is not an EIP-1559 transaction at all.
    func testRejectsAnEnvelopeWhoseBodyIsNotAList() {
        XCTAssertThrowsError(
            try EvmSigner.assembleSignedTx(
                rawUnsigned: data("0283010203"), r: data("2a"), s: data("2b"), yParity: 0))
    }

    /// A header that promises more bytes than the envelope carries would
    /// otherwise slice past the end.
    func testRejectsAPayloadShorterThanItsDeclaredLength() {
        XCTAssertThrowsError(
            try EvmSigner.assembleSignedTx(
                rawUnsigned: data("02c90102"), r: data("2a"), s: data("2b"), yParity: 0))
    }

    // MARK: - RLP primitives

    /// Zero is the empty byte string, and a single byte below 0x80 is its
    /// own encoding — the two rules that make RLP integers canonical.
    func testEncodesIntegersCanonically() {
        XCTAssertEqual(hex(EvmSigner.rlpInteger(Data())), "80")
        XCTAssertEqual(hex(EvmSigner.rlpInteger(data("7f"))), "7f")
        XCTAssertEqual(hex(EvmSigner.rlpInteger(data("80"))), "8180")
        XCTAssertEqual(hex(EvmSigner.rlpInteger(data("ff"))), "81ff")
        XCTAssertEqual(hex(EvmSigner.rlpInteger(data("0102"))), "820102")
    }

    /// 55 bytes is the last short-form length; 56 is the first long-form
    /// one. Getting this boundary wrong corrupts every large field.
    func testEncodesStringsAcrossTheShortToLongBoundary() {
        let fiftyFive = String(repeating: "11", count: 55)
        XCTAssertEqual(hex(EvmSigner.rlpInteger(data(fiftyFive))), "b7" + fiftyFive)
        let fiftySix = String(repeating: "11", count: 56)
        XCTAssertEqual(hex(EvmSigner.rlpInteger(data(fiftySix))), "b838" + fiftySix)
    }

    func testEncodesListHeadersAcrossTheShortToLongBoundary() {
        XCTAssertEqual(hex(EvmSigner.encodeListHeader(0)), "c0")
        XCTAssertEqual(hex(EvmSigner.encodeListHeader(1)), "c1")
        XCTAssertEqual(hex(EvmSigner.encodeListHeader(55)), "f7")
        XCTAssertEqual(hex(EvmSigner.encodeListHeader(56)), "f838")
        XCTAssertEqual(hex(EvmSigner.encodeListHeader(255)), "f8ff")
        XCTAssertEqual(hex(EvmSigner.encodeListHeader(256)), "f90100")
        XCTAssertEqual(hex(EvmSigner.encodeListHeader(65536)), "fa010000")
    }

    // MARK: - Against a real Rust-built envelope

    /// The fixtures above are hand-built; this one crosses the FFI so the
    /// two sides cannot drift apart silently.
    func testSplicesAnEnvelopeBuiltByRust() throws {
        let params = FfiEvmTxParams(
            to: "0x" + String(repeating: "aa", count: 20),
            valueWei: "1000000000000000000",
            nonce: 42,
            gasLimit: 21000,
            maxFeePerGas: "50000000000",
            maxPriorityFeePerGas: "1000000000",
            chainId: 1,
            data: Data()
        )
        let raw = try horcruxBuildEvmTransaction(params: params).rawData
        XCTAssertEqual(raw.first, 0x02, "Rust no longer emits a type-2 envelope")

        let signed = try EvmSigner.assembleSignedTx(
            rawUnsigned: raw, r: data(sigR), s: data(sigS), yParity: 1)

        // The nine items Rust produced, unchanged, between the new header
        // and the three signature items.
        let headerLen = raw[1] >= 0xf8 ? Int(raw[1] - 0xf7) + 1 : 1
        let items = hex(raw.dropFirst(1 + headerLen))
        XCTAssertTrue(signed.contains(items), "the Rust-built items did not survive the splice")
        XCTAssertTrue(
            signed.hasSuffix("01" + "9e" + String(repeating: "11", count: 30)
                + "a0" + "7f" + String(repeating: "22", count: 31)))
    }
}
