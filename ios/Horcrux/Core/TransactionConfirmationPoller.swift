import Foundation

/// Periodically checks broadcast transactions for on-chain confirmation.
/// Updates TransactionStore status from .broadcast → .confirmed.
actor TransactionConfirmationPoller {
    private var isRunning = false
    private var pollTask: Task<Void, Never>?

    /// Start polling. Checks every `interval` seconds.
    func start(store: TransactionStore, service: BlockchainService,
               config: NetworkConfig, interval: TimeInterval = 30) {
        guard !isRunning else { return }
        isRunning = true

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
        guard !broadcast.isEmpty else { return }

        for tx in broadcast {
            guard let txHash = tx.txHash else { continue }
            let confirmed = await checkConfirmation(
                txHash: txHash, chain: tx.chain, service: service, config: config
            )
            if confirmed {
                store.updateStatus(id: tx.id, status: .confirmed)
            }
        }
    }

    /// Check if a transaction is confirmed on-chain.
    private func checkConfirmation(txHash: String, chain: Chain,
                                   service: BlockchainService,
                                   config: NetworkConfig) async -> Bool {
        do {
            if chain.isEVM {
                return try await checkEthConfirmation(txHash: txHash, service: service, rpcURL: config.rpcURL(for: chain))
            }
            switch chain {
            case .bitcoin:
                return try await checkBtcConfirmation(txHash: txHash, apiURL: config.bitcoinAPI)
            case .litecoin:
                // litecoinspace.org exposes the same Esplora `/tx/{id}/status`
                // endpoint as mempool.space, so we reuse the BTC prober.
                return try await checkBtcConfirmation(txHash: txHash, apiURL: config.litecoinAPI)
            case .solana:
                return try await checkSolConfirmation(txHash: txHash, service: service, rpcURL: config.solanaRPC)
            case .tron:
                // TRON signing not yet wired — no pending tx hashes should
                // reach this branch, so "not yet" keeps the UI from spinning.
                return false
            default:
                return false
            }
        } catch {
            return false
        }
    }

    private func checkEthConfirmation(txHash: String, service: BlockchainService, rpcURL: String) async throws -> Bool {
        // BlockchainService already gives us a retry+pinned variant that
        // returns `nil` for pending (null-result) receipts.
        if let _ = try await service.ethTxConfirmed(txHash: txHash, rpcURL: rpcURL) {
            return true
        }
        return false
    }

    private func checkBtcConfirmation(txHash: String, apiURL: String) async throws -> Bool {
        // Direct Esplora call — no need to go through BlockchainService.
        guard let url = URL(string: "\(apiURL)/tx/\(txHash)/status") else { return false }
        let session = PinnedURLSession.shared.session
        let (data, _) = try await session.data(from: url)

        struct BtcTxStatus: Decodable {
            let confirmed: Bool
        }
        let status = try JSONDecoder().decode(BtcTxStatus.self, from: data)
        return status.confirmed
    }

    private func checkSolConfirmation(txHash: String, service: BlockchainService, rpcURL: String) async throws -> Bool {
        return try await service.solSigConfirmed(signature: txHash, rpcURL: rpcURL)
    }
}
