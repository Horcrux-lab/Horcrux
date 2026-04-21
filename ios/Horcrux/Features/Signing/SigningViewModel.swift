import Foundation
import Combine
import CryptoKit
import UIKit

/// View model for threshold signing ceremony.
@MainActor
final class SigningViewModel: ObservableObject {
    enum Step {
        case compose, invite, signing, complete, error
    }

    let wallet: Wallet

    @Published var step: Step = .compose
    @Published var recipientAddress: String = "" {
        didSet {
            if recipientAddress != oldValue { triggerReverseENSLookup() }
        }
    }
    @Published var amount: String = ""
    /// Selected ERC-20 / SPL token (nil = native coin transfer).
    @Published var selectedToken: Token? = nil {
        didSet {
            // Prime the Max button for token transfers by prefetching the
            // token balance into the shared cache. No-op for native coin.
            guard selectedToken?.id != oldValue?.id,
                  let token = selectedToken,
                  let cfg = networkConfig,
                  let svc = blockchainService else { return }
            let w = wallet
            Task { @MainActor in
                _ = await BalanceCache.shared.tokenBalance(
                    wallet: w, token: token,
                    service: svc, config: cfg)
                // Kick a view refresh so the Max button re-evaluates canFillMax.
                self.objectWillChange.send()
            }
        }
    }

    /// User-selected fee priority. Scales the cached EVM gas estimate
    /// and (in future) BTC fee rate. Normal = network-suggested values.
    @Published var feeTier: FeeTier = .normal {
        didSet {
            if feeTier != oldValue { refreshFeeDisplay() }
        }
    }

    /// When set, the current signing session is replacing a prior (pending)
    /// BTC/LTC tx with higher fee (BIP-125 RBF). On broadcast success we flag
    /// the original record so history UI can show a "被 RBF 替换" marker.
    var rbfReplacing: String?

    enum FeeTier: String, CaseIterable, Identifiable {
        case slow, normal, fast, custom
        var id: String { rawValue }
        var label: String {
            switch self {
            case .slow: return L10n.SigningExtra.speedSlow
            case .normal: return L10n.SigningExtra.speedNormal
            case .fast: return L10n.SigningExtra.speedFast
            case .custom: return L10n.SigningExtra.speedCustom
            }
        }
        /// Multiplier applied to maxFeePerGas & maxPriorityFeePerGas
        /// (EVM) or to the suggested BTC feerate. For `.custom`, the
        /// caller reads `customMultiplier` instead.
        var multiplier: Double {
            switch self {
            case .slow: return 0.85
            case .normal: return 1.0
            case .fast: return 1.3
            case .custom: return 1.0 // placeholder; see customMultiplier
            }
        }
    }

    /// User-entered gas price in gwei for `.custom` tier. Empty = fall back
    /// to network-suggested. We translate this into a multiplier against
    /// the cached network-suggested maxFeePerGas at fee-refresh time.
    @Published var customGasPriceGwei: String = "" {
        didSet { if feeTier == .custom { refreshFeeDisplay() } }
    }

    /// Available tokens for the current wallet chain. Native coin is represented as `nil`.
    var availableTokens: [Token] {
        if let customTokenStore {
            return customTokenStore.effectiveTokens(for: wallet.chain)
        }
        return TokenList.tokens(for: wallet.chain)
    }

    /// Decimals of the asset currently being transferred (18 for ETH, 8 for BTC, 9 for SOL, token-specific for ERC-20/SPL).
    var transferDecimals: Int {
        if let selectedToken { return Int(selectedToken.decimals) }
        if wallet.chain.isEVM { return 18 }
        switch wallet.chain {
        case .bitcoin, .litecoin: return 8
        case .solana: return 9
        case .tron: return 6
        default: return 18
        }
    }

    /// Display symbol of the asset currently being transferred.
    var transferSymbol: String {
        selectedToken?.symbol ?? wallet.chain.symbol
    }

    // Signing
    @Published var joinedSigners: [Peer] = []
    /// Peer IDs the initiator has explicitly dismissed from this ceremony
    /// (via the "remove" button on the joined-cosigners row). They stay
    /// filtered out of `joinedSigners` as long as the current room code
    /// is alive, so a removed peer can't silently rejoin just because
    /// `peerManager.connectedPeers` still reports them. Cleared on
    /// `regenerateRoomCode()` / room-code rotation (new ceremony = clean
    /// slate).
    /// Peer IDs the initiator explicitly kicked from this ceremony.
    /// Keeps them out of `joinedSigners` on subsequent presence ticks
    /// until a full `regenerateRoomCode()` / room-code rotation (new ceremony = clean
    /// slate). `internal` (not private) so tests can observe the
    /// blocklist without calling internal reducer plumbing.
    var kickedPeerIds: Set<String> = []
    /// Three-word room code shared with co-signers to join this MPC session.
    /// Generated lazily when user advances to the invite step. Also used
    /// verbatim as the MPC `sessionId` so every participant derives the same
    /// session key; co-signers join the same relay room via `joinRelayRoom`.
    @Published var roomCode: String = ""
    /// True once we've called `peerManager.joinRelayRoom` with `roomCode`.
    /// Drives UI hints ("waiting for co-signers to join…" vs retry prompt).
    @Published var roomJoined: Bool = false
    /// Non-nil if joining the relay failed; shown in invite UI with a retry.
    @Published var roomJoinError: String?
    /// User-selected transports to announce the ceremony on. Default is
    /// relay + LAN, giving both remote and same-network cosigners a way
    /// to attach. The invite step exposes this as toggles; picking only
    /// LAN keeps the entire ceremony off the relay (privacy mode), and
    /// picking only relay avoids broadcasting on the local network.
    @Published var selectedTransports: Set<TransportType> = [.relay, .wifiLAN]

    /// When the current room code stops being advertised and the invite
    /// stops accepting new joiners. Limits the window in which a leaked
    /// code can be reused (e.g. photographed from a screen, pasted in
    /// the wrong chat). `nil` before invite is prepared. Refreshed on
    /// every `prepareInvite()` / `regenerateRoomCode()` call.
    @Published var roomCodeExpiresAt: Date?
    /// Driven by a 1 Hz timer in the invite view. `true` means the user
    /// must tap "generate a new code" before anyone can join.
    @Published var roomCodeExpired: Bool = false
    /// How long a freshly-minted room code stays valid. 5 min keeps the
    /// attack surface small without forcing users to re-negotiate during
    /// a normal sign session.
    static let roomCodeTTL: TimeInterval = 5 * 60
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
    private var customTokenStore: CustomTokenStore?
    private var deviceKey: Data?
    private var networkConfig: NetworkConfig?
    private var blockchainService: BlockchainService?
    // `internal` for @testable visibility; lifecycle is managed via
    // `prepareInvite` / `regenerateRoomCode` / `resignToSameRecipient`.
    var sessionId: String?
    private var currentRecordId: String?
    private var cancellables = Set<AnyCancellable>()
    private var signingTask: Task<Void, Never>?
    /// Periodic broadcast of `SignRequestDTO` while in the `.invite` step
    /// so cosigners who join the relay room late still see the request.
    private var announceTask: Task<Void, Never>?
    private var decodingFailures = 0
    private let maxDecodingFailures = 5

    // Gas estimation (EVM)
    @Published var estimatedGas: String = "—"
    @Published var estimatedFee: String = "—"
    @Published var isEstimatingGas = false
    /// Human-readable reason the current compose state can't be sent.
    /// Surfaced in `SigningView` under the amount field so the user
    /// sees "insufficient balance" *before* trying to sign, instead of
    /// losing the MPC race to a post-signing broadcast rejection.
    @Published var composeBlocker: String? = nil

    /// True when the user has entered a positive custom gas price in gwei
    /// (and the fee tier is `.custom`). Acts as an escape hatch when
    /// `estimateGas` failed — e.g. sending an ERC-20 the wallet has zero
    /// balance of, where the contract reverts with "invalid opcode" during
    /// eth_estimateGas but the user still wants to sign (offline / manual
    /// broadcast later). Used by `SigningView` to un-gate the Next button.
    var hasCustomGasOverride: Bool {
        guard feeTier == .custom else { return false }
        let trimmed = customGasPriceGwei.trimmingCharacters(in: .whitespaces)
        guard let v = Double(trimmed), v > 0 else { return false }
        return true
    }

    // Broadcast
    @Published var broadcastStatus: String?
    @Published var isBroadcasting = false

    /// For real BTC signing: holds the Rust-built unsigned segwit skeleton
    /// until we have the MPC signature, at which point we splice the
    /// witness and write the finalized hex into `txHash`.
    private var pendingBtcRawData: Data?
    private var pendingBtcInputCount: Int = 0

    /// For real EVM signing: holds the Rust-built unsigned EIP-1559 envelope
    /// (`0x02 || RLP(...)`) plus the gas estimate used to build it, so the
    /// post-signing step can splice in (y_parity, r, s) and broadcast.
    private var pendingEvmRawData: Data?
    private var pendingEvmGas: BlockchainService.EvmGasEstimate?

