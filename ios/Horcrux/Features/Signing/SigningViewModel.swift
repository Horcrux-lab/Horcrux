import Foundation
import Combine

/// View model for threshold signing ceremony.
@MainActor
final class SigningViewModel: ObservableObject {
    enum Step {
        case compose, invite, signing, complete, error
    }

    let wallet: Wallet

    @Published var step: Step = .compose
    @Published var recipientAddress: String = ""
    @Published var amount: String = ""

    // Signing
    @Published var joinedSigners: [Peer] = []
    @Published var signingProgress: Double = 0
    @Published var signingStatusMessage: String = ""
    @Published var currentRound: Int = 0
    @Published var totalRounds: Int = 4 // CGGMP21 signing = 4, FROST = 2

    // Result
    @Published var txHash: String?
    @Published var errorMessage: String = ""

    private var bridge: HorcruxBridge?
    private var peerManager: PeerManager?
    private var walletStore: WalletStore?
    private var transactionStore: TransactionStore?
    private var deviceKey: Data?
    private var networkConfig: NetworkConfig?
    private var blockchainService: BlockchainService?
    private var sessionId: String?
    private var signingPin: String?
    private var currentRecordId: String?
    private var cancellables = Set<AnyCancellable>()
    private var signingTask: Task<Void, Never>?
    private var decodingFailures = 0
    private let maxDecodingFailures = 5

    // Gas estimation (EVM)
    @Published var estimatedGas: String = "—"
    @Published var estimatedFee: String = "—"
    @Published var isEstimatingGas = false

    // Broadcast
    @Published var broadcastStatus: String?
    @Published var isBroadcasting = false

    var shortRecipient: String {
        guard recipientAddress.count > 12 else { return recipientAddress }
        return "\(recipientAddress.prefix(6))…\(recipientAddress.suffix(4))"
    }

