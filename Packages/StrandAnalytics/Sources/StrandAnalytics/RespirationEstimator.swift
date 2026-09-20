import Foundation

/// Shadow spectral/autocorrelation estimator; engineering gates are not clinical cutoffs.
public enum RespirationEstimator {
    public static let version = "resp-spectrum-acf-1"
    public static let preprocessVersion = "masked-linear-detrend-hann-1"
    public struct Input: Sendable {
        public let start: Double
        public let sampleRateHz: Double
        public let values: [Double]
        public let observed: [Bool]
        public let source: String
        public let modality: String
        public let timingVerified: Bool
        public let channelVerified: Bool
        public var motionContaminated: Bool = false
        public var inputRevision: String = "local"
        public var maximumSupportedRate: Double?
        public init(start: Double, sampleRateHz: Double, values: [Double], observed: [Bool], source: String,
                    modality: String, timingVerified: Bool, channelVerified: Bool) {
            self.start = start; self.sampleRateHz = sampleRateHz; self.values = values; self.observed = observed
            self.source = source; self.modality = modality; self.timingVerified = timingVerified
            self.channelVerified = channelVerified
        }
    }
    public struct Policy: Sendable {
        public var minimumRate = 4.0
        public var maximumRate = 40.0
        public var minimumObservedFraction = 0.9
        public var maximumGapSeconds = 2.0
        public var minimumCycles = 5.0
        public var minimumStandardDeviation = 0.01
        public var minimumSpectralFraction = 0.45
        public var minimumAutocorrelation = 0.5
        public var maximumDisagreement = 1.5
        public var harmonicPowerRatio = 0.2
        public init() {}
    }
    public struct Result: Codable, Equatable, Sendable {
        public let start: Double
        public let end: Double
        public let breathsPerMinute: Double?
        public let reason: String?
        public let observedTimeFraction: Double
        public let maximumGapSeconds: Double
        public let spectralRate: Double?
        public let autocorrelationRate: Double?
        public let spectralFraction: Double?
        public let autocorrelation: Double?
        public let effectiveCycles: Double?
        public let source: String
        public let modality: String
        public let inputRevision: String
        public let minimumRate: Double
        public let maximumRate: Double
        public var acceptedSpans: [PhysiologyQuality.Span] = []
        public var methodVersion: String = version
        public var preprocessVersion: String = RespirationEstimator.preprocessVersion
        public var publicationMode: String = "shadow"
        public var computationMode: String = "windowed_retrospective"
    }

