import Foundation

/// A signing request that has arrived at this device but hasn't been
/// acted on yet — or has been handled and is kept in the log for audit.
///
/// MPC threshold signing still requires all co-signers to be online
/// simultaneously to exchange protocol rounds, so a "pending" entry
/// here does NOT mean the request can be re-activated at a later time
/// offline — the relay session it referenced is almost certainly gone
/// by then. What the queue DOES give us is:
///   • a persistent to-do for the operator (so QR scans aren't lost
///     when the sheet is dismissed without a decision)
///   • an audit trail of approve/reject actions with timestamps
///   • a single place to see all signing activity across wallets,
///     which is the start of a compliance-grade log view
struct ApprovalRequest: Identifiable, Codable, Equatable {
    let id: String
    /// MPC relay room — same value the cosigner's `SigningViewModel`
    /// would pin if they resumed. Kept for debugging + future resume.
    let sessionId: String
    /// Group public key hex of the wallet that owns this request.
    let groupPublicKey: String
    let chain: String
    let recipient: String
    let amount: String
    let tokenSymbol: String?
    let feeDisplay: String?
    let initiatorDeviceName: String

    var status: Status
    let createdAt: Date
    var resolvedAt: Date?

    enum Status: String, Codable {
        case pending
        case approved
        case rejected
        case expired
    }

    /// Pending entries older than this are considered stale — the
    /// relay session they reference has almost certainly been torn
    /// down so re-activating would fail. `ApprovalsView` uses this
    /// to grey-out stale rows and nudge the user to dismiss them.
    static let pendingTTL: TimeInterval = 24 * 3600

    var isStale: Bool {
        guard status == .pending else { return false }
        return Date().timeIntervalSince(createdAt) > Self.pendingTTL
    }
}
