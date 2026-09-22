import Foundation
import WhoopProtocol

/// Evidence shared by measurement and state models. State labels never decide signal validity.
public enum PhysiologyQuality {
    public struct Span: Codable, Equatable, Sendable {
        public let start: Double
        public let end: Double
        public init(_ start: Double, _ end: Double) { self.start = start; self.end = end }
    }
    public struct Correction: Codable, Equatable, Sendable {
        public let id: String
        public let pass: String
        public let kind: String
        public init(id: String, pass: String, kind: String) { self.id = id; self.pass = pass; self.kind = kind }
    }
    public struct IntervalObservation: Codable, Equatable, Sendable {
        public let originalId: String
        public let userId: String
        public let deviceId: String
        public let deviceFirmware: String?
        public let source: String
        public let modality: String
        public let eventTime: Double
        public let originalRRMs: Double
        public let startBeatId: String?
        public let endBeatId: String?
        public let continuityGroup: String?
        /// Only a verified clock/beat adapter may populate this span. Never reconstructed from mean HR.
        public let verifiedSpan: Span?
        public let timestampPrecisionSeconds: Double
        public let decoderVersion: String
        public let clockVersion: String
        public let packetId: String?
        public let ordinal: Int?
        public var originalAccepted: Bool = true
        public var startBeatAccepted: Bool = true
        public var endBeatAccepted: Bool = true
        public var rhythmAmbiguous: Bool = false
        public var qualityReason: String?
        public var corrections: [Correction] = []
        public var correctedRRMs: Double?
        /// Nil means unavailable, never clean. Populate only from time-aligned, qualified signals.
        public var motionContaminated: Bool?
        public var contactAccepted: Bool?
        public var opticalQualityAccepted: Bool?
        public var detectorAgreementFraction: Double?

        public init(originalId: String, userId: String = "local", deviceId: String, source: String,
                    modality: String = "ppg_ibi", eventTime: Double, originalRRMs: Double,
                    startBeatId: String? = nil, endBeatId: String? = nil, continuityGroup: String? = nil,
                    verifiedSpan: Span? = nil, timestampPrecisionSeconds: Double = 1,
                    decoderVersion: String = "unknown", clockVersion: String = "unknown",
                    packetId: String? = nil, ordinal: Int? = nil, deviceFirmware: String? = nil) {
            self.originalId = originalId; self.userId = userId; self.deviceId = deviceId
            self.source = source; self.modality = modality; self.eventTime = eventTime
            self.originalRRMs = originalRRMs; self.startBeatId = startBeatId; self.endBeatId = endBeatId
            self.continuityGroup = continuityGroup; self.verifiedSpan = verifiedSpan
            self.timestampPrecisionSeconds = timestampPrecisionSeconds
            self.decoderVersion = decoderVersion; self.clockVersion = clockVersion
            self.packetId = packetId; self.ordinal = ordinal
            self.deviceFirmware = deviceFirmware
        }
    }
    public struct ContextEpoch: Codable, Equatable, Sendable {
        public let start: Double
        public let end: Double
        /// sleep, nap, quiet_rest, active, transition, off_body or unknown. Independent of stage.
        public let state: String
        public let qualified: Bool
        public let availableAt: Double?
        public init(start: Double, end: Double, state: String, qualified: Bool, availableAt: Double? = nil) {
            self.start = start; self.end = end; self.state = state; self.qualified = qualified
            self.availableAt = availableAt
        }
    }

    public static func signalRejectionReason(_ row: IntervalObservation) -> String? {
        PhoneComputeRuntime.entered("swift.PhysiologyQuality.signalRejectionReason")
        if row.motionContaminated == true { return "motion_contamination" }
        if row.contactAccepted == false { return "contact_rejected" }
        if row.opticalQualityAccepted == false { return "optical_quality_rejected" }
        if let agreement = row.detectorAgreementFraction {
            if !agreement.isFinite || !(0...1).contains(agreement) { return "invalid_detector_evidence" }
            if agreement < 0.90 { return "detector_disagreement" }
        }
        return nil
    }

