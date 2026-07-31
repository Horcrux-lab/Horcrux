import Foundation
import MultipeerConnectivity

/// Wi-Fi Direct (P2P) transport using MultipeerConnectivity framework.
/// Works without a Wi-Fi router — creates an ad-hoc peer-to-peer connection.
final class WiFiDirectTransport: NSObject, TransportChannel, ObservableObject {
    let channelId = "wifi-direct"
    let channelName = "Wi-Fi Direct"

    static let serviceType = "horcrux-mpc"

    @Published private(set) var isConnected: Bool = false
    @Published private(set) var discoveredPeers: [Peer] = []

    weak var delegate: TransportChannelDelegate?

    private let myPeerId: MCPeerID

    private var messageContinuation: AsyncStream<TransportMessage>.Continuation?
    let incomingMessages: AsyncStream<TransportMessage>

    /// Last-resort display name. `MCPeerID` will not accept an empty string,
    /// so there has to be something to fall back to.
    static let fallbackPeerName = "Horcrux"

    /// Maximum `MCPeerID` display name length, in UTF-8 bytes, per its
    /// documented contract.
    static let maxPeerNameBytes = 63

    /// `MCPeerID(displayName:)` raises an Objective-C exception — not a Swift
    /// error, so `try?` cannot contain it — for any name that is empty or
    /// longer than 63 UTF-8 bytes. It is constructed from
    /// `ProcessInfo.processInfo.hostName` inside `PeerManager.init`, which
    /// runs inside `AppState.init`, which is a `@StateObject` initialiser in
    /// `HorcruxApp` — so a bad name aborts the process before the first
    /// frame, with no code path able to catch it.
    ///
    /// Both bounds are reachable in practice. `hostName` is empty on a
    /// simulator with no configured hostname (this is how CI found it: the
    /// app aborted in `-[MCPeerID initWithDisplayName:]` before a single test
    /// could attach). At the other end, 63 *bytes* is not 63 characters — 16
    /// emoji or 21 CJK characters exceed it, and users name their phones that.
    static func sanitizedPeerName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallbackPeerName }
        guard trimmed.utf8.count > maxPeerNameBytes else { return trimmed }

        // Truncate on grapheme boundaries: cutting at byte 63 could split a
        // multi-byte scalar and produce a string MCPeerID also rejects.
        var truncated = ""
        for character in trimmed {
            if truncated.utf8.count + String(character).utf8.count > maxPeerNameBytes {
                break
            }
            truncated.append(character)
        }
        // A single grapheme cluster can be longer than the whole budget.
        return truncated.isEmpty ? fallbackPeerName : truncated
    }

    init(peerName: String = ProcessInfo.processInfo.hostName) {
        let (stream, continuation) = AsyncStream<TransportMessage>.makeStream()
        self.incomingMessages = stream
        self.messageContinuation = continuation
        self.myPeerId = MCPeerID(displayName: Self.sanitizedPeerName(peerName))
        super.init()
        setupSession()
    }
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var peerIdMap: [String: MCPeerID] = [:]

    func setupSession() {
        session = MCSession(peer: myPeerId, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
    }

    func startDiscovery() {
        // Advertise ourselves
        advertiser = MCNearbyServiceAdvertiser(
            peer: myPeerId,
            discoveryInfo: nil,
            serviceType: Self.serviceType
        )
        advertiser?.delegate = self
        advertiser?.startAdvertisingPeer()

        // Browse for others
        browser = MCNearbyServiceBrowser(peer: myPeerId, serviceType: Self.serviceType)
        browser?.delegate = self
        browser?.startBrowsingForPeers()
    }

    func stopDiscovery() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
    }

    func connect(to peer: Peer) async throws {
        guard let mcPeer = peerIdMap[peer.id] else {
            throw TransportError.peerNotFound
        }
        browser?.invitePeer(mcPeer, to: session, withContext: nil, timeout: 30)
    }

    func disconnect(from peer: Peer) {
        session.disconnect()
        isConnected = false
    }

    func send(_ data: Data, to peer: Peer) async throws {
        guard let mcPeer = peerIdMap[peer.id] else {
            throw TransportError.notConnected
        }
        try session.send(data, toPeers: [mcPeer], with: .reliable)
    }

    func broadcast(_ data: Data) async throws {
        guard !session.connectedPeers.isEmpty else { return }
        try session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }
}

// MARK: - MCSessionDelegate

extension WiFiDirectTransport: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let peer = Peer(id: peerID.displayName, name: peerID.displayName, channel: self.channelId)

            switch state {
            case .connected:
                self.isConnected = true
                self.delegate?.channel(self, didConnect: peer)
            case .notConnected:
                self.isConnected = !session.connectedPeers.isEmpty
                self.delegate?.channel(self, didDisconnect: peer)
            case .connecting:
                break
            @unknown default:
                break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        let peer = Peer(id: peerID.displayName, name: peerID.displayName, channel: channelId)
        let msg = TransportMessage(from: peer, data: data, timestamp: .now)
        messageContinuation?.yield(msg)
        delegate?.channel(self, didReceive: msg)
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName: String, fromPeer: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName: String, fromPeer: MCPeerID, with: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName: String, fromPeer: MCPeerID, at: URL?, withError: Error?) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension WiFiDirectTransport: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                    didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?,
                    invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Auto-accept invitations (Noise handshake provides authentication)
        invitationHandler(true, session)
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension WiFiDirectTransport: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        let peer = Peer(id: peerID.displayName, name: peerID.displayName, channel: channelId)
        peerIdMap[peer.id] = peerID

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !self.discoveredPeers.contains(peer) {
                self.discoveredPeers.append(peer)
                self.delegate?.channel(self, didDiscover: peer)
            }
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async { [weak self] in
            self?.discoveredPeers.removeAll { $0.id == peerID.displayName }
        }
    }
}
