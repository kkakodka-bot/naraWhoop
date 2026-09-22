import Foundation
import WhoopProtocol
import XCTest
@testable import StrandAnalytics

final class ServerDaySwiftV3ThermalTests: XCTestCase {
    private typealias F = S11Fixtures
    private typealias R = ServerDaySwiftV3History
    private typealias T = ServerDaySwiftV3Thermal
    private typealias S = ServerDaySwiftV3Selection
    private typealias V = ServerDaySwiftV3Contract
    private typealias C = ServerDaySwiftContract
    private typealias H = ServerDaySwiftHistory
    private typealias P = ServerDaySwiftV3CoreProbe

    func testNativeAnchor99And100InBandThresholdAndOriginalRowids() async throws {
        for count in [99, 100] {
            var input = try S10Fixtures.input(family: "whoop4", model: "WHOOP 4.0")
            let lo = try V.validate(input).dayLo
            for index in 0..<count {
                F.append(&input, .skinTemp, lo + index, ["raw": .number(Double(1_000 + index % 2 * 2))])
            }
            F.append(&input, .skinTemp, lo + 200, ["raw": .number(549)], id: "low")
            F.append(&input, .skinTemp, lo + 201, ["raw": .number(2041)], id: "high")
            let seed = try await S.seed(input), a = try await T.anchor(seed)
            let originals = try input.raw.map { try V.integer($0.fields["raw"]) }
            XCTAssertEqual(a.learnedRaw, Whoop4SkinTemp.deviceAnchorRaw(originals))
            XCTAssertEqual(a.inBandIDs.count, count)
            XCTAssertEqual(a.rows.map(\.rowid), (1...Int64(count + 2)).map { $0 })
            XCTAssertEqual(a.rows.map(\.id), input.raw.map(\.id))
            if count == 99 { XCTAssertNil(a.learnedRaw); XCTAssertEqual(a.resolvedRaw, Whoop4SkinTemp.anchorRaw) }
            else { XCTAssertNotNil(a.learnedRaw); XCTAssertEqual(a.resolvedRaw, a.learnedRaw) }
        }
    }

    func testTrueZone21DaySelectionAcrossFullAndHalfHourDSTRetainsRejectedRows() async throws {
        for (day, lowerDay, zone) in [("2026-03-28", "2026-03-08", "America/Los_Angeles"),
            ("2026-11-21", "2026-11-01", "America/Los_Angeles"), ("2026-10-24", "2026-10-04", "Australia/Lord_Howe"),
            ("2026-04-25", "2026-04-05", "Australia/Lord_Howe")] {
            var input = try S10Fixtures.input(day: day, zone: zone, family: "whoop4", model: "WHOOP 4.0")
            let bounds = try T.lookback(input), dayBounds = try V.validate(input)
            XCTAssertEqual(bounds.lowerBound, try C.dayBounds(lowerDay, zone).lowerBound - 108_000)
            XCTAssertNotEqual(bounds.lowerBound, dayBounds.dayLo - 20 * 86_400 - 108_000)
            for (id, ts) in [("too-old", bounds.lowerBound - 1), ("lo", bounds.lowerBound), ("hi", bounds.upperBound), ("future", bounds.upperBound + 1)] {
                F.append(&input, .skinTemp, ts, ["raw": .number(1_290)], id: id)
            }
            F.append(&input, .skinTemp, bounds.lowerBound, ["raw": .number(1_700)], id: "foreign-owner", owner: S10Fixtures.foreign)
            F.append(&input, .skinTemp, bounds.lowerBound, ["raw": .number(1_800)], id: "foreign-device", device: S10Fixtures.otherDevice)
            let seed = try await S.seed(input), a = try await T.anchor(seed), loaded = try await S.load(seed)
            XCTAssertEqual(a.rows.map(\.id), ["lo", "hi"])
            XCTAssertEqual(a.rows.map(\.rowid), [2, 3])
            XCTAssertEqual(loaded.evidence.retainedByOwner[S10Fixtures.owner.uuidString.lowercased()]?["skinTemp"], 5)
            XCTAssertEqual(loaded.evidence.retainedByOwner[S10Fixtures.foreign.uuidString.lowercased()]?["skinTemp"], 1)
            XCTAssertEqual(seed.input.raw, input.raw)
        }
    }

