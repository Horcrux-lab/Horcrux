import XCTest
@testable import Horcrux

/// TRON addresses are Base58Check: the last four bytes are a truncated
/// double-SHA256 over everything before them, and they exist so that a
/// mistyped address is refused instead of paid. `TronAddress` implements
/// that checksum correctly in `base58CheckDecode` — and `looksValid`, the
/// only function the send screen consults, never called it. This file
/// covers the derivation, the codec and the gap between them.
final class TronAddressTests: XCTestCase {

    /// SEC1 uncompressed public key for private key 1 — the secp256k1
    /// generator. Its Ethereum address is the widely published
    /// 0x7e5f4552091a69125d5dfcb7b8c2659029395bdf, and a TRON address is
    /// that same 20 bytes behind the 0x41 mainnet prefix.
    private let generatorPubkey =
        "04"
        + "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
        + "483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8"
    private let generatorAddress = "TMVQGm1qAQYVdetCeGRRkTWYYrLXuHK2HC"

    /// The TRC-20 USDT contract — a real address in constant use.
    private let usdtContract = "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
    private let usdtPayload = "41a614f803b6fd780986a42c78ec9c7f77e6ded13c"

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

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - The defect

    /// Advancing one character to the next in the Base58 alphabet keeps the
    /// length at 34, the leading `T`, and every character inside the
    /// alphabet — everything `looksValid` used to check. Only the checksum
    /// tells the two apart, and the address it decodes to is one nobody
    /// holds a key for.
    func testRejectsATronAddressWithASingleCharacterTypo() {
        let typo = "TMVQGn1qAQYVdetCeGRRkTWYYrLXuHK2HC"
        XCTAssertEqual(typo.count, generatorAddress.count)
        XCTAssertEqual(typo.first, "T")
        XCTAssertFalse(TronAddress.looksValid(typo))
    }

    func testRejectsAContractAddressWithASingleCharacterTypo() {
        XCTAssertFalse(TronAddress.looksValid("TR7NHrjeKQxGTCi8q8ZY4pL8otSzgjLj6t"))
    }

    /// The same address, reached through the screen the user actually types
    /// into.
    func testTheSendScreenRefusesAMistypedTronAddress() {
        XCTAssertThrowsError(
            try AddressValidator.validate("TMVQGn1qAQYVdetCeGRRkTWYYrLXuHK2HC", chain: .tron))
        XCTAssertNotNil(
            AddressValidator.errorMessage(
                for: "TR7NHrjeKQxGTCi8q8ZY4pL8otSzgjLj6t", chain: .tron))
    }

    func testAcceptsRealTronAddresses() {
        XCTAssertTrue(TronAddress.looksValid(generatorAddress))
        XCTAssertTrue(TronAddress.looksValid(usdtContract))
        XCTAssertNoThrow(try AddressValidator.validate(usdtContract, chain: .tron))
    }

    // MARK: - Shape

    func testRejectsAnAddressOfTheWrongLength() {
        XCTAssertFalse(TronAddress.looksValid(String(generatorAddress.dropLast())))
        XCTAssertFalse(TronAddress.looksValid(generatorAddress + "1"))
        XCTAssertFalse(TronAddress.looksValid(""))
    }

    /// Base58 has no 0, O, I or l, precisely so they cannot be confused
    /// with o, 1 and so on.
    func testRejectsCharactersOutsideTheBase58Alphabet() {
        XCTAssertFalse(TronAddress.looksValid("TMVQG01qAQYVdetCeGRRkTWYYrLXuHK2HC"))
        XCTAssertFalse(TronAddress.looksValid("TMVQGO1qAQYVdetCeGRRkTWYYrLXuHK2HC"))
        XCTAssertFalse(TronAddress.looksValid("TMVQGI1qAQYVdetCeGRRkTWYYrLXuHK2HC"))
    }

    /// Mainnet addresses carry the 0x41 prefix, which is what makes them
    /// start with `T`. But `T` covers prefix bytes 0x40 through 0x43, so a
    /// well-formed Base58Check string can look exactly like a TRON address
    /// — right length, right leading letter, valid checksum — and still
    /// name no TRON account at all. Only the prefix byte separates them.
    func testRejectsAValidBase58CheckStringThatIsNotATronAddress() {
        // Each is 34 characters, starts with `T` and has a valid checksum.
        for notTron in [
            "T16JoLriwFFvZyueBXjRUsHAS2dwtDTrb7",  // 0x40 prefix
            "TZJozAg1ruapycCicgz31GxvYJ1G1qELV7",  // 0x42 prefix
            "TxeQyGyJa63ho3Loe7KMVQEiAoGCjsUGkb",  // 0x43 prefix
        ] {
            XCTAssertEqual(notTron.count, 34)
            XCTAssertNotNil(Base58Check.decode(notTron), "\(notTron) should decode")
            XCTAssertFalse(TronAddress.looksValid(notTron), "\(notTron) is not TRON mainnet")
        }

        let bitcoinStyle = Base58Check.encode(data("00") + Data(repeating: 0xab, count: 20))
        XCTAssertFalse(TronAddress.looksValid(bitcoinStyle))
    }

    // MARK: - Derivation

    func testDerivesTheAddressForAKnownPublicKey() throws {
        XCTAssertEqual(
            try TronAddress.derive(uncompressedPublicKey: data(generatorPubkey)),
            generatorAddress)
    }

