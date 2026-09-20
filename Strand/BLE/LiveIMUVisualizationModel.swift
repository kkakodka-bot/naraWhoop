import Foundation
import simd
import WhoopProtocol

/// A local 6-axis attitude estimate, never a measured heading or position tracker.
/// The gyro integration plus accelerometer gravity correction follows the complementary-filter
/// family described by Mahony, Hamel & Pflimlin, IEEE TAC 53(5), 2008,
/// https://doi.org/10.1109/TAC.2008.923738. This is an app visualization, not a validated
/// implementation of that paper: the 0.85...1.15 g acceptance band and two-second correction
/// constant below are explicit NOOP display heuristics. Uses every received sample at strap cadence;
/// rendering only reads already-computed poses.
@MainActor
final class LiveIMUVisualizationModel {
    struct Pose {
        let orientation: simd_quatf // sensor -> gravity-aligned world
        let acceleration: SIMD3<Float> // sensor axes, g, includes gravity
        let angularVelocity: SIMD3<Float> // sensor axes, degrees/second
        let linearAcceleration: SIMD3<Float> // gravity removed using estimated attitude
        let sensorTimestamp: TimeInterval
    }
    struct Presentation {
        let pose: Pose
        let relativeOrientation: simd_quatf
        let eulerDegrees: SIMD3<Float> // roll, pitch, yaw (ZYX convention)
        let receivedAt: Date
    }

    private var cached: (frame: Whoop5ImuFrame, receivedAt: Date)?
    private var poses: [Pose] = []
    private var orientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1))
    private var reference = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1))
    private var lastBaseTs: Int?
    private(set) var lastReceivedAt: Date?
    private(set) var isActive = false
    private(set) var samplesProcessed = 0
    private(set) var gapResets = 0
    private let up = SIMD3<Float>(0, 0, 1)

    func activate(at now: Date = Date()) {
        isActive = true
        clearEstimate()
        if let cached, now.timeIntervalSince(cached.receivedAt) < 5 {
            process(cached.frame, receivedAt: cached.receivedAt)
        }
    }

    func deactivate() { isActive = false; clearEstimate() }

    /// Disconnect/device change invalidates the cached sample and relative reference.
    func reset() { cached = nil; clearEstimate() }

    private func clearEstimate() {
        poses = []; lastBaseTs = nil; lastReceivedAt = nil
        orientation = simd_quatf(angle: 0, axis: up); reference = orientation
        samplesProcessed = 0; gapResets = 0
    }

    /// Only the CRC-checked, fresh, live-only diagnostics seam may call this.
    func receive(_ frame: Whoop5ImuFrame, at now: Date) {
        guard frame.sampleRateHz == 100, frame.samples.count == 100,
              frame.samples.allSatisfy({ [$0.ax, $0.ay, $0.az, $0.gx, $0.gy, $0.gz].allSatisfy(\.isFinite) }) else { return }
        // Duplicate/reordered packets cannot rotate the model twice or keep a stopped stream alive.
        guard cached.map({ frame.baseTs > $0.frame.baseTs }) ?? true else { return }
        cached = (frame, now)
        if isActive { process(frame, receivedAt: now) }
    }

    private func process(_ frame: Whoop5ImuFrame, receivedAt: Date) {
        let discontinuity = lastBaseTs.map { frame.baseTs != $0 + 1 } ?? false
        if discontinuity { gapResets += 1 }
        let startsSegment = lastBaseTs == nil || discontinuity
        let dt: Float = 1 / Float(frame.sampleRateHz)
        var next: [Pose] = []
        next.reserveCapacity(frame.samples.count)
        for (index, sample) in frame.samples.enumerated() {
            let a = SIMD3<Float>(Float(sample.ax), Float(sample.ay), Float(sample.az))
            let gyro = SIMD3<Float>(Float(sample.gx), Float(sample.gy), Float(sample.gz))
            let magnitude = simd_length(a)
            if startsSegment && index == 0 {
                // Only trust gravity for initialization near rest. No magnetometer: yaw is arbitrary.
                orientation = (0.85...1.15).contains(magnitude)
                    ? simd_quatf(from: a / magnitude, to: up)
                    : simd_quatf(angle: 0, axis: up)
                reference = orientation
            }
            // Body-frame angular velocity right-multiplies sensor->world attitude.
            // The first sample establishes t=0; subsequent samples represent 10 ms increments.
            if !(startsSegment && index == 0) {
                let omega = gyro * (.pi / 180)
                let speed = simd_length(omega)
                if speed > 0.000001 {
                    orientation = simd_normalize(orientation * simd_quatf(angle: speed * dt, axis: omega / speed))
                }
                // Gentle gravity correction (2 s time constant). Skip strong linear acceleration.
                if (0.85...1.15).contains(magnitude) {
                    let worldAcceleration = orientation.act(a / magnitude)
                    let correction = simd_quatf(from: worldAcceleration, to: up)
                    let blend = simd_slerp(simd_quatf(angle: 0, axis: up), correction, 1 - exp(-dt / 2))
                    orientation = simd_normalize(blend * orientation)
                }
            }
            let gravityInSensor = orientation.inverse.act(up)
            next.append(Pose(orientation: orientation, acceleration: a, angularVelocity: gyro,
                linearAcceleration: a - gravityInSensor, sensorTimestamp: frame.ts(of: index)))
        }
        poses = next
        lastBaseTs = frame.baseTs
        lastReceivedAt = receivedAt
        samplesProcessed += frame.samples.count
    }

    /// Play the latest one-second packet at its native cadence. Hold its last real sample on silence;
    /// never extrapolate movement. Receipt/strap age stays visible in the sheet.
    func presentation(at now: Date) -> Presentation? {
        guard let receivedAt = lastReceivedAt, !poses.isEmpty else { return nil }
        let index = min(poses.count - 1, max(0, Int(now.timeIntervalSince(receivedAt) * 100)))
        let pose = poses[index]
        let relative = simd_normalize(reference.inverse * pose.orientation)
        let m = simd_float3x3(relative)
        let angles = SIMD3<Float>(atan2(m.columns.1.z, m.columns.2.z),
            asin(max(-1, min(1, -m.columns.0.z))), atan2(m.columns.0.y, m.columns.0.x)) * (180 / .pi)
        return Presentation(pose: pose, relativeOrientation: relative, eulerDegrees: angles, receivedAt: receivedAt)
    }

    func zeroRotation(at now: Date = Date()) {
        if let pose = presentation(at: now)?.pose { reference = pose.orientation }
    }
}
