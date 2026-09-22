import XCTest
import GRDB
import NoopPush
import WhoopStore
import WhoopProtocol
@testable import Strand

final class CloudAuxiliaryIdentityTests: XCTestCase {
    private var fixtureRoots: [URL] = []
    override func tearDownWithError() throws {
        for root in fixtureRoots where FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        }
        fixtureRoots.removeAll()
        try super.tearDownWithError()
    }
    private let owner = try! AccountScope(projectURL: "https://fixture.invalid", userID: "11111111-1111-4111-8111-111111111111")
    private let sourceID = "44444444-4444-4444-8444-444444444444"
    private let device = "strap"

    private func withStore(_ body: (WhoopStore, CloudPushSnapshot) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aux-identity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fixtureRoots.append(root)
        let store = try await WhoopStore(path: root.appendingPathComponent("source.sqlite").path)
        defer {
            do { try store.registryWriter.close() }
            catch { XCTFail("Fixture cleanup failed; retained path: \(root.path)") }
        }
        try await store.bindAccountOwner(projectURL: owner.projectURL, userID: owner.userID)
        try await body(store, CloudPushSnapshot(db: store.registryWriter))
    }

    func testSnapshotPreservesAuxiliarySiblingsAndExactReceiptMembership() async throws {
        try await withStore { store, snapshot in
            _ = try await store.insert(Streams(v18Aux: [V18AuxSample(ts: 100, recordIndex: 0),
                V18AuxSample(ts: 100, recordIndex: 1), V18AuxSample(ts: 100, rrCount: 2)]), deviceId: device)
            let rows = try await snapshot.binaryRows(table: .v18AuxSample, deviceId: device, afterRowId: 0, limit: 10)
            XCTAssertEqual(rows.count, 3)
            let records = rows.compactMap { row -> PushV18AuxRecord? in if case .v18Aux(let record) = row { return record }; return nil }
            XCTAssertEqual(records.map(\.recordIndex), [0, 1, nil])
            XCTAssertEqual(records.map(\.resourceKey), ["100:0", "100:1", "100:-1"])
            let batch = try object([rows[0]])
            let receipt = try receipt(batch)
            do {
                try await snapshot.associateReceipt(batch: batch, rows: [rows[1]], receipt: receipt, scope: owner)
                XCTFail("receipt must not attest a same-second sibling")
            } catch { XCTAssertEqual(error as? CloudUploadError, .invalidReceipt) }
            try await snapshot.associateReceipt(batch: batch, rows: [rows[0]], receipt: receipt, scope: owner)
            let keys = try await store.registryWriter.read { db in
                try String.fetchAll(db, sql: "SELECT resourceKey FROM rawDurabilityReceipt ORDER BY resourceKey")
            }
            XCTAssertEqual(keys, ["100:0"])
        }
    }

    func testMigratedTimestampResourceKeyRemainsLocalAndCannotBeReassigned() async throws {
        try await withStore { store, snapshot in
            _ = try await store.insert(Streams(v18Aux: [V18AuxSample(ts: 100, recordIndex: 7)]), deviceId: device)
            // Model the preserved legacy ledger key, without replacing any original payload bytes.
            try await store.registryWriter.write { db in
                try db.execute(sql: "UPDATE v18AuxSample SET resourceKey='100' WHERE deviceId='strap'; UPDATE ingestRawResource SET resourceKey='100' WHERE lane='v18AuxSample'")
            }
            _ = try await store.insert(Streams(v18Aux: [V18AuxSample(ts: 100, recordIndex: 8)]), deviceId: device)
            let rows = try await snapshot.binaryRows(table: .v18AuxSample, deviceId: device, afterRowId: 0, limit: 10)
            guard case .v18Aux(let first) = rows[0] else { return XCTFail("auxiliary row") }
            XCTAssertEqual(first.resourceKey, "100")
            let batch = try object([rows[0]])
            try await snapshot.associateReceipt(batch: batch, rows: [rows[0]], receipt: receipt(batch), scope: owner)
            let tampered = PushBinaryRow.v18Aux(.init(rowId: first.rowId, ts: first.ts, fields: first.fields,
                recordIndex: first.recordIndex, resourceKey: "100:8"))
            do {
                try await snapshot.associateReceipt(batch: batch, rows: [tampered], receipt: receipt(batch), scope: owner)
                XCTFail("capture compatibility key is immutable")
            } catch { XCTAssertEqual(error as? CloudUploadError, .invalidReceipt) }
            let keys = try await store.registryWriter.read { db in try String.fetchAll(db, sql: "SELECT resourceKey FROM rawDurabilityReceipt") }
            XCTAssertEqual(keys, ["100"])
        }
    }

    func testStoredScalarProvenanceIsAnObjectAndLegacyNullIsNotInvented() async throws {
        try await withStore { store, snapshot in
            let provenance = try ScalarProvenance(origin: .whoopV18, recordIndex: 0, frameSHA256: String(repeating: "a", count: 64))
            _ = try await store.insert(Streams(steps: [StepSample(ts: 100, counter: 65535),
                StepSample(ts: 101, counter: 0, provenance: provenance)]), deviceId: device)
            let rows = try await snapshot.appendRows(table: .stepSample, deviceId: device, afterRowId: 0, limit: 10)
            XCTAssertEqual(rows.count, 2); XCTAssertNil(rows[0].data["provenance"])
            guard case .map(let metadata) = rows[1].data["provenance"] else { return XCTFail("provenance must be JSON object") }
            XCTAssertEqual(metadata["recordIndex"], .int(0))
            XCTAssertEqual(metadata["frameSHA256"], .string(String(repeating: "a", count: 64)))
            XCTAssertThrowsError(try PushProtocol.appendBatch(table: .stepSample, sourceId: sourceID,
                deviceId: device, startCursor: nil, records: rows, protocolVersion: "1.3"))
            let batch = try PushProtocol.appendBatch(table: .stepSample, sourceId: sourceID,
                deviceId: device, startCursor: nil, records: rows, protocolVersion: "1.4")
            XCTAssertEqual(batch.recordCount, 2)
            try await store.registryWriter.write { db in
                try db.execute(sql: "UPDATE stepSample SET provenanceJSON=? WHERE ts=101", arguments: [#"{"v":true,"origin":"whoop-v18"}"#])
            }
            do {
                _ = try await snapshot.appendRows(table: .stepSample, deviceId: device, afterRowId: 0, limit: 10)
                XCTFail("invalid stored provenance must not be stripped or converted")
            } catch { XCTAssertTrue(error is PushProtocolException) }
        }
    }

    func testAuxiliaryProgressUpgradeDoesNotRewriteOtherStreamsOrOldInFlightObject() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aux-progress-" + UUID().uuidString)
        fixtureRoots.append(root)
        let old = try CloudPushProgressStore(namespace: "same-receiver", directory: root)
        let cursor = PushCursor(rowId: 42, naturalKeyFingerprint: String(repeating: "a", count: 64))
        let object = PushInFlightObject(objectId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", objectKey: "fixture/old",
            contentSha256: String(repeating: "b", count: 64), uploaded: true)
        try await old.saveBinaryCursor(table: .v18AuxSample, deviceId: device, cursor: cursor)
        try await old.saveBinaryCursor(table: .ppgWaveformSample, deviceId: device, cursor: cursor)
        try await old.saveInFlightObject(table: .v18AuxSample, deviceId: device, object: object)
        let upgraded = try CloudPushProgressStore(namespace: "same-receiver", directory: root, auxiliaryIdentityV2: true)
        let newAux = try await upgraded.binaryCursor(table: .v18AuxSample, deviceId: device)
        let ppg = try await upgraded.binaryCursor(table: .ppgWaveformSample, deviceId: device)
        let newObject = try await upgraded.inFlightObject(table: .v18AuxSample, deviceId: device)
        XCTAssertNil(newAux); XCTAssertNil(newObject); XCTAssertEqual(ppg, cursor)
        try await upgraded.saveBinaryCursor(table: .v18AuxSample, deviceId: device, cursor: .init(rowId: 99, naturalKeyFingerprint: String(repeating: "c", count: 64)))
        let reopened = try CloudPushProgressStore(namespace: "same-receiver", directory: root)
        let oldAux = try await reopened.binaryCursor(table: .v18AuxSample, deviceId: device)
        let oldObject = try await reopened.inFlightObject(table: .v18AuxSample, deviceId: device)
        XCTAssertEqual(oldAux, cursor); XCTAssertEqual(oldObject, object)
    }

    func testSourceBlobLengthAdmissionRetainsOversizedFirstMemberAndMoreDebt() async throws {
        try await withStore { store, snapshot in
            try await store.registryWriter.write { db in
                try db.execute(sql: "INSERT INTO ppgWaveformSample(deviceId, ts, recordIndex, burstIndex, samples) VALUES ('strap', 100, -1, NULL, zeroblob(2000)), ('strap', 101, -1, NULL, zeroblob(8388608)), ('strap', 102, -1, NULL, zeroblob(20))")
            }
            let limits = PushSourceReadLimits(maximumDecodedBytes: 4096, protocolVersion: "1.4", shouldContinue: { true })
            let first = try await snapshot.binaryPage(table: .ppgWaveformSample, deviceId: device, afterRowId: 0, limit: 2001, limits: limits)
            XCTAssertEqual(first.rows.count, 1); XCTAssertTrue(first.hasMore)
            guard case .ppgWaveform(let row) = first.rows[0] else { return XCTFail("wrong source") }
            do {
                _ = try await snapshot.binaryPage(table: .ppgWaveformSample, deviceId: device, afterRowId: row.rowId, limit: 2001, limits: limits)
                XCTFail("oversized atomic row must not be skipped")
            } catch { guard case PushSourceReadError.requiresCompatibleEncoding = error else { return XCTFail("wrong failure") } }
            let retained = try await store.registryWriter.read { db in
                try Int.fetchAll(db, sql: "SELECT length(samples) FROM ppgWaveformSample ORDER BY rowid")
            }
            XCTAssertEqual(retained, [2000, 8388608, 20])
            let fingerprint = try await snapshot.binaryFingerprintAt(table: .ppgWaveformSample, deviceId: device,
                rowId: row.rowId + 1, protocolVersion: "1.4")
            XCTAssertNotNil(fingerprint)
        }
    }

    func testAppendBytePrefixKeepsDebtAndOversizedMutableWindowIsNeverTruncated() async throws {
        let db = try DatabaseQueue()
        try await db.write { db in
            try db.execute(sql: "CREATE TABLE event(deviceId TEXT, ts INTEGER, kind TEXT, payloadJSON TEXT); CREATE TABLE journal(deviceId TEXT, day TEXT, question TEXT, answeredYes INTEGER, notes TEXT, numericValue REAL)")
            try db.execute(sql: "INSERT INTO event VALUES ('strap', 100, 'fixture', ?), ('strap', 101, 'fixture', ?)",
                arguments: [String(repeating: "a", count: 1000), String(repeating: "b", count: 5000)])
            try db.execute(sql: "INSERT INTO journal VALUES ('strap', '2026-09-22', 'fixture', 1, ?, NULL)",
                arguments: [String(repeating: "x", count: 3 * 1_048_576)])
        }
        let snapshot = CloudPushSnapshot(db: db)
        let limits = PushSourceReadLimits(maximumDecodedBytes: 2000, protocolVersion: "1.0", shouldContinue: { true })
        let page = try await snapshot.appendPage(table: .event, deviceId: device, afterRowId: 0, limit: 2001, limits: limits)
        XCTAssertEqual(page.rows.count, 1); XCTAssertTrue(page.hasMore)
        do {
            _ = try await snapshot.appendPage(table: .event, deviceId: device, afterRowId: page.rows[0].rowId, limit: 2001, limits: limits)
            XCTFail("oversized source must remain visible")
        } catch { guard case PushSourceReadError.requiresCompatibleEncoding = error else { return XCTFail("wrong failure") } }
        let window = PushWindow.ending(today: ISO8601DateFormatter().date(from: "2026-09-22T12:00:00Z")!, calendar: Calendar(identifier: .gregorian))
        do {
            _ = try await snapshot.mutableRows(table: .journal, deviceId: device, window: window, limit: 1001)
            XCTFail("replacement must remain all-or-nothing")
        } catch { guard case PushSourceReadError.requiresCompatibleEncoding = error else { return XCTFail("wrong failure") } }
        let count = try await db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM journal") }
        XCTAssertEqual(count, 1)
    }

    private func object(_ rows: [PushBinaryRow]) throws -> PushBinaryBatch {
        try PushProtocol.binaryObjectBatch(table: .v18AuxSample, sourceId: sourceID,
            deviceId: device, startCursor: nil, rows: rows, protocolVersion: "1.4")
    }
    private func receipt(_ batch: PushBinaryBatch) throws -> PushDurabilityReceipt {
        let fields = W5ReceiptFixture.receipt(owner: owner.userID, device: device, object: batch.objectId,
            batch: batch.batchId, source: sourceID, stream: batch.wireName, decoded: batch.contentSha256,
            wire: PushDurabilityReceipt.sha256(batch.payload), decodedBytes: batch.uncompressedBytes,
            wireBytes: batch.payload.count, schema: 2)
        return try JSONDecoder().decode(PushDurabilityReceipt.self, from: W5ReceiptFixture.bytes(fields))
    }
}
