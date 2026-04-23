import Foundation
import SwiftUI
import CryptoKit

/// Cold-signing coordinator **v2** — generic `t-of-n` ceremony over QR.
///
/// Complements `ColdSigningCoordinator` (v1), which is hand-tuned for
/// 2-of-2. v2 handles any wallet shape with `totalParties ≥ 3` (and in
/// practice up to ~5 — beyond that the QR choreography becomes too long
/// to be usable).
///
/// **Topology**: star + payload-batching.
///
/// - One party is the **initiator** (hub). All cosigners only talk to
///   the initiator. When cosigner B produces a message for cosigner C,
///   it tucks it into the QR destined for the initiator; the initiator
///   later forwards it inside the QR destined for C.
/// - Each QR may carry **multiple** `FfiMpcMessage`s at once — the
///   batched payload mirrors how relay-based signing already works,
///   so the Rust core sees no difference.
///
/// **Choreography** (example for 3-of-3 with parties A=initiator,
/// B, C):
///
/// ```
/// Iteration 1 (round-1 exchange):
///   1. A → B   (invite + A's r1 msgs for B and C)
///   2. B → A   (B's r1 msgs for A and C)
///   3. A → C   (A's r1 for C + B's r1 for C)
///   4. C → A   (C's r1 for A and B + possibly r2 if engine emitted)
///
/// Iteration 2 (round-2 exchange):
///   5. A → B   (C's r1 for B + A's r2 for B + C's r2 for B)
///   6. B → A   (B's r2 for A and C)
///   7. A → C   (B's r2 for C + A's r2 for C)
///   8. C → A   (final C's r2 for A if any)
/// ```
///
/// Most protocols (CGGMP21 in our case) converge well before iteration
/// 2 completes — the coordinator stops the instant
/// `getSigningResult` returns non-nil.
///
/// **State model**: `Phase` is intentionally flat (`idle`, `showingQR`,
/// `awaitingScan`, `complete`, `failed`) with `currentPeer` tracked
/// separately. The old v1 used a dedicated case per step; that doesn't
/// scale past 2 parties, where the step count is dynamic.
///
/// **Not implemented**:
/// - `t < n` with explicit participant selection (the UI currently
///   signs with every party in the wallet).
/// - Resume-after-interruption. Dropping a QR mid-ceremony forces a
///   restart. Documented in the view copy.
@MainActor
final class ColdSigningCoordinatorV2: ObservableObject {

    // MARK: - Public types

    enum Role {
        case initiator
        case cosigner
    }

    enum Phase: Equatable {
        case idle
        case showing(toPeer: UInt16)
        case awaitingScan(fromPeer: UInt16)
        case complete
        case failed
    }

    // MARK: - Published state

    @Published private(set) var role: Role = .initiator
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var currentQRPayload: Data?
    @Published private(set) var errorMessage: String?
    @Published private(set) var finalSignature: Data?
    /// Human-readable step description for the view layer
    /// (e.g. "向设备 B 展示 · 第 2 / 8 步").
    @Published private(set) var stepDescription: String = ""

    // MARK: - Dependencies

    private let bridge: HorcruxBridge
    private var sessionId: String?
    private var wallet: Wallet?
    private var messageHash: Data?
    private var shardData: Data?

    // MARK: - Ceremony bookkeeping

    /// All party indices participating in this signing (sorted).
    private var participants: [UInt16] = []
    /// Party index of this device.
    private var myIndex: UInt16 = 0
    /// Initiator's view of cosigners in exchange order (ascending party index).
    private var cosignerOrder: [UInt16] = []
    /// Index into `cosignerOrder`; which cosigner we're currently transacting with.
    private var orderCursor: Int = 0
    /// Per-peer outbox of pending `FfiMpcMessage`s to hand over next visit.
    private var outbox: [UInt16: [FfiMpcMessage]] = [:]
    /// Cosigners that have already scanned the invite packet.
    private var invitedPeers: Set<UInt16> = []
    /// How many QR hops happened so far (display only).
    private var stepCounter: Int = 0
    /// Audit C1 (round-14 follow-up) — scan-session fingerprint TOFU.
    /// The first MPC message we observe from each `fromParty` during
    /// this ceremony is hashed (session_id ‖ from_party_be ‖ payload)
    /// and stashed here. Every later message from the same party must
    /// carry the same `sessionId`; divergence means a different
    /// ceremony was spliced in (attacker re-using a valid party slot
    /// mid-scan). The fingerprint itself is also written to SecureLog
    /// so an audit export can reconstruct who said what in which
    /// ceremony — useful both for operator triage after a failed
    /// signing and for external auditors reviewing cold-flow traces.
    private var peerScanFingerprint: [UInt16: Data] = [:]
    /// First-seen session id per party (for sessionId-stickiness).
    private var peerFirstSessionId: [UInt16: String] = [:]

