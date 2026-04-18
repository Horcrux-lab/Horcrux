import Foundation
import SwiftUI

/// Cold-signing coordinator — drives the FROST ceremony entirely over
/// air-gapped QR chain (no relay, no WebSocket). One device plays the
/// **initiator**, another the **cosigner**; each produces a QR that the
/// other scans. For MPC the coordinator just marshals `FfiMpcMessage`s
/// through `HorcruxBridge` — all crypto happens in Rust.
///
/// **Status (dev.50):** both initiator and cosigner flows are functional
/// for 2-of-2 wallets. A complete ceremony flows over 4 QR codes:
///
///   QR1  initiator → cosigner   (invite + initiator round1)
///   QR2  cosigner  → initiator  (cosigner round1)
///   QR3  initiator → cosigner   (initiator round2 shares)
///   QR4  cosigner  → initiator  (cosigner round2 shares)
///
/// After QR4 each side has consumed all peer messages and
/// `getSigningResult` yields the aggregated signature.
///
/// Wire format — a packet is a single JSON encoded as base64 inside a
/// QR code. Three packet kinds:
///
/// 1. **invite**: initiator → cosigner. Sets up the session (threshold,
///    message hash, curve). Once scanned, both sides call `startSigning`
///    with identical params so the MPC engines line up.
/// 2. **round**: either side → other. Wraps a batch of `FfiMpcMessage`s
///    produced by `handleMessage`. Both rounds (commitments, shares)
///    ride the same shape.
/// 3. **done**: cosigner → initiator optional ack. Not required because
///    the initiator derives completion from `getSigningResult`.
@MainActor
final class ColdSigningCoordinator: ObservableObject {

    // MARK: - Public state

    enum Role {
        case initiator
        case cosigner
    }

    enum Phase: String {
        case idle
        // Initiator phases
        case showingInvite           // initiator: display invite QR, wait for scan
        case awaitingRound1          // initiator: scan cosigner's round-1 reply
        case showingRound2           // initiator: display round-2 QR
        case awaitingRound2          // initiator: scan cosigner's round-2 share
        // Cosigner phases
        case awaitingInvite          // cosigner: scan initiator's invite QR
        case showingCosignerRound1   // cosigner: display own round-1 reply
        case awaitingInitiatorRound2 // cosigner: scan initiator's round-2 share
        case showingCosignerRound2   // cosigner: display own round-2 share (final QR)
        // Terminal
        case complete
        case failed
    }

    @Published private(set) var role: Role = .initiator
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var currentQRPayload: Data?
    @Published private(set) var errorMessage: String?
    @Published private(set) var finalSignature: Data?

    // MARK: - Dependencies

    private let bridge: HorcruxBridge
    private var sessionId: String?
    private var wallet: Wallet?
    private var messageHash: Data?
    private var shardData: Data?
    private var pendingRound2: [FfiMpcMessage] = []

    init(bridge: HorcruxBridge) {
        self.bridge = bridge
    }

    // MARK: - Initiator flow

    /// Kick off the ceremony. The caller is responsible for decrypting
    /// the shard (same pattern as online signing) and passing the
    /// plaintext `shardData` in. We zero it when the ceremony ends.
    func startAsInitiator(wallet: Wallet, messageHash: Data, shardData: Data) throws {
        guard wallet.threshold == 2, wallet.totalParties == 2 else {
            throw ColdError.unsupportedWalletShape
        }
        self.role = .initiator
        let sid = "cold-\(UUID().uuidString.lowercased().prefix(12))"
        self.sessionId = String(sid)
        self.wallet = wallet
        self.messageHash = messageHash
        self.shardData = shardData

        let config = FfiHorcruxConfig(
            threshold: wallet.threshold,
            totalParties: wallet.totalParties,
            partyIndex: wallet.partyIndex,
            curve: wallet.chain.curveType
        )

        // Round-1 messages from this device (initiator).
        let outgoing = try bridge.startSigning(
            sessionId: String(sid),
            config: config,
            messageHash: messageHash,
            shardData: shardData,
            participants: [1, 2]
        )

        // The invite QR carries session setup + our round-1 messages, so
        // the cosigner only has to scan one code before replying.
        let packet = ColdPacket.invite(
            ColdPacket.Invite(
                sessionId: String(sid),
                walletId: wallet.accountId,
                chain: wallet.chain.rawValue,
                threshold: wallet.threshold,
                totalParties: wallet.totalParties,
                initiatorParty: wallet.partyIndex,
                messageHash: messageHash,
                round1: outgoing.map { MpcMessageDTO($0) }
            )
        )
        currentQRPayload = try packet.encode()
        phase = .showingInvite
    }

