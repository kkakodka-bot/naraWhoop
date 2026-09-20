import Foundation
import WhoopProtocol
import XCTest
@testable import StrandAnalytics

enum S11Fixtures {
    typealias V = ServerDaySwiftV3Contract
    typealias C = ServerDaySwiftContract
    typealias R = ServerDaySwiftV3History
    typealias F = S10Fixtures
    static func day(_ index: Int, start: String = "2026-01-01") throws -> String {
        C.dayKey(try C.dayBounds(start, "UTC").lowerBound + index * 86_400, zone: TimeZone(secondsFromGMT: 0)!)
    }
    static func input(_ day: String, zone: String = "UTC", whoop4: Bool = false, raw: Int? = nil,
                      skinCount: Int = 300, variation: Int = 40, config: [String: C.JSON] = [:]) throws -> V.Input {
        var input = try F.input("s11-\(day)", day: day, zone: zone,
            family: whoop4 ? "whoop4" : "whoop5", model: whoop4 ? "WHOOP 4.0" : "WHOOP 5.0")
        var flags: [String: C.JSON] = ["dayCycleMode": .string("midnight"), "useSleepStagerV2": .bool(false),
            "useMotionAwareWake": .bool(false), "effortMethod": .string("EDWARDS")]
        flags.merge(config) { _, new in new }
        input.journal[1] = F.journal(.config, 2, day: day, payload: flags)
        let lo = try V.validate(input).dayLo
        // Bounded raw density: 10-second original measurements, not synthetic daily observations.
        // The actual stager must establish sleep and HRV availability in native tests.
        for offset in stride(from: 0, through: 10_800, by: 10) {
            let ts = lo + offset
            append(&input, .hr, ts, ["bpm": .number(Double(52 + offset / 300 % 3))])
            append(&input, .rr, ts, F.rr(1_000 + [0, variation, 0, -variation][offset / 10 % 4], channel: whoop4 ? nil : 5))
            append(&input, .gravity, ts, ["x": .number(0), "y": .number(0), "z": .number(1)])
        }
        for index in 0..<skinCount {
            append(&input, .skinTemp, lo + 600 + index * 10, ["raw": .number(Double(raw ?? (whoop4 ? 1_290 : 3_300)))])
        }
        return input
    }
    static func append(_ input: inout V.Input, _ stream: C.Stream, _ ts: Int, _ fields: [String: C.JSON],
                       id: String? = nil, owner: UUID = F.owner, device: UUID = F.device) {
        F.append(&input, stream, ts, fields, id: id ?? "\(stream.rawValue)-\(ts)", owner: owner, device: device)
    }
    static func lineage(_ input: V.Input, _ history: [R.Record], addThermalLookback: Bool = false) throws -> V.Input {
        var input = input
        input.historyCaseIds = history.map { $0.body.input.id }
        if addThermalLookback {
            let range = try ServerDaySwiftV3Thermal.lookback(input)
            var timestamps = Set(input.raw.filter { $0.userId == F.owner && $0.sourceDeviceId == F.device && $0.stream == .skinTemp }.map(\.ts))
            for record in history {
                for row in record.body.input.raw where row.userId == F.owner && row.sourceDeviceId == F.device
                    && row.stream == .skinTemp && range.contains(row.ts) && row.ts < record.body.input.asOfExclusive {
                    if timestamps.insert(row.ts).inserted { input.raw.append(row) }
                }
            }
        }
        return input
    }
    static func run(_ input: V.Input, _ history: [R.Record] = [], warm: Bool = true, lookback: Bool = false) async throws -> R.Outcome {
        try await R.run(lineage(input, history, addThermalLookback: lookback), history: history,
            predecessor: warm ? history.last?.restart : nil)
    }
}

final class ServerDaySwiftV3HistoryTests: XCTestCase {
    private typealias F = S11Fixtures
    private typealias R = ServerDaySwiftV3History
    private typealias C = ServerDaySwiftContract
    private typealias V = ServerDaySwiftV3Contract
    private typealias H = ServerDaySwiftHistory
    private typealias P = ServerDaySwiftV3CoreProbe

    func testBoundedRawRecipeActuallyStagesAndMatchesFrozenS10Core() async throws {
        let input = try F.input("2026-06-15")
        let actual = try await R.run(input), reference = try await P.run(input)
        XCTAssertEqual(actual.record.body.result, reference.result)
        XCTAssertEqual(actual.record.body.selection, reference.selection)
        XCTAssertEqual(actual.record.body.checkpoint, reference.history.checkpoint)
        XCTAssertEqual(actual.record.body.mainNightIndices, reference.mainNightIndices)
        XCTAssertEqual(actual.record.body.hrvWindows, reference.hrvWindows)
        XCTAssertFalse(actual.record.body.rawNight.sessions.isEmpty)
        XCTAssertFalse(actual.record.body.rawNight.sessions.flatMap(\.stages).isEmpty)
        XCTAssertNotNil(actual.record.body.checkpoint.observation.measurements.values["hrv"])
        XCTAssertNotNil(actual.record.body.checkpoint.observation.measurements.values["skin_temp"])
        XCTAssertEqual(actual.record.body.input, input)
    }

