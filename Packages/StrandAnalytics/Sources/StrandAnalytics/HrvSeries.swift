import Foundation

/// Context-specific summaries and past-only comparison. No baseline clamps a measured value.
public enum HrvSeries {
    /// Retrospective stage feature: signal validity only, never a prerequisite sleep label.
    public static func feature(at time: Int, measurements: [HrvWindow.Result]) -> HrvWindow.Result? {
        let rows = measurements.filter { $0.start <= time && time < $0.end }
        guard let first = rows.first, rows.allSatisfy({ $0.sameMeasurement(as: first) }), first.measurementValid else { return nil }
        return first
    }
    public struct Baseline: Codable, Equatable, Sendable {
        public let version: String
        public let windowDays: Int
        public let effectiveSampleCount: Int
        public let excludedZeroCount: Int
        public let logMedian: Double?
        public let logMAD: Double?
        public let logDeviation: Double?
        public let robustZ: Double?
        public let reason: String?
    }
    public struct Summary: Codable, Equatable, Sendable {
        public let context: String
        public let meanRMSSD: Double?
        public let medianRMSSD: Double?
        public let durationWeightedMeanRMSSD: Double?
        public let distribution: [Double]
        public let eligibleWindowCount: Int
        public let excludedWindowCount: Int
        public let acceptedDurationSeconds: Double
        public let opportunitySeconds: Double
        public let samplingCoverage: Double
        public let segmentCoverage: [Double]
        public let representative: Bool
        public let reason: String?
        public let version: String
    }
    public struct SummaryPolicy: Codable, Equatable, Sendable {
        public var minimumSamplingCoverage: Double = 0.50
        public var minimumSegmentCoverage: Double = 0.10
        public var minimumWindows: Int = 3
        public var version: String = "engineering-night-thirds-v1"
        public init() {}
    }

