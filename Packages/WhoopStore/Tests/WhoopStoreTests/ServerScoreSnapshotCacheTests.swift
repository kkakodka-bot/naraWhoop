import Foundation
import GRDB
import XCTest
@testable import WhoopStore

final class ServerScoreSnapshotCacheTests: XCTestCase {
    private let owner = ServerScoreCacheOwner(projectURL: "https://a.example", userID: "account-a")

    private func database(path: String? = nil) throws -> DatabaseQueue {
        let db = try path.map { try DatabaseQueue(path: $0) } ?? DatabaseQueue()
        var migrator = DatabaseMigrator()
        ServerScoreCacheMigration.register(in: &migrator)
        try migrator.migrate(db)
        return db
    }

    private func key(owner: ServerScoreCacheOwner? = nil, device: String = "device-a", day: String = "2026-09-18",
                     zone: String = "America/Los_Angeles", schema: Int = 2, algorithm: String = "test-1") -> ServerScoreCacheKey {
        ServerScoreCacheKey(owner: owner ?? self.owner, sourceDeviceID: device, day: day,
                            timeZoneID: zone, schemaVersion: schema, algorithmVersion: algorithm)
    }

    private func snapshot(_ key: ServerScoreCacheKey, input: Int64 = 1, result: Int64 = 1,
                          state: ServerScoreCachedSnapshot.State = .available, payload: String = "{\"daily\":{},\"sleep\":[]}") -> ServerScoreCachedSnapshot {
        ServerScoreCachedSnapshot(key: key, inputRevision: input, resultRevision: result, state: state,
                                  payload: Data(payload.utf8), fetchedAt: Date(timeIntervalSince1970: 1_790_000_000))
    }

    func testEveryKeyDimensionIsIsolated() async throws {
        let db = try database()
        let cache = ServerScoreSnapshotCache(db: db)
        let session = ServerScoreCacheSession(owner: owner, generation: UUID())
        await cache.activate(session)
        let original = snapshot(key())
        try await cache.store(original, session: session)
        let matching = try await cache.load(key(), session: session)
        XCTAssertEqual(matching, original)
        let misses = [key(device: "device-b"), key(day: "2026-09-19"), key(zone: "UTC"),
                      key(schema: 3), key(algorithm: "test-2")]
        for query in misses {
            let value = try await cache.load(query, session: session)
            XCTAssertNil(value)
        }
        for other in [ServerScoreCacheOwner(projectURL: owner.projectURL, userID: "account-b"),
                      ServerScoreCacheOwner(projectURL: "https://b.example", userID: owner.userID)] {
            let changed = ServerScoreCacheSession(owner: other, generation: UUID())
            await cache.activate(changed)
            let value = try await cache.load(key(owner: other), session: changed)
            XCTAssertNil(value)
        }
    }

    func testLogoutAndSameAccountReloginRejectOldReadsAndWrites() async throws {
        let cache = ServerScoreSnapshotCache(db: try database())
        let first = ServerScoreCacheSession(owner: owner, generation: UUID())
        await cache.activate(first)
        try await cache.store(snapshot(key()), session: first)
        await cache.activate(nil)
        do { _ = try await cache.load(key(), session: first); XCTFail("Logout must hide retained cache") }
        catch { XCTAssertEqual(error as? ServerScoreSnapshotCacheError, .staleSession) }
        let second = ServerScoreCacheSession(owner: owner, generation: UUID())
        await cache.activate(second)
        do { try await cache.store(snapshot(key(), result: 2), session: first); XCTFail("Old response must not commit") }
        catch { XCTAssertEqual(error as? ServerScoreSnapshotCacheError, .staleSession) }
        let retained = try await cache.load(key(), session: second)
        XCTAssertEqual(retained?.resultRevision, 1)
    }

    func testRecentLoadsLastObservedSourceAndVersionWithoutCrossingOwnerOrTimezone() async throws {
        let cache = ServerScoreSnapshotCache(db: try database())
        let session = ServerScoreCacheSession(owner: owner, generation: UUID())
        await cache.activate(session)
        let first = snapshot(key(), result: 99)
        try await cache.store(first, session: session)
        let selected = ServerScoreCachedSnapshot(key: key(device: "selected-device", algorithm: "next-version"),
            inputRevision: 1, resultRevision: 1, state: .partial, payload: first.payload,
            fetchedAt: first.fetchedAt.addingTimeInterval(1))
        try await cache.store(selected, session: session)
        try await cache.store(snapshot(key(zone: "UTC"), result: 999), session: session)
        let rows = try await cache.loadRecent(session: session, timeZoneID: "America/Los_Angeles")
        XCTAssertEqual(rows, [selected])
        let other = ServerScoreCacheSession(owner: .init(projectURL: owner.projectURL, userID: "different"), generation: UUID())
        await cache.activate(other)
        let isolated = try await cache.loadRecent(session: other, timeZoneID: "America/Los_Angeles")
        XCTAssertTrue(isolated.isEmpty)
        do { _ = try await cache.loadRecent(session: session, timeZoneID: "America/Los_Angeles"); XCTFail("Old owner") }
        catch { XCTAssertEqual(error as? ServerScoreSnapshotCacheError, .staleSession) }
    }

