import Foundation

/// Periodically checks broadcast transactions for on-chain confirmation.
/// Updates TransactionStore status from .broadcast → .confirmed.
actor TransactionConfirmationPoller {
    private var isRunning = false
    private var pollTask: Task<Void, Never>?

    /// Start polling. Checks every `interval` seconds.
    func start(store: TransactionStore, service: BlockchainService,
               config: NetworkConfig, interval: TimeInterval = 30) {
        guard !isRunning else {
            NSLog("[tx-poller] start: already running, skip")
            return
        }
        isRunning = true
        NSLog("[tx-poller] start: interval=%.0fs", interval)

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce(store: store, service: service, config: config)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stop() {
        isRunning = false
        pollTask?.cancel()
        pollTask = nil
    }

    /// Single poll: check all broadcast transactions.
    @MainActor
    private func pollOnce(store: TransactionStore, service: BlockchainService,
                          config: NetworkConfig) async {
        let broadcast = store.records.filter { $0.status == .broadcast && $0.txHash != nil }
        guard !broadcast.isEmpty else {
            NSLog("[tx-poller] pollOnce: no broadcast records to check")
            return
        }
        NSLog("[tx-poller] pollOnce: checking %d broadcast tx(s)", broadcast.count)

        for tx in broadcast {
            guard let txHash = tx.txHash else { continue }
            let confirmed = await checkConfirmation(
                txHash: txHash, chain: tx.chain, service: service, config: config
            )
            NSLog("[tx-poller] %@ %@ confirmed=%@", tx.chain.rawValue, String(txHash.prefix(10)), confirmed ? "YES" : "no")
            if confirmed {
                store.updateStatus(id: tx.id, status: .confirmed)
                NotificationManager.shared.notifyTransactionConfirmed(
                    txHash: txHash,
                    chain: tx.chain.rawValue
                )
            }
        }
    }

    /// Check if a transaction is confirmed on-chain.
    private func checkConfirmation(txHash: String, chain: Chain,
                                   service: BlockchainService,
                                   config: NetworkConfig) async -> Bool {
        do {
            if chain.isEVM {
                return try await checkEthConfirmation(txHash: txHash, service: service, chain: chain, config: config)
            }
            switch chain {
            case .bitcoin:
                return try await checkBtcConfirmation(txHash: txHash, chain: .bitcoin, config: config)
            case .litecoin:
                return try await checkBtcConfirmation(txHash: txHash, chain: .litecoin, config: config)
            case .solana:
                return try await checkSolConfirmation(txHash: txHash, service: service, rpcURL: config.solanaRPC)
            case .tron:
                return try await checkTronConfirmation(txID: txHash, apiURL: config.tronAPI)
            default:
                return false
            }
        } catch {
            NSLog("[tx-poller] checkConfirmation error: %@", String(describing: error))
            return false
        }
    }

    /// Try each candidate EVM RPC endpoint in order until one responds.
    /// Returns true on any mined receipt (Optional(true/false)); a thrown
    /// error from the last candidate bubbles up so the poller logs it.
    private func checkEthConfirmation(txHash: String, service: BlockchainService,
                                      chain: Chain, config: NetworkConfig) async throws -> Bool {
        let endpoints = RPCFallbacks.orderedAttempts(for: chain, config: config)
        var lastError: Error = NSError(domain: "tx-poller", code: -1)
        for (idx, rpcURL) in endpoints.enumerated() {
            do {
                if let _ = try await service.ethTxConfirmed(txHash: txHash, rpcURL: rpcURL) {
                    if idx > 0 { NSLog("[tx-poller] eth fallback %d (%@) succeeded", idx, rpcURL) }
                    return true
                }
                return false
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError
    }

    /// Try each candidate Esplora-compatible endpoint (blockstream / mempool
    /// / litecoinspace) until one responds.
    private func checkBtcConfirmation(txHash: String, chain: Chain,
                                      config: NetworkConfig) async throws -> Bool {
        let endpoints = RPCFallbacks.orderedAttempts(for: chain, config: config)
        struct BtcTxStatus: Decodable { let confirmed: Bool }
        let session = PinnedURLSession.shared.session
        var lastError: Error = NSError(domain: "tx-poller", code: -1)
        for (idx, apiURL) in endpoints.enumerated() {
            guard let url = URL(string: "\(apiURL)/tx/\(txHash)/status") else { continue }
            do {
                let (data, _) = try await session.data(from: url)
                let status = try JSONDecoder().decode(BtcTxStatus.self, from: data)
                if idx > 0 { NSLog("[tx-poller] btc fallback %d (%@) succeeded", idx, apiURL) }
                return status.confirmed
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError
    }

    private func checkSolConfirmation(txHash: String, service: BlockchainService, rpcURL: String) async throws -> Bool {
        return try await service.solSigConfirmed(signature: txHash, rpcURL: rpcURL)
    }

    private func checkTronConfirmation(txID: String, apiURL: String) async throws -> Bool {
        // TRON tx IDs are unprefixed 64-char hex. TronGrid's
        // /wallet/gettransactionbyid returns `{}` while pending.
        let service = BlockchainService()
        return try await service.tronTxConfirmed(txID: txID, apiURL: apiURL)
    }
}
