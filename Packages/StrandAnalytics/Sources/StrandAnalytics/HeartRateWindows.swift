import Foundation
import WhoopProtocol

/// Frequent sampled HR, separate from the overnight resting baseline. The low-motion statistic
/// is an engineering estimate, not proof of rest or a clinically validated measurement.
public enum HeartRateWindows {
    public static let version = "sampled-hr-five-minute-2"
    public struct Measurement: Equatable, Sendable {
        public let start: Int, end: Int
        public let meanBpm: Double?, lowMotionBpm: Double?
        public let sampleFraction: Double, lowMotionSampleFraction: Double
        public let reason: String?, lowMotionReason: String?
        public let movingSeconds: Int, motionObservedSeconds: Int
    }

    /// Inputs must belong to one device. Each unique sampled second contributes once; conflicts,
    /// missing seconds, off-body evidence and incomplete windows never become observed coverage.
    public static func windows(start: Int, end: Int, hr: [HRSample], gravity: [GravitySample],
                               excluded: [PhysiologyQuality.Span] = []) -> [Measurement] {
        guard end >= start, end - start <= 172800 else { return [] }
        let first = Int(ceil(Double(start) / 300)) * 300
        let h = Dictionary(grouping: hr.filter { $0.ts >= first && $0.ts < end }, by: \.ts)
        let g = Dictionary(grouping: gravity.filter { $0.ts >= first && $0.ts < end }, by: \.ts)
        var output: [Measurement] = []
        var t = first
        while t + 300 <= end {
            var values: [Double] = [], quietValues: [Double] = []
            var gap = 0, longestGap = 0, quietGap = 0, longestQuietGap = 0
            var offBody = false, movingSeconds = 0, motionObservedSeconds = 0
            for second in t..<(t + 300) {
                let excludedSecond = excluded.contains { $0.start < Double(second + 1) && $0.end > Double(second) }
                offBody = offBody || excludedSecond
                let hrs = Set((h[second] ?? []).map(\.bpm))
                let value = !excludedSecond && hrs.count == 1 && (25...240).contains(hrs.first!) ? Double(hrs.first!) : nil
                let gs = g[second] ?? []
                let motion = Set(gs.compactMap(\.dynAccel).filter { $0.isFinite && (0...8).contains($0) })
                let validMotion = !gs.isEmpty && gs.allSatisfy { $0.unit == "g" && $0.dynAccel != nil && $0.dynAccel!.isFinite && (0...8).contains($0.dynAccel!) } && motion.count == 1
                let moving = validMotion && motion.first! > 0.03
                if validMotion { motionObservedSeconds += 1 }
                if moving { movingSeconds += 1 }
                if let value { values.append(value); gap = 0 } else { gap += 1 }
                if let value, validMotion, !moving { quietValues.append(value); quietGap = 0 } else { quietGap += 1 }
                longestGap = max(longestGap, gap); longestQuietGap = max(longestQuietGap, quietGap)
            }
            let fraction = Double(values.count) / 300, quietFraction = Double(quietValues.count) / 300
            let reason: String? = fraction < 0.9 ? "insufficient_hr_samples" : longestGap > 30 ? "hr_sample_gap" : nil
            let quietReason: String? = offBody ? "off_body_evidence" :
                quietFraction < 0.9 ? "insufficient_motion_matched_samples" : longestQuietGap > 30 ? "motion_sample_gap" : nil
            output.append(Measurement(start: t, end: t + 300,
                meanBpm: reason == nil ? values.reduce(0, +) / Double(values.count) : nil,
                lowMotionBpm: quietReason == nil ? quietValues.reduce(0, +) / Double(quietValues.count) : nil,
                sampleFraction: fraction, lowMotionSampleFraction: quietFraction,
                reason: reason, lowMotionReason: quietReason, movingSeconds: movingSeconds,
                motionObservedSeconds: motionObservedSeconds))
            t += 300
        }
        return output
    }
}
