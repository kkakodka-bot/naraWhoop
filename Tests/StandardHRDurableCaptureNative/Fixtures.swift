import Foundation

// Presentation only. The journal, source, decoder, retirement drain and Store are real sources.
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