    func testActualAutomaticNight299Versus300KeptUsesNativeFloor() async throws {
        for count in [299, 300] {
            let input = try F.input("2026-06-15", whoop4: true, skinCount: count)
            let output = try await R.run(input).record.body
            XCTAssertFalse(output.rawNight.sessions.isEmpty)
            let native = T.funnel(output.rawNight, family: .whoop4, anchor: output.thermal.anchor.resolvedRaw)
            XCTAssertEqual(native.kept, count)
            XCTAssertEqual(native.minSamples, AnalyticsEngine.minSkinTempSamples)
            XCTAssertEqual(output.checkpoint.observation.measurements.values["skin_temp"], native.mean)
            XCTAssertEqual(output.wornInBedRawCounts.reduce(0) { $0 + $1.count }, count)
            if count == 299 { XCTAssertNil(native.mean) } else { XCTAssertNotNil(native.mean) }
        }
    }

    func testNoConcurrentHRAndOutOfBandSamplesRemainRawWithoutInventingTemperature() async throws {
        var input = try F.input("2026-06-15", whoop4: true)
        // Shift only original thermal timestamps away from measured HR; retain all signals.
        input.raw = input.raw.map { row in
            guard row.stream == .skinTemp else { return row }
            return C.RawRow(id: row.id, userId: row.userId, sourceDeviceId: row.sourceDeviceId, stream: row.stream,
                ts: row.ts + 1, fields: row.fields)
        }
        let output = try await R.run(input).record.body
        XCTAssertFalse(output.rawNight.sessions.isEmpty)
        XCTAssertNil(output.checkpoint.observation.measurements.values["skin_temp"])
        let f = T.funnel(output.rawNight, family: .whoop4, anchor: output.thermal.anchor.resolvedRaw)
        XCTAssertEqual(f.droppedNotWorn, 300)
        XCTAssertEqual(f.kept, 0)
        XCTAssertTrue(output.wornInBedRawCounts.isEmpty)
        for raw in [549, 2041] {
            let bad = try await R.run(F.input("2026-06-15", whoop4: true, raw: raw)).record.body
            XCTAssertEqual(bad.rawNight.skin.count, 300)
            XCTAssertNil(bad.thermal.anchor.learnedRaw)
            XCTAssertNil(bad.checkpoint.observation.measurements.values["skin_temp"])
            XCTAssertTrue(bad.wornInBedRawCounts.isEmpty)
            XCTAssertEqual(T.funnel(bad.rawNight, family: .whoop4, anchor: bad.thermal.anchor.resolvedRaw).droppedOutOfRange, 300)
        }
    }

