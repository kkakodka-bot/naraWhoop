import CoreBluetooth

/// Retained for one admitted connection generation. Delayed callbacks cannot consume a new ACK queue.
@MainActor
final class BLEPeripheralDelegateProxy: NSObject, @preconcurrency CBPeripheralDelegate {
    private weak var manager: BLEManager?
    private let token: BLEConnectionOwner.Token
    init(manager: BLEManager, token: BLEConnectionOwner.Token) {
        self.manager = manager
        self.token = token
    }
    private func current(_ peripheral: CBPeripheral) -> BLEManager? {
        guard peripheral.identifier == token.peripheralID,
              manager?.acceptsPeripheralCallback(token) == true else { return nil }
        return manager
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        current(peripheral)?.peripheral(peripheral, didDiscoverServices: error)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral.services?.contains(where: { $0 === service }) == true else { return }
        current(peripheral)?.peripheral(peripheral, didDiscoverCharacteristicsFor: service, error: error)
    }
    private func owns(_ peripheral: CBPeripheral, _ characteristic: CBCharacteristic) -> Bool {
        peripheral.services?.contains(where: { service in
            service.characteristics?.contains(where: { $0 === characteristic }) == true
        }) == true
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard owns(peripheral, characteristic) else { return }
        current(peripheral)?.peripheral(peripheral, didWriteValueFor: characteristic, error: error)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard owns(peripheral, characteristic) else { return }
        current(peripheral)?.peripheral(peripheral, didUpdateValueFor: characteristic, error: error)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard owns(peripheral, characteristic) else { return }
        current(peripheral)?.peripheral(peripheral, didUpdateNotificationStateFor: characteristic, error: error)
    }
}
