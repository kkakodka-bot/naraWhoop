import Foundation
import GRDB
import WhoopProtocol
@testable import StrandAnalytics

/// S11 test-only raw re-execution oracle; no histogram-to-temperature formula.
enum ServerDaySwiftV3Thermal {
    typealias V = ServerDaySwiftV3Contract
    typealias C = ServerDaySwiftContract
    typealias H = ServerDaySwiftHistory
    typealias S = ServerDaySwiftV3Selection
    typealias P = ServerDaySwiftV3CoreProbe

    struct Session: Codable, Equatable {
        let start: Int
        let end: Int
        let efficiency: Double
        let stages: [StageSegment]
        let restingHR: Int?
        let avgHRV: Double?
        let hrOnly: Bool
        init(_ s: SleepSession) {
            start = s.start; end = s.end; efficiency = s.efficiency; stages = s.stages
            restingHR = s.restingHR; avgHRV = s.avgHRV; hrOnly = s.hrOnly
        }
        var native: SleepSession { .init(start: start, end: end, efficiency: efficiency, stages: stages,
            restingHR: restingHR, avgHRV: avgHRV, hrOnly: hrOnly) }
    }
    struct RawNight: Codable, Equatable {
        let hr: [HRSample]
        let skin: [SkinTempSample]
        let sessions: [Session]
        let hrIDs: [String]
        let skinIDs: [String]
    }
    struct Anchor: Codable, Equatable {
        let family: String
        let lo: Int?
        let hi: Int?
        let rows: [V.StoredIdentity]
        let inBandIDs: [String]
        let learnedRaw: Double?
        let resolvedRaw: Double?
    }
    struct RawCount: Codable, Equatable {
        let raw: Int
        let count: Int
    }
    struct RebasedNight: Codable, Equatable {
        let caseID: String
        let day: String
        let inputDigest: String
        let originalMean: Double?
        let mean: Double?
        let funnel: C.JSON
    }
    struct Evidence: Codable, Equatable {
        let anchor: Anchor
        let priorNights: [RebasedNight]
        let beforeState: H.State
    }

    static func lookback(_ input: V.Input) throws -> ClosedRange<Int> {
        let bounds = try V.validate(input), zone = TimeZone(identifier: input.timezone)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone; calendar.locale = Locale(identifier: "en_US_POSIX")
        guard let earlier = calendar.date(byAdding: .day, value: -20,
            to: Date(timeIntervalSince1970: Double(bounds.dayLo))) else { throw V.failure("thermal_calendar") }
        let day = C.dayKey(Int(earlier.timeIntervalSince1970), zone: zone)
        let localStart = try C.dayBounds(day, input.timezone).lowerBound
        return (localStart - 30 * 3_600)...bounds.dayHi
    }

    static func anchor(_ seed: S.Seed) async throws -> Anchor {
        let source = seed.input.source
        guard let family = DeviceFamily.confirmedRegistryFamily(model: source.storeModel, brand: source.storeBrand) else {
            throw V.failure("thermal_unknown_family")
        }
        guard family == .whoop4 else {
            return Anchor(family: family.rawValue, lo: nil, hi: nil, rows: [], inBandIDs: [], learnedRaw: nil, resolvedRaw: nil)
        }
        let bounds = try lookback(seed.input), device = seed.input.identity.sourceDeviceId.uuidString.lowercased()
        let rows = try await seed.store.registryWriter.read { db in
            try Row.fetchAll(db, sql: "SELECT rowid AS fixtureRowId,ts,raw FROM skinTempSample WHERE deviceId=? AND ts BETWEEN ? AND ? ORDER BY ts",
                arguments: [device, bounds.lowerBound, bounds.upperBound])
        }
        let identities: [V.StoredIdentity] = try rows.map { row in
            let rowid: Int64 = row["fixtureRowId"]
            guard let original = seed.rows[rowid], original.userId == seed.input.identity.userId,
                  original.sourceDeviceId == seed.input.identity.sourceDeviceId, original.stream == .skinTemp,
                  original.ts == row["ts"] as Int else { throw V.failure("thermal_row_identity") }
            return V.StoredIdentity(id: original.id, rowid: rowid, ts: original.ts, fields: original.fields)
        }
        let raws = rows.map { $0["raw"] as Int }
        let learned = Whoop4SkinTemp.deviceAnchorRaw(raws)
        return Anchor(family: family.rawValue, lo: bounds.lowerBound, hi: bounds.upperBound, rows: identities,
            inBandIDs: zip(identities, raws).filter { (Whoop4SkinTemp.wornMinRaw...Whoop4SkinTemp.wornMaxRaw).contains($0.1) }.map { $0.0.id },
            learnedRaw: learned, resolvedRaw: learned ?? Whoop4SkinTemp.anchorRaw)
    }

