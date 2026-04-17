import Foundation

/// Validates blockchain addresses before use.
enum AddressValidator {

    enum ValidationError: LocalizedError {
        case empty
        case invalidEthAddress
        case invalidBtcAddress
        case invalidLtcAddress
        case invalidSolAddress
        case invalidTronAddress

        var errorDescription: String? {
            switch self {
            case .empty: return "Address is empty"
            case .invalidEthAddress: return "Invalid Ethereum address (expected 0x + 40 hex chars)"
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
        // Must start with 0x and be 42 characters total (0x + 40 hex)
        guard address.hasPrefix("0x"),
              address.count == 42,
              address.dropFirst(2).allSatisfy({ $0.isHexDigit }) else {
            throw ValidationError.invalidEthAddress
        }
        // Optional: EIP-55 checksum validation could be added here
    }

    // MARK: - Bitcoin

    private static let base58Chars = CharacterSet(charactersIn: "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
    private static let bech32Chars = CharacterSet(charactersIn: "qpzry9x8gf2tvdw0s3jn54khce6mua7l")

    private static func validateBitcoin(_ address: String) throws {
        // Bech32/Bech32m (bc1... or tb1...)
        if address.lowercased().hasPrefix("bc1") || address.lowercased().hasPrefix("tb1") {
            let payload = String(address.lowercased().dropFirst(3))
            guard payload.count >= 11 && payload.count <= 71,
                  payload.unicodeScalars.allSatisfy({ bech32Chars.contains($0) }) else {
                throw ValidationError.invalidBtcAddress
            }
            return
        }

        // Legacy P2PKH (1...) or P2SH (3...)
        if address.hasPrefix("1") || address.hasPrefix("3") || address.hasPrefix("m") || address.hasPrefix("n") || address.hasPrefix("2") {
            guard (25...34).contains(address.count),
                  address.unicodeScalars.allSatisfy({ base58Chars.contains($0) }) else {
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
            let payload = lower.hasPrefix("ltc1") ? String(lower.dropFirst(4)) : String(lower.dropFirst(5))
            guard payload.count >= 11 && payload.count <= 71,
                  payload.unicodeScalars.allSatisfy({ bech32Chars.contains($0) }) else {
                throw ValidationError.invalidLtcAddress
            }
            return
        }
        // Legacy P2PKH (L...) / P2SH (M... or 3...)
        if address.hasPrefix("L") || address.hasPrefix("M") || address.hasPrefix("3") {
            guard (25...34).contains(address.count),
                  address.unicodeScalars.allSatisfy({ base58Chars.contains($0) }) else {
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