    func testTombstoneReplacesCompletePayloadAndRejectsOlderResponses() async throws {
        let cache = ServerScoreSnapshotCache(db: try database())
        let session = ServerScoreCacheSession(owner: owner, generation: UUID())
        await cache.activate(session)
        try await cache.store(snapshot(key(), payload: "{\"daily\":{\"hrv\":42},\"sleep\":[{\"id\":\"old\"}]}"), session: session)
        let tombstone = snapshot(key(), input: 2, result: 3, state: .noData, payload: "{\"daily\":null,\"sleep\":[]}")
        try await cache.store(tombstone, session: session)
        let staleResult = try await cache.store(snapshot(key(), input: 2, result: 2), session: session)
        let staleInput = try await cache.store(snapshot(key(), input: 1, result: 4), session: session)
        XCTAssertEqual(staleResult, .ignoredOlderRevision)
        XCTAssertEqual(staleInput, .ignoredOlderRevision)
        let latest = try await cache.load(key(), session: session)
        XCTAssertEqual(latest, tombstone)
        let repeated = try await cache.store(tombstone, session: session)
        XCTAssertEqual(repeated, .refreshed)
        do { try await cache.store(snapshot(key(), input: 2, result: 3), session: session); XCTFail("Revision must be immutable") }
        catch { XCTAssertEqual(error as? ServerScoreSnapshotCacheError, .revisionConflict) }
    }

    func testRowsAndBytesAreBoundedAndReadsTouchLRU() async throws {
        let db = try database()
        let cache = ServerScoreSnapshotCache(db: db, limits: .init(daysPerNamespace: 2, totalRows: 3, payloadBytes: 32, totalBytes: 64))
        let session = ServerScoreCacheSession(owner: owner, generation: UUID())
        await cache.activate(session)
        for day in 1...3 {
            try await cache.store(snapshot(key(day: String(format: "2026-09-%02d", day))), session: session, now: Date(timeIntervalSince1970: Double(day)))
        }
        let oldest = try await cache.load(key(day: "2026-09-01"), session: session)
        XCTAssertNil(oldest)
        _ = try await cache.load(key(day: "2026-09-02"), session: session, now: Date(timeIntervalSince1970: 4))
        try await cache.store(snapshot(key(device: "device-b")), session: session, now: Date(timeIntervalSince1970: 5))
        let evictedForBytes = try await cache.load(key(day: "2026-09-03"), session: session)
        XCTAssertNil(evictedForBytes)
        let touched = try await cache.load(key(day: "2026-09-02"), session: session)
        XCTAssertNotNil(touched)
        try await db.read { db in
            XCTAssertLessThanOrEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM serverScoreSnapshotCache")!, 3)
            XCTAssertLessThanOrEqual(try Int.fetchOne(db, sql: "SELECT sum(length(payload)) FROM serverScoreSnapshotCache")!, 64)
        }
    }

    func testOversizedAndCorruptPayloadsAreNotAdmitted() async throws {
        let db = try database()
        let cache = ServerScoreSnapshotCache(db: db, limits: .init(payloadBytes: 32, totalBytes: 64))
        let session = ServerScoreCacheSession(owner: owner, generation: UUID())
        await cache.activate(session)
        do { try await cache.store(snapshot(key(), payload: String(repeating: "x", count: 33)), session: session); XCTFail("Unbounded payload") }
        catch { XCTAssertEqual(error as? ServerScoreSnapshotCacheError, .payloadTooLarge) }
        try await cache.store(snapshot(key()), session: session)
        try await db.write { db in try db.execute(sql: "UPDATE serverScoreSnapshotCache SET payload=zeroblob(33)") }
        do { _ = try await cache.load(key(), session: session); XCTFail("Oversized disk row") }
        catch { XCTAssertEqual(error as? ServerScoreSnapshotCacheError, .corruptRow) }
    }

