import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Human-readable name for this device used in peer discovery control messages.
/// Priority: user-set nickname in Settings → UIDevice.current.name → model.
private var localDeviceName: String {
    if let nick = UserDefaults.standard.string(forKey: "deviceNickname"),
       !nick.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return nick
    }
    #if canImport(UIKit)
    let d = UIDevice.current
    if !d.name.isEmpty, d.name != d.model {
        return "\(d.name) (\(d.model))"
    }
    return d.model
    #else
    return "iOS Device"
    #endif
}

/// WebSocket transport to the horcrux-relay server for remote DKG and signing.
/// All messages are E2E encrypted via Noise Protocol before sending.
///
/// Protocol: connect to `ws://{host}/ws/{room_id}?device_id={id}`,
/// then exchange JSON messages: `{"from","to","payload","seq"}`.
/// Peer discovery uses an app-level announce/ack handshake over the relay.
final class RelayTransport: NSObject, TransportChannel, ObservableObject {
    let channelId = "relay"
    let channelName = "Relay Server"

    @Published private(set) var isConnected: Bool = false
    @Published private(set) var discoveredPeers: [Peer] = []
    @Published var relayURL: String = RelayConfig.effectiveURL

    weak var delegate: TransportChannelDelegate?

    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession!
    private var roomId: String?
    private(set) var deviceId: String = UUID().uuidString
    private var seq: UInt64 = 0
    private var openContinuation: CheckedContinuation<Void, Error>?

    private var messageContinuation: AsyncStream<TransportMessage>.Continuation?
    let incomingMessages: AsyncStream<TransportMessage>

    override init() {
        let (stream, continuation) = AsyncStream<TransportMessage>.makeStream()
        self.incomingMessages = stream
        self.messageContinuation = continuation
        super.init()
        let config = URLSessionConfiguration.default
        config.connectionProxyDictionary = [:]  // bypass system proxy for relay
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    func startDiscovery() {
        // After joining a room, send an announce so other peers discover us
        guard isConnected else { return }
        Task {
            try? await sendControl(type: "announce")
        }
    }

    func stopDiscovery() {}

    /// Join (or create) a relay room. Room code is shared out-of-band (QR, verbal).
    /// Connects to: `ws://{relayURL}/ws/{roomId}?device_id={deviceId}`
    func joinRoom(roomId: String, token: String? = nil) async throws {
        self.roomId = roomId
        seq = 0

        // Build URL: base/ws/{roomId}?device_id={deviceId}
        let base = relayURL.hasSuffix("/") ? String(relayURL.dropLast()) : relayURL
        var urlString = "\(base)/ws/\(roomId)?device_id=\(deviceId)"
        if let token { urlString += "&token=\(token)" }

        guard let url = URL(string: urlString) else {
            throw TransportError.connectionFailed("Invalid relay URL: \(urlString)")
        }

        // Wait for actual WebSocket open before sending anything
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.openContinuation = cont
            self.webSocket = self.urlSession.webSocketTask(with: url)
            self.webSocket?.maximumMessageSize = 4 * 1024 * 1024 // 4MB for Paillier proofs
            self.webSocket?.resume()
        }

        isConnected = true
        startReceiving()

        // Announce our presence so peers already in the room discover us
        try await sendControl(type: "announce")
    }

    func connect(to peer: Peer) async throws {
        // In relay mode, connection is implicit via room membership
    }

    func disconnect(from peer: Peer) {
        webSocket?.cancel(with: .normalClosure, reason: nil)
        isConnected = false
        discoveredPeers.removeAll()
    }

    func send(_ data: Data, to peer: Peer) async throws {
        guard isConnected else { throw TransportError.notConnected }
        let msg = RelayMessage(
            from: deviceId,
            to: peer.id,
            payload: data.base64EncodedString(),
            seq: nextSeq()
        )
        let json = try JSONEncoder().encode(msg)
        try await webSocket?.send(.string(String(data: json, encoding: .utf8)!))
    }