    static func rawNight(_ loaded: S.Loaded, sessions: [SleepSession]) -> RawNight {
        RawNight(hr: loaded.hr, skin: loaded.skinTemp, sessions: sessions.map(Session.init),
            hrIDs: loaded.evidence.streams["hr"]!.map(\.id), skinIDs: loaded.evidence.streams["skinTemp"]!.map(\.id))
    }

    static func funnel(_ night: RawNight, family: DeviceFamily, anchor: Double?) -> AnalyticsEngine.SkinTempFunnelDiagnostic {
        AnalyticsEngine.skinTempFunnel(night.sessions.map(\.native), hr: night.hr, skinTemp: night.skin,
            family: family, anchorRaw: anchor)
    }

    /// Diagnostic raw multiplicities after wear/window/ADC admission, BEFORE the anchor-dependent C gate.
    /// Never used to compute a mean or baseline; native funnel re-execution below is the independent oracle.
    static func wornInBedRawCounts(_ night: RawNight) -> [RawCount] {
        let worn = Set(night.hr.filter { (30...220).contains($0.bpm) }.map(\.ts))
        var counts: [Int: Int] = [:]
        for sample in night.skin where worn.contains(sample.ts)
            && (Whoop4SkinTemp.wornMinRaw...Whoop4SkinTemp.wornMaxRaw).contains(sample.raw)
            && night.sessions.contains(where: { sample.ts >= $0.start && sample.ts <= $0.end }) {
            counts[sample.raw, default: 0] += 1
        }
        return counts.keys.sorted().map { RawCount(raw: $0, count: counts[$0]!) }
    }

    static func prepare(_ prepared: H.Prepared, history: [ServerDaySwiftV3History.Record], anchor: Anchor) throws -> (H.Prepared, Evidence) {
        guard anchor.family == DeviceFamily.whoop4.rawValue else {
            return (prepared, Evidence(anchor: anchor, priorNights: [], beforeState: prepared.baselinesBefore["skin_temp"]!))
        }
        let eligible = history.filter { $0.body.checkpoint.policy.sourceEra == prepared.policy.sourceEra }
        var byDay: [String: RebasedNight] = [:]
        for record in eligible {
            guard DeviceFamily.confirmedRegistryFamily(model: record.body.input.source.storeModel,
                brand: record.body.input.source.storeBrand) == .whoop4 else { throw V.failure("thermal_family_changed_without_era") }
            let f = funnel(record.body.rawNight, family: .whoop4, anchor: anchor.resolvedRaw)
            let observation = record.body.checkpoint.observation
            byDay[observation.day] = RebasedNight(caseID: record.body.input.id, day: observation.day,
                inputDigest: record.inputDigest, originalMean: observation.measurements.values["skin_temp"],
                mean: f.mean, funnel: try P.reflect(f))
        }
        var state: BaselineState?
        let cfg = Baselines.metricCfg["skin_temp"]!
        for day in try C.days(from: eligible.first?.body.input.day ?? prepared.input.day, through: prepared.input.day).dropLast() {
            guard Double(try C.dayBounds(day, "UTC").lowerBound) >= prepared.policy.recoveryEpoch else { continue }
            state = Baselines.update(state, value: byDay[day]?.mean, cfg: cfg)
        }
        let thermal = H.State(state ?? Baselines.foldHistory([], cfg: cfg))
        var before = prepared.baselinesBefore; before["skin_temp"] = thermal
        let rebased = H.Prepared(input: prepared.input, resolution: prepared.resolution, policy: prepared.policy,
            history: prepared.history, eligibleHistory: prepared.eligibleHistory, baselinesBefore: before,
            needHours: prepared.needHours, consistency: prepared.consistency, habitualMidsleepSec: prepared.habitualMidsleepSec,
            reusedCheckpoint: prepared.reusedCheckpoint)
        return (rebased, Evidence(anchor: anchor, priorNights: eligible.compactMap { byDay[$0.body.input.day] }, beforeState: thermal))
    }

