import Foundation
import GRDB
import XCTest
@testable import WhoopStore

final class ServerScoreCacheEfficiencyTests: XCTestCase {
    private let owner = ServerScoreCacheOwner(projectURL: "https://fixture.invalid", userID: "synthetic-owner")

    private func database(path: String? = nil, trace: CacheSQLTrace = CacheSQLTrace()) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.defaultTransactionKind = .immediate
        configuration.prepareDatabase { db in
            db.trace { event in
                if case .statement(let statement) = event { trace.append(statement.sql) }
            }
        }
        let db = try path.map { try DatabaseQueue(path: $0, configuration: configuration) }
            ?? DatabaseQueue(configuration: configuration)
        var migrator = DatabaseMigrator()
        ServerScoreCacheMigration.register(in: &migrator)
        try migrator.migrate(db)
        trace.reset()
        return db
    }

    private func key(day: Int = 1, device: String = "synthetic-device", zone: String = "UTC",
                     owner: ServerScoreCacheOwner? = nil) -> ServerScoreCacheKey {
        ServerScoreCacheKey(owner: owner ?? self.owner, sourceDeviceID: device,
            day: String(format: "2026-09-%02d", day), timeZoneID: zone, schemaVersion: 2,
            algorithmVersion: "synthetic-v1")
    }

    private func snapshot(_ key: ServerScoreCacheKey, input: Int64 = 1, result: Int64 = 1,
                          state: ServerScoreCachedSnapshot.State = .available,
                          payload: String = "{\"daily\":null,\"sleep\":[]}", fetched: Double = 1) -> ServerScoreCachedSnapshot {
        ServerScoreCachedSnapshot(key: key, inputRevision: input, resultRevision: result, state: state,
                                  payload: Data(payload.utf8), fetchedAt: Date(timeIntervalSince1970: fetched))
    }

    private func session() -> ServerScoreCacheSession { .init(owner: owner, generation: UUID()) }
    private func time(_ value: Double) -> Date { Date(timeIntervalSince1970: value) }

    func testFourteenDayHydrationCommitsOneLRUTransactionWithoutPayloadWrites() async throws {
        let trace = CacheSQLTrace()
        let db = try database(trace: trace)
        let cache = ServerScoreSnapshotCache(db: db)
        let session = session()
        await cache.activate(session)
        for day in 1...14 {
            try await cache.store(snapshot(key(day: day), fetched: Double(day)), session: session, now: time(1))
        }
        trace.reset()
        let loaded = try await cache.loadRecent(session: session, timeZoneID: "UTC", now: time(20))
        XCTAssertEqual(loaded.count, 14)
        XCTAssertEqual(loaded.map(\.key.day), (1...14).reversed().map { String(format: "2026-09-%02d", $0) })
        XCTAssertEqual(trace.writeTransactions, 1)
        XCTAssertEqual(trace.updates.count, 14)
        XCTAssertTrue(trace.payloadWrites.isEmpty)
        XCTAssertTrue(trace.evictions.isEmpty)
        let touched = try await db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM serverScoreSnapshotCache WHERE accessedAt=20") }
        XCTAssertEqual(touched, 14)
        XCTAssertEqual(loaded.map { $0.fetchedAt.timeIntervalSince1970 }, (1...14).reversed().map(Double.init))
    }

    func testMissesAndRepeatedIdenticalAccessTimeDoNotStartWriteTransactions() async throws {
        let trace = CacheSQLTrace()
        let db = try database(trace: trace)
        let cache = ServerScoreSnapshotCache(db: db)
        let session = session()
        await cache.activate(session)
        let original = snapshot(key())
        try await cache.store(original, session: session, now: time(10))
        trace.reset()
        let loaded = try await cache.load(key(), session: session, now: time(10))
        let recent = try await cache.loadRecent(session: session, timeZoneID: "UTC", now: time(10))
        let missing = try await cache.load(key(day: 2), session: session, now: time(20))
        let emptyZone = try await cache.loadRecent(session: session, timeZoneID: "Asia/Tokyo", now: time(20))
        XCTAssertEqual(loaded, original)
        XCTAssertEqual(recent, [original])
        XCTAssertNil(missing)
        XCTAssertTrue(emptyZone.isEmpty)
        XCTAssertEqual(trace.writeTransactions, 0)
        XCTAssertTrue(trace.updates.isEmpty)
    }

    func testHydrationTouchesOnlySelectedOwnerTimezoneAndSource() async throws {
        let trace = CacheSQLTrace()
        let db = try database(trace: trace)
        let cache = ServerScoreSnapshotCache(db: db)
        let firstSession = session()
        await cache.activate(firstSession)
        let old = snapshot(key(), result: 99, fetched: 1)
        let selected = snapshot(key(device: "selected-device"), fetched: 2)
        let otherZone = snapshot(key(zone: "Asia/Tokyo"), fetched: 3)
        for row in [old, selected, otherZone] { try await cache.store(row, session: firstSession, now: time(10)) }
        let secondOwner = ServerScoreCacheOwner(projectURL: owner.projectURL, userID: "another-synthetic-owner")
        let secondSession = ServerScoreCacheSession(owner: secondOwner, generation: UUID())
        await cache.activate(secondSession)
        try await cache.store(snapshot(key(owner: secondOwner), fetched: 4), session: secondSession, now: time(10))
        await cache.activate(firstSession)
        trace.reset()
        let loaded = try await cache.loadRecent(session: firstSession, timeZoneID: "UTC", now: time(20))
        XCTAssertEqual(loaded, [selected])
        XCTAssertEqual(trace.writeTransactions, 1)
        XCTAssertEqual(trace.updates.count, 1)
        let counts = try await db.read { db in
            (try Int.fetchOne(db, sql: "SELECT count(*) FROM serverScoreSnapshotCache WHERE accessedAt=20"),
             try Int.fetchOne(db, sql: "SELECT count(*) FROM serverScoreSnapshotCache WHERE accessedAt=10"))
        }
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 3)
        trace.reset()
        do { _ = try await cache.loadRecent(session: secondSession, timeZoneID: "UTC"); XCTFail("Stale account") }
        catch { XCTAssertEqual(error as? ServerScoreSnapshotCacheError, .staleSession) }
        XCTAssertEqual(trace.writeTransactions, 0)
        // Async GRDB reads can finish their transaction cleanup after returning the result above.
        XCTAssertFalse(trace.statements.contains { $0.contains("SERVERSCORESNAPSHOTCACHE") })
    }

    func testCorruptSelectedRowFailsBeforeAnyHydrationTouch() async throws {
        for corruption in ["payload=zeroblob(65)", "state='invalid'", "inputRevision=-1", "resultRevision=0"] {
            let trace = CacheSQLTrace()
            let db = try database(trace: trace)
            let cache = ServerScoreSnapshotCache(db: db, limits: .init(payloadBytes: 64, totalBytes: 128))
            let session = session()
            await cache.activate(session)
            for day in 1...2 {
                try await cache.store(snapshot(key(day: day), fetched: Double(day)), session: session, now: time(10))
            }
            try await db.write { try $0.execute(sql: "UPDATE serverScoreSnapshotCache SET \(corruption) WHERE day='2026-09-01'") }
            trace.reset()
            do { _ = try await cache.loadRecent(session: session, timeZoneID: "UTC", now: time(20)); XCTFail("Corrupt row admitted") }
            catch { XCTAssertEqual(error as? ServerScoreSnapshotCacheError, .corruptRow) }
            XCTAssertEqual(trace.writeTransactions, 0)
            XCTAssertTrue(trace.updates.isEmpty)
            let untouched = try await db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM serverScoreSnapshotCache WHERE accessedAt=10") }
            XCTAssertEqual(untouched, 2)
        }
    }

    func testCoalescedTouchFailureRollsBackEveryAccessUpdate() async throws {
        let trace = CacheSQLTrace()
        let db = try database(trace: trace)
        let cache = ServerScoreSnapshotCache(db: db)
        let session = session()
        await cache.activate(session)
        for day in 1...2 {
            try await cache.store(snapshot(key(day: day), fetched: Double(day)), session: session, now: time(10))
        }
        try await db.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER fail_last_touch BEFORE UPDATE OF accessedAt ON serverScoreSnapshotCache
                WHEN NEW.day='2026-09-01' BEGIN SELECT RAISE(ABORT, 'synthetic touch failure'); END
                """)
        }
        trace.reset()
        do { _ = try await cache.loadRecent(session: session, timeZoneID: "UTC", now: time(20)); XCTFail("Touch failure hidden") }
        catch {}
        XCTAssertEqual(trace.writeTransactions, 1)
        let untouched = try await db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM serverScoreSnapshotCache WHERE accessedAt=10") }
        XCTAssertEqual(untouched, 2)
    }

    func testExactFetchedContentRefreshesMetadataWithoutPayloadRewriteOrEviction() async throws {
        let trace = CacheSQLTrace()
        let db = try database(trace: trace)
        let cache = ServerScoreSnapshotCache(db: db)
        let session = session()
        await cache.activate(session)
        try await cache.store(snapshot(key()), session: session, now: time(10))
        try await db.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER reject_payload_rewrite BEFORE UPDATE OF payload ON serverScoreSnapshotCache
                BEGIN SELECT RAISE(ABORT, 'synthetic payload rewrite'); END
                """)
        }
        trace.reset()
        let fresh = snapshot(key(), fetched: 30)
        let result = try await cache.store(fresh, session: session, now: time(20))
        XCTAssertEqual(result, .refreshed)
        XCTAssertEqual(trace.writeTransactions, 1)
        XCTAssertEqual(trace.updates.count, 1)
        XCTAssertTrue(trace.payloadWrites.isEmpty)
        XCTAssertTrue(trace.evictions.isEmpty)
        let loaded = try await cache.load(key(), session: session, now: time(20))
        XCTAssertEqual(loaded, fresh)
        trace.reset()
        let repeated = try await cache.store(fresh, session: session, now: time(20))
        XCTAssertEqual(repeated, .refreshed)
        XCTAssertTrue(trace.updates.isEmpty)
        XCTAssertTrue(trace.evictions.isEmpty)
    }

    func testRefreshPreservesRevisionConflictsAndOlderResponseFences() async throws {
        let trace = CacheSQLTrace()
        let db = try database(trace: trace)
        let cache = ServerScoreSnapshotCache(db: db)
        let session = session()
        await cache.activate(session)
        let original = snapshot(key(), input: 2, result: 3, fetched: 10)
        try await cache.store(original, session: session, now: time(10))
        let conflicts = [snapshot(key(), input: 3, result: 3, fetched: 20),
                         snapshot(key(), input: 2, result: 3, state: .noData, fetched: 20),
                         snapshot(key(), input: 2, result: 3, payload: "different", fetched: 20)]
        trace.reset()
        for row in conflicts {
            do { try await cache.store(row, session: session, now: time(20)); XCTFail("Revision conflict accepted") }
            catch { XCTAssertEqual(error as? ServerScoreSnapshotCacheError, .revisionConflict) }
        }
        for older in [snapshot(key(), input: 1, result: 4, fetched: 20), snapshot(key(), input: 2, result: 2, fetched: 20)] {
            let result = try await cache.store(older, session: session, now: time(20))
            XCTAssertEqual(result, .ignoredOlderRevision)
        }
        XCTAssertTrue(trace.updates.isEmpty)
        let loaded = try await cache.load(key(), session: session, now: time(10))
        XCTAssertEqual(loaded, original)
    }

    func testChangedRevisionStillReplacesWholePayloadAndEnforcesBoundsAtomically() async throws {
        let trace = CacheSQLTrace()
        let db = try database(trace: trace)
        let cache = ServerScoreSnapshotCache(db: db)
        let session = session()
        await cache.activate(session)
        try await cache.store(snapshot(key()), session: session, now: time(1))
        let replacement = snapshot(key(), input: 2, result: 2, state: .noData,
                                   payload: "{\"daily\":null,\"sleep\":[],\"deleted\":true}", fetched: 2)
        trace.reset()
        let result = try await cache.store(replacement, session: session, now: time(2))
        XCTAssertEqual(result, .inserted)
        XCTAssertEqual(trace.writeTransactions, 1)
        XCTAssertEqual(trace.payloadWrites.count, 1)
        XCTAssertFalse(trace.evictions.isEmpty)
        let loaded = try await cache.load(key(), session: session, now: time(2))
        XCTAssertEqual(loaded, replacement)
    }

    func testTighterReopenedLimitsAreEnforcedForEachNamespace() async throws {
        let trace = CacheSQLTrace()
        let db = try database(trace: trace)
        let loose = ServerScoreSnapshotCache(db: db)
        let session = session()
        await loose.activate(session)
        for device in ["device-a", "device-b"] {
            for day in 1...2 {
                try await loose.store(snapshot(key(day: day, device: device)), session: session, now: time(Double(day)))
            }
        }
        let tight = ServerScoreSnapshotCache(db: db, limits: .init(daysPerNamespace: 1))
        await tight.activate(session)
        for device in ["device-a", "device-b"] {
            try await tight.store(snapshot(key(day: 2, device: device)), session: session, now: time(10))
            let count = try await db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM serverScoreSnapshotCache WHERE sourceDeviceID=?", arguments: [device]) }
            XCTAssertEqual(count, 1)
        }
        trace.reset()
        try await tight.store(snapshot(key(day: 2, device: "device-b")), session: session, now: time(11))
        XCTAssertTrue(trace.evictions.isEmpty)
    }

    func testSameWriterAndExternalConnectionChangesInvalidateEvictionProof() async throws {
        for external in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            let path = directory.appendingPathComponent("synthetic.sqlite").path
            let trace = CacheSQLTrace()
            let db = try database(path: path, trace: trace)
            let tight = ServerScoreSnapshotCache(db: db, limits: .init(daysPerNamespace: 1))
            let session = session()
            await tight.activate(session)
            try await tight.store(snapshot(key()), session: session, now: time(1))
            let other = try external ? database(path: path) : db
            let loose = ServerScoreSnapshotCache(db: other)
            await loose.activate(session)
            try await loose.store(snapshot(key(day: 2)), session: session, now: time(2))
            trace.reset()
            try await tight.store(snapshot(key()), session: session, now: time(3))
            XCTAssertFalse(trace.evictions.isEmpty, "external=\(external)")
            let days = try await db.read { try String.fetchAll($0, sql: "SELECT day FROM serverScoreSnapshotCache") }
            XCTAssertEqual(days, ["2026-09-01"])
        }
    }

    func testRejectedCommitCannotEstablishAnEvictionProof() async throws {
        let db = try database()
        let session = session()
        let loose = ServerScoreSnapshotCache(db: db)
        await loose.activate(session)
        for day in 1...2 { try await loose.store(snapshot(key(day: day)), session: session, now: time(1)) }
        let tight = ServerScoreSnapshotCache(db: db, limits: .init(daysPerNamespace: 1))
        await tight.activate(session)
        let rejection = CacheRejectCommit()
        db.add(transactionObserver: rejection)
        do { try await tight.store(snapshot(key()), session: session, now: time(2)); XCTFail("Commit failure hidden") }
        catch {}
        db.remove(transactionObserver: rejection)
        let retained = try await db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM serverScoreSnapshotCache") }
        XCTAssertEqual(retained, 2)
        try await tight.store(snapshot(key()), session: session, now: time(2))
        let bounded = try await db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM serverScoreSnapshotCache") }
        XCTAssertEqual(bounded, 1)
    }

    func testExactRefreshUpdatesOfflineSourceSelectionAndInvalidTimeFailsBeforeSQL() async throws {
        let trace = CacheSQLTrace()
        let db = try database(trace: trace)
        let cache = ServerScoreSnapshotCache(db: db)
        let session = session()
        await cache.activate(session)
        try await cache.store(snapshot(key(), fetched: 1), session: session, now: time(1))
        try await cache.store(snapshot(key(device: "other-device"), fetched: 2), session: session, now: time(2))
        let latest = snapshot(key(), fetched: 3)
        try await cache.store(latest, session: session, now: time(3))
        let selected = try await cache.loadRecent(session: session, timeZoneID: "UTC", now: time(3))
        XCTAssertEqual(selected, [latest])
        trace.reset()
        do { _ = try await cache.loadRecent(session: session, timeZoneID: "UTC", now: time(.infinity)); XCTFail("Invalid clock") }
        catch { XCTAssertEqual(error as? ServerScoreSnapshotCacheError, .invalidSnapshot) }
        XCTAssertTrue(trace.statements.isEmpty)
    }
}