    /// A rejected original beat stays rejected on both sides of an event-time window boundary.
    public static func propagatingEndpointRejections(_ observations: [IntervalObservation]) -> [IntervalObservation] {
        guard PhoneComputeRuntime.permitsLocal("swift.PhysiologyQuality.propagatingEndpointRejections") else { return [] }
        PhoneComputeRuntime.entered("swift.PhysiologyQuality.propagatingEndpointRejections")
        var rejected = Set<[String]>()
        for row in observations {
            if let beat = row.startBeatId, !row.startBeatAccepted { rejected.insert([row.userId, row.deviceId, row.source, beat]) }
            if let beat = row.endBeatId, !row.endBeatAccepted { rejected.insert([row.userId, row.deviceId, row.source, beat]) }
        }
        guard !rejected.isEmpty else { return observations }
        var originals: [[String]: IntervalObservation] = [:]
        var conflicts = Set<[String]>()
        for row in observations {
            let key = [row.userId, row.deviceId, row.source, row.originalId]
            if let prior = originals[key], prior != row { conflicts.insert(key) }
            else { originals[key] = row }
        }
        return observations.map { row in
            if conflicts.contains([row.userId, row.deviceId, row.source, row.originalId]) { return row }
            var result = row
            result.startBeatAccepted = row.startBeatAccepted && !rejected.contains([row.userId, row.deviceId, row.source, row.startBeatId ?? ""])
            result.endBeatAccepted = row.endBeatAccepted && !rejected.contains([row.userId, row.deviceId, row.source, row.endBeatId ?? ""])
            return result
        }
    }

    /// Engineering ambiguity screen, not a rhythm diagnosis or an upper HRV bound.
    public static func hasAmbiguousAlternation(_ observations: [IntervalObservation]) -> Bool {
        PhoneComputeRuntime.entered("swift.PhysiologyQuality.hasAmbiguousAlternation")
        let rows = observations.sorted { ($0.verifiedSpan?.start ?? $0.eventTime) < ($1.verifiedSpan?.start ?? $1.eventTime) }
        func usable(_ row: IntervalObservation) -> Bool {
            guard let span = row.verifiedSpan else { return false }
            return row.originalAccepted && row.startBeatAccepted && row.endBeatAccepted &&
                row.originalRRMs.isFinite && (250...2500).contains(row.originalRRMs) &&
                span.start.isFinite && span.end.isFinite && span.end > span.start &&
                abs(span.end - span.start - row.originalRRMs / 1000) <= 0.002001 &&
                row.timestampPrecisionSeconds.isFinite && row.timestampPrecisionSeconds > 0 && row.timestampPrecisionSeconds <= 0.020
        }
        func adjacent(_ a: IntervalObservation, _ b: IntervalObservation) -> Bool {
            usable(a) && usable(b) && a.userId == b.userId && a.deviceId == b.deviceId && a.source == b.source &&
                a.deviceFirmware == b.deviceFirmware && a.clockVersion == b.clockVersion && a.decoderVersion == b.decoderVersion &&
                a.continuityGroup != nil && a.continuityGroup == b.continuityGroup && a.endBeatId != nil &&
                a.endBeatId == b.startBeatId && a.startBeatId != b.endBeatId &&
                abs(a.verifiedSpan!.end - b.verifiedSpan!.start) <= 0.000001
        }
        guard rows.count > 2 else { return false }
        var run = 0
        for i in 2..<rows.count {
            let a = rows[i - 2], b = rows[i - 1], c = rows[i]
            let x = b.originalRRMs - a.originalRRMs, y = c.originalRRMs - b.originalRRMs
            let scale = (a.originalRRMs + b.originalRRMs + c.originalRRMs) / 3
            if adjacent(a, b) && adjacent(b, c) && x * y < 0 && min(abs(x), abs(y)) > max(250, 0.35 * scale) {
                run += 1
                if run >= 20 { return true }
            } else { run = 0 }
        }
        return false
    }

    public static func legacy(_ rows: [RRInterval], deviceId: String) -> [IntervalObservation] {
        rows.map { row in
            IntervalObservation(originalId: "legacy:\(row.ts):\(row.rrMs):\(row.seq)", deviceId: deviceId,
                source: "channel:\(row.srcChannel?.rawValue ?? -1)", eventTime: Double(row.ts),
                originalRRMs: Double(row.rrMs), ordinal: row.ord)
        }
    }

    /// The production receipt path: IDs and original positions derive from checked retained bytes.
    /// No supplied word list, acceptance claim or timing span is trusted from an uploaded record.
    public static func checkedPackets(_ packets: [RRPacketProvenance], deviceId: String,
                                      userId: String = "local", deviceFirmware: String? = nil) -> [IntervalObservation] {
        packets.flatMap { packet in packet.words.map { word in
            var row = IntervalObservation(originalId: "\(packet.packetId):interval:\(word.index)", userId: userId,
                deviceId: deviceId, source: "whoop5_history", eventTime: Double(packet.ts), originalRRMs: Double(word.rrMs),
                startBeatId: "\(packet.packetId):beat:\(word.index)", endBeatId: "\(packet.packetId):beat:\(word.index + 1)",
                continuityGroup: packet.packetId, timestampPrecisionSeconds: packet.timestampPrecisionSeconds,
                decoderVersion: packet.decoderVersion, clockVersion: packet.clockVersion, packetId: packet.packetId,
                ordinal: word.index, deviceFirmware: deviceFirmware)
            if word.rawTicks == 0 { row.originalAccepted = false; row.startBeatAccepted = false; row.endBeatAccepted = false; row.qualityReason = "zero_original_word" }
            return row
        } }
    }

