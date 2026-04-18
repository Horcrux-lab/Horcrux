import Foundation
import SwiftUI

/// Cold-signing coordinator — drives the FROST ceremony entirely over
/// air-gapped QR chain (no relay, no WebSocket). One device plays the
/// **initiator**, another the **cosigner**; each produces a QR that the
/// other scans. For MPC the coordinator just marshals `FfiMpcMessage`s
/// through `HorcruxBridge` — all crypto happens in Rust.
///
/// **Status (dev.39):** initiator flow scaffolded and functional for
/// 2-of-2 wallets. The matching cosigner state machine lands in dev.40,
/// so a full end-to-end ceremony requires the next build. The UI is
/// explicitly marked 实验性 until then.
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

    enum Phase: String {
        case idle
        case showingInvite      // initiator: display invite QR, wait for scan
        case awaitingRound1     // initiator: scan cosigner's round-1 reply
        case showingRound2      // initiator: display round-2 QR
        case awaitingRound2     // initiator: scan cosigner's round-2 share
        case complete
        case failed
    }

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
        default: break
        }
    }

    // MARK: - Internals

    private func process(_ packet: ColdPacket) throws {
        switch (phase, packet) {
        case (.awaitingRound1, .round(let r)) where r.round == 1:
            try ingestRound1(r)
        case (.awaitingRound2, .round(let r)) where r.round == 2:
            try ingestRound2(r)
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

        var errorDescription: String? {
            switch self {
            case .unsupportedWalletShape:
                return L10n.ColdSignErr.mvpOnly2of2
            case .unexpectedPacket(let phase):
                return L10n.ColdSignErr.qrMismatchPhase("\(phase)")
            case .noSignatureProduced:
                return L10n.ColdSignErr.signatureMissing
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
