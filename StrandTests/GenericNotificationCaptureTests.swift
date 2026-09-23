import XCTest
import Foundation
import GRDB
import WhoopProtocol
import OuraProtocol
import WhoopStore
@testable import Strand

@MainActor
final class GenericNotificationCaptureTests: XCTestCase {
    private let device = "synthetic-generic-notification"
    private let timestamp = 1_750_000_000

    private func prepared(afterRawCommit: @escaping @Sendable () async throws -> Void = {}) async throws -> (WhoopStore, GenericCaptureJournal) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("generic-raw-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try await WhoopStore(path: directory.appendingPathComponent("capture.sqlite").path)
        let owner = try StandardHRCaptureOwner(projectURL: "https://raw-capture.invalid",
            userID: "00000000-0000-0000-0000-0000000000a1")
        try await store.bindAccountOwner(projectURL: owner.projectURL, userID: owner.userID)
        try await store.upsertDevice(id: device, mac: nil, name: nil)
        var hooks = StandardHRJournalHooks()
        hooks.automaticRetry = false
        hooks.afterRawCommit = afterRawCommit
        hooks.availableBytes = { _ in 2_147_483_648 }
        let journal = try await GenericCaptureJournal.prepareStandardHR(store: store, owner: owner,
            runtimeGeneration: UUID(), hooks: hooks)
        addTeardownBlock { try store.registryWriter.close(); try FileManager.default.removeItem(at: directory) }
        return (store, journal)
    }

    private func assertDrained(_ journal: GenericCaptureJournal, expected: Bool = true,
                               file: StaticString = #filePath, line: UInt = #line) async {
        let result = await journal.drain()
        XCTAssertEqual(result, expected, file: file, line: line)
    }
    private func assertEmpty<T>(_ values: [T], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(values.isEmpty, file: file, line: line)
    }
    private func assertCount<T>(_ values: [T], _ count: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(values.count, count, file: file, line: line)
    }

