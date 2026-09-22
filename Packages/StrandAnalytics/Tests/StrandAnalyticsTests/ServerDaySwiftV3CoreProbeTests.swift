import Foundation
import XCTest
@testable import StrandAnalytics

final class ServerDaySwiftV3CoreProbeTests: XCTestCase {
    private typealias V = ServerDaySwiftV3Contract
    private typealias C = ServerDaySwiftContract
    private typealias H = ServerDaySwiftHistory
    private typealias P = ServerDaySwiftV3CoreProbe
    private typealias S = ServerDaySwiftV3Selection
    private typealias F = S10Fixtures

    func testActualAutomaticDayResultMatchesDirectNativeCallIncludingEveryStoredField() async throws {
        for useV2 in [false, true] {
            let i = try F.dense(useV2 ? "automatic-v2" : "automatic-v1", day: "2026-06-15", v2: useV2)
            let result = try await P.run(i)
            let prepared = try H.prepare(i.historyInput, history: [])
            let seed = try await S.seed(i), loaded = try await S.load(seed)
            let native = try P.analyze(i, prepared: prepared, loaded: loaded)
            XCTAssertFalse(native.sleepSessions.isEmpty)
            XCTAssertFalse(native.cachedSleep.isEmpty)
            XCTAssertFalse(native.sleepSessions.flatMap(\.stages).isEmpty)
            XCTAssertEqual(result.result, try P.reflect(native))
            let actual = try V.object(result.result)
            XCTAssertEqual(Set(actual.keys), Set(Mirror(reflecting: native).children.compactMap(\.label)))
            for key in ["daily", "sleepSessions", "cachedSleep", "workouts", "detectionFunnel", "recovery",
                "chargeDrivers", "skinTempRelative", "strain", "restScore", "chargeConfidence", "effortConfidence",
                "restConfidence", "nightlySkinTempC", "sessionMotionByStart", "sessionSleepStateByStart"] {
                XCTAssertNotNil(actual[key], key)
            }
            XCTAssertEqual(result.history.checkpoint.observation.measurements.values["hrv"], native.daily.avgHrv)
            XCTAssertEqual(result.history.checkpoint.observation.measurements.values["skin_temp"], native.nightlySkinTempC)
            XCTAssertEqual(result.history.checkpoint.observation.measurements.values["strain"], native.strain)
            let direct = try H.finish(prepared, measurements: result.history.checkpoint.observation.measurements)
            XCTAssertEqual(result.history.checkpoint, direct)
            XCTAssertEqual(result.selection.streams["bandState"]?.count, loaded.bandState.count)
            XCTAssertFalse(result.selection.gaps.contains("sleepStateSample_measurement_invalid"))
        }
    }

    func testActualHROnlyFallbackKeepsMeasuredPhysiologyAndMissingRespirationAsNull() async throws {
        let i = try F.hrOnly(), output = try await P.run(i)
        let seed = try await S.seed(i), loaded = try await S.load(seed)
        let provided = SleepStager.hrOnlySessions(hr: loaded.hr, rr: loaded.rr, resp: loaded.resp)
        XCTAssertFalse(provided.isEmpty)
        let result = try V.object(output.result), sleep = try V.array(result["sleepSessions"]!)
        XCTAssertEqual(sleep.count, provided.count)
        XCTAssertTrue(try sleep.allSatisfy { try V.object($0)["hrOnly"] == .bool(true) })
        let daily = try V.object(result["daily"]!)
        let prepared = try H.prepare(i.historyInput, history: [])
        let native = try P.analyze(i, prepared: prepared, loaded: loaded)
        XCTAssertEqual(output.result, try P.reflect(native))
        XCTAssertNotNil(native.daily.restingHr)
        XCTAssertNotNil(native.daily.avgHrv)
        XCTAssertEqual(output.history.checkpoint.observation.measurements.values["resting_hr"], native.daily.restingHr.map(Double.init))
        XCTAssertEqual(daily["respRateBpm"], .null)
        XCTAssertNil(output.history.checkpoint.observation.measurements.values["resp"])
    }

