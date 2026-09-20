import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

final class SyncJobStoreTests: XCTestCase {

    private func store() async throws -> WhoopStore {
        try await WhoopStore.inMemory()
    }

    // MARK: - Migration shape

    func testV44AddsSyncJobTablesAdditively() async throws {
        let s = try await store()
        let tables = try await s.tableNames()
        XCTAssertTrue(tables.contains("syncJob"))
        XCTAssertTrue(tables.contains("syncJournalEntry"))

        let jobPK = try await s.primaryKeyColumns("syncJob")
        XCTAssertEqual(jobPK, ["kind"])

        let jobCols = try await s.columnNamesForTest(table: "syncJob")
        XCTAssertEqual(jobCols, ["kind", "owedAt", "token", "attempts", "lastNote"])

        let journalCols = try await s.columnNamesForTest(table: "syncJournalEntry")
        XCTAssertEqual(journalCols, ["id", "ts", "wakeReason", "stagesRun", "stagesOwed", "durationMs", "note"])
    }

    // MARK: - Token semantics (#1681)

    func testStaleTokenCannotSettle() async throws {
        let s = try await store()
        let first = try await s.markJobOwed(kind: SyncJobKind.cloudPush.rawValue)
        _ = try await s.markJobOwed(kind: SyncJobKind.cloudPush.rawValue)
        let staleSettled = try await s.settleJob(kind: SyncJobKind.cloudPush.rawValue, token: first)
        XCTAssertFalse(staleSettled)

        let owed = try await s.owedJobs()
        XCTAssertEqual(owed.count, 1)
        XCTAssertNotEqual(owed[0].token, first)

        let settled = try await s.settleJob(kind: SyncJobKind.cloudPush.rawValue, token: owed[0].token)
        XCTAssertTrue(settled)
        let remaining = try await s.owedJobs()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testMatchingTokenSettles() async throws {
        let s = try await store()
        let token = try await s.markJobOwed(kind: SyncJobKind.widgetPublish.rawValue, note: "test")
        let settled = try await s.settleJob(kind: SyncJobKind.widgetPublish.rawValue, token: token)
        XCTAssertTrue(settled)
    }

    func testBatchMarkIsAtomicInShapeAndRefreshesEveryToken() async throws {
        let s = try await store()
        let kinds = [SyncJobKind.rescore.rawValue, SyncJobKind.healthWriteback.rawValue,
                     SyncJobKind.widgetPublish.rawValue]
        let first = try await s.markJobsOwed(kinds: kinds, note: "chunk-1")
        XCTAssertEqual(Set(first.keys), Set(kinds))
        let firstRows = try await s.owedJobs()
        XCTAssertEqual(Set(firstRows.map(\.kind)), Set(kinds))

        try await s.recordJobAttempt(kind: SyncJobKind.rescore.rawValue)
        let second = try await s.markJobsOwed(kinds: kinds, note: "chunk-2")
        for kind in kinds {
            XCTAssertNotEqual(first[kind], second[kind])
            let staleSettled = try await s.settleJob(kind: kind, token: first[kind] ?? "")
            XCTAssertFalse(staleSettled)
        }
        let rows = try await s.owedJobs()
        XCTAssertTrue(rows.allSatisfy { $0.attempts == 0 && $0.lastNote == "chunk-2" })
    }

    func testRecordJobAttemptIncrements() async throws {
        let s = try await store()
        let stale = try await s.markJobOwed(kind: SyncJobKind.healthWriteback.rawValue)
        let current = try await s.markJobOwed(kind: SyncJobKind.healthWriteback.rawValue)
        try await s.recordJobAttempt(kind: SyncJobKind.healthWriteback.rawValue, token: stale)
        try await s.recordJobAttempt(kind: SyncJobKind.healthWriteback.rawValue, token: current)
        try await s.recordJobAttempt(kind: SyncJobKind.healthWriteback.rawValue)
        let job = try await s.owedJobs().first
        XCTAssertEqual(job?.attempts, 2, "the stale generation must not increment the current job")
    }

    // MARK: - Journal cap

    func testJournalCapSweepsOldestRows() async throws {
        let s = try await store()
        let keep = WhoopStore.syncJournalRetentionRows
        for i in 0..<(keep + 5) {
            try await s.appendSyncJournal(
                wakeReason: "manual",
                stagesRun: ["rescore"],
                stagesOwed: [],
                durationMs: i,
                note: "row-\(i)"
            )
        }
        let rows = try await s.recentSyncJournal(limit: keep + 10)
        XCTAssertEqual(rows.count, keep)
        XCTAssertEqual(rows.first?.durationMs, keep + 4)
        XCTAssertEqual(rows.last?.durationMs, 5)
    }

    func testMirrorRescoreJobPreservesExternalToken() async throws {
        let s = try await store()
        let external = "external-rescore-token"
        try await s.mirrorRescoreJob(token: external, owedAt: 1_700_000_000)
        let job = try await s.owedJobs().first
        XCTAssertEqual(job?.kind, SyncJobKind.rescore.rawValue)
        XCTAssertEqual(job?.token, external)
    }

    // MARK: - Atomic backfill insert-and-mark (safe-trim invariant across process death)

    func testAtomicInsertMarksJobsAndDuplicateReplayDoesNotRefreshToken() async throws {
        let s = try await store()
        let streams = Streams(hr: [HRSample(ts: 1_700_000_001, bpm: 61)])
        let kinds = [SyncJobKind.rescore.rawValue, SyncJobKind.widgetPublish.rawValue]

        let first = try await s.insertAndMarkJobsOwed(
            streams, deviceId: "test", postOffloadJobKinds: kinds, note: nil)
        XCTAssertEqual(first.counts.hr, 1)
        XCTAssertTrue(first.markedJobs)
        let tokens = Dictionary(uniqueKeysWithValues:
            (try await s.owedJobs()).map { ($0.kind, $0.token) })
        XCTAssertEqual(tokens.count, 3)
        XCTAssertNotNil(tokens[SyncJobKind.cloudPush.rawValue])
        XCTAssertNotNil(tokens[SyncJobKind.rescore.rawValue])

        // Duplicate-only replay: rows dedupe to zero, debt must neither refresh nor disappear.
        let replay = try await s.insertAndMarkJobsOwed(
            streams, deviceId: "test", postOffloadJobKinds: kinds, note: nil)
        XCTAssertEqual(replay.counts.hr, 0)
        XCTAssertFalse(replay.markedJobs)
        let after = Dictionary(uniqueKeysWithValues:
            (try await s.owedJobs()).map { ($0.kind, $0.token) })
        XCTAssertEqual(after, tokens)
    }

    func testAtomicInsertMarksForEveryScoringOnlyStream() async throws {
        let s = try await store()
        let kinds = [SyncJobKind.rescore.rawValue]
        let cases: [(String, Streams)] = [
            ("steps", Streams(steps: [StepSample(ts: 1_700_000_002, counter: 12)])),
            ("sleepState", Streams(sleepState: [SleepStateSample(ts: 1_700_000_002, state: 2)])),
            ("ppgHr", Streams(ppgHr: [PpgHrSample(ts: 1_700_000_002, bpm: 61, conf: 0.9)])),
            ("events", Streams(events: [WhoopEvent(ts: 1_700_000_002, kind: "x", payload: [:])])),
            ("batteryOnly", Streams(battery: [BatterySample(ts: 1_700_000_002, soc: 80, mv: 3_900)])),
        ]
        for (name, streams) in cases {
            let outcome = try await s.insertAndMarkJobsOwed(
                streams, deviceId: "dev-\(name)", postOffloadJobKinds: kinds, note: nil)
            if name == "batteryOnly" {
                XCTAssertFalse(outcome.markedJobs, "\(name) must not create rescore debt")
            } else {
                XCTAssertTrue(outcome.markedJobs, "\(name) must create rescore debt")
            }
        }
    }
}
