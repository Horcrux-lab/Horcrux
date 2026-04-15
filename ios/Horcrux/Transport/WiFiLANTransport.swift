import Foundation
import Network

/// Wi-Fi LAN transport using Network.framework + Bonjour discovery.
/// Discovers peers on the same local network via mDNS (_horcrux._tcp).
final class WiFiLANTransport: NSObject, TransportChannel, ObservableObject {
    let channelId = "wifi-lan"
    let channelName = "Wi-Fi LAN"

    static let bonjourType = "_horcrux._tcp"

    @Published private(set) var isConnected: Bool = false
    @Published private(set) var discoveredPeers: [Peer] = []

    weak var delegate: TransportChannelDelegate?

    private var browser: NWBrowser?
    private var listener: NWListener?
    private var connections: [String: NWConnection] = [:]

    private var messageContinuation: AsyncStream<TransportMessage>.Continuation?
    lazy var incomingMessages: AsyncStream<TransportMessage> = {
        AsyncStream { continuation in
            self.messageContinuation = continuation
        }
    }()

    func startDiscovery() {
        startListener()
        startBrowsing()
    }

    func stopDiscovery() {
        browser?.cancel()
        browser = nil
        listener?.cancel()
        listener = nil
    }

    func connect(to peer: Peer) async throws {
        guard let endpoint = peerEndpoints[peer.id] else {
            throw TransportError.peerNotFound
        }
        let params = NWParameters.tcp
        params.includePeerToPeer = true

        let connection = NWConnection(to: endpoint, using: params)
        connections[peer.id] = connection

        return try await withCheckedThrowingContinuation { continuation in
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.isConnected = true
                    self?.delegate?.channel(self!, didConnect: peer)
                    self?.receiveLoop(connection: connection, peer: peer)
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: TransportError.connectionFailed(error.localizedDescription))
                default:
                    break
                }
            }
            connection.start(queue: .main)
        }
    }

    func disconnect(from peer: Peer) {
        connections[peer.id]?.cancel()
        connections.removeValue(forKey: peer.id)
        isConnected = !connections.isEmpty
    }

    func send(_ data: Data, to peer: Peer) async throws {
        guard let connection = connections[peer.id] else {
            throw TransportError.notConnected
        }
        // Length-prefixed framing: 4 bytes (big-endian UInt32) + payload
        var length = UInt32(data.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(data)

        return try await withCheckedThrowingContinuation { continuation in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: TransportError.sendFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func broadcast(_ data: Data) async throws {
        for peerId in connections.keys {
            let peer = Peer(id: peerId, name: peerId, channel: channelId)
            try await send(data, to: peer)
        }
    }

    // MARK: - Private

    private var peerEndpoints: [String: NWEndpoint] = [:]

    private func startListener() {
        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = true

            listener = try NWListener(using: params)
            listener?.service = NWListener.Service(
                name: UIDevice.current.name,
                type: Self.bonjourType
            )

            listener?.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                let peerId = connection.endpoint.debugDescription
                let peer = Peer(id: peerId, name: "LAN Peer", channel: self.channelId)
                self.connections[peerId] = connection

                connection.stateUpdateHandler = { state in
                    if case .ready = state {
                        self.isConnected = true
                        self.delegate?.channel(self, didConnect: peer)
                        self.receiveLoop(connection: connection, peer: peer)
                    }
                }
                connection.start(queue: .main)
            }

            listener?.start(queue: .main)
        } catch {
            print("WiFi LAN listener failed: \(error)")
        }
    }

    private func startBrowsing() {
        let params = NWParameters()
        params.includePeerToPeer = true

        browser = NWBrowser(for: .bonjour(type: Self.bonjourType, domain: nil), using: params)

        browser?.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            for result in results {
                let peerId = result.endpoint.debugDescription
                let name: String
                if case .service(let n, _, _, _) = result.endpoint {
                    name = n
                } else {
                    name = peerId
                }
                let peer = Peer(id: peerId, name: name, channel: self.channelId)

                if !self.discoveredPeers.contains(peer) {
                    self.peerEndpoints[peerId] = result.endpoint
                    self.discoveredPeers.append(peer)
                    self.delegate?.channel(self, didDiscover: peer)
                }
            }
        }

        browser?.start(queue: .main)
    }

    private func receiveLoop(connection: NWConnection, peer: Peer) {
        // Read 4-byte length header
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, _, error in
            guard let self, let header, error == nil else { return }

            let length = header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

            // Read payload
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { payload, _, _, error in
                guard let payload, error == nil else { return }

                let msg = TransportMessage(from: peer, data: payload, timestamp: .now)
                self.messageContinuation?.yield(msg)
                self.delegate?.channel(self, didReceive: msg)

                // Continue reading
                self.receiveLoop(connection: connection, peer: peer)
            }
        }
    }
}
