import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

final class RrPromotionExportTests: XCTestCase {
    func testMetadataPromotionCrossesSavedAppendCursorAndCreatesDebtWithoutAddingBeats() async throws {
        let store = try await WhoopStore.inMemory()
        let native = Streams(rr: [RRInterval(ts: 100, rrMs: 800, srcChannel: .whoop5Realtime),
                                  RRInterval(ts: 101, rrMs: 900, srcChannel: .whoop5Realtime)])
        _ = try await store.insert(native, deviceId: "d")
        let cursor = try await store.registryWriter.write { db -> Int in
            try db.execute(sql: "UPDATE rrInterval SET synced=1, tsSuspect=0 WHERE ts=100")
            return try Int.fetchOne(db, sql: "SELECT MAX(rowid) FROM rrInterval")!
        }
        let before = try await store.rrIntervals(deviceId: "d", from: 100, to: 101, limit: 10)
        XCTAssertTrue(before.isEmpty)
        let standard = Streams(rr: [RRInterval(ts: 100, rrMs: 800, srcChannel: .whoop5Standard)])
        let change = try await store.insertAndMarkJobsOwed(standard, deviceId: "d", postOffloadJobKinds: ["rescore"])
        XCTAssertEqual(change.counts.rr, 0, "source promotion must not add a numerical beat")
        XCTAssertTrue(change.markedJobs)
        let after = try await store.rrIntervals(deviceId: "d", from: 100, to: 101, limit: 10)
        XCTAssertEqual(after.map(\.rrMs), [800])
        let promotedRowid = try await store.registryWriter.read { db -> Int in
            let rows = try Row.fetchAll(db, sql: "SELECT rowid, * FROM rrInterval WHERE deviceId=? AND rowid>? ORDER BY rowid",
                                       arguments: ["d", cursor])
            XCTAssertEqual(rows.count, 1, "the append snapshot must include changed provenance")
            let row = try XCTUnwrap(rows.first)
            XCTAssertEqual(row["ts"] as Int, 100)
            XCTAssertEqual(row["rrMs"] as Int, 800)
            XCTAssertEqual(row["seq"] as Int, 0)
            XCTAssertEqual(row["ord"] as Int, 0)
            XCTAssertEqual(row["srcChannel"] as Int, 7)
            XCTAssertEqual(row["tsSuspect"] as Int, 0)
            XCTAssertEqual(row["synced"] as Int, 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM rrInterval"), 2)
            return row["rowid"]
        }
        let token = try await store.owedJobs().first?.token
        for batch in [standard, native] {
            let replay = try await store.insertAndMarkJobsOwed(batch, deviceId: "d", postOffloadJobKinds: ["rescore"])
            XCTAssertEqual(replay.counts.rr, 0)
            XCTAssertFalse(replay.markedJobs)
        }
        let afterReplay = try await store.owedJobs().first?.token
        XCTAssertEqual(afterReplay, token)
        try await store.registryWriter.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT rowid FROM rrInterval WHERE ts=100"), promotedRowid)
        }
    }

    func testPromotionAfterDeletingHighestRowInvalidatesReusedCursorIdentity() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.insert(Streams(rr: [RRInterval(ts: 100, rrMs: 800, srcChannel: .whoop5Realtime),
                                                RRInterval(ts: 101, rrMs: 900, srcChannel: .whoop5Realtime)]), deviceId: "d")
        let cursor = try await store.registryWriter.write { db -> Int in
            let cursor = try Int.fetchOne(db, sql: "SELECT rowid FROM rrInterval WHERE ts=101")!
            try db.execute(sql: "DELETE FROM rrInterval WHERE ts=101")
            return cursor
        }
        _ = try await store.insert(Streams(rr: [RRInterval(ts: 100, rrMs: 800, srcChannel: .whoop5Standard)]), deviceId: "d")
        try await store.registryWriter.read { db in
            let atCursor = try Row.fetchOne(db, sql: "SELECT ts, rrMs, seq FROM rrInterval WHERE rowid=?", arguments: [cursor])
            XCTAssertNotEqual(atCursor?["ts"] as Int?, 101,
                              "the push cursor key check must reset when a deleted rowid is reused")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM rrInterval"), 1)
        }
    }
}