    public static func estimate(_ input: Input, policy: Policy = Policy()) -> Result {
        let n = input.values.count, rate = input.sampleRateHz
        let duration = rate.isFinite && rate > 0 ? Double(n) / rate : 0
        let maximumRate = min(policy.maximumRate, input.maximumSupportedRate ?? policy.maximumRate)
        var coverage = 0.0, maxGap = duration
        var spectralRate: Double?, acfRate: Double?, spectralFraction: Double?, acfStrength: Double?, cycles: Double?
        var acceptedSpans: [PhysiologyQuality.Span] = []
        func result(_ reason: String?, _ estimate: Double? = nil) -> Result {
            Result(start: input.start, end: input.start + duration, breathsPerMinute: estimate, reason: reason,
                observedTimeFraction: coverage, maximumGapSeconds: maxGap, spectralRate: spectralRate,
                autocorrelationRate: acfRate, spectralFraction: spectralFraction, autocorrelation: acfStrength,
                effectiveCycles: cycles, source: input.source, modality: input.modality,
                inputRevision: input.inputRevision, minimumRate: policy.minimumRate, maximumRate: maximumRate,
                acceptedSpans: acceptedSpans)
        }
        guard input.start.isFinite, rate.isFinite, rate >= 1, rate <= 128, (32...16384).contains(n),
              input.observed.count == n, duration >= 32, duration <= 300,
              policy.minimumRate > 0, maximumRate.isFinite, maximumRate > policy.minimumRate,
              policy.maximumRate < 0.8 * rate * 30 else { return result("unsupported_shape_or_rate") }
        guard input.timingVerified else { return result("timing_unverified") }
        guard input.channelVerified else { return result("channel_semantics_unverified") }
        guard !input.motionContaminated else { return result("motion_contamination") }
        let mask = input.values.indices.map { input.observed[$0] && input.values[$0].isFinite }
        let indices = mask.indices.filter { mask[$0] }
        coverage = Double(indices.count) / Double(n)
        acceptedSpans = PhysiologyQuality.union(indices.map {
            PhysiologyQuality.Span(input.start + Double($0) / rate, input.start + Double($0 + 1) / rate)
        }, start: input.start, end: input.start + duration)
        var run = 0, longest = 0
        for observed in mask { run = observed ? 0 : run + 1; longest = max(longest, run) }
        maxGap = Double(longest) / rate
        guard coverage >= policy.minimumObservedFraction else { return result("insufficient_observed_time") }
        guard maxGap <= policy.maximumGapSeconds else { return result("acquisition_gap") }
        let count = Double(indices.count)
        let meanT = indices.reduce(0.0) { $0 + Double($1) } / count
        let meanY = indices.reduce(0.0) { $0 + input.values[$1] } / count
        let denominator = indices.reduce(0.0) { $0 + pow(Double($1) - meanT, 2) }
        let slope = indices.reduce(0.0) { $0 + (Double($1) - meanT) * (input.values[$1] - meanY) } / denominator
        let x = input.values.indices.map { mask[$0] ? input.values[$0] - meanY - slope * (Double($0) - meanT) : 0 }
        let variance = x.reduce(0.0) { $0 + $1 * $1 } / count
        guard sqrt(variance) >= policy.minimumStandardDeviation else { return result("weak_modulation") }
        let highestBin = min(n / 2 - 1, Int(floor(min(90, rate * 24) * duration / 60)))
        let firstBin = max(1, Int(ceil(2 * duration / 60)))
        var power = [Double](repeating: 0, count: highestBin + 1)
        for k in firstBin...highestBin {
            var real = 0.0, imaginary = 0.0
            for i in x.indices {
                let windowed = x[i] * (0.5 - 0.5 * cos(2 * .pi * Double(i) / Double(n - 1)))
                let angle = 2 * Double.pi * Double(k) * Double(i) / Double(n)
                real += windowed * cos(angle); imaginary -= windowed * sin(angle)
            }
            power[k] = real * real + imaginary * imaginary
        }
        var peak = firstBin
        for k in firstBin...highestBin where power[k] > power[peak] { peak = k }
        spectralRate = Double(peak) * 60 / duration
        let totalPower = power.reduce(0, +)
        spectralFraction = ((peak - 1)...(peak + 1)).filter { power.indices.contains($0) }.reduce(0.0) { $0 + power[$1] } / totalPower
        guard spectralRate! >= policy.minimumRate, spectralRate! <= maximumRate else { return result("out_of_supported_range") }
        guard spectralFraction!.isFinite, spectralFraction! >= policy.minimumSpectralFraction else { return result("weak_periodicity") }
        let lagLo = max(1, Int(floor(60 * rate / maximumRate)))
        let lagHi = min(n / 2, Int(ceil(60 * rate / policy.minimumRate)))
        var acf = [Double](repeating: -1, count: lagHi + 2)
        for lag in 1...(lagHi + 1) {
            var cross = 0.0, left = 0.0, right = 0.0, pairs = 0
            for i in lag..<n where mask[i] && mask[i - lag] {
                cross += x[i] * x[i - lag]; left += x[i] * x[i]; right += x[i - lag] * x[i - lag]; pairs += 1
            }
            if Double(pairs) >= Double(n - lag) * policy.minimumObservedFraction, left > 0, right > 0 {
                acf[lag] = cross / sqrt(left * right)
            }
        }
        let peaks = (max(2, lagLo)...min(lagHi, n - 2)).filter {
            acf[$0] >= acf[$0 - 1] && acf[$0] > acf[$0 + 1] && acf[$0] >= policy.minimumAutocorrelation
        }
        guard let lag = peaks.first else { return result("weak_autocorrelation") }
        let denom = acf[lag - 1] - 2 * acf[lag] + acf[lag + 1]
        let shift = abs(denom) > 1e-12 ? min(0.5, max(-0.5, 0.5 * (acf[lag - 1] - acf[lag + 1]) / denom)) : 0
        acfRate = 60 * rate / (Double(lag) + shift); acfStrength = acf[lag]
        guard acfRate!.isFinite, acfRate! >= policy.minimumRate, acfRate! <= maximumRate else {
            return result("out_of_supported_range")
        }
        let harmonic = [Double(peak) / 2, Double(peak) * 2].contains { bin in
            let k = Int(bin.rounded())
            return (firstBin...highestBin).contains(k) && abs(k - peak) > 2 && power[k] >= power[peak] * policy.harmonicPowerRatio
        }
        guard !harmonic else { return result("harmonic_ambiguity") }
        guard abs(acfRate! - spectralRate!) <= policy.maximumDisagreement else { return result("spectral_autocorrelation_disagreement") }
        cycles = duration * coverage * acfRate! / 60
        guard cycles! >= policy.minimumCycles else { return result("insufficient_cycles") }
        let estimate = (spectralRate! + acfRate!) / 2
        guard estimate.isFinite, estimate >= policy.minimumRate, estimate <= maximumRate else {
            return result("out_of_supported_range")
        }
        return result(nil, estimate)
    }

