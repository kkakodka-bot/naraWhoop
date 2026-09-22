import XCTest
@testable import NoopPush

final class PushMutableGenerationTests: XCTestCase {
    private let source = "44444444-4444-4444-8444-444444444444"
    private let device = "33333333-3333-4333-8333-333333333333"

    private func batches(day: String, values: [Bool?], versioned: Bool) throws -> [PushBatch] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = ISO8601DateFormatter().date(from: day + "T00:00:00Z")!
        return try values.enumerated().map { index, value in
            let records = value.map { [PushMutableRecord(key: ["day": .string(day), "question": .string("synthetic")],
                data: ["answeredYes": .bool($0), "notes": .null, "numericValue": .null])] } ?? []
            return try XCTUnwrap(PushProtocol.mutableBatches(table: .journal, sourceId: source,
                deviceId: device, window: .days(from: date, to: date, calendar: calendar), records: records,
                replacementGeneration: versioned ? "synthetic-receiver|revision-\(index + 1)|nonce-\(index + 1)" : nil).first)
        }
    }

    func testCachedReceiverAppliesReturnToPriorValueAndEmptySnapshotOnlyWithNewGeneration() throws {
        let legacy = try batches(day: "2026-09-18", values: [true, false, true], versioned: false)
        var oldReceiver = CachedMutableReceiver()
        for batch in legacy { _ = try oldReceiver.accept(batch) }
        XCTAssertEqual(legacy[0].batchId, legacy[2].batchId)
        XCTAssertEqual(oldReceiver.value, false, "Negative control must expose the old cached-ACK bug")
        XCTAssertEqual(oldReceiver.applied, 2)

        let updated = try batches(day: "2026-09-19", values: [true, false, true], versioned: true)
        var receiver = CachedMutableReceiver()
        for batch in updated {
            let receipt = try receiver.accept(batch)
            XCTAssertTrue(receipt.matches(batch, owner: receiver.owner))
        }
        XCTAssertEqual(Set(updated.map(\.batchId)).count, 3)
        XCTAssertEqual(Set(updated.compactMap(\.replacementId)).count, 3)
        XCTAssertEqual(receiver.value, true)
        XCTAssertEqual(receiver.applied, 3)

        let empty = try batches(day: "2026-09-20", values: [nil, true, nil], versioned: true)
        var deletionReceiver = CachedMutableReceiver()
        for batch in empty { _ = try deletionReceiver.accept(batch) }
        XCTAssertNil(deletionReceiver.value)
        XCTAssertEqual(deletionReceiver.applied, 3)
        _ = try deletionReceiver.accept(empty[2])
        XCTAssertEqual(deletionReceiver.applied, 3, "Exact immutable retry must remain idempotent")

        if let directory = ProcessInfo.processInfo.environment["NOOP_MUTABLE_GENERATION_FIXTURES"] {
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let groups = [("legacy_aba", legacy), ("generated_aba", updated), ("generated_empty", empty)]
            let artifact: [String: Any] = ["schema_version": 1, "synthetic_only": true,
                "groups": groups.map { name, values in ["name": name, "bodies_base64": values.map { $0.body.base64EncodedString() }] }]
            try JSONSerialization.data(withJSONObject: artifact, options: [.sortedKeys, .prettyPrinted])
                .write(to: output.appendingPathComponent("mutable-generations.json"), options: .atomic)
        }
    }

    func testSavedGenerationReplaysExactBytesAndLegacySelectionsStayUnchanged() throws {
        for versioned in [false, true] {
            let batch = try batches(day: "2026-09-21", values: [true], versioned: versioned)[0]
            let window = try XCTUnwrap(batch.window)
            let progress = PushWindowProgress(window: window, batchId: try XCTUnwrap(batch.replacementId),
                dayHashes: [window.fromDay: String(repeating: "a", count: 64)])
            let saved = try PushPreparedSelection(inline: [batch], commit: .init(kind: .mutable,
                table: batch.table.wireName, deviceID: device, batchIDs: [batch.batchId], window: progress))
            let encoded = try saved.encoded(), replay = try PushPreparedSelection.decode(encoded)
            let restored = try replay.restoredInlineBatches()[0]
            XCTAssertEqual(restored.body, batch.body)
            XCTAssertEqual(restored.batchId, batch.batchId)
            XCTAssertEqual(try replay.encoded(), encoded)
            var receiver = CachedMutableReceiver()
            XCTAssertEqual(try receiver.accept(batch), try receiver.accept(restored))
            XCTAssertEqual(receiver.applied, 1)
            XCTAssertFalse(String(decoding: batch.body, as: UTF8.self).contains("synthetic-receiver"),
                           "Local namespace/generation must not leak into wire fields")
        }
    }

    func testGenerationIsBoundedAndChangesOnlyReplacementIdentity() throws {
        let a = try batches(day: "2026-09-22", values: [true], versioned: false)[0]
        let record = PushMutableRecord(key: ["day": .string("2026-09-22"), "question": .string("synthetic")],
            data: ["answeredYes": .bool(true), "notes": .null, "numericValue": .null])
        for generation in ["", String(repeating: "x", count: 4097)] {
            XCTAssertThrowsError(try PushProtocol.mutableBatches(table: .journal, sourceId: source,
                deviceId: device, window: XCTUnwrap(a.window), records: [record], replacementGeneration: generation))
        }
        let first = try PushProtocol.mutableBatches(table: .journal, sourceId: source, deviceId: device,
            window: XCTUnwrap(a.window), records: [record], replacementGeneration: "receiver-one|revision-one|nonce")[0]
        let second = try PushProtocol.mutableBatches(table: .journal, sourceId: source, deviceId: device,
            window: XCTUnwrap(a.window), records: [record], replacementGeneration: "receiver-two|revision-one|nonce")[0]
        XCTAssertNotEqual(first.batchId, second.batchId)
        XCTAssertNotEqual(first.batchId, a.batchId)
        XCTAssertEqual(first.protocolVersion, a.protocolVersion)
        XCTAssertEqual(first.body.split(separator: 10).dropFirst(), a.body.split(separator: 10).dropFirst())
    }
}

