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
}
