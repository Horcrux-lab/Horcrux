import Foundation

/// Utilities for formatting and verifying blockchain addresses for display.
enum AddressFormatter {

    // MARK: - EIP-55 checksum

    /// Applies EIP-55 mixed-case checksum to an Ethereum address.
    /// Returns the canonical checksummed form (e.g. `0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed`).
    /// If input is not a valid 40-hex address, returns input unchanged.
    static func eip55(_ address: String) -> String {
        let lower = address.lowercased()
        guard lower.hasPrefix("0x"), lower.count == 42,
              lower.dropFirst(2).allSatisfy({ $0.isHexDigit }) else {
            return address
        }
        let body = String(lower.dropFirst(2))
        let bytes = [UInt8](body.utf8)
        let hash = horcruxKeccak256(data: Data(bytes))
        // Expand hash bytes → hex chars (nibbles)
        let hashHex = hash.map { String(format: "%02x", $0) }.joined()
        var result = "0x"
        for (i, ch) in body.enumerated() {
            if ch.isLetter {
                let nibbleIndex = i // hashHex has 2 nibble per byte, index is same
                let hashChar = hashHex[hashHex.index(hashHex.startIndex, offsetBy: nibbleIndex)]
                if let n = Int(String(hashChar), radix: 16), n >= 8 {
                    result.append(ch.uppercased())
                } else {
                    result.append(ch)
                }
            } else {
                result.append(ch)
            }
        }
        return result
    }

    /// Return `address` formatted appropriately for the chain. All EVM chains use EIP-55.
    static func canonical(_ address: String, chain: Chain) -> String {
        if chain.isEVM { return eip55(address) }
        return address
    }

    // MARK: - Readable chunked display

    /// Break a long address into 4-char groups so the user can verify segments:
    /// `0x5aAe b605 3F3E 94C9 b9A0 9f33 6694 35E7 Ef1B eAed`.
    /// Keeps the `0x` prefix attached to the first chunk.
    static func chunked(_ address: String, chunkSize: Int = 4) -> String {
        guard !address.isEmpty else { return address }
        var body = address
        var prefix = ""
        if body.hasPrefix("0x") {
            prefix = "0x"
            body = String(body.dropFirst(2))
        }
        var chunks: [String] = []
        var index = body.startIndex
        while index < body.endIndex {
            let end = body.index(index, offsetBy: chunkSize, limitedBy: body.endIndex) ?? body.endIndex
            chunks.append(String(body[index..<end]))
            index = end
        }
        if prefix.isEmpty {
            return chunks.joined(separator: " ")
        } else {
            guard let first = chunks.first else { return prefix }
            return prefix + first + " " + chunks.dropFirst().joined(separator: " ")
        }
    }

    // MARK: - Explorer deep links

    static func explorerURL(address: String, chain: Chain) -> URL? {
        switch chain {
        case .ethereum:
            return URL(string: "https://etherscan.io/address/\(address)")
        case .bnb:
            return URL(string: "https://bscscan.com/address/\(address)")
        case .polygon:
            return URL(string: "https://polygonscan.com/address/\(address)")
        case .arbitrum:
            return URL(string: "https://arbiscan.io/address/\(address)")
        case .base:
            return URL(string: "https://basescan.org/address/\(address)")
        case .avalanche:
            return URL(string: "https://snowtrace.io/address/\(address)")
        case .optimism:
            return URL(string: "https://optimistic.etherscan.io/address/\(address)")
        case .zksync:
            return URL(string: "https://explorer.zksync.io/address/\(address)")
        case .linea:
            return URL(string: "https://lineascan.build/address/\(address)")
        case .scroll:
            return URL(string: "https://scrollscan.com/address/\(address)")
        case .bitcoin:
            return URL(string: "https://mempool.space/address/\(address)")
        case .litecoin:
            return URL(string: "https://litecoinspace.org/address/\(address)")
        case .solana:
            return URL(string: "https://solscan.io/account/\(address)")
        case .tron:
            return URL(string: "https://tronscan.org/#/address/\(address)")
        }
    }

    static func txExplorerURL(txHash: String, chain: Chain) -> URL? {
        // Only build an explorer URL when the stored txHash actually looks
        // like a final on-chain hash — in our flow we temporarily stash the
        // full signed payload (long RLP hex, long base64, etc.) in the same
        // field until broadcast succeeds, and linking that to an explorer
        // produces a dead link.
        guard looksLikeFinalTxHash(txHash, chain: chain) else { return nil }
        switch chain {
        case .ethereum:
            return URL(string: "https://etherscan.io/tx/\(txHash)")
        case .bnb:
            return URL(string: "https://bscscan.com/tx/\(txHash)")
        case .polygon:
            return URL(string: "https://polygonscan.com/tx/\(txHash)")
        case .arbitrum:
            return URL(string: "https://arbiscan.io/tx/\(txHash)")
        case .base:
            return URL(string: "https://basescan.org/tx/\(txHash)")
        case .avalanche:
            return URL(string: "https://snowtrace.io/tx/\(txHash)")
        case .optimism:
            return URL(string: "https://optimistic.etherscan.io/tx/\(txHash)")
        case .zksync:
            return URL(string: "https://explorer.zksync.io/tx/\(txHash)")
        case .linea:
            return URL(string: "https://lineascan.build/tx/\(txHash)")
        case .scroll:
            return URL(string: "https://scrollscan.com/tx/\(txHash)")
        case .bitcoin:
            return URL(string: "https://mempool.space/tx/\(txHash)")
        case .litecoin:
            return URL(string: "https://litecoinspace.org/tx/\(txHash)")
        case .solana:
            return URL(string: "https://solscan.io/tx/\(txHash)")
        case .tron:
            return URL(string: "https://tronscan.org/#/transaction/\(txHash)")
        }
    }

    /// Heuristic: does the string look like a real on-chain tx hash vs a
    /// pre-broadcast signed payload we've stashed in the same field?
    private static func looksLikeFinalTxHash(_ s: String, chain: Chain) -> Bool {
        if chain.isEVM {
            // 0x + 64 hex chars
            guard s.hasPrefix("0x") else { return false }
            let hex = s.dropFirst(2)
            return hex.count == 64 && hex.allSatisfy { $0.isHexDigit }
        }
        switch chain {
        case .bitcoin, .litecoin:
            return s.count == 64 && s.allSatisfy { $0.isHexDigit }
        case .solana:
            // Signature is 64 bytes → 87-88 chars base58 in practice.
            // Our pre-broadcast stash is base64 (contains + / =) and much longer.
            if s.count > 100 { return false }
            let base58 = Set("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
            return s.allSatisfy { base58.contains($0) }
        case .tron:
            return s.count == 64 && s.allSatisfy { $0.isHexDigit }
        default:
            return true
        }
    }
}
