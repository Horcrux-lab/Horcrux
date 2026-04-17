import CryptoKit
import Foundation

/// TRON mainnet address derivation.
///
/// Spec: `addr = Base58Check(0x41 || keccak256(uncompressedPubkey[1:])[12:])`
/// where `uncompressedPubkey` is the 65-byte SEC1 uncompressed form `04 || X || Y`.
///
/// Example derived address is 34 characters long and starts with `T`.
enum TronAddress {
    enum Error: Swift.Error, LocalizedError {
        case invalidPublicKeyLength(Int)

        var errorDescription: String? {
            switch self {
            case .invalidPublicKeyLength(let n):
                return "TRON expects a 65-byte uncompressed secp256k1 public key (got \(n))."
            }
        }
    }

    /// Derive the Base58Check address for the given uncompressed secp256k1 public key.
    static func derive(uncompressedPublicKey pubkey: Data) throws -> String {
        guard pubkey.count == 65, pubkey.first == 0x04 else {
            throw Error.invalidPublicKeyLength(pubkey.count)
        }
        // Keccak-256 of the X||Y coordinates (strip leading 0x04).
        let hash = horcruxKeccak256(data: pubkey.dropFirst())
        // Take the low 20 bytes and prepend the TRON mainnet prefix 0x41.
        var addrBytes = Data([0x41])
        addrBytes.append(hash.suffix(20))
        return base58Check(addrBytes)
    }

    /// Lightweight syntactic validation for a user-entered TRON address.
    /// - Starts with `T`
    /// - 34 characters long
    /// - Only contains Base58 characters
    /// Full checksum validation could be added later by round-tripping Base58Check.
    static func looksValid(_ address: String) -> Bool {
        guard address.count == 34, address.hasPrefix("T") else { return false }
        return address.unicodeScalars.allSatisfy { base58Alphabet.contains(Character($0)) }
    }

    // MARK: - Base58Check helpers

    private static let base58Alphabet: [Character] = Array(
        "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    )

    /// Double-SHA256 the payload, append the first 4 bytes as the checksum,
    /// then Base58-encode the whole blob.
    private static func base58Check(_ payload: Data) -> String {
        let first = SHA256.hash(data: payload)
        let second = SHA256.hash(data: Data(first))
        let checksum = Data(second).prefix(4)
        var buf = payload
        buf.append(checksum)
        return base58Encode(buf)
    }

    /// Standard Base58 encode. Preserves leading-zero bytes as leading '1's.
    private static func base58Encode(_ input: Data) -> String {
        guard !input.isEmpty else { return "" }

        // Count leading zero bytes.
        var zeros = 0
        for byte in input {
            if byte == 0 { zeros += 1 } else { break }
        }

        // Convert to base-58 via big-int long division on a byte array.
        var digits: [UInt8] = [0]
        for byte in input {
            var carry = Int(byte)
            for i in 0..<digits.count {
                carry += Int(digits[i]) << 8
                digits[i] = UInt8(carry % 58)
                carry /= 58
            }
            while carry > 0 {
                digits.append(UInt8(carry % 58))
                carry /= 58
            }
        }

        var result = String(repeating: "1", count: zeros)
        for digit in digits.reversed() {
            result.append(base58Alphabet[Int(digit)])
        }
        return result
    }
}