    /// Resampling is restricted to adjacent verified original spans. Coarse packet time is ineligible.
    public static func fromIntervals(start: Double, duration: Int,
                                      observations: [PhysiologyQuality.IntervalObservation],
                                      inputRevision: String = "local") -> Input {
        precondition((32...300).contains(duration) && start.isFinite)
        var unique: [PhysiologyQuality.IntervalObservation] = []
        for row in observations where !unique.contains(row) { unique.append(row) }
        let rows = unique.sorted { ($0.verifiedSpan?.start ?? $0.eventTime) < ($1.verifiedSpan?.start ?? $1.eventTime) }
        let ownership = Set(rows.map { [$0.userId, $0.deviceId, $0.source, $0.modality, $0.clockVersion] })
        let identities = Dictionary(grouping: rows, by: \.originalId)
        let verified = !rows.isEmpty && ownership.count == 1 && identities.values.allSatisfy { $0.count == 1 } && rows.allSatisfy { row in
            guard let span = row.verifiedSpan else { return false }
            return span.start.isFinite && span.end.isFinite && span.end > span.start &&
                row.eventTime.isFinite && row.originalRRMs.isFinite &&
                abs((span.end - span.start) - row.originalRRMs / 1000) <= 0.002001 &&
                row.timestampPrecisionSeconds.isFinite && row.timestampPrecisionSeconds > 0 && row.timestampPrecisionSeconds <= 0.020 &&
                row.startBeatId?.isEmpty == false && row.endBeatId?.isEmpty == false &&
                row.continuityGroup?.isEmpty == false && !row.clockVersion.isEmpty && row.clockVersion != "unknown" && row.decoderVersion != "unknown" &&
                ["ecg_nn", "ppg_ibi"].contains(row.modality)
        }
        // Clock uncertainty cannot widen RR quantization, and a shared rejected beat stays rejected.
        var rejectedBeats = Set<String>()
        for row in rows {
            if !row.startBeatAccepted, let beat = row.startBeatId { rejectedBeats.insert(beat) }
            if !row.endBeatAccepted, let beat = row.endBeatId { rejectedBeats.insert(beat) }
        }
        func endpointsAccepted(_ row: PhysiologyQuality.IntervalObservation) -> Bool {
            row.startBeatAccepted && row.endBeatAccepted &&
                !rejectedBeats.contains(row.startBeatId ?? "") && !rejectedBeats.contains(row.endBeatId ?? "")
        }
        var values = [Double](repeating: .nan, count: duration * 4), mask = [Bool](repeating: false, count: duration * 4)
        if verified, rows.count > 1 {
            for i in 1..<rows.count {
                let a = rows[i - 1], b = rows[i], sa = a.verifiedSpan!, sb = b.verifiedSpan!
                guard a.endBeatId == b.startBeatId, a.continuityGroup == b.continuityGroup,
                      abs(sa.end - sb.start) <= 0.002, a.originalAccepted, b.originalAccepted,
                      endpointsAccepted(a), endpointsAccepted(b), !a.rhythmAmbiguous, !b.rhythmAmbiguous,
                      a.corrections.isEmpty, b.corrections.isEmpty else { continue }
                let left = (sa.start + sa.end) / 2, right = (sb.start + sb.end) / 2
                guard right > left, right - left <= 2 else { continue }
                for j in values.indices {
                    let t = start + Double(j) / 4
                    if t >= left && t < right {
                        values[j] = a.originalRRMs + (b.originalRRMs - a.originalRRMs) * (t - left) / (right - left)
                        mask[j] = true
                    }
                }
            }
        }
        var input = Input(start: start, sampleRateHz: 4, values: values, observed: mask,
            source: rows.first?.source ?? "unavailable", modality: "rsa_ibi_ms", timingVerified: verified, channelVerified: verified)
        input.inputRevision = inputRevision
        if verified { input.maximumSupportedRate = 24 / rows.map { $0.verifiedSpan!.end - $0.verifiedSpan!.start }.max()! }
        return input
    }