    func testChangingAnchorReexecutesRawPriorNightAndMayDropOrRestoreMean() async throws {
        for restore in [false, true] {
            var firstInput = try F.input("2026-06-14", whoop4: true, raw: 1_000)
            if restore { try addAnchorWeight(&firstInput, raw: 1_600) }
            let first = try await R.run(firstInput).record
            let originalBytes = try C.bytes(first)
            var nextInput = try F.input("2026-06-15", whoop4: true, raw: restore ? 1_000 : 1_600)
            try addAnchorWeight(&nextInput, raw: restore ? 1_000 : 1_600, count: 1_501)
            nextInput = try F.lineage(nextInput, [first], addThermalLookback: true)
            let warm = try await R.run(nextInput, history: [first], predecessor: first.restart)
            let cold = try await R.run(nextInput, history: [first])
            XCTAssertEqual(warm.record, cold.record)
            XCTAssertTrue(warm.reusedCheckpoint); XCTAssertFalse(cold.reusedCheckpoint)
            XCTAssertEqual(try C.bytes(first), originalBytes, "Original observations are never rewritten under today's anchor")
            let evidence = warm.record.body.thermal
            let replay = try XCTUnwrap(evidence.priorNights.first)
            let direct = T.funnel(first.body.rawNight, family: .whoop4, anchor: evidence.anchor.resolvedRaw)
            XCTAssertEqual(replay.funnel, try P.reflect(direct))
            XCTAssertEqual(replay.mean, direct.mean)
            XCTAssertEqual(replay.originalMean, first.body.checkpoint.observation.measurements.values["skin_temp"])
            if restore { XCTAssertNil(replay.originalMean); XCTAssertNotNil(replay.mean) }
            else { XCTAssertNotNil(replay.originalMean); XCTAssertNil(replay.mean) }
            let expectedBefore = Baselines.foldHistory([direct.mean], cfg: Baselines.metricCfg["skin_temp"]!)
            XCTAssertEqual(try evidence.beforeState.native(), expectedBefore)
            XCTAssertEqual(warm.record.body.checkpoint.observation.baselinesBefore["skin_temp"], evidence.beforeState)
            let measured = warm.record.body.checkpoint.observation.measurements.values["skin_temp"]
            XCTAssertEqual(try warm.record.body.checkpoint.baselinesAfter["skin_temp"]?.native(),
                Baselines.update(expectedBefore, value: measured, cfg: Baselines.metricCfg["skin_temp"]!))
            for key in Baselines.metricCfg.keys where key != "skin_temp" {
                XCTAssertEqual(warm.record.body.checkpoint.observation.baselinesBefore[key], first.body.checkpoint.baselinesAfter[key])
            }
        }
    }

    func testWHOOP5CentidegreesRemainS10ExactAndDoNotLearnAnAnchor() async throws {
        let input = try F.input("2026-06-15", raw: 3_325)
        let actual = try await R.run(input).record.body, s10 = try await P.run(input)
        XCTAssertEqual(actual.result, s10.result)
        XCTAssertEqual(actual.checkpoint, s10.history.checkpoint)
        XCTAssertNil(actual.thermal.anchor.lo)
        XCTAssertNil(actual.thermal.anchor.resolvedRaw)
        XCTAssertTrue(actual.thermal.anchor.rows.isEmpty)
        XCTAssertTrue(actual.thermal.priorNights.isEmpty)
        let native = T.funnel(actual.rawNight, family: .whoop5, anchor: nil)
        XCTAssertEqual(actual.checkpoint.observation.measurements.values["skin_temp"], native.mean)
        XCTAssertEqual(native.mean, skinTempCelsius(raw: 3_325, family: .whoop5))
    }

    func testActualDSTNightsColdWarmRestartAndTravelRetainOriginalZone() async throws {
        for (day, zone, duration) in [("2026-03-08", "America/Los_Angeles", 82_800),
            ("2026-11-01", "America/Los_Angeles", 90_000), ("2026-10-04", "Australia/Lord_Howe", 84_600),
            ("2026-04-05", "Australia/Lord_Howe", 88_200)] {
            let prior = try await R.run(F.input(F.day(-1, start: day), zone: "Asia/Kathmandu", whoop4: true)).record
            let input = try F.lineage(F.input(day, zone: zone, whoop4: true), [prior], addThermalLookback: true)
            let restored = try JSONDecoder().decode(R.Record.self, from: C.bytes(prior))
            let warm = try await R.run(input, history: [restored], predecessor: restored.restart)
            let cold = try await R.run(input, history: [prior])
            XCTAssertEqual(warm.record, cold.record)
            XCTAssertEqual(warm.record.body.selection.bounds.dayRange.count, duration)
            XCTAssertFalse(warm.record.body.rawNight.sessions.isEmpty)
            XCTAssertEqual(prior.body.checkpoint.observation.timezone, "Asia/Kathmandu")
            XCTAssertEqual(warm.record.body.checkpoint.observation.timezone, zone)
            XCTAssertEqual(warm.record.body.thermal.priorNights.count, 1)
        }
    }

