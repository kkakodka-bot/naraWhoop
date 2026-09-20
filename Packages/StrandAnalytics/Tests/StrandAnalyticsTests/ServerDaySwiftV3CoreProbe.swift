import CryptoKit
import Foundation
import WhoopProtocol
import WhoopStore
@testable import StrandAnalytics

enum ServerDaySwiftV3CoreProbe {
    typealias V = ServerDaySwiftV3Contract
    typealias C = ServerDaySwiftContract
    typealias H = ServerDaySwiftHistory
    static let artifactSchemaVersion = 1
    static let artifactRecipe = "s10-actual-swift-core-probe-v1"
    static let artifactMode = "core_probe_not_server_day"

    struct Prior: Codable, Equatable {
        let caseId: String
        let inputDigest: String
        let checkpoint: H.Checkpoint
    }
    struct History: Codable, Equatable {
        let baselinesBefore: [String: H.State]
        let needHours: Double
        let consistency: Double?
        let habitualMidsleepSec: Int?
        let reusedCheckpoint: Bool
        let checkpoint: H.Checkpoint
    }
    struct Outcome: Codable, Equatable {
        let input: V.Input
        let selection: V.Selection
        let result: C.JSON
        let history: History
        let mainNightIndices: [Int]
        let physiologySessionIndices: [Int]
        let hrvWindows: C.JSON
        var prior: Prior {
            get throws { Prior(caseId: input.id, inputDigest: try C.digest(input), checkpoint: history.checkpoint) }
        }
    }
    struct Artifact: Codable, Equatable {
        let schemaVersion: Int
        let producer: String
        let recipe: String
        let mode: String
        let sourceRevision: String
        let sourceHashes: [String: String]
        let cases: [Outcome]
    }

