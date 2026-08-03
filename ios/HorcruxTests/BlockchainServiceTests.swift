import XCTest
@testable import Horcrux

/// Tests for BlockchainService — RPC calls, balance queries, error handling.
/// Uses a mock URLSession via URLProtocol to avoid real network calls.
final class BlockchainServiceTests: XCTestCase {

    // MARK: - Mock URL Protocol

    private final class MockURLProtocol: URLProtocol {
        nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
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

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        service = BlockchainService(session: session)
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        service = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func jsonRPCResponse(result: Any) -> Data {
        let body: [String: Any] = ["jsonrpc": "2.0", "id": 1, "result": result]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private func httpOK(url: URL = URL(string: "https://rpc.test")!) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }

    // MARK: - testFetchBalanceReturnsValue

    func testFetchBalanceReturnsValue() async throws {
        // 0x0de0b6b3a7640000 = 1 ETH in wei = 1000000000000000000
        MockURLProtocol.handler = { _ in
            let data = self.jsonRPCResponse(result: "0x0de0b6b3a7640000")
            return (self.httpOK(), data)
        }

        let balance = try await service.ethBalance(
            address: "0x742D35CC6634C0532925a3B844Bc9E7595F2bD18",
            rpcURL: "https://rpc.test"
        )
        // hexToDecimal converts to UInt64 decimal string
        let value = UInt64(balance) ?? 0
        XCTAssertGreaterThan(value, 0, "Balance should be a positive value")
    }

    // MARK: - testFetchBalanceInvalidAddressThrows

    func testFetchBalanceInvalidAddressThrows() async {
        // RPC returns an error for invalid address
        MockURLProtocol.handler = { _ in
            let body: [String: Any] = [
                "jsonrpc": "2.0", "id": 1,
                "error": ["code": -32602, "message": "invalid argument"]
            ]
            let data = try! JSONSerialization.data(withJSONObject: body)
            return (self.httpOK(), data)
        }

        do {
            _ = try await service.ethBalance(
                address: "0xINVALID",
                rpcURL: "https://rpc.test"
            )
            XCTFail("Should have thrown for RPC error")
        } catch {
            // Expect a BlockchainError.rpcError or emptyResult
            XCTAssertTrue(
                error is BlockchainError,
                "Expected BlockchainError, got \(type(of: error))"
            )
        }
    }

    // MARK: - testFetchTransactionsReturnsArray

    func testFetchTransactionsReturnsArray() async throws {
        // btcUtxos returns an array of BtcUtxo
        let utxoJSON: [[String: Any]] = [
            ["txid": "abc123", "vout": 0, "value": 50000, "status": ["confirmed": true]],
            ["txid": "def456", "vout": 1, "value": 30000, "status": ["confirmed": false]]
        ]
        MockURLProtocol.handler = { _ in
            let data = try! JSONSerialization.data(withJSONObject: utxoJSON)
            return (self.httpOK(), data)
        }

        let utxos = try await service.btcUtxos(
            address: "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4",
            apiURL: "https://blockstream.info/api"
        )
        XCTAssertEqual(utxos.count, 2, "Should return two UTXOs")
        XCTAssertEqual(utxos.first?.txid, "abc123")
        XCTAssertEqual(utxos.last?.value, 30000)
    }

    // MARK: - testFetchTokenBalanceERC20

    func testFetchTokenBalanceERC20() async throws {
        // ERC-20 balanceOf returns a hex-encoded uint256
        // 0x0000...00000f4240 = 1000000 (1 USDC with 6 decimals)
        let hexBalance = "0x00000000000000000000000000000000000000000000000000000000000f4240"
        MockURLProtocol.handler = { _ in
            let body: [String: Any] = ["jsonrpc": "2.0", "id": 1, "result": hexBalance]
            let data = try! JSONSerialization.data(withJSONObject: body)
            return (self.httpOK(), data)
        }

        let balance = try await service.erc20Balance(
            tokenContract: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
            ownerAddress: "0x742D35CC6634C0532925a3B844Bc9E7595F2bD18",
            rpcURL: "https://rpc.test"
        )
        XCTAssertEqual(balance, "1000000", "Should decode ERC-20 balance correctly")
    }

    // MARK: - testBroadcastTransactionWithEmptyDataThrows

    func testBroadcastTransactionWithEmptyDataThrows() async {
        // Server rejects empty TX payload with HTTP 400
        MockURLProtocol.handler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://blockstream.info/api/tx")!,
                statusCode: 400,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("sendrawtransaction: bad-txns".utf8))
        }

        do {
            _ = try await service.btcBroadcast(
                signedTxHex: "",
                apiURL: "https://blockstream.info/api"
            )
            XCTFail("Should have thrown for empty transaction data")
        } catch let error as BlockchainError {
            if case .httpError(let statusCode) = error {
                XCTAssertEqual(statusCode, 400)
            } else {
                // Other BlockchainError variants are acceptable
                XCTAssertNotNil(error.errorDescription)
            }
        } catch {
            // Any error is acceptable — empty TX should not succeed
            XCTAssertNotNil(error)
        }
    }

    // MARK: - testRPCTimeoutHandled

    func testRPCTimeoutHandled() async {
        // Simulate a network timeout error
        MockURLProtocol.handler = { _ in
            throw URLError(.timedOut)
        }

        do {
            _ = try await service.ethBalance(
                address: "0x742D35CC6634C0532925a3B844Bc9E7595F2bD18",
                rpcURL: "https://rpc.test"
            )
            XCTFail("Should have thrown a timeout error")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut, "Error should be a timeout")
        } catch {
            // Any thrown error means timeout was handled (not a crash)
            XCTAssertNotNil(error, "Timeout should produce an error, not a crash")
        }
    }

    // MARK: - BlockchainError descriptions

    func testBlockchainErrorDescriptions() {
        XCTAssertNotNil(BlockchainError.invalidAddress.errorDescription)
        XCTAssertNotNil(BlockchainError.emptyResult.errorDescription)
        XCTAssertNotNil(BlockchainError.invalidResponse.errorDescription)
        XCTAssertNotNil(BlockchainError.httpError(statusCode: 500).errorDescription)
        XCTAssertNotNil(BlockchainError.rpcError(code: -32600, message: "bad").errorDescription)
        XCTAssertNotNil(BlockchainError.invalidURL("bad://url").errorDescription)
    }

    // MARK: - Solana balance

    func testSolBalanceReturnsLamports() async throws {
        MockURLProtocol.handler = { _ in
            let body: [String: Any] = [
                "jsonrpc": "2.0", "id": 1,
                "result": ["value": 1_500_000_000]
            ]
            let data = try! JSONSerialization.data(withJSONObject: body)
            return (self.httpOK(), data)
        }

        let lamports = try await service.solBalance(
            address: "9noXzpXnkyEcKF3DkXFTEJLMu1bRNqsm5GCrNPB3Jkda",
            rpcURL: "https://rpc.test"
        )
        XCTAssertEqual(lamports, 1_500_000_000)
    }
}
