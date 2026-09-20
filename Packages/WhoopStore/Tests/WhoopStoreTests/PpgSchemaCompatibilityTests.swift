import Foundation
import GRDB
import WhoopProtocol
import XCTest
@testable import WhoopStore

final class PpgSchemaCompatibilityTests: XCTestCase {
    func testLegacyMigrationPreservesBytesAndRowIDsUsedByUploadCursors() throws {
        let dbq = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(dbq, upTo: "v47-server-score-cache")
        let blob = WhoopStore.packPpgSamples([-32768, 7, 32767])
        try dbq.write { db in
            try db.execute(sql: """
                INSERT INTO ppgWaveformSample (rowid, deviceId, ts, samples, burstIndex)
                VALUES (88, 'legacy', 123, ?, 14)
                """, arguments: [blob])
        }
        try WhoopStore.makeMigrator().migrate(dbq)
        try dbq.read { db in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT rowid, * FROM ppgWaveformSample"))
            XCTAssertEqual(row["rowid"] as Int, 88)
            XCTAssertEqual(row["samples"] as Data, blob)
            XCTAssertEqual(row["burstIndex"] as Int, 14)
            XCTAssertEqual(row["recordIndex"] as Int, -1)
            XCTAssertEqual(try db.primaryKey("ppgWaveformSample").columns,
                           ["deviceId", "ts", "recordIndex"])
        }
    }

    /// Mirrors the installed phone: both differently named v45 migrations have run, and the
    /// PPG key was widened by a research build. The old SQL must fail before we verify recovery.
    func testResearchSchemaReopensWithoutLosingSameSecondRecords() async throws {
        let path = NSTemporaryDirectory() + "ppg-compat-\(UUID().uuidString).sqlite"
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        let dbq = try DatabaseQueue(path: path)
        try WhoopStore.makeMigrator().migrate(dbq, upTo: "v47-server-score-cache")
        try await dbq.write { db in
            try db.execute(sql: """
                DROP TABLE ppgWaveformSample;
                CREATE TABLE ppgWaveformSample (
                    deviceId TEXT NOT NULL, ts INTEGER NOT NULL, samples BLOB NOT NULL,
                    burstIndex INTEGER, recordIndex INTEGER NOT NULL,
                    PRIMARY KEY(deviceId, ts, recordIndex));
                INSERT INTO ppgWaveformSample VALUES ('compat-test', 123, X'0100', 14, 10);
                INSERT INTO ppgWaveformSample VALUES ('compat-test', 123, X'0200', 14, 11);
                INSERT INTO grdb_migrations VALUES ('v45-v26-record-index');
                """)
            XCTAssertThrowsError(try db.execute(sql: """
                INSERT INTO ppgWaveformSample (deviceId, ts, samples, burstIndex)
                VALUES ('compat-test', 123, X'0300', 14)
                ON CONFLICT(deviceId, ts) DO NOTHING
                """)) { error in
                XCTAssertTrue(String(describing: error).contains("ON CONFLICT clause does not match"))
            }
        }
        let store = try await WhoopStore(path: path)
        let input = Streams(hr: [HRSample(ts: 123, bpm: 65)], ppgWaveform: [
            PpgWaveformSample(ts: 123, samples: [3], burstIndex: 14),
            PpgWaveformSample(ts: 123, samples: [4], burstIndex: 14, recordIndex: 12),
        ])
        let first = try await store.insertAndMarkJobsOwed(input, deviceId: "compat-test",
                                                       postOffloadJobKinds: ["compat-scoring"])
        XCTAssertEqual(first.counts.hr, 1)
        XCTAssertTrue(first.markedJobs, "mixed chunk and downstream debt commit atomically")
        let replay = try await store.insertAndMarkJobsOwed(input, deviceId: "compat-test",
                                                        postOffloadJobKinds: ["compat-scoring"])
        XCTAssertEqual(replay.counts.hr, 0)
        XCTAssertFalse(replay.markedJobs)
        let rows = try await store.ppgWaveformSamples(deviceId: "compat-test", from: 123, to: 123)
        XCTAssertEqual(rows.map(\.recordIndex), [nil, 10, 11, 12])
        XCTAssertEqual(rows.map(\.samples), [[3], [1], [2], [4]])
        let jobs = try await store.owedJobs()
        XCTAssertEqual(jobs.map(\.kind), ["compat-scoring"])
        try await dbq.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT rowid FROM ppgWaveformSample WHERE recordIndex=10"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT rowid FROM ppgWaveformSample WHERE recordIndex=11"), 2)
        }
    }

    /// Opt-in acceptance against a PRIVATE SQLITE BACKUP COPY, never the handset database.
    /// The caller supplies a disposable clone; no patient values are printed or checked in.
    func testCopiedPhoneDatabaseAcceptsMixedHistoryAndIdempotentReplay() async throws {
        guard let path = ProcessInfo.processInfo.environment["WHOOP_SYNC_TEST_DATABASE_COPY"] else {
            throw XCTSkip("Requires a disposable copy of the phone database")
        }
        let before = try DatabaseQueue(path: path)
        let count = try await before.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ppgWaveformSample") ?? 0
        }
        let store = try await WhoopStore(path: path)
        let streams = Streams(hr: [HRSample(ts: 123, bpm: 65)], ppgWaveform: [
            PpgWaveformSample(ts: 123, samples: [7, -7], burstIndex: 14, recordIndex: 123),
            PpgWaveformSample(ts: 123, samples: [8, -8], burstIndex: 14, recordIndex: 124),
        ])
        let first = try await store.insertAndMarkJobsOwed(streams, deviceId: "compat-copy-test",
                                                       postOffloadJobKinds: ["compat-copy-scoring"])
        XCTAssertEqual(first.counts.hr, 1)
        XCTAssertTrue(first.markedJobs)
        let replay = try await store.insertAndMarkJobsOwed(streams, deviceId: "compat-copy-test",
                                                        postOffloadJobKinds: ["compat-copy-scoring"])
        XCTAssertEqual(replay.counts.hr, 0)
        XCTAssertFalse(replay.markedJobs)
        let afterCount = try await store.ppgWaveformCountForTest()
        XCTAssertEqual(afterCount, count + 2)
        let rows = try await store.ppgWaveformSamples(deviceId: "compat-copy-test", from: 123, to: 123)
        XCTAssertEqual(rows, streams.ppgWaveform)
    }
}
