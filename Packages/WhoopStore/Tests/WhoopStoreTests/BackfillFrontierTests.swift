import XCTest
import WhoopProtocol
import GRDB
@testable import WhoopStore

final class BackfillFrontierTests: XCTestCase {

    func testV45AddsBackfillFrontierTable() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("backfillFrontier"))
        let pk = try await store.primaryKeyColumns("backfillFrontier")
        XCTAssertEqual(pk, ["deviceId", "stream"])
        let cols = try await store.columnNamesForTest(table: "backfillFrontier")
        XCTAssertEqual(cols, ["deviceId", "stream", "maxTs"])
    }

    func testDuplicateChunkReplayDoesNotInsertOrRefreshDebt() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev", mac: nil, name: nil)
        let kinds = [SyncJobKind.rescore.rawValue]
        let chunk = Streams(
            hr: [HRSample(ts: 1_700_000_100, bpm: 61)],
            rr: [RRInterval(ts: 1_700_000_100, rrMs: 800)])
        let first = try await store.insertAndMarkJobsOwed(
            chunk, deviceId: "dev", postOffloadJobKinds: kinds, note: nil)
        XCTAssertEqual(first.counts.hr, 1)
        XCTAssertEqual(first.counts.rr, 1)
        XCTAssertTrue(first.markedJobs)
        let hrFrontier = try await store.backfillFrontierForTest(deviceId: "dev", stream: "hr")
        XCTAssertEqual(hrFrontier, 1_700_000_100)
        let tokens = Dictionary(uniqueKeysWithValues:
            (try await store.owedJobs()).map { ($0.kind, $0.token) })

        let replay = try await store.insertAndMarkJobsOwed(
            chunk, deviceId: "dev", postOffloadJobKinds: kinds, note: nil)
        XCTAssertEqual(replay.counts.hr, 0)
        XCTAssertEqual(replay.counts.rr, 0)
        XCTAssertFalse(replay.markedJobs)
        let replayHrFrontier = try await store.backfillFrontierForTest(deviceId: "dev", stream: "hr")
        XCTAssertEqual(replayHrFrontier, hrFrontier)
        let after = Dictionary(uniqueKeysWithValues:
            (try await store.owedJobs()).map { ($0.kind, $0.token) })
        XCTAssertEqual(after, tokens)
        let stats = try await store.storageStats_rowCountsForTest()
        XCTAssertEqual(stats.hr, 1)
        XCTAssertEqual(stats.rr, 1)
    }

    func testReplayWithNewerRowInsertsOnlyAbsentRows() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev", mac: nil, name: nil)
        let kinds = [SyncJobKind.rescore.rawValue]
        let first = Streams(
            hr: [HRSample(ts: 1_700_000_100, bpm: 61)],
            rr: [RRInterval(ts: 1_700_000_100, rrMs: 800)])
        _ = try await store.insertAndMarkJobsOwed(
            first, deviceId: "dev", postOffloadJobKinds: kinds, note: nil)

        let replay = Streams(
            hr: [HRSample(ts: 1_700_000_100, bpm: 61), HRSample(ts: 1_700_000_101, bpm: 62)],
            rr: [RRInterval(ts: 1_700_000_100, rrMs: 800)])
        let outcome = try await store.insertAndMarkJobsOwed(
            replay, deviceId: "dev", postOffloadJobKinds: kinds, note: nil)
        XCTAssertEqual(outcome.counts.hr, 1, "only the newer hr row should insert")
        XCTAssertEqual(outcome.counts.rr, 0, "natural-key replay must not add an RR interval")
        let hrFrontier = try await store.backfillFrontierForTest(deviceId: "dev", stream: "hr")
        let rrFrontier = try await store.backfillFrontierForTest(deviceId: "dev", stream: "rr")
        XCTAssertEqual(hrFrontier, 1_700_000_101)
        XCTAssertEqual(rrFrontier, 1_700_000_100)
    }

    func testLiveInsertDoesNotConsultFrontier() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev", mac: nil, name: nil)
        let backfill = Streams(hr: [HRSample(ts: 1_700_000_100, bpm: 61)])
        _ = try await store.insertAndMarkJobsOwed(
            backfill, deviceId: "dev", postOffloadJobKinds: [SyncJobKind.rescore.rawValue], note: nil)
        let hrFrontier = try await store.backfillFrontierForTest(deviceId: "dev", stream: "hr")
        XCTAssertEqual(hrFrontier, 1_700_000_100)

        // Live inserts and backfill both deduplicate by natural identity.
        let live = Streams(hr: [HRSample(ts: 1_700_000_100, bpm: 61)])
        let n = try await store.insert(live, deviceId: "dev")
        XCTAssertEqual(n.hr, 0)
        let afterFrontier = try await store.backfillFrontierForTest(deviceId: "dev", stream: "hr")
        XCTAssertEqual(afterFrontier, 1_700_000_100)
    }

    func testEveryLegacyFrontierAllowsAbsentOlderRowsAndReplayKeepsDebtToken() async throws {
        let cases: [(table: String, stream: String, scores: Bool, make: (Int) -> Streams)] = [
            ("hrSample", "hr", true, { Streams(hr: [HRSample(ts: $0, bpm: 61)]) }),
            ("rrInterval", "rr", true, { Streams(rr: [RRInterval(ts: $0, rrMs: 800)]) }),
            ("event", "event", true, { Streams(events: [WhoopEvent(ts: $0, kind: "off_wrist", payload: [:])]) }),
            ("battery", "battery", false, { Streams(battery: [BatterySample(ts: $0, soc: 80, mv: 3900)]) }),
            ("spo2Sample", "spo2", true, { Streams(spo2: [SpO2Sample(ts: $0, red: 123, ir: 456)]) }),
            ("skinTempSample", "skinTemp", true, { Streams(skinTemp: [SkinTempSample(ts: $0, raw: 3300)]) }),
            ("respSample", "resp", true, { Streams(resp: [RespSample(ts: $0, raw: 12)]) }),
            ("gravitySample", "gravity", true, { Streams(gravity: [GravitySample(ts: $0, x: 0, y: 0, z: 1)]) }),
            ("stepSample", "steps", true, { Streams(steps: [StepSample(ts: $0, counter: 12)]) }),
            ("sleepStateSample", "sleepState", true, { Streams(sleepState: [SleepStateSample(ts: $0, state: 2)]) }),
            ("ppgHrSample", "ppgHr", true, { Streams(ppgHr: [PpgHrSample(ts: $0, bpm: 60, conf: 0.9)]) }),
            ("v18AuxSample", "v18Aux", false, { Streams(v18Aux: [V18AuxSample(ts: $0, recordIndex: 3)]) }),
        ]
        let store = try await WhoopStore.inMemory()
        let newer = 1_700_000_100, older = newer - 1
        for test in cases {
            let device = test.table
            let kind = "late-" + test.stream
            _ = try await store.insertAndMarkJobsOwed(test.make(newer), deviceId: device,
                                                       postOffloadJobKinds: [kind])
            try await store.clearJob(kind: kind)
            let late = try await store.insertAndMarkJobsOwed(test.make(older), deviceId: device,
                                                             postOffloadJobKinds: [kind])
            XCTAssertEqual(late.markedJobs, test.scores, test.table)
            let beforeReplay = try await store.owedJobs().first { $0.kind == kind }?.token
            let replay = try await store.insertAndMarkJobsOwed(test.make(older), deviceId: device,
                                                               postOffloadJobKinds: [kind])
            XCTAssertFalse(replay.markedJobs, test.table)
            let afterReplay = try await store.owedJobs().first { $0.kind == kind }?.token
            XCTAssertEqual(afterReplay, beforeReplay, test.table)
            try await store.registryWriter.read { db in
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM \(test.table) WHERE deviceId=?",
                                               arguments: [device]), 2, test.table)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM \(test.table) WHERE deviceId=? AND ts=?",
                                               arguments: [device, older]), 1, test.table)
            }
            let frontier = try await store.backfillFrontierForTest(deviceId: device, stream: test.stream)
            XCTAssertEqual(frontier, newer, "late data must not lower the diagnostic watermark")
        }
    }

    func testSameSecondDistinctAndEqualOccurrenceIdentitiesSurviveAcrossChunks() async throws {
        let store = try await WhoopStore.inMemory()
        let ts = 1_700_000_100
        func chunk(expanded: Bool) -> Streams {
            Streams(rr: (expanded ? [800, 800, 900] : [800]).map { RRInterval(ts: ts, rrMs: $0) },
                    ppgWaveform: [PpgWaveformSample(ts: ts, samples: [expanded ? 2 : 1], recordIndex: expanded ? 11 : 10)],
                    events: [WhoopEvent(ts: ts, kind: expanded ? "on_wrist" : "off_wrist", payload: [:])])
        }
        _ = try await store.insertAndMarkJobsOwed(chunk(expanded: false), deviceId: "d", postOffloadJobKinds: ["rescore"])
        try await store.clearJob(kind: "rescore")
        let added = try await store.insertAndMarkJobsOwed(chunk(expanded: true), deviceId: "d", postOffloadJobKinds: ["rescore"])
        XCTAssertEqual(added.counts.rr, 2)
        XCTAssertEqual(added.counts.events, 1)
        XCTAssertTrue(added.markedJobs)
        let token = try await store.owedJobs().first?.token
        let replay = try await store.insertAndMarkJobsOwed(chunk(expanded: true), deviceId: "d", postOffloadJobKinds: ["rescore"])
        XCTAssertEqual(replay.counts.rr, 0)
        XCTAssertEqual(replay.counts.events, 0)
        XCTAssertFalse(replay.markedJobs)
        let replayToken = try await store.owedJobs().first?.token
        XCTAssertEqual(replayToken, token)
        try await store.registryWriter.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT rrMs, seq FROM rrInterval WHERE deviceId='d' ORDER BY rrMs, seq")
            XCTAssertEqual(rows.map { $0["rrMs"] as Int }, [800, 800, 900])
            XCTAssertEqual(rows.map { $0["seq"] as Int }, [0, 1, 0])
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM event WHERE deviceId='d'"), 2)
        }
        let ppg = try await store.ppgWaveformSamples(deviceId: "d", from: ts, to: ts)
        XCTAssertEqual(ppg.map(\.recordIndex), [10, 11])
        XCTAssertEqual(ppg.map(\.samples), [[1], [2]])
    }
}
