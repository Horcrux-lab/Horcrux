import XCTest
@testable import Horcrux

/// Tests for `PortfolioMetrics` pure-math helpers.
///
/// The live wrappers (`totalUSD` / `sparkline24h` / `change24h`) thread
/// `PriceService` and `BalanceCache` through the same `compute…` entry
/// points, so exercising the pure functions covers the arithmetic the
/// wallet home screen actually shows.
final class PortfolioMetricsTests: XCTestCase {

    private typealias WalletEntry = (walletId: String, symbol: String)

    private let wallets: [WalletEntry] = [
        (walletId: "w-eth", symbol: "ETH"),
        (walletId: "w-btc", symbol: "BTC"),
    ]

    // MARK: - totalUSD

    func testTotalUSD_sumsAmountTimesPrice() {
        let amounts = ["w-eth": 2.0, "w-btc": 0.5]
        let prices = ["ETH": 2000.0, "BTC": 60_000.0]
        let total = PortfolioMetrics.computeTotalUSD(
            wallets: wallets,
            nativeAmount: { amounts[$0] },
            usdPrice: { prices[$0] }
        )
        XCTAssertEqual(total, 2.0 * 2000 + 0.5 * 60_000, accuracy: 1e-9)
    }

    func testTotalUSD_missingPriceContributesZero() {
        let amounts = ["w-eth": 2.0, "w-btc": 0.5]
        let prices = ["ETH": 2000.0] // BTC missing
        let total = PortfolioMetrics.computeTotalUSD(
            wallets: wallets,
            nativeAmount: { amounts[$0] },
            usdPrice: { prices[$0] }
        )
        XCTAssertEqual(total, 4000, accuracy: 1e-9)
    }

    func testTotalUSD_missingAmountContributesZero() {
        let prices = ["ETH": 2000.0, "BTC": 60_000.0]
        let total = PortfolioMetrics.computeTotalUSD(
            wallets: wallets,
            nativeAmount: { _ in nil },
            usdPrice: { prices[$0] }
        )
        XCTAssertEqual(total, 0, accuracy: 1e-9)
    }

    func testTotalUSD_emptyWalletsIsZero() {
        let total = PortfolioMetrics.computeTotalUSD(
            wallets: [],
            nativeAmount: { _ in 1 },
            usdPrice: { _ in 1 }
        )
        XCTAssertEqual(total, 0)
    }

    // MARK: - sparkline24h

    func testSparkline_returnsEmptyArrayWhenNoHoldings() {
        let bucket = PortfolioMetrics.computeSparkline24h(
            wallets: wallets,
            nativeAmount: { _ in 0 },
            sparkline: { _ in Array(repeating: 100.0, count: 24) }
        )
        XCTAssertEqual(bucket, [])
    }

    func testSparkline_returnsEmptyArrayWhenNoSeries() {
        let amounts = ["w-eth": 2.0]
        let bucket = PortfolioMetrics.computeSparkline24h(
            wallets: wallets,
            nativeAmount: { amounts[$0] },
            sparkline: { _ in nil }
        )
        XCTAssertEqual(bucket, [])
    }

    func testSparkline_scalesByHoldingsAndSumsSymbols() {
        let amounts = ["w-eth": 2.0, "w-btc": 0.5]
        let ethSeries = Array(repeating: 2000.0, count: 24)
        let btcSeries = Array(repeating: 60_000.0, count: 24)
        let bucket = PortfolioMetrics.computeSparkline24h(
            wallets: wallets,
            nativeAmount: { amounts[$0] },
            sparkline: { $0 == "ETH" ? ethSeries : btcSeries }
        )
        XCTAssertEqual(bucket.count, 24)
        // Each bucket = 2 * 2000 + 0.5 * 60_000 = 34_000
        for value in bucket {
            XCTAssertEqual(value, 34_000, accuracy: 1e-9)
        }
    }

    func testSparkline_truncatesSeriesLongerThan24() {
        let amounts = ["w-eth": 1.0, "w-btc": 0.0]
        // 30-point series: the last 24 all equal 7, the first 6 are 1 (should be discarded).
        var series = Array(repeating: 1.0, count: 6)
        series.append(contentsOf: Array(repeating: 7.0, count: 24))
        let bucket = PortfolioMetrics.computeSparkline24h(
            wallets: wallets,
            nativeAmount: { amounts[$0] },
            sparkline: { $0 == "ETH" ? series : nil }
        )
        XCTAssertEqual(bucket.count, 24)
        for value in bucket {
            XCTAssertEqual(value, 7, accuracy: 1e-9)
        }
    }

