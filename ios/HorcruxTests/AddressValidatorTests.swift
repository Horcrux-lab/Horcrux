import XCTest
@testable import Horcrux

/// Tests for AddressValidator — ETH, BTC, SOL address format validation.
final class AddressValidatorTests: XCTestCase {

    // MARK: - Ethereum

    func testValidEthAddress() {
        XCTAssertNil(AddressValidator.errorMessage(for: "0x742D35CC6634C0532925a3B844Bc9E7595F2bD18", chain: .ethereum))
    }

    func testValidEthAddressAllLowercase() {
        XCTAssertNil(AddressValidator.errorMessage(for: "0x742d35cc6634c0532925a3b844bc9e7595f2bd18", chain: .ethereum))
    }

    func testInvalidEthAddressMissingPrefix() {
        XCTAssertNotNil(AddressValidator.errorMessage(for: "742D35CC6634C0532925a3B844Bc9E7595F2bD18", chain: .ethereum))
    }

    func testInvalidEthAddressTooShort() {
        XCTAssertNotNil(AddressValidator.errorMessage(for: "0x742d35Cc6634C0532925a3b8", chain: .ethereum))
    }

    func testInvalidEthAddressTooLong() {
        XCTAssertNotNil(AddressValidator.errorMessage(for: "0x742D35CC6634C0532925a3B844Bc9E7595F2bD18aa", chain: .ethereum))
    }

    func testInvalidEthAddressNonHex() {
        XCTAssertNotNil(AddressValidator.errorMessage(for: "0xZZZd35Cc6634C0532925a3b844Bc9e7595f2bD18", chain: .ethereum))
    }

    func testEmptyEthAddress() {
        XCTAssertNotNil(AddressValidator.errorMessage(for: "", chain: .ethereum))
    }

    // MARK: - Bitcoin

    func testValidBtcBech32Address() {
        XCTAssertNil(AddressValidator.errorMessage(for: "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4", chain: .bitcoin))
    }

    func testValidBtcBech32mTaprootAddress() {
        // P2TR address (Bech32m)
        XCTAssertNil(AddressValidator.errorMessage(for: "bc1p5d7rjq7g6rdk2yhzks9smlaqtedr4dekq08ge8ztwac72sfr9rusxg3297", chain: .bitcoin))
    }

    func testValidBtcLegacyP2PKH() {
        XCTAssertNil(AddressValidator.errorMessage(for: "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2", chain: .bitcoin))
    }

    func testValidBtcP2SH() {
        XCTAssertNil(AddressValidator.errorMessage(for: "3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy", chain: .bitcoin))
    }

    func testValidBtcTestnetAddress() {
        XCTAssertNil(AddressValidator.errorMessage(for: "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx", chain: .bitcoin))
    }

    func testInvalidBtcAddress() {
        XCTAssertNotNil(AddressValidator.errorMessage(for: "invalid_btc_address!", chain: .bitcoin))
    }

    func testEmptyBtcAddress() {
        XCTAssertNotNil(AddressValidator.errorMessage(for: "", chain: .bitcoin))
    }

    // MARK: - Solana

    func testValidSolAddress() {
        XCTAssertNil(AddressValidator.errorMessage(for: "9noXzpXnkyEcKF3DkXFTEJLMu1bRNqsm5GCrNPB3Jkda", chain: .solana))
    }

    func testValidSolShortAddress() {
        // Minimum 32 chars
        XCTAssertNil(AddressValidator.errorMessage(for: "11111111111111111111111111111111", chain: .solana))
    }

    func testInvalidSolAddressTooShort() {
        XCTAssertNotNil(AddressValidator.errorMessage(for: "abc123", chain: .solana))
    }

    func testInvalidSolAddressInvalidChars() {
        // '0', 'O', 'I', 'l' are not in base58
        XCTAssertNotNil(AddressValidator.errorMessage(for: "0OIl111111111111111111111111111111", chain: .solana))
    }

    func testEmptySolAddress() {
        XCTAssertNotNil(AddressValidator.errorMessage(for: "", chain: .solana))
    }

    // MARK: - Cross-chain

    func testEthAddressInvalidForBtc() {
        XCTAssertNotNil(AddressValidator.errorMessage(for: "0x742D35CC6634C0532925a3B844Bc9E7595F2bD18", chain: .bitcoin))
    }

    func testBtcAddressInvalidForEth() {
        XCTAssertNotNil(AddressValidator.errorMessage(for: "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4", chain: .ethereum))
    }

    // MARK: - Additional Security Edge Cases

    func testETHAddressRejectsEmpty() {
        XCTAssertNotNil(AddressValidator.errorMessage(for: "", chain: .ethereum),
                        "Empty string should fail ETH validation")
        XCTAssertThrowsError(try AddressValidator.validate("", chain: .ethereum)) { error in
            if let ve = error as? AddressValidator.ValidationError, case .empty = ve {
                // Expected
            } else {
                XCTFail("Expected ValidationError.empty, got \(error)")
            }
        }
    }