    func testDSTTrueZoneIsPassedThroughNativeCoreWithoutFixedOffsetWindow() async throws {
        for (day, zone, duration) in [("2026-03-08", "America/Los_Angeles", 82_800),
            ("2026-11-01", "America/Los_Angeles", 90_000), ("2026-10-04", "Australia/Lord_Howe", 84_600),
            ("2026-04-05", "Australia/Lord_Howe", 88_200)] {
            var i = try F.input("dst-\(day)", day: day, zone: zone)
            let b = try V.validate(i)
            for (id, ts) in [("lo", b.dayLo), ("hi", b.dayHi), ("future", b.dayHi + 1)] {
                F.append(&i, .hr, ts, ["bpm": .number(60)], id: id)
            }
            let o = try await P.run(i)
            XCTAssertEqual(o.selection.bounds.dayRange.count, duration)
            XCTAssertEqual(o.selection.dayHr, ["lo", "hi"])
            XCTAssertEqual(o.selection.retainedByOwner[F.owner.uuidString.lowercased()]?["hr"], 3)
            XCTAssertEqual(o.history.checkpoint.observation.timezone, zone)
            XCTAssertEqual(try V.object(V.object(o.result)["daily"]!)["day"], .string(day))
        }
    }

    func testFutureSignalsAndJournalDoNotChangeActualOutputOrHistory() async throws {
        let base = try F.dense("future-control", day: "2026-06-15")
        let before = try await P.run(base)
        var changed = base
        F.append(&changed, .rr, changed.asOfExclusive, F.rr(400, channel: 7), id: "future-rr")
        F.append(&changed, .hr, changed.asOfExclusive, ["bpm": .number(180)], id: "future-hr")
        F.append(&changed, .skinTemp, changed.asOfExclusive, ["raw": .number(4000)], id: "future-temp")
        changed.journal.append(F.journal(.profile, 3, day: "2026-06-16", payload: ["timezone": .string("Asia/Tokyo"), "age": .number(70)]))
        changed.journal.append(F.journal(.config, 4, day: "2026-06-16", payload: ["sourceEra": .string("future"), "effortMethod": .string("BANISTER")]))
        let after = try await P.run(changed)
        XCTAssertEqual(after.result, before.result)
        XCTAssertEqual(after.history, before.history)
        XCTAssertEqual(after.selection.streams, before.selection.streams)
        XCTAssertNotEqual(after.selection.retainedByOwner, before.selection.retainedByOwner)
        XCTAssertEqual(after.input.raw.count, base.raw.count + 3)
    }

    func testUnsupportedFullCompositionRefusesRatherThanEmitsEmptySections() async throws {
        var cases: [V.Input] = []
        var i = try F.input(family: nil, model: ""); cases.append(i)
        i = try F.input(family: "whoop4", model: "WHOOP 4.0")
        F.append(&i, .skinTemp, i.asOfExclusive - 1, ["raw": .number(1800)]); cases.append(i)
        i = try F.input(); i.journal.append(F.journal(.context, 3)); cases.append(i)
        for flag in ["journalContextEnabled", "cycleAwarenessEnabled", "daytimePersonalBaselineEnabled", "spo2CandidateDisplayEnabled"] {
            i = try F.input(); i.journal[1] = F.journal(.config, 2, payload: [flag: .bool(true)]); cases.append(i)
        }
        i = try F.input(); i.journal[1] = F.journal(.config, 2, payload: ["dayCycleMode": .string("sleep_onset")]); cases.append(i)
        for input in cases {
            do { _ = try await P.run(input); XCTFail("Unsupported composition must throw") }
            catch { XCTAssertTrue(error is C.Failure) }
        }
    }

    func testWHOOP4FutureThermalAtExclusiveCutoffDoesNotChangeCore() async throws {
        try await assertUnselectedWHOOP4Thermal(context: "future", future: true)
    }

    func testWHOOP4ForeignOwnerThermalDoesNotChangeCore() async throws {
        try await assertUnselectedWHOOP4Thermal(context: "foreign-owner", owner: F.foreign)
    }

    func testWHOOP4ForeignDeviceThermalDoesNotChangeCore() async throws {
        try await assertUnselectedWHOOP4Thermal(context: "foreign-device", device: F.otherDevice)
    }

    private func assertUnselectedWHOOP4Thermal(context: String, future: Bool = false,
                                             owner: UUID = F.owner, device: UUID = F.device) async throws {
        let base = try F.input("whoop4-noninterference", family: "whoop4", model: "WHOOP 4.0")
        let expected = try await P.run(base)
        var changed = base
        F.append(&changed, .skinTemp, future ? base.asOfExclusive : base.asOfExclusive - 1,
            ["raw": .number(1800)], id: context, owner: owner, device: device)
        let seed = try await S.seed(changed), loaded = try await S.load(seed)
        XCTAssertTrue(loaded.skinTemp.isEmpty)
        XCTAssertEqual(loaded.evidence.streams["skinTemp"], [])
        let actual = try await P.run(changed)
        XCTAssertEqual(actual.result, expected.result)
        XCTAssertEqual(actual.history, expected.history)
        XCTAssertEqual(actual.selection.streams, expected.selection.streams)
        XCTAssertEqual(actual.input, changed, "Original excluded rows remain evidence")
        XCTAssertEqual(actual.selection.retainedByOwner[owner.uuidString.lowercased()]?["skinTemp"], 1)
    }

