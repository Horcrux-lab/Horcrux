import Foundation
import Combine

/// Coordinates multiple transport channels and the Noise E2E encryption layer.
/// The MPC layer talks only to PeerManager — it doesn't know which transport is in use.
@MainActor
final class PeerManager: ObservableObject {
    // Available transports
    let ble = BLETransport()
    let wifiDirect = WiFiDirectTransport()
    let wifiLAN = WiFiLANTransport()
    let relay = RelayTransport()
    let qr = QRTransport()

    /// All discovered peers across all transports
    @Published var allPeers: [Peer] = []

    /// Connected peers with established E2E channels
    @Published var connectedPeers: [Peer] = []

    /// Active Noise channels keyed by peer ID
    private var noiseChannels: [String: HorcruxNoiseChannel] = [:]

    /// Our Noise static keypair (persisted identity)
    private(set) var noiseKeypair: FfiNoiseKeypair?

    /// Incoming decrypted MPC messages
    private var mpcMessageContinuation: AsyncStream<(Peer, Data)>.Continuation?
    lazy var incomingMpcMessages: AsyncStream<(Peer, Data)> = {
        AsyncStream { continuation in
            self.mpcMessageContinuation = continuation
        }
    }()

    private var cancellables = Set<AnyCancellable>()

    init() {
        noiseKeypair = horcruxGenerateNoiseKeypair()
        setupTransportObservers()
    }

    // MARK: - Discovery

    func startDiscovery(transports: Set<TransportType> = [.ble, .wifiLAN]) {
        if transports.contains(.ble) { ble.startDiscovery() }
        if transports.contains(.wifiDirect) { wifiDirect.startDiscovery() }
        if transports.contains(.wifiLAN) { wifiLAN.startDiscovery() }
    }

    func stopDiscovery() {
        ble.stopDiscovery()
        wifiDirect.stopDiscovery()
        wifiLAN.stopDiscovery()
    }

    // MARK: - Connection

    func connect(to peer: Peer) async throws {
        let channel = channelForPeer(peer)
        try await channel.connect(to: peer)

        try await performNoiseHandshake(with: peer, asInitiator: true)
    }

    // MARK: - Sending (encrypted)

    /// Send MPC protocol data to a peer, encrypted via Noise.
    func sendMpcMessage(_ data: Data, to peer: Peer) async throws {
        guard let noise = noiseChannels[peer.id] else {
            throw TransportError.notConnected
        }

        let envelope = try noise.seal(plaintext: data)
        let encoded = try JSONEncoder().encode(EnvelopeDTO(envelope))
        let channel = channelForPeer(peer)
        try await channel.send(encoded, to: peer)
    }

    /// Broadcast MPC data to all connected peers.
    func broadcastMpcMessage(_ data: Data) async throws {
        for peer in connectedPeers {
            try await sendMpcMessage(data, to: peer)
        }
    }

    // MARK: - Relay Room

    func joinRelayRoom(roomId: String, token: String? = nil) async throws {
        try await relay.joinRoom(roomId: roomId, token: token)
    }

    // MARK: - Private

    private func channelForPeer(_ peer: Peer) -> TransportChannel {
        switch peer.channel {
        case "ble": return ble
        case "wifi-direct": return wifiDirect
        case "wifi-lan": return wifiLAN
        case "relay": return relay
        default: return ble
        }
    }

    private func setupTransportObservers() {
        let blePublisher = ble.$discoveredPeers
        let wifiDirectPublisher = wifiDirect.$discoveredPeers
        let wifiLANPublisher = wifiLAN.$discoveredPeers
        let relayPublisher = relay.$discoveredPeers

        Publishers.CombineLatest4(blePublisher, wifiDirectPublisher, wifiLANPublisher, relayPublisher)
            .map { ble, wifiDirect, wifiLAN, relay in
                var all: [Peer] = []
                all.append(contentsOf: ble)
                all.append(contentsOf: wifiDirect)
                all.append(contentsOf: wifiLAN)
                all.append(contentsOf: relay)
                return all
            }
            .assign(to: &$allPeers)

        Task { await listenForMessages(from: ble) }
        Task { await listenForMessages(from: wifiDirect) }
        Task { await listenForMessages(from: wifiLAN) }
        Task { await listenForMessages(from: relay) }
    }

    private func listenForMessages(from transport: TransportChannel) async {
        for await message in transport.incomingMessages {
            handleIncomingMessage(message)
        }
    }

    private func handleIncomingMessage(_ message: TransportMessage) {
        let peerId = message.from.id

        if let noise = noiseChannels[peerId] {
            if let dto = try? JSONDecoder().decode(EnvelopeDTO.self, from: message.data) {
                let envelope = FfiSealedEnvelope(ciphertext: dto.ciphertext, handshake: dto.handshake)
                if let decrypted = try? noise.open(envelope: envelope) {
                    mpcMessageContinuation?.yield((message.from, decrypted))
                }
            }
        } else {
            Task {
                try? await handleHandshakeMessage(from: message.from, data: message.data)
            }
        }
    }

    private func performNoiseHandshake(with peer: Peer, asInitiator: Bool) async throws {
        guard let keypair = noiseKeypair else { return }

        let noise = try HorcruxNoiseChannel.newInitiator(keypair: keypair)
        let msg1 = try noise.writeHandshake(payload: Data())

        let channel = channelForPeer(peer)
        try await channel.send(msg1, to: peer)

        noiseChannels[peer.id] = noise
    }

    private func handleHandshakeMessage(from peer: Peer, data: Data) async throws {
        guard let keypair = noiseKeypair else { return }

        if noiseChannels[peer.id] == nil {
            let noise = try HorcruxNoiseChannel.newResponder(keypair: keypair)
            let _ = try noise.readHandshake(message: data)
            let msg2 = try noise.writeHandshake(payload: Data())

            let channel = channelForPeer(peer)
            try await channel.send(msg2, to: peer)

            noiseChannels[peer.id] = noise
            connectedPeers.append(peer)
        } else {
            let noise = noiseChannels[peer.id]!
            let _ = try noise.readHandshake(message: data)

            if !noise.isHandshakeFinished() {
                let msg3 = try noise.writeHandshake(payload: Data())
                let channel = channelForPeer(peer)
                try await channel.send(msg3, to: peer)
            }

            connectedPeers.append(peer)
        }
    }
}

/// Codable DTO for serializing FfiSealedEnvelope across transports.
private struct EnvelopeDTO: Codable {
    let ciphertext: Data
    let handshake: Bool

    init(_ envelope: FfiSealedEnvelope) {
        self.ciphertext = envelope.ciphertext
        self.handshake = envelope.handshake
    }
}

enum TransportType: String, CaseIterable, Identifiable {
    case ble = "Bluetooth"
    case wifiDirect = "Wi-Fi Direct"
    case wifiLAN = "Wi-Fi LAN"
    case relay = "Relay Server"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .ble: return "wave.3.right"
        case .wifiDirect: return "wifi"
        case .wifiLAN: return "network"
        case .relay: return "cloud"
        }
    }
}