    /// Authoritative tx params shared by every participant.
    ///
    /// - On the **initiator** side this is populated by
    ///   `preresolveTxParams()` right before broadcasting `SignBeginDTO`;
    ///   `computeMessageHash` then reads from it instead of re-querying
    ///   the RPC.
    /// - On the **cosigner** side it's populated by the `SignBeginDTO`
    ///   handler in `awaitInitiatorStart` before `startSigning()` runs.
    ///
    /// Both sides reading from the **same** DTO guarantees identical
    /// nonce/gas/tx bytes → identical sighash → MPC signature that
    /// actually verifies on-chain.
    private var authoritativeTx: AuthoritativeTxParams?

    /// For real Solana signing: holds the serialized transfer message
    /// (which is identical to the sign payload) so we can prepend the
    /// MPC-produced ed25519 signature after signing completes.
    private var pendingSolMessage: Data?

    /// Map of `peer.id → MPC party index`, populated while we're in the
    /// `.invite` step by listening for `SignPresenceDTO` pings from each
    /// cosigner right after they approve the request. Used by
    /// `startSigning` to build a correctly-indexed `participants` list
    /// (e.g. `[1, 2]` for a 2-of-2 ceremony rather than the old
    /// `[1, 1]`). Entries for peers that never sent a "confirmed" ping
    /// (old clients, out-of-order packets) are filled in deterministically
    /// from the pool of unused party indices before signing starts.
    // `internal` for @testable visibility. Populated by kickPeer /
    // presence reducer; cleared by regenerateRoomCode/resignToSame.
    var peerPartyIndex: [String: UInt16] = [:]
    /// Background task that watches the MPC stream during `.invite` for
    /// incoming `SignPresenceDTO` packets carrying `partyIndex`.
    private var presenceListenerTask: Task<Void, Never>?

    /// TRON unsigned-tx context: we send `txID` (32-byte hash) to the MPC
    /// round, then replay `rawDataHex` + `rawDataJSON` to TronGrid on
    /// broadcast along with the produced signature.
    private var pendingTronTx: BlockchainService.TronUnsignedTx?

    /// ENS primary name (forward-verified) for the current `recipientAddress`,
    /// when it's a valid EVM address on Ethereum mainnet. Populated asynchronously
    /// after the user types or pastes the address. `nil` when no primary name is
    /// set or the chain isn't Ethereum mainnet.
    @Published var resolvedRecipientENS: String?
    private var ensLookupTask: Task<Void, Never>?

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