    func test131ActualRawDaysAndOwnSerializedRestartAfterDay65() async throws {
        let hashes = try R.sourceHashes()
        var first: [R.Record] = []
        for index in 0..<131 {
            let input = try F.input(F.day(index), variation: 36 + index % 5 * 2)
            let output = try await F.run(input, first)
            XCTAssertEqual(output.reusedCheckpoint, index > 0)
            XCTAssertEqual(output.record.body.input.raw.count, 3_543)
            XCTAssertFalse(output.record.body.rawNight.sessions.isEmpty)
            XCTAssertNotNil(output.record.body.checkpoint.observation.measurements.values["hrv"])
            first.append(output.record)
        }
        let last = first.last!
        for (metric, cfg) in Baselines.metricCfg {
            let actual = Baselines.foldHistory(first.map { $0.body.checkpoint.observation.measurements.baselineValues[metric] }, cfg: cfg,
                rejectHardOutliers: metric != "readiness_hrv_ln")
            XCTAssertEqual(try last.body.checkpoint.baselinesAfter[metric]?.native(), actual, metric)
        }
        XCTAssertEqual(last.body.checkpoint.baselinesAfter["hrv"]?.nValid, 131)
        let restored = try JSONDecoder().decode([R.Record].self, from: C.bytes(Array(first.prefix(66))))
        var replay = restored
        for index in 66..<131 {
            let output = try await R.run(first[index].body.input, history: replay, predecessor: replay.last?.restart)
            XCTAssertEqual(output.record, first[index], "Own restart at raw day \(index)")
            replay.append(output.record)
        }
        for index in [0, 14, 65, 100, 130] {
            let cold = try await R.run(first[index].body.input, history: Array(first.prefix(index)))
            XCTAssertFalse(cold.reusedCheckpoint)
            XCTAssertEqual(cold.record, first[index], "Cold raw/history replay \(index)")
        }
        XCTAssertEqual(try R.sourceHashes(), hashes)
        try writeEvidence(first, hashes: hashes)
        print("S11 raw long-history: 131 actual days, 65 restarted suffix days, 5 cold checkpoints, \(hashes.count) source hashes stable")
    }

    func testRawCorrectionInvalidatesAndReexecutesBeyond100Days() async throws {
        var original: [R.Record] = [], corrected: [R.Record] = []
        for index in 0..<108 {
            let input = try F.input(F.day(index), variation: index % 2 == 0 ? 40 : 42)
            original.append(try await F.run(input, original).record)
            if index < 5 { corrected.append(original.last!) }
            else {
                let changed = try F.input(F.day(index), variation: index == 5 ? 52 : index % 2 == 0 ? 40 : 42)
                corrected.append(try await F.run(changed, corrected).record)
            }
        }
        XCTAssertEqual(Array(original.prefix(5)), Array(corrected.prefix(5)))
        XCTAssertNotEqual(original[5].inputDigest, corrected[5].inputDigest)
        XCTAssertNotEqual(original.last?.digest, corrected.last?.digest)
        XCTAssertNotEqual(original.last?.body.checkpoint.baselinesAfter["hrv"], corrected.last?.body.checkpoint.baselinesAfter["hrv"])
        let next = try F.lineage(F.input(F.day(108)), corrected)
        do { _ = try await R.run(next, history: corrected, predecessor: original.last?.restart); XCTFail("Stale raw-lineage checkpoint accepted") }
        catch { XCTAssertEqual(error as? C.Failure, .invalid("s10:s11_restart_lineage")) }
        let cold = try await R.run(corrected.last!.body.input, history: Array(corrected.dropLast()))
        XCTAssertEqual(cold.record, corrected.last)
        print("S11 correction: raw day5 changed, 103-day dependent suffix re-executed; old predecessor rejected")
    }

    func testMissingDaysEpochsSourceEraAndEffortChangesKeepColdWarmEqual() async throws {
        var history: [R.Record] = []
        for index in [0, 1, 2, 6, 7, 8, 12, 13] {
            var config: [String: C.JSON] = [:]
            if index >= 6 {
                config["hrvBaselineEpoch"] = .number(Double(try C.dayBounds(F.day(2), "UTC").lowerBound) + 0.5)
                config["recoveryBaselineEpoch"] = .number(Double(try C.dayBounds(F.day(1), "UTC").lowerBound))
            }
            if index >= 8 { config["effortMethod"] = .string("BANISTER") }
            if index >= 12 { config["sourceEra"] = .string("new-era") }
            let input = try F.lineage(F.input(F.day(index), config: config), history)
            let warm = try await R.run(input, history: history, predecessor: history.last?.restart)
            let cold = try await R.run(input, history: history)
            XCTAssertEqual(warm.record, cold.record, "Policy at day \(index)")
            if index == 6 { XCTAssertEqual(warm.record.body.checkpoint.observation.baselinesBefore["hrv"]?.nValid, 0) }
            if index == 12 { XCTAssertEqual(warm.record.body.checkpoint.observation.baselinesBefore["hrv"]?.nValid, 0) }
            history.append(warm.record)
        }
    }

