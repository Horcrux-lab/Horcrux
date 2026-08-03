import XCTest
@testable import Horcrux

/// `Bech32` had no tests at all, and it decides where Bitcoin goes: the
/// recipient address a user types is turned into scriptPubKey bytes here
/// and nowhere else.
///
/// Vectors are BIP-173 and BIP-350's published ones. The witness program
/// behind the mainnet/testnet P2WPKH vector is
/// `751e76e8199196d454941c45d1b3a323f1433bd6`.
final class Bech32Tests: XCTestCase {

    private let validP2WPKH = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"
    private let expectedProgram: [UInt8] = [
        0x75, 0x1e, 0x76, 0xe8, 0x19, 0x91, 0x96, 0xd4, 0x54, 0x94,
        0x1c, 0x45, 0xd1, 0xb3, 0xa3, 0x23, 0xf1, 0x43, 0x3b, 0xd6
    ]

    // MARK: - The defect

    /// One wrong character — `bc1qw508…` typed as `bc1qq508…` — has the
    /// right prefix, the right length and none but bech32 characters, so
    /// nothing downstream objects. It decodes to a *different* witness
    /// program, which is a different address, which nobody holds the key
    /// to. The checksum is the only thing in the format that catches this,
    /// and it is the reason bech32 has one.
    func testRejectsASingleCharacterTypoThatWouldOtherwiseRedirectTheFunds() {
        let typo = "bc1qq508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"

        XCTAssertNil(
            Bech32.decodeP2WPKH(typo),
            "a typo'd address must be refused, not decoded")
        XCTAssertNil(
            Bech32.p2wpkhScriptPubkey(for: typo),
            "a typo'd address must not yield a scriptPubKey to pay")
    }

    /// The stakes, stated as an assertion: the typo differs from the real
    /// address in exactly one character, matches it in length and alphabet,
    /// and the bytes it would have produced are a different destination.
    func testTheTypoDiffersFromTheRealAddressOnlyInWaysNothingElseChecks() {
        let typo = "bc1qq508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"
        let charset = Set("qpzry9x8gf2tvdw0s3jn54khce6mua7l")

        XCTAssertEqual(typo.count, validP2WPKH.count)
        XCTAssertTrue(typo.hasPrefix("bc1"))
        XCTAssertTrue(typo.dropFirst(3).allSatisfy { charset.contains($0) })
        XCTAssertEqual(zip(typo, validP2WPKH).filter { $0 != $1 }.count, 1)

        // What the unchecked decode produced, kept here so the consequence
        // is legible: a valid-looking 20-byte program that is not ours.
        XCTAssertNotEqual(
            "051e76e8199196d454941c45d1b3a323f1433bd6",
            expectedProgram.map { String(format: "%02x", $0) }.joined())
    }

    // MARK: - BIP-173 / BIP-350 conformance

    func testDecodesTheMainnetP2WPKHVector() {
        let decoded = Bech32.decodeP2WPKH(validP2WPKH)
        XCTAssertEqual(decoded?.hrp, "bc")
        XCTAssertEqual(decoded?.program, expectedProgram)
    }

    func testDecodesTheTestnetP2WPKHVector() {
        let decoded = Bech32.decodeP2WPKH("tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx")
        XCTAssertEqual(decoded?.hrp, "tb")
        XCTAssertEqual(decoded?.program, expectedProgram)
    }

    func testBuildsThe22ByteP2WPKHScriptPubkey() {
        XCTAssertEqual(
            Bech32.p2wpkhScriptPubkey(for: validP2WPKH),
            Data([0x00, 0x14] + expectedProgram))
    }

    /// BIP-173 permits an all-uppercase rendering, which is what QR codes
    /// use because alphanumeric mode is denser.
    func testUppercaseFormDecodesToTheSameProgram() {
        XCTAssertEqual(
            Bech32.decodeP2WPKH(validP2WPKH.uppercased())?.program,
            expectedProgram)
    }

    /// Mixed case is invalid: the checksum is defined over one case, so
    /// accepting a mixture means accepting something whose checksum was
    /// never really verified.
    func testRejectsMixedCase() {
        XCTAssertNil(Bech32.decodeP2WPKH("bc1QW508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"))
    }

    func testRejectsTheBIP173InvalidChecksumVector() {
        XCTAssertNil(Bech32.decodeP2WPKH("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t5"))
    }

    /// BIP-350 splits the constant by witness version: v0 must use bech32,
    /// v1 and up must use bech32m. This is the same program and the same
    /// characters up to the checksum, so only the constant separates them.
    func testRejectsAVersion0ProgramEncodedWithBech32m() {
        XCTAssertNil(Bech32.decodeP2WPKH("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kemeawh"))
    }