    init(bridge: HorcruxBridge) {
        self.bridge = bridge
    }

    // MARK: - Entry points

    /// Starts the ceremony as the initiator. Emits the first QR
    /// (an invite addressed to the lowest-indexed cosigner).
    func startAsInitiator(
        wallet: Wallet,
        messageHash: Data,
        shardData: Data,
        participants: [UInt16]
    ) throws {
        let sorted = participants.sorted()
        guard sorted.count >= 3 else {
            throw ColdSigningCoordinator.ColdError.unsupportedWalletShape
        }
        guard sorted.contains(wallet.partyIndex) else {
            throw ColdSigningCoordinator.ColdError.walletMismatch
        }

        self.role = .initiator
        self.wallet = wallet
        self.messageHash = messageHash
        self.shardData = shardData
        self.participants = sorted
        self.myIndex = wallet.partyIndex
        self.cosignerOrder = sorted.filter { $0 != wallet.partyIndex }
        self.orderCursor = 0
        self.outbox = [:]
        self.invitedPeers = []
        self.peerScanFingerprint = [:]
        self.peerFirstSessionId = [:]
        self.stepCounter = 0
        self.finalSignature = nil
        self.errorMessage = nil

        let sid = "coldv2-\(UUID().uuidString.lowercased().prefix(12))"
        self.sessionId = String(sid)

        let config = FfiHorcruxConfig(
            threshold: wallet.threshold,
            totalParties: wallet.totalParties,
            partyIndex: wallet.partyIndex,
            curve: wallet.chain.curveType
        )

        let initialMessages = try bridge.startSigning(
            sessionId: String(sid),
            config: config,
            messageHash: messageHash,
            shardData: shardData,
            participants: sorted
        )
        distribute(initialMessages)

        try emitQR(toPeer: cosignerOrder[0], asInvite: true)
    }

    /// Starts as a cosigner. The first scan will be the invite QR.
    func startAsCosigner(wallet: Wallet, shardData: Data) throws {
        guard wallet.totalParties >= 3 else {
            throw ColdSigningCoordinator.ColdError.unsupportedWalletShape
        }
        self.role = .cosigner
        self.wallet = wallet
        self.shardData = shardData
        self.sessionId = nil
        self.messageHash = nil
        self.outbox = [:]
        self.invitedPeers = []
        self.peerScanFingerprint = [:]
        self.peerFirstSessionId = [:]
        self.stepCounter = 0
        self.finalSignature = nil
        self.errorMessage = nil
        self.myIndex = wallet.partyIndex
        self.phase = .awaitingScan(fromPeer: 0)  // initiator index filled on invite
        self.stepDescription = L10n.ColdSignV2.waitingInvite
    }

    // MARK: - User actions

    /// Called when the operator taps "ready to scan" after showing a QR.
    func readyToScan() {
        switch phase {
        case .showing(let toPeer):
            // We expect the peer to reply next.
            phase = .awaitingScan(fromPeer: toPeer)
            stepDescription = L10n.ColdSignV2.scanFromPeer("\(toPeer)")
        default:
            break
        }
    }

