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
            // TRON: also pull TRC-20 token transfers in a second pass.
            if wallet.chain == .tron {
                let trc20 = (try? await service.tronRecentTrc20Txs(address: wallet.address, apiURL: config.tronAPI)) ?? []
                for (ext, symbol, decimals, _) in trc20 where !existing.contains(ext.txHash) {
                    let rec = makeTokenRecord(ext, wallet: wallet, symbol: symbol, decimals: decimals)
                    store.add(rec)
                    inserted += 1
                }
            }
            // EVM: also pull ERC-20 token transfers via Etherscan V2.
            if wallet.chain.isEVM {
                let erc20 = (try? await service.etherscanRecentTokenTxs(
                    address: wallet.address,
                    chainId: config.evmChainId,
                    apiKey: config.etherscanAPIKey
                )) ?? []
                for (ext, symbol, decimals, _) in erc20 where !existing.contains("\(ext.txHash):\(symbol)") {
                    // Use `hash:symbol` composite to dedupe so a native tx
                    // and its paired token transfer don't collide.
                    let rec = makeTokenRecord(ext, wallet: wallet, symbol: symbol, decimals: decimals)
                    // Skip if a record with same composite id already exists.
                    if store.records.contains(where: { $0.id == rec.id }) { continue }
                    store.add(rec)
                    inserted += 1
                }
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
        let amountStr = formatAmount(smallest: absAmount, chain: wallet.chain)
        let feeStr: String? = ext.feeSmallest > 0
            ? formatAmount(smallest: ext.feeSmallest, chain: wallet.chain)
            : nil
        let status: TransactionRecord.TxStatus = ext.confirmed ? .confirmed : .broadcast
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

    private func makeTokenRecord(_ ext: BlockchainService.ExternalTx, wallet: Wallet, symbol: String, decimals: Int) -> TransactionRecord {
        let absAmount = abs(ext.deltaSmallest)
        let d = max(0, min(decimals, 36))
        let scale = pow(Decimal(10), d)
        let scaled = absAmount / scale
        let nsnum = scaled as NSDecimalNumber
        let amountStr = String(format: "%.\(max(2, min(d, 6)))f %@", nsnum.doubleValue, symbol)
        return TransactionRecord(
            id: "ext:\(ext.txHash):\(symbol)",
            walletId: wallet.id,
            chain: wallet.chain,
            fromAddress: ext.from,
            toAddress: ext.to,
            amount: amountStr,
            fee: nil,
            txHash: ext.txHash,
            status: ext.confirmed ? .confirmed : .broadcast,
            createdAt: ext.blockTime ?? Date(),
            broadcastAt: ext.blockTime,
            confirmedAt: ext.confirmed ? ext.blockTime : nil
        )
    }

    private func formatAmount(smallest: Decimal, chain: Chain) -> String {
        let nsnum = smallest as NSDecimalNumber
        let double = nsnum.doubleValue
        switch chain {
        case .bitcoin:
            let btc = double / 1e8
            return trim(String(format: "%.8f", btc)) + " BTC"
        case .litecoin:
            let ltc = double / 1e8
            return trim(String(format: "%.8f", ltc)) + " LTC"
        case .tron:
            let trx = double / 1_000_000
            return trim(String(format: "%.6f", trx)) + " TRX"
        case .solana:
            let sol = double / 1e9
            return trim(String(format: "%.9f", sol)) + " SOL"
        default:
            if chain.isEVM {
                let ether = double / 1e18
                return trim(String(format: "%.6f", ether)) + " " + chain.symbol
            }
            return "\(nsnum.stringValue)"
        }
    }

    private func trim(_ s: String) -> String {
        var t = s
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }
}
