import Foundation
import Combine

/// CoinGecko-backed price service for the three supported chains.
///
/// Caches quotes in memory with a 5-minute TTL. Users of this class should
/// observe `@Published quotes` and format via `Quote.fiatString(for:)`.
///
/// No API key needed: we use the free `/api/v3/simple/price` endpoint.
@MainActor
final class PriceService: ObservableObject {
    static let shared = PriceService()

    struct Quote {
        let symbol: String    // ETH / BTC / SOL / LTC / TRX / USDC / USDT
        let usd: Double
        let change24h: Double  // Percent, e.g. -3.42
        let fetchedAt: Date
    }

    @Published private(set) var quotes: [String: Quote] = [:]
    private let session: URLSession
    private let ttl: TimeInterval = 300
    private var inflight: Task<Void, Never>?

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 10
        self.session = URLSession(configuration: cfg)
    }

    /// Fetch prices for the listed CoinGecko IDs. Symbols are uppercase chain tickers.
    /// Call this lazily from views; repeated calls within TTL are ignored.
    func refreshIfNeeded(symbols: [String] = ["ETH", "BTC", "SOL", "LTC", "TRX", "USDC", "USDT"]) {
        let needRefresh = symbols.contains { symbol in
            guard let q = quotes[symbol] else { return true }
            return Date().timeIntervalSince(q.fetchedAt) > ttl
        }
        guard needRefresh, inflight == nil else { return }
        inflight = Task { [weak self] in
            defer { self?.inflight = nil }
            await self?.fetch(symbols: symbols)
        }
    }

    private func fetch(symbols: [String]) async {
        let mapping: [String: String] = [
            "ETH": "ethereum",
            "BTC": "bitcoin",
            "SOL": "solana",
            "LTC": "litecoin",
            "TRX": "tron",
            "USDC": "usd-coin",
            "USDT": "tether"
        ]
        let ids = symbols.compactMap { mapping[$0] }.joined(separator: ",")
        guard let url = URL(string: "https://api.coingecko.com/api/v3/simple/price?ids=\(ids)&vs_currencies=usd&include_24hr_change=true") else { return }

        do {
            let (data, _) = try await session.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: [String: Double]] else { return }
            var new: [String: Quote] = quotes
            for symbol in symbols {
                guard let cgId = mapping[symbol], let obj = json[cgId], let usd = obj["usd"] else { continue }
                // CoinGecko returns `usd_24h_change` with this flag set.
                let change = obj["usd_24h_change"] ?? 0
                new[symbol] = Quote(symbol: symbol, usd: usd, change24h: change, fetchedAt: Date())
            }
            self.quotes = new
        } catch {
            // Silent failure — price display is best-effort.
        }
    }

    /// Convenience: fiat string for a given crypto amount, or nil if quote is missing.
    func fiatString(amount: Double, symbol: String) -> String? {
        guard let q = quotes[symbol] else { return nil }
        let usd = amount * q.usd
        let fmt = NumberFormatter()
        fmt.numberStyle = .currency
        fmt.currencyCode = "USD"
        fmt.maximumFractionDigits = usd >= 1 ? 2 : 4
        return fmt.string(from: NSNumber(value: usd))
    }

    func usdPrice(symbol: String) -> Double? {
        quotes[symbol]?.usd
    }

    /// 24h percent change for a symbol (e.g. -3.42 means -3.42%).
    func change24h(symbol: String) -> Double? {
        quotes[symbol]?.change24h
    }
}
