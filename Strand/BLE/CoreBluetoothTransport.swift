import CoreBluetooth

@MainActor
final class CoreBluetoothPeripheralTransport: BLEPeripheralTransport {
    let native: CBPeripheral
    init(_ native: CBPeripheral) { self.native = native }
    var identifier: UUID { native.identifier }
    var linkState: BLEConnectionOwner.LinkState {
        switch native.state {
        case .connected: return .connected
        case .connecting: return .connecting
        case .disconnecting: return .disconnecting
        default: return .disconnected
        }
    }
    func owns(service: CBService) -> Bool { native.services?.contains(where: { $0 === service }) == true }
    func owns(characteristic: CBCharacteristic) -> Bool {
        native.services?.contains(where: { service in
            service.characteristics?.contains(where: { $0 === characteristic }) == true
        }) == true
    }
    func discoverServices(_ uuids: [String]) { native.discoverServices(uuids.map(CBUUID.init(string:))) }
    func discoverCharacteristics(_ uuids: [String]?, for service: CBService) {
        native.discoverCharacteristics(uuids?.map(CBUUID.init(string:)), for: service)
    }
    func setNotify(_ enabled: Bool, for characteristic: CBCharacteristic) {
        native.setNotifyValue(enabled, for: characteristic)
    }
    func read(_ characteristic: CBCharacteristic) { native.readValue(for: characteristic) }
    func write(_ bytes: Data, for characteristic: CBCharacteristic, withResponse: Bool) {
        native.writeValue(bytes, for: characteristic, type: withResponse ? .withResponse : .withoutResponse)
    }
}

@MainActor
final class CoreBluetoothCentralTransport: BLECentralTransport {
    let native: CBCentralManager
    private var peripherals: [ObjectIdentifier: CoreBluetoothPeripheralTransport] = [:]
    init(_ native: CBCentralManager) { self.native = native }
    var poweredOn: Bool { native.state == .poweredOn }

    func wrap(_ native: CBPeripheral) -> CoreBluetoothPeripheralTransport {
        let identity = ObjectIdentifier(native)
        if let cached = peripherals[identity] { return cached }
        let result = CoreBluetoothPeripheralTransport(native)
        peripherals[identity] = result
        return result
    }
    func retrieve(_ identifiers: [UUID]) -> [CoreBluetoothPeripheralTransport] {
        native.retrievePeripherals(withIdentifiers: identifiers).map(wrap)
    }
    func retrieveConnected(_ services: [String]) -> [CoreBluetoothPeripheralTransport] {
        native.retrieveConnectedPeripherals(withServices: services.map(CBUUID.init(string:))).map(wrap)
    }
    func scan(_ services: [String], allowDuplicates: Bool) {
        native.scanForPeripherals(withServices: services.map(CBUUID.init(string:)),
                                 options: [CBCentralManagerScanOptionAllowDuplicatesKey: allowDuplicates])
    }
    func stopScan() { native.stopScan() }
    func connect(_ peripheral: CoreBluetoothPeripheralTransport, request: BLEConnectionOwner.Request) {
        var options: [String: Any] = [:]
        if request.startDelay > 0 {
            options[CBConnectPeripheralOptionStartDelayKey] = NSNumber(value: request.startDelay)
        }
        if #available(iOS 17.0, macOS 14.0, *) {
            options[CBConnectPeripheralOptionEnableAutoReconnect] = request.automaticReconnect
        }
        native.connect(peripheral.native, options: options)
    }
    func cancel(_ peripheral: CoreBluetoothPeripheralTransport) { native.cancelPeripheralConnection(peripheral.native) }
}