    func testThermalRefoldHonorsRecoveryEpochEraAndMissingCalendarDays() async throws {
        var history: [R.Record] = []
        for index in [0, 1, 4, 5, 9] {
            var config: [String: C.JSON] = [:]
            if index >= 4 { config["recoveryBaselineEpoch"] = .number(Double(try C.dayBounds(F.day(1), "UTC").lowerBound) + 0.5) }
            if index >= 9 { config["sourceEra"] = .string("replacement") }
            let input = try F.lineage(F.input(F.day(index), whoop4: true, raw: 1_000 + index, config: config), history, addThermalLookback: true)
            let warm = try await R.run(input, history: history, predecessor: history.last?.restart)
            let cold = try await R.run(input, history: history)
            XCTAssertEqual(warm.record, cold.record)
            if index == 4 || index == 9 { XCTAssertEqual(warm.record.body.thermal.beforeState.nValid, 0) }
            if index == 5 { XCTAssertEqual(warm.record.body.thermal.beforeState.nValid, 1) }
            history.append(warm.record)
        }
    }

    func test32RawWHOOP4DaysSlidingAnchorAndOwnSerializedRestart() async throws {
        var records: [R.Record] = []
        for index in 0..<32 {
            let input = try F.lineage(F.input(F.day(index), whoop4: true, raw: 1_000 + index), records, addThermalLookback: true)
            let warm = try await R.run(input, history: records, predecessor: records.last?.restart)
            let body = warm.record.body
            XCTAssertNotNil(body.checkpoint.observation.measurements.values["skin_temp"])
            XCTAssertEqual(body.wornInBedRawCounts.reduce(0) { $0 + $1.count }, 300)
            let selected = try body.thermal.anchor.rows.map { try V.integer($0.fields["raw"]) }
            XCTAssertEqual(body.thermal.anchor.learnedRaw, Whoop4SkinTemp.deviceAnchorRaw(selected))
            XCTAssertEqual(body.checkpoint.observation.baselinesBefore["skin_temp"], body.thermal.beforeState)
            let direct = body.thermal.priorNights.map { night -> Double? in
                let prior = records.first { $0.body.input.id == night.caseID }!
                return T.funnel(prior.body.rawNight, family: .whoop4, anchor: body.thermal.anchor.resolvedRaw).mean
            }
            XCTAssertEqual(try body.thermal.beforeState.native(), Baselines.foldHistory(direct, cfg: Baselines.metricCfg["skin_temp"]!))
            if [0, 16, 21, 31].contains(index) {
                let restored = try JSONDecoder().decode([R.Record].self, from: C.bytes(records))
                let cold = try await R.run(input, history: records)
                let restart = try await R.run(input, history: restored, predecessor: restored.last?.restart)
                XCTAssertEqual(cold.record, warm.record)
                XCTAssertEqual(restart.record, warm.record)
            }
            records.append(warm.record)
        }
        let last = records.last!.body
        XCTAssertEqual(last.thermal.priorNights.count, 31, "Rebase prior history, not just the 21-day anchor scan")
        XCTAssertFalse(last.thermal.anchor.rows.contains { records.first!.body.rawNight.skinIDs.contains($0.id) })
        XCTAssertTrue(records.first!.body.input.raw.contains { $0.stream == .skinTemp }, "Old raw evidence stays retained")
        print("S11 WHOOP4: 32 raw nights, sliding 21-civil-day anchor, 31 prior-night native funnel replays, 4 cold/restart controls")
    }

    private func addAnchorWeight(_ input: inout V.Input, raw: Int, count: Int = 501) throws {
        let ts = try V.validate(input).dayLo + 12 * 3_600
        for index in 0..<count { F.append(&input, .skinTemp, ts + index, ["raw": .number(Double(raw))]) }
    }
}