    func testOwnRawFutureForeignRowsAndJournalsRetainedButDoNotAffectComputation() async throws {
        let original = try F.input("2026-06-15")
        let a = try await R.run(original)
        var changed = original
        F.append(&changed, .hr, changed.asOfExclusive, ["bpm": .number(180)], id: "future-hr")
        F.append(&changed, .rr, changed.asOfExclusive, S10Fixtures.rr(500, channel: 7), id: "future-rr")
        F.append(&changed, .skinTemp, changed.asOfExclusive - 1, ["raw": .number(4000)], id: "foreign-temp", owner: S10Fixtures.foreign)
        changed.journal.append(S10Fixtures.journal(.config, 3, day: "2026-06-16", payload: ["sourceEra": .string("future")]))
        let b = try await R.run(changed)
        XCTAssertEqual(b.record.body.result, a.record.body.result)
        XCTAssertEqual(b.record.body.checkpoint, a.record.body.checkpoint)
        XCTAssertEqual(b.record.body.selection.streams, a.record.body.selection.streams)
        XCTAssertEqual(b.record.body.input.raw.count, original.raw.count + 3)
        XCTAssertNotEqual(b.record.inputDigest, a.record.inputDigest)
        XCTAssertNotEqual(b.record.digest, a.record.digest)
    }

    func testRecordTamperingForeignHistoryAndUnsupportedScopesFailClosed() async throws {
        let first = try await R.run(F.input("2026-06-15")).record
        var object = try V.object(V.json(first))
        object["inputDigest"] = .string(String(repeating: "0", count: 64))
        XCTAssertThrowsError(try JSONDecoder().decode(R.Record.self, from: C.bytes(C.JSON.object(object))))
        let next = try F.lineage(F.input("2026-06-16"), [first])
        var foreign = next
        foreign.identity = C.Identity(userId: S10Fixtures.foreign, sourceDeviceId: next.identity.sourceDeviceId, algorithmVersion: next.identity.algorithmVersion)
        do { _ = try await R.run(foreign, history: [first]); XCTFail("Foreign lineage accepted") }
        catch { XCTAssertEqual(error as? C.Failure, .invalid("s10:s11_record_lineage")) }
        var intraday = next; intraday.asOfExclusive -= 1
        do { _ = try await R.run(intraday, history: [first]); XCTFail("Intraday fabricated") }
        catch { XCTAssertEqual(error as? C.Failure, .invalid("s10:intraday_unsupported")) }
        var unknown = try S10Fixtures.input(family: nil, model: "")
        S10Fixtures.append(&unknown, .rr, unknown.asOfExclusive - 1, S10Fixtures.rr(channel: nil))
        S10Fixtures.append(&unknown, .rr, unknown.asOfExclusive, S10Fixtures.rr(channel: 5))
        let seed = try await ServerDaySwiftV3Selection.seed(unknown), loaded = try await ServerDaySwiftV3Selection.load(seed)
        XCTAssertNotEqual(loaded.evidence.rrPolicy.serverWindowIDs, loaded.evidence.rrPolicy.shippedStoreIDs)
        do { _ = try await R.run(unknown); XCTFail("Unknown family relabelled") }
        catch { XCTAssertEqual(error as? C.Failure, .invalid("s10:s11_requires_known_whoop_family")) }
    }

    private func writeEvidence(_ records: [R.Record], hashes: [String: String]) throws {
        guard let directory = ProcessInfo.processInfo.environment["S11_EVIDENCE_DIRECTORY"] else { return }
        struct Evidence: Encodable {
            let schemaVersion = 1
            let recipe = "s11-actual-swift-history-probe-v1"
            let mode = "history_probe_not_server_day"
            let sourceHashes: [String: String]
            let records: [R.Record]
        }
        let root = URL(fileURLWithPath: directory).standardizedFileURL
        let resolved = root.resolvingSymlinksInPath()
        guard root == resolved, !root.path.hasPrefix(P.repository.path + "/"), root != P.repository,
              FileManager.default.fileExists(atPath: root.path) else { throw V.failure("s11_external_directory") }
        let path = root.appendingPathComponent("S11-actual-swift-131-raw-days.json")
        guard !FileManager.default.fileExists(atPath: path.path) else { throw V.failure("s11_immutable_evidence") }
        let bytes = try C.bytes(Evidence(sourceHashes: hashes, records: records))
        try bytes.write(to: path, options: .withoutOverwriting)
        XCTAssertEqual(try Data(contentsOf: path), bytes)
    }
}
