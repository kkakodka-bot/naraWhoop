import Foundation
import GRDB
import XCTest
@testable import WhoopStore

final class UnrecognizedStoreTests: XCTestCase {
    func testUnknownDatabaseAndUncheckpointedWalRemainIntact() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("unassigned.sqlite")
        let original = try DatabasePool(path: file.path)
        try await original.write { db in
            try db.execute(sql: "CREATE TABLE private_samples(id INTEGER PRIMARY KEY, value TEXT)")
            try db.execute(sql: "INSERT INTO private_samples(value) VALUES ('unassigned-data')")
        }
        let beforeDatabase = try Data(contentsOf: file)
        let wal = URL(fileURLWithPath: file.path + "-wal")
        let beforeWal = try Data(contentsOf: wal)
        XCTAssertFalse(beforeWal.isEmpty)
        for _ in 0..<2 {
            do {
                _ = try await WhoopStore(path: file.path)
                XCTFail("an unrecognized store was silently replaced")
            } catch let error as WhoopStore.OpenError {
                XCTAssertEqual(error, .unrecognizedDatabase)
            }
        }
        XCTAssertEqual(try Data(contentsOf: file), beforeDatabase)
        XCTAssertEqual(try Data(contentsOf: wal), beforeWal)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path + "-shm"))
        let value = try await original.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM private_samples WHERE id=1")
        }
        XCTAssertEqual(value, "unassigned-data")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .contains { $0.contains("incompatible") })
    }
}