    /// 8-char hex fingerprint of the wallet's group public key. Shown on
    /// both the initiator's invite screen and the cosigner's review
    /// screen; reading them aloud to each other verifies the two sides
    /// are signing against the same wallet (prevents a same-room-code
    /// attacker from slipping in a lookalike wallet for signature).
    var walletFingerprint: String {
        wallet.groupPublicKey
            .prefix(4)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    var recipientExplorerURL: URL? {
        let canonical = AddressFormatter.canonical(recipientAddress, chain: wallet.chain)
        return AddressFormatter.explorerURL(address: canonical, chain: wallet.chain)
    }

    /// Kick off an ENS reverse lookup after the recipient field changes.
    /// No-op unless the wallet is on Ethereum mainnet and the input is a
    /// syntactically-valid 0x… address. Coalesces rapid changes by
    /// cancelling any in-flight task.
    private func triggerReverseENSLookup() {
        ensLookupTask?.cancel()
        resolvedRecipientENS = nil

        // Only Ethereum mainnet has a widely-used ENS deployment; other
        // chains either don't have ENS or use CCIP-read which we don't
        // support yet.
        guard wallet.chain == .ethereum else { return }
        let addr = recipientAddress.trimmingCharacters(in: .whitespaces)
        guard addr.lowercased().hasPrefix("0x"), addr.count == 42 else { return }

        ensLookupTask = Task { [weak self, addr] in
            // Tiny debounce so we don't hammer the RPC mid-typing.
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            let name = await ENSResolver.reverse(addr)
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                self?.resolvedRecipientENS = name
            }
        }
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
        self.customTokenStore = appState.customTokenStore
        do {
            self.deviceKey = try appState.deviceKey
        } catch {
            SecureLog.error("Failed to access device key: \(error.localizedDescription)")
            self.deviceKey = nil
        }
        self.networkConfig = appState.networkConfig
        self.blockchainService = appState.blockchainService

        // Observe connected peers as potential co-signers.
        // Deduplicate by normalized display name: the same physical
        // device can appear under two peer.ids when relay + wifi-lan
        // are both active, and Bonjour often appends a parenthetical
        // ("iPhone 16 (iPhone)") while the relay announce keeps the
        // plain UIDevice name ("iPhone 16"). Strip a trailing " (…)"
        // so both land on the same bucket.
        appState.peerManager.$connectedPeers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildJoinedSigners()
            }
            .store(in: &cancellables)
    }

    /// Recompute `joinedSigners` from `peerManager.connectedPeers` filtered
    /// by `peerPartyIndex` (explicit opt-in via `SignPresenceDTO`). Called
    /// both when the peer list itself changes and when we get a new
    /// presence ping — see `listenForPresence()`.
    @MainActor
    private func rebuildJoinedSigners() {
        guard let peerManager = peerManager else { return }
        var seen = Set<String>()
        var unique: [Peer] = []
        for peer in peerManager.connectedPeers {
            if kickedPeerIds.contains(peer.id) { continue }
            // Gate: only include peers that have actively opted into
            // *this* signing session via an authenticated
            // `SignPresenceDTO` ping. Without this filter every
            // connected peer (LAN neighbor, leftover relay tenant
            // from an earlier ceremony, etc.) would appear in the
            // invite list before they had any intent to cosign.
            guard peerPartyIndex[peer.id] != nil else { continue }
            let base = peer.name.isEmpty ? peer.id : peer.name
            let normalized = base
                .replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#,
                                      with: "",
                                      options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            let key = normalized.isEmpty ? base : normalized
            if seen.insert(key).inserted {
                unique.append(peer)
            }
        }
        joinedSigners = unique
    }

    /// Estimate gas / fees before signing (called when user fills amount + address).
    func estimateGas() {
        SecureLog.info("[estimateGas] called recipient='\(recipientAddress.prefix(10))...' amount='\(amount)' chain=\(wallet.chain.rawValue) svc=\(blockchainService != nil) cfg=\(networkConfig != nil)")
        guard !recipientAddress.isEmpty, !amount.isEmpty,
              let blockchainService, let networkConfig else {
            SecureLog.info("[estimateGas] early-return (empty fields or unbound)")
            return
        }
        guard let amountDecimal = Decimal(string: amount), amountDecimal > 0 else {
            errorMessage = "Invalid amount"
            SecureLog.info("[estimateGas] early-return (bad amount)")
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
                if wallet.chain.isEVM {
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
                    let rpc = networkConfig.rpcURL(for: wallet.chain)
                    let estimate = try await blockchainService.ethEstimateGas(
                        from: wallet.address,
                        to: txTo,
                        valueWei: txValueWei,
                        data: txData,
                        rpcURL: rpc
                    )
                    let feeDisplay = try await blockchainService.ethFeeEstimateDisplay(
                        from: wallet.address,
                        to: txTo,
                        valueWei: txValueWei,
                        rpcURL: rpc
                    )
                    await MainActor.run {
                        estimatedGas = "\(estimate.gasLimit)"
                        estimatedFee = "≈ \(feeDisplay.estimatedFee)"
                        isEstimatingGas = false
                        self.pendingEvmGas = estimate
                        self.composeBlocker = nil
                        SecureLog.info("[estimateGas] EVM ok gasLimit=\(estimate.gasLimit) fee=\(feeDisplay.estimatedFee)")
                    }
                } else {
                    switch wallet.chain {
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
                    case .tron:
                        // Native TRX transfer: ~345 byte bandwidth ≈ 0.345 TRX
                        // when the account has no free bandwidth.
                        // TRC-20: query /wallet/triggerconstantcontract for
                        // real energy_used, multiply by 420 SUN/unit, add
                        // ~345 B × 1000 SUN/B for bandwidth. Falls back to a
                        // conservative 14 TRX ceiling if the call fails.
                        let feeTRX: String
                        if let token = self.selectedToken {
                            let api = networkConfig.tronAPI
                            let rawAmount = Self.amountToRawUnits(amount, decimals: Int(token.decimals))
                            do {
                                let result = try await blockchainService.tronEstimateTRC20Fee(
                                    from: wallet.address,
                                    contract: token.id,
                                    to: recipientAddress,
                                    amountRaw: rawAmount,
                                    apiURL: api
                                )
                                let trx = Double(result.feeSun) / 1_000_000.0
                                feeTRX = L10n.SigningExtra.feeTRXEnergy(trx, result.energy)
                            } catch {
                                feeTRX = "≈ 14 TRX"
                            }
                        } else {
                            feeTRX = "≈ 0.3 TRX"
                        }
                        await MainActor.run {
                            estimatedFee = feeTRX
                            isEstimatingGas = false
                        }
                    case .litecoin:
                        // litecoinspace.org exposes the same Esplora + fees API
                        // as mempool.space, so we can reuse btcFeeEstimateDisplay.
                        do {
                            let feeDisplay = try await blockchainService.btcFeeEstimateDisplay(
                                inputCount: 1, outputCount: 2,
                                apiURL: networkConfig.litecoinAPI
                            )
                            // Replace BTC units in the display with LTC.
                            let ltcFee = feeDisplay.estimatedFee.replacingOccurrences(of: "BTC", with: "LTC")
                            await MainActor.run {
                                estimatedFee = "≈ \(ltcFee)"
                                isEstimatingGas = false
                            }
                        } catch {
                            await MainActor.run {
                                estimatedFee = L10n.Signing.unableToEstimate
                                isEstimatingGas = false
                            }
                        }
                    default:
                        await MainActor.run {
                            estimatedFee = L10n.Signing.unableToEstimate
                            isEstimatingGas = false
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    estimatedFee = L10n.Signing.unableToEstimate
                    estimatedGas = "—"
                    isEstimatingGas = false
                    // Classify the most common failure. The exact RPC
                    // error surface varies by provider; match on
                    // substrings rather than types for resilience.
                    let lower = error.localizedDescription.lowercased()
                    if lower.contains("insufficient funds") || lower.contains("insufficient balance") {
                        self.composeBlocker = L10n.Signing.insufficientBalance
                    } else if lower.contains("timeout") || lower.contains("timed out")
                                || lower.contains("offline") || lower.contains("unreachable")
                                || lower.contains("network") || lower.contains("connection") {
                        self.composeBlocker = L10n.Signing.estimateNetworkError
                    } else {
                        self.composeBlocker = L10n.Signing.cannotEstimateFee
                    }
                    SecureLog.error("[estimateGas] failed: \(error.localizedDescription)")
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

    /// Cosigner-only entry point. Called from `JoinSigningView` after the
    /// user approves the incoming `SignRequestDTO`. Unlike the initiator,
    /// the cosigner must NOT immediately call `bridge.startSigning` —
    /// doing so would emit round-1 messages into a stream that the
    /// initiator has not yet subscribed to (they are still on the invite
    /// step waiting for "Start Signing"). Instead we:
    ///   1. Flip to `.signing` so the progress UI mounts and subscribes.
    ///   2. Spawn a task that listens for a `SignBeginDTO` from the
    ///      initiator; on receipt we invoke `startSigning()` locally,
    ///      which is synchronous with the initiator's own invocation.
    /// This produces a reliable barrier: both sides call
    /// `bridge.startSigning` only after every peer is listening, so no
    /// round-1 message is ever lost.
    func awaitInitiatorStart() {
        isCosigner = true
        step = .signing
        signingStartedAt = Date()
        currentRound = 0
        totalRounds = wallet.chain.curveType == .ed25519 ? 2 : 4
        signingStatusMessage = L10n.Signing.waitingForInitiator

        // Kick straight into startSigning. The cosigner path inside the
        // signingTask subscribes the MPC stream *first*, then drains it
        // until `SignBeginDTO` arrives (setting `authoritativeTx`), then
        // proceeds with buildSignHash + bridge.startSigning on the same
        // already-advanced iterator. A single subscription spans the
        // whole ceremony — there is no window in which messages can be
        // yielded to zero subscribers.
        //
        // Earlier designs ran a separate begin-listener Task that held
        // its own subscription and then `return`ed on receipt of
        // SignBeginDTO. `AsyncStream.onTermination` fires when the
        // iterator is deallocated, so the for-await drop on return tore
        // down the continuation; the FROST round-1 packets arriving ~500
        // ms later (logged as "yielding 13543B to 0 subscriber(s)") hit a
        // dead stream and were silently dropped, stalling the ceremony.
        startSigning()
    }
    /// True on a cosigner's VM so `startSigning` skips the "broadcast begin"
    /// handshake (only the initiator sends it).
    private var isCosigner: Bool = false

    /// Move from the compose step to the invite step. Generates a fresh
    /// three-word `roomCode`, joins the relay room so co-signers with the
    /// same code can connect, and pins that code as the MPC `sessionId`.
    /// Safe to call multiple times — on retry we reuse the existing code.
    func prepareInvite() {
        if roomCode.isEmpty {
            roomCode = RoomCode.generate()
            roomCodeExpiresAt = Date().addingTimeInterval(Self.roomCodeTTL)
            roomCodeExpired = false
        } else if roomCodeExpiresAt == nil {
            // Defensive: if we re-enter invite with an existing code
            // and no timer, kick one off so it will eventually expire.
            roomCodeExpiresAt = Date().addingTimeInterval(Self.roomCodeTTL)
            roomCodeExpired = false
        }
        // MPC sessionId == roomCode regardless of transport — the bridge
        // keys its session state off this ID on every participant.
        sessionId = roomCode
        roomJoinError = nil
        step = .invite
        startPresenceListener()

        // LAN visibility is user-gated: only advertise on Bonjour if
        // the user actually wants same-network cosigners to see us.
        if selectedTransports.contains(.wifiLAN) {
            peerManager?.wifiLAN.startDiscovery()
        } else {
            peerManager?.wifiLAN.stopDiscovery()
        }

        // Relay is similarly opt-in. Skipping it keeps the ceremony
        // entirely off the server (LAN-only privacy mode).
        guard selectedTransports.contains(.relay) else {
            roomJoined = false
            startAnnounceLoop()
            return
        }

        guard let peerManager, !roomJoined else {
            startAnnounceLoop()
            return
        }
        let code = roomCode
        Task { [weak self] in
            do {
                try await peerManager.joinRelayRoom(roomId: code)
                await MainActor.run {
                    self?.roomJoined = true
                    self?.startAnnounceLoop()
                    SecureLog.info("[signing] joined relay room \(code)")
                }
            } catch {
                await MainActor.run {
                    self?.roomJoinError = error.localizedDescription
                    SecureLog.error("[signing] joinRelayRoom failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Retry relay room join after a failure. UI binds to this from the
    /// invite step when `roomJoinError != nil`.
    func retryJoinRoom() {
        roomJoined = false
        roomJoinError = nil
        prepareInvite()
    }

    /// Throw away the current room code and mint a fresh one. Called
    /// when the TTL expires or the user manually requests a rotation.
    /// We also clear any already-accumulated cosigners since they joined
    /// against the old code and shouldn't be counted toward the new
    /// ceremony; the announce beacon + a new `joinRelayRoom` kick off
    /// discovery against the new code.
    func regenerateRoomCode() {
        announceTask?.cancel()
        announceTask = nil
        // Close the old relay room immediately so the server can GC it
        // rather than waiting on its idle timer. Best-effort: if the
        // peer manager is nil (never connected) we skip.
        peerManager?.leaveRelayRoom()
        roomCode = RoomCode.generate()
        sessionId = roomCode
        roomCodeExpiresAt = Date().addingTimeInterval(Self.roomCodeTTL)
        roomCodeExpired = false
        roomJoined = false
        roomJoinError = nil
        peerPartyIndex.removeAll()
        kickedPeerIds.removeAll()
        rebuildJoinedSigners()
        prepareInvite()
    }

    /// Remove a peer from the current ceremony. The peer is added to a
    /// local blocklist so they don't pop back into `joinedSigners` on
    /// the next `connectedPeers` tick; they can only re-participate by
    /// the initiator rotating the room code (at which point the
    /// blocklist is cleared — fresh ceremony, fresh slate).
    ///
    /// Note: this is a one-sided dismissal. The kicked peer is still
    /// in the underlying relay/LAN room (we don't have an authenticated
    /// kick message), so they might still see late broadcasts. That's
    /// why we pair this with `regenerateRoomCode()` in the UI when the
    /// user wants a harder reset — new code, old peer gone for real.
    func kickPeer(_ peer: Peer) {
        kickedPeerIds.insert(peer.id)
        peerPartyIndex.removeValue(forKey: peer.id)
        joinedSigners.removeAll { $0.id == peer.id }
        SecureLog.info("[signing] kicked peer \(peer.id) from ceremony")
    }

    /// Bounce back to `.compose` while preserving the recipient and
    /// token selection from the just-completed tx, so the user can
    /// fire off another transfer to the same address without retyping
    /// it. We reset everything tied to the *previous* ceremony —
    /// amount (new transfer, new amount), fee estimates (stale),
    /// session/room/peer state, tx hash, broadcast status, etc. — but
    /// keep `recipientAddress` + `selectedToken` as a "sticky" pair.
    ///
    /// Called from the complete screen's "Sign again" quick-action.
    func resignToSameRecipient() {
        // Hold on to what we want to keep before wiping step state.
        let keepRecipient = recipientAddress
        let keepToken = selectedToken

        // Tear down ceremony state so the next compose starts clean.
        announceTask?.cancel()
        announceTask = nil
        peerManager?.leaveRelayRoom()
        presenceListenerTask?.cancel()
        presenceListenerTask = nil
        joinedSigners.removeAll()
        peerPartyIndex.removeAll()
        kickedPeerIds.removeAll()
        peerStates.removeAll()
        peerRounds.removeAll()
        sessionId = nil
        roomCode = ""
        roomJoined = false
        roomJoinError = nil
        roomCodeExpiresAt = nil
        roomCodeExpired = false
        authoritativeTx = nil
        txHash = nil
        broadcastStatus = nil
        isBroadcasting = false
        signingProgress = 0
        signingStatusMessage = ""
        currentRound = 0
        errorMessage = ""
        composeBlocker = nil

        // Amount resets — the user almost certainly wants a different
        // amount next time. Fee tier stays at whatever they last picked.
        amount = ""
        estimatedFee = "—"

        // Restore stickies and return to the compose step.
        recipientAddress = keepRecipient
        selectedToken = keepToken
        step = .compose
    }

    /// Called ~once per second by the invite view's ticker to surface
    /// the "code expired" state. Cheap idempotent operation; we keep
    /// the state-diff check so SwiftUI only re-renders when it flips.
    func tickRoomCodeExpiry() {
        guard step == .invite, let expires = roomCodeExpiresAt else { return }
        let shouldExpire = Date() >= expires
        if shouldExpire != roomCodeExpired {
            roomCodeExpired = shouldExpire
            if shouldExpire {
                // Stop advertising the expired code; a new one will be
                // minted via `regenerateRoomCode()` when the user taps
                // the regenerate button.
                announceTask?.cancel()
                announceTask = nil
            }
        }
    }

    /// Seconds remaining on the current room code. Returns 0 once
    /// expired so the UI can show "0:00" briefly before flipping to
    /// the regenerate CTA. Nil before `prepareInvite` runs.
    var roomCodeSecondsRemaining: Int? {
        guard let expires = roomCodeExpiresAt else { return nil }
        return max(0, Int(expires.timeIntervalSinceNow.rounded()))
    }

    /// Periodically broadcast a `SignRequestDTO` while still in the invite
    /// step so any cosigner who joins the relay room late sees the request
    /// without needing a re-tap from the initiator. Stops automatically
    /// once `step` advances past `.invite` or the VM is deallocated.
    private func startAnnounceLoop() {
        announceTask?.cancel()
        guard let peerManager, !roomCode.isEmpty else { return }
        let dto = buildSignRequestDTO()
        guard let payload = try? JSONEncoder().encode(dto) else { return }
        announceTask = Task { [weak self] in
            // Rapid early beacon: first 6 broadcasts ~300ms apart to catch
            // a cosigner joining right after the initiator, then slow to
            // every 2s to limit relay traffic.
            var interval: UInt64 = 300_000_000
            var count = 0
            while let self, !Task.isCancelled {
                if await MainActor.run(body: { self.step != .invite }) { return }
                try? await peerManager.broadcastMpcMessage(payload)
                count += 1
                if count >= 6 { interval = 2_000_000_000 }
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    /// Subscribe to the MPC stream while still in the invite step and
    /// harvest every incoming `SignPresenceDTO` into `peerPartyIndex`.
    /// The mapping is then used by `startSigning()` to build a
    /// correctly-populated `participants` array.
    ///
    /// Cosigners send two presence pings: one on join (no partyIndex
    /// yet, harmless) and one right after `approve` with partyIndex
    /// filled. We accept both; only the second populates the map.
    private func startPresenceListener() {
        guard let peerManager else { return }
        presenceListenerTask?.cancel()
        presenceListenerTask = Task { [weak self] in
            let (subId, stream) = peerManager.mpcMessageStream()
            defer { peerManager.unsubscribeMpc(subId) }
            for await (peer, data) in stream {
                guard let self else { return }
                if Task.isCancelled { return }
                guard let dto = try? JSONDecoder().decode(SignPresenceDTO.self, from: data),
                      dto.magic == SignPresenceDTO.magic,
                      let idx = dto.partyIndex else { continue }
                // Scope presence to the active room. Without this, a
                // presence ping left over from a *previous* ceremony
                // (or a stray peer dialed into an unrelated session
                // over the same relay connection) would pre-populate
                // `peerPartyIndex` and therefore `joinedSigners`,
                // which is exactly what caused ghost entries to show
                // up in the invite list before anyone had joined.
                let activeSession = await MainActor.run { self.roomCode }
                guard dto.sessionId == activeSession, !activeSession.isEmpty else { continue }
                await MainActor.run {
                    self.peerPartyIndex[peer.id] = idx
                    SecureLog.info("[signing] presence: peer=\(peer.id.prefix(8)) party=\(idx)")
                    // `joinedSigners` is derived from a snapshot of
                    // `connectedPeers ∩ peerPartyIndex`, and the
                    // `connectedPeers` publisher only fires on peer
                    // list changes — not on our internal state. Kick
                    // the reducer manually so a peer that was already
                    // in `connectedPeers` but freshly approved shows
                    // up in the invite list right away.
                    self.rebuildJoinedSigners()
                }
            }
        }
    }

    private func buildSignRequestDTO() -> SignRequestDTO {
        let gpkHex = wallet.groupPublicKey.map { String(format: "%02x", $0) }.joined()
        return SignRequestDTO(
            sessionId: roomCode,
            groupPublicKey: gpkHex,
            chain: wallet.chain.rawValue,
            recipient: recipientAddress,
            amount: amount,
            tokenContract: selectedToken?.id,
            tokenSymbol: selectedToken?.symbol,
            tokenDecimals: selectedToken.map { $0.decimals },
            feeDisplay: estimatedFee == "—" ? nil : estimatedFee,
            initiatorDeviceName: DeviceIdentity.displayName
        )
    }

    /// Populate this VM from a received `SignRequestDTO` so a cosigner's
    /// local signing flow mirrors the initiator's exactly. The caller is
    /// responsible for setting `roomCode` to match and pinning the wallet
    /// (via the VM initializer) before invoking.
    func applySignRequest(_ dto: SignRequestDTO) {
        self.roomCode = dto.sessionId
        self.sessionId = dto.sessionId
        self.recipientAddress = dto.recipient
        self.amount = dto.amount
        // Token lookup: check built-in list first, then custom tokens.
        if let contract = dto.tokenContract?.lowercased() {
            let built = TokenList.tokens(for: wallet.chain)
                .first { $0.id.lowercased() == contract }
            let custom = customTokenStore?.effectiveTokens(for: wallet.chain)
                .first { $0.id.lowercased() == contract }
            self.selectedToken = built ?? custom
        }
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
        // Stop the invite-step sign-request beacon now that signing begins;
        // rebroadcasting it during signing would only add relay noise.
        announceTask?.cancel()
        announceTask = nil
        // Presence listener is only useful while we're still in invite;
        // once signing starts, all further traffic is real MPC bytes.
        presenceListenerTask?.cancel()
        presenceListenerTask = nil
        // sessionId was pinned by prepareInvite() to match roomCode so all
        // participants share the same MPC session. Fall back to a fresh
        // UUID only if someone bypassed prepareInvite (defensive).
        if sessionId == nil || sessionId?.isEmpty == true {
            sessionId = roomCode.isEmpty ? UUID().uuidString : roomCode
        }
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
                // Subscribe to the MPC stream BEFORE broadcasting SignBeginDTO
                // (initiator) or waiting for it (cosigner). AsyncStream buffers
                // `.unbounded` by default, so any early arrivals queue safely
                // until we drain them below.
                //
                // Single subscription spans the entire ceremony. On the
                // cosigner path we iterate this very stream until SignBeginDTO
                // arrives, stash authoritativeTx, then hand the already-
                // advanced iterator to `runSigningRounds` (which resumes
                // reading without ever tearing the subscription down).
                //
                // Historical stall: an earlier design ran a separate
                // begin-listener Task that held its own subscription and
                // returned from its for-await on SignBeginDTO. AsyncStream's
                // onTermination fires when the iterator deallocates — the
                // continuation was killed at that moment and the FROST
                // round-1 packets arriving ~500 ms later (e.g. 13.5 KB +
                // 21.7 KB, logged as "yielding to 0 subscriber(s)") were
                // silently dropped.
                let (mpcSubId, mpcStream) = peerManager.mpcMessageStream()
                var mpcSubActive = true
                defer {
                    if mpcSubActive { peerManager.unsubscribeMpc(mpcSubId) }
                }
                var mpcIterator = mpcStream.makeAsyncIterator()
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

                // Pre-resolve authoritative tx parameters exactly once.
                // The initiator fetches nonce + gas here, stashes them,
                // and hands them to every cosigner via `SignBeginDTO`.
                // From this point `computeMessageHash` reads from the
                // authoritative struct, so no participant ever makes an
                // independent RPC call and no two participants can drift.
                if !isCosigner {
                    try await preresolveTxParams()
                } else {
                    // Cosigner: drain the MPC iterator until the initiator's
                    // SignBeginDTO arrives with authoritative tx params, then
                    // fall through with the iterator already advanced past it.
                    // Non-SignBegin packets that land here (e.g. stale
                    // presence pings) are discarded — real FROST rounds only
                    // start after SignBeginDTO so anything before it is
                    // either another control DTO or a packet from a previous
                    // ceremony in the same room.
                    let expectedSession = sessionId ?? roomCode
                    NSLog("[signing] cosigner waiting for SignBegin session=%@", expectedSession)
                    while !Task.isCancelled {
                        guard let (_, data) = await mpcIterator.next() else {
                            NSLog("[signing] cosigner iterator finished before SignBegin")
                            throw SigningError.notInitialized
                        }
                        NSLog("[signing] cosigner rx %dB while waiting SignBegin", data.count)
                        if let begin = try? JSONDecoder().decode(SignBeginDTO.self, from: data),
                           begin.magic == SignBeginDTO.magic,
                           begin.sessionId == expectedSession {
                            NSLog("[signing] cosigner got SignBegin")
                            await MainActor.run { self.authoritativeTx = begin.tx }
                            break
                        }
                    }
                }

                NSLog("[signing] building sign hash (isCosigner=%d)", isCosigner ? 1 : 0)
                // Build the transaction hash to sign
                let messageHash = try await buildSignHash()
                NSLog("[signing] sign hash built (%dB)", messageHash.count)

                // Collect participant indices.
                //
                // Prefer each joined peer's self-reported party index
                // (received via `SignPresenceDTO` into `peerPartyIndex`);
                // fall back to the smallest unused index in
                // `1...totalParties \ {myIndex, already-assigned}` for
                // peers we never got a partyIndex ping from (old
                // clients, or packet lost).
                //
                // Historical bug: the old code was
                //   `[wallet.partyIndex] + joinedSigners.prefix(k-1)
                //      .enumerated().map { UInt16($0.offset + 1) }`
                // which produced `[1, 1]` whenever the initiator itself
                // was party 1 and filled cosigner slots starting at 1,
                // breaking any 2-of-2 ceremony initiated by party 1.
                let myIndex = wallet.partyIndex
                let neededCosigners = Int(wallet.threshold) - 1
                var assigned: Set<UInt16> = [myIndex]
                var cosignerIndices: [UInt16] = []
                let joined = Array(joinedSigners.prefix(neededCosigners))
                var unresolved: [Peer] = []
                for peer in joined {
                    if let idx = peerPartyIndex[peer.id],
                       idx != myIndex,
                       !assigned.contains(idx),
                       idx >= 1, idx <= wallet.totalParties {
                        cosignerIndices.append(idx)
                        assigned.insert(idx)
                    } else {
                        unresolved.append(peer)
                    }
                }
                // Fill any unresolved slots with the smallest unused
                // indices. Deterministic so both sides agree even if
                // the ping was dropped.
                if !unresolved.isEmpty {
                    var next: UInt16 = 1
                    for _ in unresolved {
                        while next <= wallet.totalParties && assigned.contains(next) {
                            next += 1
                        }
                        guard next <= wallet.totalParties else { break }
                        cosignerIndices.append(next)
                        assigned.insert(next)
                    }
                }
                let participants = ([myIndex] + cosignerIndices).sorted()
                SecureLog.info("[signing] participants=\(participants) threshold=\(wallet.threshold)/\(wallet.totalParties) me=\(myIndex)")

                signingStatusMessage = L10n.Signing.initializingProtocol
                currentRound = 1

                // Initiator-only handshake: broadcast a `SignBeginDTO`
                // carrying the authoritative tx params so every waiting
                // cosigner (a) applies identical nonce/gas and (b) calls
                // `bridge.startSigning` at essentially the same moment.
                // The short sleep gives cosigners time to receive the
                // DTO, subscribe to the MPC stream and be ready to
                // catch our round-1 output.
                if !isCosigner, let sid = sessionId,
                   let payload = try? JSONEncoder().encode(
                        SignBeginDTO(sessionId: sid, tx: authoritativeTx)) {
                    try? await peerManager.broadcastMpcMessage(payload)
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }

                let outgoing = try bridge.startSigning(
                    sessionId: sessionId!,
                    config: config,
                    messageHash: messageHash,
                    shardData: shardData,
                    participants: participants
                )
                NSLog("[signing] startSigning me=%d participants=%@ initial=%d hash=%@",
                      Int(myIndex),
                      participants.map { String($0) }.joined(separator: ","),
                      outgoing.count,
                      messageHash.map { String(format: "%02x", $0) }.joined().prefix(16).description)

                signingProgress = 0.2

                mpcSubActive = false
                await runSigningRounds(
                    initialMessages: outgoing,
                    subId: mpcSubId,
                    mpcIterator: mpcIterator
                )

            } catch {
                NSLog("[signing] signingTask error: %@ (cancelled=%d)", error.localizedDescription, Task.isCancelled ? 1 : 0)
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
        presenceListenerTask?.cancel()
        presenceListenerTask = nil
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

    private func runSigningRounds(
        initialMessages: [FfiMpcMessage],
        subId: UUID,
        mpcIterator: AsyncStream<(Peer, Data)>.Iterator
    ) async {
        guard let bridge, let peerManager else { return }

        defer { peerManager.unsubscribeMpc(subId) }

        // The iterator is passed in already advanced past SignBeginDTO
        // (cosigner) or fresh (initiator). Capture it into a local `var`
        // so we can call `next()` — AsyncStream.Iterator is a struct and
        // `next()` is mutating.
        var iterator = mpcIterator

        do {
            // Send initial messages
            for msg in initialMessages {
                let data = try JSONEncoder().encode(MpcMessageDTO(msg))
                try await peerManager.broadcastMpcMessage(data)
            }

            // Dedupe EXACT byte-for-byte duplicates (same payload arrived
            // on relay + wifi-lan). Do NOT dedupe by (fromParty, round)
            // because CMP/GG18 can emit multiple distinct messages in a
            // single round (e.g. Paillier commit + proof); those must
            // all reach the bridge.
            var seenMessages = Set<Data>()

            // Process incoming messages
            while let (peer, data) = await iterator.next() {
                // Drop exact-byte duplicates before even decoding. SHA-256
                // keeps the set bounded in size vs storing raw bytes.
                let digest = Data(SHA256.hash(data: data))
                if !seenMessages.insert(digest).inserted {
                    NSLog("[signing] dup drop from %@ (%dB)", peer.id, data.count)
                    continue
                }
                NSLog("[signing] rx from %@ (%dB, unique)", peer.id, data.count)
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

                    // Drop P2P messages addressed to a *different* concrete
                    // party. Over a broadcast relay room every participant
                    // sees every packet. Without this filter the state
                    // machine rejects foreign traffic as "party N tried to
                    // overwrite message".
                    //
                    // IMPORTANT: treat `toParty == fromParty` as a
                    // self-labeled broadcast — CMP/GG18 bridges often tag
                    // round-output messages this way ("message from party
                    // X as part of their broadcast round"), and every
                    // counterparty must process them. Skipping would
                    // deprive the peer of half of round 1 (Paillier
                    // commit + proof) and stall the ceremony.
                    let myPartyIndex = wallet.partyIndex
                    if msg.toParty != 0
                        && msg.toParty != myPartyIndex
                        && msg.toParty != msg.fromParty {
                        NSLog("[signing] skip p2p to=%d me=%d from=%d r=%d", msg.toParty, myPartyIndex, msg.fromParty, msg.round)
                        continue
                    }

                    NSLog("[signing] handleMessage from=%d to=%d r=%d (%dB)", msg.fromParty, msg.toParty, msg.round, data.count)
                    let responses = try bridge.handleMessage(msg)
                    NSLog("[signing] bridge produced %d responses", responses.count)

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

                        // Default: raw 64-byte ECDSA signature hex. For
                        // P2WPKH chains (BTC/LTC) we splice into the stashed
                        // raw tx; for EVM we RLP-wrap with (r,s,yParity).
                        if let finalBtcHex = finalizeBitcoinSignedTx(signature: result.signature) {
                            txHash = finalBtcHex
                        } else if let finalEvmHex = finalizeEvmSignedTx(
                            signature: result.signature,
                            recoveryId: result.recoveryId
                        ) {
                            txHash = finalEvmHex
                        } else if let finalSolB64 = finalizeSolanaSignedTx(signature: result.signature) {
                            txHash = finalSolB64
                        } else if let finalTronTxID = finalizeTronSignedTx(
                            signature: result.signature,
                            recoveryId: result.recoveryId
                        ) {
                            txHash = finalTronTxID
                        } else {
                            txHash = "0x" + result.signature.map { String(format: "%02x", $0) }.joined()
                        }

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
                        // Remember who we just signed with so the next
                        // invite screen can surface "Last signed with
                        // XX" and skip the name-guessing step.
                        let walletId = wallet.id
                        let signers = joinedSigners
                        Task { @MainActor in
                            for peer in signers {
                                RecentCoSignersStore.shared.record(
                                    peerId: peer.id,
                                    name: peer.name,
                                    walletId: walletId
                                )
                            }
                        }
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

    /// Resolve nonce + gas + value + calldata **once**, stash into
    /// `authoritativeTx`. Called by the initiator immediately before
    /// broadcasting `SignBeginDTO`; cosigners skip this and take the
    /// wire value verbatim.
    private func preresolveTxParams() async throws {
        guard wallet.chain.isEVM else {
            // Non-EVM chains don't share fee/nonce semantics across
            // participants in the same way; leave authoritativeTx nil.
            return
        }
        guard let networkConfig else { return }

        let (txTo, txValueWei, txData): (String, String, Data) = {
            if let token = self.selectedToken {
                let raw = Self.amountToRawUnits(amount, decimals: Int(token.decimals))
                let data = Self.erc20TransferCalldata(to: recipientAddress, amountRaw: raw)
                return (token.id, "0", data)
            }
            return (recipientAddress, ethToWei(amount), Data())
        }()

        let chainId: UInt64 = {
            if wallet.chain == .ethereum { return networkConfig.evmChainId }
            return wallet.chain.defaultEVMNetwork?.rawValue ?? networkConfig.evmChainId
        }()
        let rpc = networkConfig.rpcURL(for: wallet.chain)

        let rpcNonce: UInt64 = (try? await blockchainService?.ethNonce(
            address: wallet.address, rpcURL: rpc)) ?? 0
        let nonce = PendingNonceTracker.shared.nextNonce(
            chainId: chainId, address: wallet.address, rpcNonce: rpcNonce
        )
        PendingNonceTracker.shared.record(
            chainId: chainId, address: wallet.address, nonce: nonce
        )

        let gas = self.pendingEvmGas
        let gasLimit: UInt64 = gas?.gasLimit ?? UInt64(estimatedGas) ?? 21000
        let tier = self.feeTier
        let maxFee: String
        let maxPriority: String
        if tier == .custom, let gwei = Double(self.customGasPriceGwei), gwei > 0 {
            let weiStr = String(UInt64(gwei * 1e9))
            maxFee = weiStr
            maxPriority = weiStr
        } else {
            maxFee = Self.scaleDecimalWei(gas?.maxFeePerGas ?? "0", by: tier.multiplier)
            maxPriority = Self.scaleDecimalWei(gas?.maxPriorityFeePerGas ?? "0", by: tier.multiplier)
        }

        self.authoritativeTx = AuthoritativeTxParams(
            chainId: chainId,
            nonce: nonce,
            gasLimit: gasLimit,
            maxFeePerGasWei: maxFee,
            maxPriorityFeePerGasWei: maxPriority,
            to: txTo,
            valueWei: txValueWei,
            dataHex: txData.map { String(format: "%02x", $0) }.joined()
        )
    }

    private func buildSignHash() async throws -> Data {
        guard let networkConfig else {
            // Fallback: hash a placeholder
            return horcruxKeccak256(data: Data("\(amount) \(wallet.chain.symbol) → \(recipientAddress)".utf8))
        }

        if wallet.chain.isEVM {
            // Build real EIP-1559 sign hash via Rust FFI.
            //
            // IMPORTANT: Every participant MUST hash the byte-identical
            // transaction envelope for the MPC signature to be valid.
            // If `authoritativeTx` is already populated — either we are
            // the initiator after `preresolveTxParams()` or we are a
            // cosigner whose `SignBeginDTO` listener stashed the wire
            // values — use those verbatim. Falling back to local RPC
            // here would let nonce or gas drift between sides.
            let auth = self.authoritativeTx
            let (txTo, txValueWei, txData): (String, String, Data) = {
                if let a = auth {
                    let bytes = Self.hexToData(a.dataHex) ?? Data()
                    return (a.to, a.valueWei, bytes)
                }
                if let token = self.selectedToken {
                    let raw = Self.amountToRawUnits(amount, decimals: Int(token.decimals))
                    let data = Self.erc20TransferCalldata(to: recipientAddress, amountRaw: raw)
                    return (token.id, "0", data)
                }
                return (recipientAddress, ethToWei(amount), Data())
            }()
            let chainId: UInt64 = auth?.chainId ?? {
                if wallet.chain == .ethereum { return networkConfig.evmChainId }
                return wallet.chain.defaultEVMNetwork?.rawValue ?? networkConfig.evmChainId
            }()
            let rpc = networkConfig.rpcURL(for: wallet.chain)

            let nonce: UInt64
            if let n = auth?.nonce {
                nonce = n
            } else {
                // Legacy path (no DTO yet, or non-EVM initiator we
                // haven't refactored): re-query nonce here.
                let rpcNonce: UInt64 = (try? await blockchainService?.ethNonce(
                    address: wallet.address, rpcURL: rpc)) ?? 0
                nonce = PendingNonceTracker.shared.nextNonce(
                    chainId: chainId, address: wallet.address, rpcNonce: rpcNonce
                )
                PendingNonceTracker.shared.record(
                    chainId: chainId, address: wallet.address, nonce: nonce
                )
            }

            let gasLimit: UInt64
            let maxFee: String
            let maxPriority: String
            if let a = auth {
                gasLimit = a.gasLimit ?? 21000
                maxFee = a.maxFeePerGasWei
                maxPriority = a.maxPriorityFeePerGasWei
            } else {
                let gas = self.pendingEvmGas
                gasLimit = gas?.gasLimit ?? UInt64(estimatedGas) ?? 21000
                let tier = self.feeTier
                if tier == .custom, let gwei = Double(self.customGasPriceGwei), gwei > 0 {
                    let weiStr = String(UInt64(gwei * 1e9))
                    maxFee = weiStr
                    maxPriority = weiStr
                } else {
                    maxFee = Self.scaleDecimalWei(gas?.maxFeePerGas ?? "0", by: tier.multiplier)
                    maxPriority = Self.scaleDecimalWei(gas?.maxPriorityFeePerGas ?? "0", by: tier.multiplier)
                }
            }

            let params = FfiEvmTxParams(
                to: txTo,
                valueWei: txValueWei,
                nonce: nonce,
                gasLimit: gasLimit,
                maxFeePerGas: maxFee,
                maxPriorityFeePerGas: maxPriority,
                chainId: chainId,
                data: txData
            )
            if let tx = try? horcruxBuildEvmTransaction(params: params) {
                self.pendingEvmRawData = tx.rawData
                return tx.signHash
            }
            // Fallback: hash a stable string representation
            let txBytes = "\(params.chainId):\(params.nonce):\(params.to):\(params.valueWei):\(params.gasLimit):\(txData.count)"
            return horcruxKeccak256(data: Data(txBytes.utf8))
        }

        switch wallet.chain {
        case .bitcoin, .litecoin:
            // Real end-to-end signing for P2WPKH segwit chains (BTC + LTC
            // share the Esplora API shape and BIP-143 sighash path). Fetch
            // UTXOs, coin-select, build unsigned skeleton via Rust, stash
            // raw_data so the post-signing step can splice the witness.
            if let hash = try? await buildP2WPKHSignHash() {
                return hash
            }
            // Fallback placeholder if UTXO fetch / build fails.
            let txData = "\(amount) \(wallet.chain.symbol) → \(recipientAddress)"
            return horcruxKeccak256(data: Data(txData.utf8))

        case .solana:
            // Real Solana signing: fetch a recent blockhash, build a
            // System Program transfer via Rust, stash the message bytes
            // (raw_data == sign payload for SOL) so the post-signing step
            // can prepend the ed25519 signature and produce a base64 tx.
            if let built = try? await buildSolanaSignHash() {
                return built
            }
            // Placeholder fallback so the preview doesn't crash if the
            // RPC hiccups.
            let txData = "\(amount) SOL → \(recipientAddress)"
            return Data(txData.utf8)

        case .tron:
            // Real TRON signing — ask TronGrid to build the unsigned tx
            // (TRX transfer or TRC-20 `transfer(address,uint256)`), stash
            // the raw_data so we can replay it on broadcast, and return the
            // 32-byte txID as the hash the MPC round will sign.
            if let built = try? await buildTronSignHash() {
                return built
            }
            let txData = "\(amount) TRX → \(recipientAddress)"
            return horcruxKeccak256(data: Data(txData.utf8))

        default:
            return horcruxKeccak256(data: Data("\(amount) \(wallet.chain.symbol) → \(recipientAddress)".utf8))
        }
    }

    /// Fetch UTXOs for the wallet, pick one that covers amount + fee, build
    /// the unsigned P2WPKH segwit skeleton via Rust, and return the BIP-143
    /// sighash for input 0. Mutates `pendingBtcRawData` / `pendingBtcInputCount`
    /// so the post-signing step can splice the final witness.
    ///
    /// MVP scope: single-input, one-or-two-output (recipient + optional change),
    /// mainnet only, bech32 P2WPKH recipient only. Works for both Bitcoin
    /// and Litecoin (hrp differs but the signing & finalizer paths are
    /// byte-for-byte identical — Litespace exposes the same Esplora API).
    private func buildP2WPKHSignHash() async throws -> Data {
        guard let networkConfig, let blockchainService else {
            throw SigningError.notInitialized
        }
        let apiURL: String
        switch wallet.chain {
        case .bitcoin: apiURL = networkConfig.bitcoinAPI
        case .litecoin: apiURL = networkConfig.litecoinAPI
        default: throw SigningError.notInitialized
        }

        // 1. Fetch UTXOs (confirmed only to avoid replace-by-fee surprises).
        let utxos = try await blockchainService.btcUtxos(address: wallet.address, apiURL: apiURL)
        let confirmed = utxos.filter { $0.status.confirmed }.sorted { $0.value > $1.value }
        guard !confirmed.isEmpty else { throw SigningError.notInitialized }

        // 2. Parse send amount (BTC → sats).
        let sendSats = Self.btcAmountToSats(amount)
        guard sendSats > 0 else { throw SigningError.notInitialized }

        // 3. Fee estimate. Fall back to 2 sat/vB if the API hiccups.
        //    Apply the user's fee tier — .fast uses fastestFee, .slow uses
        //    economyFee (falls back to halfHour × 0.85), .normal stays on
        //    halfHourFee. Custom tier isn't exposed for UTXO chains yet
        //    and falls through as normal.
        let satPerVbyte: UInt64
        if feeTier == .custom, let v = UInt64(customGasPriceGwei.trimmingCharacters(in: .whitespaces)), v >= 1 {
            // User-provided sat/vB.
            satPerVbyte = v
        } else if let rate = try? await blockchainService.btcFeeEstimate(apiURL: apiURL) {
            let base = rate.halfHourFee
            let scaled: UInt64 = {
                switch feeTier {
                case .fast: return rate.fastestFee
                case .slow: return max(UInt64(Double(base) * 0.85), 1)
                case .normal, .custom: return base
                }
            }()
            satPerVbyte = max(scaled, 1)
        } else {
            satPerVbyte = 2
        }

        // 4. Pick smallest UTXO that covers amount + fee (1 in, 2 out ≈ 141 vB).
        let estVbytes: UInt64 = 141
        let feeSats = estVbytes * satPerVbyte
        let ascending = confirmed.sorted { $0.value < $1.value }
        guard let chosen = ascending.first(where: { $0.value >= sendSats + feeSats }) else {
            throw SigningError.notInitialized
        }

        // 5. Resolve our own pubkey_hash (== 20-byte witness program of wallet.address).
        guard let ownBech = Bech32.decodeP2WPKH(wallet.address) else {
            throw SigningError.notInitialized
        }
        let pubkeyHash = ownBech.program

        // 6. Build outputs: recipient + (optional) change back to self.
        guard let recipientSPK = Bech32.p2wpkhScriptPubkey(for: recipientAddress) else {
            throw SigningError.notInitialized
        }
        var outputs: [FfiBtcOutput] = [
            FfiBtcOutput(address: recipientAddress, value: sendSats, scriptPubkey: recipientSPK)
        ]
        let change = Int64(chosen.value) - Int64(sendSats) - Int64(feeSats)
        let dust: Int64 = 546
        if change >= dust {
            let selfSPK = Data([0x00, 0x14]) + Data(pubkeyHash)
            outputs.append(
                FfiBtcOutput(address: wallet.address, value: UInt64(change), scriptPubkey: selfSPK)
            )
        }

        // 7. Build FfiBtcTxParams with one input from the chosen UTXO.
        let params = FfiBtcTxParams(
            inputs: [FfiBtcInput(
                txid: chosen.txid,
                vout: chosen.vout,
                value: chosen.value,
                pubkeyHash: Data(pubkeyHash)
            )],
            outputs: outputs,
            testnet: false
        )

        // 8. Rust returns (raw_data, sighash) — stash raw_data for later.
        let built = try horcruxBuildBtcTransaction(params: params, inputIndex: 0)
        self.pendingBtcRawData = built.rawData
        self.pendingBtcInputCount = params.inputs.count
        return built.signHash
    }

    /// Convert a user-typed BTC string like "0.001" into satoshis.
    private static func btcAmountToSats(_ s: String) -> UInt64 {
        let parts = s.split(separator: ".", maxSplits: 1).map(String.init)
        let whole = UInt64(parts[0]) ?? 0
        var frac: UInt64 = 0
        if parts.count == 2 {
            var f = parts[1]
            if f.count > 8 { f = String(f.prefix(8)) }
            while f.count < 8 { f += "0" }
            frac = UInt64(f) ?? 0
        }
        return whole * 100_000_000 + frac
    }

    /// Splice the MPC signature into the stashed raw tx to produce the
    /// broadcast-ready hex string. Called once MPC signing completes for
    /// P2WPKH chains (Bitcoin, Litecoin); returns nil for chains that
    /// aren't real-signing yet.
    private func finalizeBitcoinSignedTx(signature: Data) -> String? {
        guard wallet.chain == .bitcoin || wallet.chain == .litecoin,
              let rawData = pendingBtcRawData,
              pendingBtcInputCount > 0 else {
            return nil
        }
        let compressedPubkey = BtcSigner.compressPubkey(wallet.groupPublicKey)
        do {
            let signed = try BtcSigner.assembleSignedTx(
                unsignedRawData: rawData,
                inputCount: pendingBtcInputCount,
                signatures: [signature],
                compressedPubkey: compressedPubkey
            )
            // Clear stashed state so a subsequent retry rebuilds fresh.
            pendingBtcRawData = nil
            pendingBtcInputCount = 0
            return BtcSigner.hexEncode(signed)
        } catch {
            SecureLog.error("BTC finalize failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Fetch a recent blockhash and build a Solana System Program transfer
    /// via Rust, returning the message bytes (which are also the payload
    /// the Ed25519 sig is computed over). The message is stashed so the
    /// post-signing step can prepend the signature for broadcast.
    private func buildSolanaSignHash() async throws -> Data {
        guard let networkConfig, let blockchainService else {
            throw SigningError.notInitialized
        }
        // Parse amount "1.5" → lamports (1 SOL = 10^9 lamports).
        let lamports = Self.amountToRawUnits(amount, decimals: 9)
        guard let lamportsU64 = UInt64(lamports), lamportsU64 > 0 else {
            throw SigningError.notInitialized
        }
        let blockhash = try await blockchainService.solRecentBlockhash(
            rpcURL: networkConfig.solanaRPC)
        let params = FfiSolanaTxParams(
            fromAddress: wallet.address,
            toAddress: recipientAddress,
            lamports: lamportsU64,
            recentBlockhash: blockhash,
            devnet: false
        )
        let tx = try horcruxBuildSolanaTransaction(params: params)
        self.pendingSolMessage = tx.rawData
        return tx.signHash
    }

    /// Prepend the MPC ed25519 signature to the stashed Solana message and
    /// base64-encode the result for `sendTransaction`. Returns nil for
    /// non-Solana chains or when the stashed message is missing.
    private func finalizeSolanaSignedTx(signature: Data) -> String? {
        guard wallet.chain == .solana,
              let message = pendingSolMessage,
              signature.count == 64 else {
            return nil
        }
        // Solana signed tx layout:
        //   compact_u16(num_signatures=1) || 64-byte sig || message
        // Compact-u16 for 1 is a single byte 0x01.
        var signed = Data()
        signed.append(0x01)
        signed.append(signature)
        signed.append(message)
        pendingSolMessage = nil
        return signed.base64EncodedString()
    }

    /// Ask TronGrid to build the unsigned TRON transaction (native TRX or
    /// TRC-20 `transfer`), stash the raw_data fields so broadcast can replay
    /// them, and return the 32-byte `txID` (sha256 of raw_data) as the hash
    /// the MPC round will sign.
    private func buildTronSignHash() async throws -> Data {
        guard let blockchainService, let networkConfig else {
            throw SigningError.notInitialized
        }
        let apiURL = networkConfig.tronAPI
        let built: BlockchainService.TronUnsignedTx
        if let token = selectedToken {
            // TRC-20 transfer — token.id is the base58 contract address.
            let amountRaw = Self.amountToRawUnits(amount, decimals: Int(token.decimals))
            built = try await blockchainService.tronTriggerTRC20Transfer(
                from: wallet.address,
                contract: token.id,
                to: recipientAddress,
                amountRaw: amountRaw,
                apiURL: apiURL
            )
        } else {
            // Native TRX, denominated in `sun` (1 TRX = 1e6 sun).
            let amountRaw = Self.amountToRawUnits(amount, decimals: 6)
            let sun = UInt64(amountRaw) ?? 0
            built = try await blockchainService.tronCreateTransaction(
                from: wallet.address,
                to: recipientAddress,
                amountSun: sun,
                apiURL: apiURL
            )
        }
        self.pendingTronTx = built
        guard let hash = Self.hexToData(built.txID) else {
            throw SigningError.notInitialized
        }
        return hash
    }

    /// Attach the MPC signature (r || s || v) to the stashed unsigned
    /// TRON tx so `broadcastTransaction` has everything it needs.
    /// Returns a hex string of the pending txID, or nil for non-TRON
    /// chains / missing state. The returned "signed hex" is just the
    /// txID because broadcast actually takes the raw_data_hex +
    /// signature separately — we persist them via `pendingTronTx`.
    private func finalizeTronSignedTx(signature: Data, recoveryId: UInt8?) -> String? {
        guard wallet.chain == .tron,
              let tron = pendingTronTx,
              signature.count == 64 else {
            return nil
        }
        // TRON signature is 65 bytes: r || s || v, where v is the raw
        // recovery id (0 or 1) — NOT bumped by 27 like EVM.
        let r = signature.prefix(32)
        let s = signature.suffix(32)
        let v: UInt8 = (recoveryId ?? 0) & 1
        var sig = Data()
        sig.append(r); sig.append(s); sig.append(v)
        // Stash the sig alongside the raw_data so broadcastTransaction
        // can replay everything.
        self.pendingTronSignature = sig.map { String(format: "%02x", $0) }.joined()
        // Return the txID so the UI / TransactionStore have a stable
        // reference before broadcast lands.
        return tron.txID
    }
    private var pendingTronSignature: String?

    /// Splice the MPC (r,s) + recovery_id into the stashed EIP-1559 envelope
    /// to produce a broadcast-ready signed tx hex. Returns nil for chains
    /// other than EVM, or if the stashed state is missing (e.g. fallback
    /// placeholder sighash was used).
    private func finalizeEvmSignedTx(signature: Data, recoveryId: UInt8?) -> String? {
        guard wallet.chain.isEVM,
              let rawData = pendingEvmRawData,
              signature.count == 64,
              let recId = recoveryId else {
            return nil
        }
        let r = signature.prefix(32)
        let s = signature.suffix(32)
        // y_parity must be 0 or 1. Threshold ECDSA may return 2/3 when r
        // overflowed the curve order — extremely rare; fall back to the
        // low bit in that case so we still produce a tx (node will reject
        // if truly wrong and user can retry).
        let yParity: UInt8 = recId & 1
        do {
            let hex = try EvmSigner.assembleSignedTx(
                rawUnsigned: rawData, r: Data(r), s: Data(s), yParity: yParity
            )
            pendingEvmRawData = nil
            return hex
        } catch {
            SecureLog.error("EVM finalize failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Broadcast the signed transaction to the network.
    func broadcastTransaction() {
        guard let blockchainService, let networkConfig, let txHash else { return }
        isBroadcasting = true
        broadcastStatus = L10n.Signing.broadcastingTo(wallet.chain.displayName)

        Task {
            do {
                if wallet.chain.isEVM {
                    let result = try await blockchainService.ethSendRawTransaction(
                        signedTxHex: txHash,
                        rpcURL: networkConfig.rpcURL(for: wallet.chain)
                    )
                    await MainActor.run {
                        broadcastStatus = "Broadcast OK: \(result.prefix(20))…"
                        isBroadcasting = false
                        Haptics.success()
                        if let id = currentRecordId {
                            transactionStore?.updateStatus(id: id, status: .broadcast, txHash: result)
                        }
                    }
                } else {
                    switch wallet.chain {
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
                            if let replaced = rbfReplacing {
                                transactionStore?.markReplaced(txHash: replaced)
                            }
                        }
                    case .litecoin:
                        let result = try await blockchainService.btcBroadcast(
                            signedTxHex: txHash,
                            apiURL: networkConfig.litecoinAPI
                        )
                        await MainActor.run {
                            broadcastStatus = "Broadcast OK: \(result.prefix(20))…"
                            isBroadcasting = false
                            Haptics.success()
                            if let id = currentRecordId {
                                transactionStore?.updateStatus(id: id, status: .broadcast, txHash: result)
                            }
                            if let replaced = rbfReplacing {
                                transactionStore?.markReplaced(txHash: replaced)
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
                    case .tron:
                        guard let tron = self.pendingTronTx,
                              let sig = self.pendingTronSignature else {
                            await MainActor.run {
                                broadcastStatus = L10n.SigningExtra.broadcastFailTronSigMissing
                                isBroadcasting = false
                                Haptics.error()
                                if let id = currentRecordId {
                                    transactionStore?.updateStatus(id: id, status: .failed)
                                }
                            }
                            return
                        }
                        let result = try await blockchainService.tronBroadcast(
                            rawDataHex: tron.rawDataHex,
                            rawDataJSON: tron.rawDataJSON,
                            signatureHex: sig,
                            apiURL: networkConfig.tronAPI
                        )
                        let finalTxID = result.isEmpty ? tron.txID : result
                        await MainActor.run {
                            broadcastStatus = "Broadcast OK: \(finalTxID.prefix(20))…"
                            isBroadcasting = false
                            Haptics.success()
                            if let id = currentRecordId {
                                transactionStore?.updateStatus(id: id, status: .broadcast, txHash: finalTxID)
                            }
                            self.pendingTronTx = nil
                            self.pendingTronSignature = nil
                        }
                    default:
                        await MainActor.run {
                            broadcastStatus = "Broadcast for \(wallet.chain.displayName) is not supported yet."
                            isBroadcasting = false
                            Haptics.error()
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    let mapped = NodeErrorMapper.map(error)
                    broadcastStatus = L10n.SigningExtra.broadcastFailed(mapped.message)
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

    /// Multiply a decimal-string wei value by a Double multiplier, clamping
    /// at UInt64 (EVM max fees never approach that ceiling in practice).
    /// Falls back to the input on parse failure.
    static func scaleDecimalWei(_ decimalWei: String, by multiplier: Double) -> String {
        guard multiplier != 1.0 else { return decimalWei }
        guard let v = UInt64(decimalWei) else { return decimalWei }
        let scaled = Double(v) * multiplier
        if !scaled.isFinite || scaled < 0 { return decimalWei }
        return String(UInt64(scaled))
    }

    /// Rebuild the `estimatedFee` display string when the tier changes,
    /// without hitting the network again.
    private func refreshFeeDisplay() {
        guard wallet.chain.isEVM, let gas = pendingEvmGas else { return }
        guard let maxFee = UInt64(gas.maxFeePerGas) else { return }
        let effectiveGasPrice: UInt64 = {
            if feeTier == .custom, let gwei = Double(customGasPriceGwei), gwei > 0 {
                // Convert gwei → wei, clamp to UInt64.
                let wei = gwei * 1e9
                return wei.isFinite ? UInt64(max(0, wei)) : maxFee
            }
            return UInt64(Double(maxFee) * feeTier.multiplier)
        }()
        let feeWei = effectiveGasPrice &* gas.gasLimit
        // Convert wei → ether with 6-decimal display, strip trailing zeros.
        let feeEth = Double(feeWei) / 1e18
        let display = String(format: "%.6f", feeEth)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
        estimatedFee = "≈ \(display) \(wallet.chain.symbol)"
    }

    /// Populate `amount` with the maximum sendable value.
    ///
    /// Supports native transfers and ERC-20/SPL/TRC-20 token transfers. For
    /// tokens we read the cached whole-token balance from `BalanceCache`;
    /// if the cache is empty the button is disabled via `canFillMax`.
    func fillMax() {
        // Token path: no gas deduction needed (fee is paid in native).
        if let token = selectedToken {
            guard let bal = BalanceCache.shared.cachedTokenBalance(walletId: wallet.id, tokenId: token.id) else { return }
            amount = Self.formatAmountTrimmed(bal)
            return
        }

        // Parse "1.234 ETH" → 1.234.
        guard let raw = preTxBalance,
              let balStr = raw.split(separator: " ").first,
              let bal = Double(String(balStr).replacingOccurrences(of: ",", with: ""))
        else { return }

        // Parse "≈ 0.00123 ETH" → 0.00123.
        let fee: Double = {
            let parts = estimatedFee.split(separator: " ")
            for part in parts {
                if let v = Double(String(part)) { return v }
            }
            // No numeric fee yet — use a conservative buffer.
            switch wallet.chain {
            case .bitcoin, .litecoin: return 0.00005
            case .solana: return 0.000005
            case .tron: return 1.1
            default: return 0.0003 // EVM default
            }
        }()

        let maxAmount = max(0, bal - fee)
        amount = Self.formatAmountTrimmed(maxAmount)
    }

    /// Whether the Max button should be shown for the current compose state.
    var canFillMax: Bool {
        if let token = selectedToken {
            return BalanceCache.shared.cachedTokenBalance(walletId: wallet.id, tokenId: token.id) != nil
        }
        return preTxBalance != nil
    }

    private static func formatAmountTrimmed(_ v: Double) -> String {
        if v == 0 { return "0" }
        let s = String(format: "%.8f", v)
        var trimmed = s
        while trimmed.hasSuffix("0") { trimmed.removeLast() }
        if trimmed.hasSuffix(".") { trimmed.removeLast() }
        return trimmed
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
