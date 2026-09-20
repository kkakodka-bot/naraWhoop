import XCTest
import GRDB
import NoopPush
import WhoopStore
@testable import Strand

final class CloudPushSnapshotTests: XCTestCase {
    private let window = PushWindow(fromDay: "2026-09-18", toDay: "2026-09-18",
                                   startTsInclusive: 1_000, endTsExclusive: 2_000)

    func testAppleWorkoutExportsNullRouteWithoutFailingTheUploadCycle() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.registryWriter.write { db in
            XCTAssertFalse(try db.columns(in: "workout").contains { $0.name == "routePolyline" })
            try db.execute(sql: "INSERT INTO workout(deviceId,startTs,endTs,sport,source) VALUES('d',1100,1200,'walk','manual')")
        }
        let rows = try await CloudPushSnapshot(db: store.registryWriter).mutableRows(
            table: .workout, deviceId: "d", window: window, limit: 10)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].data["routePolyline"], .null)
        XCTAssertEqual(rows[0].data["endTs"], .int(1_200))
    }

    func testEmptyWorkoutTableStillExportsSuccessfully() async throws {
        let store = try await WhoopStore.inMemory()
        let rows = try await CloudPushSnapshot(db: store.registryWriter).mutableRows(
            table: .workout, deviceId: "d", window: window, limit: 10)
        XCTAssertTrue(rows.isEmpty)
    }

    func testExistingRouteColumnIsPreservedIfSchemaSupportsIt() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.registryWriter.write { db in
            try db.execute(sql: "ALTER TABLE workout ADD COLUMN routePolyline TEXT")
            try db.execute(sql: "INSERT INTO workout(deviceId,startTs,endTs,sport,source,routePolyline) VALUES('d',1100,1200,'walk','manual','fixture-route')")
        }
        let rows = try await CloudPushSnapshot(db: store.registryWriter).mutableRows(
            table: .workout, deviceId: "d", window: window, limit: 10)
        XCTAssertEqual(rows.first?.data["routePolyline"], .string("fixture-route"))
    }

    func testEveryExportQueryIsCompatibleWithTheMigratedAppleSchema() async throws {
        let store = try await WhoopStore.inMemory()
        let snapshot = CloudPushSnapshot(db: store.registryWriter)
        _ = try await snapshot.knownDeviceIds(capabilities: .all)
        for table in PushAppendTable.allCases {
            _ = try await snapshot.appendRows(table: table, deviceId: "d", afterRowId: 0, limit: 10)
            _ = try await snapshot.appendRecordAt(table: table, deviceId: "d", rowId: 1)
        }
        for table in PushMutableTable.allCases {
            _ = try await snapshot.mutableRows(table: table, deviceId: "d", window: window, limit: 10)
        }
        for table in PushBinaryTable.allCases {
            _ = try await snapshot.binaryRows(table: table, deviceId: "d", afterRowId: 0, limit: 10)
            _ = try await snapshot.binaryRecordAt(table: table, deviceId: "d", rowId: 1)
        }
    }

    func testReceiptSnapshotPreservesMonotonicClockBeyondJsonPrecision() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.registryWriter.write { db in
            try db.execute(sql: """
                INSERT INTO standardHRReceipt(deviceId,receiptId,ts,sessionId,notificationOrdinal,
                  receivedUnixMs,receivedMonotonicNs,rawHex,schemaVersion,clockVersion)
                VALUES('d','00000000-0000-4000-8000-000000000001:0',1700000000,
                  '00000000-0000-4000-8000-000000000001',0,1700000000123,9007199254740993,'103c0004',1,'host-arrival-unmapped')
                """)
        }
        let rows = try await CloudPushSnapshot(db: store.registryWriter).appendRows(
            table: .standardHRReceipt, deviceId: "d", afterRowId: 0, limit: 10)
        XCTAssertEqual(rows.first?.data["receivedMonotonicNs"], .string("9007199254740993"))
    }

    func testCopiedPhoneWorkoutExportReadOnlyWhenFixtureIsProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["NOOP_PUSH_READONLY_DB_FIXTURE"] else {
            throw XCTSkip("Optional private copied phone database was not supplied")
        }
        var config = Configuration()
        config.readonly = true
        let db = try DatabaseQueue(path: path, configuration: config)
        let snapshot = CloudPushSnapshot(db: db)
        let devices = try await db.read { try String.fetchAll($0, sql: "SELECT id FROM device") }
        XCTAssertFalse(devices.isEmpty, "The supplied regression fixture must exercise a device export")
        for device in devices {
            _ = try await snapshot.mutableRows(table: .workout, deviceId: device, window: window, limit: 10)
        }
    }
}
