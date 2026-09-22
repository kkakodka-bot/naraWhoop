import Foundation
import XCTest
@testable import NoopPush

final class PushResourceAdmissionTests: XCTestCase {
    private let sourceID = "22222222-2222-4222-8222-222222222222"

    func testDeniedAdmissionDoesNotReadSourceOrProgressAcrossEveryEntryPoint() async throws {
        let probe = AdmissionProbe()
        let coordinator = PushCoordinator(source: probe, transport: probe, progress: probe,
            sourceId: sourceID, allowsPreparation: { false })
        let lane = PushObjectLane(endpoint: "https://fixture.invalid/objects",
            maxObjectBytes: 1_000_000, urlTtlSec: nil, streams: [.rawBatch])
        let results = [
            await coordinator.pushAppend(.battery, deviceId: "synthetic-device"),
            await coordinator.pushMutable(.dailyMetric, deviceId: "synthetic-device"),
            await coordinator.pushBinary(.rawBatch, deviceId: "synthetic-device"),
            await coordinator.pushObjects(.rawBatch, deviceId: "synthetic-device", lane: lane)
        ]
        for result in results {
            guard case .rejected(let reason, let retryable, let failure) = result else {
                return XCTFail("denied work must remain retryable debt")
            }
            XCTAssertEqual(reason, "resource_pressure")
            XCTAssertTrue(retryable)
            XCTAssertNil(failure)
        }
        let run = await coordinator.pushKnownDevices(binaryEnabled: true)
        XCTAssertEqual(run.acceptedBatches, 0)
        XCTAssertEqual(run.rejectedBatches, 0)
        XCTAssertTrue(run.hasMoreAppendRows)
        XCTAssertTrue(run.hasRetryableFailure)
        let calls = await probe.calls
        XCTAssertEqual(calls, [], "admission must precede discovery, cursors, scans, and transport")
    }

    func testPressureBetweenLanesStopsFurtherScansAndPacking() async throws {
        let gate = AdmissionGate()
        let probe = AdmissionProbe(revokeAfterMutableRead: { gate.deny() })
        let coordinator = PushCoordinator(source: probe, transport: probe, progress: probe,
            sourceId: sourceID, allowsPreparation: { gate.allowed })
        let lane = PushObjectLane(endpoint: "https://fixture.invalid/objects",
            maxObjectBytes: 1_000_000, urlTtlSec: nil, streams: [.rawBatch])
        let capabilities = PushCapabilities(appendTables: [.battery, .hrSample],
            mutableTables: [.dailyMetric, .sleepSession], binaryTables: [.rawBatch], objectLane: lane)
        let run = await coordinator.pushKnownDevices(capabilities: capabilities, binaryEnabled: true)
        XCTAssertEqual(run.acceptedBatches, 0)
        XCTAssertTrue(run.hasRetryableFailure)
        let calls = await probe.calls
        XCTAssertEqual(calls, ["source.devices", "progress.remember", "progress.devices", "source.mutable"])
    }

    func testAdmissionCanResumeWithoutRecreatingCoordinator() async throws {
        let gate = AdmissionGate()
        gate.deny()
        let probe = AdmissionProbe()
        let coordinator = PushCoordinator(source: probe, transport: probe, progress: probe,
            sourceId: sourceID, allowsPreparation: { gate.allowed })
        _ = await coordinator.pushAppend(.battery, deviceId: "synthetic-device")
        let deniedCalls = await probe.calls
        XCTAssertEqual(deniedCalls, [])
        gate.allow()
        let result = await coordinator.pushAppend(.battery, deviceId: "synthetic-device")
        guard case .noData = result else { return XCTFail("empty admitted source should finish without upload") }
        let resumedCalls = await probe.calls
        XCTAssertEqual(resumedCalls, ["progress.cursor", "source.append"])
    }