    func testInvalidDayAndTimezoneAreRejected() async throws {
        let cache = ServerScoreSnapshotCache(db: try database())
        let session = ServerScoreCacheSession(owner: owner, generation: UUID())
        await cache.activate(session)
        for invalid in [key(day: "2026-02-30"), key(day: "2026-9-18"), key(zone: "Not/AZone")] {
            do { try await cache.store(snapshot(invalid), session: session); XCTFail("Invalid date contract") }
            catch { XCTAssertEqual(error as? ServerScoreSnapshotCacheError, .invalidKey) }
        }
    }

    func testGlobalRowLimitAppliesAcrossAccountNamespaces() async throws {
        let db = try database()
        let cache = ServerScoreSnapshotCache(db: db, limits: .init(daysPerNamespace: 14, totalRows: 3,
                                                                  payloadBytes: 32, totalBytes: 128))
        var sessions: [ServerScoreCacheSession] = []
        for index in 0..<4 {
            let account = ServerScoreCacheOwner(projectURL: owner.projectURL, userID: "account-\(index)")
            let session = ServerScoreCacheSession(owner: account, generation: UUID())
            sessions.append(session)
            await cache.activate(session)
            try await cache.store(snapshot(key(owner: account)), session: session,
                                  now: Date(timeIntervalSince1970: Double(index)))
        }
        let first = sessions[0]
        await cache.activate(first)
        let oldest = try await cache.load(key(owner: first.owner), session: first)
        XCTAssertNil(oldest)
        let count = try await db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM serverScoreSnapshotCache") }
        XCTAssertEqual(count, 3)
        let last = sessions[3]
        await cache.activate(last)
        let newest = try await cache.load(key(owner: last.owner), session: last)
        XCTAssertNotNil(newest)
        do { _ = try await cache.load(key(owner: first.owner), session: last); XCTFail("Cannot read another owner's row") }
        catch { XCTAssertEqual(error as? ServerScoreSnapshotCacheError, .staleSession) }
    }

    func testDelayedResponsesFrom128SessionGenerationsCannotReplaceLatest() async throws {
        let cache = ServerScoreSnapshotCache(db: try database())
        var sessions: [ServerScoreCacheSession] = []
        for _ in 0..<128 {
            let session = ServerScoreCacheSession(owner: owner, generation: UUID())
            sessions.append(session)
            await cache.activate(session)
        }
        let latest = sessions[127]
        let tombstone = snapshot(key(), input: 128, result: 128, state: .noData,
                                 payload: "{\"daily\":null,\"sleep\":[]}")
        try await cache.store(tombstone, session: latest)
        let lateValue = snapshot(key(), input: 129, result: 129)
        let rejected = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for session in sessions.dropLast() {
                group.addTask {
                    do { try await cache.store(lateValue, session: session); return false }
                    catch { return error as? ServerScoreSnapshotCacheError == .staleSession }
                }
            }
            var count = 0
            for await wasRejected in group where wasRejected { count += 1 }
            return count
        }
        XCTAssertEqual(rejected, 127)
        let retained = try await cache.load(key(), session: latest)
        XCTAssertEqual(retained, tombstone)
    }

    func testFileReopenPreservesScopedSnapshotWithoutAdoptingLegacyRows() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("server-score-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("cache.sqlite").path
        let session = ServerScoreCacheSession(owner: owner, generation: UUID())
        let original = snapshot(key())
        do {
            let db = try DatabaseQueue(path: path)
            try await db.write { db in
                try db.execute(sql: "CREATE TABLE serverScoreCache(day TEXT PRIMARY KEY, dailyJson TEXT)")
                try db.execute(sql: "INSERT INTO serverScoreCache VALUES ('2026-09-18', 'legacy-owner-unknown')")
                try db.execute(sql: "CREATE TABLE rawSentinel(bytes BLOB)")
                try db.execute(sql: "INSERT INTO rawSentinel VALUES (X'0001FF')")
                try ServerScoreCacheMigration.migrate(db)
            }
            let cache = ServerScoreSnapshotCache(db: db)
            await cache.activate(session)
            let legacy = try await cache.load(key(), session: session)
            XCTAssertNil(legacy)
            try await cache.store(original, session: session)
            try db.close()
        }
        let reopened = try DatabaseQueue(path: path)
        let cache = ServerScoreSnapshotCache(db: reopened)
        await cache.activate(session)
        let loaded = try await cache.load(key(), session: session)
        XCTAssertEqual(loaded, original)
        try await reopened.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT dailyJson FROM serverScoreCache"), "legacy-owner-unknown")
            XCTAssertEqual(try Data.fetchOne(db, sql: "SELECT bytes FROM rawSentinel"), Data([0, 1, 255]))
        }
    }
}
