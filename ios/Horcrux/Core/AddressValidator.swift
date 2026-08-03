import Foundation

/// Validates blockchain addresses before use.
enum AddressValidator {

    enum ValidationError: LocalizedError {
        case empty
        case invalidEthAddress
        case invalidEthChecksum
        case invalidBtcAddress
        case invalidLtcAddress
        case invalidSolAddress
        case invalidTronAddress

        var errorDescription: String? {
            switch self {
            case .empty: return "Address is empty"
            case .invalidEthAddress: return "Invalid Ethereum address (expected 0x + 40 hex chars)"
            case .invalidEthChecksum:
                return "Invalid Ethereum address checksum — check the address for typos"
            case .invalidBtcAddress: return "Invalid Bitcoin address"
            case .invalidLtcAddress: return "Invalid Litecoin address"
            case .invalidSolAddress: return "Invalid Solana address (expected 32-44 base58 chars)"
            case .invalidTronAddress: return "Invalid TRON address (expected 34 chars starting with T)"
            }
        }
    }

    /// Validate address for the given chain. Throws on invalid.
    static func validate(_ address: String, chain: Chain) throws {
        guard !address.isEmpty else { throw ValidationError.empty }

        if chain.isEVM { try validateEthereum(address); return }
        switch chain {
        case .bitcoin:  try validateBitcoin(address)
        case .litecoin: try validateLitecoin(address)
        case .solana:   try validateSolana(address)
        case .tron:     try validateTron(address)
        default:        throw ValidationError.invalidEthAddress
        }
    }

    /// Returns nil if valid, or a user-facing error string.
    static func errorMessage(for address: String, chain: Chain) -> String? {
        do {
            try validate(address, chain: chain)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Ethereum

    private static func validateEthereum(_ address: String) throws {
        // Must start with 0x and be 42 characters total (0x + 40 hex).
        // `Character.isHexDigit` is also true for full-width forms such as
        // "Ａ", which are not hex to anything downstream, so restrict to
        // ASCII.
        let body = address.dropFirst(2)
        guard address.hasPrefix("0x"),
              address.count == 42,
              body.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw ValidationError.invalidEthAddress
        }
        // EIP-55 hides a checksum in the *case* of the letters. An address
        // written entirely in one case carries no checksum — the standard
        // permits that, and addresses predating it look exactly so — but a
        // mixed-case address is making a claim, and a mistyped one keeps
        // the prefix, the length and the hex alphabet, so the checksum is
        // the only thing that can refuse it.
        let hasUpper = body.contains { $0.isUppercase }
        let hasLower = body.contains { $0.isLowercase }
        guard hasUpper && hasLower else { return }
        guard String(body) == eip55Checksummed(String(body)) else {
            throw ValidationError.invalidEthChecksum
        }
    }

    /// EIP-55: uppercase the letter at position i exactly when nibble i of
    /// `keccak256(lowercased address)` is 8 or greater.
    private static func eip55Checksummed(_ body: String) -> String {
        let lower = body.lowercased()
        let hash = horcruxKeccak256(data: Data(lower.utf8))
        var out = ""
        out.reserveCapacity(lower.count)
        for (i, c) in lower.enumerated() {
            let byte = hash[hash.startIndex + i / 2]
            let nibble = i % 2 == 0 ? byte >> 4 : byte & 0x0f
            out.append(c.isLetter && nibble >= 8 ? Character(c.uppercased()) : c)
        }
        return out
    }

    // MARK: - Bitcoin

    private static let base58Chars = CharacterSet(charactersIn: "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")

    private static func validateBitcoin(_ address: String) throws {
        // Bech32 (v0) / Bech32m (v1+) — bc1… or tb1…
        if address.lowercased().hasPrefix("bc1") || address.lowercased().hasPrefix("tb1") {
            // The checksum, not the length and alphabet, is what catches a
            // mistyped address. Those two are satisfied by any typo that
            // keeps the shape, and such an address decodes cleanly to a
            // *different* witness program — a destination nobody holds the
            // key to. Verifying it here is what stops it being paid.
            guard Bech32.decodeSegwit(address) != nil else {
                throw ValidationError.invalidBtcAddress
            }
            return
        }

        // Legacy P2PKH (1...) or P2SH (3...)
        if address.hasPrefix("1") || address.hasPrefix("3") || address.hasPrefix("m") || address.hasPrefix("n") || address.hasPrefix("2") {
            // Base58Check's truncated double-SHA256 serves the same purpose
            // and has always been implemented; it was simply never called.
            guard let payload = Base58Check.decode(address),
                  payload.count == 21 else {
                throw ValidationError.invalidBtcAddress
            }
            return
        }

        throw ValidationError.invalidBtcAddress
    }

    // MARK: - Solana

    private static func validateSolana(_ address: String) throws {
        // Solana addresses are base58-encoded ed25519 public keys (32-44 chars)
        guard (32...44).contains(address.count),
              address.unicodeScalars.allSatisfy({ base58Chars.contains($0) }) else {
            throw ValidationError.invalidSolAddress
        }
    }

    // MARK: - Litecoin

    private static func validateLitecoin(_ address: String) throws {
        let lower = address.lowercased()
        // SegWit bech32 (ltc1... mainnet, tltc1... testnet)
        if lower.hasPrefix("ltc1") || lower.hasPrefix("tltc1") {
            guard Bech32.decodeSegwit(address) != nil else {
                throw ValidationError.invalidLtcAddress
            }
            return
        }
        // Legacy P2PKH (L...) / P2SH (M... or 3...)
        if address.hasPrefix("L") || address.hasPrefix("M") || address.hasPrefix("3") {
            guard let payload = Base58Check.decode(address),
                  payload.count == 21 else {
                throw ValidationError.invalidLtcAddress
            }
            return
        }
        throw ValidationError.invalidLtcAddress
    }

    // MARK: - TRON

    private static func validateTron(_ address: String) throws {
        guard TronAddress.looksValid(address) else {
            throw ValidationError.invalidTronAddress
        }
    }
}
