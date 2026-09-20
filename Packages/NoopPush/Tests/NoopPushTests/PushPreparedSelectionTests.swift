import XCTest
@testable import NoopPush

final class PushPreparedSelectionTests: XCTestCase {
    private let source = "3a3486dd-5030-4e17-a00d-a781399890f9"
    private func append() throws -> PushBatch {
        try PushProtocol.appendBatch(table: .hrSample, sourceId: source, deviceId: "synthetic", startCursor: nil,
            records: [.init(rowId: 7, key: ["ts": .int(123)],
                data: ["bpm": .int(61)])])
    }
    private func commit(_ batch: PushBatch) -> PushSourceCommit {
        .init(kind: .append, table: batch.table.wireName, deviceID: batch.deviceId, batchIDs: [batch.batchId], cursor: batch.endCursor)
    }
    private func mutate(_ model: PushPreparedSelection, _ change: (inout [String: Any]) -> Void) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: model.encoded()) as? [String: Any])
        change(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    func testAppendRoundTripKeepsExactBytesAndCursor() throws {
        let batch = try append(), model = try PushPreparedSelection(inline: [batch], commit: commit(batch))
        let restored = try PushPreparedSelection.decode(model.encoded())
        XCTAssertEqual(try restored.restoredInlineBatches().first?.body, batch.body)
        XCTAssertEqual(restored.commit.cursor, batch.endCursor)
        XCTAssertEqual(try restored.encoded(), try model.encoded())
    }
    func testUnknownAndMissingLocalVersionsFailClosed() throws {
        let batch = try append(), model = try PushPreparedSelection(inline: [batch], commit: commit(batch))
        for version in [1, 3] { XCTAssertThrowsError(try PushPreparedSelection.decode(mutate(model) { $0["version"] = version })) }
        XCTAssertThrowsError(try PushPreparedSelection.decode(mutate(model) { $0.removeValue(forKey: "version") }))
    }
    func testChangedInlineBytesAndMismatchedCommitRejected() throws {
        let batch = try append(), model = try PushPreparedSelection(inline: [batch], commit: commit(batch))
        XCTAssertThrowsError(try PushPreparedSelection.decode(mutate(model) {
            var parts = $0["inline"] as! [[String: Any]]; parts[0]["body"] = Data("changed\n".utf8).base64EncodedString(); $0["inline"] = parts
        }))
        XCTAssertThrowsError(try PushPreparedSelection(inline: [batch], commit: .init(kind: .append,
            table: batch.table.wireName, deviceID: "other", batchIDs: [batch.batchId], cursor: batch.endCursor)))
    }
    func testMultipartWholeGroupAndFullWindowSurviveRoundTrip() throws {
        let window = PushWindow(fromDay: "2026-09-18", toDay: "2026-09-18", startTsInclusive: 1, endTsExclusive: 86_401)
        let rows = (0...5_000).map { PushMutableRecord(key: ["day": .string("2026-09-18"), "question": .string("q\($0)")],
            data: ["answeredYes": .bool(true), "notes": .null, "numericValue": .null]) }
        let batches = try PushProtocol.mutableBatches(table: .journal, sourceId: source, deviceId: "synthetic", window: window, records: rows)
        XCTAssertEqual(batches.count, 2)
        let full = PushWindow(fromDay: "2026-09-17", toDay: "2026-09-18", startTsInclusive: -86_399, endTsExclusive: 86_401)
        let progress = PushWindowProgress(window: full, batchId: batches[0].replacementId!, dayHashes: [
            "2026-09-17": String(repeating: "a", count: 64), "2026-09-18": String(repeating: "b", count: 64)])
        let commit = PushSourceCommit(kind: .mutable, table: "journal", deviceID: "synthetic", batchIDs: batches.map(\.batchId), window: progress)
        let restored = try PushPreparedSelection.decode(PushPreparedSelection(inline: batches, commit: commit).encoded())
        XCTAssertEqual(try restored.restoredInlineBatches().map(\.body), batches.map(\.body))
        XCTAssertEqual(restored.commit.window?.dayHashes, progress.dayHashes)
        XCTAssertEqual(restored.commit.window?.window.fromDay, full.fromDay)
        XCTAssertThrowsError(try PushPreparedSelection(inline: Array(batches.reversed()), commit: commit))
        XCTAssertThrowsError(try PushPreparedSelection(inline: [batches[0]], commit: commit))
        XCTAssertThrowsError(try PushPreparedSelection(inline: [batches[0], batches[0]], commit: commit))
    }
    func testBinaryMemberAndExactCompressedBytesAcrossCapturedVersions() throws {
        let examples: [(PushBinaryTable, String, [PushBinaryRow])] = [
            (.ppgWaveformSample, "1.2", [.ppgWaveform(.init(rowId: 4, ts: 100, burstIndex: 1, samples: Data([1, 2])))]),
            (.ppgWaveformSample, "1.3", [.ppgWaveform(.init(rowId: 4, ts: 100, burstIndex: 1, samples: Data([1, 2]), recordIndex: 19))]),
            (.v18AuxSample, "1.4", [.v18Aux(.init(rowId: 7, ts: 100, fields: Data([3]), recordIndex: 19, resourceKey: "resource-a"))]),
            (.rawImuSession, "1.2", [1, 2].map { .rawImuSession(.init(rowId: Int64($0), ts: 100, columns: Data(repeating: UInt8($0), count: 1200))) }),
            (.rawBatch, "1.2", [.rawBatch(.init(rowId: 9, batchId: "archive-synthetic", capturedAt: 100, deviceClockRef: 99,
                wallClockRef: 100, startTs: 100, endTs: 100, frameCount: 1, byteSize: 4, framesBlob: Data([1, 2, 3, 4])))])
        ]
        for (table, version, rows) in examples {
            let batch = try PushProtocol.binaryObjectBatch(table: table, sourceId: source, deviceId: "synthetic", startCursor: nil,
                rows: rows, protocolVersion: version, decodedLimit: PushProtocolLimits.maxObjectDecodedBytes)
            let lane = PushObjectLane(endpoint: "/objects", maxObjectBytes: Int64(PushProtocolLimits.maxObjectWireBytes), urlTtlSec: 60, streams: [table])
            let manifest = PushObjectManifest(batch: batch).replacingObjectId("4b4597ee-6141-4f28-b11e-b8924a9a9010")
            let commit = PushSourceCommit(kind: .binary, table: table.wireName, deviceID: "synthetic", batchIDs: [batch.batchId],
                cursor: batch.endCursor, rawBatchIDs: table == .rawBatch ? ["archive-synthetic"] : [])
            let model = try PushPreparedSelection(binary: batch, rows: rows, manifest: manifest, lane: lane, commit: commit)
            let restored = try XCTUnwrap(PushPreparedSelection.decode(model.encoded()).restoredObject())
            XCTAssertEqual(restored.batch.payload, batch.payload)
            XCTAssertEqual(restored.batch.manifestJSON, batch.manifestJSON)
            XCTAssertEqual(restored.manifest, manifest)
            XCTAssertEqual(restored.rows.count, rows.count)
            XCTAssertThrowsError(try PushPreparedSelection.decode(mutate(model) {
                var binary = $0["binary"] as! [String: Any]; binary["payload"] = Data([0]).base64EncodedString(); $0["binary"] = binary
            }))
            if table == .rawImuSession {
                XCTAssertThrowsError(try PushPreparedSelection(binary: batch, rows: Array(rows.prefix(1)), manifest: manifest, lane: lane, commit: commit))
            }
        }
    }

    func testEveryFreshLanePreparesBeforeAnyDeliveryAndPreparationFailureStopsSend() async throws {
        let state = PreparedHookFixture()
        let coordinator = PushCoordinator(source: state, transport: state, progress: state, sourceId: source,
            prepareSelection: { selection in
                await state.prepared(selection)
                throw PushProtocolException("controlled preparation failure")
            })
        for result in [await coordinator.pushAppend(.hrSample, deviceId: "synthetic"),
                       await coordinator.pushMutable(.journal, deviceId: "synthetic"),
                       await coordinator.pushObjects(.ppgWaveformSample, deviceId: "synthetic", lane: .init(endpoint: "/objects",
                            maxObjectBytes: 8_000_000, urlTtlSec: 60, streams: [.ppgWaveformSample]))] {
            guard case .rejected = result else { return XCTFail("preparation failure must stop this lane") }
        }
        let kinds = await state.kinds, calls = await state.networkCalls, days = await state.savedDays
        XCTAssertEqual(kinds, [.append, .mutable, .binary])
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(days, 14, "pre-delivery callback carries the whole rolling window, including empty days")
    }

    func testFreshMutablePreparationKeepsCalendarLocalWindowAcrossOffsetAndDST() async throws {
        for (zone, day, seconds) in [
            ("America/Los_Angeles", "2026-03-15", 14 * 86_400 - 3_600),
            ("America/Los_Angeles", "2026-11-08", 14 * 86_400 + 3_600),
            ("Australia/Lord_Howe", "2026-10-11", 14 * 86_400 - 1_800),
            ("Asia/Kathmandu", "2026-09-18", 14 * 86_400),
            ("Etc/UTC", "2026-09-18", 14 * 86_400)
        ] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = calendar.timeZone; f.dateFormat = "yyyy-MM-dd HH:mm"
            let today = try XCTUnwrap(f.date(from: day + " 12:00"))
            for table in [PushMutableTable.journal, .workout] {
                let state = PreparedHookFixture()
                let coordinator = PushCoordinator(source: state, transport: state, progress: state, sourceId: source,
                    today: { today }, calendar: calendar, prepareSelection: { selection in
                        await state.prepared(selection)
                        throw PushProtocolException("controlled preparation failure")
                    })
                _ = await coordinator.pushMutable(table, deviceId: "synthetic")
                let saved = await state.selections
                let selection = try XCTUnwrap(saved.first, "\(zone) \(day) \(table)")
                let window = try XCTUnwrap(selection.commit.window)
                let batchWindow = try XCTUnwrap(selection.restoredInlineBatches().first?.window)
                XCTAssertEqual(window.window.toDay, day)
                XCTAssertEqual(window.dayHashes.count, 14)
                XCTAssertEqual(window.window.endTsExclusive - window.window.startTsInclusive, Int64(seconds))
                XCTAssertEqual(batchWindow.fromDay, window.window.fromDay)
                XCTAssertEqual(batchWindow.toDay, window.window.toDay)
                XCTAssertEqual(batchWindow.startTsInclusive, window.window.startTsInclusive)
                XCTAssertEqual(batchWindow.endTsExclusive, window.window.endTsExclusive)
                let calls = await state.networkCalls
                XCTAssertEqual(calls, 0)
            }
        }
    }
}