    func testETHAddressRejectsShortHex() {
        XCTAssertNotNil(AddressValidator.errorMessage(for: "0x123", chain: .ethereum),
                        "Short hex should fail ETH validation")
    }

    func testBTCAddressAcceptsBech32() {
        // Standard bech32 (P2WPKH) address
        XCTAssertNil(AddressValidator.errorMessage(for: "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4", chain: .bitcoin),
                     "Valid bech32 bc1q address should pass")
        // Bech32m (P2TR / Taproot) address
        XCTAssertNil(AddressValidator.errorMessage(for: "bc1p5d7rjq7g6rdk2yhzks9smlaqtedr4dekq08ge8ztwac72sfr9rusxg3297", chain: .bitcoin),
                     "Valid bech32m bc1p address should pass")
    }

    func testSOLAddressRejectsInvalidBase58() {
        // Characters '0', 'O', 'I', 'l' are not valid base58
        XCTAssertNotNil(AddressValidator.errorMessage(for: "0OIl111111111111111111111111111111", chain: .solana),
                        "Invalid base58 chars should fail SOL validation")
        // A single invalid character in an otherwise valid-length address
        XCTAssertNotNil(AddressValidator.errorMessage(for: "0noXzpXnkyEcKF3DkXFTEJLMu1bRNqsm5GCrNPB3Jkda", chain: .solana),
                        "Address starting with 0 should fail SOL base58 validation")
    }

    func testETHAddressAcceptsChecksummed() {
        // EIP-55 mixed-case checksummed address
        XCTAssertNil(AddressValidator.errorMessage(for: "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed", chain: .ethereum),
                     "EIP-55 checksummed address should pass")
        // All-lowercase is also valid per the current validator
        XCTAssertNil(AddressValidator.errorMessage(for: "0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed", chain: .ethereum),
                     "All-lowercase ETH address should pass")
    }

    func testETHAddressRejectsNonHexAfterPrefix() {
        XCTAssertNotNil(AddressValidator.errorMessage(for: "0xGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG", chain: .ethereum),
                        "Non-hex characters after 0x should fail")
    }

    func testBTCAddressRejectsEmpty() {
        XCTAssertNotNil(AddressValidator.errorMessage(for: "", chain: .bitcoin),
                        "Empty string should fail BTC validation")
    }

    func testSOLAddressRejectsEmpty() {
        XCTAssertNotNil(AddressValidator.errorMessage(for: "", chain: .solana),
                        "Empty string should fail SOL validation")
    }

    // MARK: - Checksums

    /// The validator used to check the prefix, the length and the
    /// alphabet, and stop. All three are satisfied by a mistyped address,
    /// which is why bech32 carries a checksum — and why `Bech32.decode`,
    /// which deferred to this function, could hand the signer a witness
    /// program for an address nobody holds the key to.
    func testRejectsABtcBech32AddressWithASingleCharacterTypo() {
        XCTAssertNotNil(AddressValidator.errorMessage(
            for: "bc1qq508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4", chain: .bitcoin))
    }

    /// BIP-173's own invalid-checksum vector: identical to the valid one
    /// but for the final character.
    func testRejectsTheBIP173InvalidChecksumVector() {
        XCTAssertNotNil(AddressValidator.errorMessage(
            for: "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t5", chain: .bitcoin))
    }

    /// BIP-350 pairs the constant with the witness version. A v0 program
    /// carrying a bech32m checksum is an address no other wallet will
    /// agree with us about.
    func testRejectsAVersion0BtcAddressEncodedWithBech32m() {
        XCTAssertNotNil(AddressValidator.errorMessage(
            for: "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kemeawh", chain: .bitcoin))
    }

    func testAcceptsAValidLitecoinBech32Address() {
        XCTAssertNil(AddressValidator.errorMessage(
            for: "ltc1qw508d6qejxtdg4y5r3zarvary0c5xw7kgmn4n9", chain: .litecoin))
    }

    func testRejectsALitecoinBech32AddressWithASingleCharacterTypo() {
        XCTAssertNotNil(AddressValidator.errorMessage(
            for: "ltc1qq508d6qejxtdg4y5r3zarvary0c5xw7kgmn4n9", chain: .litecoin))
    }

    func testAcceptsAValidLitecoinTestnetBech32Address() {
        XCTAssertNil(AddressValidator.errorMessage(
            for: "tltc1qw508d6qejxtdg4y5r3zarvary0c5xw7klfsuq0", chain: .litecoin))
    }

