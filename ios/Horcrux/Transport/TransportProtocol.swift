import Foundation

/// Abstraction over different face-to-face and remote communication channels.
/// Each transport implements this protocol so the MPC layer doesn't care
/// whether messages travel over BLE, Wi-Fi, or WebSocket.
protocol TransportChannel: AnyObject {
    /// Unique identifier for this channel
    var channelId: String { get }

    /// Human-readable name (e.g., "BLE", "Wi-Fi LAN")
    var channelName: String { get }

    /// Whether the channel is currently connected to at least one peer
    var isConnected: Bool { get }

    /// Discovered peers available on this channel
    var discoveredPeers: [Peer] { get }

    /// Start scanning for nearby peers
    func startDiscovery()

    /// Stop scanning
    func stopDiscovery()

    /// Connect to a specific peer
    func connect(to peer: Peer) async throws

    /// Disconnect from a peer
    func disconnect(from peer: Peer)

    /// Send data to a specific peer
    func send(_ data: Data, to peer: Peer) async throws

    /// Broadcast data to all connected peers
    func broadcast(_ data: Data) async throws

    /// Stream of incoming messages
    var incomingMessages: AsyncStream<TransportMessage> { get }

    /// Delegate for state change callbacks
    var delegate: TransportChannelDelegate? { get set }
}

protocol TransportChannelDelegate: AnyObject {
    func channel(_ channel: TransportChannel, didDiscover peer: Peer)
    func channel(_ channel: TransportChannel, didConnect peer: Peer)
    func channel(_ channel: TransportChannel, didDisconnect peer: Peer)
    func channel(_ channel: TransportChannel, didReceive message: TransportMessage)
}

/// A discovered peer device
struct Peer: Identifiable, Hashable {
    let id: String
    let name: String
    let channel: String

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Peer, rhs: Peer) -> Bool {
        lhs.id == rhs.id
    }
}

/// An incoming message from a peer
struct TransportMessage {
    let from: Peer
    let data: Data
    let timestamp: Date
}