    static func run(_ input: V.Input, history: [Prior] = [], predecessor: H.Checkpoint? = nil) async throws -> Outcome {
        let bounds = try V.validate(input)
        guard input.historyCaseIds == history.map(\.caseId), Set(history.map(\.caseId)).count == history.count,
              history.allSatisfy({ $0.inputDigest.utf8.count == 64 && $0.inputDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) }) else { throw V.failure("history_case_lineage") }
        let prepared = try H.prepare(input.historyInput, history: history.map { $0.checkpoint.observation }, predecessor: predecessor)
        let config = prepared.resolution.payload(.config)
        guard prepared.resolution.rows.allSatisfy({ $0.kind == .profile || $0.kind == .config || $0.deleted }),
              config["dayCycleMode"] == nil || config["dayCycleMode"] == .string("midnight"),
              ["customHRZoneLowerBounds", "stepsManualCoefficient"].allSatisfy({ config[$0] == nil || config[$0] == .null }),
              ["journalContextEnabled", "cycleAwarenessEnabled", "daytimePersonalBaselineEnabled", "spo2CandidateDisplayEnabled"].allSatisfy({ config[$0] != .bool(true) }) else {
            throw V.failure("outside_core_probe_scope")
        }
        let family = input.source.registryFamily?.lowercased()
        guard family.map({ ServerDaySwiftV3Selection.modernFamilies.contains($0) || ServerDaySwiftV3Selection.legacyFamilies.contains($0) }) == true,
              input.source.storeBrand.caseInsensitiveCompare("WHOOP") == .orderedSame else { throw V.failure("core_requires_known_whoop_family") }
        // Only selected thermal rows require S11; retained future/foreign evidence is not composed.
        if family.map(ServerDaySwiftV3Selection.legacyFamilies.contains) == true,
           prepared.resolution.raw.contains(where: { $0.stream == .skinTemp }) { throw V.failure("whoop4_thermal_requires_s11") }
        let seed = try await ServerDaySwiftV3Selection.seed(input)
        let loaded = try await ServerDaySwiftV3Selection.load(seed)
        let native = try analyze(input, prepared: prepared, loaded: loaded)
        let sessions = native.sleepSessions
        let main = SleepStageTotals.mainNightGroupIndices(sessions.map { .init(start: $0.start, end: $0.end) },
            offsetSec: bounds.tzOffsetSeconds, habitualMidsleepSec: prepared.habitualMidsleepSec,
            timezone: TimeZone(identifier: input.timezone)) ?? []
        let motionIndices = sessions.indices.filter { !sessions[$0].hrOnly }
        let physiology = motionIndices.isEmpty ? Array(sessions.indices) : motionIndices
        var measurements = H.Measurements()
        measurements.values = ["hrv": native.daily.avgHrv, "resting_hr": native.daily.restingHr.map(Double.init),
            "resp": native.daily.respRateBpm, "skin_temp": native.nightlySkinTempC, "strain": native.strain].compactMapValues { $0 }
        func asleep(_ s: SleepSession) -> Double? {
            guard !s.stages.isEmpty else { return nil }
            return Double(s.stages.filter { ["light", "deep", "rem"].contains($0.stage) }.reduce(0) { $0 + $1.end - $1.start }) / 60
        }
        measurements.sleep = sessions.map { H.SleepBlock(start: $0.start, end: $0.end, asleepMin: asleep($0)) }
        measurements.mainSleepMin = native.daily.totalSleepMin
        measurements.napSleepMin = sessions.indices.filter { !main.contains($0) }.compactMap { asleep(sessions[$0]) }.reduce(0, +)
        let checkpoint = try H.finish(prepared, measurements: measurements)
        let windows: [C.JSON] = try physiology.flatMap { index in
            let s = sessions[index]
            return try SleepStager.sessionHrvWindows(start: s.start, end: s.end, rr: loaded.rr, stages: s.stages).map { window in
                C.JSON.object(["sessionStart": .number(Double(s.start)), "start": .number(Double(window.startTs)),
                    "stage": .string(window.stage), "cleanBeats": .number(Double(window.cleanBeats)),
                    "rmssd": try reflect(window.rmssd as Any)])
            }
        }
        return Outcome(input: input, selection: loaded.evidence, result: try reflect(native),
            history: History(baselinesBefore: prepared.baselinesBefore, needHours: prepared.needHours,
                consistency: prepared.consistency, habitualMidsleepSec: prepared.habitualMidsleepSec,
                reusedCheckpoint: prepared.reusedCheckpoint, checkpoint: checkpoint),
            mainNightIndices: main, physiologySessionIndices: physiology, hrvWindows: .array(windows))
    }

    static func analyze(_ input: V.Input, prepared: H.Prepared, loaded: ServerDaySwiftV3Selection.Loaded) throws -> AnalyticsEngine.DayResult {
        let b = loaded.evidence.bounds, profile = loaded.evidence.effectiveProfile
        let config = loaded.evidence.effectiveConfig
        func state(_ key: String) throws -> BaselineState? {
            guard let encoded = prepared.baselinesBefore[key] else { throw V.failure("missing_baseline") }
            let s = try encoded.native(); return s.usable ? s : nil
        }
        func flag(_ key: String, default fallback: Bool) -> Bool {
            if case .bool(let v) = config[key] { return v }; return fallback
        }
        let family: DeviceFamily = ServerDaySwiftV3Selection.legacyFamilies.contains(input.source.registryFamily!.lowercased()) ? .whoop4 : .whoop5
        let p = try UserProfile(weightKg: V.number(profile["weightKg"]), heightCm: V.number(profile["heightCm"]),
            age: V.number(profile["age"]), sex: V.string(profile["sex"]), stepTicksPerStep: V.number(profile["stepTicksPerStep"]))
        let before = try AnalyticsEngine.ProfileBaselines(hrv: state("hrv"), restingHR: state("resting_hr"),
            resp: state("resp"), skinTemp: state("skin_temp"))
        let provided = loaded.gravity.isEmpty ? SleepStager.hrOnlySessions(hr: loaded.hr, rr: loaded.rr, resp: loaded.resp) : []
        return AnalyticsEngine.analyzeDay(day: input.day, hr: loaded.hr, rr: loaded.rr, resp: loaded.resp,
            gravity: loaded.gravity, steps: loaded.steps, dayHr: loaded.hr.filter { b.dayRange.contains($0.ts) },
            daySteps: loaded.steps.filter { b.dayRange.contains($0.ts) }, dayGravity: loaded.gravity.filter { b.dayRange.contains($0.ts) },
            skinTemp: loaded.skinTemp, skinTempFamily: family, spo2: loaded.spo2, profile: p, baselines: before,
            maxHROverride: try C.number(config, "maxHR"), tzOffsetSeconds: b.tzOffsetSeconds,
            wristOff: AnalyticsEngine.offWristIntervals(events: loaded.events, windowEnd: b.nightHi),
            sleepNeedHours: prepared.needHours, sleepConsistency: prepared.consistency, habitualMidsleepSec: prepared.habitualMidsleepSec,
            bandSleepState: loaded.bandState.map { ($0.ts, $0.state) },
            useSleepStagerV2: flag("useSleepStagerV2", default: true), useMotionAwareWake: flag("useMotionAwareWake", default: family != .whoop4),
            providedSleep: provided, deepHrvWindow: flag("deepHrvWindow", default: false),
            effortMethod: prepared.policy.effortMethod == "BANISTER" ? .banister : .edwards,
            localDayBounds: b.dayRange, timezone: TimeZone(identifier: input.timezone))
    }

    // Reflect stored fields only, including nils. This avoids dropping new native DayResult members.
    // Unsupported runtime types throw instead of being stringified or omitted.
    static func reflect(_ value: Any) throws -> C.JSON {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            return try mirror.children.first.map { try reflect($0.value) } ?? .null
        }
        if let v = value as? Bool { return .bool(v) }
        if let v = value as? String { return .string(v) }
        if let v = value as? Int { return .number(Double(v)) }
        if let v = value as? Double { guard v.isFinite else { throw V.failure("nonfinite_output") }; return .number(v) }
        if let v = value as? any RawRepresentable { return try reflect(v.rawValue) }
        if mirror.displayStyle == .collection { return .array(try mirror.children.map { try reflect($0.value) }) }
        if mirror.displayStyle == .dictionary {
            var result: [String: C.JSON] = [:]
            for child in mirror.children {
                let pair = Array(Mirror(reflecting: child.value).children)
                let key: String
                if let s = pair[0].value as? String { key = s }
                else if let i = pair[0].value as? Int { key = String(i) }
                else { throw V.failure("output_dictionary_key") }
                guard result[key] == nil else { throw V.failure("output_dictionary_collision") }
                result[key] = try reflect(pair[1].value)
            }
            return .object(result)
        }
        if mirror.displayStyle == .struct {
            var result: [String: C.JSON] = [:]
            for child in mirror.children {
                guard let key = child.label else { throw V.failure("output_member") }
                result[key] = try reflect(child.value)
            }
            return .object(result)
        }
        throw V.failure("unsupported_output_type:\(type(of: value))")
    }

    static func validateArtifact(_ artifact: Artifact) throws {
        guard artifact.schemaVersion == artifactSchemaVersion, artifact.recipe == artifactRecipe,
              artifact.mode == artifactMode, artifact.producer == "actual-swift",
              !artifact.cases.isEmpty, Set(artifact.cases.map { $0.input.id }).count == artifact.cases.count,
              !artifact.sourceHashes.isEmpty else { throw V.failure("probe_artifact") }
    }

    static var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    static func sourceHashes() throws -> [String: String] {
        var paths: [URL] = []
        for package in ["StrandAnalytics", "WhoopProtocol", "WhoopStore"] {
            let directory = repository.appendingPathComponent("Packages/\(package)")
            paths.append(directory.appendingPathComponent("Package.swift"))
            let resolved = directory.appendingPathComponent("Package.resolved")
            if FileManager.default.fileExists(atPath: resolved.path) { paths.append(resolved) }
            guard let scan = FileManager.default.enumerator(at: directory.appendingPathComponent("Sources"), includingPropertiesForKeys: [.isRegularFileKey]) else {
                throw V.failure("source_inventory")
            }
            for case let file as URL in scan where file.pathExtension == "swift" { paths.append(file) }
        }
        let tests = repository.appendingPathComponent("Packages/StrandAnalytics/Tests/StrandAnalyticsTests")
        for name in ["ServerDaySwiftContract", "ServerDaySwiftHistory", "ServerDaySwiftHistoryTests",
                     "ServerDaySwiftV3Contract", "ServerDaySwiftV3Selection", "ServerDaySwiftV3CoreProbe",
                     "ServerDaySwiftV3ContractTests", "ServerDaySwiftV3SelectionTests", "ServerDaySwiftV3CoreProbeTests"] {
            paths.append(tests.appendingPathComponent(name + ".swift"))
        }
        for version in ["v1", "v2"] {
            paths.append(repository.appendingPathComponent("Tests/Fixtures/w4-whole-day-swift-\(version)/manifest.json"))
        }
        return try Dictionary(uniqueKeysWithValues: paths.map { file in
            (String(file.path.dropFirst(repository.path.count + 1)), SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined())
        })
    }
}
