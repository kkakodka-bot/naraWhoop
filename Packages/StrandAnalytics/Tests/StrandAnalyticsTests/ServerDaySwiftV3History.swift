import CryptoKit
import Foundation
import WhoopProtocol
@testable import StrandAnalytics

/// S11 companion records retain original raw evidence; S09 observations remain immutable.
enum ServerDaySwiftV3History {
    typealias C = ServerDaySwiftContract
    typealias V = ServerDaySwiftV3Contract
    typealias H = ServerDaySwiftHistory
    typealias S = ServerDaySwiftV3Selection
    typealias P = ServerDaySwiftV3CoreProbe
    typealias T = ServerDaySwiftV3Thermal

    struct Body: Codable, Equatable {
        let input: V.Input
        let selection: V.Selection
        let result: C.JSON
        let rawNight: T.RawNight
        let thermal: T.Evidence
        let wornInBedRawCounts: [T.RawCount]
        let checkpoint: H.Checkpoint
        let consistency: Double?
        let habitualMidsleepSec: Int?
        let mainNightIndices: [Int]
        let hrvWindows: C.JSON
    }

    struct Record: Codable, Equatable {
        let body: Body
        let inputDigest: String
        let parentDigest: String?
        let digest: String
        private struct Seal: Codable { let body: Body; let inputDigest: String; let parentDigest: String? }
        fileprivate init(body: Body, parentDigest: String?) throws {
            self.body = body; self.parentDigest = parentDigest
            inputDigest = try C.digest(body.input)
            digest = try C.digest(Seal(body: body, inputDigest: inputDigest, parentDigest: parentDigest))
        }
        private enum CodingKeys: CodingKey { case body, inputDigest, parentDigest, digest }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let body = try c.decode(Body.self, forKey: .body)
            let inputDigest = try c.decode(String.self, forKey: .inputDigest)
            let parentDigest = try c.decodeIfPresent(String.self, forKey: .parentDigest)
            let digest = try c.decode(String.self, forKey: .digest)
            _ = try V.validate(body.input)
            guard inputDigest == (try C.digest(body.input)),
                  digest == (try C.digest(Seal(body: body, inputDigest: inputDigest, parentDigest: parentDigest))) else {
                throw V.failure("s11_record_digest")
            }
            self.body = body; self.inputDigest = inputDigest; self.parentDigest = parentDigest; self.digest = digest
        }
        var restart: Restart { Restart(checkpoint: body.checkpoint, lineageDigest: digest) }
    }
    struct Restart: Codable, Equatable {
        let checkpoint: H.Checkpoint
        let lineageDigest: String
    }
    struct Outcome: Equatable {
        let record: Record
        let reusedCheckpoint: Bool
    }

    static func run(_ input: V.Input, history: [Record] = [], predecessor: Restart? = nil) async throws -> Outcome {
        let bounds = try V.validate(input)
        guard input.historyCaseIds == history.map({ $0.body.input.id }), Set(input.historyCaseIds).count == history.count else {
            throw V.failure("s11_case_lineage")
        }
        var previous: String?
        for (index, record) in history.enumerated() {
            guard record.parentDigest == previous, record.body.input.identity == input.identity,
                  record.body.input.historyCaseIds == Array(input.historyCaseIds.prefix(index)),
                  record.body.checkpoint.identity == record.body.input.identity,
                  record.body.checkpoint.throughDay == record.body.input.day else { throw V.failure("s11_record_lineage") }
            previous = record.digest
        }
        if let predecessor {
            guard predecessor.lineageDigest == history.last?.digest, predecessor.checkpoint == history.last?.body.checkpoint else {
                throw V.failure("s11_restart_lineage")
            }
        }
        let prepared = try H.prepare(input.historyInput, history: history.map { $0.body.checkpoint.observation },
            predecessor: predecessor?.checkpoint)
        let config = prepared.resolution.payload(.config)
        guard config["dayCycleMode"] == .string("midnight"),
              prepared.resolution.rows.allSatisfy({ $0.kind == .profile || $0.kind == .config || $0.deleted }),
              ["customHRZoneLowerBounds", "stepsManualCoefficient"].allSatisfy({ config[$0] == nil || config[$0] == .null }),
              ["journalContextEnabled", "cycleAwarenessEnabled", "daytimePersonalBaselineEnabled", "spo2CandidateDisplayEnabled"].allSatisfy({ config[$0] != .bool(true) }) else {
            throw V.failure("outside_s11_scope")
        }
        let family = input.source.registryFamily?.lowercased()
        guard family.map({ S.modernFamilies.contains($0) || S.legacyFamilies.contains($0) }) == true,
              input.source.storeBrand.caseInsensitiveCompare("WHOOP") == .orderedSame else { throw V.failure("s11_requires_known_whoop_family") }
        let seed = try await S.seed(input), loaded = try await S.load(seed)
        let anchor = try await T.anchor(seed)
        let (thermalPrepared, evidence) = try T.prepare(prepared, history: history, anchor: anchor)
        let native = try T.analyze(input, prepared: thermalPrepared, loaded: loaded, anchor: anchor)
        let main = SleepStageTotals.mainNightGroupIndices(native.sleepSessions.map { .init(start: $0.start, end: $0.end) },
            offsetSec: bounds.tzOffsetSeconds, habitualMidsleepSec: prepared.habitualMidsleepSec,
            timezone: TimeZone(identifier: input.timezone)) ?? []
        let measured = measurements(native, main: main)
        let checkpoint = try H.finish(thermalPrepared, measurements: measured)
        let rawNight = T.rawNight(loaded, sessions: native.sleepSessions)
        let body = Body(input: input, selection: loaded.evidence, result: try P.reflect(native), rawNight: rawNight,
            thermal: evidence, wornInBedRawCounts: anchor.family == DeviceFamily.whoop4.rawValue ? T.wornInBedRawCounts(rawNight) : [],
            checkpoint: checkpoint, consistency: prepared.consistency, habitualMidsleepSec: prepared.habitualMidsleepSec,
            mainNightIndices: main, hrvWindows: try windows(native.sleepSessions, rr: loaded.rr))
        return Outcome(record: try Record(body: body, parentDigest: history.last?.digest), reusedCheckpoint: prepared.reusedCheckpoint)
    }

    static func measurements(_ native: AnalyticsEngine.DayResult, main: [Int]) -> H.Measurements {
        func asleep(_ s: SleepSession) -> Double? {
            guard !s.stages.isEmpty else { return nil }
            return Double(s.stages.filter { ["light", "deep", "rem"].contains($0.stage) }.reduce(0) { $0 + $1.end - $1.start }) / 60
        }
        let sessions = native.sleepSessions
        return H.Measurements(values: ["hrv": native.daily.avgHrv, "resting_hr": native.daily.restingHr.map(Double.init),
            "resp": native.daily.respRateBpm, "skin_temp": native.nightlySkinTempC, "strain": native.strain].compactMapValues { $0 },
            sleep: sessions.map { H.SleepBlock(start: $0.start, end: $0.end, asleepMin: asleep($0)) },
            mainSleepMin: native.daily.totalSleepMin,
            napSleepMin: sessions.indices.filter { !main.contains($0) }.compactMap { asleep(sessions[$0]) }.reduce(0, +))
    }

    private static func windows(_ sessions: [SleepSession], rr: [RRInterval]) throws -> C.JSON {
        let motion = sessions.filter { !$0.hrOnly }, physiology = motion.isEmpty ? sessions : motion
        return .array(try physiology.flatMap { s in
            try SleepStager.sessionHrvWindows(start: s.start, end: s.end, rr: rr, stages: s.stages).map { w in
                C.JSON.object(["sessionStart": .number(Double(s.start)), "start": .number(Double(w.startTs)),
                    "stage": .string(w.stage), "cleanBeats": .number(Double(w.cleanBeats)), "rmssd": try P.reflect(w.rmssd as Any)])
            }
        })
    }

    static func sourceHashes() throws -> [String: String] {
        var hashes = try P.sourceHashes()
        for name in ["History", "Thermal", "HistoryTests", "ThermalTests"] {
            let path = "Packages/StrandAnalytics/Tests/StrandAnalyticsTests/ServerDaySwiftV3\(name).swift"
            hashes[path] = SHA256.hash(data: try Data(contentsOf: P.repository.appendingPathComponent(path)))
                .map { String(format: "%02x", $0) }.joined()
        }
        return hashes
    }
}
