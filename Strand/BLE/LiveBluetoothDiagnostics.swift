import Foundation
import WhoopProtocol

/// Receipt-only diagnostics. Never reads persisted samples or the history router.
/// The view samples this bounded state once a second, avoiding per-packet dashboard invalidations.
@MainActor
final class LiveBluetoothDiagnostics {
    nonisolated static let visibilityKey = "developer.showLiveBluetoothDiagnostic"
    let imuVisualization = LiveIMUVisualizationModel()

    enum TrafficLane {
        case live
        case backfill
    }

    struct TrafficRates {
        let liveBytesPerSecond: Double
        let backfillBytesPerSecond: Double
        let totalBytesPerSecond: Double
        let chunksPerSecond: Double
    }
    private struct TrafficBucket {
        var totalBytes = 0
        var liveBytes = 0
        var backfillBytes = 0
        var chunks = 0
    }
    private var traffic: [Int: TrafficBucket] = [:]
    private(set) var receivedBytes = 0
    private(set) var savedChunks = 0
    private(set) var lastSavedChunk: Date?

    /// Count a payload whose lane is already known (standard profiles and test fixtures).
    /// This is app payload, not radio/ATT overhead.
    func receiveBytes(_ count: Int, lane: TrafficLane, at now: Date = Date()) {
        receiveIncomingBytes(count, at: now)
        receiveClassifiedBytes(count, lane: lane, at: now)
    }

    /// Count every raw notification exactly once before proprietary-frame reassembly. Keeping the total
    /// independent from the classified lanes means a partial or corrupt frame is still honest incoming
    /// Bluetooth traffic instead of disappearing from the UI.
    func receiveIncomingBytes(_ count: Int, at now: Date = Date()) {
        guard count > 0 else { return }
        let second = prepareTrafficBucket(at: now)
        traffic[second, default: TrafficBucket()].totalBytes += count
        receivedBytes += count
    }

    /// Attribute bytes after a proprietary frame is complete, when live-vs-backfill is knowable from its
    /// decoded type. This intentionally does not touch the raw total a second time.
    func receiveClassifiedBytes(_ count: Int, lane: TrafficLane, at now: Date = Date()) {
        guard count > 0 else { return }
        let second = prepareTrafficBucket(at: now)
        switch lane {
        case .live: traffic[second, default: TrafficBucket()].liveBytes += count
        case .backfill: traffic[second, default: TrafficBucket()].backfillBytes += count
        }
    }

    /// Called at the durable chunk's trim-ack boundary, not for every historical packet.
    func didSaveBackfillChunk(at now: Date = Date()) {
        let second = prepareTrafficBucket(at: now)
        traffic[second, default: TrafficBucket()].chunks += 1
        savedChunks += 1
        lastSavedChunk = now
    }

    private func prepareTrafficBucket(at now: Date) -> Int {
        let second = Int(now.timeIntervalSince1970)
        traffic = traffic.filter { $0.key > second - 10 && $0.key <= second }
        return second
    }

    func trafficRates(at now: Date) -> TrafficRates {
        let second = Int(now.timeIntervalSince1970)
        let recent = traffic.filter { $0.key > second - 10 && $0.key <= second }.values
        return TrafficRates(liveBytesPerSecond: Double(recent.reduce(0) { $0 + $1.liveBytes }) / 10,
                            backfillBytesPerSecond: Double(recent.reduce(0) { $0 + $1.backfillBytes }) / 10,
                            totalBytesPerSecond: Double(recent.reduce(0) { $0 + $1.totalBytes }) / 10,
                            chunksPerSecond: Double(recent.reduce(0) { $0 + $1.chunks }) / 10)
    }

    struct Stream: Identifiable {
        let id: String
        let title: String
        var detail: String
        var lastReceived: Date
        var arrivals: [Date]
        var packets: Int

        func isActive(at now: Date) -> Bool { now.timeIntervalSince(lastReceived) < 5 }
        func packetsPerSecond(at now: Date) -> Double {
            Double(arrivals.filter { now.timeIntervalSince($0) < 10 }.count) / 10
        }
    }

    private(set) var streams: [String: Stream] = [:]
    func reset() {
        imuVisualization.reset()
        streams.removeAll()
        traffic.removeAll()
        receivedBytes = 0
        savedChunks = 0
        lastSavedChunk = nil
    }

    private func note(_ id: String, title: String, detail: String, at now: Date) {
        var stream = streams[id] ?? Stream(id: id, title: title, detail: detail,
            lastReceived: now, arrivals: [], packets: 0)
        stream.detail = detail
        stream.lastReceived = now
        stream.arrivals.removeAll { now.timeIntervalSince($0) >= 10 }
        stream.arrivals.append(now)
        // Bound memory even under malformed producer floods.
        if stream.arrivals.count > 4096 { stream.arrivals.removeFirst(stream.arrivals.count - 4096) }
        stream.packets += 1
        streams[id] = stream
    }

    func receiveHeartRate(_ bytes: [UInt8], at now: Date = Date()) {
        guard let measurement = StandardHeartRate.parse(bytes) else { return }
        note("hr", title: "Heart rate", detail: "\(measurement.hr) bpm · standard Bluetooth", at: now)
        if !measurement.rr.isEmpty {
            note("rr", title: "Beat intervals (R–R)", detail: measurement.rr.map { "\($0) ms" }.joined(separator: ", "), at: now)
        }
        if measurement.contact != .unsupported {
            note("contact", title: "Sensor contact",
                detail: measurement.contact == .supportedDetected ? "Detected" : "Not detected", at: now)
        }
    }

    func receiveBattery(_ bytes: [UInt8], at now: Date = Date()) {
        guard let percent = bytes.first, percent <= 100 else { return }
        note("battery", title: "Battery", detail: "\(percent)% · Bluetooth reading", at: now)
    }

    func receiveFrame(_ frame: [UInt8], family: DeviceFamily, at now: Date = Date()) {
        let index = family == .whoop5 ? 8 : 4
        guard frame.count > index else { return }
        let type = frame[index]
        // Positive live-carrier allowlist, independent of the app's backfilling flag.
        // Thus type 47/52 history can NEVER appear live, even outside our own offload.
        guard [40, 43, 51].contains(type), verifyFrame(frame, family: family).ok else { return }
        if family == .whoop5, Whoop5RawImu.rawColumns(frame) != nil {
            guard ImuContinuousRecorder.isFreshLiveFrame(frame, isOffload: false,
                receivedAtMs: Int64(now.timeIntervalSince1970 * 1000)) else { return }
            note("imu", title: "Live IMU", detail: "100 Hz · accelerometer + gyroscope · 6 axes", at: now)
            if let decoded = Whoop5RawImu.decode(frame) { imuVisualization.receive(decoded, at: now) }
        } else if type == 40 {
            let parsed = parseFrame(frame, family: family)
            var values: [String] = []
            if let hr = parsed.parsed["heart_rate"]?.intValue { values.append("\(hr) bpm") }
            if let rr = parsed.parsed["rr_intervals"]?.intArrayValue, !rr.isEmpty {
                values.append("R–R " + rr.map { "\($0) ms" }.joined(separator: ", "))
            }
            note("telemetry", title: "Realtime strap telemetry",
                detail: values.isEmpty ? "\(frame.count) bytes · undecoded values" : values.joined(separator: " · "), at: now)
        } else {
            note("raw-\(type)", title: "Undecoded live raw data",
                detail: "Type \(type) · \(frame.count) bytes · optical identity/rate unverified", at: now)
        }
    }
}
