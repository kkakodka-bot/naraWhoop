import CryptoKit
import Foundation
import WhoopProtocol
@testable import StrandAnalytics

/// S12 orchestration policy. Observation presence is not physiological validity.
enum ServerDaySwiftV3Sleep {
    typealias C = ServerDaySwiftContract
    typealias V = ServerDaySwiftV3Contract
    typealias H = ServerDaySwiftHistory
    typealias S = ServerDaySwiftV3Selection
    typealias T = ServerDaySwiftV3Thermal
    typealias P = ServerDaySwiftV3CoreProbe

    struct Bounds: Codable, Equatable {
        let start: Int
        let end: Int
        func overlaps(_ other: Bounds) -> Bool { start < other.end && other.start < end }
        func contains(_ ts: Int) -> Bool { start <= ts && ts < end }
    }
    struct Identity: Codable, Equatable {
        let id: String
        let original: Bounds
        let editEntity: String?
    }
    struct Staging: Codable, Equatable {
        let source: String
        let admissionMet: Bool
        let observedEpochs: [Int]
        let hrIDs: [String]
        let gravityIDs: [String]
        let unmasked: [StageSegment]
        let stages: [StageSegment]
    }
    struct Entry: Codable, Equatable {
        let identity: Identity
        let session: T.Session
        let isNap: Bool?
        let staging: Staging
        var bounds: Bounds { Bounds(start: session.start, end: session.end) }
    }
    struct Edit: Equatable {
        let row: C.JournalRow
        let original: Bounds
        let bounds: Bounds
        let isNap: Bool
        let dismissed: Bool
        let stages: [StageSegment]?
    }
    struct ResolvedSleep: Codable, Equatable {
        let input: V.Input
        let selection: V.Selection
        let thermal: T.Anchor
        let preparedDigest: String
        let automatic: [T.Session]
        let authoritative: Bool
        let entries: [Entry]
        let gaps: [String]
        var excludedMainSleepStarts: Set<Int> { Set(entries.filter { $0.isNap == true }.map { $0.session.start }) }
    }

