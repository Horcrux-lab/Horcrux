//
// EvmSigner.swift
// Horcrux
//
// RLP encoding + EIP-1559 signed transaction assembly.
//
// Rust ships an unsigned EIP-1559 envelope:
//   raw_data = 0x02 || RLP([chain_id, nonce, maxPriorityFeePerGas,
//                           maxFeePerGas, gasLimit, to, value, data, accessList])
//
// After MPC produces (r, s, y_parity), the signed tx is:
//   0x02 || RLP([...same 9 items..., y_parity, r, s])
//
// This file keeps the transformation in pure Swift so we don't need a Rust
// rebuild. Kept deliberately minimal — only what this project needs.
//

import Foundation

enum EvmSigner {

    /// Assemble a broadcast-ready EIP-1559 signed transaction from the Rust
    /// unsigned envelope and the MPC signature components.
    ///
    /// - Parameters:
    ///   - rawUnsigned: The `raw_data` returned by `horcruxBuildEvmTransaction`
    ///     (i.e. `0x02 || RLP([9 items])`).
    ///   - r: 32-byte signature r.
    ///   - s: 32-byte signature s.
    ///   - yParity: 0 or 1. Comes from `FfiSignatureResult.recoveryId`.
    /// - Returns: `0x`-prefixed hex suitable for `eth_sendRawTransaction`.
    static func assembleSignedTx(rawUnsigned: Data, r: Data, s: Data, yParity: UInt8) throws -> String {
        guard let first = rawUnsigned.first, first == 0x02 else {
            throw EvmSignerError.notTypedEnvelope
        }
        let outer = rawUnsigned.dropFirst()
        // Decode the outer RLP list header to get the inner payload bytes
        // (all 9 already-encoded items) — we re-wrap unchanged.
        guard let header = decodeListHeader(outer) else {
            throw EvmSignerError.malformedRlp
        }
        let payloadStart = outer.startIndex + header.headerLen
        let payloadEnd = payloadStart + header.payloadLen
        guard payloadEnd <= outer.endIndex else { throw EvmSignerError.malformedRlp }
        let innerItems = outer[payloadStart..<payloadEnd]

        // Sig items — canonical RLP (integer, big-endian, no leading zeros).
        var sigItems = Data()
        sigItems.append(rlpInteger(yParity == 0 ? Data() : Data([yParity])))
        sigItems.append(rlpInteger(trimLeadingZeros(r)))
        sigItems.append(rlpInteger(trimLeadingZeros(s)))

        let newPayload = Data(innerItems) + sigItems
        let newList = encodeListHeader(newPayload.count) + newPayload

        var signed = Data([0x02])
        signed.append(newList)
        return "0x" + signed.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - RLP primitives

    /// Encode an integer value (already as big-endian bytes with no leading
    /// zeros — `0` is the empty byte string).
    static func rlpInteger(_ bytes: Data) -> Data {
        if bytes.isEmpty { return Data([0x80]) }
        if bytes.count == 1, bytes[0] < 0x80 { return bytes }
        return encodeLengthPrefix(length: bytes.count, offset: 0x80) + bytes
    }

    /// RLP "list header": length prefix that precedes the concatenated items.
    static func encodeListHeader(_ length: Int) -> Data {
        return encodeLengthPrefix(length: length, offset: 0xc0)
    }

    /// Shared length-prefix encoder: short form for < 56, long form otherwise.
    private static func encodeLengthPrefix(length: Int, offset: UInt8) -> Data {
        if length < 56 {
            return Data([offset + UInt8(length)])
        }
        let lenBytes = bigEndianBytes(UInt64(length))
        var out = Data([offset + 55 + UInt8(lenBytes.count)])
        out.append(lenBytes)
        return out
    }

    private static func bigEndianBytes(_ value: UInt64) -> Data {
        var v = value
        var buf = Data()
        while v > 0 {
            buf.insert(UInt8(v & 0xff), at: 0)
            v >>= 8
        }
        return buf.isEmpty ? Data([0]) : buf
    }

    private static func trimLeadingZeros(_ d: Data) -> Data {
        var i = d.startIndex
        while i < d.endIndex && d[i] == 0 { i = d.index(after: i) }
        return Data(d[i..<d.endIndex])
    }

    /// Decode an RLP list header at the start of `d`. Returns the header
    /// length (bytes consumed) and the payload length.
    private static func decodeListHeader(_ d: Data) -> (headerLen: Int, payloadLen: Int)? {
        guard let first = d.first else { return nil }
        if first >= 0xc0 && first <= 0xf7 {
            return (1, Int(first - 0xc0))
        }
        if first >= 0xf8 {
            let lenOfLen = Int(first - 0xf7)
            guard d.count >= 1 + lenOfLen else { return nil }
            var payloadLen = 0
            for i in 0..<lenOfLen {
                payloadLen = (payloadLen << 8) | Int(d[d.index(d.startIndex, offsetBy: 1 + i)])
            }
            return (1 + lenOfLen, payloadLen)
        }
        return nil
    }
}

enum EvmSignerError: Error {
    case notTypedEnvelope
    case malformedRlp
}
