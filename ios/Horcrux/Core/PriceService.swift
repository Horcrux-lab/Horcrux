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
    /// Hourly USD price points for the last 24h per symbol. Populated
    /// by `refreshSparklinesIfNeeded()` from CoinGecko's `/coins/markets`
    /// endpoint. Kept separate from `quotes` so the simple-price flow
    /// stays untouched and the sparkline call can fail independently.
    @Published private(set) var sparklines: [String: [Double]] = [:]
    private var sparklinesFetchedAt: Date?
    private var sparklineInflight: Task<Void, Never>?
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

    /// Hourly USD points for the last 24h, or nil if not yet fetched.
    func sparkline24h(symbol: String) -> [Double]? {
        sparklines[symbol]
    }

    /// Fetch hourly 7-day sparkline data via `/coins/markets` and retain only
    /// the last 24 points per symbol. Cached with the same 5-min TTL as quotes.
    func refreshSparklinesIfNeeded(symbols: [String] = ["ETH", "BTC", "SOL", "LTC", "TRX", "USDC", "USDT"]) {
        let stale: Bool = {
            guard let t = sparklinesFetchedAt else { return true }
            return Date().timeIntervalSince(t) > ttl
        }()
        guard stale, sparklineInflight == nil else { return }
        sparklineInflight = Task { [weak self] in
            defer { self?.sparklineInflight = nil }
            await self?.fetchSparklines(symbols: symbols)
        }
    }

    private func fetchSparklines(symbols: [String]) async {
        let mapping: [String: String] = [
            "ETH": "ethereum", "BTC": "bitcoin", "SOL": "solana",
            "LTC": "litecoin", "TRX": "tron",
            "USDC": "usd-coin", "USDT": "tether"
        ]
        let ids = symbols.compactMap { mapping[$0] }.joined(separator: ",")
        guard let url = URL(string: "https://api.coingecko.com/api/v3/coins/markets?vs_currency=usd&ids=\(ids)&sparkline=true&price_change_percentage=24h") else { return }
        do {
            let (data, _) = try await session.data(from: url)
            guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            var new: [String: [Double]] = sparklines
            let reverse = Dictionary(uniqueKeysWithValues: mapping.map { ($0.value, $0.key) })
            for row in rows {
                guard let id = row["id"] as? String,
                      let symbol = reverse[id],
                      let spark = row["sparkline_in_7d"] as? [String: Any],
                      let prices = spark["price"] as? [Double] else { continue }
                // Retain the last 24 points (hourly for 1 day).
                new[symbol] = Array(prices.suffix(24))
            }
            self.sparklines = new
            self.sparklinesFetchedAt = Date()
        } catch {
            // Silent: sparkline is decorative.
        }
    }
}
