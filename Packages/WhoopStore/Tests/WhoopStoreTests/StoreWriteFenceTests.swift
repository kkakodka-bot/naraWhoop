import Foundation
import GRDB
import XCTest
@testable import WhoopStore

final class StoreWriteFenceTests: XCTestCase {
    func testRevokedConnectionCannotOverwriteNewRuntimeOnSameDatabase() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("scoped.sqlite").path
        let old = try await WhoopStore(path: path)
        try await assertDurableWriter(old)
        let fence = StoreWriteFence()
        try await old.fenceWrites(untilRevoked: fence)
        try await old.upsertDevice(id: "source", mac: nil, name: "old")
        try await assertDurableWriter(old)
        fence.invalidate()
        let next = try await WhoopStore(path: path)
        try await assertDurableWriter(next)
        try await next.fenceWrites(untilRevoked: StoreWriteFence())
        try await next.upsertDevice(id: "source", mac: nil, name: "new-result")
        do {
            try await old.upsertDevice(id: "source", mac: nil, name: "retired-result")
            XCTFail("retired publication committed")
        } catch {}
        let name = try await next.registryWriter.read { db in
            try String.fetchOne(db, sql: "SELECT name FROM device WHERE id='source'")
        }
        XCTAssertEqual(name, "new-result")
    }

    private func assertDurableWriter(_ store: WhoopStore) async throws {
        let modes = try await store.registryWriter.writeWithoutTransaction { db in
            (try Int.fetchOne(db, sql: "PRAGMA synchronous"),
             try String.fetchOne(db, sql: "PRAGMA journal_mode"))
        }
        XCTAssertEqual(modes.0, 2, "strap ACK requires synchronization on the actual commit connection")
        XCTAssertEqual(modes.1, "wal")
    }

    func testRevocationDuringTransactionRollsBackAllRows() async throws {
        let store = try await WhoopStore.inMemory()
        let fence = StoreWriteFence()
        try await store.fenceWrites(untilRevoked: fence)
        // Actual SQLite commit hook, not an admission-only fake. Revocation happens after SQL writes.
        do {
            try await store.registryWriter.write { db in
                try db.execute(sql: "INSERT INTO device(id,name) VALUES('source','must-rollback')")
                fence.invalidate()
            }
            XCTFail("transaction committed after revocation")
        } catch {}
        let count = try await store.registryWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM device WHERE id='source'")
        }
        XCTAssertEqual(count, 0)
        do { try await store.fenceWrites(untilRevoked: fence); XCTFail("revoked fence reattached") } catch {}
    }
}
