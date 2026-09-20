import Foundation

public typealias HrvWindowResult = HrvWindow.Result

/// Five-minute, event-time measurements. Engineering thresholds require reference-data qualification.
public enum HrvWindow {
    public static let seconds = 300
    public static let algorithmVersion = "observed-pair-rmssd-v2"
    public struct Policy: Codable, Equatable, Sendable {
        public var minimumObservedFraction: Double = 0.90
        public var minimumValidIntervalFraction: Double = 0.90
        public var minimumAcceptedDurationFraction: Double = 0.80
        public var maximumCorrectionFraction: Double = 0.10
        public var maximumGapSeconds: Double = 30
        public var minimumPairs: Int = 20
        public var version: String = "engineering-shadow-90-v2"
        public init() {}
    }
    public struct Result: Codable, Equatable, Sendable {
        public let start: Int
        public let end: Int
        public let userId: String?
        public let deviceId: String?
        public let deviceFirmware: String?
        public let source: String?
        public let modality: String?
        public private(set) var inputRevision: String
        public let computationMode: String
        public let algorithmVersion: String
        public let qualityVersion: String
        public let metric: String
        public let unit: String
        public let observedRMSSD: Double?
        public let correctedRMSSD: Double?
        public let sdnn: Double?
        public let researchObservedRMSSD: Double?
        public let originalIds: [String]
        public let pairMask: [Bool]
        public let correctedPairMask: [Bool]
        public let pairReasons: [String?]
        public let observedTimeFraction: Double
        public let observedSpans: [PhysiologyQuality.Span]
        public let acceptedDurationSeconds: Double
        public let validIntervalFraction: Double
        public let validPairCount: Int
        public let correctedPairCount: Int
        public let correctedMethodVersion: String?
        public let correctionPasses: [String]
        public let maximumGapSeconds: Double
        public let correctionFraction: Double
        public let correctionEventCount: Int
        public let insertedEventCount: Int
        public let deletedEventCount: Int
        public let measurementValid: Bool
        public let reason: String?
        public let context: String
        public let baselineEligible: Bool
        public let baselineReason: String?
        public let timingPrecisionSeconds: Double?
        public let decoderVersions: [String]
        public let clockVersions: [String]

        /// Publication revisions do not change an otherwise identical physiological measurement.
        public func sameMeasurement(as other: Self) -> Bool {
            var comparison = other
            comparison.inputRevision = inputRevision
            return self == comparison
        }
    }

    public static func alignedStart(_ epoch: Int) -> Int { Int(floor(Double(epoch) / 300)) * 300 }