    /// Legacy addresses carry a truncated double-SHA256 for the same
    /// reason, and `Base58Check.decode` has always verified it — the
    /// validator simply never called it.
    func testRejectsALegacyBtcAddressWithASingleCharacterTypo() {
        XCTAssertNotNil(AddressValidator.errorMessage(
            for: "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN3", chain: .bitcoin))
    }

    func testRejectsAP2SHBtcAddressWithASingleCharacterTypo() {
        XCTAssertNotNil(AddressValidator.errorMessage(
            for: "3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLx", chain: .bitcoin))
    }

    func testAcceptsValidLegacyLitecoinAddresses() {
        XCTAssertNil(AddressValidator.errorMessage(
            for: "LM2WMpR1Rp6j3Sa59cMXMs1SPzj9eXpGc1", chain: .litecoin))
        XCTAssertNil(AddressValidator.errorMessage(
            for: "MQMcJhpWHYVeQArcZR3sBgyPZxxRtnH441", chain: .litecoin))
    }

    func testRejectsALegacyLitecoinAddressWithASingleCharacterTypo() {
        XCTAssertNotNil(AddressValidator.errorMessage(
            for: "LM2WMpR1Rp6j3Sa59cMXMs1SPzj9eXpGc2", chain: .litecoin))
    }

    // MARK: - Ethereum — EIP-55

    /// EIP-55 puts a checksum in the *case* of an address's letters: hash
    /// the lowercase address, and each letter is uppercase exactly when
    /// its nibble of the hash is >= 8. A mistyped address keeps the 0x
    /// prefix, the 42-character length and the hex alphabet, so only the
    /// checksum catches it — and every explorer and wallet hands out the
    /// checksummed form.
    func testRejectsAMistypedChecksummedEthereumAddress() {
        // Last character d -> e. Still 42 characters, still hex.
        XCTAssertNotNil(AddressValidator.errorMessage(
            for: "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAee", chain: .ethereum))
    }

    /// Corrupting the case alone leaves the same 20 bytes but proves the
    /// checksum is read, not just the characters.
    func testRejectsAnEthereumAddressWithACorruptedChecksumCase() {
        XCTAssertNotNil(AddressValidator.errorMessage(
            for: "0x5aaeb6053F3E94C9b9A09f33669435E7Ef1BeAed", chain: .ethereum))
        // An otherwise all-uppercase address with one lowercase letter.
        XCTAssertNotNil(AddressValidator.errorMessage(
            for: "0x52908400098527886E0F7030069857D2E4169Ee7", chain: .ethereum))
    }

    /// The four mixed-case vectors published with EIP-55.
    func testAcceptsTheEIP55ReferenceVectors() {
        for address in [
            "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed",
            "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359",
            "0xdbF03B407c01E7cD3CBea99509d93f8DDDC8C6FB",
            "0xD1220A0cf47c7B9Be7A2E6BA89F429762e7b9aDb",
        ] {
            XCTAssertNil(AddressValidator.errorMessage(for: address, chain: .ethereum), address)
        }
    }

    /// An address written entirely in one case carries no checksum at all,
    /// which EIP-55 explicitly permits. Rejecting those would refuse
    /// addresses that predate the standard.
    func testAcceptsSingleCaseEthereumAddresses() {
        for address in [
            "0x52908400098527886E0F7030069857D2E4169EE7",
            "0x8617E340B3D01FA5F11F306F4090FD50E238070D",
            "0xde709f2102306220921060314715629080e2fb77",
            "0x27b1fdb04752bbc536007a920d24acb045561c26",
            "0x5AAEB6053F3E94C9B9A09F33669435E7EF1BEAED",
            "0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed",
        ] {
            XCTAssertNil(AddressValidator.errorMessage(for: address, chain: .ethereum), address)
        }
    }

    /// The checksum applies to every EVM chain, not just Ethereum.
    func testTheChecksumIsCheckedOnEveryEvmChain() {
        for chain in Chain.allCases where chain.isEVM {
            XCTAssertNotNil(
                AddressValidator.errorMessage(
                    for: "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAee", chain: chain),
                "\(chain) should reject a bad EIP-55 checksum")
            XCTAssertNil(
                AddressValidator.errorMessage(
                    for: "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed", chain: chain),
                "\(chain) should accept a good EIP-55 checksum")
        }
    }

    /// `Character.isHexDigit` is also true for the full-width compatibility
    /// forms, which no hex decoder downstream reads. A full-width *digit*
    /// slips past the case test too — it has no case — so an otherwise
    /// lowercase address containing one would carry no checksum to fail.
    func testRejectsFullWidthHexCharacters() {
        XCTAssertNotNil(AddressValidator.errorMessage(
            for: "0xde709f2102306220921060314715629080e2fb7\u{FF17}", chain: .ethereum))
        XCTAssertNotNil(AddressValidator.errorMessage(
            for: "0xde709f210230622092106031471562908\u{FF10}e2fb77", chain: .ethereum))
    }
}