    static func analyze(_ input: V.Input, prepared: H.Prepared, loaded: S.Loaded, anchor: Anchor) throws -> AnalyticsEngine.DayResult {
        guard anchor.family == DeviceFamily.whoop4.rawValue else { return try P.analyze(input, prepared: prepared, loaded: loaded) }
        // S10 stays frozen. Only this WHOOP4 call needs the existing public anchorRaw argument.
        let b = loaded.evidence.bounds, profile = loaded.evidence.effectiveProfile, config = loaded.evidence.effectiveConfig
        func state(_ key: String) throws -> BaselineState? {
            let s = try prepared.baselinesBefore[key]!.native(); return s.usable ? s : nil
        }
        func flag(_ key: String, _ fallback: Bool) -> Bool { if case .bool(let v) = config[key] { return v }; return fallback }
        let p = try UserProfile(weightKg: V.number(profile["weightKg"]), heightCm: V.number(profile["heightCm"]),
            age: V.number(profile["age"]), sex: V.string(profile["sex"]), stepTicksPerStep: V.number(profile["stepTicksPerStep"]))
        let baselines = try AnalyticsEngine.ProfileBaselines(hrv: state("hrv"), restingHR: state("resting_hr"),
            resp: state("resp"), skinTemp: state("skin_temp"))
        let provided = loaded.gravity.isEmpty ? SleepStager.hrOnlySessions(hr: loaded.hr, rr: loaded.rr, resp: loaded.resp) : []
        return AnalyticsEngine.analyzeDay(day: input.day, hr: loaded.hr, rr: loaded.rr, resp: loaded.resp,
            gravity: loaded.gravity, steps: loaded.steps, dayHr: loaded.hr.filter { b.dayRange.contains($0.ts) },
            daySteps: loaded.steps.filter { b.dayRange.contains($0.ts) }, dayGravity: loaded.gravity.filter { b.dayRange.contains($0.ts) },
            skinTemp: loaded.skinTemp, skinTempFamily: .whoop4, skinTempAnchorRaw: anchor.resolvedRaw, spo2: loaded.spo2,
            profile: p, baselines: baselines, maxHROverride: try C.number(config, "maxHR"), tzOffsetSeconds: b.tzOffsetSeconds,
            wristOff: AnalyticsEngine.offWristIntervals(events: loaded.events, windowEnd: b.nightHi),
            sleepNeedHours: prepared.needHours, sleepConsistency: prepared.consistency, habitualMidsleepSec: prepared.habitualMidsleepSec,
            bandSleepState: loaded.bandState.map { ($0.ts, $0.state) }, useSleepStagerV2: flag("useSleepStagerV2", true),
            useMotionAwareWake: flag("useMotionAwareWake", false), providedSleep: provided,
            deepHrvWindow: flag("deepHrvWindow", false), effortMethod: prepared.policy.effortMethod == "BANISTER" ? .banister : .edwards,
            localDayBounds: b.dayRange, timezone: TimeZone(identifier: input.timezone))
    }
}
