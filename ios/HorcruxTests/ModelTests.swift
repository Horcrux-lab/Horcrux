import XCTest
@testable import Horcrux

/// Tests for Chain model, Wallet model, and QR URI stripping.
final class ModelTests: XCTestCase {

    // MARK: - Chain

    func testChainSymbols() {
        XCTAssertEqual(Chain.ethereum.symbol, "ETH")
        XCTAssertEqual(Chain.bitcoin.symbol, "BTC")
        XCTAssertEqual(Chain.solana.symbol, "SOL")
    }

    func testChainCurveTypes() {
        XCTAssertEqual(Chain.ethereum.curveType, .secp256k1)
        XCTAssertEqual(Chain.bitcoin.curveType, .secp256k1)
        XCTAssertEqual(Chain.solana.curveType, .ed25519)
    }

    func testChainCaseIterable() {
        XCTAssertEqual(Chain.allCases.count, 11)
    }

    func testChainCodable() throws {
        let chain = Chain.ethereum
        let data = try JSONEncoder().encode(chain)
        let decoded = try JSONDecoder().decode(Chain.self, from: data)
        XCTAssertEqual(decoded, chain)
    }

    // MARK: - Wallet Codable

    func testWalletCodable() throws {
        let wallet = Wallet(
            id: "test-wallet",
            name: "My Wallet",
            chain: .bitcoin,
            address: "bc1qtest",
            groupPublicKey: Data([1, 2, 3]),
            threshold: 2,
            totalParties: 3,
            partyIndex: 0,
            createdAt: Date(timeIntervalSince1970: 1000000),
            isHidden: nil
        )
        let data = try JSONEncoder().encode(wallet)
        let decoded = try JSONDecoder().decode(Wallet.self, from: data)
        XCTAssertEqual(decoded.id, wallet.id)
        XCTAssertEqual(decoded.chain, Chain.bitcoin)
        XCTAssertEqual(decoded.threshold, 2)
        XCTAssertEqual(decoded.totalParties, 3)
        XCTAssertEqual(decoded.groupPublicKey, Data([1, 2, 3]))
    }

    // MARK: - TransactionRecord Codable

    func testTransactionRecordCodable() throws {
        let record = TransactionRecord(
            id: "tx-1",
            walletId: "w-1",
            chain: .solana,
            fromAddress: "from",
            toAddress: "to",
            amount: "1.5",
            fee: "0.000005 SOL",
            txHash: "sig123",
            status: .broadcast,
            createdAt: Date(timeIntervalSince1970: 2000000),
            broadcastAt: Date(timeIntervalSince1970: 2000060)
        )
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(TransactionRecord.self, from: data)
        XCTAssertEqual(decoded.id, "tx-1")
        XCTAssertEqual(decoded.status, .broadcast)
        XCTAssertEqual(decoded.chain, .solana)
        XCTAssertNotNil(decoded.broadcastAt)
    }

    // MARK: - QR URI Stripping

    func testStripEthereumPrefix() {
        let result = QRScannerViewController.stripURIPrefix("ethereum:0x742d35Cc6634C0532925a3b844Bc9e7595f2bD18")
        XCTAssertEqual(result, "0x742d35Cc6634C0532925a3b844Bc9e7595f2bD18")
    }

    func testStripBitcoinPrefix() {
        let result = QRScannerViewController.stripURIPrefix("bitcoin:bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4")
        XCTAssertEqual(result, "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4")
    }

    func testStripSolanaPrefix() {
        let result = QRScannerViewController.stripURIPrefix("solana:9noXzpXnkyEcKF3DkXFTEJLMu1bRNqsm5GCrNPB3Jkda")
        XCTAssertEqual(result, "9noXzpXnkyEcKF3DkXFTEJLMu1bRNqsm5GCrNPB3Jkda")
    }

    func testStripPrefixWithQueryParams() {
        let result = QRScannerViewController.stripURIPrefix("ethereum:0x1234567890abcdef1234567890abcdef12345678?amount=1.5&label=test")
        XCTAssertEqual(result, "0x1234567890abcdef1234567890abcdef12345678")
    }

    func testStripPrefixCaseInsensitive() {
        let result = QRScannerViewController.stripURIPrefix("BITCOIN:bc1qtest")
        XCTAssertEqual(result, "bc1qtest")
    }

    func testNoPrefix() {
        let result = QRScannerViewController.stripURIPrefix("0x742d35Cc6634C0532925a3b844Bc9e7595f2bD18")
        XCTAssertEqual(result, "0x742d35Cc6634C0532925a3b844Bc9e7595f2bD18")
    }

    func testEmptyString() {
        let result = QRScannerViewController.stripURIPrefix("")
        XCTAssertEqual(result, "")
    }

    // MARK: - TransactionRecord Status

    func testTransactionStatusIcons() {
        XCTAssertEqual(TransactionRecord.TxStatus.signed.rawValue, "signed")
        XCTAssertEqual(TransactionRecord.TxStatus.broadcast.rawValue, "broadcast")
        XCTAssertEqual(TransactionRecord.TxStatus.confirmed.rawValue, "confirmed")
        XCTAssertEqual(TransactionRecord.TxStatus.failed.rawValue, "failed")
    }

    // MARK: - Relay URL Validation

    func testValidWssURL() {
        XCTAssertNil(SettingsView.validateRelayURL("wss://relay.example.com/ws"))
    }

    func testLocalWsURLAllowed() {
        XCTAssertNil(SettingsView.validateRelayURL("ws://localhost:3000/ws"))
        XCTAssertNil(SettingsView.validateRelayURL("ws://127.0.0.1:3000/ws"))
    }

    func testRemoteWsURLWarns() {
        let warning = SettingsView.validateRelayURL("ws://relay.example.com/ws")
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning!.contains("wss://"))
    }

    func testInvalidScheme() {
        XCTAssertNotNil(SettingsView.validateRelayURL("http://example.com"))
    }

    func testInvalidURL() {
        XCTAssertNotNil(SettingsView.validateRelayURL("not a url"))
    }
}
