import XCTest
@testable import Horcrux

/// Tests for `HorcruxBridge.deriveAddress(chain:publicKey:)`, the single point
/// that decides which derivation each of the 14 supported chains gets.
///
/// This is the last step before a receive address is shown to the user. A
/// wrong branch here does not fail loudly — it produces a syntactically valid
/// address for a key the wallet cannot sign with, and the funds sent to it are
/// gone. The EVM family in particular is dispatched by `chain.isEVM` rather
/// than by an exhaustive switch, so a new chain added to the enum without the
/// flag would silently fall through to the `default:` throw.
@MainActor
final class HorcruxBridgeAddressTests: XCTestCase {

    /// SEC1 uncompressed public key for private key 1 (the secp256k1
    /// generator). Its Ethereum address is the widely published
    /// 0x7e5f4552091a69125d5dfcb7b8c2659029395bdf.
    private let uncompressed = Data(hex:
        "04"
        + "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
        + "483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8")

    /// The same key in compressed form, used for the Bitcoin-family chains.
    private let compressed = Data(hex:
        "02" + "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")

    /// A 32-byte Ed25519 public key for Solana.
    private let ed25519 = Data(repeating: 0x01, count: 32)

    /// The Rust derivation emits lowercase hex, so this is the un-checksummed form.
    private let evmAddress = "0x7e5f4552091a69125d5dfcb7b8c2659029395bdf"
    private let btcAddress = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"
    private let ltcAddress = "ltc1qw508d6qejxtdg4y5r3zarvary0c5xw7kgmn4n9"
    private let tronAddress = "TMVQGm1qAQYVdetCeGRRkTWYYrLXuHK2HC"
    private let solanaAddress = "4vJ9JU1bJJE96FWSJKvHsmmFADCg4gpZQff4P3bkLKi"

    private var bridge: HorcruxBridge!

    override func setUp() {
        super.setUp()
        bridge = HorcruxBridge()
    }

    override func tearDown() {
        bridge = nil
        super.tearDown()
    }

    private func derive(_ chain: Chain, _ key: Data? = nil) throws -> String {
        try bridge.deriveAddress(chain: chain, publicKey: key ?? defaultKey(for: chain))
    }

    private func defaultKey(for chain: Chain) -> Data {
        if chain.isEVM || chain == .tron { return uncompressed }
        if chain == .solana { return ed25519 }
        return compressed
    }

    // MARK: - Per-chain vectors

    func testEthereumDerivesTheGeneratorAddress() throws {
        XCTAssertEqual(try derive(.ethereum), evmAddress)
    }

    func testBitcoinDerivesTheBip173WitnessAddress() throws {
        XCTAssertEqual(try derive(.bitcoin), btcAddress)
    }

    func testLitecoinDerivesTheSameWitnessProgramUnderItsOwnHrp() throws {
        XCTAssertEqual(try derive(.litecoin), ltcAddress)
    }

    func testSolanaDerivesTheBase58EncodedPublicKey() throws {
        XCTAssertEqual(try derive(.solana), solanaAddress)
    }

    func testTronDerivesTheGeneratorAddress() throws {
        XCTAssertEqual(try derive(.tron), tronAddress)
    }

    // MARK: - EVM family

    /// The whole EVM family is one derivation. If any chain stopped taking the
    /// `isEVM` branch it would either throw or, worse, get another chain's
    /// format.
    func testEveryEVMChainDerivesTheIdenticalAddress() throws {
        let evmChains = Chain.allCases.filter(\.isEVM)
        XCTAssertEqual(evmChains.count, 10, "expected 10 EVM chains")
        for chain in evmChains {
            XCTAssertEqual(try derive(chain), evmAddress, "\(chain) diverged from the EVM derivation")
        }
    }

    /// The derivation emits `hex::encode` output, which is all lowercase — an
    /// EVM address with no EIP-55 checksum. That is legal (EIP-55 permits
    /// single-case addresses) and `AddressValidator` accepts it, but it means a
    /// receive address shown to the user carries no typo protection.
    func testEVMAddressIsLowercaseAndCarriesNoChecksum() throws {
        let address = try derive(.ethereum)
        XCTAssertEqual(address, address.lowercased())
        XCTAssertNoThrow(try AddressValidator.validate(address, chain: .ethereum))
    }

    // MARK: - Cross-chain distinctness

    /// Bitcoin and Litecoin share a witness program and differ only in the
    /// human-readable part. Deriving one under the other's hrp would produce
    /// an address that looks right and is unspendable.
    func testBitcoinAndLitecoinDifferOnlyInTheirPrefix() throws {
        let btc = try derive(.bitcoin)
        let ltc = try derive(.litecoin)
        XCTAssertTrue(btc.hasPrefix("bc1q"))
        XCTAssertTrue(ltc.hasPrefix("ltc1q"))
        XCTAssertNotEqual(btc, ltc)
        // Same 20-byte witness program, so the data part matches up to the
        // checksum, which covers the hrp.
        XCTAssertEqual(btc.dropFirst("bc1q".count).prefix(32),
                       ltc.dropFirst("ltc1q".count).prefix(32))
    }

