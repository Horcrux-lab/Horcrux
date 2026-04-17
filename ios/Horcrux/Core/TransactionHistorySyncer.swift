import Foundation

/// Pulls recent on-chain history for a wallet from public explorer APIs
/// (Blockstream / litecoinspace / TronGrid) and merges any new records
/// into the local `TransactionStore`. Existing hashes are skipped so
/// locally-originated sends stay authoritative.
///
/// EVM and Solana are not yet wired — adding them requires an Etherscan
/// API key (EVM) or heavier per-signature fetches (Solana).
@MainActor
final class TransactionHistorySyncer {
    private let store: TransactionStore
    private let service: BlockchainService
    private let config: NetworkConfig

    init(store: TransactionStore, service: BlockchainService, config: NetworkConfig) {
        self.store = store
        self.service = service
        self.config = config
    }

    /// Sync one wallet. Returns the number of new records inserted.
    @discardableResult
    func sync(wallet: Wallet) async -> Int {
        let existing = Set(store.records
            .compactMap { $0.txHash }
            .filter { !$0.isEmpty })
        var inserted = 0
        do {
            let pulled = try await fetchRemote(for: wallet)
            for ext in pulled where !existing.contains(ext.txHash) {
                let rec = makeRecord(ext, wallet: wallet)
                store.add(rec)
                inserted += 1
            }
        } catch {
            SecureLog.warning("history sync failed for \(wallet.chain): \(error.localizedDescription)")
        }
        return inserted
    }

    private func fetchRemote(for wallet: Wallet) async throws -> [BlockchainService.ExternalTx] {
        switch wallet.chain {
        case .bitcoin:
            return try await service.esploraRecentTxs(address: wallet.address, apiURL: config.bitcoinAPI)
        case .litecoin:
            return try await service.esploraRecentTxs(address: wallet.address, apiURL: config.litecoinAPI)
        case .tron:
            return try await service.tronRecentTxs(address: wallet.address, apiURL: config.tronAPI)
        case .solana:
            return try await service.solanaRecentTxs(address: wallet.address, rpcURL: config.solanaRPC)
        default:
            // EVM chains (all variants).
            if wallet.chain.isEVM {
                return try await service.etherscanRecentTxs(
                    address: wallet.address,
                    chainId: config.evmChainId,
                    apiKey: config.etherscanAPIKey
                )
            }
            return []
        }
    }

    private func makeRecord(_ ext: BlockchainService.ExternalTx, wallet: Wallet) -> TransactionRecord {
        let absAmount = abs(ext.deltaSmallest)
        let amountStr = formatAmount(smallest: UInt64(absAmount), chain: wallet.chain)
        let feeStr: String? = ext.feeSmallest > 0
            ? formatAmount(smallest: ext.feeSmallest, chain: wallet.chain)
            : nil
        let status: TransactionRecord.TxStatus = ext.confirmed ? .confirmed : .broadcast
        // Preserve the on-chain timestamp so records sort correctly. Prefix the
        // id so we can tell external-sourced records apart from local ones.
        return TransactionRecord(
            id: "ext:\(ext.txHash)",
            walletId: wallet.id,
            chain: wallet.chain,
            fromAddress: ext.from,
            toAddress: ext.to,
            amount: amountStr,
            fee: feeStr,
            txHash: ext.txHash,
            status: status,
            createdAt: ext.blockTime ?? Date(),
            broadcastAt: ext.blockTime,
            confirmedAt: ext.confirmed ? ext.blockTime : nil
        )
    }

    private func formatAmount(smallest: UInt64, chain: Chain) -> String {
        switch chain {
        case .bitcoin:
            let btc = Double(smallest) / 1e8
            return String(format: "%.8f BTC", btc)
                .replacingOccurrences(of: #"0+ BTC$"#, with: " BTC", options: .regularExpression)
                .replacingOccurrences(of: #"\. BTC$"#, with: " BTC", options: .regularExpression)
        case .litecoin:
            let ltc = Double(smallest) / 1e8
            return String(format: "%.8f LTC", ltc)
                .replacingOccurrences(of: #"0+ LTC$"#, with: " LTC", options: .regularExpression)
                .replacingOccurrences(of: #"\. LTC$"#, with: " LTC", options: .regularExpression)
        case .tron:
            let trx = Double(smallest) / 1_000_000
            return String(format: "%.6f TRX", trx)
                .replacingOccurrences(of: #"0+ TRX$"#, with: " TRX", options: .regularExpression)
                .replacingOccurrences(of: #"\. TRX$"#, with: " TRX", options: .regularExpression)
        case .solana:
            let sol = Double(smallest) / 1e9
            return String(format: "%.9f SOL", sol)
                .replacingOccurrences(of: #"0+ SOL$"#, with: " SOL", options: .regularExpression)
                .replacingOccurrences(of: #"\. SOL$"#, with: " SOL", options: .regularExpression)
        default:
            if chain.isEVM {
                // wei → ether with up to 6 decimal places of precision.
                let ether = Double(smallest) / 1e18
                return String(format: "%.6f %@", ether, chain.symbol)
                    .replacingOccurrences(of: #"0+ \w+$"#, with: " \(chain.symbol)", options: .regularExpression)
                    .replacingOccurrences(of: #"\. \w+$"#, with: " \(chain.symbol)", options: .regularExpression)
            }
            return "\(smallest)"
        }
    }
}