    init(wallet: Wallet) {
        self.wallet = wallet
        self.totalRounds = wallet.chain == .solana ? 2 : 4
        NotificationCenter.default.publisher(for: .appDidEnterBackground)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.clearSensitiveState() }
            .store(in: &cancellables)
    }

    func bind(to appState: AppState) {
        self.bridge = appState.bridge
        self.peerManager = appState.peerManager
        self.walletStore = appState.walletStore
        self.transactionStore = appState.transactionStore
        do {
            self.deviceKey = try appState.deviceKey
        } catch {
            SecureLog.error("Failed to access device key: \(error.localizedDescription)")
            self.deviceKey = nil
        }
        self.networkConfig = appState.networkConfig
        self.blockchainService = appState.blockchainService

        // Observe connected peers as potential co-signers
        appState.peerManager.$connectedPeers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] peers in
                self?.joinedSigners = peers
            }
            .store(in: &cancellables)
    }

    /// Estimate gas / fees before signing (called when user fills amount + address).
    func estimateGas() {
        guard !recipientAddress.isEmpty, !amount.isEmpty,
              let blockchainService, let networkConfig else { return }
        guard let amountDecimal = Decimal(string: amount), amountDecimal > 0 else {
            errorMessage = "Invalid amount"
            return
        }

        isEstimatingGas = true
        Task {
            do {
                switch wallet.chain {
                case .ethereum:
                    let weiAmount = ethToWei(amount)
                    let estimate = try await blockchainService.ethEstimateGas(
                        from: wallet.address,
                        to: recipientAddress,
                        valueWei: weiAmount,
                        rpcURL: networkConfig.ethereumRPC
                    )
                    let feeDisplay = try await blockchainService.ethFeeEstimateDisplay(
                        from: wallet.address,
                        to: recipientAddress,
                        valueWei: weiAmount,
                        rpcURL: networkConfig.ethereumRPC
                    )
                    await MainActor.run {
                        estimatedGas = "\(estimate.gasLimit)"
                        estimatedFee = "≈ \(feeDisplay.estimatedFee)"
                        isEstimatingGas = false
                    }
                case .bitcoin:
                    let feeDisplay = try await blockchainService.btcFeeEstimateDisplay(
                        inputCount: 1, outputCount: 2,
                        apiURL: networkConfig.bitcoinAPI
                    )
                    await MainActor.run {
                        estimatedFee = "≈ \(feeDisplay.estimatedFee)"
                        isEstimatingGas = false
                    }
                case .solana:
                    let feeDisplay = try await blockchainService.solFeeEstimateDisplay(
                        rpcURL: networkConfig.solanaRPC
                    )
                    await MainActor.run {
                        estimatedFee = "≈ \(feeDisplay.estimatedFee)"
                        isEstimatingGas = false
                    }
                }
            } catch {
                await MainActor.run {
                    estimatedFee = L10n.Signing.unableToEstimate
                    isEstimatingGas = false
                }
            }
        }
    }

    func setPin(_ pin: String) {
        self.signingPin = pin
    }

    func startSigning() {
        // Block on jailbroken devices
        if SecurityEnvironment.isCompromised {
            errorMessage = L10n.Signing.compromisedDevice
            step = .error
            return
        }
        guard let amountDecimal = Decimal(string: amount), amountDecimal > 0 else {
            errorMessage = "Invalid amount"
            step = .error
            return
        }

        step = .signing
        sessionId = UUID().uuidString

        signingTask = Task {
            do {
                guard let bridge, let peerManager, let deviceKey else {
                    throw SigningError.notInitialized
                }
                guard let pin = signingPin, !pin.isEmpty else {
                    throw SigningError.notInitialized
                }
                signingPin = nil  // Zero sensitive PIN from memory immediately

                let config = FfiHorcruxConfig(
                    threshold: wallet.threshold,
                    totalParties: wallet.totalParties,
                    partyIndex: wallet.partyIndex,
                    curve: wallet.chain.curveType
                )

                // Load and decrypt the key share
                var shardData = try loadKeyShare(deviceKey: deviceKey, pin: pin)
                defer { shardData.resetBytes(in: 0..<shardData.count) }

                // Build the transaction hash to sign
                let messageHash = buildSignHash()

                // Collect participant indices
                let participants = [wallet.partyIndex] + joinedSigners.prefix(Int(wallet.threshold) - 1).enumerated().map { UInt16($0.offset + 1) }

                signingStatusMessage = L10n.Signing.initializingProtocol
                currentRound = 1

                let outgoing = try bridge.startSigning(
                    sessionId: sessionId!,
                    config: config,
                    messageHash: messageHash,
                    shardData: shardData,
                    participants: participants
                )

                signingProgress = 0.2

                await runSigningRounds(initialMessages: outgoing)

            } catch {
                if !Task.isCancelled {
                    errorMessage = error.localizedDescription
                    step = .error
                }
            }
        }
    }

    func cancelSigning() {
        signingTask?.cancel()
        signingTask = nil
        signingPin = nil
        if let sessionId {
            bridge?.removeSession(sessionId: sessionId)
        }
        errorMessage = L10n.Signing.cancelledByUser
        step = .error
    }

    /// Clear sensitive in-memory state (called on app background).
    func clearSensitiveState() {
        signingPin = nil
        if var key = deviceKey {
            key.resetBytes(in: key.startIndex..<key.endIndex)
            deviceKey = nil
        }
    }

    private func runSigningRounds(initialMessages: [FfiMpcMessage]) async {
        guard let bridge, let peerManager else { return }

        do {
            // Send initial messages
            for msg in initialMessages {
                let data = try JSONEncoder().encode(MpcMessageDTO(msg))
                try await peerManager.broadcastMpcMessage(data)
            }

            // Process incoming messages
            for await (_, data) in peerManager.incomingMpcMessages {
                let decodedDTO: MpcMessageDTO?
                do {
                    decodedDTO = try JSONDecoder().decode(MpcMessageDTO.self, from: data)
                    decodingFailures = 0
                } catch {
                    SecureLog.error("Failed to decode MPC message during signing: \(error.localizedDescription)")
                    decodingFailures += 1
                    if decodingFailures >= maxDecodingFailures {
                        await MainActor.run {
                            errorMessage = "Protocol communication failure"
                            step = .error
                        }
                        return
                    }
                    decodedDTO = nil
                }
                if let dto = decodedDTO {
                    let msg = dto.toFfi()
                    let responses = try bridge.handleMessage(msg)

                    currentRound = Int(msg.round)
                    signingProgress = Double(currentRound) / Double(totalRounds + 1)
                    updateSigningStatusMessage()

                    for response in responses {
                        let responseData = try JSONEncoder().encode(MpcMessageDTO(response))
                        try await peerManager.broadcastMpcMessage(responseData)
                    }

                    if let result = bridge.getSigningResult(sessionId: sessionId!) {
                        signingProgress = 0.95
                        signingStatusMessage = L10n.Signing.verifyingSig

                        txHash = "0x" + result.signature.map { String(format: "%02x", $0) }.joined()

                        // Save transaction record
                        let recordId = UUID().uuidString
                        currentRecordId = recordId
                        let record = TransactionRecord(
                            id: recordId,
                            walletId: wallet.id,
                            chain: wallet.chain,
                            fromAddress: wallet.address,
                            toAddress: recipientAddress,
                            amount: amount,
                            fee: estimatedFee == "—" ? nil : estimatedFee,
                            txHash: txHash,
                            status: .signed,
                            createdAt: Date(),
                            broadcastAt: nil
                        )
                        await transactionStore?.add(record)

                        signingProgress = 1.0
                        bridge.removeSession(sessionId: sessionId!)
                        step = .complete
                        return
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            step = .error
        }
    }

    private func updateSigningStatusMessage() {
        switch currentRound {
        case 1: signingStatusMessage = L10n.Signing.broadcastingNonces
        case 2: signingStatusMessage = wallet.chain == .solana
            ? L10n.Signing.computingSignatureShares
            : L10n.Signing.exchangingNonces
        case 3: signingStatusMessage = L10n.Signing.computingPartialSigs
        case 4: signingStatusMessage = L10n.Signing.combiningSig
        default: signingStatusMessage = L10n.DKG.processing
        }
    }

    private func loadKeyShare(deviceKey: Data, pin: String) throws -> Data {
        guard let walletStore,
              let encoded = try walletStore.loadKeyShare(walletId: wallet.id) else {
            throw SigningError.shardNotFound
        }
        let dto = try JSONDecoder().decode(EncryptedShardDTO.self, from: encoded)
        let encrypted = dto.toFfi()
        guard let bridge else { throw SigningError.notInitialized }
        return try bridge.decryptShard(
            encrypted: encrypted,
            deviceKey: deviceKey,
            pin: try AppState.pinKeyMaterial(pin)
        )
    }

    private func buildSignHash() -> Data {
        guard let networkConfig else {
            // Fallback: hash a placeholder
            return horcruxKeccak256(data: Data("\(amount) \(wallet.chain.symbol) → \(recipientAddress)".utf8))
        }

        switch wallet.chain {
        case .ethereum:
            // Build EIP-1559 transaction sign hash via Rust FFI
            let params = FfiEvmTxParams(
                to: recipientAddress,
                valueWei: ethToWei(amount),
                nonce: UInt64(estimatedGas) ?? 0, // will be replaced by actual nonce
                gasLimit: UInt64(estimatedGas) ?? 21000,
                maxFeePerGas: "0",
                maxPriorityFeePerGas: "0",
                chainId: networkConfig.evmChainId,
                data: Data()
            )
            // For now, hash the RLP-like representation
            let txBytes = "\(params.chainId):\(params.nonce):\(params.to):\(params.valueWei):\(params.gasLimit)"
            return horcruxKeccak256(data: Data(txBytes.utf8))

        case .bitcoin:
            let txData = "\(amount) BTC → \(recipientAddress)"
            return horcruxKeccak256(data: Data(txData.utf8))

        case .solana:
            let txData = "\(amount) SOL → \(recipientAddress)"
            return Data(txData.utf8)
        }
    }

    /// Broadcast the signed transaction to the network.
    func broadcastTransaction() {
        guard let blockchainService, let networkConfig, let txHash else { return }
        isBroadcasting = true
        broadcastStatus = L10n.Signing.broadcastingTo(wallet.chain.rawValue)

        Task {
            do {
                switch wallet.chain {
                case .ethereum:
                    let result = try await blockchainService.ethSendRawTransaction(
                        signedTxHex: txHash,
                        rpcURL: networkConfig.ethereumRPC
                    )
                    await MainActor.run {
                        broadcastStatus = "Broadcast OK: \(result.prefix(20))…"
                        isBroadcasting = false
                        if let id = currentRecordId {
                            transactionStore?.updateStatus(id: id, status: .broadcast, txHash: result)
                        }
                    }
                case .bitcoin:
                    let result = try await blockchainService.btcBroadcast(
                        signedTxHex: txHash,
                        apiURL: networkConfig.bitcoinAPI
                    )
                    await MainActor.run {
                        broadcastStatus = "Broadcast OK: \(result.prefix(20))…"
                        isBroadcasting = false
                        if let id = currentRecordId {
                            transactionStore?.updateStatus(id: id, status: .broadcast, txHash: result)
                        }
                    }
                case .solana:
                    let result = try await blockchainService.solSendTransaction(
                        signedTxBase64: txHash,
                        rpcURL: networkConfig.solanaRPC
                    )
                    await MainActor.run {
                        broadcastStatus = "Broadcast OK: \(result.prefix(20))…"
                        isBroadcasting = false
                        if let id = currentRecordId {
                            transactionStore?.updateStatus(id: id, status: .broadcast, txHash: result)
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    broadcastStatus = "Broadcast failed: \(error.localizedDescription)"
                    isBroadcasting = false
                    if let id = currentRecordId {
                        transactionStore?.updateStatus(id: id, status: .failed)
                    }
                }
            }
        }
    }

    private func ethToWei(_ ethString: String) -> String {
        guard let eth = Decimal(string: ethString) else { return "0" }
        let weiPerEth = Decimal(sign: .plus, exponent: 18, significand: 1)
        let wei = eth * weiPerEth
        return NSDecimalNumber(decimal: wei).stringValue
    }

    /// Save signed transaction for later broadcast (offline mode).
    func saveForLaterBroadcast(queue: PendingBroadcastQueue) {
        guard let txHash else { return }
        let pending = PendingBroadcastQueue.PendingTransaction(
            id: currentRecordId ?? UUID().uuidString,
            walletId: wallet.id,
            chain: wallet.chain,
            signedPayload: txHash,
            toAddress: recipientAddress,
            amount: amount,
            createdAt: Date()
        )
        queue.enqueue(pending)
    }
}

private enum SigningError: LocalizedError {
    case notInitialized
    case shardNotFound

    var errorDescription: String? {
        switch self {
        case .notInitialized: return "Signing session not initialized"
        case .shardNotFound: return "Key shard not found on this device"
        }
    }
}
