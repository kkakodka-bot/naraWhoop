import XCTest
import WhoopProtocol
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

    func testDuplicateChunkReplaySkipsInsertLoops() async throws {
        UserDefaults.standard.set(true, forKey: "enableBackfillRangeSkip")
        defer { UserDefaults.standard.removeObject(forKey: "enableBackfillRangeSkip") }
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

    func testReplayWithNewerRowRunsOnlyAffectedStream() async throws {
        UserDefaults.standard.set(true, forKey: "enableBackfillRangeSkip")
        defer { UserDefaults.standard.removeObject(forKey: "enableBackfillRangeSkip") }
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
        XCTAssertEqual(outcome.counts.rr, 0, "rr at/below frontier should skip the insert loop")
        let hrFrontier = try await store.backfillFrontierForTest(deviceId: "dev", stream: "hr")
        let rrFrontier = try await store.backfillFrontierForTest(deviceId: "dev", stream: "rr")
        XCTAssertEqual(hrFrontier, 1_700_000_101)
        XCTAssertEqual(rrFrontier, 1_700_000_100)
    }

    func testLiveInsertDoesNotConsultFrontier() async throws {
        UserDefaults.standard.set(true, forKey: "enableBackfillRangeSkip")
        defer { UserDefaults.standard.removeObject(forKey: "enableBackfillRangeSkip") }
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev", mac: nil, name: nil)
        let backfill = Streams(hr: [HRSample(ts: 1_700_000_100, bpm: 61)])
        _ = try await store.insertAndMarkJobsOwed(
            backfill, deviceId: "dev", postOffloadJobKinds: [SyncJobKind.rescore.rawValue], note: nil)
        let hrFrontier = try await store.backfillFrontierForTest(deviceId: "dev", stream: "hr")
        XCTAssertEqual(hrFrontier, 1_700_000_100)

        // Live path: same row, no job kinds — must still run the insert loop (DO NOTHING), not range-skip.
        let live = Streams(hr: [HRSample(ts: 1_700_000_100, bpm: 61)])
        let n = try await store.insert(live, deviceId: "dev")
        XCTAssertEqual(n.hr, 0)
        let afterFrontier = try await store.backfillFrontierForTest(deviceId: "dev", stream: "hr")
        XCTAssertEqual(afterFrontier, 1_700_000_100)
    }

    func testDisorderedChunkBelowFrontierStillInsertsWhenSkipDisabled() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev", mac: nil, name: nil)
        let kinds = [SyncJobKind.rescore.rawValue]
        UserDefaults.standard.set(true, forKey: "enableBackfillRangeSkip")
        let first = Streams(hr: [HRSample(ts: 1_700_000_200, bpm: 65)])
        _ = try await store.insertAndMarkJobsOwed(
            first, deviceId: "dev", postOffloadJobKinds: kinds, note: nil)
        let frontier = try await store.backfillFrontierForTest(deviceId: "dev", stream: "hr")
        XCTAssertEqual(frontier, 1_700_000_200)
        UserDefaults.standard.set(false, forKey: "enableBackfillRangeSkip")
        defer { UserDefaults.standard.removeObject(forKey: "enableBackfillRangeSkip") }

        // Chunk max ts is at/below frontier but carries a genuinely-new older row (disordered replay).
        let disordered = Streams(hr: [
            HRSample(ts: 1_700_000_100, bpm: 61),
            HRSample(ts: 1_700_000_200, bpm: 65),
        ])
        let outcome = try await store.insertAndMarkJobsOwed(
            disordered, deviceId: "dev", postOffloadJobKinds: kinds, note: nil)
        XCTAssertEqual(outcome.counts.hr, 1, "older row must insert when range-skip is off")
        let stats = try await store.storageStats_rowCountsForTest()
        XCTAssertEqual(stats.hr, 2)
    }

    func testExactReplaySkipsWhenSkipEnabled() async throws {
        UserDefaults.standard.set(true, forKey: "enableBackfillRangeSkip")
        defer { UserDefaults.standard.removeObject(forKey: "enableBackfillRangeSkip") }
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev", mac: nil, name: nil)
        let kinds = [SyncJobKind.rescore.rawValue]
        let chunk = Streams(hr: [HRSample(ts: 1_700_000_100, bpm: 61)])
        _ = try await store.insertAndMarkJobsOwed(
            chunk, deviceId: "dev", postOffloadJobKinds: kinds, note: nil)
        let replay = try await store.insertAndMarkJobsOwed(
            chunk, deviceId: "dev", postOffloadJobKinds: kinds, note: nil)
        XCTAssertEqual(replay.counts.hr, 0)
        let stats = try await store.storageStats_rowCountsForTest()
        XCTAssertEqual(stats.hr, 1)
    }
}