    public struct Fusion: Codable, Equatable, Sendable {
        public let breathsPerMinute: Double?
        public let reason: String?
        public let methods: [String]
        public let evidenceStrength: Double?
    }
    /// Correlated evidence never multiplies confidence; disagreeing eligible channels abstain.
    public static func fuse(_ results: [Result], maximumDisagreement: Double = 1.5) -> Fusion {
        let accepted = results.filter { $0.reason == nil && $0.breathsPerMinute != nil }
        guard let first = accepted.first else { return Fusion(breathsPerMinute: nil, reason: "no_eligible_channels", methods: [], evidenceStrength: nil) }
        let methods = accepted.map(\.modality)
        guard accepted.allSatisfy({ $0.start == first.start && $0.end == first.end && $0.inputRevision == first.inputRevision }) else {
            return Fusion(breathsPerMinute: nil, reason: "channel_windows_not_aligned", methods: methods, evidenceStrength: nil)
        }
        let rates = accepted.compactMap(\.breathsPerMinute).sorted()
        guard rates.last! - rates.first! <= maximumDisagreement else {
            return Fusion(breathsPerMinute: nil, reason: "cross_channel_disagreement", methods: methods, evidenceStrength: nil)
        }
        return Fusion(breathsPerMinute: (rates[(rates.count - 1) / 2] + rates[rates.count / 2]) / 2,
            reason: nil, methods: methods, evidenceStrength: accepted.compactMap(\.autocorrelation).min())
    }

    public struct Summary: Codable, Equatable, Sendable {
        public let median: Double?
        public let mean: Double?
        public let acceptedSeconds: Double
        public let coverage: Double
        public let acceptedWindows: Int
        public let totalWindows: Int
        public let context: String
        /// Sorted accepted-window estimates, not a duration-weighted or reference distribution.
        public let distributionBpm: [Double]
    }
    /// Overlapping strides contribute duration once; sleep and awake-rest summaries remain separate.
    public static func summarize(_ results: [Result], start: Double, end: Double, context: String) -> Summary {
        precondition(end > start && ["qualified_sleep", "qualified_awake_rest"].contains(context))
        let inPeriod = results.filter { $0.start >= start && $0.end <= end }
        let accepted = inPeriod.filter { $0.reason == nil && $0.breathsPerMinute != nil }
        let values = accepted.compactMap(\.breathsPerMinute).sorted()
        let spans = accepted.flatMap(\.acceptedSpans)
        let seconds = PhysiologyQuality.union(spans, start: start, end: end).reduce(0.0) { $0 + $1.end - $1.start }
        let median = values.isEmpty ? nil : (values[(values.count - 1) / 2] + values[values.count / 2]) / 2
        return Summary(median: median, mean: values.isEmpty ? nil : values.reduce(0, +) / Double(values.count),
            acceptedSeconds: seconds, coverage: seconds / (end - start), acceptedWindows: accepted.count,
            totalWindows: inPeriod.count, context: context, distributionBpm: values)
    }
}