    func handleScanned(_ base64: String) {
        do {
            let packet = try ColdPacketV2.decode(base64)
            try process(packet)
        } catch {
            errorMessage = error.localizedDescription
            phase = .failed
            SecureLog.error("Cold-signing v2 scan failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Packet processing

    private func process(_ packet: ColdPacketV2) throws {
        switch (role, packet) {
        case (.cosigner, .invite(let invite)):
            try ingestInvite(invite)
        case (_, .round(let round)):
            try ingestRound(round)
        case (.initiator, .invite):
            throw ColdSigningCoordinator.ColdError.unexpectedPacket(phase: "initiator received invite")
        }
    }

    private func ingestInvite(_ i: ColdPacketV2.Invite) throws {
        guard let wallet = wallet, let shard = shardData else {
            throw ColdSigningCoordinator.ColdError.noSignatureProduced
        }
        guard wallet.accountId == i.walletId, wallet.chain.rawValue == i.chain else {
            throw ColdSigningCoordinator.ColdError.walletMismatch
        }
        guard i.participants.contains(wallet.partyIndex) else {
            throw ColdSigningCoordinator.ColdError.walletMismatch
        }

        self.sessionId = i.sessionId
        self.messageHash = i.messageHash
        self.participants = i.participants.sorted()
        self.cosignerOrder = []  // cosigners don't drive the loop

        let config = FfiHorcruxConfig(
            threshold: i.threshold,
            totalParties: i.totalParties,
            partyIndex: wallet.partyIndex,
            curve: wallet.chain.curveType
        )

        let initialMessages = try bridge.startSigning(
            sessionId: i.sessionId,
            config: config,
            messageHash: i.messageHash,
            shardData: shard,
            participants: i.participants
        )
        distribute(initialMessages)

        // Feed the initiator's messages addressed to us.
        let inbound = try feedInbound(i.messages)
        distribute(inbound)

        invitedPeers.insert(i.initiatorParty)
        try emitQR(toPeer: i.initiatorParty, asInvite: false)
    }

    private func ingestRound(_ r: ColdPacketV2.RoundPacket) throws {
        let inbound = try feedInbound(r.messages)
        distribute(inbound)

        // Signature check — initiator typically finishes last.
        if let sid = sessionId, let result = bridge.getSigningResult(sessionId: sid) {
            finalSignature = result.signature
        }

        switch role {
        case .initiator:
            if finalSignature != nil {
                phase = .complete
                stepDescription = L10n.ColdSignV2.signatureReady
                cleanup()
                return
            }
            // Advance to next cosigner (round-robin).
            orderCursor = (orderCursor + 1) % cosignerOrder.count
            let nextPeer = cosignerOrder[orderCursor]
            try emitQR(toPeer: nextPeer, asInvite: !invitedPeers.contains(nextPeer))
        case .cosigner:
            // Cosigner always reports back to the initiator — even if
            // our outbox is empty, we send an acknowledgement packet so
            // the initiator knows we processed its scan.
            let initiator = participants.first { $0 != myIndex } ?? 0
            try emitQR(toPeer: initiator, asInvite: false)
            if finalSignature != nil {
                // Stash the signature; we still need to show the QR so
                // the initiator can finish. Operator taps "done" when
                // initiator confirms.
                stepDescription = L10n.ColdSignV2.cosignerHasSignature
            }
        }
    }

    /// Consume messages addressed to us; stash forwards (for initiator
    /// acting as hub) into the outbox; return engine-produced messages.
    private func feedInbound(_ dtos: [MpcMessageDTO]) throws -> [FfiMpcMessage] {
        var produced: [FfiMpcMessage] = []
        for dto in dtos {
            let msg = dto.toFfi()
            // Audit C1: cold-signing v2 is QR-scan authenticated — there
            // is no Noise channel to bind transport identity to the
            // claimed `fromParty`. Three layers of defence at this
            // level, on top of the Rust session-state machine that
            // rejects cryptographically inconsistent transitions:
            //
            //   1. Reject messages claiming to come from ourselves —
            //      either a QR-loop bug, a replay, or a hostile scan.
            //   2. Enforce that `msg.sessionId` matches the coordinator's
            //      active ceremony sessionId. This prevents an attacker
            //      from splicing in valid MPC traffic from a *different*
            //      ceremony during the scan flow.
            //   3. Scan-session fingerprint TOFU. On first contact with
            //      each party we stash the message fingerprint and the
            //      asserted sessionId; subsequent messages from the same
            //      `fromParty` must keep the same sessionId, i.e. the
            //      party can't "jump" ceremonies mid-scan. The
            //      fingerprint is also written to SecureLog for audit
            //      export.
            if msg.fromParty == myIndex {
                throw ColdSigningCoordinator.ColdError.walletMismatch
            }
            if let activeSid = self.sessionId, msg.sessionId != activeSid {
                SecureLog.error("[ColdV2] C1 reject: msg.sessionId=\(msg.sessionId) does not match active ceremony \(activeSid)")
                throw ColdSigningCoordinator.ColdError.walletMismatch
            }
            if let pinned = peerFirstSessionId[msg.fromParty] {
                if pinned != msg.sessionId {
                    SecureLog.error("[ColdV2] C1 reject: party \(msg.fromParty) previously bound to sessionId \(pinned) but now asserts \(msg.sessionId) — ceremony splice")
                    throw ColdSigningCoordinator.ColdError.walletMismatch
                }
            } else {
                peerFirstSessionId[msg.fromParty] = msg.sessionId
                var fromBE = msg.fromParty.bigEndian
                var hasher = SHA256()
                hasher.update(data: Data(msg.sessionId.utf8))
                withUnsafeBytes(of: &fromBE) { hasher.update(bufferPointer: $0) }
                hasher.update(data: msg.payload)
                let fp = Data(hasher.finalize())
                peerScanFingerprint[msg.fromParty] = fp
                SecureLog.info("[ColdV2] scan-session fingerprint party=\(msg.fromParty) sid=\(msg.sessionId) fp=\(fp.prefix(8).map { String(format: "%02x", $0) }.joined())")
            }
            if msg.toParty == 0 || msg.toParty == myIndex {
                let out = try bridge.handleAuthenticatedMessage(msg, authenticatedFrom: msg.fromParty)
                produced.append(contentsOf: out)
            } else {
                // Not for us — queue as forward to that peer. Only the
                // initiator should ever hit this branch; cosigners only
                // scan from initiator and everything is already addressed
                // via the hub.
                outbox[msg.toParty, default: []].append(msg)
            }
            // Broadcast (toParty==0): everyone also forwards to other
            // peers they haven't talked to yet. For MVP we only feed
            // our engine; forwarding is done implicitly when the
            // initiator emits its next QR because broadcasts from the
            // engine are rewritten below in `distribute`.
        }
        return produced
    }

    /// Route engine-produced messages into per-peer outboxes. Broadcasts
    /// (toParty == 0) fan out to every peer except self.
    private func distribute(_ messages: [FfiMpcMessage]) {
        for msg in messages {
            if msg.toParty == 0 {
                for peer in participants where peer != myIndex {
                    outbox[peer, default: []].append(msg)
                }
            } else if msg.toParty != myIndex {
                outbox[msg.toParty, default: []].append(msg)
            }
            // toParty == self shouldn't happen; skip if so.
        }
    }

    /// Build the next outgoing QR for `toPeer`, flushing that peer's outbox.
    private func emitQR(toPeer: UInt16, asInvite: Bool) throws {
        let queued = outbox[toPeer] ?? []
        outbox[toPeer] = []
        stepCounter += 1

        let packet: ColdPacketV2
        if asInvite, role == .initiator, let wallet = wallet,
           let sid = sessionId, let hash = messageHash {
            invitedPeers.insert(toPeer)
            packet = .invite(
                ColdPacketV2.Invite(
                    sessionId: sid,
                    walletId: wallet.accountId,
                    chain: wallet.chain.rawValue,
                    threshold: wallet.threshold,
                    totalParties: wallet.totalParties,
                    initiatorParty: wallet.partyIndex,
                    participants: participants,
                    messageHash: hash,
                    messages: queued.map { MpcMessageDTO($0) }
                )
            )
        } else {
            packet = .round(
                ColdPacketV2.RoundPacket(
                    step: UInt32(stepCounter),
                    messages: queued.map { MpcMessageDTO($0) }
                )
            )
        }

        currentQRPayload = try packet.encode()
        phase = .showing(toPeer: toPeer)
        stepDescription = L10n.ColdSignV2.showToPeer("\(toPeer)", stepCounter)
    }

    // MARK: - Cleanup

    private func cleanup() {
        if var d = shardData {
            d.resetBytes(in: 0..<d.count)
            shardData = nil
        }
        if let sid = sessionId {
            bridge.removeSession(sessionId: sid)
        }
    }
}

// MARK: - V2 wire format

enum ColdPacketV2 {
    case invite(Invite)
    case round(RoundPacket)

    struct Invite: Codable {
        let sessionId: String
        let walletId: String
        let chain: String
        let threshold: UInt16
        let totalParties: UInt16
        let initiatorParty: UInt16
        let participants: [UInt16]
        let messageHash: Data
        let messages: [MpcMessageDTO]
    }

    struct RoundPacket: Codable {
        /// Monotonic step counter — purely informational, helps the
        /// view layer explain "this is step 4/8" and lets us detect a
        /// rescan of the same QR.
        let step: UInt32
        let messages: [MpcMessageDTO]
    }

    private enum Kind: String, Codable { case invite, round }
    private struct Envelope: Codable {
        let version: UInt8
        let kind: Kind
        let data: Data
    }

    func encode() throws -> Data {
        let encoder = JSONEncoder()
        let inner: Data
        let kind: Kind
        switch self {
        case .invite(let i):
            inner = try encoder.encode(i)
            kind = .invite
        case .round(let r):
            inner = try encoder.encode(r)
            kind = .round
        }
        let envelope = Envelope(version: 2, kind: kind, data: inner)
        let json = try encoder.encode(envelope)
        return Data(json.base64EncodedString().utf8)
    }

    static func decode(_ base64: String) throws -> ColdPacketV2 {
        guard let raw = Data(base64Encoded: base64) else {
            throw ColdSigningCoordinator.ColdError.unexpectedPacket(phase: "decode")
        }
        let decoder = JSONDecoder()
        let envelope = try decoder.decode(Envelope.self, from: raw)
        guard envelope.version == 2 else {
            throw ColdSigningCoordinator.ColdError.unexpectedPacket(
                phase: "version \(envelope.version)"
            )
        }
        switch envelope.kind {
        case .invite:
            return .invite(try decoder.decode(Invite.self, from: envelope.data))
        case .round:
            return .round(try decoder.decode(RoundPacket.self, from: envelope.data))
        }
    }
}
