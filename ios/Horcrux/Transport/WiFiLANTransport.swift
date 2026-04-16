import Foundation
import Network
import UIKit

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
    /// Our own Bonjour service name, used to filter self-discovery
    private let ownServiceName = UIDevice.current.name

    private var messageContinuation: AsyncStream<TransportMessage>.Continuation?
    let incomingMessages: AsyncStream<TransportMessage>

    override init() {
        let (stream, continuation) = AsyncStream<TransportMessage>.makeStream()
        self.incomingMessages = stream
        self.messageContinuation = continuation
        super.init()
    }

    deinit {
        browser?.cancel()
        listener?.cancel()
        for (_, conn) in connections { conn.cancel() }
    }

    func startDiscovery() {
        // Clean slate: cancel any existing listener/browser and clear stale peers
        teardown()
        discoveredPeers.removeAll()
        peerEndpoints.removeAll()
        NSLog("[WiFi-LAN] Starting discovery (listener + browser)")
        startListener()
        startBrowsing()
    }

    func stopDiscovery() {
        // Only stop browsing/advertising — keep listener + connections alive for message passing
        browser?.cancel()
        browser = nil
    }

    func teardown() {
        browser?.cancel()
        browser = nil
        listener?.cancel()
        listener = nil
        for (_, conn) in connections {
            conn.cancel()
        }
        connections.removeAll()
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

            listener?.stateUpdateHandler = { state in
                NSLog("[WiFi-LAN] Listener state: \(state)")
            }

            listener?.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                let endpointId = connection.endpoint.debugDescription
                NSLog("[WiFi-LAN] New incoming connection from: \(endpointId)")

                // Accept the connection for receiving messages, but map to a
                // placeholder peer. The outbound connection (from auto-connect)
                // is used for sending. This avoids inflating the peer count.
                let inboundPeer = Peer(id: "inbound-\(endpointId)", name: "LAN Peer", channel: self.channelId)

                connection.stateUpdateHandler = { state in
                    if case .ready = state {
                        NSLog("[WiFi-LAN] Incoming connection ready: \(endpointId)")
                        self.receiveLoop(connection: connection, peer: inboundPeer)
                    } else if case .failed(let err) = state {
                        NSLog("[WiFi-LAN] Incoming connection failed: \(err)")
                    }
                }
                connection.start(queue: .main)
            }

            listener?.start(queue: .main)
            NSLog("[WiFi-LAN] Listener started, service name=\(UIDevice.current.name) type=\(Self.bonjourType)")
        } catch {
            NSLog("[WiFi-LAN] Listener failed: \(error)")
        }
    }

    private func startBrowsing() {
        let params = NWParameters()
        params.includePeerToPeer = true

        browser = NWBrowser(for: .bonjour(type: Self.bonjourType, domain: nil), using: params)

        browser?.stateUpdateHandler = { state in
            NSLog("[WiFi-LAN] Browser state: \(state)")
        }

        browser?.browseResultsChangedHandler = { [weak self] results, changes in
            guard let self else { return }
            NSLog("[WiFi-LAN] Browse results changed: \(results.count) results")
            for result in results {
                let peerId = result.endpoint.debugDescription
                let name: String
                if case .service(let n, _, _, _) = result.endpoint {
                    name = n
                } else {
                    name = peerId
                }

                // Filter out self-discovery and stale duplicate services
                // macOS appends "(2)", "(3)" etc. for services from crashed processes
                if name == self.ownServiceName || name.hasPrefix(self.ownServiceName + " (") {
                    NSLog("[WiFi-LAN] Skipping self/stale: \(name)")
                    continue
                }
                // Filter stale duplicates of remote peers (e.g. "iPhone 16 (2)")
                if let range = name.range(of: #" \(\d+\)$"#, options: .regularExpression) {
                    let baseName = String(name[name.startIndex..<range.lowerBound])
                    NSLog("[WiFi-LAN] Skipping stale duplicate: \(name) (base=\(baseName))")
                    continue
                }

                NSLog("[WiFi-LAN] Found peer: id=\(peerId) name=\(name)")
                let peer = Peer(id: peerId, name: name, channel: self.channelId)

                if !self.discoveredPeers.contains(peer) {
                    self.peerEndpoints[peerId] = result.endpoint
                    self.discoveredPeers.append(peer)
                    self.delegate?.channel(self, didDiscover: peer)
                    NSLog("[WiFi-LAN] New peer discovered: \(name) (\(peerId))")

                    // Auto-connect to discovered peer
                    Task { [weak self] in
                        guard let self else { return }
                        do {
                            try await self.connect(to: peer)
                            NSLog("[WiFi-LAN] Auto-connected to \(name)")
                        } catch {
                            NSLog("[WiFi-LAN] Auto-connect failed to \(name): \(error)")
                        }
                    }
                }
            }
        }

        browser?.start(queue: .main)
        NSLog("[WiFi-LAN] Browser started for \(Self.bonjourType)")
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
