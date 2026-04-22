import Foundation
import Combine

/// Persists the approval queue to a JSON file in Documents. Keeps every
/// request the user has ever logged — pending, approved, rejected,
/// expired — so the view can render both the "what needs doing now"
/// section and a historical audit tail.
///
/// Entries are small (~300 bytes each), so even an active operator
/// writing multiple signing requests a day stays well under a
/// megabyte for years. We prune anything older than `retentionDays`
/// on load to keep the file bounded.
@MainActor
final class ApprovalRequestStore: ObservableObject {
    static let shared = ApprovalRequestStore()

    @Published private(set) var requests: [ApprovalRequest] = []

    private let fileURL: URL
    private let retentionDays: Int = 180

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.fileURL = docs.appendingPathComponent("horcrux_approvals.json")
        }
        load()
        sweep()
    }

    // MARK: - Public API

    /// Convert a scanned `SignRequestDTO` into a pending queue entry.
    /// Returns the id so the caller can attach it to whatever UI flow
    /// might eventually resolve the entry.
    @discardableResult
    func enqueue(from dto: SignRequestDTO) -> String {
        // De-dupe on sessionId — if the user scanned the same QR twice
        // we don't want two copies cluttering the queue.
        if let existing = requests.first(where: { $0.sessionId == dto.sessionId && $0.status == .pending }) {
            return existing.id
        }
        let req = ApprovalRequest(
            id: UUID().uuidString,
            sessionId: dto.sessionId,
            groupPublicKey: dto.groupPublicKey,
            chain: dto.chain,
            recipient: dto.recipient,
            amount: dto.amount,
            tokenSymbol: dto.tokenSymbol,
            feeDisplay: dto.feeDisplay,
            initiatorDeviceName: dto.initiatorDeviceName,
            status: .pending,
            createdAt: Date(),
            resolvedAt: nil
        )
        requests.insert(req, at: 0)
        persist()
        return req.id
    }

    /// Direct-log variant for when we already know the outcome (e.g.
    /// the cosigner tapped Approve and the signing actually
    /// completed). Used by the signing flow's completion callback —
    /// future work; for MVP this keeps the API surface ready.
    @discardableResult
    func log(from dto: SignRequestDTO, status: ApprovalRequest.Status) -> String {
        let now = Date()
        let req = ApprovalRequest(
            id: UUID().uuidString,
            sessionId: dto.sessionId,
            groupPublicKey: dto.groupPublicKey,
            chain: dto.chain,
            recipient: dto.recipient,
            amount: dto.amount,
            tokenSymbol: dto.tokenSymbol,
            feeDisplay: dto.feeDisplay,
            initiatorDeviceName: dto.initiatorDeviceName,
            status: status,
            createdAt: now,
            resolvedAt: status == .pending ? nil : now
        )
        requests.insert(req, at: 0)
        persist()
        return req.id
    }

    /// Flip a pending entry's status. Stamps `resolvedAt`.
    func resolve(id: String, as status: ApprovalRequest.Status) {
        guard let idx = requests.firstIndex(where: { $0.id == id }) else { return }
        requests[idx].status = status
        requests[idx].resolvedAt = Date()
        persist()
    }

    /// Look up the pending entry for a given session — lets the
    /// signing flow mark its own queue entry as approved on success.
    func pendingRequest(forSessionId sessionId: String) -> ApprovalRequest? {
        requests.first { $0.sessionId == sessionId && $0.status == .pending }
    }

    func delete(id: String) {
        requests.removeAll { $0.id == id }
        persist()
    }

    /// Remove everything in the log that's already been acted on —
    /// used by the "Clear history" action in the view.
    func clearResolved() {
        requests.removeAll { $0.status != .pending }
        persist()
    }

    /// Invoked by the master wipe path so the queue doesn't leak
    /// recipient addresses after a factory reset.
    func wipeAll() {
        requests.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Sections

    var pending: [ApprovalRequest] {
        requests.filter { $0.status == .pending && !$0.isStale }
    }

    var stalePending: [ApprovalRequest] {
        requests.filter { $0.status == .pending && $0.isStale }
    }

    var recent: [ApprovalRequest] {
        requests
            .filter { $0.status != .pending }
            .sorted { ($0.resolvedAt ?? $0.createdAt) > ($1.resolvedAt ?? $1.createdAt) }
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder.iso8601().decode([ApprovalRequest].self, from: data) else {
            return
        }
        requests = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder.iso8601().encode(requests) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Auto-expire stale pending + prune ancient history beyond the
    /// retention window. Runs on launch only — cheap.
    private func sweep() {
        let now = Date()
        let horizon = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        var changed = false
        for i in requests.indices {
            if requests[i].status == .pending && requests[i].isStale {
                requests[i].status = .expired
                requests[i].resolvedAt = now
                changed = true
            }
        }
        let before = requests.count
        requests.removeAll { ($0.resolvedAt ?? $0.createdAt) < horizon }
        if requests.count != before { changed = true }
        if changed { persist() }
    }
}

// MARK: - ISO-8601 JSON helpers

private extension JSONEncoder {
    static func iso8601() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return enc
    }
}

private extension JSONDecoder {
    static func iso8601() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }
}
