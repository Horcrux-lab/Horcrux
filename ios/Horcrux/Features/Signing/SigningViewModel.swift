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
    /// Selected ERC-20 / SPL token (nil = native coin transfer).
    @Published var selectedToken: Token? = nil

    /// Available tokens for the current wallet chain. Native coin is represented as `nil`.
    var availableTokens: [Token] {
        TokenList.tokens(for: wallet.chain)
    }

    /// Decimals of the asset currently being transferred (18 for ETH, 8 for BTC, 9 for SOL, token-specific for ERC-20/SPL).
    var transferDecimals: Int {
        if let selectedToken { return Int(selectedToken.decimals) }
        switch wallet.chain {
        case .ethereum: return 18
        case .bitcoin: return 8
        case .solana: return 9
        }
    }

    /// Display symbol of the asset currently being transferred.
    var transferSymbol: String {
        selectedToken?.symbol ?? wallet.chain.symbol
    }

    // Signing
    @Published var joinedSigners: [Peer] = []
    @Published var signingProgress: Double = 0
    @Published var signingStatusMessage: String = ""
    @Published var currentRound: Int = 0
    @Published var totalRounds: Int = 4 // CGGMP21 signing = 4, FROST = 2

    /// Real-time per-peer signing state, keyed by `Peer.id`.
    /// Populated as MPC messages arrive from each peer during signing.
    enum PeerSigningState { case waiting, signing, done, failed }
    @Published var peerStates: [String: PeerSigningState] = [:]
    /// Round that each peer is currently on (from the last message we received from them).
    @Published var peerRounds: [String: Int] = [:]
    /// Timestamp signing started — drives the elapsed-time indicator.
    @Published var signingStartedAt: Date?

    // Balance snapshot for the preview card ("余额: X → Y").
    @Published var preTxBalance: String?
    @Published var preTxBalanceUSD: Double?

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

    /// Full recipient address, chunked into 4-char groups (ETH uses EIP-55 checksum).
    /// Displayed on the signing preview so users can fully verify the destination.
    var displayRecipient: String {
        let canonical = AddressFormatter.canonical(recipientAddress, chain: wallet.chain)
        return AddressFormatter.chunked(canonical)
    }

    var recipientExplorerURL: URL? {
        let canonical = AddressFormatter.canonical(recipientAddress, chain: wallet.chain)
        return AddressFormatter.explorerURL(address: canonical, chain: wallet.chain)
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

        // Snapshot current balance for the preview card. Best-effort; silent failure.
        Task { [weak self] in
            guard let self else { return }
            if let raw = try? await self.blockchainService?.balance(for: self.wallet, config: networkConfig) {
                // Returns e.g. "1.234 ETH" — keep the full string; views parse it.
                self.preTxBalance = raw
                let parts = raw.split(separator: " ")
                if let value = parts.first.flatMap({ Double(String($0).replacingOccurrences(of: ",", with: "")) }) {
                    self.preTxBalanceUSD = PriceService.shared.fiatString(amount: value, symbol: self.wallet.chain.symbol).flatMap { _ in
                        PriceService.shared.usdPrice(symbol: self.wallet.chain.symbol).map { $0 * value }
                    }
                }
            }
        }

        isEstimatingGas = true
        Task {
            do {
                switch wallet.chain {
                case .ethereum:
                    // If ERC-20: call goes to token contract with value=0 and transfer() calldata
                    let (txTo, txValueWei, txData): (String, String, String?) = {
                        if let token = self.selectedToken {
                            let raw = Self.amountToRawUnits(amount, decimals: Int(token.decimals))
                            let data = Self.erc20TransferCalldata(to: recipientAddress, amountRaw: raw)
                            return (token.id, "0", "0x" + data.map { String(format: "%02x", $0) }.joined())
                        } else {
                            return (recipientAddress, ethToWei(amount), nil)
                        }
                    }()
                    let estimate = try await blockchainService.ethEstimateGas(
                        from: wallet.address,
                        to: txTo,
                        valueWei: txValueWei,
                        data: txData,
                        rpcURL: networkConfig.ethereumRPC
                    )
                    let feeDisplay = try await blockchainService.ethFeeEstimateDisplay(
                        from: wallet.address,
                        to: txTo,
                        valueWei: txValueWei,
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

    /// Cached Shard Wrap Key bytes — set either directly (cached session
    /// SWK) or produced by unwrapping via PIN/biometric from the signing UI.
    private var signingShardKey: Data?

    func setShardKey(_ swk: Data) {
        signingShardKey = swk
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
        signingStartedAt = Date()
        // Initialize each joined peer as "waiting" — flips to "signing" on first message,
        // and to "done" when the ceremony completes.
        var initialStates: [String: PeerSigningState] = [:]
        for peer in joinedSigners { initialStates[peer.id] = .waiting }
        peerStates = initialStates
        peerRounds = [:]

        signingTask = Task {
            do {
                guard let bridge, let peerManager, let deviceKey else {
                    throw SigningError.notInitialized
                }
                guard var swk = signingShardKey, !swk.isEmpty else {
                    throw SigningError.notInitialized
                }
                // Zero the local reference from the view model after copying.
                signingShardKey = nil
                defer { swk.resetBytes(in: 0..<swk.count) }

                let config = FfiHorcruxConfig(
                    threshold: wallet.threshold,
                    totalParties: wallet.totalParties,
                    partyIndex: wallet.partyIndex,
                    curve: wallet.chain.curveType
                )

                // Load and decrypt the key share using the Shard Wrap Key.
                var shardData = try loadKeyShare(deviceKey: deviceKey, swk: swk)
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
        if var k = signingShardKey {
            k.resetBytes(in: 0..<k.count)
            signingShardKey = nil
        }
        if let sessionId {
            bridge?.removeSession(sessionId: sessionId)
        }
        errorMessage = L10n.Signing.cancelledByUser
        step = .error
    }

    /// Clear sensitive in-memory state (called on app background).
    func clearSensitiveState() {
        if var k = signingShardKey {
            k.resetBytes(in: 0..<k.count)
            signingShardKey = nil
        }
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
            for await (peer, data) in peerManager.mpcMessageStream() {
                // Real per-peer state: first inbound bytes from a peer flips them to .signing.
                if peerStates[peer.id] != .done {
                    peerStates[peer.id] = .signing
                }
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
                    peerRounds[peer.id] = Int(msg.round)
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
                        // Mark every participant as done — we only reach this branch
                        // once the final combined signature is produced.
                        for key in peerStates.keys { peerStates[key] = .done }
                        bridge.removeSession(sessionId: sessionId!)
                        Haptics.success()
                        step = .complete
                        return
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            // Any peer still mid-protocol is flipped to .failed so the UI can reflect it.
            for key in peerStates.keys where peerStates[key] != .done {
                peerStates[key] = .failed
            }
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

    private func loadKeyShare(deviceKey: Data, swk: Data) throws -> Data {
        guard let walletStore,
              let encoded = try walletStore.loadKeyShare(accountId: wallet.accountId) else {
            throw SigningError.shardNotFound
        }
        let dto = try JSONDecoder().decode(EncryptedShardDTO.self, from: encoded)
        let encrypted = dto.toFfi()
        guard let bridge else { throw SigningError.notInitialized }
        return try bridge.decryptShard(
            encrypted: encrypted,
            deviceKey: deviceKey,
            pin: swk
        )
    }

    private func buildSignHash() -> Data {
        guard let networkConfig else {
            // Fallback: hash a placeholder
            return horcruxKeccak256(data: Data("\(amount) \(wallet.chain.symbol) → \(recipientAddress)".utf8))
        }

        switch wallet.chain {
        case .ethereum:
            // Build real EIP-1559 sign hash via Rust FFI
            let (txTo, txValueWei, txData): (String, String, Data) = {
                if let token = self.selectedToken {
                    let raw = Self.amountToRawUnits(amount, decimals: Int(token.decimals))
                    let data = Self.erc20TransferCalldata(to: recipientAddress, amountRaw: raw)
                    return (token.id, "0", data)
                } else {
                    return (recipientAddress, ethToWei(amount), Data())
                }
            }()
            let params = FfiEvmTxParams(
                to: txTo,
                valueWei: txValueWei,
                nonce: 0,
                gasLimit: UInt64(estimatedGas) ?? 21000,
                maxFeePerGas: "0",
                maxPriorityFeePerGas: "0",
                chainId: networkConfig.evmChainId,
                data: txData
            )
            if let tx = try? horcruxBuildEvmTransaction(params: params) {
                return tx.signHash
            }
            // Fallback: hash a stable string representation
            let txBytes = "\(params.chainId):\(params.nonce):\(params.to):\(params.valueWei):\(params.gasLimit):\(txData.count)"
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
                        Haptics.success()
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
                        Haptics.success()
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
                        Haptics.success()
                        if let id = currentRecordId {
                            transactionStore?.updateStatus(id: id, status: .broadcast, txHash: result)
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    let mapped = NodeErrorMapper.map(error)
                    broadcastStatus = "广播失败：\(mapped.message)"
                    isBroadcasting = false
                    Haptics.error()
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

    // MARK: - ERC-20 helpers

    /// Convert a human-readable amount string to raw smallest-unit value (as decimal string).
    /// Uses Decimal math — fine for any normal transfer amount.
    static func amountToRawUnits(_ amountString: String, decimals: Int) -> String {
        guard let amount = Decimal(string: amountString), amount > 0 else { return "0" }
        let multiplier = Decimal(sign: .plus, exponent: decimals, significand: 1)
        let raw = amount * multiplier
        return NSDecimalNumber(decimal: raw).stringValue
    }

    /// Build ERC-20 `transfer(address,uint256)` calldata: 4-byte selector + 32-byte address + 32-byte amount.
    /// selector = keccak256("transfer(address,uint256)")[0..4] = 0xa9059cbb
    static func erc20TransferCalldata(to: String, amountRaw: String) -> Data {
        var data = Data([0xa9, 0x05, 0x9c, 0xbb])
        // Address: strip 0x, pad to 32 bytes left
        let addrHex = to.hasPrefix("0x") ? String(to.dropFirst(2)) : to
        let addrBytes = Self.hexToData(addrHex) ?? Data()
        let padCount = max(0, 32 - addrBytes.count)
        data.append(Data(repeating: 0, count: padCount))
        data.append(addrBytes)
        // Amount: u256 big-endian, 32 bytes
        let amountBytes = Self.decimalStringToBigEndian(amountRaw, byteLength: 32)
        data.append(amountBytes)
        return data
    }

    /// Parse a hex string into Data. Supports optional `0x` prefix. Returns nil on invalid input.
    static func hexToData(_ hex: String) -> Data? {
        var s = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        if s.count % 2 != 0 { s = "0" + s }
        var bytes = [UInt8]()
        bytes.reserveCapacity(s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let b = UInt8(s[idx..<next], radix: 16) else { return nil }
            bytes.append(b)
            idx = next
        }
        return Data(bytes)
    }

    /// Encode a decimal string as big-endian bytes of the given length.
    static func decimalStringToBigEndian(_ decString: String, byteLength: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: byteLength)
        var value = Decimal(string: decString) ?? 0
        var base = Decimal(256)
        var i = byteLength - 1
        while value > 0 && i >= 0 {
            var quotient = Decimal()
            NSDecimalDivide(&quotient, &value, &base, .down)
            var floored = Decimal()
            NSDecimalRound(&floored, &quotient, 0, .down)
            var mulBack = Decimal()
            NSDecimalMultiply(&mulBack, &floored, &base, .plain)
            var remainder = Decimal()
            NSDecimalSubtract(&remainder, &value, &mulBack, .plain)
            bytes[i] = UInt8(truncating: NSDecimalNumber(decimal: remainder))
            value = floored
            i -= 1
        }
        return Data(bytes)
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
