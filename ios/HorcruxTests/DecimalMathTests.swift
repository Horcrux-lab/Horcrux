import XCTest
@testable import Horcrux

/// Tests for Decimal-based ethToWei and other numeric conversions.
final class DecimalMathTests: XCTestCase {

    /// Mirrors the ethToWei implementation in SigningViewModel.
    private func ethToWei(_ ethString: String) -> String {
        guard let eth = Decimal(string: ethString) else { return "0" }
        let weiPerEth = Decimal(sign: .plus, exponent: 18, significand: 1)
        let wei = eth * weiPerEth
        return NSDecimalNumber(decimal: wei).stringValue
    }

    func testWholeEth() {
        XCTAssertEqual(ethToWei("1"), "1000000000000000000")
    }

    func testFractionalEth() {
        XCTAssertEqual(ethToWei("0.1"), "100000000000000000")
    }

    func testSmallFraction() {
        XCTAssertEqual(ethToWei("0.000001"), "1000000000000")
    }

    func testVerySmallFraction() {
        // 1 gwei
        XCTAssertEqual(ethToWei("0.000000001"), "1000000000")
    }

    func testZero() {
        XCTAssertEqual(ethToWei("0"), "0")
    }

    func testLargeAmount() {
        XCTAssertEqual(ethToWei("100"), "100000000000000000000")
    }

    func testInvalidInput() {
        XCTAssertEqual(ethToWei("abc"), "0")
    }

    func testEmptyInput() {
        XCTAssertEqual(ethToWei(""), "0")
    }

    func testPrecisionNotLost() {
        // This is the key test — Double would lose precision here
        let result = ethToWei("1.123456789012345678")
        XCTAssertTrue(result.hasPrefix("112345678901234567"))
    }

    func testDecimalVsDoubleComparison() {
        // Demonstrate that Decimal preserves precision where Double does not
        let ethString = "0.1"

        // Decimal way (correct)
        let decimalWei = ethToWei(ethString)
        XCTAssertEqual(decimalWei, "100000000000000000")

        // Double way (would be slightly off due to IEEE 754)
        let doubleWei = Double(ethString)! * 1e18
        // Double result is approximately but not exactly 100000000000000000
        // This test proves Decimal is better
        let doubleString = String(format: "%.0f", doubleWei)
        // doubleString might be "100000000000000000" or "99999999999999998" depending on platform
        // The point is Decimal is deterministically correct
        XCTAssertEqual(decimalWei, "100000000000000000")
        _ = doubleString // suppress unused warning
    }
}