    // MARK: - Cosigner flow

    /// Prepare this device to be scanned into by an initiator. The
    /// cosigner only needs its wallet + decrypted shard up front; the
    /// message hash and session id arrive via the invite QR.
    func startAsCosigner(wallet: Wallet, shardData: Data) throws {
        guard wallet.threshold == 2, wallet.totalParties == 2 else {
            throw ColdError.unsupportedWalletShape
        }
        self.role = .cosigner
        self.wallet = wallet
        self.shardData = shardData
        self.sessionId = nil
        self.messageHash = nil
        self.currentQRPayload = nil
        phase = .awaitingInvite
    }

    /// Feed a scanned QR payload (base64 JSON) into the state machine.
    func handleScanned(_ base64: String) {
        do {
            let packet = try ColdPacket.decode(base64)
            try process(packet)
        } catch {
            errorMessage = error.localizedDescription
            phase = .failed
            SecureLog.error("Cold-signing scan failed: \(error.localizedDescription)")
        }
    }

    /// Operator manually advanced from "display QR" to "scan next" state.
    func readyToScan() {
        switch phase {
        case .showingInvite: phase = .awaitingRound1
        case .showingRound2: phase = .awaitingRound2
        case .showingCosignerRound1: phase = .awaitingInitiatorRound2
        case .showingCosignerRound2:
            // Cosigner has already completed locally; displaying its
            // final QR is a courtesy so the initiator can finish. Tap
            // advances to the terminal "complete" screen.
            phase = .complete
        default: break
        }
    }

    // MARK: - Internals

    private func process(_ packet: ColdPacket) throws {
        switch (role, phase, packet) {
        // Initiator
        case (.initiator, .awaitingRound1, .round(let r)) where r.round == 1:
            try ingestRound1(r)
        case (.initiator, .awaitingRound2, .round(let r)) where r.round == 2:
            try ingestRound2(r)
        // Cosigner
        case (.cosigner, .awaitingInvite, .invite(let i)):
            try ingestInvite(i)
        case (.cosigner, .awaitingInitiatorRound2, .round(let r)) where r.round == 2:
            try cosignerIngestRound2(r)
        default:
            throw ColdError.unexpectedPacket(phase: phase.rawValue)
        }
    }

    private func ingestRound1(_ r: ColdPacket.RoundPacket) throws {
        // Feed the cosigner's round-1 messages to our MPC engine; it
        // will produce round-2 messages (signature shares).
        var produced: [FfiMpcMessage] = []
        for dto in r.messages {
            let out = try bridge.handleMessage(dto.toFfi())
            produced.append(contentsOf: out)
        }
        pendingRound2 = produced
        let reply = ColdPacket.round(.init(round: 2, messages: produced.map { MpcMessageDTO($0) }))
        currentQRPayload = try reply.encode()
        phase = .showingRound2
    }

    private func ingestRound2(_ r: ColdPacket.RoundPacket) throws {
        // Final round. After feeding the cosigner's share, the MPC
        // engine should have a complete signature.
        for dto in r.messages {
            _ = try bridge.handleMessage(dto.toFfi())
        }
        guard let sid = sessionId, let result = bridge.getSigningResult(sessionId: sid) else {
            throw ColdError.noSignatureProduced
        }
        finalSignature = result.signature
        phase = .complete
        cleanup()
    }

    // MARK: - Cosigner internals

    /// Consume the initiator's invite. Validates the wallet identity,
    /// starts the local FROST session with identical parameters, feeds
    /// the initiator's round-1 commitments into our engine, and shows
    /// our own round-1 reply as QR2.
    private func ingestInvite(_ i: ColdPacket.Invite) throws {
        guard let wallet = self.wallet, let shard = self.shardData else {
            throw ColdError.noSignatureProduced
        }
        // Identity check: the QR must target this wallet on the right
        // chain. Mismatch usually means the operator paired the wrong
        // pair of devices or scanned a QR from a different ceremony.
        guard wallet.accountId == i.walletId, wallet.chain.rawValue == i.chain else {
            throw ColdError.walletMismatch
        }
        guard i.threshold == 2, i.totalParties == 2 else {
            throw ColdError.unsupportedWalletShape
        }
        guard i.initiatorParty != wallet.partyIndex else {
            // Both devices can't claim the same party slot.
            throw ColdError.walletMismatch
        }

        self.sessionId = i.sessionId
        self.messageHash = i.messageHash

        let config = FfiHorcruxConfig(
            threshold: i.threshold,
            totalParties: i.totalParties,
            partyIndex: wallet.partyIndex,
            curve: wallet.chain.curveType
        )

        // Start our own FROST session. This emits our round-1
        // commitments, which we'll reply with as QR2.
        var produced = try bridge.startSigning(
            sessionId: i.sessionId,
            config: config,
            messageHash: i.messageHash,
            shardData: shard,
            participants: [1, 2]
        )

        // Feed the initiator's round-1 commitments now so the engine
        // has the full round-1 view. In FROST the engine doesn't emit
        // round-2 until it sees all round-1 messages from peers.
        // Anything the engine hands us that is still round-1 we merge
        // into our reply; anything tagged round-2 we stash for QR4.
        var pending2: [FfiMpcMessage] = []
        for dto in i.round1 {
            let out = try bridge.handleMessage(dto.toFfi())
            for msg in out {
                if msg.round == 2 {
                    pending2.append(msg)
                } else {
                    produced.append(msg)
                }
            }
        }
        self.pendingRound2 = pending2

        let reply = ColdPacket.round(.init(round: 1, messages: produced.map { MpcMessageDTO($0) }))
        currentQRPayload = try reply.encode()
        phase = .showingCosignerRound1
    }

