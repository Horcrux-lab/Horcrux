import Foundation

/// Minimal Bech32 / Bech32m decoder — enough to extract the witness program
/// from a P2WPKH (v0) segwit address. Used by the BTC signer to convert
/// recipient addresses into scriptPubKey bytes without another FFI
/// round-trip. Encoding stays on the Rust side (`horcrux_btc_address`).
enum Bech32 {
    private static let charset: [Character] = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")

    /// BIP-173 caps an address at 90 characters so the checksum's
    /// guaranteed error-detection properties hold.
    private static let maxLength = 90

    /// Which checksum constant an address verified against. BIP-350 splits
    /// these by witness version: v0 must be bech32, v1 and up bech32m.
    enum Encoding {
        case bech32
        case bech32m

        fileprivate var constant: UInt32 {
            switch self {
            case .bech32: return 1
            case .bech32m: return 0x2BC8_30A3
            }
        }
    }

    /// Decode a bech32/bech32m string into its hrp, its 5-bit data payload
    /// with the checksum removed, and the constant that verified.
    ///
    /// **The checksum is verified.** It did not used to be: this function
    /// deferred to `AddressValidator`, `AddressValidator` checked only the
    /// prefix, length and alphabet, and so nothing in the app ever ran the
    /// polymod. A single mistyped character in a recipient address — say
    /// `bc1qw508…` entered as `bc1qq508…` — kept the right length and
    /// alphabet, decoded to a *different* 20-byte witness program, and was
    /// paid. Detecting exactly that is what the checksum is for.
    static func decode(_ input: String) -> (hrp: String, data: [UInt8], encoding: Encoding)? {
        guard input.count <= maxLength else { return nil }

        // The checksum is defined over a single case. Accepting a mixture
        // would mean verifying a string the user did not type.
        let hasLower = input.contains { $0.isLowercase }
        let hasUpper = input.contains { $0.isUppercase }
        guard !(hasLower && hasUpper) else { return nil }

        let s = input.lowercased()
        guard let sep = s.lastIndex(of: "1") else { return nil }
        let hrp = String(s[s.startIndex..<sep])
        let tail = s[s.index(after: sep)...]
        guard tail.count >= 6, !hrp.isEmpty else { return nil }
        guard hrp.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }) else {
            return nil
        }

        var values: [UInt8] = []
        values.reserveCapacity(tail.count)
        for c in tail {
            guard let idx = charset.firstIndex(of: c) else { return nil }
            values.append(UInt8(idx))
        }

        let checksum = polymod(hrpExpand(hrp) + values.map(Int.init))
        guard let encoding = [Encoding.bech32, .bech32m].first(where: {
            $0.constant == checksum
        }) else { return nil }

        return (hrp, Array(values.dropLast(6)), encoding)
    }

    /// Decode any segwit address into its version and witness program,
    /// applying BIP-173 and BIP-350 in full.
    ///
    /// The version and the checksum constant are not independent: v0 must
    /// carry a bech32 checksum, v1 and above a bech32m one. Verifying the
    /// checksum without that pairing accepts strings no other wallet reads
    /// the same way, so both rules live here and every caller goes through
    /// this one door.
    static func decodeSegwit(_ addr: String) -> (hrp: String, version: UInt8, program: [UInt8])? {
        guard let (hrp, data, encoding) = decode(addr), let version = data.first else {
            return nil
        }
        guard version <= 16 else { return nil }
        guard encoding == (version == 0 ? .bech32 : .bech32m) else { return nil }
        guard let program = convertBits(Array(data.dropFirst()), from: 5, to: 8, pad: false),
              (2...40).contains(program.count) else { return nil }
        // v0 is only ever P2WPKH (20) or P2WSH (32).
        if version == 0, program.count != 20, program.count != 32 { return nil }
        return (hrp, version, program)
    }

    /// Decode a segwit v0 P2WPKH address into its 20-byte witness program
    /// (== HASH160 of the pubkey). Returns nil for any other version,
    /// program length, or checksum variant.
    static func decodeP2WPKH(_ addr: String) -> (hrp: String, program: [UInt8])? {
        guard let (hrp, version, program) = decodeSegwit(addr),
              version == 0, program.count == 20 else { return nil }
        return (hrp, program)
    }

    /// Build the 22-byte P2WPKH scriptPubKey (OP_0 PUSH20 <hash160>) for a bech32 v0 address.
    static func p2wpkhScriptPubkey(for addr: String) -> Data? {
        guard let (_, program) = decodeP2WPKH(addr) else { return nil }
        return Data([0x00, 0x14]) + Data(program)
    }

    // MARK: - BIP-173 checksum

    private static func polymod(_ values: [Int]) -> UInt32 {
        let generator: [UInt32] = [0x3B6A_57B2, 0x2650_8E6D, 0x1EA1_19FA, 0x3D42_33DD, 0x2A14_62B3]
        var chk: UInt32 = 1
        for value in values {
            let top = chk >> 25
            chk = (chk & 0x1FF_FFFF) << 5 ^ UInt32(value)
            for i in 0..<5 where (top >> i) & 1 == 1 {
                chk ^= generator[i]
            }
        }
        return chk
    }

    private static func hrpExpand(_ hrp: String) -> [Int] {
        let scalars = hrp.unicodeScalars.map { Int($0.value) }
        return scalars.map { $0 >> 5 } + [0] + scalars.map { $0 & 31 }
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
