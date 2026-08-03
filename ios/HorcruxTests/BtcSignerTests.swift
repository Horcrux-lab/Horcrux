import XCTest
@testable import Horcrux

/// `BtcSigner` is the last thing that touches a Bitcoin transaction before
/// it is broadcast: it turns the 64-byte MPC signature into DER, splices it
/// into the witness of the skeleton Rust built, and hands back the hex a
/// node will accept. Every byte here is consensus-visible, and a mistake in
/// any of them is a transaction that either never relays or spends the
/// wrong thing. It had no tests at all.
final class BtcSignerTests: XCTestCase {

    /// n / 2 — the BIP-62 low-s boundary.
    private let halfOrderHex = "7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0"

    /// A 32-byte big-endian scalar from a hex string.
    private func scalar(_ hex: String) -> Data {
        let padded = String(repeating: "0", count: 64 - hex.count) + hex
        var out = Data()
        var i = padded.startIndex
        while i < padded.endIndex {
            let j = padded.index(i, offsetBy: 2)
            out.append(UInt8(padded[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    private func signature(r: String, s: String) -> Data {
        scalar(r) + scalar(s)
    }

    private func hex(_ d: Data) -> String {
        d.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Public key compression

    /// The witness carries the compressed form; the 20-byte program in the
    /// scriptPubKey is HASH160 of *that* encoding, so the parity byte is
    /// what decides whether the script verifies.
    func testCompressesAnUncompressedKeyWithAnEvenY() {
        let x = Data(repeating: 0x11, count: 32)
        let y = Data(repeating: 0x22, count: 32) // last byte 0x22, even
        let compressed = BtcSigner.compressPubkey(Data([0x04]) + x + y)
        XCTAssertEqual(compressed.count, 33)
        XCTAssertEqual(compressed.first, 0x02)
        XCTAssertEqual(compressed.dropFirst(), x)
    }

    func testCompressesAnUncompressedKeyWithAnOddY() {
        let x = Data(repeating: 0x11, count: 32)
        let y = Data(repeating: 0x22, count: 31) + Data([0x23]) // odd
        let compressed = BtcSigner.compressPubkey(Data([0x04]) + x + y)
        XCTAssertEqual(compressed.first, 0x03)
    }

    func testLeavesAnAlreadyCompressedKeyAlone() {
        let key = Data([0x02]) + Data(repeating: 0x11, count: 32)
        XCTAssertEqual(BtcSigner.compressPubkey(key), key)
    }

    // MARK: - DER encoding

    func testEncodesASignatureAsADERSequenceOfTwoIntegers() throws {
        let der = try BtcSigner.derEncodeECDSA(signature(r: "2a", s: "01"))
        XCTAssertEqual(hex(der), "300602012a020101")
    }

    /// The outer length byte must count the bytes that follow it, or a node
    /// stops parsing in the middle of the signature.
    func testTheDeclaredLengthMatchesTheEncodedBody() throws {
        for (r, s) in [("2a", "01"), (String(repeating: "f", count: 64), "01"), ("01", halfOrderHex)] {
            let der = try BtcSigner.derEncodeECDSA(signature(r: r, s: s))
            XCTAssertEqual(Int(der[1]), der.count - 2, "length byte disagrees for r=\(r)")
        }
    }

    /// BIP-62: a signature with s > n/2 is non-standard and relay nodes drop
    /// it. Both (r, s) and (r, n − s) verify, so the fix is to always emit
    /// the smaller one. Here s = n − 1 must come out as 1.
    func testNormalizesAHighSValue() throws {
        let der = try BtcSigner.derEncodeECDSA(
            signature(r: "01", s: "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364140"))
        XCTAssertEqual(hex(der), "3006020101020101")
    }

    func testLeavesALowSValueAlone() throws {
        let der = try BtcSigner.derEncodeECDSA(signature(r: "01", s: "02"))
        XCTAssertEqual(hex(der), "3006020101020102")
    }

    /// The boundary is `s > n/2`, not `s >= n/2`. At exactly n/2 the value
    /// stands; one above it folds back down to exactly n/2. Testing the pair
    /// pins which comparison is used.
    func testKeepsSExactlyAtHalfTheCurveOrder() throws {
        let der = try BtcSigner.derEncodeECDSA(signature(r: "01", s: halfOrderHex))
        XCTAssertEqual(hex(der), "3025020101" + "0220" + halfOrderHex)
    }

    func testFoldsSOneAboveHalfTheCurveOrderBackToHalf() throws {
        let der = try BtcSigner.derEncodeECDSA(
            signature(r: "01", s: "7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a1"))
        XCTAssertEqual(hex(der), "3025020101" + "0220" + halfOrderHex)
    }

    /// DER integers are signed. A value whose top bit is set needs a leading
    /// 0x00 or it reads as negative.
    func testPadsAValueWhoseTopBitIsSet() throws {
        let der = try BtcSigner.derEncodeECDSA(
            signature(r: "8000000000000000000000000000000000000000000000000000000000000000", s: "01"))
        XCTAssertEqual(
            hex(der),
            "3026" + "0221" + "008000000000000000000000000000000000000000000000000000000000000000"
                + "020101")
    }

    /// …and must not carry any leading 0x00 it does not need.
    func testStripsLeadingZeroBytes() throws {
        let der = try BtcSigner.derEncodeECDSA(signature(r: "2a", s: "2a"))
        XCTAssertEqual(hex(der), "300602012a02012a")
    }

    /// Both halves padded is the longest a DER signature can be: 72 bytes,
    /// 73 once SIGHASH_ALL is appended. Anything longer is a bug in the
    /// encoder, and `assembleSignedTx` would emit a varint for it.
    func testTheLongestPossibleEncodingIs72Bytes() throws {
        let der = try BtcSigner.derEncodeECDSA(
            signature(
                r: "8000000000000000000000000000000000000000000000000000000000000001",
                s: "8000000000000000000000000000000000000000000000000000000000000001"))
        XCTAssertLessThanOrEqual(der.count, 72)
        // s is above n/2, so it folds; only r stays padded.
        XCTAssertEqual(der.count, 71)
    }

    func testRejectsASignatureShorterThan64Bytes() {
        XCTAssertThrowsError(try BtcSigner.derEncodeECDSA(Data(repeating: 0x01, count: 63)))
    }

    func testRejectsASignatureLongerThan64Bytes() {
        XCTAssertThrowsError(try BtcSigner.derEncodeECDSA(Data(repeating: 0x01, count: 65)))
    }

    func testRejectsAnEmptySignature() {
        XCTAssertThrowsError(try BtcSigner.derEncodeECDSA(Data()))
    }

    // MARK: - Witness splicing, against a real Rust-built skeleton

    private let pubkeyHash = Data(repeating: 0xab, count: 20)
    private let recipientSPK = Data([0x00, 0x14] + [UInt8](repeating: 0xcd, count: 20))
    private let compressedPubkey = Data([0x02]) + Data(repeating: 0x11, count: 32)

    private func skeleton(inputCount: Int) throws -> Data {
        let inputs = (0..<inputCount).map {
            BtcSpendInput(
                txid: String(format: "%02x", $0) + String(repeating: "aa", count: 31),
                vout: UInt32($0),
                value: 1_000_000)
        }
        let params = BtcTxSkeleton.params(
            inputs: inputs,
            ownPubkeyHash: pubkeyHash,
            ownAddress: "bc1qown",
            recipientAddress: "bc1qrecipient",
            recipientScriptPubkey: recipientSPK,
            sendSats: 500_000,
            changeSats: 400_000
        )
        return try horcruxBuildBtcTransaction(params: params, inputIndex: 0).rawData
    }

    /// The splice is positional: it trims exactly `inputCount` bytes from
    /// the end, before the locktime, assuming Rust wrote one "0 witness
    /// items" byte per input there. If that layout ever changes the splice
    /// silently eats real transaction bytes, so assert the layout itself.
    func testTheUnsignedSkeletonEndsInOneEmptyWitnessBytePerInput() throws {
        for count in 1...3 {
            let raw = try skeleton(inputCount: count)
            let witnessRegion = raw.dropLast(4).suffix(count)
            XCTAssertEqual(
                Array(witnessRegion), [UInt8](repeating: 0x00, count: count),
                "\(count)-input skeleton does not end in empty witnesses")
        }
    }

    func testPreservesTheLocktime() throws {
        let raw = try skeleton(inputCount: 1)
        let signed = try BtcSigner.assembleSignedTx(
            unsignedRawData: raw,
            inputCount: 1,
            signatures: [signature(r: "2a", s: "01")],
            compressedPubkey: compressedPubkey)
        XCTAssertEqual(Data(signed.suffix(4)), Data(raw.suffix(4)))
    }

    /// Everything up to the empty-witness placeholders — version, marker,
    /// flag, inputs and outputs — must survive untouched. Those bytes are
    /// what the sighash committed to.
    func testLeavesEverythingBeforeTheWitnessUntouched() throws {
        let raw = try skeleton(inputCount: 1)
        let signed = try BtcSigner.assembleSignedTx(
            unsignedRawData: raw,
            inputCount: 1,
            signatures: [signature(r: "2a", s: "01")],
            compressedPubkey: compressedPubkey)
        XCTAssertEqual(Data(signed.prefix(raw.count - 5)), Data(raw.prefix(raw.count - 5)))
    }

    /// A P2WPKH witness is exactly two items: the DER signature plus its
    /// SIGHASH byte, then the 33-byte compressed pubkey.
    func testWritesTwoWitnessItemsPerInput() throws {
        let raw = try skeleton(inputCount: 1)
        let sig = signature(r: "2a", s: "01")
        let signed = try BtcSigner.assembleSignedTx(
            unsignedRawData: raw,
            inputCount: 1,
            signatures: [sig],
            compressedPubkey: compressedPubkey)

        let witness = signed.dropFirst(raw.count - 5).dropLast(4)
        let der = try BtcSigner.derEncodeECDSA(sig)
        let expected = Data([0x02])
            + Data([UInt8(der.count + 1)]) + der + Data([0x01])
            + Data([0x21]) + compressedPubkey
        XCTAssertEqual(hex(Data(witness)), hex(expected))
    }

    func testAppendsTheSighashAllByteToEverySignature() throws {
        let raw = try skeleton(inputCount: 1)
        let signed = try BtcSigner.assembleSignedTx(
            unsignedRawData: raw,
            inputCount: 1,
            signatures: [signature(r: "2a", s: "01")],
            compressedPubkey: compressedPubkey)
        // …0x01 SIGHASH_ALL, then the pubkey item.
        let pubkeyItem = Data([0x21]) + compressedPubkey
        let sighashIndex = signed.count - 4 - pubkeyItem.count - 1
        XCTAssertEqual(signed[sighashIndex], 0x01)
    }

    func testWritesOneWitnessPerInputInOrder() throws {
        let raw = try skeleton(inputCount: 2)
        let sigs = [signature(r: "2a", s: "01"), signature(r: "2b", s: "01")]
        let signed = try BtcSigner.assembleSignedTx(
            unsignedRawData: raw,
            inputCount: 2,
            signatures: sigs,
            compressedPubkey: compressedPubkey)

        let witness = Data(signed.dropFirst(raw.count - 6).dropLast(4))
        var expected = Data()
        for sig in sigs {
            let der = try BtcSigner.derEncodeECDSA(sig)
            expected += Data([0x02])
                + Data([UInt8(der.count + 1)]) + der + Data([0x01])
                + Data([0x21]) + compressedPubkey
        }
        XCTAssertEqual(hex(witness), hex(expected))
    }

    func testRejectsASignatureCountThatDoesNotMatchTheInputs() throws {
        let raw = try skeleton(inputCount: 2)
        XCTAssertThrowsError(
            try BtcSigner.assembleSignedTx(
                unsignedRawData: raw,
                inputCount: 2,
                signatures: [signature(r: "2a", s: "01")],
                compressedPubkey: compressedPubkey))
    }

    /// An uncompressed key in a v0 witness makes the script fail: the
    /// program is HASH160 of the *compressed* encoding.
    func testRejectsAPubkeyThatIsNotCompressed() throws {
        let raw = try skeleton(inputCount: 1)
        XCTAssertThrowsError(
            try BtcSigner.assembleSignedTx(
                unsignedRawData: raw,
                inputCount: 1,
                signatures: [signature(r: "2a", s: "01")],
                compressedPubkey: Data([0x04]) + Data(repeating: 0x11, count: 64)))
    }

    func testRejectsRawDataTooShortToSplice() {
        XCTAssertThrowsError(
            try BtcSigner.assembleSignedTx(
                unsignedRawData: Data(repeating: 0x00, count: 4),
                inputCount: 1,
                signatures: [signature(r: "2a", s: "01")],
                compressedPubkey: compressedPubkey))
    }

    // MARK: - Hex

    /// Blockstream's `/tx` endpoint takes the raw transaction as lower-case
    /// hex with no prefix, so a byte below 0x10 has to keep its zero.
    func testHexEncodesEveryByteAsTwoLowercaseDigits() {
        XCTAssertEqual(BtcSigner.hexEncode(Data([0x00, 0x0a, 0xff, 0x10])), "000aff10")
        XCTAssertEqual(BtcSigner.hexEncode(Data()), "")
    }
}