private actor PreparedHookFixture: PushSnapshotSource, PushTransport, PushProgressStore {
    var kinds: [PushSourceCommit.Kind] = []
    var networkCalls = 0
    var savedDays = 0
    var selections: [PushPreparedSelection] = []
    func prepared(_ selection: PushPreparedSelection) {
        selections.append(selection)
        kinds.append(selection.commit.kind)
        if let window = selection.commit.window { savedDays = window.dayHashes.count }
    }
    func knownDeviceIds(capabilities: PushCapabilities) -> [String] { ["synthetic"] }
    func appendRecordAt(table: PushAppendTable, deviceId: String, rowId: Int64) -> PushAppendRecord? { nil }
    func appendRows(table: PushAppendTable, deviceId: String, afterRowId: Int64, limit: Int) -> [PushAppendRecord] {
        [.init(rowId: 1, key: ["ts": .int(100)], data: ["bpm": .int(60)])]
    }
    func mutableRows(table: PushMutableTable, deviceId: String, window: PushWindow, limit: Int) -> [PushMutableRecord] { [] }
    func binaryRecordAt(table: PushBinaryTable, deviceId: String, rowId: Int64) -> PushBinaryRow? { nil }
    func binaryRows(table: PushBinaryTable, deviceId: String, afterRowId: Int64, limit: Int) -> [PushBinaryRow] {
        [.ppgWaveform(.init(rowId: 1, ts: 100, burstIndex: nil, samples: Data([1])))]
    }
    func acknowledgeBinary(table: PushBinaryTable, deviceId: String, rows: [PushBinaryRow]) { XCTFail("source ACK after failed preparation") }
    func capabilities() -> PushCapabilitiesResult { .available(.all) }
    func post(_ batch: PushBatch) throws -> PushTransportResponse { networkCalls += 1; throw PushProtocolException("unexpected send") }
    func postBinary(_ batch: PushBinaryBatch) throws -> PushTransportResponse { networkCalls += 1; throw PushProtocolException("unexpected send") }
    func createObjectIntent(_ manifest: PushObjectManifest, lane: PushObjectLane) throws -> PushObjectIntent { networkCalls += 1; throw PushProtocolException("unexpected intent") }
    func knownDeviceIds() -> Set<String> { ["synthetic"] }
    func rememberDeviceId(_ deviceId: String) {}
    func cursor(table: PushAppendTable, deviceId: String) -> PushCursor? { nil }
    func saveCursor(table: PushAppendTable, deviceId: String, cursor: PushCursor) { XCTFail("cursor after failed preparation") }
    func binaryCursor(table: PushBinaryTable, deviceId: String) -> PushCursor? { nil }
    func saveBinaryCursor(table: PushBinaryTable, deviceId: String, cursor: PushCursor) { XCTFail("binary cursor after failed preparation") }
    func window(table: PushMutableTable, deviceId: String) -> PushWindowProgress? { nil }
    func saveWindow(table: PushMutableTable, deviceId: String, progress: PushWindowProgress) { XCTFail("window after failed preparation") }
}
