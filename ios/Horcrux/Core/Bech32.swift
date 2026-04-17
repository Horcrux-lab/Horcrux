import Foundation

/// Minimal Bech32 / Bech32m decoder — enough to extract the witness program
/// from a P2WPKH (v0) or P2TR (v1) segwit address. Used by the BTC signer
/// to convert recipient addresses into scriptPubKey bytes without another
/// FFI round-trip. Encoding stays on the Rust side (`horcrux_btc_address`).
enum Bech32 {
    private static let charset: [Character] = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")

    /// Decode a bech32 address into (hrp, 5-bit data payload without the 6-char checksum).
    /// Checksum is NOT validated — call sites receive already-validated addresses
    /// from the user via `AddressValidator` / our own Rust encoder.
    static func decode(_ input: String) -> (hrp: String, data: [UInt8])? {
        let s = input.lowercased()
        guard let sep = s.lastIndex(of: "1") else { return nil }
        let hrp = String(s[s.startIndex..<sep])
        let tail = s[s.index(after: sep)...]
        guard tail.count >= 6, !hrp.isEmpty else { return nil }
        var values: [UInt8] = []
        values.reserveCapacity(tail.count)
        for c in tail {
            guard let idx = charset.firstIndex(of: c) else { return nil }
            values.append(UInt8(idx))
        }
        return (hrp, Array(values.dropLast(6)))
    }

    /// Decode a segwit v0 P2WPKH address into its 20-byte witness program (== HASH160 of the pubkey).
    /// Returns nil for v1 / non-segwit addresses.
    static func decodeP2WPKH(_ addr: String) -> (hrp: String, program: [UInt8])? {
        guard let (hrp, data) = decode(addr), !data.isEmpty else { return nil }
        let version = data[0]
        guard version == 0 else { return nil }
        guard let program = convertBits(Array(data.dropFirst()), from: 5, to: 8, pad: false),
              program.count == 20 else { return nil }
        return (hrp, program)
    }

    /// Build the 22-byte P2WPKH scriptPubKey (OP_0 PUSH20 <hash160>) for a bech32 v0 address.
    static func p2wpkhScriptPubkey(for addr: String) -> Data? {
        guard let (_, program) = decodeP2WPKH(addr) else { return nil }
        return Data([0x00, 0x14]) + Data(program)
    }

    private static func convertBits(_ data: [UInt8], from: Int, to: Int, pad: Bool) -> [UInt8]? {
        var acc = 0
        var bits = 0
        let maxv = (1 << to) - 1
        var result: [UInt8] = []
        for value in data {
            if value >> from != 0 { return nil }
            acc = (acc << from) | Int(value)
            bits += from
            while bits >= to {
                bits -= to
                result.append(UInt8((acc >> bits) & maxv))
            }
        }
        if pad {
            if bits > 0 { result.append(UInt8((acc << (to - bits)) & maxv)) }
        } else if bits >= from || ((acc << (to - bits)) & maxv) != 0 {
            return nil
        }
        return result
    }
}