    func testSelectedWHOOP4ThermalStillRequiresS11() async throws {
        var input = try F.input("whoop4-selected", family: "whoop4", model: "WHOOP 4.0")
        F.append(&input, .skinTemp, input.asOfExclusive - 1, ["raw": .number(1800)], id: "selected")
        let seed = try await S.seed(input), loaded = try await S.load(seed)
        XCTAssertEqual(loaded.skinTemp.count, 1)
        XCTAssertEqual(loaded.evidence.streams["skinTemp"]?.map(\.id), ["selected"])
        do { _ = try await P.run(input); XCTFail("Selected WHOOP4 thermal data must still require S11") }
        catch { XCTAssertEqual(error as? C.Failure, .invalid("s10:whoop4_thermal_requires_s11")) }
    }

    func testHistoryLineageCannotUseAbsentOrForeignCaseCheckpoint() async throws {
        var i = try F.input(); i.historyCaseIds = ["not-executed"]
        do { _ = try await P.run(i); XCTFail("Missing history accepted") }
        catch { XCTAssertEqual(error as? C.Failure, .invalid("s10:history_case_lineage")) }
        let first = try await P.run(F.input("first", day: "2026-06-14"))
        i.historyCaseIds = ["first"]
        var other = i
        other.identity = C.Identity(userId: F.foreign, sourceDeviceId: F.device, algorithmVersion: i.identity.algorithmVersion)
        do { _ = try await P.run(other, history: [first.prior]); XCTFail("Foreign history accepted") }
        catch { XCTAssertTrue(error is C.Failure) }
    }

    func testThreeDayOwnSwiftHistoryIndependentStoresSerializedRestartAndExternalProbe() async throws {
        let hashesBefore = try P.sourceHashes()
        var first: [P.Outcome] = [], second: [P.Outcome] = []
        for day in ["2026-06-15", "2026-06-16", "2026-06-17"] {
            var input = try F.dense("three-day-\(day)", day: day)
            input.historyCaseIds = first.map { $0.input.id }
            let prior = try first.map { try $0.prior }
            let a = try await P.run(input, history: prior, predecessor: first.last?.history.checkpoint)
            let serialized = try C.bytes(second.map { try $0.prior })
            let ownRestored = try JSONDecoder().decode([P.Prior].self, from: serialized)
            let b = try await P.run(input, history: ownRestored, predecessor: second.last?.history.checkpoint)
            XCTAssertEqual(try C.bytes(a), try C.bytes(b), "Independent real stores, same actual Swift computation")
            XCTAssertEqual(a.history.reusedCheckpoint, !first.isEmpty)
            XCTAssertEqual(a.history.baselinesBefore, b.history.baselinesBefore)
            XCTAssertFalse(a.history.checkpoint.observation.measurements.values.isEmpty)
            XCTAssertFalse(a.history.checkpoint.observation.measurements.sleep.isEmpty)
            first.append(a); second.append(b)
        }
        let last = first.last!
        let cold = try await P.run(last.input, history: first.dropLast().map { try $0.prior })
        XCTAssertFalse(cold.history.reusedCheckpoint)
        XCTAssertEqual(cold.result, last.result)
        XCTAssertEqual(cold.history.checkpoint, last.history.checkpoint)
        XCTAssertEqual(cold.history.baselinesBefore, last.history.baselinesBefore)
        for (key, cfg) in Baselines.metricCfg {
            let actualFold = Baselines.foldHistory(first.map { $0.history.checkpoint.observation.measurements.baselineValues[key] }, cfg: cfg,
                rejectHardOutliers: key != "readiness_hrv_ln")
            XCTAssertEqual(try last.history.checkpoint.baselinesAfter[key]?.native(), actualFold, key)
        }
        XCTAssertEqual(try P.sourceHashes(), hashesBefore, "No source or historical manifest changes during native execution")
        let artifact = P.Artifact(schemaVersion: P.artifactSchemaVersion, producer: "actual-swift", recipe: P.artifactRecipe,
            mode: P.artifactMode, sourceRevision: try revision(), sourceHashes: hashesBefore, cases: first)
        try P.validateArtifact(artifact)
        let bytes = try C.bytes(artifact)
        XCTAssertEqual(try JSONDecoder().decode(P.Artifact.self, from: bytes), artifact)
        // Probe schema/recipe/mode cannot be mistaken for the future full schema2 server_day.
        let json = try V.object(JSONDecoder().decode(C.JSON.self, from: bytes))
        XCTAssertEqual(json["schemaVersion"], .number(1))
        XCTAssertNotEqual(json["recipe"], .string(V.recipe))
        XCTAssertNotEqual(json["mode"], .string("server_day"))
        XCTAssertThrowsError(try V.decode(bytes))
        if let destination = ProcessInfo.processInfo.environment["S10_CORE_PROBE_OUTPUT"] {
            try writeExternal(bytes, destination: URL(fileURLWithPath: destination))
        }
        print("S10 actual Swift: \(first.count) days, \(hashesBefore.count) source/manifest hashes unchanged, \(bytes.count) probe bytes; not full server_day")
    }