    /// Keep packet-local originals and separate standard candidates for per-window qualification.
    /// Unmatched historical rows stay unknown; coarse seconds cannot assign them to packet words.
    public static func packetOrLegacy(_ packets: [RRPacketProvenance], legacy rows: [RRInterval],
                                      deviceId: String, userId: String = "local") -> [IntervalObservation]? {
        let observed = checkedPackets(packets, deviceId: deviceId, userId: userId)
        guard observed.contains(where: { $0.originalRRMs > 0 }) else { return nil }
        let packetTimes = Set(observed.map { Int($0.eventTime) })
        let unknown = rows.filter { $0.srcChannel == .whoop5Standard ||
            ($0.srcChannel == .whoop5Historical && !packetTimes.contains($0.ts)) }.map { row in
            IntervalObservation(originalId: "legacy:\(row.ts):\(row.rrMs):\(row.seq)", userId: userId,
                deviceId: deviceId, source: row.srcChannel == .whoop5Historical ? "whoop5_history" : "channel:7", eventTime: Double(row.ts),
                originalRRMs: Double(row.rrMs), ordinal: row.ord)
        }
        return observed + unknown
    }

    /// Final binary state, not a deep/light eligibility rule. Shadow inference is not PSG truth.
    public static func contextFromSleep(stages: [StageSegment], start: Int, end: Int,
                                        episodeType: String? = nil) -> [ContextEpoch] {
        guard PhoneComputeRuntime.permitsLocal("swift.PhysiologyQuality.contextFromSleep") else { return [] }
        PhoneComputeRuntime.entered("swift.PhysiologyQuality.contextFromSleep")
        return SleepStageSemantics.normalized(stages, start: start, end: end).map { segment in
            let state: String
            if SleepStageSemantics.isSleep(segment) { state = episodeType == "nap" ? "nap" : "sleep" }
            else if segment.state == "off_body" { state = "off_body" }
            else if SleepStageSemantics.isKnownState(segment) { state = "awake" }
            else { state = "unknown" }
            return ContextEpoch(start: Double(segment.start), end: Double(segment.end), state: state,
                qualified: state != "unknown", availableAt: segment.computationMode == "causal" ? Double(segment.end) : nil)
        }
    }

    /// Packet-local order is known for checked WHOOP5 history. Coarse packet time gives no measured
    /// duration support and cannot prove a connection to the next packet. Keep those facts separate.
    public static func historicalPacket(_ frame: ParsedFrame, packetId: String,
                                         deviceId: String, userId: String = "local") -> [IntervalObservation] {
        guard frame.ok, frame.crcOK == true, frame.typeName == "HISTORICAL_DATA",
              frame.parsed["rr_source_channel"]?.intValue == 5,
              frame.parsed["hist_version"]?.intValue == 18,
              let timestamp = frame.parsed["unix"]?.intValue,
              let values = frame.parsed["rr_intervals"]?.intArrayValue,
              let count = frame.parsed["rr_count"]?.intValue, (1...4).contains(count), count == values.count,
              frame.parsed["rr_raw_ticks"]?.intArrayValue?.count == count,
              !packetId.isEmpty else { return [] }
        return values.enumerated().map { index, value in
            IntervalObservation(originalId: "\(packetId):interval:\(index)", userId: userId,
                deviceId: deviceId, source: "whoop5_history", eventTime: Double(timestamp),
                originalRRMs: Double(value), startBeatId: "\(packetId):beat:\(index)",
                endBeatId: "\(packetId):beat:\(index + 1)", continuityGroup: packetId,
                decoderVersion: "whoop5-ticks-1024-v1", clockVersion: "sensor-second-unmapped",
                packetId: packetId, ordinal: index)
        }
    }

    static func union(_ spans: [Span], start: Double, end: Double) -> [Span] {
        let finite = spans.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
        let bounded = finite.map { Span(max(start, $0.start), min(end, $0.end)) }
        let clipped = bounded.filter { $0.end > $0.start }.sorted { a, b in
            a.start == b.start ? a.end < b.end : a.start < b.start
        }
        var result: [Span] = []
        for span in clipped {
            if let last = result.last, span.start <= last.end {
                result[result.count - 1] = Span(last.start, max(last.end, span.end))
            } else { result.append(span) }
        }
        return result
    }
}
