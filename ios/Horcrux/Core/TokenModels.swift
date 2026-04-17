import Foundation

/// A known token on a specific chain.
struct Token: Identifiable, Codable, Hashable {
    let id: String          // contract address (ERC-20) or mint address (SPL)
    let chain: Chain
    let symbol: String
    let name: String
    let decimals: UInt8
    let iconURL: String?

    /// Format a raw balance string (in smallest unit) for display.
    func formatBalance(_ rawBalance: String) -> String {
        guard let raw = Decimal(string: rawBalance), raw > 0 else { return "0 \(symbol)" }
        let divisor = Decimal(sign: .plus, exponent: Int(decimals), significand: 1)
        let human = raw / divisor
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = min(Int(decimals), 8)
        formatter.numberStyle = .decimal
        let formatted = formatter.string(from: NSDecimalNumber(decimal: human)) ?? "0"
        return "\(formatted) \(symbol)"
    }
}

/// Holds a token and its balance.
struct TokenBalance: Identifiable {
    var id: String { token.id }
    let token: Token
    let balance: String     // raw balance in smallest unit
    var displayBalance: String { token.formatBalance(balance) }
}

/// Built-in popular token lists per chain.
enum TokenList {
    static let ethereum: [Token] = [
        Token(id: "0xdAC17F958D2ee523a2206206994597C13D831ec7", chain: .ethereum,
              symbol: "USDT", name: "Tether USD", decimals: 6, iconURL: nil),
        Token(id: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", chain: .ethereum,
              symbol: "USDC", name: "USD Coin", decimals: 6, iconURL: nil),
        Token(id: "0x6B175474E89094C44Da98b954EedeAC495271d0F", chain: .ethereum,
              symbol: "DAI", name: "Dai Stablecoin", decimals: 18, iconURL: nil),
        Token(id: "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599", chain: .ethereum,
              symbol: "WBTC", name: "Wrapped Bitcoin", decimals: 8, iconURL: nil),
        Token(id: "0x514910771AF9Ca656af840dff83E8264EcF986CA", chain: .ethereum,
              symbol: "LINK", name: "Chainlink", decimals: 18, iconURL: nil),
    ]

    // BSC stablecoins use 18 decimals (unlike Ethereum's 6), a well-known quirk.
    static let bnb: [Token] = [
        Token(id: "0x55d398326f99059fF775485246999027B3197955", chain: .bnb,
              symbol: "USDT", name: "Tether USD", decimals: 18, iconURL: nil),
        Token(id: "0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d", chain: .bnb,
              symbol: "USDC", name: "USD Coin", decimals: 18, iconURL: nil),
        Token(id: "0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56", chain: .bnb,
              symbol: "BUSD", name: "Binance USD", decimals: 18, iconURL: nil),
        Token(id: "0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82", chain: .bnb,
              symbol: "CAKE", name: "PancakeSwap", decimals: 18, iconURL: nil),
    ]

    static let avalanche: [Token] = [
        Token(id: "0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7", chain: .avalanche,
              symbol: "USDT", name: "Tether USD", decimals: 6, iconURL: nil),
        Token(id: "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E", chain: .avalanche,
              symbol: "USDC", name: "USD Coin", decimals: 6, iconURL: nil),
        Token(id: "0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7", chain: .avalanche,
              symbol: "WAVAX", name: "Wrapped AVAX", decimals: 18, iconURL: nil),
    ]

    static let optimism: [Token] = [
        Token(id: "0x94b008aA00579c1307B0EF2c499aD98a8ce58e58", chain: .optimism,
              symbol: "USDT", name: "Tether USD", decimals: 6, iconURL: nil),
        Token(id: "0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85", chain: .optimism,
              symbol: "USDC", name: "USD Coin", decimals: 6, iconURL: nil),
        Token(id: "0x4200000000000000000000000000000000000042", chain: .optimism,
              symbol: "OP", name: "Optimism", decimals: 18, iconURL: nil),
        Token(id: "0x4200000000000000000000000000000000000006", chain: .optimism,
              symbol: "WETH", name: "Wrapped Ether", decimals: 18, iconURL: nil),
    ]

    static let zksync: [Token] = [
        Token(id: "0x1d17CBcF0D6D143135aE902365D2E5e2A16538D4", chain: .zksync,
              symbol: "USDC", name: "USD Coin", decimals: 6, iconURL: nil),
        Token(id: "0x493257fD37EDB34451f62EDf8D2a0C418852bA4C", chain: .zksync,
              symbol: "USDT", name: "Tether USD", decimals: 6, iconURL: nil),
        Token(id: "0x5AEa5775959fBC2557Cc8789bC1bf90A239D9a91", chain: .zksync,
              symbol: "WETH", name: "Wrapped Ether", decimals: 18, iconURL: nil),
    ]

    static let linea: [Token] = [
        Token(id: "0x176211869cA2b568f2A7D4EE941E073a821EE1ff", chain: .linea,
              symbol: "USDC", name: "USD Coin", decimals: 6, iconURL: nil),
        Token(id: "0xA219439258ca9da29E9Cc4cE5596924745e12B93", chain: .linea,
              symbol: "USDT", name: "Tether USD", decimals: 6, iconURL: nil),
    ]

    static let scroll: [Token] = [
        Token(id: "0x06eFdBFf2a14a7c8E15944D1F4A48F9F95F663A4", chain: .scroll,
              symbol: "USDC", name: "USD Coin", decimals: 6, iconURL: nil),
        Token(id: "0xf55BEC9cafDbE8730f096Aa55dad6D22d44099Df", chain: .scroll,
              symbol: "USDT", name: "Tether USD", decimals: 6, iconURL: nil),
    ]

    static let solana: [Token] = [
        Token(id: "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB", chain: .solana,
              symbol: "USDT", name: "Tether USD", decimals: 6, iconURL: nil),
        Token(id: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v", chain: .solana,
              symbol: "USDC", name: "USD Coin", decimals: 6, iconURL: nil),
    ]

    static func tokens(for chain: Chain) -> [Token] {
        switch chain {
        case .ethereum: return ethereum
        case .bnb: return bnb
        case .avalanche: return avalanche
        case .optimism: return optimism
        case .zksync: return zksync
        case .linea: return linea
        case .scroll: return scroll
        case .bitcoin, .litecoin: return []   // UTXO chains have no native token standard
        case .solana: return solana
        case .tron: return []   // TRC-20 balance read path not wired yet; USDT-TRC20 lands with signing support.
        }
    }
}