    func broadcast(_ data: Data) async throws {
        guard isConnected else { throw TransportError.notConnected }
        let msg = RelayMessage(
            from: deviceId,
            to: "",
            payload: data.base64EncodedString(),
            seq: nextSeq()
        )
        let json = try JSONEncoder().encode(msg)
        try await webSocket?.send(.string(String(data: json, encoding: .utf8)!))
    }

    // MARK: - Private

    private func nextSeq() -> UInt64 {
        seq += 1
        return seq
    }

    /// Send a control message (announce / announce_ack) for peer discovery.
    private func sendControl(type: String) async throws {
        let control = ControlPayload(type: type, deviceId: deviceId, deviceName: localDeviceName)
        let payloadData = try JSONEncoder().encode(control)
        let msg = RelayMessage(
            from: deviceId,
            to: "",
            payload: payloadData.base64EncodedString(),
            seq: nextSeq()
        )
        let json = try JSONEncoder().encode(msg)
        try await webSocket?.send(.string(String(data: json, encoding: .utf8)!))
    }

    private func startReceiving() {
        webSocket?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.startReceiving()
            case .failure:
                self.isConnected = false
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        let raw: Data
        switch message {
        case .data(let d): raw = d
        case .string(let s): raw = Data(s.utf8)
        @unknown default: return
        }

        guard let msg = try? JSONDecoder().decode(RelayMessage.self, from: raw) else { return }
        guard msg.from != deviceId else { return } // ignore echoes (server should filter, but be safe)

        guard let payloadData = Data(base64Encoded: msg.payload) else { return }

        // Check if this is a control message (announce / announce_ack)
        if let control = try? JSONDecoder().decode(ControlPayload.self, from: payloadData),
           (control.type == "announce" || control.type == "announce_ack") {
            let displayName = control.deviceName?.isEmpty == false
                ? control.deviceName!
                : "Peer \(control.deviceId.prefix(6))"
            let peer = Peer(id: control.deviceId, name: displayName, channel: channelId)
            if !discoveredPeers.contains(peer) {
                discoveredPeers.append(peer)
                delegate?.channel(self, didDiscover: peer)
                delegate?.channel(self, didConnect: peer)
            }
            // Respond to announce with ack so the sender discovers us too
            if control.type == "announce" {
                Task { try? await sendControl(type: "announce_ack") }
            }
            return
        }

        // Regular data message — forward to MPC layer.
        // If we haven't discovered this peer yet, create a stub with a generic name;
        // a later announce_ack will re-discover it with the real device name.
        let peer = Peer(id: msg.from, name: "Peer \(msg.from.prefix(6))", channel: channelId)
        if !discoveredPeers.contains(peer) {
            discoveredPeers.append(peer)
            delegate?.channel(self, didDiscover: peer)
            delegate?.channel(self, didConnect: peer)
        }
        let transportMsg = TransportMessage(from: peer, data: payloadData, timestamp: .now)
        messageContinuation?.yield(transportMsg)
        delegate?.channel(self, didReceive: transportMsg)
    }
}

// MARK: - URLSessionWebSocketDelegate

extension RelayTransport: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        isConnected = true
        openContinuation?.resume()
        openContinuation = nil
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        isConnected = false
        discoveredPeers.removeAll()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error {
            openContinuation?.resume(throwing: error)
            openContinuation = nil
            isConnected = false
        }
    }
}

// MARK: - Wire Types

/// Matches the relay server's `RoomMessage` struct.
private struct RelayMessage: Codable {
    let from: String
    let to: String
    let payload: String
    let seq: UInt64
}

/// App-level control payload for peer discovery over the relay.
/// `deviceName` was added in protocol v2; optional so older clients still parse.
private struct ControlPayload: Codable {
    let type: String
    let deviceId: String
    let deviceName: String?
}
