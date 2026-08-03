import XCTest
@testable import Horcrux

/// Tests for `ColdPacketV2`, the wire codec for air-gapped ("cold") signing.
///
/// Every byte of a cold ceremony crosses this codec: the initiator renders a
/// packet as a QR code, the offline co-signer scans it, and the reply comes
/// back the same way. There is no network to retry over and no server to
/// reconcile against — if a field is dropped, reordered, or silently
/// truncated here, the ceremony either wedges or produces a signature over
/// the wrong data.
final class ColdPacketV2Tests: XCTestCase {

    // MARK: - Helpers

    private func message(from: UInt16 = 1,
                         to: UInt16 = 2,
                         round: UInt32 = 0,
                         sessionId: String = "coldv2-abc123",
                         payload: Data = Data([0x01, 0x02, 0x03])) -> MpcMessageDTO {
        MpcMessageDTO(FfiMpcMessage(fromParty: from,
                                    toParty: to,
                                    round: round,
                                    sessionId: sessionId,
                                    payload: payload))
    }

    private func invite(messages: [MpcMessageDTO]? = nil,
                        messageHash: Data = Data(repeating: 0xAB, count: 32)) -> ColdPacketV2.Invite {
        ColdPacketV2.Invite(sessionId: "coldv2-abc123",
                            walletId: "wallet-1",
                            chain: "bitcoin",
                            threshold: 2,
                            totalParties: 2,
                            initiatorParty: 0,
                            participants: [0, 1],
                            messageHash: messageHash,
                            messages: messages ?? [message()])
    }