    func testSparkline_leftPadsShortSeriesWithFirstValue() {
        let amounts = ["w-eth": 1.0, "w-btc": 0.0]
        // 5-point series — should become [5, 5, ... (19 copies of 5), 5, 6, 7, 8, 9].
        let series: [Double] = [5, 6, 7, 8, 9]
        let bucket = PortfolioMetrics.computeSparkline24h(
            wallets: wallets,
            nativeAmount: { amounts[$0] },
            sparkline: { $0 == "ETH" ? series : nil }
        )
        XCTAssertEqual(bucket.count, 24)
        // Buckets 0..<19 should equal 5; last 5 should equal 5, 6, 7, 8, 9.
        for i in 0..<19 { XCTAssertEqual(bucket[i], 5, accuracy: 1e-9) }
        XCTAssertEqual(bucket[19], 5, accuracy: 1e-9)
        XCTAssertEqual(bucket[20], 6, accuracy: 1e-9)
        XCTAssertEqual(bucket[21], 7, accuracy: 1e-9)
        XCTAssertEqual(bucket[22], 8, accuracy: 1e-9)
        XCTAssertEqual(bucket[23], 9, accuracy: 1e-9)
    }

    func testSparkline_aggregatesSameSymbolAcrossWallets() {
        // Two ETH wallets, 1.0 + 3.0 = 4.0 ETH total.
        let wallets: [WalletEntry] = [
            (walletId: "w1", symbol: "ETH"),
            (walletId: "w2", symbol: "ETH"),
        ]
        let amounts = ["w1": 1.0, "w2": 3.0]
        let series = Array(repeating: 10.0, count: 24)
        let bucket = PortfolioMetrics.computeSparkline24h(
            wallets: wallets,
            nativeAmount: { amounts[$0] },
            sparkline: { _ in series }
        )
        for value in bucket { XCTAssertEqual(value, 40, accuracy: 1e-9) }
    }

    // MARK: - change24h

    func testChange24h_weightedPercentAndAbsolute() {
        let amounts = ["w-eth": 2.0, "w-btc": 0.5]
        let prices = ["ETH": 2000.0, "BTC": 60_000.0]
        let changes = ["ETH": 10.0, "BTC": 0.0] // ETH +10%, BTC flat
        let result = PortfolioMetrics.computeChange24h(
            wallets: wallets,
            nativeAmount: { amounts[$0] },
            usdPrice: { prices[$0] },
            change24h: { changes[$0] }
        )
        let ethValue = 4000.0
        let btcValue = 30_000.0
        let total = ethValue + btcValue
        let expectedPercent = (10 * ethValue + 0 * btcValue) / total
        // ETH: valueThen = 4000 / 1.10 → absolute = 4000 - 3636.36…
        let expectedAbs = ethValue - ethValue / 1.10
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.percent, expectedPercent, accuracy: 1e-9)
        XCTAssertEqual(result!.absolute, expectedAbs, accuracy: 1e-6)
    }

    func testChange24h_returnsNilWhenNoData() {
        let result = PortfolioMetrics.computeChange24h(
            wallets: wallets,
            nativeAmount: { _ in nil },
            usdPrice: { _ in nil },
            change24h: { _ in nil }
        )
        XCTAssertNil(result)
    }

    func testChange24h_returnsNilWhenTotalNowIsZero() {
        // Amount is 0 ⇒ valueNow is 0 for all wallets ⇒ totalNow = 0.
        let result = PortfolioMetrics.computeChange24h(
            wallets: wallets,
            nativeAmount: { _ in 0 },
            usdPrice: { _ in 100 },
            change24h: { _ in 5 }
        )
        XCTAssertNil(result)
    }

    func testChange24h_skipsWalletsWithAnyMissingPiece() {
        // ETH has everything; BTC missing change24h ⇒ skipped.
        let amounts = ["w-eth": 1.0, "w-btc": 1.0]
        let prices = ["ETH": 100.0, "BTC": 1000.0]
        let changes = ["ETH": 20.0] // BTC missing
        let result = PortfolioMetrics.computeChange24h(
            wallets: wallets,
            nativeAmount: { amounts[$0] },
            usdPrice: { prices[$0] },
            change24h: { changes[$0] }
        )
        XCTAssertNotNil(result)
        // Only ETH counts: percent should be exactly 20 (single contributor).
        XCTAssertEqual(result!.percent, 20, accuracy: 1e-9)
    }
}
