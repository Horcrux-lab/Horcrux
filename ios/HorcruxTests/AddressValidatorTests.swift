import XCTest
@testable import Horcrux

/// Tests for AddressValidator — ETH, BTC, SOL address format validation.
final class AddressValidatorTests: XCTestCase {

    // MARK: - Ethereum

    func testValidEthAddress() {
        XCTAssertNil(AddressValidator.errorMessage(for: "0x742d35Cc6634C0532925a3b844Bc9e7595f2bD18", chain: .ethereum))
    }

    func testValidEthAddressAllLowercase() {
        XCTAssertNil(AddressValidator.errorMessage(for: "0x742d35cc6634c0532925a3b844bc9e7595f2bd18", chain: .ethereum))
    }

    func testInvalidEthAddressMissingPrefix() {
        XCTAssertNotNil(AddressValidator.errorMessage(for: "742d35Cc6634C0532925a3b844Bc9e7595f2bD18", chain: .ethereum))
    }

    func testInvalidEthAddressTooShort() {
        XCTAssertNotNil(AddressValidator.errorMessage(for: "0x742d35Cc6634C0532925a3b8", chain: .ethereum))
    }

    func testInvalidEthAddressTooLong() {
        XCTAssertNotNil(AddressValidator.errorMessage(for: "0x742d35Cc6634C0532925a3b844Bc9e7595f2bD18aa", chain: .ethereum))
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
        XCTAssertNotNil(AddressValidator.errorMessage(for: "0x742d35Cc6634C0532925a3b844Bc9e7595f2bD18", chain: .bitcoin))
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
}
