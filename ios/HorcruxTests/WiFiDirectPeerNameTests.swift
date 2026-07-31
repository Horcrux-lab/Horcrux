import XCTest
import MultipeerConnectivity
@testable import Horcrux

/// `MCPeerID(displayName:)` raises an uncatchable Objective-C exception for an
/// empty name or one over 63 UTF-8 bytes, and `WiFiDirectTransport` builds one
/// from `ProcessInfo.processInfo.hostName` during `AppState.init`. An invalid
/// name therefore aborts the app before its first frame rather than degrading.
final class WiFiDirectPeerNameTests: XCTestCase {

    private let limit = WiFiDirectTransport.maxPeerNameBytes

    // MARK: - Lower bound

    func test_emptyName_fallsBack() {
        XCTAssertEqual(
            WiFiDirectTransport.sanitizedPeerName(""),
            WiFiDirectTransport.fallbackPeerName
        )
    }

    /// A simulator with no configured hostname yields whitespace as readily as
    /// "", and MCPeerID rejects " " the same way it rejects "".
    func test_whitespaceOnlyName_fallsBack() {
        XCTAssertEqual(
            WiFiDirectTransport.sanitizedPeerName("   \n\t "),
            WiFiDirectTransport.fallbackPeerName
        )
    }

    // MARK: - Pass-through

    func test_ordinaryName_isUnchanged() {
        XCTAssertEqual(
            WiFiDirectTransport.sanitizedPeerName("Bill's iPhone"),
            "Bill's iPhone"
        )
    }

    /// Exactly at the limit must survive. A truncation written with `>=` would
    /// still produce a valid name, so no length assertion alone catches that
    /// off-by-one — only comparing against the input does.
    func test_nameAtExactlyTheByteLimit_isUnchanged() {
        let name = String(repeating: "a", count: limit)
        XCTAssertEqual(name.utf8.count, limit)
        XCTAssertEqual(WiFiDirectTransport.sanitizedPeerName(name), name)
    }

    // MARK: - Upper bound

    func test_nameOneByteOverTheLimit_isTruncated() {
        let name = String(repeating: "a", count: limit + 1)
        let sanitized = WiFiDirectTransport.sanitizedPeerName(name)
        XCTAssertEqual(sanitized.utf8.count, limit)
        XCTAssertNotEqual(sanitized, name)
    }

    /// 63 bytes is not 63 characters. Sixteen emoji are 64 bytes, which is a
    /// perfectly ordinary thing to call a phone.
    func test_multiByteName_isTruncatedOnAGraphemeBoundary() {
        let name = String(repeating: "😀", count: 16)
        XCTAssertGreaterThan(name.utf8.count, limit)

        let sanitized = WiFiDirectTransport.sanitizedPeerName(name)
        XCTAssertLessThanOrEqual(sanitized.utf8.count, limit)
        // Truncating at byte 63 would split the sixteenth emoji and leave a
        // replacement character behind; cutting on graphemes cannot.
        XCTAssertFalse(sanitized.unicodeScalars.contains("\u{FFFD}"))
        XCTAssertEqual(sanitized, String(repeating: "😀", count: 15))
    }

    func test_cjkName_isTruncatedWithinTheByteBudget() {
        let name = String(repeating: "設", count: 30)
        XCTAssertGreaterThan(name.utf8.count, limit)

        let sanitized = WiFiDirectTransport.sanitizedPeerName(name)
        XCTAssertLessThanOrEqual(sanitized.utf8.count, limit)
        XCTAssertEqual(sanitized, String(repeating: "設", count: limit / 3))
    }

    /// One grapheme cluster can exceed the whole budget by itself — "a" plus
    /// forty combining accents is a single Character of 81 bytes — which
    /// leaves the truncation loop with nothing it is allowed to emit. Without
    /// the empty check that returns "", and MCPeerID rejects "".
    func test_singleGraphemeLargerThanTheBudget_fallsBack() {
        let name = "a" + String(repeating: "\u{0301}", count: 40)
        XCTAssertEqual(name.count, 1)
        XCTAssertGreaterThan(name.utf8.count, limit)

        XCTAssertEqual(
            WiFiDirectTransport.sanitizedPeerName(name),
            WiFiDirectTransport.fallbackPeerName
        )
    }

    // MARK: - The crash path itself

    /// The assertions above are about a pure function; this one is about the
    /// abort. Constructing the transport is what called
    /// `-[MCPeerID initWithDisplayName:]` and killed the process, so it is the
    /// only test here that would have caught the original bug end to end.
    func test_constructingTransportWithHostileNames_doesNotAbort() {
        for name in ["", "   ", String(repeating: "a", count: 512),
                     String(repeating: "😀", count: 64)] {
            let transport = WiFiDirectTransport(peerName: name)
            XCTAssertEqual(transport.channelId, "wifi-direct")
        }
    }

    /// Whatever this machine's hostname happens to be, it has to survive the
    /// sanitizer — this is the input the app actually uses.
    func test_realHostName_producesAValidDisplayName() {
        let sanitized = WiFiDirectTransport
            .sanitizedPeerName(ProcessInfo.processInfo.hostName)
        XCTAssertFalse(sanitized.isEmpty)
        XCTAssertLessThanOrEqual(sanitized.utf8.count, limit)
    }
}
