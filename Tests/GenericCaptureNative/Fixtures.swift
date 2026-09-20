import Foundation

// Presentation-only stand-in. Journal, StandardHRSource decoder/buffer, RetiredCaptureDrain and
// WhoopStore below are production sources. startCentral:false prevents any CoreBluetooth access.
@MainActor
public final class LiveState {
    var heartRate: Int?
    var connected = false
    var sensorSpeedKmh: Double?
    var sensorCadence: Double?
    var sensorPowerWatts: Int?
    func setRRIntervals(_ values: [Int]) {}
    func clearSensorMetrics() {}
    static func logSafeDeviceName(_ name: String) -> String { name }
}
