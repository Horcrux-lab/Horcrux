import XCTest
@testable import Horcrux

/// Fault-aware routing for the Bitcoin signing and broadcast paths.
///
/// Context: on 2026-07-31 `blockstream.info` went dark globally — dead at
/// the TCP layer, the website as well as the API, from three independent
/// vantage points. It is the *first* entry in the Bitcoin fallback table,
/// with `mempool.space` behind it, so the app should have shrugged it off.
/// Two paths did: `balance(for:config:)` routes through `withFallbackURL`,
/// and `TransactionConfirmationPoller.checkBtcConfirmation` walks
/// `resolvedAttempts`. Two did not — `btcUtxos` and `btcBroadcast` were
/// called with a single URL — and because the UTXO fetch is the first call
/// in `buildP2WPKHSignHash`, the user-visible effect was that balances kept
/// displaying while Bitcoin could not be sent at all.
///
/// Deliberately offline: every request is served by `MockURLProtocol`,
/// keyed on host so a test can make one endpoint dead and another healthy.
final class BitcoinFailoverTests: XCTestCase {

    private final class MockURLProtocol: URLProtocol {
        nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
        /// Every URL requested, in order, so a test can assert that a second
        /// endpoint was — or was not — contacted.
        nonisolated(unsafe) static var requested: [String] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.requested.append(request.url?.absoluteString ?? "")
            guard let handler = Self.handler else {
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    private var service: BlockchainService!
    private var config: NetworkConfig!

    /// The dead primary and the healthy fallback, taken from the shipped
    /// table rather than hard-coded, so this suite follows the table if it
    /// is ever re-ordered.
    private var primary: String!
    private var fallback: String!

    override func setUp() {
        super.setUp()
        RPCEndpointHealth.resetForTests()
        NetworkConfig.shared.resetToDefaults()
        config = NetworkConfig.shared

        MockURLProtocol.handler = nil
        MockURLProtocol.requested = []
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        service = BlockchainService(session: URLSession(configuration: sessionConfig))

        let attempts = RPCFallbacks.resolvedAttempts(for: .bitcoin, config: config)
        XCTAssertGreaterThanOrEqual(
            attempts.count, 2,
            "Bitcoin must ship more than one endpoint or there is nothing to fail over to"
        )
        primary = attempts[0]
        fallback = attempts[1]
        XCTAssertNotEqual(primary, fallback)
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        MockURLProtocol.requested = []
        RPCEndpointHealth.resetForTests()
        NetworkConfig.shared.resetToDefaults()
        service = nil
        config = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func host(_ urlString: String) -> String {
        URL(string: urlString)?.host ?? urlString
    }

    private func response(_ url: URL, _ code: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
    }

    /// The live failure mode: the primary host does not accept a connection,
    /// while the fallback answers normally.
    private func primaryUnreachable(fallbackBody: @escaping () -> Data) {
        let deadHost = host(primary)
        MockURLProtocol.handler = { [weak self] request in
            guard let self, let url = request.url else { throw URLError(.badURL) }
            if url.host == deadHost {
                throw URLError(.cannotConnectToHost)
            }
            return (self.response(url, 200), fallbackBody())
        }
    }

    private func utxoJSON() -> Data {
        Data("""
        [{"txid":"aa","vout":0,"value":100000,"status":{"confirmed":true}}]
        """.utf8)
    }

    // MARK: - UTXO fetch

    /// The call that currently makes it impossible to build a transaction
    /// while the primary is down.
    func test_btcUtxos_failsOverToTheNextEndpointWhenThePrimaryIsUnreachable() async throws {
        primaryUnreachable(fallbackBody: utxoJSON)

        let utxos = try await service.btcUtxos(
            address: "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq",
            chain: .bitcoin,
            config: config
        )

        XCTAssertEqual(utxos.count, 1)
        XCTAssertEqual(utxos[0].value, 100_000)
        XCTAssertTrue(
            MockURLProtocol.requested.contains { self.host($0) == self.host(self.fallback) },
            "the fallback endpoint was never contacted"
        )
    }

    /// Failing over is only half of it — the router has to learn, or every
    /// later call pays the same timeout again.
    func test_btcUtxos_recordsHealthSoTheDeadPrimaryStopsBeingTriedFirst() async throws {
        primaryUnreachable(fallbackBody: utxoJSON)

        _ = try await service.btcUtxos(
            address: "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq",
            chain: .bitcoin,
            config: config
        )

        XCTAssertTrue(RPCEndpointHealth.isCoolingDown(primary),
                      "an unreachable endpoint should be cooling down")
        XCTAssertEqual(RPCEndpointHealth.tier(fallback), 0,
                       "the endpoint that answered should rank as healthy")
    }

    /// With nothing reachable the error must surface rather than resolving
    /// to an empty UTXO set, which the signing path would read as "no funds".
    func test_btcUtxos_throwsWhenEveryEndpointIsUnreachable() async {
        MockURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }

        do {
            let utxos = try await service.btcUtxos(
                address: "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq",
                chain: .bitcoin,
                config: config
            )
            XCTFail("expected a throw, got \(utxos.count) utxos")
        } catch {
            // Expected.
        }
    }

    // MARK: - Broadcast

    func test_btcBroadcast_failsOverToTheNextEndpointWhenThePrimaryIsUnreachable() async throws {
        primaryUnreachable(fallbackBody: { Data("txid-from-fallback".utf8) })

        let txid = try await service.btcBroadcast(
            signedTxHex: "0200000001aa",
            chain: .bitcoin,
            config: config
        )

        XCTAssertEqual(txid, "txid-from-fallback")
    }

    /// A 4xx is the node telling us the transaction itself is bad. Every
    /// other node will say the same, so failing over just re-submits a
    /// known-invalid transaction around the table.
    func test_btcBroadcast_doesNotFailOverWhenTheNodeRejectsTheTransaction() async {
        MockURLProtocol.handler = { [weak self] request in
            guard let self, let url = request.url else { throw URLError(.badURL) }
            return (self.response(url, 400), Data("bad-txns-inputs-missingorspent".utf8))
        }

        do {
            let txid = try await service.btcBroadcast(
                signedTxHex: "0200000001aa",
                chain: .bitcoin,
                config: config
            )
            XCTFail("expected a throw, got \(txid)")
        } catch {
            // Expected.
        }

        XCTAssertEqual(
            MockURLProtocol.requested.count, 1,
            "a rejected transaction must not be re-submitted to other endpoints; "
                + "requested: \(MockURLProtocol.requested)"
        )
    }

    /// The reason the case above matters beyond wasted requests:
    /// `RPCEndpointHealth` is shared with balance fetches and confirmation
    /// polling, so marking healthy endpoints dead over one bad transaction
    /// would degrade routing for everything else in the app.
    func test_btcBroadcast_rejectionDoesNotMarkTheEndpointUnhealthy() async {
        MockURLProtocol.handler = { [weak self] request in
            guard let self, let url = request.url else { throw URLError(.badURL) }
            return (self.response(url, 400), Data("bad-txns-inputs-missingorspent".utf8))
        }

        _ = try? await service.btcBroadcast(
            signedTxHex: "0200000001aa",
            chain: .bitcoin,
            config: config
        )

        XCTAssertFalse(RPCEndpointHealth.isCoolingDown(primary),
                       "the endpoint answered correctly — the transaction was the problem")
        XCTAssertNotEqual(RPCEndpointHealth.tier(primary), 2,
                          "a rejected transaction must not count against the endpoint's health")
    }

    /// 401/403 is about our credentials, not the transaction, so the next
    /// endpoint is worth trying — matching the EVM broadcast policy.
    func test_btcBroadcast_failsOverWhenThePrimaryRejectsOurCredentials() async throws {
        let deadHost = host(primary)
        MockURLProtocol.handler = { [weak self] request in
            guard let self, let url = request.url else { throw URLError(.badURL) }
            if url.host == deadHost {
                return (self.response(url, 401), Data())
            }
            return (self.response(url, 200), Data("txid-from-fallback".utf8))
        }

        let txid = try await service.btcBroadcast(
            signedTxHex: "0200000001aa",
            chain: .bitcoin,
            config: config
        )

        XCTAssertEqual(txid, "txid-from-fallback")
        XCTAssertTrue(RPCEndpointHealth.isCoolingDown(primary))
    }

    func test_btcBroadcast_throwsWhenEveryEndpointIsUnreachable() async {
        MockURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }

        do {
            let txid = try await service.btcBroadcast(
                signedTxHex: "0200000001aa",
                chain: .bitcoin,
                config: config
            )
            XCTFail("expected a throw, got \(txid)")
        } catch {
            // Expected.
        }
    }

    /// Litecoin ships a single Esplora host, so the fault-aware overload has
    /// to degrade to "try the one endpoint" rather than throwing "no
    /// endpoints" or silently doing nothing.
    func test_btcUtxos_worksForAChainWithASingleEndpoint() async throws {
        MockURLProtocol.handler = { [weak self] request in
            guard let self, let url = request.url else { throw URLError(.badURL) }
            return (self.response(url, 200), self.utxoJSON())
        }

        let utxos = try await service.btcUtxos(
            address: "ltc1qar0srrr7xfkvy5l643lydnw9re59gtzzc5crhk",
            chain: .litecoin,
            config: config
        )

        XCTAssertEqual(utxos.count, 1)
    }
}
