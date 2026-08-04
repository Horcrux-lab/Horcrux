import XCTest
@testable import Horcrux

/// `CurrencyFormatter` renders every amount the user sees before they approve a
/// transfer, so these tests pin down its exact output rather than merely
/// exercising it.
///
/// Locale note: `fiat` pins its formatter to `en_US` and `compact`'s K/M/B arms
/// use `String(format:)`, which is locale independent — both can be asserted
/// exactly. `crypto` formats with `Locale.current`, so the assertions below
/// compare it against itself or inspect its digits instead of hard-coding
/// separators that differ between regions.
final class CurrencyFormatterTests: XCTestCase {

    // MARK: - fiat

    func testFiatGroupsThousandsAndKeepsTwoDecimals() {
        XCTAssertEqual(CurrencyFormatter.fiat(1234.56), "$1,234.56")
    }

    func testFiatRendersZeroWithBothDecimals() {
        XCTAssertEqual(CurrencyFormatter.fiat(0), "$0.00")
    }

    func testFiatPlacesTheMinusBeforeTheCurrencySymbol() {
        XCTAssertEqual(CurrencyFormatter.fiat(-5), "-$5.00")
    }

    func testFiatHonoursAnAlternateCurrencyCode() {
        XCTAssertEqual(CurrencyFormatter.fiat(1234.56, currencyCode: "EUR"), "€1,234.56")
    }

    /// The currency code drives the fraction digits too, not just the glyph:
    /// yen has no minor unit, so the amount is rounded to a whole number.
    func testFiatAdoptsTheFractionDigitsOfTheRequestedCurrency() {
        XCTAssertEqual(CurrencyFormatter.fiat(1234.56, currencyCode: "JPY"), "¥1,235")
    }

    /// An unrecognised code degrades to the code itself followed by a
    /// non-breaking space (U+00A0), not a plain space.
    func testFiatFallsBackToTheRawCodeForAnUnknownCurrency() {
        XCTAssertEqual(CurrencyFormatter.fiat(1234.56, currencyCode: "ZZZ"), "ZZZ\u{00A0}1,234.56")
    }

    /// Half-even rounding: 1234.565 is not exactly representable and lands just
    /// below the midpoint, so it truncates rather than rounding up.
    func testFiatRoundsToTheMinorUnit() {
        XCTAssertEqual(CurrencyFormatter.fiat(1234.565), "$1,234.56")
    }

    func testFiatKeepsFullPrecisionForVeryLargeAmounts() {
        XCTAssertEqual(CurrencyFormatter.fiat(1_000_000_000_000), "$1,000,000,000,000.00")
    }

    /// `fiat` mutates a `NumberFormatter` to apply the currency code. It copies
    /// the shared instance first; without that copy the code would leak into
    /// every later call, silently relabelling USD balances.
    func testFiatDoesNotLeakTheCurrencyCodeIntoSubsequentCalls() {
        XCTAssertEqual(CurrencyFormatter.fiat(1, currencyCode: "EUR"), "€1.00")
        XCTAssertEqual(CurrencyFormatter.fiat(1), "$1.00")
    }

    /// Each call copies the shared formatter before changing its currency. If
    /// callers shared that mutable instance, simultaneous EUR and JPY renders
    /// could pick up one another's code or fraction-digit policy.
    func testFiatKeepsConcurrentCurrencyFormattingIsolated() {
        let lock = NSLock()
        var mismatches: [String] = []

        DispatchQueue.concurrentPerform(iterations: 10_000) { iteration in
            let usesEuro = iteration.isMultiple(of: 2)
            let actual = CurrencyFormatter.fiat(
                1234.56,
                currencyCode: usesEuro ? "EUR" : "JPY"
            )
            let expected = usesEuro ? "€1,234.56" : "¥1,235"
            guard actual != expected else { return }

            lock.lock()
            mismatches.append("\(usesEuro ? "EUR" : "JPY"): \(actual)")
            lock.unlock()
        }

        XCTAssertTrue(
            mismatches.isEmpty,
            "currency formatter state leaked between calls: \(mismatches.prefix(5))"
        )
    }

