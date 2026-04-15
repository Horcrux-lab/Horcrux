import Foundation

/// Locale-aware cryptocurrency and fiat amount formatting.
enum CurrencyFormatter {
    private static let fiatFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        return f
    }()

    private static let cryptoFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 8
        f.locale = .current
        return f
    }()

    /// Format a fiat amount (e.g., "$1,234.56")
    static func fiat(_ amount: Double, currencyCode: String = "USD") -> String {
        let formatter = fiatFormatter.copy() as! NumberFormatter
        formatter.currencyCode = currencyCode
        return formatter.string(from: NSNumber(value: amount)) ?? "$\(amount)"
    }

    /// Format a crypto amount with appropriate decimal places
    static func crypto(_ amount: Double, symbol: String = "") -> String {
        let str = cryptoFormatter.string(from: NSNumber(value: amount)) ?? "\(amount)"
        return symbol.isEmpty ? str : "\(str) \(symbol)"
    }

    /// Format with compact notation for large numbers (e.g., "1.2K", "3.4M")
    static func compact(_ amount: Double) -> String {
        let absAmount = abs(amount)
        let sign = amount < 0 ? "-" : ""
        switch absAmount {
        case 1_000_000_000...:
            return "\(sign)\(String(format: "%.1f", absAmount / 1_000_000_000))B"
        case 1_000_000...:
            return "\(sign)\(String(format: "%.1f", absAmount / 1_000_000))M"
        case 1_000...:
            return "\(sign)\(String(format: "%.1f", absAmount / 1_000))K"
        default:
            return crypto(amount)
        }
    }
}
