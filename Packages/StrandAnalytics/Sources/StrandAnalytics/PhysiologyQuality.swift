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

    /// Prefer proven packet-local originals without mixing standard BLE into historical ownership.
    /// Unmatched historical rows stay unknown; coarse seconds cannot assign them to packet words.
    public static func packetOrLegacy(_ packets: [RRPacketProvenance], legacy rows: [RRInterval],
                                      deviceId: String, userId: String = "local") -> [IntervalObservation]? {
        let observed = checkedPackets(packets, deviceId: deviceId, userId: userId)
        guard observed.contains(where: { $0.originalRRMs > 0 }) else { return nil }
        let packetTimes = Set(observed.map { Int($0.eventTime) })
        let unknown = rows.filter { $0.srcChannel == .whoop5Historical && !packetTimes.contains($0.ts) }.map { row in
            IntervalObservation(originalId: "legacy:\(row.ts):\(row.rrMs):\(row.seq)", userId: userId,
                deviceId: deviceId, source: "whoop5_history", eventTime: Double(row.ts),
                originalRRMs: Double(row.rrMs), ordinal: row.ord)
        }
        return observed + unknown
    }

    /// Final binary state, not a deep/light eligibility rule. Shadow inference is not PSG truth.
    public static func contextFromSleep(stages: [StageSegment], start: Int, end: Int,
                                        episodeType: String? = nil) -> [ContextEpoch] {
        SleepStageSemantics.normalized(stages, start: start, end: end).map { segment in
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
