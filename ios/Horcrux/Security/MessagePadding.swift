import Foundation

/// Pads and unpads MPC messages to fixed-size buckets to prevent
/// length-based side-channel analysis. Also adds optional timing jitter.
///
/// Bucket sizes: 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536
/// Messages larger than 65536 bytes are padded to the next 4096 boundary.
enum MessagePadding {

    /// Pad sizes — power-of-2 buckets from 256 to 64K.
    private static let buckets: [Int] = [256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536]

    /// Pad a message to the next bucket size.
    /// Format: [4-byte big-endian original length] [original data] [random padding]
    static func pad(_ data: Data) -> Data {
        let originalLength = data.count
        let headerSize = 4 // 4 bytes for length prefix

        let totalNeeded = headerSize + originalLength
        let targetSize = bucketSize(for: totalNeeded)

        var padded = Data(capacity: targetSize)

        // 4-byte big-endian length header
        var len = UInt32(originalLength).bigEndian
        padded.append(Data(bytes: &len, count: 4))

        // Original payload
        padded.append(data)

        // Random padding to fill bucket
        let paddingNeeded = targetSize - padded.count
        if paddingNeeded > 0 {
            var randomBytes = [UInt8](repeating: 0, count: paddingNeeded)
            _ = SecRandomCopyBytes(kSecRandomDefault, paddingNeeded, &randomBytes)
            padded.append(contentsOf: randomBytes)
        }

        return padded
    }

    /// Remove padding and recover the original message.
    static func unpad(_ padded: Data) -> Data? {
        guard padded.count >= 4 else { return nil }

        // Read 4-byte big-endian length
        let lengthBytes = padded.prefix(4)
        let length = lengthBytes.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let originalLength = Int(length)

        guard originalLength >= 0,
              padded.count >= 4 + originalLength else { return nil }

        return padded.subdata(in: 4..<(4 + originalLength))
    }

    /// Find the smallest bucket that fits the given size.
    private static func bucketSize(for size: Int) -> Int {
        for bucket in buckets {
            if size <= bucket { return bucket }
        }
        // For very large messages, round up to next 4096 boundary
        return ((size + 4095) / 4096) * 4096
    }

    /// Add random timing jitter (0–50ms) before sending.
    /// Call this in an async context before transmitting.
    static func randomJitter() async {
        let jitterNanos = UInt64.random(in: 0...50_000_000) // 0–50ms
        try? await Task.sleep(nanoseconds: jitterNanos)
    }
}
