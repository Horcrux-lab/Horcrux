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

    /// A 400 is the node telling us the transaction itself is bad. Every
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

    /// The limit of the rule above. 404 does not mean "your transaction is
    /// invalid", it means "this host does not serve `POST /tx`" — an
    /// endpoint fault, and the one failover exists for.
    ///
    /// Reachable because a per-chain override is stored with no URL-shape
    /// validation: an override that omits the `/api` suffix 404s here while
    /// balances and the UTXO fetch route through the generic classifier,
    /// which calls 404 transient, fail over, and keep working. Classifying
    /// it as a verdict leaves the wallet showing balances, building
    /// transactions, and silently unable to send.
    func test_btcBroadcast_failsOverWhenTheEndpointDoesNotServeTheRoute() async throws {
        let deadHost = host(primary)
        MockURLProtocol.handler = { [weak self] request in
            guard let self, let url = request.url else { throw URLError(.badURL) }
            if url.host == deadHost {
                return (self.response(url, 404), Data("endpoint does not exist".utf8))
            }
            return (self.response(url, 200), Data("txid-from-fallback".utf8))
        }

        let txid = try await service.btcBroadcast(
            signedTxHex: "0200000001aa",
            chain: .bitcoin,
            config: config
        )

        XCTAssertEqual(txid, "txid-from-fallback")
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
        // The mock answers 200 for every host, so counting UTXOs alone would
        // pass even if the Litecoin call had routed to Bitcoin's endpoints.
        let ltcHosts = Set(RPCFallbacks.resolvedAttempts(for: .litecoin, config: config)
            .map { host($0) })
        for url in MockURLProtocol.requested {
            XCTAssertTrue(ltcHosts.contains(host(url)),
                          "\(url) is not a Litecoin endpoint")
        }
        XCTAssertFalse(MockURLProtocol.requested.isEmpty)
    }

    // MARK: - Fee estimate

    /// The fee estimate is the third call the signing path makes, after the
    /// UTXO fetch and before the broadcast, and it was the one left on the
    /// single primary URL.
    ///
    /// That was survivable while `btcUtxos` also used the primary: the UTXO
    /// fetch threw first and the whole build aborted. Once the UTXO fetch
    /// and the broadcast fail over and the fee estimate does not, a dead
    /// primary stops blocking the send and starts silently pricing it at the
    /// 2 sat/vB floor instead — the transaction is built, signed and
    /// broadcast, and the builder writes nSequence 0xFFFF_FFFE, so it is not
    /// even BIP125-replaceable.
    ///
    /// The primary here is a self-hosted Esplora rather than the shipped
    /// default, because that is the configuration where failing over
    /// actually buys redundancy: `btcFeeEstimate(apiURL:)` redirects
    /// blockstream to mempool.space for fees, so on the shipped table both
    /// attempts reach the same host. A user on their own node is exactly
    /// who a dead primary strands.
    func test_btcFeeEstimate_failsOverToTheNextEndpointWhenThePrimaryIsUnreachable() async throws {
        let ownNode = "https://my-esplora.example/api"
        ChainEndpointOverrides.shared.set(ownNode, for: .bitcoin)
        defer { ChainEndpointOverrides.shared.clear(.bitcoin) }

        MockURLProtocol.handler = { [weak self] request in
            guard let self, let url = request.url else { throw URLError(.badURL) }
            if url.host == "my-esplora.example" { throw URLError(.cannotConnectToHost) }
            return (self.response(url, 200),
                    Data(#"{"fastestFee":40,"halfHourFee":25,"hourFee":12,"minimumFee":2}"#.utf8))
        }

        let rates = try await service.btcFeeEstimate(chain: .bitcoin, config: config)

        XCTAssertEqual(rates.halfHourFee, 25)
        XCTAssertEqual(rates.fastestFee, 40)
        XCTAssertTrue(
            MockURLProtocol.requested.contains { self.host($0) == "my-esplora.example" },
            "the configured primary must be tried first"
        )
        XCTAssertTrue(
            MockURLProtocol.requested.contains { self.host($0) != "my-esplora.example" },
            "no fallback endpoint was ever asked for a fee rate"
        )
    }

    /// And when nothing answers it must throw, not quietly return a floor
    /// rate that no endpoint actually quoted.
    func test_btcFeeEstimate_throwsWhenNoEndpointAnswers() async {
        MockURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }

        do {
            let rates = try await service.btcFeeEstimate(chain: .bitcoin, config: config)
            XCTFail("expected a throw, got \(rates)")
        } catch {
            // Expected.
        }
    }

    // MARK: - Transaction fetch (issue #32)

    /// Trimmed to the shape Esplora actually serves, including the
    /// `prevout` block that carries the value being spent.
    private func txJSON() -> Data {
        Data("""
        {"txid":"5cacc97a0b8be80536b1cfc42ab244566c5d96c7d15eb81f5ebfad80cb074a35",
         "version":2,"locktime":0,
         "vin":[{"txid":"4b26c85b0000000000000000000000000000000000000000000000000000cafe",
                 "vout":1,
                 "prevout":{"scriptpubkey":"0014751e76e819916d454941c45d1b3a323f1433bd6e",
                            "scriptpubkey_address":"bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4",
                            "value":8687044},
                 "scriptsig":"","is_coinbase":false,"sequence":4294967293}],
         "vout":[{"scriptpubkey":"0014ab","value":8000000}],
         "size":222,"weight":561,"fee":1410,
         "status":{"confirmed":false}}
        """.utf8)
    }

    /// Rebuilding an RBF replacement needs the original's own outpoints;
    /// #32 was that the app never asked for them at all.
    func test_btcTx_decodesTheOutpointsValueAndFee() async throws {
        MockURLProtocol.handler = { [weak self] request in
            guard let self, let url = request.url else { throw URLError(.badURL) }
            return (self.response(url, 200), self.txJSON())
        }

        let tx = try await service.btcTx(
            txid: "5cacc97a0b8be80536b1cfc42ab244566c5d96c7d15eb81f5ebfad80cb074a35",
            chain: .bitcoin, config: config)

        XCTAssertEqual(tx.vin.count, 1)
        XCTAssertEqual(tx.vin[0].vout, 1)
        XCTAssertEqual(tx.vin[0].prevout?.value, 8_687_044)
        XCTAssertEqual(tx.vin[0].prevout?.scriptpubkey,
                       "0014751e76e819916d454941c45d1b3a323f1433bd6e")
        XCTAssertEqual(tx.vin[0].sequence, 4_294_967_293)
        XCTAssertEqual(tx.fee, 1_410)
        XCTAssertFalse(tx.status.confirmed)
    }

    /// The fetch sits on the signing path, so a dead primary must not be
    /// able to stop a stuck transaction from being replaced.
    func test_btcTx_failsOverToTheNextEndpointWhenThePrimaryIsUnreachable() async throws {
        primaryUnreachable(fallbackBody: txJSON)

        let tx = try await service.btcTx(
            txid: "5cacc97a0b8be80536b1cfc42ab244566c5d96c7d15eb81f5ebfad80cb074a35",
            chain: .bitcoin, config: config)

        XCTAssertEqual(tx.fee, 1_410)
        XCTAssertTrue(
            MockURLProtocol.requested.contains { self.host($0) == self.host(self.fallback) },
            "the fallback endpoint was never contacted"
        )
    }

    /// The txid is interpolated straight into the request path. A value
    /// carrying `/` or `?` would address a different resource entirely.
    func test_btcTx_rejectsATxidThatIsNotPlainHex() async {
        MockURLProtocol.handler = { [weak self] request in
            guard let self, let url = request.url else { throw URLError(.badURL) }
            return (self.response(url, 200), self.txJSON())
        }

        for bad in ["../address/bc1qxxx/utxo", "abc?x=1", "zz".repeated(32), "aa", ""] {
            do {
                _ = try await service.btcTx(txid: bad, chain: .bitcoin, config: config)
                XCTFail("txid \(bad.debugDescription) should have been rejected")
            } catch {
                // Expected.
            }
        }
        XCTAssertTrue(MockURLProtocol.requested.isEmpty,
                      "a malformed txid must never reach the network")
    }
}

private extension String {
    func repeated(_ n: Int) -> String { String(repeating: self, count: n) }
}
