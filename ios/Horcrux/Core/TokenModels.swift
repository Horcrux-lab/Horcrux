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

    static let solana: [Token] = [
        Token(id: "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB", chain: .solana,
              symbol: "USDT", name: "Tether USD", decimals: 6, iconURL: nil),
        Token(id: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v", chain: .solana,
              symbol: "USDC", name: "USD Coin", decimals: 6, iconURL: nil),
    ]

    static func tokens(for chain: Chain) -> [Token] {
        switch chain {
        case .ethereum: return ethereum
        case .bnb, .avalanche, .optimism, .zksync, .linea, .scroll:
            // Token registries for new EVM chains are not wired yet. The
            // native balance still works; tokens arrive in a later milestone.
            return []
        case .bitcoin, .litecoin: return []   // UTXO chains have no native token standard
        case .solana: return solana
        case .tron: return []   // TRC20 not wired yet (notable: USDT-TRC20 later)
        }
    }
}