/// Matches production ingest's cached exact-batch response before projection application.
private struct CachedMutableReceiver {
    let owner = try! AccountScope(projectURL: "https://synthetic.example", userID: "11111111-1111-4111-8111-111111111111")
    private var saved: [String: (Data, PushDurabilityReceipt)] = [:]
    var value: Bool?
    var applied = 0

    mutating func accept(_ batch: PushBatch) throws -> PushDurabilityReceipt {
        if let prior = saved[batch.batchId] {
            guard prior.0 == batch.body else { throw PushProtocolException("batch_id_conflict") }
            return prior.1
        }
        let records = try batch.body.split(separator: 10).dropFirst().map {
            try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any]
        }
        value = (records.first?["data"] as? [String: Any])?["answeredYes"] as? Bool
        applied += 1
        let fields: [String: Any] = ["version": 1, "state": "verified_indexed", "receiptId": UUID().uuidString.lowercased(),
            "ownerUserId": owner.userID, "deviceId": batch.deviceId, "objectId": batch.batchId, "batchId": batch.batchId,
            "sourceId": batch.sourceId, "stream": batch.table.wireName, "schemaVersion": 1, "objectKey": "synthetic/verified",
            "contentSha256": PushDurabilityReceipt.sha256(batch.body), "wireSha256": String(repeating: "b", count: 64),
            "compressedBytes": batch.body.count, "uncompressedBytes": batch.body.count,
            "verifiedAt": "2026-09-22T00:00:00Z", "indexedAt": "2026-09-22T00:00:01Z"]
        let receipt = try JSONDecoder().decode(PushDurabilityReceipt.self, from: JSONSerialization.data(withJSONObject: fields))
        saved[batch.batchId] = (batch.body, receipt)
        return receipt
    }
}