    public static func measure(start: Int, observations: [PhysiologyQuality.IntervalObservation],
                               context: [PhysiologyQuality.ContextEpoch] = [], policy: Policy = Policy(),
                               inputRevision: String = "unversioned", computationMode: String = "retrospective") -> Result {
        typealias Observation = PhysiologyQuality.IntervalObservation
        let lo = Double(start), hi = lo + 300
        let inWindow = observations.filter { row in
            row.eventTime >= lo && row.eventTime < hi ||
                (row.verifiedSpan.map { $0.start < hi && $0.end > lo } ?? false)
        }
        var unique: [[String]: Observation] = [:]
        var conflictingKeys = Set<[String]>()
        var conflict = false
        for row in inWindow {
            let key = [row.userId, row.deviceId, row.source, row.originalId]
            if conflictingKeys.contains(key) { continue }
            if let old = unique[key], old != row { conflict = true; conflictingKeys.insert(key); unique.removeValue(forKey: key) }
            else { unique[key] = row }
        }
        let rows = unique.values.sorted {
            let rawA = $0.verifiedSpan?.end ?? $0.eventTime, rawB = $1.verifiedSpan?.end ?? $1.eventTime
            let a = rawA.isFinite ? rawA : .infinity, b = rawB.isFinite ? rawB : .infinity
            if a != b { return a < b }
            if $0.continuityGroup != $1.continuityGroup { return ($0.continuityGroup ?? "") < ($1.continuityGroup ?? "") }
            if $0.ordinal != $1.ordinal { return ($0.ordinal ?? -1) < ($1.ordinal ?? -1) }
            return $0.originalId < $1.originalId
        }
        func proof(_ row: Observation) -> Bool {
            guard let a = row.startBeatId, let b = row.endBeatId, let group = row.continuityGroup else { return false }
            return !a.isEmpty && !b.isEmpty && a != b && !group.isEmpty && !row.originalId.isEmpty
        }
        func validTiming(_ row: Observation) -> Bool {
            guard row.timestampPrecisionSeconds.isFinite, row.timestampPrecisionSeconds > 0, row.eventTime.isFinite else { return false }
            guard let span = row.verifiedSpan else { return true }
            // Clock uncertainty never expands the fixed RR quantization tolerance.
            return !row.clockVersion.isEmpty && row.clockVersion != "unknown" && row.timestampPrecisionSeconds <= 0.020 &&
                span.start.isFinite && span.end.isFinite && span.end > span.start && row.originalRRMs.isFinite &&
                abs((span.end - span.start) - row.originalRRMs / 1000) <= 0.002001
        }
        // A rejected endpoint remains rejected wherever that same original beat appears.
        var rejectedBeats = Set<[String]>()
        for row in rows {
            if let beat = row.startBeatId, !row.startBeatAccepted { rejectedBeats.insert([row.userId, row.deviceId, row.source, beat]) }
            if let beat = row.endBeatId, !row.endBeatAccepted { rejectedBeats.insert([row.userId, row.deviceId, row.source, beat]) }
        }
        func originalAccepted(_ row: Observation) -> Bool {
            row.originalAccepted && row.startBeatAccepted && row.endBeatAccepted && !row.rhythmAmbiguous &&
                row.originalRRMs.isFinite && (250...2500).contains(row.originalRRMs) && proof(row) &&
                !rejectedBeats.contains([row.userId, row.deviceId, row.source, row.startBeatId ?? ""]) &&
                !rejectedBeats.contains([row.userId, row.deviceId, row.source, row.endBeatId ?? ""])
        }
        func inside(_ row: Observation) -> Bool {
            row.verifiedSpan.map { $0.start >= lo && $0.end <= hi } ?? (row.eventTime >= lo && row.eventTime < hi)
        }
        func successive(_ a: Observation, _ b: Observation) -> Bool {
            guard proof(a), proof(b), a.continuityGroup == b.continuityGroup,
                  a.source == b.source, a.deviceId == b.deviceId, a.userId == b.userId,
                  a.endBeatId == b.startBeatId, a.startBeatId != b.endBeatId else { return false }
            if let x = a.verifiedSpan, let y = b.verifiedSpan, abs(x.end - y.start) > 0.000001 { return false }
            return true
        }
        let accepted = rows.map(originalAccepted)
        var pairMask = Array(repeating: false, count: rows.count)
        var correctedPairMask = Array(repeating: false, count: rows.count)
        var pairReasons = Array<String?>(repeating: "continuity_break", count: rows.count)
        if !rows.isEmpty { pairReasons[0] = "window_boundary" }
        var observedDifferences: [Double] = [], correctedDifferences: [Double] = []
        if rows.count > 1 {
            for index in 1..<rows.count where successive(rows[index - 1], rows[index]) {
                let a = rows[index - 1], b = rows[index]
                guard inside(a), inside(b) else { pairReasons[index] = "window_boundary"; continue }
                pairMask[index] = accepted[index - 1] && accepted[index]
                pairReasons[index] = pairMask[index] ? nil : "rejected_original_beat"
                if pairMask[index] { observedDifferences.append(b.originalRRMs - a.originalRRMs) }
                let correctedA = a.correctedRRMs ?? (accepted[index - 1] ? a.originalRRMs : .nan)
                let correctedB = b.correctedRRMs ?? (accepted[index] ? b.originalRRMs : .nan)
                if correctedA.isFinite, correctedB.isFinite, (250...2500).contains(correctedA),
                   (250...2500).contains(correctedB), !a.rhythmAmbiguous, !b.rhythmAmbiguous {
                    correctedPairMask[index] = true
                    correctedDifferences.append(correctedB - correctedA)
                }
            }
        }
        func rms(_ values: [Double]) -> Double? {
            values.isEmpty ? nil : sqrt(values.reduce(0) { $0 + $1 * $1 } / Double(values.count))
        }
        let spans = PhysiologyQuality.union(rows.filter { proof($0) && validTiming($0) }.compactMap(\.verifiedSpan), start: lo, end: hi)
        let duration = spans.reduce(0) { $0 + $1.end - $1.start }
        let acceptedSpans = PhysiologyQuality.union(rows.filter { originalAccepted($0) && validTiming($0) }.compactMap(\.verifiedSpan), start: lo, end: hi)
        let acceptedDuration = acceptedSpans.reduce(0) { $0 + $1.end - $1.start }
        var gap = 0.0, through = lo
        for span in spans { gap = max(gap, span.start - through); through = span.end }
        gap = max(gap, hi - through)
        let validFraction = rows.isEmpty ? 0 : Double(accepted.filter { $0 }.count) / Double(rows.count)
        var events: [[String]: PhysiologyQuality.Correction] = [:]
        for row in rows { for event in row.corrections { events[[row.userId, row.deviceId, row.source, row.originalId, event.pass, event.id]] = event } }
        let affected = rows.filter { !$0.corrections.isEmpty || $0.correctedRRMs != nil }.count
        let correctionFraction = rows.isEmpty ? 0 : Double(affected) / Double(rows.count)
        let users = Set(rows.map(\.userId)), devices = Set(rows.map(\.deviceId))
        let sources = Set(rows.map(\.source)), modalities = Set(rows.map(\.modality))
        let firmware = Set(rows.map(\.deviceFirmware))
        let provenRows = rows.filter(proof)
        let endpointKeys = provenRows.map { [$0.userId, $0.deviceId, $0.source, $0.startBeatId!, $0.endBeatId!] }
        let reason: String?
        if alignedStart(start) != start { reason = "unaligned_window" }
        else if !["retrospective", "causal"].contains(computationMode) { reason = "invalid_computation_mode" }
        else if conflict { reason = "original_identity_conflict" }
        else if !policy.minimumObservedFraction.isFinite || !(0...1).contains(policy.minimumObservedFraction) ||
            !policy.minimumValidIntervalFraction.isFinite || !(0...1).contains(policy.minimumValidIntervalFraction) ||
            !policy.minimumAcceptedDurationFraction.isFinite || !(0...1).contains(policy.minimumAcceptedDurationFraction) ||
            !policy.maximumCorrectionFraction.isFinite || !(0...1).contains(policy.maximumCorrectionFraction) ||
            !policy.maximumGapSeconds.isFinite || policy.maximumGapSeconds < 0 || policy.minimumPairs < 1 { reason = "invalid_quality_policy" }
        else if rows.isEmpty { reason = "no_observations" }
        else if rows.contains(where: { $0.userId.isEmpty || $0.deviceId.isEmpty || $0.source.isEmpty || $0.originalId.isEmpty }) { reason = "missing_identity" }
        else if users.count != 1 || devices.count != 1 { reason = "owner_mismatch" }
        else if sources.count != 1 { reason = "source_switch" }
        else if firmware.count != 1 || Set(rows.map(\.decoderVersion)).count != 1 || Set(rows.map(\.clockVersion)).count != 1 { reason = "acquisition_version_switch" }
        else if modalities.count != 1 || !["ppg_ibi", "ecg_nn"].contains(rows[0].modality) { reason = "unsupported_modality" }
        else if !rows.contains(where: proof) { reason = "continuity_unverified" }
        else if Set(endpointKeys).count != endpointKeys.count { reason = "duplicate_interval_identity" }
        else if rows.contains(where: { !validTiming($0) }) { reason = "invalid_timing_metadata" }
        else if rows.contains(where: { $0.correctedRRMs != nil && $0.corrections.isEmpty }) { reason = "missing_correction_provenance" }
        else if spans.isEmpty { reason = "timing_coverage_unverified" }
        else if rows.contains(where: \.rhythmAmbiguous) { reason = "rhythm_ambiguity" }
        else if duration / 300 < policy.minimumObservedFraction { reason = "insufficient_observed_time" }
        else if gap > policy.maximumGapSeconds { reason = "acquisition_gap" }
        else if validFraction < policy.minimumValidIntervalFraction { reason = "insufficient_original_intervals" }
        else if acceptedDuration / 300 < policy.minimumAcceptedDurationFraction { reason = "insufficient_accepted_duration" }
        else if correctionFraction > policy.maximumCorrectionFraction { reason = "correction_burden" }
        else if observedDifferences.count < policy.minimumPairs { reason = "insufficient_original_pairs" }
        else { reason = nil }
        let epochs = context.filter { $0.start < hi && $0.end > lo }
        func available(_ epoch: PhysiologyQuality.ContextEpoch) -> Bool {
            epoch.qualified && (computationMode != "causal" || (epoch.availableAt.map { $0.isFinite && $0 <= hi } ?? false))
        }
        let states = Set(epochs.map { available($0) ? $0.state : "unknown" })
        let contextSpans = PhysiologyQuality.union(epochs.filter(available).map { .init($0.start, $0.end) }, start: lo, end: hi)
        let contextDuration = contextSpans.reduce(0) { $0 + $1.end - $1.start }
        let state = states.count == 1 ? states.first! : (states.isEmpty ? "unknown" : "mixed")
        let eligibleContext = ["sleep", "nap", "quiet_rest"].contains(state) && contextDuration >= 300 - 0.000001
        let baselineReason = reason ?? (eligibleContext ? nil :
            (["sleep", "nap", "quiet_rest"].contains(state) ? "context_coverage_insufficient" : "context_\(state)"))
        let hasCorrection = affected > 0
        return Result(start: start, end: start + seconds, userId: users.count == 1 ? users.first : nil,
            deviceId: devices.count == 1 ? devices.first : nil, deviceFirmware: firmware.count == 1 ? firmware.first! : nil,
            source: sources.count == 1 ? sources.first : nil,
            modality: modalities.count == 1 ? modalities.first : nil, inputRevision: inputRevision, computationMode: computationMode,
            algorithmVersion: algorithmVersion, qualityVersion: policy.version, metric: "rmssd", unit: "ms",
            observedRMSSD: reason == nil ? rms(observedDifferences) : nil,
            correctedRMSSD: reason == nil && hasCorrection && correctedDifferences.count >= policy.minimumPairs ? rms(correctedDifferences) : nil,
            sdnn: reason == nil ? HRVAnalyzer.sdnnRaw(rows.filter { originalAccepted($0) && inside($0) }.map(\.originalRRMs)) : nil,
            researchObservedRMSSD: users.count == 1 && devices.count == 1 && sources.count == 1 && modalities.count == 1 &&
                ["ppg_ibi", "ecg_nn"].contains(rows.first?.modality ?? "") && !conflict ? rms(observedDifferences) : nil,
            originalIds: rows.map(\.originalId), pairMask: pairMask, correctedPairMask: correctedPairMask,
            pairReasons: pairReasons, observedTimeFraction: duration / 300,
            observedSpans: spans,
            acceptedDurationSeconds: acceptedDuration, validIntervalFraction: validFraction,
            validPairCount: observedDifferences.count, correctedPairCount: correctedDifferences.count,
            correctedMethodVersion: hasCorrection ? "corrected-original-timeline-rmssd-v1" : nil,
            correctionPasses: Set(events.values.map(\.pass)).sorted(), maximumGapSeconds: gap,
            correctionFraction: correctionFraction, correctionEventCount: events.count,
            insertedEventCount: events.values.filter { $0.kind == "inserted" }.count,
            deletedEventCount: events.values.filter { $0.kind == "deleted" }.count,
            measurementValid: reason == nil, reason: reason, context: state,
            baselineEligible: reason == nil && eligibleContext, baselineReason: baselineReason,
            timingPrecisionSeconds: rows.map(\.timestampPrecisionSeconds).filter { $0.isFinite && $0 > 0 }.max(),
            decoderVersions: Set(rows.map(\.decoderVersion)).sorted(), clockVersions: Set(rows.map(\.clockVersion)).sorted())
    }
}
