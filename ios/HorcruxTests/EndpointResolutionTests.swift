import XCTest
@testable import Horcrux

final class EndpointResolutionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ChainEndpointOverrides.shared.removeAll()
    }

    override func tearDown() {
        ChainEndpointOverrides.shared.removeAll()
        super.tearDown()
    }

    func test_overrides_startEmpty() {
        XCTAssertNil(ChainEndpointOverrides.shared.url(for: .polygon))
        XCTAssertTrue(ChainEndpointOverrides.shared.allChains().isEmpty)
    }

    func test_setAndReadBack_roundTrips() {
        ChainEndpointOverrides.shared.set("https://my-node.example", for: .polygon)
        XCTAssertEqual(ChainEndpointOverrides.shared.url(for: .polygon),
                       "https://my-node.example")
        XCTAssertNil(ChainEndpointOverrides.shared.url(for: .base),
                     "setting one chain must not affect another")
    }

    /// The bug this design replaces: one shared field meant a custom
    /// Polygon URL silently applied to Base.
    func test_overridesAreIndependentPerChain() {
        ChainEndpointOverrides.shared.set("https://poly.example", for: .polygon)
        ChainEndpointOverrides.shared.set("https://base.example", for: .base)
        XCTAssertEqual(ChainEndpointOverrides.shared.url(for: .polygon), "https://poly.example")
        XCTAssertEqual(ChainEndpointOverrides.shared.url(for: .base), "https://base.example")
    }

    func test_settingEmptyString_clearsTheOverride() {
        ChainEndpointOverrides.shared.set("https://my-node.example", for: .polygon)
        ChainEndpointOverrides.shared.set("", for: .polygon)
        XCTAssertNil(ChainEndpointOverrides.shared.url(for: .polygon),
                     "an emptied field must fall back to provider/public, not store \"\"")
    }

    /// Whitespace-only input is the same user intent as an empty field.
    func test_settingWhitespaceOnly_clearsTheOverride() {
        ChainEndpointOverrides.shared.set("https://my-node.example", for: .polygon)
        ChainEndpointOverrides.shared.set("   \n ", for: .polygon)
        XCTAssertNil(ChainEndpointOverrides.shared.url(for: .polygon))
    }

    func test_setTrimsSurroundingWhitespace() {
        ChainEndpointOverrides.shared.set("  https://padded.example  ", for: .linea)
        XCTAssertEqual(ChainEndpointOverrides.shared.url(for: .linea), "https://padded.example")
    }

    func test_clear_removesOnlyThatChain() {
        ChainEndpointOverrides.shared.set("https://poly.example", for: .polygon)
        ChainEndpointOverrides.shared.set("https://base.example", for: .base)
        ChainEndpointOverrides.shared.clear(.polygon)
        XCTAssertNil(ChainEndpointOverrides.shared.url(for: .polygon))
        XCTAssertEqual(ChainEndpointOverrides.shared.url(for: .base), "https://base.example")
    }

    func test_allChains_reportsExactlyTheOverriddenChains() {
        ChainEndpointOverrides.shared.set("https://poly.example", for: .polygon)
        ChainEndpointOverrides.shared.set("https://sol.example", for: .solana)
        XCTAssertEqual(ChainEndpointOverrides.shared.allChains(), [.polygon, .solana])
    }

    /// Chains whose raw value contains spaces must survive the round trip
    /// through UserDefaults keys.
    func test_chainsWithSpacesInRawValue_roundTrip() {
        ChainEndpointOverrides.shared.set("https://bnb.example", for: .bnb)
        ChainEndpointOverrides.shared.reloadFromDisk()
        XCTAssertEqual(ChainEndpointOverrides.shared.url(for: .bnb), "https://bnb.example")
        XCTAssertEqual(ChainEndpointOverrides.shared.allChains(), [.bnb])
    }

    func test_overridesSurviveAReload() {
        ChainEndpointOverrides.shared.set("https://persisted.example", for: .scroll)
        ChainEndpointOverrides.shared.reloadFromDisk()
        XCTAssertEqual(ChainEndpointOverrides.shared.url(for: .scroll),
                       "https://persisted.example")
    }

    /// A key that no longer maps to a Chain (a renamed or removed case)
    /// must be ignored rather than crashing the settings list.
    func test_unknownStoredKeys_areIgnored() {
        UserDefaults.standard.set(["NotAChain": "https://ghost.example"],
                                  forKey: "com.horcrux.rpc.chainOverrides")
        ChainEndpointOverrides.shared.reloadFromDisk()
        XCTAssertTrue(ChainEndpointOverrides.shared.allChains().isEmpty)
    }
}
