import XCTest
@testable import NoopPush

private let sourceA = "3a3486dd-5030-4e17-a00d-a781399890f9"
private let sourceB = "4b4597ee-6141-4f28-b11e-b8924a9a9010"

final class PushProtocolTests: XCTestCase {
    func testAppendWireShapeIsDeterministic() throws {
        let rows = [hrRecord(rowId: 41, ts: 200, bpm: 61), hrRecord(rowId: 42, ts: 201, bpm: 62)]
        let first = try PushProtocol.appendBatch(
            table: .hrSample, sourceId: sourceA, deviceId: "strap-a", startCursor: nil, records: rows
        )
        let retry = try PushProtocol.appendBatch(
            table: .hrSample, sourceId: sourceA, deviceId: "strap-a", startCursor: nil, records: rows
        )
        XCTAssertEqual(first.body, retry.body)
        XCTAssertEqual(first.batchId, retry.batchId)
        XCTAssertEqual(42, first.endCursor?.rowId)
        let lines = String(data: first.body, encoding: .utf8)!.trimmingCharacters(in: .newlines).split(separator: "\n")
        let header = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [String: Any]
        XCTAssertEqual("batch", header["type"] as? String)
        XCTAssertEqual("1.0", header["protocolVersion"] as? String)
        XCTAssertEqual(sourceA, header["sourceId"] as? String)
        XCTAssertEqual("strap-a", header["deviceId"] as? String)
        XCTAssertEqual("hrSample", header["stream"] as? String)
        XCTAssertEqual("append", header["delivery"] as? String)
        XCTAssertTrue(header["startCursor"] is NSNull || header["startCursor"] == nil)
        let endCursor = header["endCursor"] as! [String: Any]
        XCTAssertNotNil((endCursor["keySha256"] as? String)?.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression))
        XCTAssertFalse(String(data: first.body, encoding: .utf8)!.contains("synced"))
    }

    func testSourceIdScopesStableBatchIdentity() throws {
        let rows = [hrRecord(rowId: 1, ts: 100, bpm: 60)]
        let a = try PushProtocol.appendBatch(table: .hrSample, sourceId: sourceA, deviceId: "same-device", startCursor: nil, records: rows)
        let b = try PushProtocol.appendBatch(table: .hrSample, sourceId: sourceB, deviceId: "same-device", startCursor: nil, records: rows)
        XCTAssertNotEqual(a.batchId, b.batchId)
        XCTAssertNotEqual(a.body, b.body)
    }

    func testAcknowledgementIgnoresUnknownOptionalMembers() throws {
        let batch = try PushProtocol.appendBatch(
            table: .hrSample, sourceId: sourceA, deviceId: "strap", startCursor: nil,
            records: [hrRecord(rowId: 1, ts: 10, bpm: 60)]
        )
        let encoded = try JSONSerialization.data(withJSONObject: [
            "acceptedRows": batch.recordCount,
            "batchId": batch.batchId,
            "deviceId": batch.deviceId,
            "endCursor": ["keySha256": batch.endCursor!.naturalKeyFingerprint, "rowId": batch.endCursor!.rowId],
            "protocolVersion": batch.protocolVersion,
            "status": "accepted",
            "stream": batch.table.wireName,
            "futureOptional": true,
        ])
        XCTAssertTrue(try PushAck.parse(encoded).exactlyMatches(batch))
    }

    func testAppendBatchCapsRowsAtFiveThousand() throws {
        let rows = (1...5_001).map { hrRecord(rowId: Int64($0), ts: Int64($0), bpm: 60) }
        let batch = try PushProtocol.appendBatch(table: .hrSample, sourceId: sourceA, deviceId: "strap-a", startCursor: nil, records: rows)
        XCTAssertEqual(PushProtocolLimits.maxRecords, batch.recordCount)
        XCTAssertEqual(5_000, batch.endCursor?.rowId)
        XCTAssertLessThanOrEqual(batch.body.count, PushProtocolLimits.maxBodyBytes)
    }

    func testMutableEmptySnapshotIsAuthoritative() throws {
        let window = testWindow()
        let batch = try PushProtocol.mutableBatch(table: .journal, sourceId: sourceA, deviceId: "device-a", window: window, records: [])
        XCTAssertEqual(0, batch.recordCount)
        XCTAssertNil(batch.endCursor)
        XCTAssertEqual("replace_window", batch.mode)
        XCTAssertEqual("1969b8fa-7930-5907-9d0c-2c14ef2d8608", batch.batchId)
        XCTAssertEqual("6ae704e9-2595-5a03-85d5-36189a11b05c", batch.replacementId)
        let lines = String(data: batch.body, encoding: .utf8)!.trimmingCharacters(in: .newlines).split(separator: "\n")
        let header = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [String: Any]
        let wireWindow = header["window"] as! [String: Any]
        XCTAssertEqual("day", wireWindow["selector"] as? String)
        XCTAssertEqual("2026-08-05", wireWindow["startInclusive"] as? String)
        XCTAssertEqual("2026-08-19", wireWindow["endExclusive"] as? String)
        XCTAssertEqual(1, wireWindow["part"] as? Int)
        XCTAssertEqual(1, wireWindow["parts"] as? Int)
    }

    func testMutableSnapshotSplitsIntoBoundedParts() throws {
        let records = (1...5_001).map { index in
            PushMutableRecord(
                key: [
                    "day": .string("2026-08-\(String(format: "%02d", index % 14 + 5))"),
                    "question": .string("q\(index)"),
                ],
                data: ["answeredYes": .bool(true), "notes": .null, "numericValue": .null]
            )
        }.sorted { left, right in
            func str(_ record: PushMutableRecord, _ key: String) -> String {
                guard case .string(let value) = record.key[key] else { return "" }
                return value
            }
            let dayCmp = str(left, "day").compare(str(right, "day"))
            if dayCmp != .orderedSame { return dayCmp == .orderedAscending }
            return str(left, "question") < str(right, "question")
        }
        let first = try PushProtocol.mutableBatches(table: .journal, sourceId: sourceA, deviceId: "device-a", window: testWindow(), records: records)
        let retry = try PushProtocol.mutableBatches(table: .journal, sourceId: sourceA, deviceId: "device-a", window: testWindow(), records: records)
        XCTAssertEqual(2, first.count)
        XCTAssertEqual(first.map(\.batchId), retry.map(\.batchId))
        XCTAssertEqual("0d46c335-1ebf-5493-ad11-fcfb7a0626ef", first[0].batchId)
        XCTAssertEqual("b2fe2f88-1f60-567e-ae6b-efcb2ae00d7d", first[1].batchId)
        XCTAssertEqual(first[0].replacementId, first[1].replacementId)
        XCTAssertTrue(first.allSatisfy { $0.recordCount <= PushProtocolLimits.maxRecords && $0.body.count <= PushProtocolLimits.maxBodyBytes })
    }

    func testMutableDayHashMatchesOracle() throws {
        let first = journalRecord(day: "2026-08-18", question: "coffee", notes: "one")
        let same = journalRecord(day: "2026-08-18", question: "coffee", notes: "one")
        let changed = journalRecord(day: "2026-08-18", question: "coffee", notes: "two")
        XCTAssertEqual(
            try PushProtocol.mutableSnapshotHash(table: .journal, records: [first]),
            try PushProtocol.mutableSnapshotHash(table: .journal, records: [same])
        )
        XCTAssertEqual("d8a4115d9d70cab7ec42a8bc2f2c31b8b853757d307f21de375300f38cc476f4", try PushProtocol.mutableSnapshotHash(table: .journal, records: [first]))
        XCTAssertEqual("a50091d7479831ee0d9d2cdc4cea5c16ace7dd68c1650c7d0320e3c5232101c2", try PushProtocol.mutableSnapshotHash(table: .journal, records: [changed]))
        XCTAssertEqual("a9d1c1709030d897ef1e0344fe5c23c4ced6bde18d7f4dd6d012e5de0d0baeec", try PushProtocol.mutableSnapshotHash(table: .journal, records: []))
        XCTAssertNotEqual(
            try PushProtocol.mutableSnapshotHash(table: .journal, records: [first]),
            try PushProtocol.mutableSnapshotHash(table: .journal, records: [])
        )
    }

    func testEventLabelSnapshotUsesStableIdentityAndStartWindow() throws {
        let window = testWindow()
        let event = PushMutableRecord(
            key: [
                "id": .string("8e13e903-3ba2-4bbc-8b77-e3f61a68bf8e"),
                "startTs": .int(1_789_763_348),
            ],
            data: [
                "label": .string("Outdoor walk"),
                "endTs": .int(1_789_763_438),
                "notes": .string("sunny"),
                "timeZoneIdentifier": .string("America/Los_Angeles"),
                "source": .string("manual_experiment"),
            ]
        )

        let first = try PushProtocol.mutableBatch(
            table: .eventLabel, sourceId: sourceA, deviceId: "strap-a", window: window, records: [event]
        )
        let retry = try PushProtocol.mutableBatch(
            table: .eventLabel, sourceId: sourceA, deviceId: "strap-a", window: window, records: [event]
        )

        XCTAssertEqual(first.batchId, retry.batchId)
        XCTAssertEqual("eventLabel", first.table.wireName)
        let headerLine = String(data: first.body, encoding: .utf8)!.split(separator: "\n")[0]
        let header = try JSONSerialization.jsonObject(with: Data(headerLine.utf8)) as! [String: Any]
        let wireWindow = header["window"] as! [String: Any]
        XCTAssertEqual("startTs", wireWindow["selector"] as? String)
        XCTAssertEqual(window.startTsInclusive, wireWindow["startInclusive"] as? Int64)
        XCTAssertEqual(window.endTsExclusive, wireWindow["endExclusive"] as? Int64)
    }
}

private func testWindow() -> PushWindow {
    PushWindow(fromDay: "2026-08-05", toDay: "2026-08-18", startTsInclusive: 1_754_348_400, endTsExclusive: 1_755_558_000)
}

private func journalRecord(day: String, question: String, notes: String?) -> PushMutableRecord {
    PushMutableRecord(
        key: ["day": .string(day), "question": .string(question)],
        data: ["answeredYes": .bool(true), "notes": notes.map(PushJSONValue.string) ?? .null, "numericValue": .null]
    )
}

private func hrRecord(rowId: Int64, ts: Int64, bpm: Int) -> PushAppendRecord {
    PushAppendRecord(rowId: rowId, key: ["ts": .int(ts)], data: ["bpm": .int(Int64(bpm))])
}
