import XCTest
@testable import Horcrux

/// Tests for MessagePadding — bucket sizing, pad/unpad roundtrip, length header.
final class MessagePaddingTests: XCTestCase {

    private let buckets = [256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536]

    // MARK: - Pad output size matches a bucket

    func test_pad_outputLengthIsBucketSize() {
        let data = Data(repeating: 0xAB, count: 100)
        let padded = MessagePadding.pad(data)
        XCTAssertTrue(
            buckets.contains(padded.count),
            "Padded size \(padded.count) should be one of \(buckets)"
        )
    }

    // MARK: - 4-byte big-endian length header

    func test_pad_prependsFourByteBigEndianLength() {
        let data = Data([1, 2, 3, 4, 5])
        let padded = MessagePadding.pad(data)

        let lengthBytes = padded.prefix(4)
        let storedLength = lengthBytes.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        XCTAssertEqual(Int(storedLength), 5)
    }

    // MARK: - Roundtrip

    func test_pad_unpad_roundtrip_returnsOriginal() {
        let original = Data("Hello, Horcrux!".utf8)
        let padded = MessagePadding.pad(original)
        let recovered = MessagePadding.unpad(padded)
        XCTAssertEqual(recovered, original)
    }

    func test_pad_unpad_roundtrip_binaryData() {
        let original = Data((0..<200).map { UInt8($0 % 256) })
        let padded = MessagePadding.pad(original)
        let recovered = MessagePadding.unpad(padded)
        XCTAssertEqual(recovered, original)
    }

    // MARK: - Bucket sizing

    func test_pad_smallPayload_returns256bucket() {
        // 10 bytes payload + 4 header = 14 → fits in 256
        let data = Data(repeating: 0x01, count: 10)
        let padded = MessagePadding.pad(data)
        XCTAssertEqual(padded.count, 256)
    }

    func test_pad_252bytesPayload_returns256bucket() {
        // 252 + 4 = 256 → exactly 256
        let data = Data(repeating: 0x02, count: 252)
        let padded = MessagePadding.pad(data)
        XCTAssertEqual(padded.count, 256)
    }

    func test_pad_253bytesPayload_returns512bucket() {
        // 253 + 4 = 257 → exceeds 256, goes to 512
        let data = Data(repeating: 0x03, count: 253)
        let padded = MessagePadding.pad(data)
        XCTAssertEqual(padded.count, 512)
    }

    func test_pad_508bytesPayload_returns512bucket() {
        // 508 + 4 = 512 → exactly 512
        let data = Data(repeating: 0x04, count: 508)
        let padded = MessagePadding.pad(data)
        XCTAssertEqual(padded.count, 512)
    }

    func test_pad_1020bytesPayload_returns1024bucket() {
        // 1020 + 4 = 1024 → exactly 1024
        let data = Data(repeating: 0x05, count: 1020)
        let padded = MessagePadding.pad(data)
        XCTAssertEqual(padded.count, 1024)
    }

    func test_pad_4092bytesPayload_returns4096bucket() {
        let data = Data(repeating: 0x06, count: 4092)
        let padded = MessagePadding.pad(data)
        XCTAssertEqual(padded.count, 4096)
    }

    // MARK: - Empty data

    func test_pad_emptyData_returns256bucket() {
        let data = Data()
        let padded = MessagePadding.pad(data)
        XCTAssertEqual(padded.count, 256)

        let recovered = MessagePadding.unpad(padded)
        XCTAssertEqual(recovered, Data())
    }

    // MARK: - Large data → 65536 bucket

    func test_pad_largeData_returns65536bucket() {
        // 32769 + 4 = 32773 → exceeds 32768, goes to 65536
        let data = Data(repeating: 0xFF, count: 32769)
        let padded = MessagePadding.pad(data)
        XCTAssertEqual(padded.count, 65536)
    }

    // MARK: - Very large data → next 4096 boundary

    func test_pad_veryLargeData_roundsToNext4096() {
        // 65533 + 4 = 65537 → exceeds 65536 → next 4096 boundary = 69632
        let data = Data(repeating: 0xAA, count: 65533)
        let padded = MessagePadding.pad(data)
        XCTAssertEqual(padded.count % 4096, 0, "Should be aligned to 4096")
        XCTAssertGreaterThanOrEqual(padded.count, 65537)

        let recovered = MessagePadding.unpad(padded)
        XCTAssertEqual(recovered, data)
    }

    // MARK: - Unpad edge cases

    func test_unpad_tooShort_returnsNil() {
        let short = Data([0x00, 0x00, 0x01])  // only 3 bytes, need at least 4
        XCTAssertNil(MessagePadding.unpad(short))
    }

    func test_unpad_lengthExceedsData_returnsNil() {
        // Header says 100 bytes but total data is only 8
        var bad = Data()
        var len = UInt32(100).bigEndian
        bad.append(Data(bytes: &len, count: 4))
        bad.append(Data([0x01, 0x02, 0x03, 0x04]))
        XCTAssertNil(MessagePadding.unpad(bad))
    }

    // MARK: - All standard buckets via roundtrip

    func test_pad_unpad_allStandardBuckets() {
        // Payload sizes chosen to land in each bucket (bucket - 4 = max payload for that bucket)
        let payloadSizes = [100, 300, 600, 1500, 3000, 6000, 12000, 25000, 50000]
        for size in payloadSizes {
            let data = Data(repeating: 0x42, count: size)
            let padded = MessagePadding.pad(data)
            XCTAssertTrue(
                padded.count >= size + 4,
                "Padded (\(padded.count)) must be >= payload (\(size)) + 4"
            )
            let recovered = MessagePadding.unpad(padded)
            XCTAssertEqual(recovered, data, "Roundtrip failed for size \(size)")
        }
    }
}