    func testProbeWriterRefusesRepositoryAndExistingDestination() throws {
        let bytes = Data("nonempty synthetic probe".utf8)
        let forbidden = P.repository.appendingPathComponent("forbidden-s10.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: forbidden.path))
        XCTAssertThrowsError(try writeExternal(bytes, destination: forbidden)) {
            XCTAssertEqual($0 as? C.Failure, .invalid("s10:external_new_destination_required"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: forbidden.path))
        let source = URL(fileURLWithPath: #filePath), original = try Data(contentsOf: source)
        XCTAssertThrowsError(try writeExternal(bytes, destination: source)) {
            XCTAssertEqual($0 as? C.Failure, .invalid("s10:external_new_destination_required"))
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testProbeWriterAcceptsNewExternalAndRefusesExistingExternalAndSymlink() throws {
        let fm = FileManager.default
        // On macOS Foundation's temporaryDirectory can ignore TMPDIR; honor the explicit scratch root.
        let temporary = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? fm.temporaryDirectory
        let root = temporary.resolvingSymlinksInPath().appendingPathComponent("s10-writer-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        let bytes = Data("nonempty synthetic probe".utf8), destination = root.appendingPathComponent("new.json")
        try writeExternal(bytes, destination: destination)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertThrowsError(try writeExternal(Data("must not replace".utf8), destination: destination)) {
            XCTAssertEqual($0 as? C.Failure, .invalid("s10:external_new_destination_required"))
        }
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        let real = root.appendingPathComponent("real"), alias = root.appendingPathComponent("alias")
        try fm.createDirectory(at: real, withIntermediateDirectories: false)
        try fm.createSymbolicLink(at: alias, withDestinationURL: real)
        XCTAssertThrowsError(try writeExternal(bytes, destination: alias.appendingPathComponent("forbidden.json"))) {
            XCTAssertEqual($0 as? C.Failure, .invalid("s10:external_new_destination_required"))
        }
        XCTAssertFalse(fm.fileExists(atPath: real.appendingPathComponent("forbidden.json").path))
    }

    private func writeExternal(_ bytes: Data, destination: URL) throws {
        // Resolve the existing parent: resolving the full URL can leave a symlink unresolved
        // when its final component does not exist yet (the required new-file case here).
        let resolved = destination.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent(destination.lastPathComponent, isDirectory: false)
        let repo = P.repository.resolvingSymlinksInPath().standardizedFileURL
        guard !resolved.path.hasPrefix(repo.path + "/"), resolved != repo,
              destination.standardizedFileURL == resolved,
              !FileManager.default.fileExists(atPath: resolved.path), !bytes.isEmpty,
              FileManager.default.fileExists(atPath: resolved.deletingLastPathComponent().path) else { throw V.failure("external_new_destination_required") }
        try bytes.write(to: resolved, options: .withoutOverwriting)
        XCTAssertEqual(try Data(contentsOf: resolved), bytes)
    }

    private func revision() throws -> String {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["--no-lazy-fetch", "rev-parse", "HEAD"]
        p.currentDirectoryURL = P.repository
        p.standardOutput = pipe
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw V.failure("source_revision") }
        let revision = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard revision.count == 40 else { throw V.failure("source_revision") }
        return revision
    }
}
