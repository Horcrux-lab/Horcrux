import Foundation

/// WebSocket transport to the horcrux-relay server for remote DKG and signing.
/// All messages are E2E encrypted via Noise Protocol before sending.
final class RelayTransport: NSObject, TransportChannel, ObservableObject {
    let channelId = "relay"
    let channelName = "Relay Server"

    @Published private(set) var isConnected: Bool = false
    @Published private(set) var discoveredPeers: [Peer] = []
    @Published var relayURL: String = "ws://localhost:3000/ws"

    weak var delegate: TransportChannelDelegate?

    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession!
    private var roomId: String?
    private var deviceId: String = UUID().uuidString

    private var messageContinuation: AsyncStream<TransportMessage>.Continuation?
    lazy var incomingMessages: AsyncStream<TransportMessage> = {
        AsyncStream { continuation in
            self.messageContinuation = continuation
        }
    }()

    override init() {
        super.init()
        urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    }

    func startDiscovery() {
        // Relay doesn't "discover" — peers join the same room via shared code
    }

    func stopDiscovery() {}

    /// Join (or create) a relay room. The room code is shared out-of-band (QR, verbal).
    func joinRoom(roomId: String, token: String? = nil) async throws {
        self.roomId = roomId

        guard let url = URL(string: relayURL) else {
            throw TransportError.connectionFailed("Invalid relay URL")
        }

        webSocket = urlSession.webSocketTask(with: url)
        webSocket?.resume()

        // Send join message
        let joinMsg: [String: Any] = [
            "type": "join",
            "room_id": roomId,
            "device_id": deviceId,
            "token": token as Any
        ]
        let data = try JSONSerialization.data(withJSONObject: joinMsg)
        try await webSocket?.send(.data(data))

        isConnected = true
        startReceiving()
    }

    func connect(to peer: Peer) async throws {
        // In relay mode, connection is implicit via room membership
    }

    func disconnect(from peer: Peer) {
        webSocket?.cancel(with: .normalClosure, reason: nil)
        isConnected = false
    }

    func send(_ data: Data, to peer: Peer) async throws {
        guard let roomId else { throw TransportError.notConnected }

        let envelope: [String: Any] = [
            "type": "message",
            "room_id": roomId,
            "from": deviceId,
            "to": peer.id,
            "payload": data.base64EncodedString()
        ]
        let json = try JSONSerialization.data(withJSONObject: envelope)
        try await webSocket?.send(.data(json))
    }

    func broadcast(_ data: Data) async throws {
        guard let roomId else { throw TransportError.notConnected }

        let envelope: [String: Any] = [
            "type": "broadcast",
            "room_id": roomId,
            "from": deviceId,
            "payload": data.base64EncodedString()
        ]
        let json = try JSONSerialization.data(withJSONObject: envelope)
        try await webSocket?.send(.data(json))
    }

    // MARK: - Private

    private func startReceiving() {
        webSocket?.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.startReceiving() // Continue listening

            case .failure:
                self.isConnected = false
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .data(let d): data = d
        case .string(let s): data = Data(s.utf8)
        @unknown default: return
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let type = json["type"] as? String {
            switch type {
            case "peer_joined":
                if let peerId = json["device_id"] as? String {
                    let peer = Peer(id: peerId, name: "Remote Peer", channel: channelId)
                    if !discoveredPeers.contains(peer) {
                        discoveredPeers.append(peer)
                        delegate?.channel(self, didDiscover: peer)
                        delegate?.channel(self, didConnect: peer)
                    }
                }

            case "message", "broadcast":
                if let from = json["from"] as? String,
                   let payloadB64 = json["payload"] as? String,
                   let payload = Data(base64Encoded: payloadB64) {
                    let peer = Peer(id: from, name: "Remote Peer", channel: channelId)
                    let msg = TransportMessage(from: peer, data: payload, timestamp: .now)
                    messageContinuation?.yield(msg)
                    delegate?.channel(self, didReceive: msg)
                }

            case "peer_left":
                if let peerId = json["device_id"] as? String {
                    discoveredPeers.removeAll { $0.id == peerId }
                    let peer = Peer(id: peerId, name: "Remote Peer", channel: channelId)
                    delegate?.channel(self, didDisconnect: peer)
                }

            default:
                break
            }
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension RelayTransport: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        isConnected = true
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        isConnected = false
    }
}
