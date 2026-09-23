import XCTest
import GRDB
import NoopPush
import WhoopStore
#if canImport(CloudUploadHarness)
@testable import CloudUploadHarness
#else
@testable import Strand
#endif

final class CloudPushSnapshotTests: XCTestCase {
    private let window = PushWindow(fromDay: "2026-09-18", toDay: "2026-09-18",
                                   startTsInclusive: 1_000, endTsExclusive: 2_000)

    func testPartialBootstrapExposesRegisteredDeviceAndFreshTimestampPageBeforeHistoryCompletes() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "fresh-device", mac: nil, name: nil)
        try await store.registryWriter.write { db in
            for row in 1...10_000 {
                try db.execute(sql: "INSERT INTO hrSample(deviceId,ts,bpm) VALUES('history-device',?,60)", arguments: [row])
            }
            try db.execute(sql: "INSERT INTO hrSample(deviceId,ts,bpm) VALUES('fresh-device',19999,61)")
            try db.execute(sql: "UPDATE cloudSourceBootstrap SET complete=0,lastRowId=NULL WHERE tableName='hrSample'")
            try db.execute(sql: "DELETE FROM cloudSourceMembership WHERE tableName='hrSample'")
        }
        let snapshot = CloudPushSnapshot(db: store.registryWriter)
        let discovery = try await snapshot.discoverDevices(capabilities: .init(appendTables: [.hrSample], mutableTables: []))
        XCTAssertFalse(discovery.isComplete)
        XCTAssertTrue(discovery.deviceIDs.contains("fresh-device"))
        let page = try await snapshot.freshAppendPage(table: .hrSample, deviceId: "fresh-device", afterRowId: 0,
            sinceTs: 19700, throughTs: 20000, limit: 129,
            limits: .init(maximumDecodedBytes: 65536, protocolVersion: "1.4", shouldContinue: { true }))
        XCTAssertEqual(page.rows.map { $0.key["ts"] }, [.int(19999)])
        let cursor = try await store.registryWriter.read { db in
            try Int64.fetchOne(db, sql: "SELECT lastRowId FROM cloudSourceBootstrap WHERE tableName='hrSample'")
        }
        XCTAssertEqual(cursor, 2000, "one discovery call commits only its bounded legacy page")
    }

    func testFreshTimestampFilterUsesIndexAndRetainsOutOfOrderOriginalTimesAndGaps() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.registryWriter.write { db in
            for row in 1...10_000 {
                try db.execute(sql: "INSERT INTO hrSample(deviceId,ts,bpm) VALUES('d',?,60)", arguments: [row])
            }
            for ts in [19999, 19800, 20001, 19699] {
                try db.execute(sql: "INSERT INTO hrSample(deviceId,ts,bpm) VALUES('d',?,61)", arguments: [ts])
            }
        }
        let snapshot = CloudPushSnapshot(db: store.registryWriter)
        let limits = PushSourceReadLimits(maximumDecodedBytes: 65536, protocolVersion: "1.4", shouldContinue: { true })
        let page = try await snapshot.freshAppendPage(table: .hrSample, deviceId: "d", afterRowId: 0,
            sinceTs: 19700, throughTs: 20000, limit: 129, limits: limits)
        XCTAssertEqual(page.rows.map(\.rowId), [10001,10002])
        XCTAssertEqual(page.rows.map { $0.key["ts"] }, [.int(19999), .int(19800)])
        let plan = try await store.registryWriter.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN SELECT rowid FROM hrSample WHERE deviceId=? AND rowid>? AND ts>=? AND ts<=? ORDER BY +rowid LIMIT ?",
                arguments: ["d",0,19700,20000,129]).map { $0["detail"] as String }.joined(separator: " ")
        }
        XCTAssertTrue(plan.contains("ts>? AND ts<?"), plan)
        let history = try await snapshot.appendPage(table: .hrSample, deviceId: "d", afterRowId: 0, limit: 2, limits: limits)
        XCTAssertEqual(history.rows.map(\.rowId), [1,2])
        let after = try await snapshot.freshAppendPage(table: .hrSample, deviceId: "d", afterRowId: 10001,
            sinceTs: 19700, throughTs: 20000, limit: 129, limits: limits)
        XCTAssertEqual(after.rows.map(\.rowId), [10002])
    }

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
        // IMU is file-backed and requires its owner-bound membership source;
        // missing source admission must not be confused with an empty lane.
        let imu = try W5ImuFixture()
        defer { imu.close() }
        let snapshot = CloudPushSnapshot(db: store.registryWriter, imuPushSource: imu.source)
        _ = try await snapshot.knownDeviceIds(capabilities: .all)
        for table in PushAppendTable.allCases {
            _ = try await snapshot.appendRows(table: table, deviceId: "d", afterRowId: 0, limit: 10)
            _ = try await snapshot.appendRecordAt(table: table, deviceId: "d", rowId: 1)
            _ = try await snapshot.freshAppendPage(table: table, deviceId: "d", afterRowId: 0,
                sinceTs: 1000, throughTs: 1300, limit: 129,
                limits: .init(maximumDecodedBytes: 65536, protocolVersion: "1.4", shouldContinue: { true }))
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
        let receipt = try await CloudPushSnapshot(db: store.registryWriter).appendRecordAt(
            table: .standardHRReceipt, deviceId: "d", rowId: XCTUnwrap(rows.first?.rowId))
        XCTAssertEqual(receipt?.data["receivedMonotonicNs"], .string("9007199254740993"))
    }

    func testSmallMonotonicClockUsesTheSameLosslessWireType() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.registryWriter.write { db in
            try db.execute(sql: """
                INSERT INTO standardHRReceipt(deviceId,receiptId,ts,sessionId,notificationOrdinal,
                  receivedUnixMs,receivedMonotonicNs,rawHex,schemaVersion,clockVersion)
                VALUES('d','00000000-0000-4000-8000-000000000001:0',1700000000,
                  '00000000-0000-4000-8000-000000000001',0,1700000000123,123,'103c0004',1,'host-arrival-unmapped')
                """)
        }
        let rows = try await CloudPushSnapshot(db: store.registryWriter).appendRows(
            table: .standardHRReceipt, deviceId: "d", afterRowId: 0, limit: 10)
        XCTAssertEqual(rows.first?.data["receivedMonotonicNs"], .string("123"))
        XCTAssertEqual(rows.first?.data["receivedUnixMs"], .int(1_700_000_000_123))
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
