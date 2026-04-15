import XCTest
@testable import Horcrux

/// Tests for Token, TokenBalance, and TokenList.
final class TokenModelsTests: XCTestCase {

    // MARK: - TokenList.ethereum

    func test_ethereumTokens_containsExpectedSymbols() {
        let symbols = TokenList.ethereum.map(\.symbol)
        XCTAssertTrue(symbols.contains("USDT"))
        XCTAssertTrue(symbols.contains("USDC"))
        XCTAssertTrue(symbols.contains("DAI"))
        XCTAssertTrue(symbols.contains("WBTC"))
        XCTAssertTrue(symbols.contains("LINK"))
    }

    func test_ethereumTokens_count() {
        XCTAssertEqual(TokenList.ethereum.count, 5)
    }

    func test_ethereumTokens_allOnEthereumChain() {
        for token in TokenList.ethereum {
            XCTAssertEqual(token.chain, .ethereum, "\(token.symbol) should be on Ethereum")
        }
    }

    // MARK: - TokenList.solana

    func test_solanaTokens_containsExpectedSymbols() {
        let symbols = TokenList.solana.map(\.symbol)
        XCTAssertTrue(symbols.contains("USDT"))
        XCTAssertTrue(symbols.contains("USDC"))
    }

    func test_solanaTokens_count() {
        XCTAssertEqual(TokenList.solana.count, 2)
    }

    func test_solanaTokens_allOnSolanaChain() {
        for token in TokenList.solana {
            XCTAssertEqual(token.chain, .solana, "\(token.symbol) should be on Solana")
        }
    }

    // MARK: - TokenList.tokens(for:)

    func test_tokensForEthereum_matchesEthereumList() {
        XCTAssertEqual(TokenList.tokens(for: .ethereum), TokenList.ethereum)
    }

    func test_tokensForSolana_matchesSolanaList() {
        XCTAssertEqual(TokenList.tokens(for: .solana), TokenList.solana)
    }

    func test_tokensForBitcoin_isEmpty() {
        XCTAssertTrue(TokenList.tokens(for: .bitcoin).isEmpty)
    }

    // MARK: - Token struct init & fields

    func test_tokenInit_fieldsAreCorrect() {
        let token = Token(
            id: "0xABCDEF",
            chain: .ethereum,
            symbol: "TST",
            name: "Test Token",
            decimals: 18,
            iconURL: "https://example.com/icon.png"
        )
        XCTAssertEqual(token.id, "0xABCDEF")
        XCTAssertEqual(token.chain, .ethereum)
        XCTAssertEqual(token.symbol, "TST")
        XCTAssertEqual(token.name, "Test Token")
        XCTAssertEqual(token.decimals, 18)
        XCTAssertEqual(token.iconURL, "https://example.com/icon.png")
    }

    func test_tokenInit_iconURLCanBeNil() {
        let token = Token(
            id: "0x123", chain: .ethereum, symbol: "X",
            name: "X Token", decimals: 6, iconURL: nil
        )
        XCTAssertNil(token.iconURL)
    }

    // MARK: - Token Codable

    func test_tokenCodable_roundtrip() throws {
        let token = Token(
            id: "0x999", chain: .solana, symbol: "SOL",
            name: "Solana Token", decimals: 9, iconURL: nil
        )
        let data = try JSONEncoder().encode(token)
        let decoded = try JSONDecoder().decode(Token.self, from: data)
        XCTAssertEqual(decoded, token)
    }

    // MARK: - Token Hashable

    func test_tokenHashable_equalTokensSameHash() {
        let a = Token(id: "0x1", chain: .ethereum, symbol: "A", name: "A", decimals: 6, iconURL: nil)
        let b = Token(id: "0x1", chain: .ethereum, symbol: "A", name: "A", decimals: 6, iconURL: nil)
        XCTAssertEqual(a.hashValue, b.hashValue)

        let set: Set<Token> = [a, b]
        XCTAssertEqual(set.count, 1)
    }

    // MARK: - Token.formatBalance

    func test_formatBalance_zeroReturnsZeroSymbol() {
        let token = Token(id: "0x1", chain: .ethereum, symbol: "USDT", name: "Tether", decimals: 6, iconURL: nil)
        XCTAssertEqual(token.formatBalance("0"), "0 USDT")
    }

    func test_formatBalance_validAmount() {
        let token = Token(id: "0x1", chain: .ethereum, symbol: "USDT", name: "Tether", decimals: 6, iconURL: nil)
        // 1_500_000 smallest units with 6 decimals = 1.5
        XCTAssertEqual(token.formatBalance("1500000"), "1.5 USDT")
    }

    func test_formatBalance_largeAmount_18decimals() {
        let token = Token(id: "0x1", chain: .ethereum, symbol: "DAI", name: "Dai", decimals: 18, iconURL: nil)
        // 1 DAI = 10^18
        XCTAssertEqual(token.formatBalance("1000000000000000000"), "1 DAI")
    }

    func test_formatBalance_invalidStringReturnsZero() {
        let token = Token(id: "0x1", chain: .ethereum, symbol: "TST", name: "Test", decimals: 6, iconURL: nil)
        XCTAssertEqual(token.formatBalance("not_a_number"), "0 TST")
    }

    // MARK: - TokenBalance

    func test_tokenBalance_zeroAmount() {
        let token = Token(id: "0x1", chain: .ethereum, symbol: "USDC", name: "USD Coin", decimals: 6, iconURL: nil)
        let balance = TokenBalance(token: token, balance: "0")
        XCTAssertEqual(balance.id, token.id)
        XCTAssertEqual(balance.displayBalance, "0 USDC")
    }

    func test_tokenBalance_nonZeroAmount() {
        let token = Token(id: "0x1", chain: .ethereum, symbol: "USDC", name: "USD Coin", decimals: 6, iconURL: nil)
        let balance = TokenBalance(token: token, balance: "2000000")
        XCTAssertEqual(balance.displayBalance, "2 USDC")
    }

    func test_tokenBalance_idDerivedFromToken() {
        let token = Token(id: "unique-id-xyz", chain: .solana, symbol: "S", name: "S", decimals: 6, iconURL: nil)
        let balance = TokenBalance(token: token, balance: "0")
        XCTAssertEqual(balance.id, "unique-id-xyz")
    }
}
