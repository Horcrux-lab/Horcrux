import XCTest
@testable import Horcrux

/// Tests for `AddressFormatter` — EIP-55 checksum, chunked display, and
/// explorer URL construction.
final class AddressFormatterTests: XCTestCase {

    // MARK: - EIP-55

    /// Canonical vectors from EIP-55 spec
    /// https://eips.ethereum.org/EIPS/eip-55#test-cases
    func testEIP55_canonicalVectors() {
        let vectors = [
            "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed",
            "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359",
            "0xdbF03B407c01E7cD3CBea99509d93f8DDDC8C6FB",
            "0xD1220A0cf47c7B9Be7A2E6BA89F429762e7b9aDb",
        ]
        for checksummed in vectors {
            let roundtrip = AddressFormatter.eip55(checksummed.lowercased())
            XCTAssertEqual(roundtrip, checksummed, "EIP-55 vector failed for \(checksummed)")
        }
    }

    func testEIP55_isStableOnAlreadyChecksummed() {
        let addr = "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"
        XCTAssertEqual(AddressFormatter.eip55(addr), addr)
    }

    func testEIP55_returnsInputUnchangedForInvalidAddress() {
        XCTAssertEqual(AddressFormatter.eip55("not an address"), "not an address")
        XCTAssertEqual(AddressFormatter.eip55("0xGG"), "0xGG")
        // 0x + 40 non-hex: treated as invalid, returned unchanged.
        let bad = "0x" + String(repeating: "z", count: 40)
        XCTAssertEqual(AddressFormatter.eip55(bad), bad)
    }

    func testEIP55_rejectsMissingPrefix() {
        let naked = "5aaeb6053f3e94c9b9a09f33669435e7ef1beaed"
        // No 0x prefix → invalid, returned as-is.
        XCTAssertEqual(AddressFormatter.eip55(naked), naked)
    }

    func testEIP55_rejectsWrongLength() {
        XCTAssertEqual(AddressFormatter.eip55("0xabc"), "0xabc")
    }

    // MARK: - canonical(chain:)

    func testCanonical_appliesEIP55ForEVMChains() {
        let lowered = "0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed"
        XCTAssertEqual(AddressFormatter.canonical(lowered, chain: .ethereum),
                       "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed")
        XCTAssertEqual(AddressFormatter.canonical(lowered, chain: .polygon),
                       "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed")
    }

    func testCanonical_leavesNonEVMChainsAlone() {
        let btc = "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq"
        XCTAssertEqual(AddressFormatter.canonical(btc, chain: .bitcoin), btc)

        let sol = "DRpbCBMxVnDK7maPM5tGv6MvB3v1sRMC86PZ8okm21hy"
        XCTAssertEqual(AddressFormatter.canonical(sol, chain: .solana), sol)
    }

    // MARK: - chunked

    func testChunked_preservesZeroXPrefix() {
        let formatted = AddressFormatter.chunked("0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed")
        XCTAssertTrue(formatted.hasPrefix("0x5aAe "))
    }

    func testChunked_splitsIntoFourCharGroups() {
        let formatted = AddressFormatter.chunked("0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed")
        // 40 hex chars → 10 chunks of 4 + "0x" on the first.
        let groups = formatted.split(separator: " ")
        XCTAssertEqual(groups.count, 10)
        XCTAssertEqual(groups.first, "0x5aAe")
        XCTAssertEqual(groups.last, "eAed")
    }

    func testChunked_handlesNonPrefixedAddress() {
        // Bitcoin-style address, no 0x prefix.
        let out = AddressFormatter.chunked("bc1qar0srrr", chunkSize: 4)
        XCTAssertEqual(out, "bc1q ar0s rrr")
    }

    func testChunked_emptyInputReturnsEmpty() {
        XCTAssertEqual(AddressFormatter.chunked(""), "")
    }

    func testChunked_customChunkSize() {
        let out = AddressFormatter.chunked("0xabcdef0123", chunkSize: 2)
        XCTAssertEqual(out, "0xab cd ef 01 23")
    }

    // MARK: - Explorer URLs

    func testExplorerURL_etherscan() {
        let url = AddressFormatter.explorerURL(address: "0xabc", chain: .ethereum)
        XCTAssertEqual(url?.absoluteString, "https://etherscan.io/address/0xabc")
    }

    func testExplorerURL_coversEveryChain() {
        // Every Chain case must yield a non-nil URL so the UI never
        // offers an "Open in Explorer" button that dead-ends.
        for chain in Chain.allCases {
            XCTAssertNotNil(
                AddressFormatter.explorerURL(address: "someaddr", chain: chain),
                "explorerURL nil for \(chain)"
            )
        }
    }

    // MARK: - Tx explorer URLs

    func testTxExplorerURL_realEVMHashProducesURL() {
        // 0x + 64 hex chars → looks like a real tx hash.
        let hash = "0x" + String(repeating: "a", count: 64)
        let url = AddressFormatter.txExplorerURL(txHash: hash, chain: .ethereum)
        XCTAssertEqual(url?.absoluteString, "https://etherscan.io/tx/\(hash)")
    }

    func testTxExplorerURL_rejectsPreBroadcastPayloadForEVM() {
        // Long RLP hex that we temporarily stash pre-broadcast — must NOT
        // produce a (dead) explorer link.
        let preBroadcast = "0x" + String(repeating: "f", count: 500)
        XCTAssertNil(AddressFormatter.txExplorerURL(txHash: preBroadcast, chain: .ethereum))
    }

    func testTxExplorerURL_rejectsEVMHashWithoutZeroXPrefix() {
        let noPrefix = String(repeating: "a", count: 64)
        XCTAssertNil(AddressFormatter.txExplorerURL(txHash: noPrefix, chain: .ethereum))
    }

    func testTxExplorerURL_rejectsSolanaBase64Payload() {
        // Base64 contains '+', '/', '=' which aren't in base58 — must be rejected.
        let base64Stash = "somebase64payload=="
        XCTAssertNil(AddressFormatter.txExplorerURL(txHash: base64Stash, chain: .solana))
    }

    func testTxExplorerURL_acceptsSolanaBase58Signature() {
        // Realistic 88-char base58 signature.
        let sig = "5VERv8NMvzbJMEkV8xnrLkEaWRtSz9CosKDYjCJjBRnbJLgp8uirBgmQpjKhoR4tjF3ZpRzrFmBV6UjKdiSZkQUW"
        let url = AddressFormatter.txExplorerURL(txHash: sig, chain: .solana)
        XCTAssertEqual(url?.absoluteString, "https://solscan.io/tx/\(sig)")
    }
}