    private func archive(_ store: WhoopStore) async throws -> [[String: Any]] {
        var records: [[String: Any]] = []
        for meta in try await store.rawBatchMetas(deviceId: device, limit: 100) {
            let frames = try await store.rawFrames(batchId: meta.batchId)
            XCTAssertEqual(frames.count, 1)
            records.append(try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frames[0])) as? [String: Any]))
        }
        return records
    }

    func testHuamiCustomNotificationCommitsExactProtocolBytesAndObservedHR() async throws {
        let (store, journal) = try await prepared()
        let sink = try journal.rawNotificationSink(deviceID: device, family: "huami")
        var wakes = 0
        let source = HuamiHRSource(live: LiveState(), deviceId: device, durableCapture: sink,
            startCentral: false, onCaptureOpportunity: { wakes += 1 })
        let service = "0000FEE0-0000-1000-8000-00805F9B34FB"
        let characteristic = "00002A37-0000-3512-2118-0009AF100700"
        XCTAssertTrue(source.ingestNotification(Data([0, 72]), serviceUUID: service,
            characteristicUUID: characteristic, at: timestamp))
        XCTAssertEqual(wakes, 1)
        await assertDrained(journal)
        let rows = try await store.hrSamples(deviceId: device, from: timestamp, to: timestamp + 1, limit: 10)
        XCTAssertEqual(rows.map(\.bpm), [72])
        assertEmpty(try await store.rrIntervals(deviceId: device, from: timestamp, to: timestamp + 1, limit: 10))
        let archives = try await archive(store)
        let raw = try XCTUnwrap(archives.first)
        XCTAssertEqual(raw["serviceUUID"] as? String, service)
        XCTAssertEqual(raw["characteristicUUID"] as? String, characteristic)
        XCTAssertEqual(raw["family"] as? String, "huami")
        XCTAssertEqual(raw["clockQuality"] as? String, "host_receipt_unverified")
        XCTAssertEqual(raw["payload"] as? String, Data([0, 72]).base64EncodedString())
        source.stop(); journal.sealCapture(); await assertDrained(journal)
        XCTAssertFalse(source.ingestNotification(Data([0, 73]), serviceUUID: service,
            characteristicUUID: characteristic, at: timestamp + 1))
    }

    func testFTMSObservedHRAndMalformedOriginalBothSurviveWithoutInventedRR() async throws {
        let (store, journal) = try await prepared()
        let sink = try journal.rawNotificationSink(deviceID: device, family: "ftms")
        let source = FTMSSource(live: LiveState(), durableCapture: sink, startCentral: false)
        // Actual SIG flag decoder fixture: More Data omits speed; bit8 carries HR=99.
        XCTAssertTrue(source.ingestNotification(Data([1, 1, 99]), serviceUUID: "1826",
            characteristicUUID: "2ACD", at: timestamp))
        XCTAssertTrue(source.ingestNotification(Data([255]), serviceUUID: "1826",
            characteristicUUID: "2ACD", at: timestamp + 1))
        source.stop(); journal.sealCapture(); await assertDrained(journal)
        let rows = try await store.hrSamples(deviceId: device, from: timestamp, to: timestamp + 2, limit: 10)
        XCTAssertEqual(rows.map(\.bpm), [99])
        assertCount(try await archive(store), 2)
        assertEmpty(try await store.rrIntervals(deviceId: device, from: timestamp, to: timestamp + 2, limit: 10))
    }

    func testRawInsertFailureRollsBackDecodedRowsAndCursorUntilExactRetry() async throws {
        let (store, journal) = try await prepared()
        let sink = try journal.rawNotificationSink(deviceID: device, family: "huami")
        try await store.registryWriter.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_raw BEFORE INSERT ON rawBatch BEGIN SELECT RAISE(ABORT, 'injected raw failure'); END")
        }
        XCTAssertTrue(sink.capture(Data([72]), serviceUUID: "FEE0", characteristicUUID: "custom", at: timestamp) {
            XCTAssertTrue(sink.persist(Streams(hr: [HRSample(ts: timestamp, bpm: 72)])))
        })
        var cursorSaved = false
        sink.setCursorAfterDurablePrefix { cursorSaved = true }
        await assertDrained(journal, expected: false)
        XCTAssertFalse(cursorSaved)
        XCTAssertEqual(journal.pendingBatchCount, 1)
        assertEmpty(try await store.hrSamples(deviceId: device, from: timestamp, to: timestamp + 1, limit: 10))
        assertEmpty(try await archive(store))
        try await store.registryWriter.write { db in try db.execute(sql: "DROP TRIGGER reject_raw") }
        journal.sealCapture()
        await assertDrained(journal)
        XCTAssertTrue(cursorSaved)
        assertCount(try await archive(store), 1)
        assertCount(try await store.hrSamples(deviceId: device, from: timestamp, to: timestamp + 1, limit: 10), 1)
    }

    func testAdmissionIsBoundedAndFinalAdmittedOriginalIsRetainedAfterSeal() async throws {
        let (store, journal) = try await prepared()
        let sink = try journal.rawNotificationSink(deviceID: device, family: "ftms")
        for index in 0..<16 {
            XCTAssertTrue(sink.capture(Data([UInt8(index)]), serviceUUID: "1826", characteristicUUID: "2ACD",
                at: timestamp + index, uptime: Double(index), decode: {}))
        }
        XCTAssertTrue(journal.isHeld)
        XCTAssertFalse(sink.capture(Data([65]), serviceUUID: "1826", characteristicUUID: "2ACD", at: timestamp + 65, decode: {}))
        XCTAssertEqual(journal.pendingBatchCount, 16)
        journal.sealCapture(); await assertDrained(journal)
        let raw = try await archive(store)
        XCTAssertEqual(raw.count, 16)
        XCTAssertEqual(Set(raw.compactMap { $0["sequence"] as? Int }), Set(0..<16))
        XCTAssertEqual(Set(raw.compactMap { $0["receivedUptime"] as? Double }), Set((0..<16).map(Double.init)))
    }
    private func ouraPacket() -> Data {
        Data([0x60,0x12,0x02,0x00,0x01,0x00,0x80,0x7b,0x77,0x75,0x7a,0x78,0xe4,0xdd,0xcc,0xd4,0xe8,0xd7,0x9d,0x33])
    }

    func testOuraExactCallbackArchivesOriginalAndCommitsAnchoredIBIWithoutLocalHR() async throws {
        try await PhoneComputeRuntime.$testMode.withValue(.finalHosted) {
            let (store, journal) = try await prepared()
            let sink = try journal.rawNotificationSink(deviceID: device, family: "oura")
            let source = OuraLiveSource(live: LiveState(), deviceId: device, ringGen: .gen3,
                authKey: { nil }, startCentral: false, durableCapture: sink)
            let driver = OuraDriver(ringGen: .gen3, authKey: nil)
            XCTAssertTrue(driver.adoptSyncTimeAnchor(ringTimestamp: 0x0001_0002, unixSeconds: Int64(timestamp)))
            source.prepareNotificationTestDriver(driver)
            source.ingestNotification(ouraPacket())
            source.stop(); journal.sealCapture(); await assertDrained(journal)
            let observations = try await store.rrIntervals(deviceId: device, from: timestamp, to: timestamp + 1, limit: 20)
            XCTAssertEqual(observations.count, 6)
            assertEmpty(try await store.hrSamples(deviceId: device, from: timestamp, to: timestamp + 1, limit: 20))
            let originals = try await archive(store)
            XCTAssertEqual(originals.count, 1)
            XCTAssertEqual(originals.first?["payload"] as? String, ouraPacket().base64EncodedString())
        }
    }

    func testOuraUnanchoredCallbackRetainsOriginalWithoutReceiptTimeBeatProjection() async throws {
        try await PhoneComputeRuntime.$testMode.withValue(.finalHosted) {
            let (store, journal) = try await prepared()
            let sink = try journal.rawNotificationSink(deviceID: device, family: "oura")
            let source = OuraLiveSource(live: LiveState(), deviceId: device, ringGen: .gen3,
                authKey: { nil }, startCentral: false, durableCapture: sink)
            source.prepareNotificationTestDriver(OuraDriver(ringGen: .gen3, authKey: nil))
            source.ingestNotification(ouraPacket())
            source.stop(); journal.sealCapture(); await assertDrained(journal)
            let count = try await store.registryWriter.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rrInterval") }
            XCTAssertEqual(count, 0)
            let originals = try await archive(store)
            XCTAssertEqual(originals.count, 1)
            XCTAssertEqual(originals.first?["clockQuality"] as? String, "host_receipt_unverified")
        }
    }

    func testOuraResumeCursorIsScopedAndFollowsOriginalDurability() async throws {
        let (store, journal) = try await prepared()
        let sink = try journal.rawNotificationSink(deviceID: device, family: "oura")
        let source = OuraLiveSource(live: LiveState(), deviceId: device, ringGen: .gen3,
            authKey: { nil }, startCentral: false, durableCapture: sink)
        let key = "com.noop.oura.historyCursor.scoped." + sink.cursorScope + "." + device
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        try await store.registryWriter.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_raw BEFORE INSERT ON rawBatch BEGIN SELECT RAISE(ABORT, 'injected raw failure'); END")
        }
        source.prepareNotificationTestDriver(OuraDriver(ringGen: .gen3, authKey: nil))
        source.ingestNotification(Data([0x7f, 1, 0]))
        source.saveNotificationTestCursor(123)
        await assertDrained(journal, expected: false)
        XCTAssertEqual(OuraHistoryCursorStore.read(deviceId: device, scope: sink.cursorScope), 0)
        try await store.registryWriter.write { db in try db.execute(sql: "DROP TRIGGER reject_raw") }
        source.stop(); journal.sealCapture(); await assertDrained(journal)
        XCTAssertEqual(OuraHistoryCursorStore.read(deviceId: device, scope: sink.cursorScope), 123)
        XCTAssertEqual(OuraHistoryCursorStore.read(deviceId: device, scope: "other-account"), 0)
        assertCount(try await archive(store), 1)
    }

    func testRepeatedCursorOffersCoalesceAndFinalResetWaitsForCommit() async throws {
        let (store, journal) = try await prepared()
        let sink = try journal.rawNotificationSink(deviceID: device, family: "oura")
        try await store.registryWriter.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_raw BEFORE INSERT ON rawBatch BEGIN SELECT RAISE(ABORT, 'injected raw failure'); END")
        }
        XCTAssertTrue(sink.capture(Data([1]), serviceUUID: "oura", characteristicUUID: "notify", at: timestamp, decode: {}))
        var saved = -1, calls = 0
        for cursor in 1...10_000 { XCTAssertTrue(sink.setCursorAfterDurablePrefix { saved = cursor; calls += 1 }) }
        XCTAssertTrue(sink.setCursorAfterDurablePrefix { saved = 0; calls += 1 })
        await assertDrained(journal, expected: false)
        XCTAssertEqual(saved, -1); XCTAssertEqual(calls, 0)
        XCTAssertEqual(journal.pendingBatchCount, 1)
        try await store.registryWriter.write { db in try db.execute(sql: "DROP TRIGGER reject_raw") }
        journal.sealCapture(); await assertDrained(journal)
        XCTAssertEqual(saved, 0); XCTAssertEqual(calls, 1)
    }

    func testOuraLongUnknownClockAndPhaseStreamRemainsRawWithoutLocalTimeline() async throws {
        try await PhoneComputeRuntime.$testMode.withValue(.finalHosted) {
            PhoneComputeRuntime.resetTestCounters()
            let (store, journal) = try await prepared()
            let sink = try journal.rawNotificationSink(deviceID: device, family: "oura")
            let source = OuraLiveSource(live: LiveState(), deviceId: device, ringGen: .gen3,
                authKey: { nil }, startCentral: false, durableCapture: sink)
            source.prepareNotificationTestDriver(OuraDriver(ringGen: .gen3, authKey: nil))
            let phase = Data([0x4e, 0x06, 0x02, 0x00, 0x01, 0x00, 0x00, 0x6c])
            for _ in 0..<32 {
                source.ingestNotification(ouraPacket())
                source.ingestNotification(phase)
                await assertDrained(journal)
            }
            XCTAssertEqual(source.notificationTestRetainedHistoryCount, 0)
            source.stop(); journal.sealCapture(); await assertDrained(journal)
            let counts = try await store.registryWriter.read { db in
                try ["rawBatch", "rrInterval", "hrSample", "event"].map { try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? -1 }
            }
            XCTAssertEqual(counts, [64, 0, 0, 0])
            XCTAssertEqual(PhoneComputeRuntime.counters().executions.values.reduce(0, +), 0)
            let originals = try await archive(store)
            XCTAssertEqual(originals.filter { $0["payload"] as? String == phase.base64EncodedString() }.count, 32)
            XCTAssertEqual(originals.filter { $0["payload"] as? String == ouraPacket().base64EncodedString() }.count, 32)
        }
    }

    func testHuamiAndFTMSBatteryCallbacksKeepTheirActualCharacteristicAndRawBytes() async throws {
        let (store, journal) = try await prepared()
        let huami = HuamiHRSource(live: LiveState(), deviceId: device,
            durableCapture: try journal.rawNotificationSink(deviceID: device, family: "huami"), startCentral: false)
        let ftms = FTMSSource(live: LiveState(),
            durableCapture: try journal.rawNotificationSink(deviceID: device, family: "ftms"), startCentral: false)
        XCTAssertTrue(huami.ingestNotification(Data([72]), serviceUUID: "180F", characteristicUUID: "2A19", at: timestamp))
        XCTAssertTrue(ftms.ingestNotification(Data([88]), serviceUUID: "180F", characteristicUUID: "2A19", at: timestamp + 1))
        huami.stop(); ftms.stop(); journal.sealCapture(); await assertDrained(journal)
        let originals = try await archive(store)
        XCTAssertEqual(originals.count, 2)
        XCTAssertEqual(Set(originals.compactMap { $0["characteristicUUID"] as? String }), ["2A19"])
        let batteries = try await store.registryWriter.read { db in
            try Double.fetchAll(db, sql: "SELECT soc FROM battery ORDER BY ts")
        }
        XCTAssertEqual(batteries, [72, 88])
    }

    private actor OneCommitFailure {
        var shouldFail = true
        func check() throws {
            if shouldFail { shouldFail = false; throw NSError(domain: "injected-after-commit", code: 1) }
        }
    }

    func testLostCommitResponseReplaysExactRawAndDecodedIdentityOnce() async throws {
        let failure = OneCommitFailure()
        let (store, journal) = try await prepared(afterRawCommit: { try await failure.check() })
        let sink = try journal.rawNotificationSink(deviceID: device, family: "huami")
        XCTAssertTrue(sink.capture(Data([72]), serviceUUID: "FEE0", characteristicUUID: "custom", at: timestamp) {
            XCTAssertTrue(sink.persist(Streams(hr: [HRSample(ts: timestamp, bpm: 72)])))
        })
        var cursor = false
        sink.setCursorAfterDurablePrefix { cursor = true }
        await assertDrained(journal, expected: false)
        XCTAssertFalse(cursor)
        assertCount(try await archive(store), 1)
        assertCount(try await store.hrSamples(deviceId: device, from: timestamp, to: timestamp + 1, limit: 10), 1)
        journal.sealCapture(); await assertDrained(journal)
        XCTAssertTrue(cursor)
        assertCount(try await archive(store), 1)
        assertCount(try await store.hrSamples(deviceId: device, from: timestamp, to: timestamp + 1, limit: 10), 1)
    }

}