    /// Locale independence is the point of pinning `en_US`: the grouping and
    /// decimal separators must not follow the device region.
    func testFiatIgnoresTheDeviceLocale() {
        let formatted = CurrencyFormatter.fiat(1234.56)
        XCTAssertTrue(formatted.contains(","), "expected an ASCII group separator, got \(formatted)")
        XCTAssertTrue(formatted.contains("."), "expected an ASCII decimal separator, got \(formatted)")
    }

    /// Documented limitation: non-finite input reaches the UI as a raw token
    /// rather than a placeholder.
    func testFiatRendersNonFiniteAmountsAsRawTokens() {
        XCTAssertEqual(CurrencyFormatter.fiat(.nan), "NaN")
        XCTAssertEqual(CurrencyFormatter.fiat(.infinity), "+∞")
    }

    // MARK: - crypto

    func testCryptoDropsTrailingZeros() {
        XCTAssertEqual(Self.digits(CurrencyFormatter.crypto(1)), "1")
        XCTAssertEqual(Self.digits(CurrencyFormatter.crypto(0)), "0")
    }

    func testCryptoKeepsEightFractionDigits() {
        XCTAssertEqual(Self.digits(CurrencyFormatter.crypto(0.12345678)), "012345678")
    }

    func testCryptoRoundsAwayAnythingBeyondEightFractionDigits() {
        XCTAssertEqual(Self.digits(CurrencyFormatter.crypto(0.123456789)), "012345679")
    }

    /// One satoshi is the smallest amount that survives the eight-digit cap.
    func testCryptoKeepsASingleSatoshi() {
        XCTAssertNotEqual(CurrencyFormatter.crypto(0.00000001), CurrencyFormatter.crypto(0))
    }

    /// Chains with more than eight decimals (every EVM chain has eighteen)
    /// render sub-satoshi amounts as a flat zero. A non-zero transfer can
    /// therefore be displayed as "0".
    func testCryptoCollapsesSubSatoshiDustToZero() {
        XCTAssertEqual(CurrencyFormatter.crypto(0.000000001), CurrencyFormatter.crypto(0))
    }

    func testCryptoGroupsThousands() {
        let formatted = CurrencyFormatter.crypto(21_000_000)
        XCTAssertEqual(Self.digits(formatted), "21000000")
        XCTAssertGreaterThan(formatted.count, 8, "expected group separators in \(formatted)")
    }

    func testCryptoAppendsTheSymbolAfterASingleSpace() {
        let bare = CurrencyFormatter.crypto(1234.5)
        XCTAssertEqual(CurrencyFormatter.crypto(1234.5, symbol: "BTC"), bare + " BTC")
    }

    func testCryptoAddsNoSeparatorWhenTheSymbolIsEmpty() {
        XCTAssertEqual(CurrencyFormatter.crypto(1234.5, symbol: ""), CurrencyFormatter.crypto(1234.5))
    }

    func testCryptoPreservesTheSign() {
        let negative = CurrencyFormatter.crypto(-0.5)
        XCTAssertEqual(Self.parseCrypto(negative), -0.5)
        XCTAssertEqual(Self.digits(negative), Self.digits(CurrencyFormatter.crypto(0.5)))
    }

    func testCryptoRendersNonFiniteAmountsAsRawTokens() {
        XCTAssertEqual(CurrencyFormatter.crypto(.nan), Self.localizedNaNSymbol)
    }

    // MARK: - compact: unit selection

    func testCompactDefersToCryptoBelowOneThousand() {
        XCTAssertEqual(CurrencyFormatter.compact(999), CurrencyFormatter.crypto(999))
        XCTAssertEqual(CurrencyFormatter.compact(0), CurrencyFormatter.crypto(0))
    }

    func testCompactFormatsThousands() {
        XCTAssertEqual(CurrencyFormatter.compact(1_000), "1.0K")
        XCTAssertEqual(CurrencyFormatter.compact(1_234), "1.2K")
    }

