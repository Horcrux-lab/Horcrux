import Foundation
import CoreBluetooth

/// BLE transport using CoreBluetooth for near-field device communication.
/// Acts as both central (scanner) and peripheral (advertiser) simultaneously.
final class BLETransport: NSObject, TransportChannel, ObservableObject {
    let channelId = "ble"
    let channelName = "Bluetooth"

    // Horcrux BLE service UUID
    static let serviceUUID = CBUUID(string: "7B3B4D64-0000-1000-8000-00805F9B34FB")
    static let characteristicUUID = CBUUID(string: "7B3B4D64-0001-1000-8000-00805F9B34FB")

    @Published private(set) var isConnected: Bool = false
    @Published private(set) var discoveredPeers: [Peer] = []

    weak var delegate: TransportChannelDelegate?

    private var centralManager: CBCentralManager!
    private var peripheralManager: CBPeripheralManager!
    private var connectedPeripherals: [String: CBPeripheral] = [:]
    private var messageCharacteristic: CBMutableCharacteristic?

    private var messageContinuation: AsyncStream<TransportMessage>.Continuation?
    lazy var incomingMessages: AsyncStream<TransportMessage> = {
        AsyncStream { continuation in
            self.messageContinuation = continuation
        }
    }()

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
        peripheralManager = CBPeripheralManager(delegate: self, queue: .main)
    }

    func startDiscovery() {
        guard centralManager.state == .poweredOn else { return }
        centralManager.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        startAdvertising()
    }

    func stopDiscovery() {
        centralManager.stopScan()
        peripheralManager.stopAdvertising()
    }

    func connect(to peer: Peer) async throws {
        guard let peripheral = connectedPeripherals[peer.id] ??
              discoveredPeers.first(where: { $0.id == peer.id })
                .flatMap({ _ in nil as CBPeripheral? }) else {
            throw TransportError.peerNotFound
        }
        centralManager.connect(peripheral, options: nil)
    }

    func disconnect(from peer: Peer) {
        if let peripheral = connectedPeripherals[peer.id] {
            centralManager.cancelPeripheralConnection(peripheral)
            connectedPeripherals.removeValue(forKey: peer.id)
        }
    }

    func send(_ data: Data, to peer: Peer) async throws {
        guard let peripheral = connectedPeripherals[peer.id] else {
            throw TransportError.notConnected
        }
        guard let characteristic = peripheral.services?
            .first(where: { $0.uuid == Self.serviceUUID })?
            .characteristics?
            .first(where: { $0.uuid == Self.characteristicUUID }) else {
            throw TransportError.characteristicNotFound
        }

        // Fragment large messages (BLE MTU is ~512 bytes)
        let chunks = data.chunked(into: 500)
        for chunk in chunks {
            peripheral.writeValue(chunk, for: characteristic, type: .withResponse)
        }
    }

    func broadcast(_ data: Data) async throws {
        for (_, peripheral) in connectedPeripherals {
            guard let characteristic = peripheral.services?
                .first(where: { $0.uuid == Self.serviceUUID })?
                .characteristics?
                .first(where: { $0.uuid == Self.characteristicUUID }) else { continue }
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
        }
    }

    private func startAdvertising() {
        let characteristic = CBMutableCharacteristic(
            type: Self.characteristicUUID,
            properties: [.read, .write, .notify],
            value: nil,
            permissions: [.readable, .writeable]
        )
        messageCharacteristic = characteristic

        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [characteristic]
        peripheralManager.add(service)

        peripheralManager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
            CBAdvertisementDataLocalNameKey: "Horcrux"
        ])
    }
}

// MARK: - CBCentralManagerDelegate

extension BLETransport: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            // Ready to scan
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "Unknown"
        let peer = Peer(id: peripheral.identifier.uuidString, name: name, channel: channelId)

        if !discoveredPeers.contains(peer) {
            discoveredPeers.append(peer)
            delegate?.channel(self, didDiscover: peer)
        }

        connectedPeripherals[peer.id] = peripheral
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID])
        isConnected = true

        let peer = Peer(
            id: peripheral.identifier.uuidString,
            name: peripheral.name ?? "Unknown",
            channel: channelId
        )
        delegate?.channel(self, didConnect: peer)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let peerId = peripheral.identifier.uuidString
        connectedPeripherals.removeValue(forKey: peerId)
        isConnected = !connectedPeripherals.isEmpty

        let peer = Peer(id: peerId, name: peripheral.name ?? "Unknown", channel: channelId)
        delegate?.channel(self, didDisconnect: peer)
    }
}

// MARK: - CBPeripheralDelegate

extension BLETransport: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else { return }
        peripheral.discoverCharacteristics([Self.characteristicUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristic = service.characteristics?
            .first(where: { $0.uuid == Self.characteristicUUID }) else { return }
        peripheral.setNotifyValue(true, for: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        let peer = Peer(
            id: peripheral.identifier.uuidString,
            name: peripheral.name ?? "Unknown",
            channel: channelId
        )
        let msg = TransportMessage(from: peer, data: data, timestamp: .now)
        messageContinuation?.yield(msg)
        delegate?.channel(self, didReceive: msg)
    }
}

// MARK: - CBPeripheralManagerDelegate

extension BLETransport: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state == .poweredOn {
            // Ready to advertise
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            if let data = request.value {
                let peer = Peer(
                    id: request.central.identifier.uuidString,
                    name: "Peer",
                    channel: channelId
                )
                let msg = TransportMessage(from: peer, data: data, timestamp: .now)
                messageContinuation?.yield(msg)
                delegate?.channel(self, didReceive: msg)
            }
            peripheral.respond(to: request, withResult: .success)
        }
    }
}

// MARK: - Helpers

enum TransportError: LocalizedError {
    case peerNotFound
    case notConnected
    case characteristicNotFound
    case connectionFailed(String)
    case sendFailed(String)

    var errorDescription: String? {
        switch self {
        case .peerNotFound: return "Peer not found"
        case .notConnected: return "Not connected to peer"
        case .characteristicNotFound: return "BLE characteristic not found"
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .sendFailed(let msg): return "Send failed: \(msg)"
        }
    }
}

extension Data {
    func chunked(into size: Int) -> [Data] {
        stride(from: 0, to: count, by: size).map { offset in
            let end = Swift.min(offset + size, count)
            return self[offset..<end]
        }
    }
}