    func testWakeBudgetBoundsActualSourceSelectionAndStopsNextLaneBeforeRead() async throws {
        let probe = AdmissionProbe(appendCount: 5_001)
        let budget = PushWakeBudget(maximumRequests: 1, clock: { 100 })
        let coordinator = PushCoordinator(source: probe, transport: probe, progress: probe,
            sourceId: sourceID, wakeBudget: budget)
        _ = await coordinator.pushAppend(.battery, deviceId: "synthetic-device")
        let firstCalls = await probe.calls
        let limit = await probe.lastAppendLimit
        let posted = await probe.lastPostedRows
        XCTAssertEqual(limit, 2_001)
        XCTAssertEqual(posted, 2_000)
        let next = await coordinator.pushAppend(.hrSample, deviceId: "synthetic-device")
        guard case .rejected(let reason, let retryable, _) = next else { return XCTFail("exhausted wake started another lane") }
        XCTAssertEqual(reason, "resource_pressure")
        XCTAssertTrue(retryable)
        let nextCalls = await probe.calls
        XCTAssertEqual(nextCalls, firstCalls)
        XCTAssertFalse(nextCalls.contains("progress.saveCursor"))
    }
    func testEmptyLanesRefundTheirByteReservationBeforeLaterSourceDebt() async throws {
        let probe = AdmissionProbe(binary: [.ppgWaveform(.init(rowId: 1, ts: 100, burstIndex: nil, samples: Data([1])))])
        let captured = PreparedCapture()
        let coordinator = PushCoordinator(source: probe, transport: probe, progress: probe, sourceId: sourceID,
            prepareSelection: { await captured.save($0) },
            wakeBudget: PushWakeBudget(maximumPreparedBytes: 4 * 1_048_576 + 64 * 1024, clock: { 100 }))
        for table in PushAppendTable.allCases {
            guard case .noData = await coordinator.pushAppend(table, deviceId: "fixture") else { return XCTFail("empty lane exhausted real-work budget") }
        }
        _ = await coordinator.pushObjects(.ppgWaveformSample, deviceId: "fixture",
            lane: .init(endpoint: "/objects", maxObjectBytes: 10_000_000, urlTtlSec: nil, streams: [.ppgWaveformSample]))
        let saved = await captured.selection
        XCTAssertNotNil(saved)
    }

    func testInsufficientObjectControlBudgetDefersBeforeSourceOrCursorRead() async throws {
        let probe = AdmissionProbe()
        let budget = PushWakeBudget(maximumWireBytes: 4 * 1_048_576 + 64 * 1024, clock: { 100 })
        let coordinator = PushCoordinator(source: probe, transport: probe, progress: probe, sourceId: sourceID, wakeBudget: budget)
        let lane = PushObjectLane(endpoint: "/objects", maxObjectBytes: 10_000_000, urlTtlSec: nil, streams: [.ppgWaveformSample])
        let result = await coordinator.pushObjects(.ppgWaveformSample, deviceId: "fixture", lane: lane)
        guard case .rejected("resource_pressure", true, _) = result else { return XCTFail("packing began without control headroom") }
        let calls = await probe.calls
        XCTAssertEqual(calls, [])
    }

    func testUnsplittableMemberPausesAndNextWakeDoesNotReadOrSkipIt() async throws {
        let probe = AdmissionProbe(binary: [.ppgWaveform(.init(rowId: 1, ts: 100, burstIndex: nil, samples: Data(count: 1000))),
            .ppgWaveform(.init(rowId: 2, ts: 101, burstIndex: nil, samples: Data([1])))])
        let lane = PushObjectLane(endpoint: "/objects", maxObjectBytes: 10_000_000, urlTtlSec: nil, streams: [.ppgWaveformSample])
        for _ in 0..<2 {
            let coordinator = PushCoordinator(source: probe, transport: probe, progress: probe, sourceId: sourceID,
                wakeBudget: PushWakeBudget(objectDecodedBytesPerJob: 100, clock: { 100 }))
            let result = await coordinator.pushObjects(.ppgWaveformSample, deviceId: "fixture", lane: lane)
            guard case .rejected("compatible_encoder_required", false, _) = result else { return XCTFail("unsplittable row was not visibly paused") }
        }
        let calls = await probe.calls
        XCTAssertEqual(calls, ["progress.binaryCursor", "source.binary", "transport.pause"])
    }

    func testExactPreparationReservationStillFinishesOneBoundedJob() async throws {
        let row = PushBinaryRow.ppgWaveform(.init(rowId: 1, ts: 100, burstIndex: nil, samples: Data(count: 1000)))
        let probe = AdmissionProbe(binary: [row])
        let captured = PreparedCapture()
        let decoded = try PushBinaryCodec.pack(table: .ppgWaveformSample, rows: [row]).count
        let budget = PushWakeBudget(maximumPreparedBytes: decoded + 64 * 1024,
            maximumWireBytes: decoded + 80 * 1024, maximumRequests: 3,
            objectDecodedBytesPerJob: decoded, clock: { 100 })
        let coordinator = PushCoordinator(source: probe, transport: probe, progress: probe, sourceId: sourceID,
            prepareSelection: { await captured.save($0) }, wakeBudget: budget)
        let lane = PushObjectLane(endpoint: "/objects", maxObjectBytes: 10_000_000, urlTtlSec: nil, streams: [.ppgWaveformSample])
        _ = await coordinator.pushObjects(.ppgWaveformSample, deviceId: "fixture", lane: lane)
        let saved = await captured.selection
        XCTAssertNotNil(saved, "already-reserved finite preparation was incorrectly denied by remaining quota")
        let calls = await probe.calls
        XCTAssertEqual(calls, ["progress.binaryCursor", "source.binary", "transport.intent"])
        XCTAssertFalse(budget.permitsPreparation)
        XCTAssertTrue(budget.permitsFinishingPreparation)
    }

}