private final class CacheSQLTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var sql: [String] = []
    func append(_ statement: String) {
        lock.lock(); defer { lock.unlock() }
        sql.append(statement.uppercased().split(whereSeparator: \.isWhitespace).joined(separator: " "))
    }
    func reset() { lock.lock(); sql.removeAll(); lock.unlock() }
    var statements: [String] { lock.lock(); defer { lock.unlock() }; return sql }
    var writeTransactions: Int { statements.filter { $0.hasPrefix("BEGIN IMMEDIATE") }.count }
    var updates: [String] { statements.filter { $0.hasPrefix("UPDATE SERVERSCORESNAPSHOTCACHE") } }
    var payloadWrites: [String] {
        statements.filter { $0.hasPrefix("INSERT INTO SERVERSCORESNAPSHOTCACHE")
            || ($0.hasPrefix("UPDATE SERVERSCORESNAPSHOTCACHE") && $0.components(separatedBy: " WHERE ")[0].contains("PAYLOAD")) }
    }
    var evictions: [String] {
        statements.filter { $0.hasPrefix("DELETE FROM SERVERSCORESNAPSHOTCACHE")
            || $0.hasPrefix("SELECT ROWID, LENGTH(PAYLOAD)") }
    }
}

private final class CacheRejectCommit: TransactionObserver {
    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { true }
    func databaseDidChange(with event: DatabaseEvent) {}
    func databaseWillCommit() throws { throw CocoaError(.fileWriteOutOfSpace) }
    func databaseDidCommit(_ db: Database) {}
    func databaseDidRollback(_ db: Database) {}
}
