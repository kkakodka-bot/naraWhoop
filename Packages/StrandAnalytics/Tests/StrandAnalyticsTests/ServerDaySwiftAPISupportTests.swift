import CryptoKit
import Foundation
import XCTest
import WhoopProtocol
import WhoopStore
@testable import StrandAnalytics

/// API probes only. These are not complete schema1 server_day expected values.
final class ServerDaySwiftAPISupportTests: XCTestCase {
    private struct ZonedDay {
        let calendar: Calendar
        let start: Int
        let end: Int
        var offsetAtStart: Int { calendar.timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(start))) }
        var offsetAtEnd: Int { calendar.timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(end - 1))) }
    }

    private func zonedDay(_ day: String, _ zone: String) throws -> ZonedDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let pieces = day.split(separator: "-").compactMap { Int($0) }
        let noon = try XCTUnwrap(calendar.date(from: DateComponents(year: pieces[0], month: pieces[1], day: pieces[2], hour: 12)))
        let interval = try XCTUnwrap(calendar.dateInterval(of: .day, for: noon))
        return ZonedDay(calendar: calendar, start: Int(interval.start.timeIntervalSince1970), end: Int(interval.end.timeIntervalSince1970))
    }

    func testTrueZoneBoundsDriveActualStoreBoundarySelection() async throws {
        _ = try await zoneProbes()
    }

    private func zoneProbes() async throws -> [[String: Any]] {
        let vectors: [(String, String, Int)] = [
            ("2026-06-15", "UTC", 86_400),
            ("2026-03-08", "America/Los_Angeles", 82_800),
            ("2026-11-01", "America/Los_Angeles", 90_000),
            ("2026-04-05", "Australia/Lord_Howe", 88_200),
            ("2026-10-04", "Australia/Lord_Howe", 84_600),
            ("2026-06-15", "Asia/Kathmandu", 86_400),
            ("2000-01-15", "Africa/Khartoum", 82_800)
        ]
        var output: [[String: Any]] = []
        for (day, zone, duration) in vectors {
            let bounds = try zonedDay(day, zone)
            XCTAssertEqual(bounds.end - bounds.start, duration, "\(day) \(zone)")
            let nightLo = bounds.start - 30 * 3_600
            let points = Set([nightLo - 1, nightLo, nightLo + 1, bounds.start - 1, bounds.start, bounds.start + 1,
                              bounds.end - 2, bounds.end - 1, bounds.end]).sorted()
            var recipe = WholeDaySwiftParityExporter.Recipe(id: "true-zone-probe", day: day, timezone: zone)
            for (index, ts) in points.enumerated() {
                recipe.append("hr", ["ts": ts, "bpm": 60 + index])
                recipe.append("rr", ["ts": ts, "rrMs": 800 + index, "seq": 0, "ord": 0, "srcChannel": 5])
            }
            let store = try await WholeDaySwiftParityExporter.seed(recipe)
            let dayRows = try await store.hrSamples(deviceId: WholeDaySwiftParityExporter.device,
                from: bounds.start, to: bounds.end - 1, limit: 100)
            let nightRows = try await store.rrIntervals(deviceId: WholeDaySwiftParityExporter.device,
                from: nightLo, to: bounds.end - 1, limit: 100)
            XCTAssertEqual(dayRows.map(\.ts), points.filter { $0 >= bounds.start && $0 < bounds.end })
            XCTAssertEqual(nightRows.map(\.ts), points.filter { $0 >= nightLo && $0 < bounds.end })
            let idByTs = Dictionary(uniqueKeysWithValues: recipe.raw["rr"]!.map { ($0["ts"] as! Int, $0["id"] as! String) })
            output.append(["day": day, "timezone": zone, "dayLo": bounds.start, "dayHi": bounds.end - 1,
                "nightLo": nightLo, "nightHi": bounds.end - 1, "durationSeconds": duration,
                "offsetAtStart": bounds.offsetAtStart, "offsetAtEnd": bounds.offsetAtEnd,
                "inputTimestamps": points, "selectedDayHR": dayRows.map(\.ts),
                "selectedNightRR": nightRows.map { idByTs[$0.ts]! }])
        }
        return output
    }

    func testFixedOffsetEngineCannotAdmitBothEdgesOfTwentyFiveHourDay() throws {
        _ = try fallbackProbe()
    }

    private func suppliedSleep(_ start: Int, _ end: Int) -> SleepSession {
        SleepSession(start: start, end: end, efficiency: 1,
            stages: [StageSegment(start: start, end: end, stage: "light")], restingHR: 50, avgHRV: 40)
    }

    private func fallbackProbe() throws -> [String: Any] {
        let day = "2026-11-01", zone = "America/Los_Angeles"
        let bounds = try zonedDay(day, zone)
        let early = suppliedSleep(bounds.start + 600, bounds.start + 1_800)
        let late = suppliedSleep(bounds.end - 3_000, bounds.end - 1_800)
        XCTAssertEqual(bounds.end - bounds.start, 90_000)
        XCTAssertNotEqual(bounds.offsetAtStart, bounds.offsetAtEnd)
        let usingStart = AnalyticsEngine.analyzeDay(day: day, profile: UserProfile(), tzOffsetSeconds: bounds.offsetAtStart, providedSleep: [early, late])
        let usingEnd = AnalyticsEngine.analyzeDay(day: day, profile: UserProfile(), tzOffsetSeconds: bounds.offsetAtEnd, providedSleep: [early, late])
        XCTAssertEqual(usingStart.sleepSessions.map(\.start), [early.start])
        XCTAssertEqual(usingEnd.sleepSessions.map(\.start), [late.start])
        let eligible = [early, late].filter { $0.end >= bounds.start && $0.end < bounds.end }
        XCTAssertEqual(eligible.count, 2)
        return ["day": day, "timezone": zone, "trueZoneEligibleStarts": eligible.map(\.start),
            "actualUsingStartOffset": usingStart.sleepSessions.map(\.start),
            "actualUsingEndOffset": usingEnd.sleepSessions.map(\.start),
            "requiredMissingSeam": "zone-aware sleep admission or an explicit admitted-session aggregation API"]
    }

    func testProvidedSleepIsNotAnAuthoritativeEmptyOrMovedSessionSet() throws {
        _ = try resolvedSleepProbe()
    }

    private func resolvedSleepProbe() throws -> [String: Any] {
        let day = "2026-06-15", start = try zonedDay(day, "UTC").start + 3_600
        let hr = (0..<7_200).map { HRSample(ts: start + $0, bpm: 50) }
        let gravity = (0..<7_200).map { GravitySample(ts: start + $0, x: 0, y: 0, z: 1) }
        let rr = (0..<7_200).map { RRInterval(ts: start + $0, rrMs: 1000 + ($0 % 2) * 10) }
        let empty = AnalyticsEngine.analyzeDay(day: day, hr: hr, rr: rr, gravity: gravity, profile: UserProfile(), providedSleep: [])
        XCTAssertEqual(empty.sleepSessions.count, 1)
        let detected = try XCTUnwrap(empty.sleepSessions.first)
        let moved = suppliedSleep(detected.end + 3_600, detected.end + 5_400)
        let supplied = AnalyticsEngine.analyzeDay(day: day, hr: hr, rr: rr, gravity: gravity, profile: UserProfile(), providedSleep: [moved])
        XCTAssertEqual(supplied.sleepSessions.count, 2)
        XCTAssertTrue(supplied.sleepSessions.contains { $0.start == detected.start })
        XCTAssertTrue(supplied.sleepSessions.contains { $0.start == moved.start })
        return ["day": day, "actualWithEmptyProvidedStarts": empty.sleepSessions.map(\.start),
            "actualWithDisjointMovedProvidedStarts": supplied.sleepSessions.map(\.start),
            "requiredMissingSeam": "authoritative resolved sessions including an empty set, plus explicit main-night exclusions"]
    }

    func testActualHistoryHelpersSupportReplayResetEraNeedAndDebt() throws {
        _ = try historyProbe()
    }

    private func historyProbe() throws -> [String: Any] {
        let calendar = try zonedDay("2026-01-01", "UTC").calendar
        let start = try zonedDay("2026-01-01", "UTC").start
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        let days = (0..<131).map { formatter.string(from: Date(timeIntervalSince1970: Double(start + $0 * 86_400))) }
        let hrv: [Double?] = (0..<131).map { $0 % 17 == 0 ? nil : Double(40 + $0 % 4) }
        let rhr: [Double?] = (0..<131).map { Double(50 + $0 % 3) }
        let sleep: [Double?] = (0..<131).map { $0 % 19 == 0 ? nil : Double(420 + ($0 % 4) * 20) }
        let folded = Baselines.foldHistory(hrv, cfg: Baselines.hrvCfg)
        var replay: BaselineState?
        for value in hrv { replay = Baselines.update(replay, value: value, cfg: Baselines.hrvCfg) }
        XCTAssertEqual(replay, folded)
        XCTAssertEqual(folded.status, .trusted)
        let epoch = Double(start + 91 * 86_400)
        let reset = Baselines.foldHistory(hrv, dayKeys: days, cfg: Baselines.hrvCfg, baselineEpoch: epoch)
        XCTAssertEqual(reset, Baselines.foldHistory(Array(hrv[91...]), cfg: Baselines.hrvCfg))
        let rhrUnreset = Baselines.foldHistory(rhr, dayKeys: days, cfg: Baselines.restingHRCfg, baselineEpoch: 0)
        XCTAssertEqual(rhrUnreset.nValid, 131)
        let sourceDays = days.enumerated().map { (day: $0.element, sourceId: $0.offset < 91 ? "oura-import" : "my-whoop") }
        XCTAssertEqual(Baselines.deviceEraEpoch(sourceDays), epoch)
        var corrected = hrv
        corrected[120] = 55
        let correctedState = Baselines.foldHistory(corrected, cfg: Baselines.hrvCfg)
        XCTAssertNotEqual(correctedState, folded)
        let need = AnalyticsEngine.Rest.personalizedNeedHours(nightlyHours: sleep.compactMap { $0.map { $0 / 60 } }, age: 30)
        let debt = SleepDebt.ledger(series: Array(zip(days, sleep)).map { (day: $0.0, totalSleepMin: $0.1) }, needHours: need)
        XCTAssertEqual(debt.nightCount, SleepDebt.defaultWindowNights)
        XCTAssertEqual(debt.nights.last?.day, days.last)
        func state(_ s: BaselineState) -> [String: Any] {
            ["baseline": s.baseline, "spread": s.spread, "nValid": s.nValid,
             "nightsSinceUpdate": s.nightsSinceUpdate, "status": s.status.rawValue]
        }
        return ["input": ["days": days, "hrv": hrv.map(WholeDaySwiftParityExporter.optional),
            "restingHR": rhr.map(WholeDaySwiftParityExporter.optional), "sleepMinutes": sleep.map(WholeDaySwiftParityExporter.optional),
            "resetEpoch": epoch, "correctedIndex": 120, "correctedValue": 55],
            "actual": ["hrvBaseline": state(folded), "resetHRVBaseline": state(reset),
                "unresetRHRBaseline": state(rhrUnreset), "correctedHRVBaseline": state(correctedState),
                "sourceEraEpoch": Baselines.deviceEraEpoch(sourceDays), "needHours": need,
                "sleepDebt": ["needMin": debt.needMin, "balanceMin": debt.balanceMin, "magnitudeMin": debt.magnitudeMin,
                    "nightCount": debt.nightCount, "nights": debt.nights.map { ["day": $0.day, "sleptMin": $0.sleptMin, "deltaMin": $0.deltaMin] as [String: Any] }]],
            "scope": "actual individual helper executions, not the missing as-of history/snapshot orchestrator"]
    }

    func testExportAPIEvidenceWithoutChangingFrozenKernelCorpus() async throws {
        let liveSourceHashes = try WholeDaySwiftV2Corpus.sourceHashes()
        let zones = try await zoneProbes(), fallback = try fallbackProbe(), resolved = try resolvedSleepProbe(), history = try historyProbe()
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let directory = root.appendingPathComponent("Tests/Fixtures/w4-whole-day-swift-v1")
        let manifestData = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(digest(manifestData), "d948f5b7dffbd71dece63586ecce08fb3c497c87995bf2685d6469d0782fa245")
        let manifest = try WholeDaySwiftHistoricalProvenance.verify(.v1, repository: root)
        let entries = try XCTUnwrap(manifest["cases"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 13)
        for entry in entries {
            let file = try XCTUnwrap(entry["file"] as? String)
            XCTAssertEqual(digest(try Data(contentsOf: directory.appendingPathComponent(file))), entry["sha256"] as? String, file)
        }
        let ownPath = "Packages/StrandAnalytics/Tests/StrandAnalyticsTests/ServerDaySwiftAPISupportTests.swift"
        XCTAssertEqual(try WholeDaySwiftV2Corpus.sourceHashes(), liveSourceHashes, "source changed while executing API probes")
        var hashes = liveSourceHashes
        hashes[ownPath] = digest(try Data(contentsOf: root.appendingPathComponent(ownPath)))
        guard testRun?.failureCount == 0 else { throw ProbeError.failedAssertion }
        guard let path = ProcessInfo.processInfo.environment["W4_SERVER_DAY_PROBE_PATH"] else { return }
        let output = URL(fileURLWithPath: path).standardizedFileURL
        guard output.lastPathComponent == "server-day-api-probes.json", output.resolvingSymlinksInPath() == output else {
            throw ProbeError.unsafePath
        }
        let evidence: [String: Any] = ["kind": "actual-swift-api-probes-not-server-day-corpus", "sourceHashes": hashes,
            "timezoneDatabase": TimeZone.timeZoneDataVersion, "trueZoneStoreSelection": zones,
            "fixedOffsetAdmission": fallback, "providedSleepSemantics": resolved, "historyHelpers": history]
        try WholeDaySwiftParityExporter.bytes(evidence).write(to: output, options: .atomic)
    }

    private enum ProbeError: Error { case failedAssertion, unsafePath }
}
