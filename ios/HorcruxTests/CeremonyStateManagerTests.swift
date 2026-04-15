import XCTest
@testable import Horcrux

/// Tests for CeremonyStateManager and MpcRetryPolicy.
final class CeremonyStateManagerTests: XCTestCase {

    // MARK: - CeremonyStateManager: save / load

    func test_save_andRetrieveState() async {
        let manager = CeremonyStateManager()
        let messages = [Data([0x01, 0x02]), Data([0x03])]

        await manager.save(
            sessionId: "sess-1",
            type: .keygen,
            walletId: "wallet-1",
            round: 1,
            messages: messages
        )

        let state = await manager.state(for: "sess-1")
        XCTAssertNotNil(state)
        XCTAssertEqual(state?.sessionId, "sess-1")
        XCTAssertEqual(state?.type, .keygen)
        XCTAssertEqual(state?.walletId, "wallet-1")
        XCTAssertEqual(state?.currentRound, 1)
        XCTAssertEqual(state?.lastMessages, messages)
        XCTAssertFalse(state?.isComplete ?? true)
    }

    func test_save_updatesExistingSession() async {
        let manager = CeremonyStateManager()

        await manager.save(sessionId: "sess-2", type: .signing, walletId: "w", round: 1, messages: [])
        await manager.save(sessionId: "sess-2", type: .signing, walletId: "w", round: 2, messages: [Data([0xFF])])

        let state = await manager.state(for: "sess-2")
        XCTAssertEqual(state?.currentRound, 2)
        XCTAssertEqual(state?.lastMessages, [Data([0xFF])])
    }

    func test_save_preservesOriginalCreatedAt() async {
        let manager = CeremonyStateManager()

        await manager.save(sessionId: "sess-3", type: .keygen, walletId: "w", round: 1, messages: [])
        let firstCreatedAt = await manager.state(for: "sess-3")?.createdAt

        // Brief delay to ensure different timestamp
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms

        await manager.save(sessionId: "sess-3", type: .keygen, walletId: "w", round: 2, messages: [])
        let secondCreatedAt = await manager.state(for: "sess-3")?.createdAt

        XCTAssertEqual(firstCreatedAt, secondCreatedAt, "createdAt should be preserved on update")
    }

    // MARK: - markComplete

    func test_markComplete_setsIsComplete() async {
        let manager = CeremonyStateManager()
        await manager.save(sessionId: "s", type: .signing, walletId: "w", round: 3, messages: [])

        await manager.markComplete(sessionId: "s")

        let state = await manager.state(for: "s")
        XCTAssertTrue(state?.isComplete ?? false)
    }

    // MARK: - remove

    func test_remove_deletesSession() async {
        let manager = CeremonyStateManager()
        await manager.save(sessionId: "del-me", type: .keygen, walletId: "w", round: 1, messages: [])

        await manager.remove(sessionId: "del-me")

        let state = await manager.state(for: "del-me")
        XCTAssertNil(state)
    }

    // MARK: - incompleteSessions

    func test_incompleteSessions_excludesComplete() async {
        let manager = CeremonyStateManager()
        await manager.save(sessionId: "a", type: .keygen, walletId: "w", round: 1, messages: [])
        await manager.save(sessionId: "b", type: .signing, walletId: "w", round: 1, messages: [])
        await manager.markComplete(sessionId: "a")

        let incomplete = await manager.incompleteSessions()
        XCTAssertEqual(incomplete.count, 1)
        XCTAssertEqual(incomplete.first?.sessionId, "b")
    }

    func test_incompleteSessions_sortedByLastUpdated() async {
        let manager = CeremonyStateManager()
        await manager.save(sessionId: "old", type: .keygen, walletId: "w", round: 1, messages: [])
        try? await Task.sleep(nanoseconds: 10_000_000)
        await manager.save(sessionId: "new", type: .signing, walletId: "w", round: 1, messages: [])

        let incomplete = await manager.incompleteSessions()
        XCTAssertEqual(incomplete.first?.sessionId, "new", "Most recently updated should be first")
    }

    // MARK: - state(for:) nonexistent

    func test_state_forNonexistent_returnsNil() async {
        let manager = CeremonyStateManager()
        let state = await manager.state(for: "does-not-exist")
        XCTAssertNil(state)
    }

    // MARK: - CeremonyState.CeremonyType

    func test_ceremonyType_rawValues() {
        XCTAssertEqual(CeremonyStateManager.CeremonyState.CeremonyType.keygen.rawValue, "keygen")
        XCTAssertEqual(CeremonyStateManager.CeremonyState.CeremonyType.signing.rawValue, "signing")
    }

    // MARK: - MpcRetryPolicy: delay

    func test_retryDelay_exponentialBackoff() {
        XCTAssertEqual(MpcRetryPolicy.delay(attempt: 0), 1.0)  // 2^0 = 1
        XCTAssertEqual(MpcRetryPolicy.delay(attempt: 1), 2.0)  // 2^1 = 2
        XCTAssertEqual(MpcRetryPolicy.delay(attempt: 2), 4.0)  // 2^2 = 4
        XCTAssertEqual(MpcRetryPolicy.delay(attempt: 3), 8.0)  // 2^3 = 8, capped at 8
    }

    func test_retryDelay_cappedAt8Seconds() {
        XCTAssertEqual(MpcRetryPolicy.delay(attempt: 4), 8.0)  // 2^4 = 16, capped at 8
        XCTAssertEqual(MpcRetryPolicy.delay(attempt: 10), 8.0) // Way beyond cap
    }

    // MARK: - MpcRetryPolicy: maxRetries

    func test_maxRetries_isThree() {
        XCTAssertEqual(MpcRetryPolicy.maxRetries, 3)
    }

    // MARK: - MpcRetryPolicy: withRetry success

    func test_withRetry_succeedsOnFirstAttempt() async throws {
        var callCount = 0
        let result: String = try await MpcRetryPolicy.withRetry(maxAttempts: 3) {
            callCount += 1
            return "ok"
        }
        XCTAssertEqual(result, "ok")
        XCTAssertEqual(callCount, 1)
    }

    // MARK: - MpcRetryPolicy: withRetry failure then success

    func test_withRetry_succeedsAfterRetries() async throws {
        var callCount = 0
        let result: String = try await MpcRetryPolicy.withRetry(maxAttempts: 3) {
            callCount += 1
            if callCount < 3 {
                throw CeremonyError.peerDisconnected
            }
            return "recovered"
        }
        XCTAssertEqual(result, "recovered")
        XCTAssertEqual(callCount, 3)
    }

    // MARK: - MpcRetryPolicy: withRetry exhausts attempts

    func test_withRetry_throwsAfterMaxAttempts() async {
        var callCount = 0
        do {
            let _: String = try await MpcRetryPolicy.withRetry(maxAttempts: 2) {
                callCount += 1
                throw CeremonyError.peerDisconnected
            }
            XCTFail("Should have thrown")
        } catch {
            XCTAssertEqual(callCount, 2)
        }
    }

    // MARK: - CeremonyError descriptions

    func test_ceremonyError_descriptions() {
        XCTAssertNotNil(CeremonyError.maxRetriesExceeded.errorDescription)
        XCTAssertNotNil(CeremonyError.sessionExpired.errorDescription)
        XCTAssertNotNil(CeremonyError.peerDisconnected.errorDescription)
    }
}
