import Foundation

/// Persists MPC ceremony state so sessions can resume after disconnection.
/// Stores intermediate round data, allowing retry from the last successful round.
actor CeremonyStateManager {
    private var sessions: [String: CeremonyState] = [:]

    struct CeremonyState: Codable {
        let sessionId: String
        let type: CeremonyType
        let walletId: String
        var currentRound: Int
        var lastMessages: [Data]       // last outgoing messages for retransmit
        var isComplete: Bool
        let createdAt: Date
        var lastUpdated: Date

        enum CeremonyType: String, Codable {
            case keygen
            case signing
        }
    }

    // MARK: - State Management

    func save(sessionId: String, type: CeremonyState.CeremonyType,
              walletId: String, round: Int, messages: [Data]) {
        sessions[sessionId] = CeremonyState(
            sessionId: sessionId,
            type: type,
            walletId: walletId,
            currentRound: round,
            lastMessages: messages,
            isComplete: false,
            createdAt: sessions[sessionId]?.createdAt ?? Date(),
            lastUpdated: Date()
        )
        persistToDisk()
    }

    func markComplete(sessionId: String) {
        sessions[sessionId]?.isComplete = true
        sessions[sessionId]?.lastUpdated = Date()
        persistToDisk()
    }

    func state(for sessionId: String) -> CeremonyState? {
        sessions[sessionId]
    }

    func remove(sessionId: String) {
        sessions.removeValue(forKey: sessionId)
        persistToDisk()
    }

    /// Get all incomplete sessions (for resume on app launch).
    func incompleteSessions() -> [CeremonyState] {
        sessions.values
            .filter { !$0.isComplete }
            .sorted { $0.lastUpdated > $1.lastUpdated }
    }

    /// Clean up stale sessions older than the given interval (default: 10 minutes).
    func cleanupStale(olderThan interval: TimeInterval = 600) {
        let cutoff = Date().addingTimeInterval(-interval)
        sessions = sessions.filter { $0.value.lastUpdated > cutoff }
        persistToDisk()
    }

    // MARK: - Persistence

    private static let fileURL: URL = {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            fatalError("DocumentDirectory unavailable")
        }
        return docs.appendingPathComponent("horcrux_ceremony_state.json")
    }()

    func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: Self.fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: Self.fileURL)
            let states = try JSONDecoder().decode([CeremonyState].self, from: data)
            sessions = Dictionary(uniqueKeysWithValues: states.map { ($0.sessionId, $0) })
        } catch {
            SecureLog.error("CeremonyStateManager: load failed: \(error)")
        }
    }

    private func persistToDisk() {
        do {
            let states = Array(sessions.values)
            let data = try JSONEncoder().encode(states)
            try data.write(to: Self.fileURL, options: [.atomic, .completeFileProtection])
        } catch {
            SecureLog.error("CeremonyStateManager: save failed: \(error)")
        }
    }
}

/// Retry policy for MPC message delivery.
enum MpcRetryPolicy {
    /// Maximum retry attempts per message.
    static let maxRetries = 3

    /// Delay between retries (exponential backoff).
    static func delay(attempt: Int) -> TimeInterval {
        min(Double(1 << attempt), 8.0) // 1s, 2s, 4s, 8s
    }

    /// Execute a block with retry logic.
    static func withRetry<T>(
        maxAttempts: Int = maxRetries,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for attempt in 0..<maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                if attempt < maxAttempts - 1 {
                    let seconds = delay(attempt: attempt)
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                }
            }
        }
        throw lastError ?? CeremonyError.maxRetriesExceeded
    }
}

enum CeremonyError: LocalizedError {
    case maxRetriesExceeded
    case sessionExpired
    case peerDisconnected

    var errorDescription: String? {
        switch self {
        case .maxRetriesExceeded: return "Failed after maximum retry attempts"
        case .sessionExpired: return "Ceremony session has expired"
        case .peerDisconnected: return "Co-signer disconnected during ceremony"
        }
    }
}
