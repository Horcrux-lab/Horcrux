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

    init(sessionId: String, deviceName: String) {
        self.magic = Self.magic
        self.sessionId = sessionId
        self.deviceName = deviceName
    }
}

/// Fired exactly once by the initiator immediately before it calls
/// `bridge.startSigning` and starts emitting real MPC round-1 messages.
/// Cosigners hold off on `bridge.startSigning` (and therefore on their
/// own round-1 emission) until they see this DTO, guaranteeing every
/// participant has already subscribed to the MPC message stream before
/// any FROST/CGGMP21 protocol bytes are sent — otherwise the first
/// messages would be dropped by peers who haven't subscribed yet.
struct SignBeginDTO: Codable {
    static let magic = "HSG-v1"
    let magic: String
    /// Must match the cosigner's pinned `sessionId` (= room code) for
    /// them to act on the signal. Prevents a stray begin from a
    /// different concurrent ceremony from starting this one.
    let sessionId: String

    init(sessionId: String) {
        self.magic = Self.magic
        self.sessionId = sessionId
    }
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