    func testNonEVMChainsAllProduceDistinctAddresses() throws {
        let addresses = try [Chain.bitcoin, .litecoin, .solana, .tron].map { try derive($0) }
        XCTAssertEqual(Set(addresses).count, addresses.count, "two chains produced the same address")
    }

    // MARK: - Every chain is wired up

    /// A `Chain` case with no derivation falls into `default:` and throws. That
    /// would ship a chain the user can select but never receive on.
    func testEveryChainHasADerivation() {
        for chain in Chain.allCases {
            XCTAssertNoThrow(try derive(chain), "\(chain) has no address derivation")
        }
    }

    func testEveryDerivedAddressPassesItsOwnValidator() throws {
        for chain in Chain.allCases {
            let address = try derive(chain)
            XCTAssertNoThrow(try AddressValidator.validate(address, chain: chain),
                             "\(chain) derived \(address), which its own validator rejects")
        }
    }

    /// Derivation must not be chain-agnostic: an address derived for one chain
    /// should not validate against an unrelated chain's rules.
    func testBitcoinAddressIsRejectedByTheEthereumValidator() throws {
        XCTAssertThrowsError(try AddressValidator.validate(try derive(.bitcoin), chain: .ethereum))
    }

    func testEthereumAddressIsRejectedByTheBitcoinValidator() throws {
        XCTAssertThrowsError(try AddressValidator.validate(try derive(.ethereum), chain: .bitcoin))
    }

    // MARK: - Determinism

    func testDerivationIsDeterministic() throws {
        for chain in Chain.allCases {
            let first = try derive(chain)
            XCTAssertEqual(try derive(chain), first, "\(chain) derivation is not deterministic")
        }
    }

    func testDistinctKeysProduceDistinctAddresses() throws {
        let other = Data(hex:
            "04"
            + "c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5"
            + "1ae168fea63dc339a3c58419466ceaeef7f632653266d0e1236431a950cfe52a")
        XCTAssertNotEqual(try derive(.ethereum, other), try derive(.ethereum))
        XCTAssertNotEqual(try derive(.tron, other), try derive(.tron))
    }

    // MARK: - Rejection

    func testEmptyPublicKeyIsRejectedOnEveryChain() {
        for chain in Chain.allCases {
            XCTAssertThrowsError(try derive(chain, Data()), "\(chain) accepted an empty public key")
        }
    }

    func testCompressedKeyIsRejectedByTheEVMDerivation() {
        XCTAssertThrowsError(try derive(.ethereum, compressed))
    }

    /// The Bitcoin derivation accepts the uncompressed form and compresses it
    /// itself, so both spellings of the same key must land on one address.
    /// Anything else would mean the receive address depends on which form the
    /// caller happened to hold.
    func testBitcoinAcceptsBothKeyFormsAndAgreesOnTheAddress() throws {
        XCTAssertEqual(try derive(.bitcoin, uncompressed), try derive(.bitcoin, compressed))
        XCTAssertEqual(try derive(.litecoin, uncompressed), try derive(.litecoin, compressed))
    }

    /// The EVM derivation also takes raw 64-byte X||Y coordinates. A 65-byte
    /// key that loses its last byte is therefore still a well-formed input and
    /// derives a *different* address rather than failing — worth pinning down
    /// so the behaviour is a decision rather than a surprise.
    func testTruncatedUncompressedKeyDerivesADifferentEVMAddress() throws {
        let truncated = try derive(.ethereum, uncompressed.dropLast())
        XCTAssertEqual(truncated.count, 42)
        XCTAssertNotEqual(truncated, evmAddress)
    }

    func testBitcoinRejectsAKeyOfNeitherLength() {
        XCTAssertThrowsError(try derive(.bitcoin, compressed.dropLast()))
        XCTAssertThrowsError(try derive(.bitcoin, uncompressed.dropLast()))
    }

    func testEVMRejectsAKeyOfNeitherLength() {
        XCTAssertThrowsError(try derive(.ethereum, uncompressed.dropLast(2)))
        XCTAssertThrowsError(try derive(.ethereum, compressed))
    }

    func testSolanaRejectsAKeyThatIsNot32Bytes() {
        XCTAssertThrowsError(try derive(.solana, ed25519.dropLast()))
        XCTAssertThrowsError(try derive(.solana, ed25519 + Data([0x00])))
    }
}

private extension Data {
    init(hex: String) {
        var out = Data()
        var i = hex.startIndex
        while i < hex.endIndex, let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) {
            out.append(UInt8(hex[i..<j], radix: 16) ?? 0)
            i = j
        }
        self = out
    }
}
