import XCTest
@testable import Horcrux

/// Audit H8 follow-up — iOS-side smoke tests for the EIP-712 digest
/// FFI binding (`horcruxEip712Digest`). The Rust side has full unit
/// coverage in `horcrux-core/src/chain/evm.rs`; these tests exist to
/// prove the uniffi surface is reachable from Swift, that the hex
/// adapter for `verifyingContract` is forgiving (accepts both 0x
/// prefixed and bare hex), and that the Rust-side guards propagate
/// as Swift throws.
final class Eip712BindingTests: XCTestCase {

    private func validDomain(chainId: UInt64 = 1, verifyingContract: String = "0x0000000000000000000000000000000000000042") -> FfiEip712Domain {
        FfiEip712Domain(
            name: "TestApp",
            version: "1",
            chainId: chainId,
            verifyingContract: verifyingContract
        )
    }

    func testDeterministicDigest() throws {
        let domain = validDomain()
        let structHash = Data(repeating: 0xAB, count: 32)
        let d1 = try horcruxEip712Digest(domain: domain, structHash: structHash)
        let d2 = try horcruxEip712Digest(domain: domain, structHash: structHash)
        XCTAssertEqual(d1.count, 32)
        XCTAssertEqual(d1, d2, "same inputs must yield the same digest")
    }

    func testChainIdBinding() throws {
        // Replay-binding: changing the chain_id must change the digest.
        let structHash = Data(repeating: 0xCD, count: 32)
        let mainnet = try horcruxEip712Digest(domain: validDomain(chainId: 1), structHash: structHash)
        let polygon = try horcruxEip712Digest(domain: validDomain(chainId: 137), structHash: structHash)
        XCTAssertNotEqual(mainnet, polygon, "digest must differ across chain_ids")
    }

    func testVerifyingContractHexWithoutPrefix() throws {
        // The FFI adapter accepts both "0x..." and bare hex.
        let structHash = Data(repeating: 0x11, count: 32)
        let withPrefix = try horcruxEip712Digest(
            domain: validDomain(verifyingContract: "0x0000000000000000000000000000000000000042"),
            structHash: structHash
        )
        let without = try horcruxEip712Digest(
            domain: validDomain(verifyingContract: "0000000000000000000000000000000000000042"),
            structHash: structHash
        )
        XCTAssertEqual(withPrefix, without, "hex parsing must tolerate missing 0x prefix")
    }

    func testRejectsZeroChainId() {
        // chain_id=0 would allow cross-chain replay; Rust rejects.
        let structHash = Data(repeating: 0x00, count: 32)
        XCTAssertThrowsError(try horcruxEip712Digest(
            domain: validDomain(chainId: 0),
            structHash: structHash
        )) { error in
            XCTAssertTrue(String(describing: error).lowercased().contains("chain"),
                          "error should reference chain_id: \(error)")
        }
    }

    func testRejectsZeroVerifyingContract() {
        let structHash = Data(repeating: 0x00, count: 32)
        XCTAssertThrowsError(try horcruxEip712Digest(
            domain: validDomain(verifyingContract: "0x0000000000000000000000000000000000000000"),
            structHash: structHash
        )) { error in
            XCTAssertTrue(String(describing: error).lowercased().contains("verifying"),
                          "error should reference verifyingContract: \(error)")
        }
    }

    func testRejectsInvalidHex() {
        // Non-hex or wrong-length string must fail before reaching
        // the Rust guards — the FFI adapter should reject the input.
        let structHash = Data(repeating: 0x00, count: 32)
        XCTAssertThrowsError(try horcruxEip712Digest(
            domain: validDomain(verifyingContract: "not-a-real-hex-address"),
            structHash: structHash
        ))
    }

    func testStructHashBinding() throws {
        let domain = validDomain()
        let h1 = try horcruxEip712Digest(domain: domain, structHash: Data(repeating: 0x01, count: 32))
        let h2 = try horcruxEip712Digest(domain: domain, structHash: Data(repeating: 0x02, count: 32))
        XCTAssertNotEqual(h1, h2, "digest must differ across struct hashes")
    }
}
