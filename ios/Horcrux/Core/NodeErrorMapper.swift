import Foundation

/// Converts raw JSON-RPC / blockchain node error strings into actionable,
/// user-friendly Chinese messages with an optional suggested action.
///
/// The mapper scans the raw error message for well-known substrings from
/// Ethereum (geth/erigon/infura), Bitcoin (Blockstream/Mempool.space, Bitcoin Core),
/// and Solana (solana-rpc). When nothing matches, we fall back to a generic
/// "network error" string while preserving a short diagnostic tail.
enum NodeErrorMapper {

    enum SuggestedAction: String {
        case retry              // transient; user can retry immediately
        case raiseFee           // replace-by-fee with a higher gas/fee
        case refreshNonce       // nonce stale; re-sync nonce and re-sign
        case fundAccount        // not enough balance / gas
        case waitForConfirm     // a prior tx is still pending
        case checkNetwork       // RPC host unreachable
        case none
    }

    struct Mapped {
        let message: String
        let action: SuggestedAction
        /// Short technical detail suitable for a small caption under the message.
        let diagnostic: String?
    }

    static func map(_ error: Error) -> Mapped {
        map(error.localizedDescription)
    }

    static func map(_ raw: String) -> Mapped {
        let s = raw.lowercased()

        // MARK: - Ethereum
        if s.contains("nonce too low") || s.contains("invalid nonce") || s.contains("nonce has already been used") {
            return .init(message: L10n.NodeErr.nonceStale,
                         action: .refreshNonce, diagnostic: raw.tail())
        }
        if s.contains("replacement transaction underpriced") || s.contains("replacement underpriced") {
            return .init(message: L10n.NodeErr.replacementUnderpriced,
                         action: .raiseFee, diagnostic: raw.tail())
        }
        if s.contains("transaction underpriced") || s.contains("fee too low") || s.contains("gas price too low") {
            return .init(message: L10n.NodeErr.underpriced,
                         action: .raiseFee, diagnostic: raw.tail())
        }
        if s.contains("insufficient funds") || s.contains("insufficient balance") {
            return .init(message: L10n.NodeErr.insufficientFunds,
                         action: .fundAccount, diagnostic: raw.tail())
        }
        if s.contains("already known") || s.contains("known transaction") {
            return .init(message: L10n.NodeErr.alreadyKnown,
                         action: .waitForConfirm, diagnostic: raw.tail())
        }
        if s.contains("intrinsic gas too low") || s.contains("gas limit") && s.contains("too low") {
            return .init(message: L10n.NodeErr.gasTooLow,
                         action: .raiseFee, diagnostic: raw.tail())
        }

        // MARK: - Bitcoin
        if s.contains("min relay fee not met") || s.contains("mempool min fee") {
            return .init(message: L10n.NodeErr.btcMinRelay,
                         action: .raiseFee, diagnostic: raw.tail())
        }
        if s.contains("txn-mempool-conflict") || s.contains("bad-txns-inputs-missingorspent") {
            return .init(message: L10n.NodeErr.btcInputSpent,
                         action: .refreshNonce, diagnostic: raw.tail())
        }
        if s.contains("absurdly-high-fee") || s.contains("bad-txns-in-belowout") {
            return .init(message: L10n.NodeErr.btcAbnormalFee,
                         action: .raiseFee, diagnostic: raw.tail())
        }

        // MARK: - Solana
        if s.contains("blockhash not found") || s.contains("block height exceeded") {
            return .init(message: L10n.NodeErr.solBlockhash,
                         action: .refreshNonce, diagnostic: raw.tail())
        }
        if s.contains("insufficient funds for rent") {
            return .init(message: L10n.NodeErr.solRent,
                         action: .fundAccount, diagnostic: raw.tail())
        }

        // MARK: - Transport / network
        if s.contains("timed out") || s.contains("timeout") || s.contains("request timed out") {
            return .init(message: L10n.NodeErr.timeout,
                         action: .retry, diagnostic: raw.tail())
        }
        if s.contains("cannot find host") || s.contains("not connect") || s.contains("offline") ||
            s.contains("network connection was lost") {
            return .init(message: L10n.NodeErr.cannotConnect,
                         action: .checkNetwork, diagnostic: raw.tail())
        }
        if s.contains("429") || s.contains("too many requests") || s.contains("rate limit") {
            return .init(message: L10n.NodeErr.rateLimited,
                         action: .retry, diagnostic: raw.tail())
        }
        if s.contains("401") || s.contains("403") || s.contains("unauthorized") {
            return .init(message: L10n.NodeErr.unauthorized,
                         action: .checkNetwork, diagnostic: raw.tail())
        }

        // Fallback
        return .init(message: L10n.NodeErr.broadcastFailed(String(raw.prefix(80))),
                     action: .retry, diagnostic: raw.count > 80 ? String(raw.suffix(80)) : nil)
    }
}

private extension String {
    /// Last 120 characters, trimmed — useful as a compact diagnostic tail.
    func tail() -> String {
        let s = trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count <= 120 { return s }
        return "…" + String(s.suffix(120))
    }
}
