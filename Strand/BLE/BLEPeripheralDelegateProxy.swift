import CoreBluetooth

/// Retains the admitted generation. The driver rejects a callback from an obsolete proxy
/// before it reaches the manager's current ACK queue. Native callbacks have no operation ID.
@MainActor
final class BLEPeripheralDelegateProxy: NSObject, @preconcurrency CBPeripheralDelegate {
    private weak var driver: BLETransportDriver<CoreBluetoothCentralTransport>?
    private let token: BLEConnectionOwner.Token
    init(driver: BLETransportDriver<CoreBluetoothCentralTransport>, token: BLEConnectionOwner.Token) {
        self.driver = driver
        self.token = token
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let driver else { return }
        driver.discoveredServices(driver.central.wrap(peripheral), token: token, error: error)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let driver else { return }
        driver.discoveredCharacteristics(driver.central.wrap(peripheral), token: token, service: service, error: error)
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let driver else { return }
        driver.writeCompleted(driver.central.wrap(peripheral), token: token, characteristic: characteristic, error: error)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let driver else { return }
        driver.valueChanged(driver.central.wrap(peripheral), token: token, characteristic: characteristic,
                            value: characteristic.value, error: error)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard let driver else { return }
        driver.notificationChanged(driver.central.wrap(peripheral), token: token, characteristic: characteristic,
                                   notifying: characteristic.isNotifying, error: error)
    }
}
