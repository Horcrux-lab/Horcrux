import Foundation
import AVFoundation
import CoreImage

/// QR code transport — uses camera to scan and screen to display.
/// For small payloads (public keys, session IDs, room codes).
/// For larger data, uses animated QR (multiple frames).
final class QRTransport: NSObject, ObservableObject {
    @Published var scannedData: Data?
    @Published var qrImage: CGImage?

    /// Generate a QR code image from data.
    func generateQR(from data: Data) -> CGImage? {
        let string = data.base64EncodedString()
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel") // High error correction

        guard let ciImage = filter.outputImage else { return nil }

        // Scale up for display
        let transform = CGAffineTransform(scaleX: 10, y: 10)
        let scaled = ciImage.transformed(by: transform)

        let context = CIContext()
        let cgImage = context.createCGImage(scaled, from: scaled.extent)
        qrImage = cgImage
        return cgImage
    }

    /// Generate a QR code for a relay room invitation.
    func generateRoomInvite(roomId: String, token: String?, relayURL: String) -> CGImage? {
        let invite: [String: String?] = [
            "room": roomId,
            "token": token,
            "relay": relayURL
        ]
        let data: Data
        do {
            data = try JSONEncoder().encode(invite)
        } catch {
            SecureLog.error("Failed to encode QR room invite: \(error.localizedDescription)")
            return nil
        }
        return generateQR(from: data)
    }

    /// Parse a scanned QR code as a room invitation.
    func parseRoomInvite(from data: Data) -> (roomId: String, token: String?, relayURL: String)? {
        let json: [String: String?]
        do {
            json = try JSONDecoder().decode([String: String?].self, from: data)
        } catch {
            SecureLog.error("Failed to decode QR room invite: \(error.localizedDescription)")
            return nil
        }
        guard let roomId = json["room"] ?? nil,
              let relay = json["relay"] ?? nil else { return nil }
        return (roomId: roomId, token: json["token"] ?? nil, relayURL: relay)
    }
}