    func testCompactFormatsMillions() {
        XCTAssertEqual(CurrencyFormatter.compact(1_000_000), "1.0M")
        XCTAssertEqual(CurrencyFormatter.compact(3_400_000), "3.4M")
    }

    func testCompactFormatsBillions() {
        XCTAssertEqual(CurrencyFormatter.compact(1_000_000_000), "1.0B")
        XCTAssertEqual(CurrencyFormatter.compact(1_250_000_000), "1.2B")
    }

    // MARK: - compact: magnitude boundaries

    /// Regression: rendering uses one decimal place, so 999_999 divided by a
    /// thousand rounds to 1000.0. It used to be shown as "1000.0K".
    func testCompactPromotesValuesThatWouldRenderAsOneThousandK() {
        XCTAssertEqual(CurrencyFormatter.compact(999_999), "1.0M")
        XCTAssertEqual(CurrencyFormatter.compact(999_950), "1.0M")
    }

    /// Regression: the same overflow one magnitude up, previously "1000.0M".
    func testCompactPromotesValuesThatWouldRenderAsOneThousandM() {
        XCTAssertEqual(CurrencyFormatter.compact(999_999_999), "1.0B")
        XCTAssertEqual(CurrencyFormatter.compact(999_950_000), "1.0B")
    }

    /// The counterpart to the promotion tests: the largest value that still
    /// renders below 1000.0 must stay in its own bucket.
    func testCompactKeepsValuesThatStillFitBelowTheirBucketCeiling() {
        XCTAssertEqual(CurrencyFormatter.compact(999_949), "999.9K")
        XCTAssertEqual(CurrencyFormatter.compact(999_949_999), "999.9M")
    }

    /// Nine hundred and ninety nine is the last value handled by `crypto`, so
    /// the K bucket must start at exactly one thousand.
    func testCompactSwitchesToUnitsAtExactlyOneThousand() {
        XCTAssertEqual(CurrencyFormatter.compact(1_000), "1.0K")
        XCTAssertNotEqual(CurrencyFormatter.compact(999.99), "1.0K")
    }

    /// There is no unit above billions, so the mantissa is allowed to grow.
    func testCompactHasNoUnitBeyondBillions() {
        XCTAssertEqual(CurrencyFormatter.compact(1_000_000_000_000), "1000.0B")
    }

    // MARK: - compact: sign, rounding and separators

    func testCompactPrefixesNegativesWithASingleMinus() {
        XCTAssertEqual(CurrencyFormatter.compact(-1_500), "-1.5K")
        XCTAssertEqual(CurrencyFormatter.compact(-3_400_000), "-3.4M")
    }

    func testCompactLeavesSmallNegativesToCrypto() {
        XCTAssertEqual(CurrencyFormatter.compact(-999), CurrencyFormatter.crypto(-999))
    }

    func testCompactRoundsToOneDecimalPlace() {
        XCTAssertEqual(CurrencyFormatter.compact(1_050), "1.1K")
        XCTAssertEqual(CurrencyFormatter.compact(1_999), "2.0K")
    }

    /// `compact` formats through `String(format:)`, which always emits an ASCII
    /// dot, while `crypto` follows the device locale. The two therefore
    /// disagree about the decimal separator in comma-decimal regions.
    func testCompactAlwaysUsesAnASCIIDecimalPoint() {
        XCTAssertEqual(CurrencyFormatter.compact(1_234), "1.2K")
    }

    func testCompactRendersNonFiniteAmountsAsRawTokens() {
        XCTAssertEqual(CurrencyFormatter.compact(.infinity), "infB")
    }

    // MARK: - Helpers

    private static func digits(_ string: String) -> String {
        string.compactMap { character in
            character.wholeNumberValue.map(String.init)
        }.joined()
    }

    private static func parseCrypto(_ string: String) -> Double? {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = .current
        return formatter.number(from: string)?.doubleValue
    }

    private static var localizedNaNSymbol: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = .current
        return formatter.notANumberSymbol
    }
}
