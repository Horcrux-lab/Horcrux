import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Bitcoin (P2WPKH segwit) signing helpers that run entirely in Swift.
/// The Rust side computes BIP-143 sighashes and the unsigned tx skeleton;
/// after MPC signing we splice DER-encoded signatures + pubkey into the
/// witness to produce a broadcast-ready hex blob.
enum BtcSigner {
    enum BtcSignerError: Error, LocalizedError {
        case badSignatureLength
        case badPubkey
        case signatureCountMismatch
        case rawDataTooShort
        case decodeRecipient

        var errorDescription: String? {
            switch self {
            case .badSignatureLength: return "ECDSA signature must be 64 bytes (r||s)"
            case .badPubkey: return "Public key must be 33 (compressed) or 65 (uncompressed) bytes"
            case .signatureCountMismatch: return "signatures.count must match inputs.count"
            case .rawDataTooShort: return "Rust-built raw transaction is too short to splice"
            case .decodeRecipient: return "Could not decode recipient address as bech32 P2WPKH"
            }
        }
    }

    // secp256k1 curve order n
    private static let n = Data([
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE,
        0xBA, 0xAE, 0xDC, 0xE6, 0xAF, 0x48, 0xA0, 0x3B,
        0xBF, 0xD2, 0x5E, 0x8C, 0xD0, 0x36, 0x41, 0x41
    ])
    // n / 2
    private static let halfN = Data([
        0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0x5D, 0x57, 0x6E, 0x73, 0x57, 0xA4, 0x50, 0x1D,
        0xDF, 0xE9, 0x2F, 0x46, 0x68, 0x1B, 0x20, 0xA0
    ])

    // MARK: - Public API

    /// Compress a 65-byte uncompressed secp256k1 pubkey (0x04 || X || Y) to 33 bytes.
    /// If already 33 bytes, returned as-is.
    static func compressPubkey(_ pk: Data) -> Data {
        if pk.count == 33 { return pk }
        guard pk.count == 65, pk.first == 0x04 else { return pk }
        let x = pk.subdata(in: 1..<33)
        let yParity: UInt8 = (pk[64] & 0x01) == 0 ? 0x02 : 0x03
        return Data([yParity]) + x
    }

    /// DER-encode a raw 64-byte ECDSA signature (r||s), enforcing low-s per BIP-62.
    static func derEncodeECDSA(_ rs: Data) throws -> Data {
        guard rs.count == 64 else { throw BtcSignerError.badSignatureLength }
        let rBytes = rs.prefix(32)
        var sBytes = rs.suffix(32)
        if compareBE(Data(sBytes), halfN) > 0 {
            sBytes = Data(subtractBE(n, Data(sBytes)))
        }
        let r = normalizeBE(Data(rBytes))
        let s = normalizeBE(Data(sBytes))
        var body = Data()
        body.append(0x02); body.append(UInt8(r.count)); body.append(r)
        body.append(0x02); body.append(UInt8(s.count)); body.append(s)
        var out = Data([0x30, UInt8(body.count)])
        out.append(body)
        return out
    }

    /// Splice real witness data into a Rust-produced unsigned raw tx.
    ///
    /// Rust's `serialize_witness_tx` writes `N` zero bytes (one per input,
    /// denoting "0 witness items") right before the 4-byte locktime. We
    /// trim those `N` bytes and append the real witness sections in order,
    /// then re-append the locktime.
    static func assembleSignedTx(
        unsignedRawData: Data,
        inputCount: Int,
        signatures: [Data],
        compressedPubkey: Data
    ) throws -> Data {
        guard signatures.count == inputCount else { throw BtcSignerError.signatureCountMismatch }
        guard compressedPubkey.count == 33 else { throw BtcSignerError.badPubkey }
        guard unsignedRawData.count >= inputCount + 4 else { throw BtcSignerError.rawDataTooShort }

        // Last 4 bytes = locktime; `inputCount` bytes before that = empty witnesses
        let prefixEnd = unsignedRawData.count - inputCount - 4
        let locktime = unsignedRawData.suffix(4)
        var result = Data(unsignedRawData.prefix(prefixEnd))

        for sig in signatures {
            let der = try derEncodeECDSA(sig)
            var sigWithHashType = der
            sigWithHashType.append(0x01) // SIGHASH_ALL
            // witness item count (2: signature + pubkey)
            result.append(0x02)
            result.append(varint(UInt64(sigWithHashType.count)))
            result.append(sigWithHashType)
            result.append(varint(UInt64(compressedPubkey.count)))
            result.append(compressedPubkey)
        }

        result.append(contentsOf: locktime)
        return result
    }

    /// Lower-case hex encoding (no 0x prefix) — matches the `/tx` body format
    /// expected by Blockstream's broadcast endpoint.
    static func hexEncode(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - BE big-int helpers (32-byte fixed width)

    private static func compareBE(_ a: Data, _ b: Data) -> Int {
        let lhs = Array(a), rhs = Array(b)
        for i in 0..<32 {
            if lhs[i] < rhs[i] { return -1 }
            if lhs[i] > rhs[i] { return 1 }
        }
        return 0
    }

    private static func subtractBE(_ a: Data, _ b: Data) -> [UInt8] {
        let lhs = Array(a), rhs = Array(b)
        var out = [UInt8](repeating: 0, count: 32)
        var borrow: Int = 0
        for i in (0..<32).reversed() {
            let ai = Int(lhs[i])
            let bi = Int(rhs[i]) + borrow
            if ai >= bi {
                out[i] = UInt8(ai - bi); borrow = 0
            } else {
                out[i] = UInt8(ai + 256 - bi); borrow = 1
            }
        }
        return out
    }

    private static func normalizeBE(_ bytes: Data) -> Data {
        var b = Array(bytes)
        while b.count > 1 && b[0] == 0x00 { b.removeFirst() }
        if (b[0] & 0x80) != 0 { b.insert(0x00, at: 0) }
        return Data(b)
    }

    private static func varint(_ v: UInt64) -> Data {
        if v < 0xfd { return Data([UInt8(v)]) }
        if v <= 0xffff {
            return Data([0xfd, UInt8(v & 0xff), UInt8((v >> 8) & 0xff)])
        }
        if v <= 0xffff_ffff {
            return Data([
                0xfe,
                UInt8(v & 0xff),
                UInt8((v >> 8) & 0xff),
                UInt8((v >> 16) & 0xff),
                UInt8((v >> 24) & 0xff)
            ])
        }
        var r = Data([0xff])
        var x = v
        for _ in 0..<8 { r.append(UInt8(x & 0xff)); x >>= 8 }
        return r
    }
}