    public static func windows(start: Int, end: Int, observations: [PhysiologyQuality.IntervalObservation],
                               context: [PhysiologyQuality.ContextEpoch] = [], policy: HrvWindow.Policy = .init(),
                               inputRevision: String = "unversioned", computationMode: String = "retrospective") -> [HrvWindow.Result] {
        guard end > start else { return [] }
        let starts = Array(stride(from: HrvWindow.alignedStart(start), to: end, by: HrvWindow.seconds))
        let lo = Double(starts[0]), hi = Double(starts.last!) + 300
        var buckets: [Int: [PhysiologyQuality.IntervalObservation]] = [:]
        for row in observations {
            var owners = Set<Int>()
            if row.eventTime.isFinite, row.eventTime >= lo, row.eventTime < hi {
                owners.insert(HrvWindow.alignedStart(Int(floor(row.eventTime))))
            }
            if let span = row.verifiedSpan, span.start.isFinite, span.end.isFinite {
                let a = max(lo, span.start), b = min(hi, span.end)
                if b > a {
                    var cursor = HrvWindow.alignedStart(Int(floor(a)))
                    while Double(cursor) < b { owners.insert(cursor); cursor += 300 }
                }
            }
            for owner in owners { buckets[owner, default: []].append(row) }
        }
        return starts.map {
            HrvWindow.measure(start: $0, observations: buckets[$0] ?? [], context: context, policy: policy, inputRevision: inputRevision, computationMode: computationMode)
        }
    }
    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted(), n = sorted.count
        return n % 2 == 0 ? (sorted[n / 2 - 1] + sorted[n / 2]) / 2 : sorted[n / 2]
    }
    private static func sameSeries(_ a: HrvWindow.Result, _ b: HrvWindow.Result) -> Bool {
        a.userId == b.userId && a.deviceId == b.deviceId && a.deviceFirmware == b.deviceFirmware && a.source == b.source && a.modality == b.modality &&
            a.metric == b.metric && a.unit == b.unit && a.algorithmVersion == b.algorithmVersion &&
            a.qualityVersion == b.qualityVersion && a.computationMode == b.computationMode &&
            a.decoderVersions == b.decoderVersions && a.clockVersions == b.clockVersions &&
            a.end - a.start == b.end - b.start
    }
    private static func comparable(_ a: HrvWindow.Result, _ b: HrvWindow.Result) -> Bool {
        sameSeries(a, b) && a.context == b.context
    }
    /// Semantic conflicts are excluded. Re-publication of identical evidence counts only once.
    private static func unambiguous(_ windows: [HrvWindow.Result]) -> [HrvWindow.Result] {
        Dictionary(grouping: windows, by: \.start).values.compactMap { rows in
            guard let first = rows.first, rows.allSatisfy({ $0.sameMeasurement(as: first) }) else { return nil }
            return first
        }.sorted { $0.start < $1.start }
    }
    public static func baseline(current: HrvWindow.Result, history: [HrvWindow.Result],
                                windowDays: Int = 28, minimumSamples: Int = 20) -> Baseline {
        // A changed validity/context result must invalidate its older eligible counterpart first.
        let candidates = unambiguous(history.filter {
            $0.end <= current.start && $0.start >= current.start - max(0, windowDays) * 86400 &&
                sameSeries(current, $0)
        }).filter { $0.baselineEligible && $0.measurementValid && $0.context == current.context }
        let values = candidates.compactMap(\.observedRMSSD).filter { $0.isFinite && $0 >= 0 }
        let positives = values.filter { $0 > 0 }.map(log)
        let center = median(positives)
        let mad = center.flatMap { m in median(positives.map { abs($0 - m) }) }
        let reason: String?
        if windowDays <= 0 || minimumSamples < 1 { reason = "invalid_baseline_policy" }
        else if !current.measurementValid || !current.baselineEligible { reason = current.baselineReason ?? "ineligible_measurement" }
        else if positives.count < minimumSamples { reason = "insufficient_baseline" }
        else if current.observedRMSSD == 0 { reason = "zero_not_log_transformable" }
        else if current.observedRMSSD == nil || current.observedRMSSD! < 0 || !current.observedRMSSD!.isFinite { reason = "unusable_measurement" }
        else { reason = nil }
        let deviation = reason == nil ? log(current.observedRMSSD!) - center! : nil
        let z = deviation.flatMap { d in mad.flatMap { $0 > 0 ? d / (1.4826 * $0) : nil } }
        return Baseline(version: "past-log-median-mad-v1", windowDays: windowDays,
            effectiveSampleCount: positives.count, excludedZeroCount: values.count - positives.count,
            logMedian: center, logMAD: mad, logDeviation: deviation, robustZ: z,
            reason: reason ?? (mad == 0 ? "zero_baseline_dispersion" : nil))
    }

    /// Arithmetic mean is primary; representativeness is measured across three equal episode spans.
    public static func summarize(_ windows: [HrvWindow.Result], start: Int, end: Int,
                                 context: String = "sleep", policy: SummaryPolicy = .init()) -> Summary {
        let overlapping = windows.filter { $0.start < end && $0.end > start }
        let overlappingCount = Set(overlapping.map(\.start)).count
        let inEpisode = unambiguous(overlapping.filter { $0.start >= start && $0.end <= end })
        let eligible = inEpisode.filter { $0.measurementValid && $0.baselineEligible && $0.context == context &&
            $0.observedRMSSD?.isFinite == true && $0.observedRMSSD! >= 0 }
        let homogeneous = eligible.first.map { first in eligible.allSatisfy { comparable(first, $0) } } ?? true
        let values = eligible.compactMap(\.observedRMSSD)
        let opportunity = Double(max(0, end - start))
        let accepted = eligible.reduce(0) { $0 + $1.acceptedDurationSeconds }
        let observed = eligible.reduce(0) { $0 + $1.observedTimeFraction * 300 }
        let observedSpans = eligible.flatMap(\.observedSpans)
        let thirds = (0..<3).map { part -> Double in
            let a = Double(start) + opportunity * Double(part) / 3, b = a + opportunity / 3
            guard b > a else { return 0 }
            let covered = PhysiologyQuality.union(observedSpans, start: a, end: b).reduce(0) { $0 + $1.end - $1.start }
            return covered / (b - a)
        }
        let coverage = opportunity > 0 ? observed / opportunity : 0
        let reason: String?
        if opportunity <= 0 || !policy.minimumSamplingCoverage.isFinite || !(0...1).contains(policy.minimumSamplingCoverage) ||
            !policy.minimumSegmentCoverage.isFinite || !(0...1).contains(policy.minimumSegmentCoverage) || policy.minimumWindows < 1 { reason = "invalid_summary_policy" }
        else if !homogeneous { reason = "incompatible_measurements" }
        else if values.count < policy.minimumWindows { reason = "insufficient_windows" }
        else if coverage < policy.minimumSamplingCoverage || thirds.contains(where: { $0 < policy.minimumSegmentCoverage }) { reason = "unrepresentative_sampling" }
        else { reason = nil }
        let weighted = accepted > 0 ? eligible.reduce(0) { $0 + $1.observedRMSSD! * $1.acceptedDurationSeconds } / accepted : nil
        return Summary(context: context, meanRMSSD: reason == nil ? values.reduce(0, +) / Double(values.count) : nil,
            medianRMSSD: homogeneous ? median(values) : nil, durationWeightedMeanRMSSD: homogeneous ? weighted : nil,
            distribution: homogeneous ? values.sorted() : [], eligibleWindowCount: eligible.count,
            excludedWindowCount: overlappingCount - eligible.count, acceptedDurationSeconds: accepted,
            opportunitySeconds: opportunity, samplingCoverage: coverage, segmentCoverage: thirds,
            representative: reason == nil, reason: reason, version: policy.version)
    }
}