    /// `encode()` returns base64 *text*, while `decode()` takes a `String`.
    private func wire(_ packet: ColdPacketV2) throws -> String {
        let data = try packet.encode()
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func assertUnexpectedPacket(_ expression: @autoclosure () throws -> ColdPacketV2,
                                        file: StaticString = #filePath,
                                        line: UInt = #line) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard case ColdSigningCoordinator.ColdError.unexpectedPacket = error else {
                XCTFail("expected .unexpectedPacket, got \(error)", file: file, line: line)
                return
            }
        }
    }

    // MARK: - Invite round trip

    func testInviteRoundTripPreservesEveryField() throws {
        let original = invite()
        guard case .invite(let decoded) = try ColdPacketV2.decode(wire(.invite(original))) else {
            return XCTFail("expected an invite")
        }
        XCTAssertEqual(decoded.sessionId, original.sessionId)
        XCTAssertEqual(decoded.walletId, original.walletId)
        XCTAssertEqual(decoded.chain, original.chain)
        XCTAssertEqual(decoded.threshold, original.threshold)
        XCTAssertEqual(decoded.totalParties, original.totalParties)
        XCTAssertEqual(decoded.initiatorParty, original.initiatorParty)
        XCTAssertEqual(decoded.participants, original.participants)
        XCTAssertEqual(decoded.messageHash, original.messageHash)
        XCTAssertEqual(decoded.messages.count, original.messages.count)
    }

    /// The hash the co-signer is about to authorize. A mangled byte here means
    /// signing something other than what the initiator displayed.
    func testMessageHashSurvivesEveryByteValue() throws {
        let hash = Data((0...255).map { UInt8($0) })
        guard case .invite(let decoded) = try ColdPacketV2.decode(wire(.invite(invite(messageHash: hash)))) else {
            return XCTFail("expected an invite")
        }
        XCTAssertEqual(decoded.messageHash, hash)
    }

    func testInvitePreservesParticipantOrder() throws {
        let original = ColdPacketV2.Invite(sessionId: "s", walletId: "w", chain: "ethereum",
                                           threshold: 2, totalParties: 3, initiatorParty: 2,
                                           participants: [2, 0, 1],
                                           messageHash: Data([0x01]), messages: [])
        guard case .invite(let decoded) = try ColdPacketV2.decode(wire(.invite(original))) else {
            return XCTFail("expected an invite")
        }
        XCTAssertEqual(decoded.participants, [2, 0, 1])
        XCTAssertEqual(decoded.initiatorParty, 2)
    }

    func testInviteSurvivesUInt16Extremes() throws {
        let original = ColdPacketV2.Invite(sessionId: "s", walletId: "w", chain: "c",
                                           threshold: .max, totalParties: .max,
                                           initiatorParty: .max, participants: [0, .max],
                                           messageHash: Data(), messages: [])
        guard case .invite(let decoded) = try ColdPacketV2.decode(wire(.invite(original))) else {
            return XCTFail("expected an invite")
        }
        XCTAssertEqual(decoded.threshold, .max)
        XCTAssertEqual(decoded.totalParties, .max)
        XCTAssertEqual(decoded.initiatorParty, .max)
        XCTAssertEqual(decoded.participants, [0, .max])
    }

    func testInviteWithNoMessagesRoundTrips() throws {
        guard case .invite(let decoded) = try ColdPacketV2.decode(wire(.invite(invite(messages: [])))) else {
            return XCTFail("expected an invite")
        }
        XCTAssertTrue(decoded.messages.isEmpty)
    }

    func testInviteWithUnicodeIdentifiersRoundTrips() throws {
        let original = ColdPacketV2.Invite(sessionId: "会话-🔐", walletId: "钱包/1", chain: "bitcoin",
                                           threshold: 2, totalParties: 2, initiatorParty: 0,
                                           participants: [0, 1], messageHash: Data([0xFF]),
                                           messages: [])
        guard case .invite(let decoded) = try ColdPacketV2.decode(wire(.invite(original))) else {
            return XCTFail("expected an invite")
        }
        XCTAssertEqual(decoded.sessionId, "会话-🔐")
        XCTAssertEqual(decoded.walletId, "钱包/1")
    }

    // MARK: - Round packet round trip

    func testRoundPacketRoundTripPreservesStepAndMessages() throws {
        let original = ColdPacketV2.RoundPacket(step: 7, messages: [message(from: 1, to: 0, round: 3)])
        guard case .round(let decoded) = try ColdPacketV2.decode(wire(.round(original))) else {
            return XCTFail("expected a round packet")
        }
        XCTAssertEqual(decoded.step, 7)
        XCTAssertEqual(decoded.messages.count, 1)
        XCTAssertEqual(decoded.messages[0].fromParty, 1)
        XCTAssertEqual(decoded.messages[0].toParty, 0)
        XCTAssertEqual(decoded.messages[0].round, 3)
    }

    func testRoundPacketSurvivesUInt32Extremes() throws {
        let original = ColdPacketV2.RoundPacket(step: .max,
                                                messages: [message(round: .max)])
        guard case .round(let decoded) = try ColdPacketV2.decode(wire(.round(original))) else {
            return XCTFail("expected a round packet")
        }
        XCTAssertEqual(decoded.step, .max)
        XCTAssertEqual(decoded.messages[0].round, .max)
    }

    func testRoundPacketPreservesMessageOrder() throws {
        let msgs = (0..<5).map { message(from: UInt16($0), to: UInt16(5 - $0), round: UInt32($0)) }
        guard case .round(let decoded) = try ColdPacketV2.decode(wire(.round(.init(step: 1, messages: msgs)))) else {
            return XCTFail("expected a round packet")
        }
        XCTAssertEqual(decoded.messages.map(\.fromParty), [0, 1, 2, 3, 4])
        XCTAssertEqual(decoded.messages.map(\.toParty), [5, 4, 3, 2, 1])
    }

    /// MPC payloads are opaque binary; base64/JSON must not mangle them.
    func testMessagePayloadSurvivesEveryByteValue() throws {
        let payload = Data((0...255).map { UInt8($0) })
        guard case .round(let decoded) = try ColdPacketV2.decode(
            wire(.round(.init(step: 0, messages: [message(payload: payload)])))
        ) else {
            return XCTFail("expected a round packet")
        }
        XCTAssertEqual(decoded.messages[0].payload, payload)
    }

    func testLargeMultiMessagePacketRoundTrips() throws {
        let msgs = (0..<24).map { i in
            message(from: UInt16(i % 4), payload: Data(repeating: UInt8(i), count: 1024))
        }
        guard case .round(let decoded) = try ColdPacketV2.decode(wire(.round(.init(step: 2, messages: msgs)))) else {
            return XCTFail("expected a round packet")
        }
        XCTAssertEqual(decoded.messages.count, 24)
        XCTAssertEqual(decoded.messages[23].payload, Data(repeating: 23, count: 1024))
    }

    // MARK: - Kind discrimination

    func testInviteDoesNotDecodeAsRoundPacket() throws {
        guard case .invite = try ColdPacketV2.decode(wire(.invite(invite()))) else {
            return XCTFail("an invite must not decode as a round packet")
        }
    }

    func testRoundPacketDoesNotDecodeAsInvite() throws {
        guard case .round = try ColdPacketV2.decode(wire(.round(.init(step: 0, messages: [])))) else {
            return XCTFail("a round packet must not decode as an invite")
        }
    }

    // MARK: - Wire format

    func testEncodeProducesBase64Text() throws {
        let text = try wire(.invite(invite()))
        XCTAssertNotNil(Data(base64Encoded: text), "QR payload must be decodable base64")
        XCTAssertTrue(text.allSatisfy { $0.isASCII }, "QR payload must be ASCII")
    }

    func testEnvelopeDeclaresVersionTwo() throws {
        let raw = try XCTUnwrap(Data(base64Encoded: try wire(.invite(invite()))))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 2)
        XCTAssertEqual(json["kind"] as? String, "invite")
    }

    // MARK: - Rejection

    func testDecodeRejectsNonBase64() {
        assertUnexpectedPacket(try ColdPacketV2.decode("not base64 !!!"))
    }

    func testDecodeRejectsEmptyString() throws {
        // "" is valid base64 for zero bytes, so this must fail in the JSON
        // decoder rather than silently yielding a packet.
        XCTAssertThrowsError(try ColdPacketV2.decode(""))
    }

    func testDecodeRejectsBase64ThatIsNotJSON() {
        let junk = Data([0xDE, 0xAD, 0xBE, 0xEF]).base64EncodedString()
        XCTAssertThrowsError(try ColdPacketV2.decode(junk))
    }

    /// A scanner on v2 must refuse a v1 QR outright rather than misread its
    /// fields — the two formats are not interchangeable.
    func testDecodeRejectsOlderEnvelopeVersion() throws {
        assertUnexpectedPacket(try ColdPacketV2.decode(try envelope(version: 1, kind: "invite")))
    }

    func testDecodeRejectsNewerEnvelopeVersion() throws {
        assertUnexpectedPacket(try ColdPacketV2.decode(try envelope(version: 3, kind: "invite")))
    }

    func testDecodeRejectsVersionZero() throws {
        assertUnexpectedPacket(try ColdPacketV2.decode(try envelope(version: 0, kind: "invite")))
    }

    func testDecodeRejectsUnknownKind() throws {
        XCTAssertThrowsError(try ColdPacketV2.decode(try envelope(version: 2, kind: "handshake")))
    }

    /// The version guard must run before the inner payload is trusted.
    func testVersionIsCheckedEvenWhenInnerPayloadIsValid() throws {
        let inner = try JSONEncoder().encode(invite())
        assertUnexpectedPacket(try ColdPacketV2.decode(try envelope(version: 1, kind: "invite", data: inner)))
    }

    func testDecodeRejectsKindInviteCarryingRoundPayload() throws {
        let inner = try JSONEncoder().encode(ColdPacketV2.RoundPacket(step: 1, messages: []))
        XCTAssertThrowsError(try ColdPacketV2.decode(try envelope(version: 2, kind: "invite", data: inner)))
    }

    func testDecodeRejectsTruncatedPayload() throws {
        let text = try wire(.invite(invite()))
        let raw = try XCTUnwrap(Data(base64Encoded: text))
        let truncated = raw.prefix(raw.count / 2).base64EncodedString()
        XCTAssertThrowsError(try ColdPacketV2.decode(truncated))
    }

    // MARK: - Missing required fields
    //
    // A corrupted or hand-crafted QR must be rejected outright. Nothing in
    // the packet may fall back to a default: a defaulted `messageHash` would
    // mean authorizing an empty digest, and a defaulted `step` would let a
    // replayed frame pass as the next one.

    func testDecodeRejectsInviteMissingMessageHash() throws {
        let inner = Data(#"{"sessionId":"s","walletId":"w","chain":"bitcoin","threshold":2,"totalParties":2,"initiatorParty":0,"participants":[0,1],"messages":[]}"#.utf8)
        XCTAssertThrowsError(try ColdPacketV2.decode(try envelope(version: 2, kind: "invite", data: inner)))
    }

    func testDecodeRejectsInviteMissingParticipants() throws {
        let inner = Data(#"{"sessionId":"s","walletId":"w","chain":"bitcoin","threshold":2,"totalParties":2,"initiatorParty":0,"messageHash":"AAE=","messages":[]}"#.utf8)
        XCTAssertThrowsError(try ColdPacketV2.decode(try envelope(version: 2, kind: "invite", data: inner)))
    }

    func testDecodeRejectsRoundPacketMissingStep() throws {
        let inner = Data(#"{"messages":[]}"#.utf8)
        XCTAssertThrowsError(try ColdPacketV2.decode(try envelope(version: 2, kind: "round", data: inner)))
    }

    func testDecodeRejectsRoundPacketMissingMessages() throws {
        let inner = Data(#"{"step":1}"#.utf8)
        XCTAssertThrowsError(try ColdPacketV2.decode(try envelope(version: 2, kind: "round", data: inner)))
    }

    func testDecodeRejectsMessageMissingPayload() throws {
        let inner = Data(#"{"step":1,"messages":[{"fromParty":1,"toParty":2,"round":0,"sessionId":"s"}]}"#.utf8)
        XCTAssertThrowsError(try ColdPacketV2.decode(try envelope(version: 2, kind: "round", data: inner)))
    }

    private func envelope(version: UInt8, kind: String, data: Data = Data("{}".utf8)) throws -> String {
        struct TestEnvelope: Codable {
            let version: UInt8
            let kind: String
            let data: Data
        }
        let json = try JSONEncoder().encode(TestEnvelope(version: version, kind: kind, data: data))
        return json.base64EncodedString()
    }
}
