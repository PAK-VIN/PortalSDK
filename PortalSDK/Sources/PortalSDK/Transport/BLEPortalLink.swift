import CoreBluetooth
import Foundation

public final class BLEPortalLink: NSObject, PortalLink, @unchecked Sendable {
    public static let serviceUUID = CBUUID(string: "533E1530-3ABE-F33F-CD00-594E8B0A8EA3")
    public static let notifyUUID  = CBUUID(string: "533E1542-3ABE-F33F-CD00-594E8B0A8EA3")  // read + notify
    public static let writeUUID   = CBUUID(string: "533E1543-3ABE-F33F-CD00-594E8B0A8EA3")  // write (with response)
    private static let savedIdentifierKey = "PortalSDK.lastPortalIdentifier"

    public let frames: AsyncStream<Data>
    public let states: AsyncStream<LinkState>

    private let frameContinuation: AsyncStream<Data>.Continuation
    private let stateContinuation: AsyncStream<LinkState>.Continuation
    private let queue = DispatchQueue(label: "PortalSDK.BLEPortalLink")
    private let defaults: UserDefaults

    // Everything below is only touched on `queue`.
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var pendingWrite: CheckedContinuation<Void, Error>?
    private var writeToken = 0
    private var wantsConnection = false

    public init(defaults: UserDefaults = .standard) {
        let frameStream = AsyncStream<Data>.makeStream()
        let stateStream = AsyncStream<LinkState>.makeStream()
        frames = frameStream.stream
        frameContinuation = frameStream.continuation
        states = stateStream.stream
        stateContinuation = stateStream.continuation
        self.defaults = defaults
        super.init()
    }

    // MARK: PortalLink

    public func connect() {
        queue.async { [self] in
            wantsConnection = true
            if central == nil {
                // Created lazily so the Bluetooth permission prompt appears when the app starts using the portal.
                central = CBCentralManager(delegate: self, queue: queue)
            } else {
                startIfPossible()
            }
        }
    }

    public func disconnect() {
        queue.async { [self] in
            wantsConnection = false
            central?.stopScan()
            if let peripheral { central?.cancelPeripheralConnection(peripheral) }
            writeCharacteristic = nil
            failPendingWrite(PortalError.notConnected)
            emit(.idle)
        }
    }

    public func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard let peripheral, let characteristic = writeCharacteristic, peripheral.state == .connected else {
                    continuation.resume(throwing: PortalError.notConnected)
                    return
                }
                guard pendingWrite == nil else {
                    continuation.resume(throwing: PortalError.busy)
                    return
                }
                writeToken += 1
                let token = writeToken
                pendingWrite = continuation
                peripheral.writeValue(data, for: characteristic, type: .withResponse)

                // Safety net: never leave a write hanging forever.
                queue.asyncAfter(deadline: .now() + 2) { [self] in
                    if writeToken == token, let pending = pendingWrite {
                        pendingWrite = nil
                        pending.resume(throwing: PortalError.timeout)
                    }
                }
            }
        }
    }

    // MARK: Connection management (queue only)

    private func startIfPossible() {
        guard wantsConnection, let central, central.state == .poweredOn else { return }
        if let peripheral, peripheral.state == .connected || peripheral.state == .connecting { return }

        if let known = central.retrieveConnectedPeripherals(withServices: [Self.serviceUUID]).first {
            adopt(known)
            return
        }
        if let text = defaults.string(forKey: Self.savedIdentifierKey),
           let id = UUID(uuidString: text),
           let remembered = central.retrievePeripherals(withIdentifiers: [id]).first {
            adopt(remembered)
            return
        }
        emit(.scanning)
        central.scanForPeripherals(withServices: nil)
    }

    private func adopt(_ candidate: CBPeripheral) {
        central?.stopScan()
        peripheral = candidate
        candidate.delegate = self
        emit(.connecting)
        central?.connect(candidate)
    }

    private func scheduleReconnect() {
        guard wantsConnection else { return }
        queue.asyncAfter(deadline: .now() + 1) { [self] in startIfPossible() }
    }

    private func handleLoss(_ state: LinkState) {
        writeCharacteristic = nil
        failPendingWrite(PortalError.bluetoothUnavailable)
        emit(state)
    }

    private func failPendingWrite(_ error: Error) {
        guard let pending = pendingWrite else { return }
        pendingWrite = nil
        pending.resume(throwing: error)
    }

    private func emit(_ state: LinkState) {
        stateContinuation.yield(state)
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEPortalLink: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: startIfPossible()
        case .poweredOff: handleLoss(.poweredOff)
        case .unauthorized: handleLoss(.unauthorized)
        case .unsupported: handleLoss(.unsupported)
        default: break
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover discovered: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = (advertisedName ?? discovered.name ?? "").lowercased()
        guard name.contains("skylanders") else { return }
        adopt(discovered)
    }

    public func centralManager(_ central: CBCentralManager, didConnect connected: CBPeripheral) {
        defaults.set(connected.identifier.uuidString, forKey: Self.savedIdentifierKey)
        connected.discoverServices([Self.serviceUUID])
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect failed: CBPeripheral,
                               error: Error?) {
        scheduleReconnect()
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral lost: CBPeripheral,
                               error: Error?) {
        writeCharacteristic = nil
        failPendingWrite(PortalError.notConnected)
        if wantsConnection {
            emit(.disconnected)
            scheduleReconnect()
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEPortalLink: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([Self.notifyUUID, Self.writeUUID], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        guard let characteristics = service.characteristics,
              let notify = characteristics.first(where: { $0.uuid == Self.notifyUUID }),
              let write = characteristics.first(where: { $0.uuid == Self.writeUUID }) else {
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        writeCharacteristic = write
        peripheral.setNotifyValue(true, for: notify)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        if error == nil, characteristic.uuid == Self.notifyUUID, characteristic.isNotifying {
            emit(.connected)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard error == nil, characteristic.uuid == Self.notifyUUID, let value = characteristic.value else { return }
        frameContinuation.yield(value)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didWriteValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard let pending = pendingWrite else { return }
        pendingWrite = nil
        if let error {
            pending.resume(throwing: error)
        } else {
            pending.resume()
        }
    }
}
