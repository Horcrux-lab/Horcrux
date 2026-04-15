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
    private var noiseChannels: [String: HorcruxNoiseChannel] = []

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
        noiseKeypair = horcruxNoiseKeypairGenerate()
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

        // Initiate Noise handshake
        try await performNoiseHandshake(with: peer, asInitiator: true)
    }

    // MARK: - Sending (encrypted)

    /// Send MPC protocol data to a peer, encrypted via Noise.
    func sendMpcMessage(_ data: Data, to peer: Peer) async throws {
        guard let noise = noiseChannels[peer.id] else {
            throw TransportError.notConnected
        }

        let encrypted = try noise.encrypt(plaintext: [UInt8](data))
        let channel = channelForPeer(peer)
        try await channel.send(Data(encrypted), to: peer)
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
        // Merge discovered peers from all transports
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

        // Listen for incoming messages on all transports
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

        // If we have a Noise channel, decrypt
        if let noise = noiseChannels[peerId] {
            if let decrypted = try? noise.decrypt(ciphertext: [UInt8](message.data)) {
                mpcMessageContinuation?.yield((message.from, Data(decrypted)))
            }
        } else {
            // Could be a Noise handshake message — handle it
            Task {
                try? await handleHandshakeMessage(from: message.from, data: message.data)
            }
        }
    }

    private func performNoiseHandshake(with peer: Peer, asInitiator: Bool) async throws {
        guard let keypair = noiseKeypair else { return }

        let noise = HorcruxNoiseChannel.initiate(keypair: keypair)
        let msg1 = try noise.handshakeWrite(payload: [])

        let channel = channelForPeer(peer)
        try await channel.send(Data(msg1), to: peer)

        noiseChannels[peer.id] = noise
    }

    private func handleHandshakeMessage(from peer: Peer, data: Data) async throws {
        guard let keypair = noiseKeypair else { return }

        if noiseChannels[peer.id] == nil {
            // We're the responder
            let noise = HorcruxNoiseChannel.respond(keypair: keypair)
            let _ = try noise.handshakeRead(message: [UInt8](data))
            let msg2 = try noise.handshakeWrite(payload: [])

            let channel = channelForPeer(peer)
            try await channel.send(Data(msg2), to: peer)

            noiseChannels[peer.id] = noise
            connectedPeers.append(peer)
        } else {
            // We're the initiator reading msg2
            let noise = noiseChannels[peer.id]!
            let _ = try noise.handshakeRead(message: [UInt8](data))
            let msg3 = try noise.handshakeWrite(payload: [])

            let channel = channelForPeer(peer)
            try await channel.send(Data(msg3), to: peer)

            connectedPeers.append(peer)
        }
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
