import Foundation

/// Pure portfolio-math helpers extracted from `WalletHomeView`.
///
/// The live code path still calls the `@MainActor` convenience wrappers at
/// the bottom of this file, which pull live numbers from `PriceService`
/// and `BalanceCache`. The arithmetic itself lives in the `compute…`
/// functions, which take plain dictionaries and are unit-testable without
/// touching UserDefaults or the ObservableObject singletons.
enum PortfolioMetrics {

    // MARK: - Pure math (unit-testable)

    /// Sum of `amount × price` across wallets.
    ///
    /// Wallets whose chain symbol has no price entry contribute `0`. This
    /// matches the live behaviour (`usdPrice(...) ?? 0`) — a missing price
    /// is treated as "don't count it" rather than returning `nil`, so the
    /// banner can still render a partial total while some quotes are in
    /// flight.
    static func computeTotalUSD(
        wallets: [(walletId: String, symbol: String)],
        nativeAmount: (String) -> Double?,
        usdPrice: (String) -> Double?
    ) -> Double {
        wallets.reduce(0.0) { acc, w in
            let amount = nativeAmount(w.walletId) ?? 0
            let price = usdPrice(w.symbol) ?? 0
            return acc + amount * price
        }
    }

    /// 24-bucket sparkline scaled by holdings.
    ///
    /// For each symbol we aggregate the total native amount across wallets,
    /// then multiply the per-bucket price series by that amount. Buckets are
    /// summed across symbols to produce the portfolio-wide curve. A series
    /// shorter than 24 is left-padded with its first value so the line
    /// doesn't snap to zero at the start of the window.
    ///
    /// Returns `[]` when no symbol has both a positive amount *and* a
    /// sparkline — the caller uses an empty array to hide the chart entirely.
    static func computeSparkline24h(
        wallets: [(walletId: String, symbol: String)],
        nativeAmount: (String) -> Double?,
        sparkline: (String) -> [Double]?
    ) -> [Double] {
        var holdings: [String: Double] = [:]
        for w in wallets {
            let amount = nativeAmount(w.walletId) ?? 0
            holdings[w.symbol, default: 0] += amount
        }
        var bucketValues = Array(repeating: 0.0, count: 24)
        var anyData = false
        for (symbol, amount) in holdings where amount > 0 {
            guard let spark = sparkline(symbol) else { continue }
            anyData = true
            let padded: [Double] = spark.count >= 24
                ? Array(spark.suffix(24))
                : Array(repeating: spark.first ?? 0, count: 24 - spark.count) + spark
            for i in 0..<24 {
                bucketValues[i] += padded[i] * amount
            }
        }
        return anyData ? bucketValues : []
    }

    /// Portfolio-weighted 24h change.
    ///
    /// - `percent`: value-weighted mean of per-symbol percent changes.
    /// - `absolute`: sum of `(valueNow − valueThen)` where
    ///   `valueThen = valueNow / (1 + change/100)`.
    ///
    /// A wallet is skipped if any of amount / price / change is missing —
    /// partial data is better than crashing, but we require all three to
    /// avoid attributing phantom movement. Returns `nil` when nothing
    /// contributes (either no data, or total value is zero).
    static func computeChange24h(
        wallets: [(walletId: String, symbol: String)],
        nativeAmount: (String) -> Double?,
        usdPrice: (String) -> Double?,
        change24h: (String) -> Double?
    ) -> (percent: Double, absolute: Double)? {
        var weightedChange = 0.0
        var totalNow = 0.0
        var totalAbs = 0.0
        var hadAny = false
        for w in wallets {
            guard let amount = nativeAmount(w.walletId),
                  let price = usdPrice(w.symbol),
                  let change = change24h(w.symbol) else { continue }
            let valueNow = amount * price
            let valueThen = valueNow / (1 + change / 100)
            hadAny = true
            weightedChange += change * valueNow
            totalNow += valueNow
            totalAbs += (valueNow - valueThen)
        }
        guard hadAny, totalNow > 0 else { return nil }
        return (percent: weightedChange / totalNow, absolute: totalAbs)
    }

    // MARK: - Live wrappers (used by SwiftUI views)

    @MainActor
    static func totalUSD(wallets: [Wallet], priceService: PriceService, balanceCache: BalanceCache) -> Double {
        computeTotalUSD(
            wallets: wallets.map { (walletId: $0.id, symbol: $0.chain.symbol) },
            nativeAmount: balanceCache.nativeAmount(walletId:),
            usdPrice: priceService.usdPrice(symbol:)
        )
    }

    @MainActor
    static func sparkline24h(wallets: [Wallet], priceService: PriceService, balanceCache: BalanceCache) -> [Double] {
        computeSparkline24h(
            wallets: wallets.map { (walletId: $0.id, symbol: $0.chain.symbol) },
            nativeAmount: balanceCache.nativeAmount(walletId:),
            sparkline: priceService.sparkline24h(symbol:)
        )
    }

    @MainActor
    static func change24h(wallets: [Wallet], priceService: PriceService, balanceCache: BalanceCache) -> (percent: Double, absolute: Double)? {
        computeChange24h(
            wallets: wallets.map { (walletId: $0.id, symbol: $0.chain.symbol) },
            nativeAmount: balanceCache.nativeAmount(walletId:),
            usdPrice: priceService.usdPrice(symbol:),
            change24h: priceService.change24h(symbol:)
        )
    }
}
