import Foundation
import Combine
import os

private let peerLog = Logger(subsystem: "com.horcrux.wallet", category: "PeerManager")

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

    /// Incoming decrypted MPC messages (eagerly initialized to avoid race)
    private var mpcMessageContinuation: AsyncStream<(Peer, Data)>.Continuation?
    let incomingMpcMessages: AsyncStream<(Peer, Data)>

    private var cancellables = Set<AnyCancellable>()
    private let keychain = KeychainManager.shared
    private static let noiseKeypairKey = "noise_static_keypair"
    private static let noiseKeypairSEKey = "noise_static_keypair_se"

    init() {
        let (stream, continuation) = AsyncStream<(Peer, Data)>.makeStream()
        self.incomingMpcMessages = stream
        self.mpcMessageContinuation = continuation
        noiseKeypair = Self.loadOrGenerateNoiseKeypair(keychain: keychain)
        setupTransportObservers()
    }

    /// Load persisted Noise keypair from Keychain, or generate and store a new one.
    /// On SE-capable devices, the keypair is sealed under the Secure Enclave.
    private static func loadOrGenerateNoiseKeypair(keychain: KeychainManager) -> FfiNoiseKeypair? {
        let se = SecureEnclaveManager.shared

        // SE path: try loading SE-sealed keypair
        if se.isAvailable {
            if let sealed = try? keychain.retrieve(key: noiseKeypairSEKey) {
                do {
                    let plaintext = try se.open(sealed)
                    let dto = try JSONDecoder().decode(NoiseKeypairDTO.self, from: plaintext)
                    return FfiNoiseKeypair(privateKey: dto.privateKey, publicKey: dto.publicKey)
                } catch {
                    SecureLog.error("Failed to unseal/decode noise keypair: \(error.localizedDescription)")
                }
            }

            // Migrate legacy unprotected keypair → SE-sealed
            if let legacy = try? keychain.retrieve(key: noiseKeypairKey) {
                do {
                    let dto = try JSONDecoder().decode(NoiseKeypairDTO.self, from: legacy)
                    do {
                        let sealed = try se.seal(legacy)
                        do {
                            try keychain.storeSecure(key: noiseKeypairSEKey, data: sealed)
                        } catch {
                            SecureLog.error("Failed to store SE-sealed noise keypair: \(error.localizedDescription)")
                        }
                        try? keychain.delete(key: noiseKeypairKey)
                    } catch {
                        SecureLog.error("Failed to seal legacy noise keypair: \(error.localizedDescription)")
                    }
                    return FfiNoiseKeypair(privateKey: dto.privateKey, publicKey: dto.publicKey)
                } catch {
                    SecureLog.error("Failed to decode legacy noise keypair: \(error.localizedDescription)")
                }
            }

            // Generate new, seal, store
            guard let keypair = try? horcruxGenerateNoiseKeypair() else {
                SecureLog.error("Failed to generate noise keypair")
                return nil
            }
            let dto = NoiseKeypairDTO(privateKey: keypair.privateKey, publicKey: keypair.publicKey)
            do {
                let encoded = try JSONEncoder().encode(dto)
                do {
                    let sealed = try se.seal(encoded)
                    do {
                        try keychain.storeSecure(key: noiseKeypairSEKey, data: sealed)
                    } catch {
                        SecureLog.error("Failed to store SE-sealed noise keypair: \(error.localizedDescription)")
                    }
                } catch {
                    SecureLog.error("Failed to seal new noise keypair: \(error.localizedDescription)")
                }
            } catch {
                SecureLog.error("Failed to encode noise keypair: \(error.localizedDescription)")
            }
            return keypair
        }

        // Non-SE fallback: software Keychain
        if let data = try? keychain.retrieve(key: noiseKeypairKey) {
            do {
                let dto = try JSONDecoder().decode(NoiseKeypairDTO.self, from: data)
                return FfiNoiseKeypair(privateKey: dto.privateKey, publicKey: dto.publicKey)
            } catch {
                SecureLog.error("Failed to decode noise keypair: \(error.localizedDescription)")
            }
        }
        guard let keypair = try? horcruxGenerateNoiseKeypair() else {
            SecureLog.error("Failed to generate noise keypair")
            return nil
        }
        let dto = NoiseKeypairDTO(privateKey: keypair.privateKey, publicKey: keypair.publicKey)
        do {
            let encoded = try JSONEncoder().encode(dto)
            do {
                try keychain.store(key: noiseKeypairKey, data: encoded)
            } catch {
                SecureLog.error("Failed to store noise keypair: \(error.localizedDescription)")
            }
        } catch {
            SecureLog.error("Failed to encode noise keypair: \(error.localizedDescription)")
        }
        return keypair
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
    /// For relay/wifi-lan peers without a Noise channel, sends raw data (trusted local transport).
    func sendMpcMessage(_ data: Data, to peer: Peer) async throws {
        if let noise = noiseChannels[peer.id] {
            // Encrypted path: Pad → Encrypt → Send
            let padded = MessagePadding.pad(data)
            let envelope = try noise.seal(plaintext: padded)
            let encoded = try JSONEncoder().encode(EnvelopeDTO(envelope))
            await MessagePadding.randomJitter()
            let channel = channelForPeer(peer)
            try await channel.send(encoded, to: peer)
        } else if peer.channel == "relay" || peer.channel == "wifi-lan" {
            // Local transport path: send raw MPC data (no Noise encryption needed)
            let channel = channelForPeer(peer)
            try await channel.send(data, to: peer)
        } else {
            throw TransportError.notConnected
        }
    }

    /// Broadcast MPC data to all connected peers, with retry on failure.
    func broadcastMpcMessage(_ data: Data) async throws {
        let targets = connectedPeers.isEmpty ? allPeers : connectedPeers
        for peer in targets {
            try await MpcRetryPolicy.withRetry {
                try await self.sendMpcMessage(data, to: peer)
            }
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
            NSLog("[PM] listenForMessages got msg from \(message.from.id.prefix(8)), channel=\(message.from.channel), \(message.data.count)B")
            handleIncomingMessage(message)
        }
    }

    private func handleIncomingMessage(_ message: TransportMessage) {
        let peerId = message.from.id

        if let noise = noiseChannels[peerId] {
            NSLog("[PM] handleIncoming: noise path for \(peerId.prefix(8))")
            // Encrypted path: Decrypt → Unpad → Yield
            do {
                let dto = try JSONDecoder().decode(EnvelopeDTO.self, from: message.data)
                let envelope = FfiSealedEnvelope(ciphertext: dto.ciphertext, handshake: dto.handshake)
                do {
                    let decryptedPadded = try noise.open(envelope: envelope)
                    if let decrypted = MessagePadding.unpad(decryptedPadded) {
                        mpcMessageContinuation?.yield((message.from, decrypted))
                    }
                } catch {
                    SecureLog.error("Failed to decrypt message from peer \(peerId): \(error.localizedDescription)")
                }
            } catch {
                SecureLog.error("Failed to decode envelope from peer \(peerId): \(error.localizedDescription)")
            }
        } else if message.from.channel == "relay" || message.from.channel == "wifi-lan" {
            // Local transport path: raw MPC data, no noise encryption
            NSLog("[PM] handleIncoming: \(message.from.channel) path → yielding \(message.data.count)B to mpcStream")
            mpcMessageContinuation?.yield((message.from, message.data))
        } else {
            NSLog("[PM] handleIncoming: unknown peer \(peerId.prefix(8)), trying handshake")
            // Unknown peer without noise channel — try handshake
            Task {
                do {
                    try await handleHandshakeMessage(from: message.from, data: message.data)
                } catch {
                    SecureLog.error("Handshake failed with peer \(message.from.id): \(error.localizedDescription)")
                }
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

/// Codable DTO for persisting the Noise static keypair.
private struct NoiseKeypairDTO: Codable {
    let privateKey: Data
    let publicKey: Data
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
