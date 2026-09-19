import Combine
import Foundation
import WhoopProtocol

/// Local Bluetooth capture for the explicitly enrolled research strap. Requested rate is a goal,
/// not a firmware setting: opcode 107 has no verified rate argument on 5/MG. Preserve native
/// packets and their provenance; never upsample, sum channels into a rate, or label an ack 100 Hz.
@MainActor
final class BluetoothOpticalRecorder: ObservableObject {
    nonisolated static let enrolledDeviceId = "whoop-5B00145417"
    static let requestedRateHz = 100
    private static let enabledPrefix = "bluetooth.optical.enabled."
    struct Status {
        var enabled = false
        var requestSent = false
        var responseCode: Int?
        var historyFrames = 0
        var liveCandidateFrames = 0
        var lastSampleCounts: [Int] = []
        var lastStrapTs: Int?
        var error: String?
    }
    @Published private(set) var status = Status()
    var sendEnable: () -> Void = {}
    var sendDisable: () -> Void = {}
    var log: (String) -> Void = { _ in }
    private(set) var deviceId = ""
    private var ready = false
    private let defaults: UserDefaults
    private let directory: URL
    private let now: () -> Date
    private var loggedShape = false

    init(directory: URL? = nil, defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask)[0].appendingPathComponent("OpenWhoop/RawOpticalBluetooth")
    }

    func isEnabled(for id: String) -> Bool {
        guard !id.isEmpty else { return false }
        return defaults.object(forKey: Self.enabledPrefix + id) == nil
            ? id == Self.enrolledDeviceId : defaults.bool(forKey: Self.enabledPrefix + id)
    }

    func bonded(deviceId: String) {
        if ready, self.deviceId == deviceId { return }
        self.deviceId = deviceId
        ready = true
        status = Status()
        status.enabled = isEnabled(for: deviceId)
        loggedShape = false
        if status.enabled { request() }
        else if defaults.object(forKey: Self.enabledPrefix + deviceId) != nil { sendDisable() }
    }

    func disconnected() { ready = false; status.requestSent = false }

    func setEnabled(_ enabled: Bool) {
        guard !deviceId.isEmpty, status.enabled != enabled else { return }
        defaults.set(enabled, forKey: Self.enabledPrefix + deviceId)
        status.enabled = enabled
        if ready {
            if enabled { request() } else { sendDisable(); status.requestSent = false }
        }
    }

    private func request() {
        sendEnable()
        status.requestSent = true
        log("Optical Bluetooth: enable requested; target 100 Hz is UNVERIFIED. Native optical history remains enabled; IMU is live-only.")
    }

    func observeCommandResponse(_ frame: [UInt8]) {
        guard ready, status.requestSent, frame.count >= 17,
              frame[8] == 36 || Int(frame[8]) == PuffinPacketType.puffinCommandResponse,
              frame[10] == 107, verifyFrame(frame, family: .whoop5).ok else { return }
        status.responseCode = Int(frame[12])
        log("Optical Bluetooth: command 107 result=\(frame[12]); acknowledgement does not verify a stream or sample rate")
    }

    /// Called inside the chunk commit BEFORE the strap's trim ack. A write failure holds the ack.
    /// Archive every native v20/v26 packet even when normal summary extraction has no optical row.
    func persistHistory(deviceId: String, frames: [[UInt8]]) -> Bool {
        guard isEnabled(for: deviceId) else { return true }
        let optical = frames.filter { Self.isOpticalHistory($0) }
        return persist(deviceId: deviceId, frames: optical, origin: "historical")
    }

    /// Type 47 is historical even outside our own offload: another client may initiate a replay.
    /// Unknown type-43/51 layouts are retained as candidates, never claimed to be decoded optical.
    func ingestOutsideOffload(_ frame: [UInt8], deviceId: String) {
        guard isEnabled(for: deviceId), frame.count > 9 else { return }
        if Self.isOpticalHistory(frame) {
            _ = persistHistory(deviceId: deviceId, frames: [frame])
        } else if Self.isLiveCandidate(frame) {
            _ = persist(deviceId: deviceId, frames: [frame], origin: "live_raw_unclassified")
        }
    }

    nonisolated static func isOpticalHistory(_ frame: [UInt8]) -> Bool {
        guard frame.count > 9, frame[8] == 47, verifyFrame(frame, family: .whoop5).ok else { return false }
        return Whoop5RawOptical.decode(frame) != nil || (frame[9] == 26 && frame.count == 88)
    }

    nonisolated static func isLiveCandidate(_ frame: [UInt8]) -> Bool {
        frame.count > 9 && (frame[8] == 43 || frame[8] == 51)
            && Whoop5RawImu.rawColumns(frame) == nil && verifyFrame(frame, family: .whoop5).ok
    }

    /// Hourly append-only JSONL; base64 keeps the complete checked frame (including unknown fields).
    /// Arrival order is explicit; replay duplicates may occur and consumers dedupe by frame identity.
    /// No pruning or cloud lane: disk errors are visible and historical trim is held until resolved.
    private func persist(deviceId: String, frames: [[UInt8]], origin: String) -> Bool {
        guard !frames.isEmpty else { return true }
        do {
            var bytes = Data()
            let receivedMs = Int64(now().timeIntervalSince1970 * 1_000)
            for frame in frames {
                let decoded = Whoop5RawOptical.decode(frame)
                let ts = frame.count > 18 ? Int(UInt32(frame[15]) | UInt32(frame[16]) << 8
                    | UInt32(frame[17]) << 16 | UInt32(frame[18]) << 24) : nil
                var record: [String: Any] = [
                    "format": 1, "device_id": deviceId, "recorded_at_ms": receivedMs,
                    "origin": origin, "packet_type": Int(frame[8]), "layout_byte": Int(frame[9]),
                    "requested_rate_hz": Self.requestedRateHz, "verified_100hz": false,
                    "frame_base64": Data(frame).base64EncodedString()
                ]
                if origin == "historical" {
                    record["strap_ts"] = ts
                    record["sample_counts_per_slot"] = decoded?.blocks.map(\.sampleCount) ?? [24]
                }
                bytes.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
                bytes.append(0x0A)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("optical-\(receivedMs / 3_600_000).jsonl")
            if !FileManager.default.fileExists(atPath: file.path) {
                try Data().write(to: file, options: .atomic)
                #if os(iOS)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
                #endif
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            let offset = try handle.seekToEnd()
            do { try handle.write(contentsOf: bytes); try handle.synchronize() }
            catch { try? handle.truncate(atOffset: offset); throw error }
            status.error = nil
            if origin == "historical" {
                status.historyFrames += frames.count
                if let decoded = frames.last.flatMap(Whoop5RawOptical.decode) {
                    status.lastSampleCounts = decoded.blocks.map(\.sampleCount)
                    status.lastStrapTs = decoded.baseTs
                    if !loggedShape {
                        loggedShape = true
                        log("Optical Bluetooth: durable native v20; samples per slot \(status.lastSampleCounts). Target 100 Hz not verified.")
                    }
                } else { status.lastSampleCounts = [24] }
            } else { status.liveCandidateFrames += frames.count }
            return true
        } catch {
            let message = "Optical Bluetooth: local write failed; history ack held (\((error as NSError).domain):\((error as NSError).code))"
            if status.error != message { log(message) }
            status.error = message
            return false
        }
    }
}
