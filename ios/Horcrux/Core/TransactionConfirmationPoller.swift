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
            switch chain {
            case .ethereum:
                return try await checkEthConfirmation(txHash: txHash, service: service, rpcURL: config.ethereumRPC)
            case .bitcoin:
                return try await checkBtcConfirmation(txHash: txHash, apiURL: config.bitcoinAPI)
            case .solana:
                return try await checkSolConfirmation(txHash: txHash, service: service, rpcURL: config.solanaRPC)
            }
        } catch {
            return false
        }
    }

    private func checkEthConfirmation(txHash: String, service: BlockchainService, rpcURL: String) async throws -> Bool {
        // eth_getTransactionReceipt — returns null if not mined
        guard let url = URL(string: rpcURL) else { return false }
        let body: [String: Any] = [
            "jsonrpc": "2.0", "id": 1,
            "method": "eth_getTransactionReceipt",
            "params": [txHash]
        ]
        let jsonBody = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = jsonBody
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let session = PinnedURLSession.shared.session
        let (data, _) = try await session.data(for: request)

        struct ReceiptResponse: Decodable {
            struct Receipt: Decodable {
                let status: String? // "0x1" = success
                let blockNumber: String?
            }
            let result: Receipt?
        }
        let response = try JSONDecoder().decode(ReceiptResponse.self, from: data)
        return response.result?.blockNumber != nil
    }

    private func checkBtcConfirmation(txHash: String, apiURL: String) async throws -> Bool {
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
        guard let url = URL(string: rpcURL) else { return false }
        let body: [String: Any] = [
            "jsonrpc": "2.0", "id": 1,
            "method": "getSignatureStatuses",
            "params": [[txHash], ["searchTransactionHistory": true]]
        ]
        let jsonBody = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = jsonBody
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let session = PinnedURLSession.shared.session
        let (data, _) = try await session.data(for: request)

        struct SolStatusResponse: Decodable {
            struct Result: Decodable {
                struct Value: Decodable {
                    let confirmationStatus: String?
                }
                let value: [Value?]
            }
            let result: Result?
        }
        let response = try JSONDecoder().decode(SolStatusResponse.self, from: data)
        let status = response.result?.value.first??.confirmationStatus
        return status == "finalized" || status == "confirmed"
    }
}