    /// Consume the initiator's round-2 shares, then assemble our own
    /// round-2 shares (if not already pending) and produce QR4.
    private func cosignerIngestRound2(_ r: ColdPacket.RoundPacket) throws {
        for dto in r.messages {
            let out = try bridge.handleMessage(dto.toFfi())
            for msg in out where msg.round == 2 {
                pendingRound2.append(msg)
            }
        }

        // At this point we should have a complete signature ourselves.
        if let sid = sessionId, let result = bridge.getSigningResult(sessionId: sid) {
            finalSignature = result.signature
        }

        // Either way, send our round-2 shares so the initiator can
        // finish. Even if we already have the full signature locally,
        // the initiator still needs our shares to aggregate its own.
        let reply = ColdPacket.round(.init(round: 2, messages: pendingRound2.map { MpcMessageDTO($0) }))
        currentQRPayload = try reply.encode()
        phase = .showingCosignerRound2
        // Zero the shard now — everything downstream is public.
        cleanup()
    }

    private func cleanup() {
        if var d = shardData {
            d.resetBytes(in: 0..<d.count)
            shardData = nil
        }
        if let sid = sessionId {
            bridge.removeSession(sessionId: sid)
        }
    }

    enum ColdError: LocalizedError {
        case unsupportedWalletShape
        case unexpectedPacket(phase: String)
        case noSignatureProduced
        case walletMismatch

        var errorDescription: String? {
            switch self {
            case .unsupportedWalletShape:
                return L10n.ColdSignErr.mvpOnly2of2
            case .unexpectedPacket(let phase):
                return L10n.ColdSignErr.qrMismatchPhase("\(phase)")
            case .noSignatureProduced:
                return L10n.ColdSignErr.signatureMissing
            case .walletMismatch:
                return L10n.ColdSignErr.walletMismatch
            }
        }
    }
}

// MARK: - Packet codec

enum ColdPacket {
    case invite(Invite)
    case round(RoundPacket)

    struct Invite: Codable {
        let sessionId: String
        let walletId: String
        let chain: String
        let threshold: UInt16
        let totalParties: UInt16
        let initiatorParty: UInt16
        let messageHash: Data
        let round1: [MpcMessageDTO]
    }

    struct RoundPacket: Codable {
        let round: UInt32
        let messages: [MpcMessageDTO]
    }

    private enum CodingKeys: String, CodingKey { case kind, data }
    private enum Kind: String, Codable { case invite, round }

    func encode() throws -> Data {
        let encoder = JSONEncoder()
        let json: Data
        switch self {
        case .invite(let i):
            let env = Envelope(kind: .invite, data: try encoder.encode(i))
            json = try encoder.encode(env)
        case .round(let r):
            let env = Envelope(kind: .round, data: try encoder.encode(r))
            json = try encoder.encode(env)
        }
        return Data(json.base64EncodedString().utf8)
    }

    static func decode(_ base64: String) throws -> ColdPacket {
        guard let raw = Data(base64Encoded: base64) else {
            throw ColdSigningCoordinator.ColdError.unexpectedPacket(phase: "decode")
        }
        let decoder = JSONDecoder()
        let env = try decoder.decode(Envelope.self, from: raw)
        switch env.kind {
        case .invite:
            return .invite(try decoder.decode(Invite.self, from: env.data))
        case .round:
            return .round(try decoder.decode(RoundPacket.self, from: env.data))
        }
    }

    private struct Envelope: Codable {
        let kind: Kind
        let data: Data
    }
}