    static func detectedIdentity(_ input: V.Input, _ bounds: Bounds) -> Identity {
        let key = "sleep-v1|\(input.identity.userId.uuidString.lowercased())|\(input.identity.sourceDeviceId.uuidString.lowercased())|\(bounds.start)"
        var bytes = Array(Insecure.MD5.hash(data: Data(key.utf8)))
        bytes[6] = (bytes[6] & 0x0f) | 0x30
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }
        let id = [hex[0..<4], hex[4..<6], hex[6..<8], hex[8..<10], hex[10..<16]].map { $0.joined() }.joined(separator: "-")
        return Identity(id: id, original: bounds, editEntity: nil)
    }

    static func parse(_ row: C.JournalRow) throws -> Edit {
        guard row.kind == .sleepEdit, !row.deleted, row.entity.hasPrefix("sleep:"),
              let id = UUID(uuidString: String(row.entity.dropFirst(6))),
              row.entity == "sleep:" + id.uuidString.lowercased() else { throw V.failure("s12_sleep_entity") }
        let p = row.payload
        try V.keys(p, required: "schemaVersion originalStart originalEnd start end isNap dismissed", optional: "stages")
        guard p["schemaVersion"] == .number(1), case .bool(let nap) = p["isNap"],
              case .bool(let dismissed) = p["dismissed"] else { throw V.failure("s12_sleep_payload") }
        func timestamp(_ key: String) throws -> Int {
            let n = try V.integer(p[key])
            guard (1...7_289_654_400).contains(n) else { throw V.failure("s12_sleep_timestamp") }
            return n
        }
        let original = try Bounds(start: timestamp("originalStart"), end: timestamp("originalEnd"))
        let bounds = try Bounds(start: timestamp("start"), end: timestamp("end"))
        guard original.end > original.start, bounds.end > bounds.start, bounds.end - bounds.start <= 172_800 else {
            throw V.failure("s12_sleep_interval")
        }
        var stages: [StageSegment]?
        if let value = p["stages"] {
            let array = try V.array(value) // Present null is not absence.
            guard array.count <= 5_760 else { throw V.failure("s12_sleep_stages_count") }
            var previous = bounds.start
            stages = try array.map { value in
                let s = try V.object(value)
                try V.keys(s, required: "start end stage")
                let lo = try V.integer(s["start"]), hi = try V.integer(s["end"]), stage = try V.string(s["stage"])
                guard lo >= previous, hi > lo, hi <= bounds.end, ["wake", "light", "deep", "rem"].contains(stage) else {
                    throw V.failure("s12_sleep_stage_interval")
                }
                previous = hi
                return StageSegment(start: lo, end: hi, stage: stage)
            }
        }
        return Edit(row: row, original: original, bounds: bounds, isNap: nap, dismissed: dismissed, stages: stages)
    }

    static func edits(_ input: V.Input, resolution: C.Resolution) throws -> [Edit] {
        var anchors: [String: Bounds] = [:]
        for row in input.journal where row.kind == .sleepEdit && row.userId == input.identity.userId
            && row.sourceDeviceId == input.identity.sourceDeviceId && row.effectiveDay <= input.day {
            // Validate the identity of tombstones as well, without inventing their removed payload.
            guard row.entity.hasPrefix("sleep:"), let uuid = UUID(uuidString: String(row.entity.dropFirst(6))),
                  row.entity == "sleep:" + uuid.uuidString.lowercased() else { throw V.failure("s12_sleep_entity") }
            if row.deleted { continue }
            let edit = try parse(row)
            if let old = anchors[row.entity], old != edit.original { throw V.failure("s12_original_anchor_changed") }
            anchors[row.entity] = edit.original
        }
        return try resolution.rows.filter { $0.kind == .sleepEdit && !$0.deleted }.map(parse).sorted { $0.row.revision > $1.row.revision }
    }

    static func staging(_ bounds: Bounds, loaded: S.Loaded, useV2: Bool, supplied: [StageSegment]? = nil,
                        automatic: [StageSegment]? = nil) -> Staging {
        let hr = loaded.hr.filter { bounds.contains($0.ts) && $0.bpm > 0 }
        let gravity = loaded.gravity.filter { bounds.contains($0.ts) }
        let epochs = Set((hr.map(\.ts) + gravity.map(\.ts)).map { ($0 - bounds.start) / 30 })
        let hrTimes = Set(hr.map(\.ts)), gravTimes = Set(gravity.map(\.ts))
        let admitted = useV2 ? hr.count >= 2 || gravity.count >= 2 : gravity.count >= 2
        let raw: [StageSegment]
        let stages: [StageSegment]
        let source: String
        if let automatic {
            source = "native_automatic"; raw = automatic; stages = automatic
        } else if let supplied {
            source = "journal_supplied"; raw = supplied; stages = supplied
        } else {
            source = useV2 ? "native_v2_restaged_observed_epochs" : "native_v1_restaged_observed_epochs"
            raw = admitted ? (useV2
                ? SleepStagerV2.stageSession(start: bounds.start, end: bounds.end, grav: loaded.gravity, hr: loaded.hr, rr: loaded.rr, resp: loaded.resp)
                : SleepStager.stageSession(start: bounds.start, end: bounds.end, grav: loaded.gravity, hr: loaded.hr, rr: loaded.rr, resp: loaded.resp)) : []
            stages = mask(raw, bounds: bounds, observed: epochs)
        }
        return Staging(source: source, admissionMet: admitted, observedEpochs: epochs.sorted(),
            hrIDs: loaded.evidence.streams["hr", default: []].filter { hrTimes.contains($0.ts) }.map(\.id),
            gravityIDs: loaded.evidence.streams["gravity", default: []].filter { gravTimes.contains($0.ts) }.map(\.id),
            unmasked: raw, stages: stages)
    }

    static func mask(_ native: [StageSegment], bounds: Bounds, observed: Set<Int>) -> [StageSegment] {
        var result: [StageSegment] = []
        for segment in native {
            var t = max(bounds.start, segment.start)
            while t < min(bounds.end, segment.end) {
                let epoch = (t - bounds.start) / 30
                let end = min(segment.end, bounds.end, bounds.start + (epoch + 1) * 30)
                if observed.contains(epoch) {
                    if let last = result.last, last.end == t, last.stage == segment.stage { result[result.count - 1].end = end }
                    else { result.append(StageSegment(start: t, end: end, stage: segment.stage)) }
                }
                t = end
            }
        }
        return result
    }

    /// The approved positive-overlap/latest-revision policy, independently exercisable at one-second boundaries.
    static func apply(_ edits: [Edit], detected: [SleepSession], input: V.Input, loaded: S.Loaded) -> (entries: [Entry], gaps: [String]) {
        let useV2 = loaded.evidence.effectiveConfig["useSleepStagerV2"] != .bool(false)
        var suppressed: [Bounds] = [], supplied: [Entry] = [], gaps: [String] = []
        for edit in edits.sorted(by: { $0.row.revision > $1.row.revision }) {
            suppressed.append(edit.original) // A losing or dismissed edit still suppresses its original.
            if edit.dismissed { continue }
            if supplied.contains(where: { $0.bounds.overlaps(edit.bounds) }) {
                gaps.append("overlapping_sleep_edits_latest_revision_wins"); continue
            }
            let evidence = staging(edit.bounds, loaded: loaded, useV2: useV2, supplied: edit.stages)
            if evidence.stages.isEmpty { gaps.append("edited_sleep_raw_staging_unavailable") }
            let asleep = evidence.stages.filter { $0.stage != "wake" }.reduce(0) { $0 + $1.end - $1.start }
            let s = SleepSession(start: edit.bounds.start, end: edit.bounds.end,
                efficiency: Double(asleep) / Double(edit.bounds.end - edit.bounds.start), stages: evidence.stages,
                restingHR: nil, avgHRV: nil, hrOnly: !loaded.gravity.contains { edit.bounds.contains($0.ts) })
            supplied.append(Entry(identity: Identity(id: String(edit.row.entity.dropFirst(6)), original: edit.original,
                editEntity: edit.row.entity), session: T.Session(s), isNap: edit.isNap, staging: evidence))
        }
        let kept = detected.compactMap { s -> Entry? in
            let b = Bounds(start: s.start, end: s.end)
            guard !suppressed.contains(where: { $0.start == b.start || $0.overlaps(b) }),
                  !supplied.contains(where: { $0.bounds.overlaps(b) }) else { return nil }
            return Entry(identity: detectedIdentity(input, b), session: T.Session(s), isNap: nil,
                staging: staging(b, loaded: loaded, useV2: useV2, automatic: s.stages))
        }
        return ((kept + supplied).sorted { ($0.session.start, $0.session.end) < ($1.session.start, $1.session.end) }, Array(Set(gaps)).sorted())
    }

    static func contextDigest(_ prepared: H.Prepared) throws -> String {
        struct Context: Encodable {
            let policy: C.Policy
            let baselines: [String: H.State]
            let need: Double
            let consistency: Double?
            let midpoint: Int?
        }
        return try C.digest(Context(policy: prepared.policy, baselines: prepared.baselinesBefore, need: prepared.needHours,
            consistency: prepared.consistency, midpoint: prepared.habitualMidsleepSec))
    }

    static func resolve(input: V.Input, prepared: H.Prepared, loaded: S.Loaded, thermal: T.Anchor) throws -> ResolvedSleep {
        let bounds = try V.validate(input)
        guard prepared.input == input.historyInput, loaded.evidence.bounds == bounds,
              let family = DeviceFamily.confirmedRegistryFamily(model: input.source.storeModel, brand: input.source.storeBrand),
              thermal.family == family.rawValue else { throw V.failure("s12_sleep_input_scope") }
        let config = loaded.evidence.effectiveConfig
        guard prepared.resolution.rows.allSatisfy({ [.profile, .config, .sleepEdit].contains($0.kind) || $0.deleted }),
              ["customHRZoneLowerBounds", "stepsManualCoefficient"].allSatisfy({ config[$0] == nil || config[$0] == .null }),
              ["journalContextEnabled", "cycleAwarenessEnabled", "daytimePersonalBaselineEnabled", "spo2CandidateDisplayEnabled"].allSatisfy({ config[$0] != .bool(true) }) else {
            throw V.failure("outside_s12_sleep_cycle_scope")
        }
        let edits = try edits(input, resolution: prepared.resolution)
        let automatic = try T.analyze(input, prepared: prepared, loaded: loaded, anchor: thermal)
        let resolved = apply(edits, detected: automatic.sleepSessions, input: input, loaded: loaded)
        return ResolvedSleep(input: input, selection: loaded.evidence, thermal: thermal, preparedDigest: try contextDigest(prepared),
            automatic: automatic.sleepSessions.map(T.Session.init), authoritative: !edits.isEmpty, entries: resolved.entries, gaps: resolved.gaps)
    }

    static func analyze(input: V.Input, prepared: H.Prepared, loaded: S.Loaded, thermal: T.Anchor,
                        resolved: ResolvedSleep) throws -> AnalyticsEngine.DayResult {
        guard resolved.input == input, prepared.input == input.historyInput, resolved.selection == loaded.evidence,
              resolved.thermal == thermal, resolved.preparedDigest == (try contextDigest(prepared)) else { throw V.failure("s12_sleep_context_changed") }
        if !resolved.authoritative { return try T.analyze(input, prepared: prepared, loaded: loaded, anchor: thermal) }
        let b = loaded.evidence.bounds, config = loaded.evidence.effectiveConfig
        let family = DeviceFamily.confirmedRegistryFamily(model: input.source.storeModel, brand: input.source.storeBrand)!
        func state(_ key: String) throws -> BaselineState? {
            let value = try prepared.baselinesBefore[key]!.native(); return value.usable ? value : nil
        }
        func flag(_ key: String, _ fallback: Bool) -> Bool { if case .bool(let v) = config[key] { return v }; return fallback }
        let before = try AnalyticsEngine.ProfileBaselines(hrv: state("hrv"), restingHR: state("resting_hr"), resp: state("resp"), skinTemp: state("skin_temp"))
        return AnalyticsEngine.analyzeDay(day: input.day, hr: loaded.hr, rr: loaded.rr, resp: loaded.resp,
            gravity: loaded.gravity, steps: loaded.steps, dayHr: loaded.hr.filter { b.dayRange.contains($0.ts) },
            daySteps: loaded.steps.filter { b.dayRange.contains($0.ts) }, dayGravity: loaded.gravity.filter { b.dayRange.contains($0.ts) },
            skinTemp: loaded.skinTemp, skinTempFamily: family, skinTempAnchorRaw: thermal.resolvedRaw, spo2: loaded.spo2,
            profile: try profile(loaded.evidence), baselines: before, maxHROverride: try C.number(config, "maxHR"), tzOffsetSeconds: b.tzOffsetSeconds,
            wristOff: AnalyticsEngine.offWristIntervals(events: loaded.events, windowEnd: b.nightHi),
            sleepNeedHours: prepared.needHours, sleepConsistency: prepared.consistency, habitualMidsleepSec: prepared.habitualMidsleepSec,
            bandSleepState: loaded.bandState.map { ($0.ts, $0.state) }, useSleepStagerV2: flag("useSleepStagerV2", true),
            useMotionAwareWake: flag("useMotionAwareWake", family != .whoop4),
            deepHrvWindow: flag("deepHrvWindow", false), effortMethod: prepared.policy.effortMethod == "BANISTER" ? .banister : .edwards,
            resolvedSleep: resolved.entries.map { $0.session.native }, excludedMainSleepStarts: resolved.excludedMainSleepStarts,
            localDayBounds: b.dayRange, timezone: TimeZone(identifier: input.timezone))
    }

    static func profile(_ selection: V.Selection) throws -> UserProfile {
        let p = selection.effectiveProfile
        return try UserProfile(weightKg: V.number(p["weightKg"]), heightCm: V.number(p["heightCm"]), age: V.number(p["age"]),
            sex: V.string(p["sex"]), stepTicksPerStep: V.number(p["stepTicksPerStep"]))
    }

    static func mainIndices(_ result: AnalyticsEngine.DayResult, prepared: H.Prepared, resolved: ResolvedSleep) -> [Int] {
        let indices = result.sleepSessions.indices.filter { !resolved.excludedMainSleepStarts.contains(result.sleepSessions[$0].start) }
        let blocks = indices.map { SleepStageTotals.NightBlock(start: result.sleepSessions[$0].start, end: result.sleepSessions[$0].end) }
        return (SleepStageTotals.mainNightGroupIndices(blocks, offsetSec: resolved.selection.bounds.tzOffsetSeconds,
            habitualMidsleepSec: prepared.habitualMidsleepSec, timezone: TimeZone(identifier: resolved.input.timezone)) ?? []).map { indices[$0] }
    }

    static func sourceHashes() throws -> [String: String] {
        var hashes = try ServerDaySwiftV3History.sourceHashes()
        for name in ["Sleep", "Cycle", "SleepCycleTests"] {
            let path = "Packages/StrandAnalytics/Tests/StrandAnalyticsTests/ServerDaySwiftV3\(name).swift"
            hashes[path] = SHA256.hash(data: try Data(contentsOf: P.repository.appendingPathComponent(path))).map { String(format: "%02x", $0) }.joined()
        }
        return hashes
    }
}
