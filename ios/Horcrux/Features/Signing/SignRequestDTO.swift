import Foundation

/// Broadcast by the **initiator** of a hot-signing ceremony during the
/// `.invite` step. Carries enough transaction metadata for a co-signer
/// who just joined the same relay room (via room code) to (a) identify
/// which of their local wallets the request applies to and (b) render a
/// human-reviewable preview before approving.
///
/// All participants must agree on the tx bytes for the MPC hash to
/// match; the cosigner therefore reconstructs the same `SigningViewModel`
/// inputs verbatim from this DTO instead of re-collecting them.
///
/// Wire format: JSON over the existing relay/BLE/LAN pipeline. The
/// `magic` field lets the transport layer's decoder distinguish this
/// from real MPC protocol messages (`MpcMessageDTO`) and room presence
/// beacons (`RoomPresenceDTO`).
/// Tiny "I'm here" ping sent by a cosigner right after establishing a
/// LAN (or relay) connection to the initiator. The initiator's
/// `PeerManager.handleIncomingMessage` adds any peer from which it
/// receives a message on a trusted local transport to `connectedPeers`
/// — so this ping is specifically what moves the cosigner out of
/// "discovered" and into "joined" on the initiator's invite screen.
/// Without it the initiator would sit in "等待共签方加入" forever
/// because the announce-beacon traffic is one-way (initiator → peers).
struct SignPresenceDTO: Codable {
    static let magic = "HSP-v1"
    let magic: String
    let sessionId: String
    let deviceName: String
    /// Cosigner's MPC party index inside the matched wallet, shipped
    /// so the initiator can map `peer.id → partyIndex` when building
    /// the `participants` array for `bridge.startSigning`. Optional:
    /// the first ping is fired before the cosigner has matched a
    /// wallet (so it doesn't know its own index yet); a second ping
    /// with this field populated is sent right after the user taps
    /// "approve". Pre-dev.89 peers omit this field entirely.
    let partyIndex: UInt16?

    init(sessionId: String, deviceName: String, partyIndex: UInt16? = nil) {
        self.magic = Self.magic
        self.sessionId = sessionId
        self.deviceName = deviceName
        self.partyIndex = partyIndex
    }
}

/// Fired exactly once by the initiator immediately before it calls
/// `bridge.startSigning` and starts emitting real MPC round-1 messages.
/// Cosigners hold off on `bridge.startSigning` (and therefore on their
/// own round-1 emission) until they see this DTO, guaranteeing every
/// participant has already subscribed to the MPC message stream before
/// any FROST/CGGMP21 protocol bytes are sent — otherwise the first
/// messages would be dropped by peers who haven't subscribed yet.
///
/// **Also carries the authoritative transaction parameters.** The
/// initiator resolves nonce / gas / fees exactly once; every cosigner
/// uses these verbatim instead of re-querying their own RPC. Without
/// this the two sides could diverge on nonce or gas and end up hashing
/// different transactions → the MPC protocol runs to completion but
/// produces an unusable signature (or hangs when the bridge detects
/// inconsistent inputs).
struct SignBeginDTO: Codable {
    static let magic = "HSG-v1"
    let magic: String
    /// Must match the cosigner's pinned `sessionId` (= room code) for
    /// them to act on the signal. Prevents a stray begin from a
    /// different concurrent ceremony from starting this one.
    let sessionId: String

    /// Authoritative tx params. Optional for backwards compat with
    /// older peers (pre-dev.88); when nil, cosigner falls back to the
    /// legacy "recompute locally" path.
    let tx: AuthoritativeTxParams?

    /// Full sorted list of MPC party indices participating in this
    /// ceremony, computed by the initiator from its `peerPartyIndex`
    /// map (which is populated from cosigners' `SignPresenceDTO`
    /// pings during the invite phase). Cosigners cannot derive this
    /// locally because they don't receive presence pings from each
    /// other — they only know their own `wallet.partyIndex`. Optional
    /// for back-compat with pre-dev.115 peers; when nil or absent,
    /// cosigner falls back to `[myIndex, otherIndexFallback]`.
    let participants: [UInt16]?

    init(sessionId: String, tx: AuthoritativeTxParams? = nil, participants: [UInt16]? = nil) {
        self.magic = Self.magic
        self.sessionId = sessionId
        self.tx = tx
        self.participants = participants
    }
}

/// Fully-resolved transaction inputs. Initiator fills these right
/// before `bridge.startSigning`; cosigners apply them verbatim before
/// their own `buildSignHash` runs.
///
/// All gas/value fields are **decimal strings in wei / base units**,
/// never scientific notation, never pre-scaled — the wire is the
/// canonical representation so a re-parse on the other side can't
/// round-trip differently.
struct AuthoritativeTxParams: Codable {
    /// EVM chainId. Ignored for non-EVM chains (bitcoin, solana, etc.).
    let chainId: UInt64?
    let nonce: UInt64?
    let gasLimit: UInt64?
    /// Decimal-string wei. Empty string = "leave defaults" (non-EVM).
    let maxFeePerGasWei: String
    let maxPriorityFeePerGasWei: String
    /// Canonical recipient / amount pair. `to` is either the native
    /// destination (for coin transfer) or the token contract (for
    /// ERC-20 transfers — the actual recipient lives in `dataHex`).
    let to: String
    let valueWei: String
    /// Hex-encoded calldata (no `0x` prefix). Empty for native coin tx.
    let dataHex: String
}

struct SignRequestDTO: Codable {
    static let magic = "HSQ-v1"
    let magic: String

    /// MPC session id = relay room code. Used by the cosigner to pin
    /// their own `SigningViewModel.sessionId` to the same value.
    let sessionId: String

    /// Initiator's group public key (hex). The cosigner matches this
    /// against their `Wallet.groupPublicKey` to pick the right local
    /// wallet to load the shard from.
    let groupPublicKey: String

    /// Chain raw string (`Chain.rawValue`).
    let chain: String

    /// Destination address. Cosigner displays this in the preview.
    let recipient: String

    /// Amount as the user-entered decimal string (e.g. "0.1"). Same
    /// string the initiator's VM holds in `amount`.
    let amount: String

    /// Optional SPL / ERC-20 token contract address + symbol. `nil`
    /// means native coin transfer.
    let tokenContract: String?
    let tokenSymbol: String?
    let tokenDecimals: UInt8?

    /// Display string for the estimated fee ("≈ 0.00021 ETH"), for UX
    /// only — cosigner will recompute the actual fee from network.
    let feeDisplay: String?

    /// Friendly name of the initiator device ("Bill's iPhone 16 Pro")
    /// so the cosigner sees who is asking.
    let initiatorDeviceName: String

    init(
        sessionId: String,
        groupPublicKey: String,
        chain: String,
        recipient: String,
        amount: String,
        tokenContract: String? = nil,
        tokenSymbol: String? = nil,
        tokenDecimals: UInt8? = nil,
        feeDisplay: String? = nil,
        initiatorDeviceName: String
    ) {
        self.magic = Self.magic
        self.sessionId = sessionId
        self.groupPublicKey = groupPublicKey
        self.chain = chain
        self.recipient = recipient
        self.amount = amount
        self.tokenContract = tokenContract
        self.tokenSymbol = tokenSymbol
        self.tokenDecimals = tokenDecimals
        self.feeDisplay = feeDisplay
        self.initiatorDeviceName = initiatorDeviceName
    }
}