private final class AdmissionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    var allowed: Bool { lock.withLock { value } }
    func deny() { lock.withLock { value = false } }
    func allow() { lock.withLock { value = true } }
}

private actor AdmissionProbe: PushSnapshotSource, PushProgressStore, PushTransport {
    private let revokeAfterMutableRead: @Sendable () -> Void
    private let appendCount: Int
    private let binary: [PushBinaryRow]
    private var paused = false
    private(set) var calls: [String] = []
    private(set) var lastAppendLimit = 0
    private(set) var lastPostedRows = 0
    init(appendCount: Int = 0, binary: [PushBinaryRow] = [], revokeAfterMutableRead: @escaping @Sendable () -> Void = {}) {
        self.appendCount = appendCount; self.binary = binary
        self.revokeAfterMutableRead = revokeAfterMutableRead
    }
    func knownDeviceIds(capabilities: PushCapabilities) -> [String] {
        calls.append("source.devices"); return ["synthetic-device"]
    }
    func appendRecordAt(table: PushAppendTable, deviceId: String, rowId: Int64) -> PushAppendRecord? {
        calls.append("source.appendRecord"); return nil
    }
    func appendRows(table: PushAppendTable, deviceId: String, afterRowId: Int64, limit: Int) -> [PushAppendRecord] {
        calls.append("source.append"); lastAppendLimit = limit
        return (0..<min(limit, appendCount)).map { index in
            .init(rowId: Int64(index + 1), key: ["ts": .int(Int64(1_800_000_000 + index))],
                data: ["soc": .int(50), "mv": .null, "charging": .null])
        }
    }
    func mutableRows(table: PushMutableTable, deviceId: String, window: PushWindow, limit: Int) -> [PushMutableRecord] {
        calls.append("source.mutable"); revokeAfterMutableRead(); return []
    }
    func binaryRecordAt(table: PushBinaryTable, deviceId: String, rowId: Int64) -> PushBinaryRow? {
        calls.append("source.binaryRecord"); return nil
    }
    func binaryRows(table: PushBinaryTable, deviceId: String, afterRowId: Int64, limit: Int) -> [PushBinaryRow] {
        calls.append("source.binary"); return Array(binary.prefix(limit))
    }
    func acknowledgeBinary(table: PushBinaryTable, deviceId: String, rows: [PushBinaryRow]) {
        calls.append("source.acknowledge")
    }
    func knownDeviceIds() -> Set<String> { calls.append("progress.devices"); return [] }
    func rememberDeviceId(_ deviceId: String) { calls.append("progress.remember") }
    func cursor(table: PushAppendTable, deviceId: String) -> PushCursor? {
        calls.append("progress.cursor"); return nil
    }
    func saveCursor(table: PushAppendTable, deviceId: String, cursor: PushCursor) { calls.append("progress.saveCursor") }
    func binaryCursor(table: PushBinaryTable, deviceId: String) -> PushCursor? {
        calls.append("progress.binaryCursor"); return nil
    }
    func saveBinaryCursor(table: PushBinaryTable, deviceId: String, cursor: PushCursor) {
        calls.append("progress.saveBinaryCursor")
    }
    func window(table: PushMutableTable, deviceId: String) -> PushWindowProgress? {
        calls.append("progress.window"); return nil
    }
    func saveWindow(table: PushMutableTable, deviceId: String, progress: PushWindowProgress) {
        calls.append("progress.saveWindow")
    }
    func post(_ batch: PushBatch) throws -> PushTransportResponse {
        calls.append("transport.post"); lastPostedRows = batch.recordCount
        throw PushProtocolException("unexpected transport")
    }
    func isPreparationPaused(_ lane: PushPreparationLane) -> Bool { paused }
    func pausePreparation(_ lane: PushPreparationLane) { paused = true; calls.append("transport.pause") }
    func createObjectIntent(_ manifest: PushObjectManifest, lane: PushObjectLane) throws -> PushObjectIntent {
        calls.append("transport.intent"); throw PushTransportException(PushFailure(code: .networkIO))
    }
    func postBinary(_ batch: PushBinaryBatch) throws -> PushTransportResponse {
        calls.append("transport.binary"); throw PushProtocolException("unexpected transport")
    }
}

private actor PreparedCapture {
    private(set) var selection: PushPreparedSelection?
    func save(_ value: PushPreparedSelection) { selection = value }
}
