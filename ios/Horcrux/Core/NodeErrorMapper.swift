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
            return .init(message: "交易序号（nonce）已过期，请刷新后重新签名。",
                         action: .refreshNonce, diagnostic: raw.tail())
        }
        if s.contains("replacement transaction underpriced") || s.contains("replacement underpriced") {
            return .init(message: "替换原交易的矿工费不够高，需要至少提升 10%。",
                         action: .raiseFee, diagnostic: raw.tail())
        }
        if s.contains("transaction underpriced") || s.contains("fee too low") || s.contains("gas price too low") {
            return .init(message: "矿工费偏低，节点拒绝收录。请提高 gas 价格后重试。",
                         action: .raiseFee, diagnostic: raw.tail())
        }
        if s.contains("insufficient funds") || s.contains("insufficient balance") {
            return .init(message: "余额不足以支付金额与矿工费。",
                         action: .fundAccount, diagnostic: raw.tail())
        }
        if s.contains("already known") || s.contains("known transaction") {
            return .init(message: "交易已经在打包队列里，无需重复广播。",
                         action: .waitForConfirm, diagnostic: raw.tail())
        }
        if s.contains("intrinsic gas too low") || s.contains("gas limit") && s.contains("too low") {
            return .init(message: "gas 上限设置过低，请使用建议值重试。",
                         action: .raiseFee, diagnostic: raw.tail())
        }

        // MARK: - Bitcoin
        if s.contains("min relay fee not met") || s.contains("mempool min fee") {
            return .init(message: "矿工费低于节点最低中继费率。",
                         action: .raiseFee, diagnostic: raw.tail())
        }
        if s.contains("txn-mempool-conflict") || s.contains("bad-txns-inputs-missingorspent") {
            return .init(message: "交易的输入已被其他交易花掉（可能是 RBF 替换）。",
                         action: .refreshNonce, diagnostic: raw.tail())
        }
        if s.contains("absurdly-high-fee") || s.contains("bad-txns-in-belowout") {
            return .init(message: "矿工费异常，请检查手续费设置。",
                         action: .raiseFee, diagnostic: raw.tail())
        }

        // MARK: - Solana
        if s.contains("blockhash not found") || s.contains("block height exceeded") {
            return .init(message: "blockhash 已过期，需要重新构造交易。",
                         action: .refreshNonce, diagnostic: raw.tail())
        }
        if s.contains("insufficient funds for rent") {
            return .init(message: "账户余额不足以支付 rent，请先充值。",
                         action: .fundAccount, diagnostic: raw.tail())
        }

        // MARK: - Transport / network
        if s.contains("timed out") || s.contains("timeout") || s.contains("request timed out") {
            return .init(message: "节点响应超时，请检查网络或稍后重试。",
                         action: .retry, diagnostic: raw.tail())
        }
        if s.contains("cannot find host") || s.contains("not connect") || s.contains("offline") ||
            s.contains("network connection was lost") {
            return .init(message: "无法连接节点，请检查网络或切换 RPC。",
                         action: .checkNetwork, diagnostic: raw.tail())
        }
        if s.contains("429") || s.contains("too many requests") || s.contains("rate limit") {
            return .init(message: "RPC 请求过于频繁，请稍候再试或更换节点。",
                         action: .retry, diagnostic: raw.tail())
        }
        if s.contains("401") || s.contains("403") || s.contains("unauthorized") {
            return .init(message: "RPC 节点拒绝访问（鉴权失败或 key 无效）。",
                         action: .checkNetwork, diagnostic: raw.tail())
        }

        // Fallback
        return .init(message: "广播失败：\(raw.prefix(80))",
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
