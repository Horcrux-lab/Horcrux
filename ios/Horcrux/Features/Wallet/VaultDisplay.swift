import Foundation

/// Derivation helpers that turn the existing wallet-group data into the
/// institutional-style signals shown by Vault Mode. No new persistence —
/// everything read here is already stored locally.
enum VaultDisplay {

    // MARK: - Names & monograms

    /// Convert a free-form wallet-group name (`"Trading Hot"`, `"主钱包"`)
    /// into the monospace vault code shown in Vault Mode. The raw name is
    /// preserved as-is on disk; this is a purely visual transformation.
    ///
    /// Rules:
    ///   • Uppercase ASCII letters
    ///   • Whitespace / underscores collapsed to single hyphens
    ///   • Leading/trailing hyphens stripped
    ///   • Non-ASCII characters (CJK, emoji) are passed through unchanged
    ///     so `"主钱包"` still reads as `"主钱包"` — the point of Vault
    ///     Mode is an organisational vibe, not ASCII-only
    static func vaultCode(from name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "VAULT" }

        var out = ""
        var lastWasSeparator = false
        for scalar in trimmed.unicodeScalars {
            if scalar == " " || scalar == "_" || scalar == "-" {
                if !out.isEmpty && !lastWasSeparator {
                    out.append("-")
                    lastWasSeparator = true
                }
                continue
            }
            let asCh = Character(scalar)
            if asCh.isASCII, let a = asCh.asciiValue, a >= 0x61 && a <= 0x7A {
                out.append(Character(UnicodeScalar(a - 0x20)))
            } else {
                out.append(asCh)
            }
            lastWasSeparator = false
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "VAULT" : out
    }

    /// Two-character uppercase monogram for the square vault badge. Picks
    /// the first letter of the first two words; falls back to the first
    /// two characters if the name is one word. Non-ASCII names use the
    /// first grapheme cluster (so `"主钱包"` shows `主` — the badge renders
    /// it in a wide glyph, which is actually fine on the square tile).
    static func monogram2(from name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "V" }

        let words = trimmed.split { $0.isWhitespace || $0 == "-" || $0 == "_" }
        if words.count >= 2, let a = words[0].first, let b = words[1].first {
            return "\(a)\(b)".uppercased()
        }
        let chars = Array(trimmed)
        if chars.count >= 2, chars[0].isASCII {
            return "\(chars[0])\(chars[1])".uppercased()
        }
        return String(chars[0]).uppercased()
    }

    // MARK: - Environment tag (PROD / TESTNET / MIXED)

    enum Environment: String {
        case prod    = "PROD"
        case testnet = "TESTNET"
        case mixed   = "MIXED"
    }

    /// Derive the PROD/TESTNET tag for a vault by looking at the current
    /// network selectors in `NetworkConfig`. A vault that spans chains
    /// which are configured to different environments shows `MIXED` —
    /// that's an operational hazard worth surfacing.
    static func environment(for wallets: [Wallet], config: NetworkConfig) -> Environment {
        var sawMainnet = false
        var sawTestnet = false
        for wallet in wallets {
            let isTestnet: Bool
            switch wallet.chain {
            case .ethereum, .bnb, .polygon, .arbitrum, .base,
                 .avalanche, .optimism, .zksync, .linea, .scroll:
                isTestnet = config.evmChainId == EVMNetwork.sepolia.rawValue
            case .bitcoin, .litecoin:
                isTestnet = config.btcTestnet
            case .solana:
                isTestnet = config.solDevnet
            case .tron:
                isTestnet = false
            }
            if isTestnet { sawTestnet = true } else { sawMainnet = true }
            if sawTestnet && sawMainnet { return .mixed }
        }
        return sawTestnet ? .testnet : .prod
    }

    // MARK: - Last signed + vault health

    /// Latest activity timestamp across every wallet in the group. Reads
    /// from the persistent `TransactionStore` — the same source that
    /// feeds the history list in wallet detail. Transactions from other
    /// devices in the MPC group aren't reflected here, but any sign that
    /// touched this device is.
    @MainActor
    static func lastSigned(for wallets: [Wallet], store: TransactionStore) -> Date? {
        var latest: Date?
        for wallet in wallets {
            for record in store.records(for: wallet.id) {
                let ts = record.broadcastAt ?? record.createdAt
                if let existing = latest {
                    if ts > existing { latest = ts }
                } else {
                    latest = ts
                }
            }
        }
        return latest
    }

    /// The four values drive the status-dot colour on the vault badge
    /// and the tone of the "last signed Xd ago" segment in the header.
    enum Health {
        case healthy     // signed within 30d
        case degraded    // signed 30–90d ago
        case stale       // signed > 90d ago
        case idle        // never signed (cold vault)
    }

    static func health(lastSigned: Date?, now: Date = Date()) -> Health {
        guard let ts = lastSigned else { return .idle }
        let days = now.timeIntervalSince(ts) / 86_400
        if days < 30 { return .healthy }
        if days < 90 { return .degraded }
        return .stale
    }

    /// Compact "3d ago" / "2w ago" / "5mo ago" for the meta row. Uses
    /// `RelativeDateTimeFormatter` with abbreviated style so it reads
    /// the same in en/zh/… without manual pluralisation.
    static func relativeSignedLabel(lastSigned: Date?) -> String {
        guard let ts = lastSigned else {
            return Foundation.NSLocalizedString("vaultMode.neverSigned", value: "never signed", comment: "")
        }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: ts, relativeTo: Date())
    }
}