    /// Derivation takes keccak256 of X‖Y, so the 0x04 tag must be dropped
    /// first; hashing the tagged form gives a different, unspendable
    /// address.
    func testTheDerivedAddressCarriesTheMainnetPrefixAndTwentyByteHash() throws {
        let derived = try TronAddress.derive(uncompressedPublicKey: data(generatorPubkey))
        let payload = try XCTUnwrap(Base58Check.decode(derived))
        XCTAssertEqual(payload.count, 21)
        XCTAssertEqual(payload.first, 0x41)
        XCTAssertEqual(hex(payload), "417e5f4552091a69125d5dfcb7b8c2659029395bdf")
    }

    func testRefusesACompressedPublicKey() {
        XCTAssertThrowsError(
            try TronAddress.derive(uncompressedPublicKey: data("02" + String(generatorPubkey.dropFirst(2).prefix(64)))))
    }

    func testRefusesAKeyWithoutTheUncompressedTag() {
        XCTAssertThrowsError(
            try TronAddress.derive(uncompressedPublicKey: data("03" + String(generatorPubkey.dropFirst(2)))))
    }

    func testRefusesAnEmptyKey() {
        XCTAssertThrowsError(try TronAddress.derive(uncompressedPublicKey: Data()))
    }

    // MARK: - Base58Check codec

    func testDecodesAKnownAddressToItsPayload() throws {
        XCTAssertEqual(hex(try XCTUnwrap(Base58Check.decode(usdtContract))), usdtPayload)
    }

    func testEncodeAndDecodeRoundTrip() throws {
        let payload = data("41") + Data(repeating: 0x5a, count: 20)
        let encoded = Base58Check.encode(payload)
        XCTAssertEqual(encoded.count, 34)
        XCTAssertEqual(Base58Check.decode(encoded).map { Data($0) }, payload)
    }

    /// Leading zero bytes are carried as leading '1' characters, and both
    /// directions have to agree on how many.
    func testPreservesLeadingZeroBytes() throws {
        for zeros in 1...3 {
            let payload = Data(repeating: 0x00, count: zeros) + Data(repeating: 0xcd, count: 20)
            let encoded = Base58Check.encode(payload)
            XCTAssertEqual(
                String(encoded.prefix(zeros)), String(repeating: "1", count: zeros),
                "\(zeros) leading zero bytes")
            XCTAssertEqual(Base58Check.decode(encoded).map { Data($0) }, payload)
        }
    }

    func testDecodeRejectsACorruptedChecksum() {
        XCTAssertNil(Base58Check.decode("TMVQGn1qAQYVdetCeGRRkTWYYrLXuHK2HC"))
    }

    func testDecodeRejectsCharactersOutsideTheAlphabet() {
        XCTAssertNil(Base58Check.decode("TMVQG01qAQYVdetCeGRRkTWYYrLXuHK2HC"))
    }

    func testDecodeRejectsAStringTooShortToHoldAChecksum() {
        XCTAssertNil(Base58Check.decode(""))
        XCTAssertNil(Base58Check.decode("1"))
        XCTAssertNil(Base58Check.decode("2"))
    }

    // MARK: - ABI uint256

    func testEncodesADecimalAmountAsAPaddedUint256() {
        XCTAssertEqual(
            decimalStringToABIUint256Hex("0"), String(repeating: "0", count: 64))
        XCTAssertEqual(
            decimalStringToABIUint256Hex("1"), String(repeating: "0", count: 63) + "1")
        XCTAssertEqual(
            decimalStringToABIUint256Hex("255"), String(repeating: "0", count: 62) + "ff")
        XCTAssertEqual(
            decimalStringToABIUint256Hex("256"), String(repeating: "0", count: 61) + "100")
    }

    /// TRC-20 amounts are integers in the token's smallest unit, so a
    /// transfer of 1 USDT (6 decimals) is 1000000 — and a whale-sized
    /// amount still has to survive the long division exactly.
    func testEncodesAmountsBeyondWhatUInt64Holds() {
        XCTAssertEqual(
            decimalStringToABIUint256Hex("1000000"),
            String(repeating: "0", count: 58) + "0f4240")
        // 2^64, one past UInt64.max.
        XCTAssertEqual(
            decimalStringToABIUint256Hex("18446744073709551616"),
            String(repeating: "0", count: 47) + "10000000000000000")
        // uint256 max.
        XCTAssertEqual(
            decimalStringToABIUint256Hex(
                "1157920892373161954235709850086879078532699846656405640394575840079131296399"
                    + "35"),
            String(repeating: "f", count: 64))
    }

    func testRejectsAnAmountThatOverflowsUint256() {
        XCTAssertNil(
            decimalStringToABIUint256Hex(
                "1157920892373161954235709850086879078532699846656405640394575840079131296399"
                    + "36"))
    }

    func testRejectsNonDecimalAmounts() {
        XCTAssertNil(decimalStringToABIUint256Hex(""))
        XCTAssertNil(decimalStringToABIUint256Hex("  "))
        XCTAssertNil(decimalStringToABIUint256Hex("1.5"))
        XCTAssertNil(decimalStringToABIUint256Hex("-1"))
        XCTAssertNil(decimalStringToABIUint256Hex("0x10"))
        XCTAssertNil(decimalStringToABIUint256Hex("1e18"))
    }

    /// `Character.isNumber` is true for fractions and other numerics that
    /// have no digit value, and `compactMap` then drops them — so "1½"
    /// must not silently become 1.
    func testRejectsNumericCharactersThatAreNotDigits() {
        XCTAssertNil(decimalStringToABIUint256Hex("½"))
        XCTAssertNil(decimalStringToABIUint256Hex("1½"))
        XCTAssertNil(decimalStringToABIUint256Hex("Ⅶ"))
    }

    func testAcceptsSurroundingWhitespace() {
        XCTAssertEqual(
            decimalStringToABIUint256Hex("  42  "), String(repeating: "0", count: 62) + "2a")
    }
}