    /// 98 characters, and its checksum is correct — only the length rule
    /// rejects it.
    func testRejectsAnAddressLongerThanTheBIP173Limit() {
        let long = "bc1qqqqsyqcyq5rqwzqfpg9scrgwpugpzysnzs23v9ccrydpk8qarc0jqgfzyvjz2f389"
            + "q5j52ev95hz7vp3xgengdfkxhatqv"
        XCTAssertEqual(long.count, 98)
        XCTAssertNil(Bech32.decode(long))
    }

    func testRejectsAnEmptyHumanReadablePart() {
        XCTAssertNil(Bech32.decode("1qzzfhee"))
    }

    /// `b`, `i`, `o` and `1` are excluded from the alphabet precisely
    /// because they are the characters people confuse.
    func testRejectsCharactersOutsideTheBech32Alphabet() {
        XCTAssertNil(Bech32.decode("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3b4"))
    }

    func testRejectsAStringWithNoSeparator() {
        XCTAssertNil(Bech32.decode("bcqw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"))
    }

    func testRejectsADataPartTooShortToHoldAChecksum() {
        XCTAssertNil(Bech32.decode("bc1qzzf"))
    }

    func testReportsWhichConstantItVerified() {
        XCTAssertEqual(Bech32.decode(validP2WPKH)?.encoding, .bech32)
        XCTAssertEqual(
            Bech32.decode("bc1pw508d6qejxtdg4y5r3zarvary0c5xw7kj9wkru")?.encoding,
            .bech32m)
    }

    // MARK: - P2WPKH is narrower than "valid bech32"

    /// Taproot is a valid address that this signer cannot pay: the witness
    /// program is 32 bytes and the script is `OP_1 PUSH32`, not
    /// `OP_0 PUSH20`. Decoding it as P2WPKH would build a script paying
    /// the wrong thing.
    func testRefusesATaprootAddressEvenThoughItIsValidBech32m() {
        let taproot = "bc1pw508d6qejxtdg4y5r3zarvary0c5xw7kj9wkru"
        XCTAssertNotNil(Bech32.decode(taproot), "the address itself is well-formed")
        XCTAssertNil(Bech32.decodeP2WPKH(taproot))
        XCTAssertNil(Bech32.p2wpkhScriptPubkey(for: taproot))
    }

    /// Version 0 but a 32-byte program, i.e. P2WSH. Same version byte as
    /// P2WPKH, so only the program length distinguishes them.
    func testRefusesAP2WSHAddress() {
        XCTAssertNil(Bech32.decodeP2WPKH(
            "bc1qrp33g0q5c5txsp9arysrx4k6zdkfs4nce4xj0gdcccefvpysxf3qccfmv3"))
    }

    // MARK: - BIP-350 version/constant pairing

    /// The mirror of the v0-with-bech32m case: a v1 program carrying a
    /// bech32 checksum. Verifying "some" constant is not enough — the
    /// version decides which one.
    func testRejectsAVersion1ProgramEncodedWithBech32() {
        XCTAssertNil(Bech32.decodeSegwit("bc1pw508d6qejxtdg4y5r3zarvary0c5xw7k8e76x7"))
    }

    func testRejectsAWitnessVersionAbove16() {
        XCTAssertNil(Bech32.decodeSegwit("bc13w508d6qejxtdg4y5r3zarvary0c5xw7kxflzvg"))
    }

    /// A witness program is 2…40 bytes, and v0 is only ever 20 or 32.
    func testRejectsProgramLengthsOutsideTheSegwitRange() {
        XCTAssertNil(Bech32.decodeSegwit("bc1q4g2vqve2"), "1-byte program")
        XCTAssertNil(
            Bech32.decodeSegwit(
                "bc1pqqqsyqcyq5rqwzqfpg9scrgwpugpzysnzs23v9ccrydpk8qarc0jqgfzyvjz2f389q02am2l"),
            "41-byte program")
    }

    /// BIP-173 invalid vector. 16 bytes sits inside the generic 2…40 witness
    /// program range, so only the version-0 rule rejects it. Without that rule
    /// the address decodes to a program no consensus rule can ever spend.
    func testRejectsAVersion0ProgramOfALengthOtherThan20Or32() {
        XCTAssertNil(Bech32.decodeSegwit("BC1QR508D6QEJXTDG4Y5R3ZARVARYV98GJ9P"))
    }

    func testAcceptsBothVersion0ProgramLengths() {
        XCTAssertEqual(Bech32.decodeSegwit(validP2WPKH)?.program.count, 20)
        XCTAssertEqual(
            Bech32.decodeSegwit(
                "bc1qrp33g0q5c5txsp9arysrx4k6zdkfs4nce4xj0gdcccefvpysxf3qccfmv3")?.program.count,
            32)
    }

    func testReportsTheWitnessVersion() {
        XCTAssertEqual(Bech32.decodeSegwit(validP2WPKH)?.version, 0)
        XCTAssertEqual(
            Bech32.decodeSegwit("bc1pw508d6qejxtdg4y5r3zarvary0c5xw7kj9wkru")?.version, 1)
    }
}
