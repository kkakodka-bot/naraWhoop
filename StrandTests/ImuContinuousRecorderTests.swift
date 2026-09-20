import XCTest
@testable import Strand
import WhoopProtocol
import WhoopStore

/// State-machine tests for the Developer Options "Record 100 Hz IMU locally" producer owner.
/// Every test drives the recorder through its injected transport/clock seams — no CoreBluetooth,
/// no strap — over a real temp-dir `ImuSessionFileStore`, so the store round-trip (append → flush
/// → coverage) is exercised exactly as in production.
@MainActor
final class ImuContinuousRecorderTests: XCTestCase {

    /// Mutable script for the recorder's transport seams.
    private final class Harness {
        var nowMs: Int64 = 1_800_000_000_000
        var starts = 0, stops = 0
        var linkReady = true
        var deviceId = "strap"
        var otherProducer = false
        var freeDisk: Int64? = nil
        var logs: [String] = []
        var now: Date { Date(timeIntervalSince1970: TimeInterval(nowMs) / 1_000) }
        var nowSec: Int64 { nowMs / 1_000 }
    }

    private var harness: Harness!
    private var directory: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ImuSessionFileStore!
    private let captureScope = DurableIngestScope(
        environment: "https://fixture.invalid", accountID: "owner-a", deviceID: "strap")

    override func setUp() async throws {
        try await super.setUp()
        harness = Harness()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "imu-recorder-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = ImuSessionFileStore(directory: directory, defaultsKey: "windows", defaults: defaults,
                                    captureScope: captureScope)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: self.directory)
            if let suiteName = self.suiteName { self.defaults?.removePersistentDomain(forName: suiteName) }
        }
    }

    private func makeRecorder() -> ImuContinuousRecorder {
        let harness = self.harness!
        let recorder = ImuContinuousRecorder(store: store, defaults: defaults,
                                             now: { harness.now }, tickInterval: nil)
        recorder.transport = ImuContinuousRecorder.Transport(
            sendStart: { harness.starts += 1 },
            sendStop: { harness.stops += 1 },
            linkReady: { harness.linkReady },
            activeDeviceId: { harness.deviceId },
            otherProducerActive: { harness.otherProducer },
            freeDiskBytes: { harness.freeDisk },
            log: { harness.logs.append($0) })
        return recorder
    }

    /// CRC-valid 1244-byte 5/MG IMU buffer: u32 LE strap ts @15, sample counts 100 @24/@630.
    /// `seed` varies the accel payload so same-ts frames can differ (conflict detection).
    private func imuFrame(ts: Int64, seed: UInt8 = 0) -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: Whoop5RawImu.bufferLength)
        frame[0] = 0xAA
        frame[1] = 0x01
        let declaredLength = frame.count - 8
        frame[2] = UInt8(declaredLength & 0xFF)
        frame[3] = UInt8((declaredLength >> 8) & 0xFF)
        frame[4] = 0x01
        frame[8] = 43
        frame[15] = UInt8(ts & 0xff); frame[16] = UInt8((ts >> 8) & 0xff)
        frame[17] = UInt8((ts >> 16) & 0xff); frame[18] = UInt8((ts >> 24) & 0xff)
        frame[24] = 100; frame[630] = 100
        if seed != 0 { frame[28] = seed }
        return stampWhoop5Crc(frame)
    }

    private func stampWhoop5Crc(_ frame: [UInt8]) -> [UInt8] {
        var frame = frame
        let headerCRC = crc16Modbus(frame, 0, 6)
        frame[6] = UInt8(headerCRC & 0xFF)
        frame[7] = UInt8(headerCRC >> 8)
        let payloadEnd = frame.count - 4
        let payloadCRC = crc32(frame, 8, payloadEnd)
        frame[payloadEnd] = UInt8(payloadCRC & 0xFF)
        frame[payloadEnd + 1] = UInt8((payloadCRC >> 8) & 0xFF)
        frame[payloadEnd + 2] = UInt8((payloadCRC >> 16) & 0xFF)
        frame[payloadEnd + 3] = UInt8((payloadCRC >> 24) & 0xFF)
        return frame
    }

    /// A high-entropy variant so zlib cannot compress a block below the retention test's cap.
    private func noisyFrame(ts: Int64) -> [UInt8] {
        var frame = imuFrame(ts: ts)
        var state = UInt64(bitPattern: ts) &* 2_862_933_555_777_941_757 &+ 1
        for index in 28..<(frame.count - 4) {
            if index == 630 || index == 631 { continue }
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            frame[index] = UInt8(truncatingIfNeeded: state >> 33)
        }
        frame[630] = 100; frame[631] = 0   // keep the gyro sample-count gate valid
        return stampWhoop5Crc(frame)
    }

    private func advance(seconds: Int64) { harness.nowMs += seconds * 1_000 }

    // MARK: - Acceptance 1: On records verified packets; an ack alone never counts

    func testOnArmsWhenBondedAndRecordsOnlyVerifiedFrames() {
        let recorder = makeRecorder()
        harness.linkReady = false
        recorder.setEnabled(true)
        XCTAssertEqual(recorder.status.phase, .waitingForConnection)
        XCTAssertEqual(harness.starts, 0, "no link — the hardware start must not be claimed sent")

        harness.linkReady = true
        recorder.handleBonded5MG()
        XCTAssertEqual(harness.starts, 1)
        XCTAssertEqual(recorder.status.phase, .startSent)

        // The start command being SENT is not recording: past the grace period with no valid
        // packet, the surface says so.
        advance(seconds: 11)
        recorder.tick()
        XCTAssertEqual(recorder.status.phase, .startSent)
        XCTAssertTrue(recorder.status.noPacketsObserved)

        // A non-IMU frame (e.g. a command ack) never counts as a packet.
        recorder.ingestFrame([UInt8](repeating: 1, count: 40), isOffload: false,
                             receivedAtMs: harness.nowMs)
        XCTAssertEqual(recorder.status.phase, .startSent)

        // The first VERIFIED frame flips to recording and lands in the store under its strap ts.
        recorder.ingestFrame(imuFrame(ts: harness.nowSec), isOffload: false,
                             receivedAtMs: harness.nowMs)
        XCTAssertEqual(recorder.status.phase, .recording)
        XCTAssertFalse(recorder.status.noPacketsObserved)
        recorder.refreshCoverage()
        XCTAssertEqual(recorder.coverage.coveredSeconds, 1)
        // The 11 silent seconds between arm and the first packet are a REAL gap — the strap never
        // sent them — and honest coverage says so instead of claiming them.
        XCTAssertEqual(recorder.coverage.gapCount, 1)
    }

    func testStartIsResentOncePerRetryIntervalWhileSilent() {
        let recorder = makeRecorder()
        recorder.setEnabled(true)   // link already up: the switch itself arms
        XCTAssertEqual(harness.starts, 1)
        advance(seconds: 11)
        recorder.tick()
        XCTAssertTrue(recorder.status.noPacketsObserved)
        advance(seconds: 30)
        recorder.tick()
        XCTAssertEqual(harness.starts, 2, "a lost start write gets one bounded retry per interval")
    }

    func testRecordingStallRearmsOnReadyLink() {
        let recorder = makeRecorder()
        recorder.setEnabled(true)
        recorder.ingestFrame(imuFrame(ts: harness.nowSec), isOffload: false,
                             receivedAtMs: harness.nowMs)
        XCTAssertEqual(recorder.status.phase, .recording)
        advance(seconds: 46)
        recorder.tick()
        XCTAssertEqual(recorder.status.phase, .startSent)
        XCTAssertEqual(harness.starts, 2, "a stalled stream re-arms instead of silently gapping")
    }

    func testResourceConstraintFlushesRetainsBytesAndResumesWithoutChangingIntent() throws {
        let recorder = makeRecorder()
        recorder.setEnabled(true)
        let ts = harness.nowSec
        recorder.ingestFrame(imuFrame(ts: ts), isOffload: false, receivedAtMs: harness.nowMs)
        recorder.setResourceConstrained(true)
        let window = try XCTUnwrap(store.registeredWindows().first)
        let saved = store.exportSegments(window.id, from: Int(ts), to: Int(ts)).map(\.data)
        XCTAssertFalse(saved.isEmpty, "the in-memory block was flushed before pausing")
        XCTAssertTrue(defaults.bool(forKey: ImuContinuousRecorder.enabledKey))
        XCTAssertTrue(recorder.status.enabled)
        XCTAssertTrue(recorder.status.resourceConstrained)
        XCTAssertEqual(harness.stops, 1)

        advance(seconds: 1)
        recorder.ingestFrame(imuFrame(ts: harness.nowSec), isOffload: false, receivedAtMs: harness.nowMs)
        recorder.tick()
        recorder.setResourceConstrained(true)
        XCTAssertEqual(recorder.status.phase, .waitingForConnection,
                       "a late packet must not claim recording while capture is paused")
        XCTAssertEqual(harness.starts, 1)
        XCTAssertEqual(harness.stops, 1, "duplicate notifications and late packets cannot storm stop")
        XCTAssertEqual(recorder.status.droppedForResourceConstraint, 1)
        XCTAssertEqual(recorder.status.droppedForLowDisk, 0)
        XCTAssertEqual(store.exportSegments(window.id, from: Int(ts), to: Int(ts)).map(\.data), saved)

        advance(seconds: 30)
        recorder.ingestFrame(imuFrame(ts: harness.nowSec), isOffload: false, receivedAtMs: harness.nowMs)
        XCTAssertEqual(harness.stops, 2, "continued packets get a bounded stop retry")
        recorder.setResourceConstrained(false)
        recorder.setResourceConstrained(false)
        XCTAssertEqual(harness.starts, 2, "lifting constraints re-arms exactly once")
        XCTAssertEqual(recorder.status.phase, .startSent)
        XCTAssertFalse(recorder.status.resourceConstrained)
        recorder.ingestFrame(imuFrame(ts: harness.nowSec), isOffload: false, receivedAtMs: harness.nowMs)
        recorder.refreshCoverage()
        XCTAssertEqual(recorder.coverage.coveredSeconds, 2)
        XCTAssertTrue(defaults.bool(forKey: ImuContinuousRecorder.enabledKey))
    }

    func testResourceConstraintAppliedBeforeArmingSurvivesReconnectAndDefersResumeUntilBonded() {
        let recorder = makeRecorder()
        recorder.setResourceConstrained(true)
        recorder.setEnabled(true)
        XCTAssertEqual(harness.starts, 0)
        XCTAssertEqual(harness.stops, 1)
        harness.linkReady = false
        recorder.handleDisconnect()
        advance(seconds: 31)
        recorder.tick()
        harness.linkReady = true
        recorder.handleBonded5MG()
        XCTAssertEqual(harness.stops, 2, "a constrained reconnect must stop, never start")
        XCTAssertEqual(harness.starts, 0)
        harness.linkReady = false
        recorder.handleDisconnect()
        recorder.setResourceConstrained(false)
        XCTAssertEqual(harness.starts, 0)
        harness.linkReady = true
        recorder.handleBonded5MG()
        XCTAssertEqual(harness.starts, 1)
    }

    func testResourcePauseDoesNotStopAnotherProducerAndUserOffWinsOverResume() {
        let recorder = makeRecorder()
        recorder.setEnabled(true)
        harness.otherProducer = true
        recorder.setResourceConstrained(true)
        advance(seconds: 31)
        recorder.tick()
        XCTAssertEqual(harness.stops, 0)
        harness.otherProducer = false
        recorder.tick()
        XCTAssertEqual(harness.stops, 1, "stop deferred until this recorder can own the producer")
        recorder.setEnabled(false)
        recorder.setResourceConstrained(false)
        recorder.tick()
        XCTAssertEqual(harness.starts, 1)
        XCTAssertFalse(recorder.status.enabled)
        XCTAssertFalse(defaults.bool(forKey: ImuContinuousRecorder.enabledKey))
    }

    func testResourcePolicyAndQueuedCallbacksCannotReviveShutdownRecorder() {
        let recorder = makeRecorder()
        recorder.setEnabled(true)
        recorder.setResourceConstrained(true)
        recorder.shutdownForAccountChange()
        recorder.setResourceConstrained(false)
        recorder.setEnabled(true)
        recorder.handleBonded5MG()
        recorder.ingestFrame(imuFrame(ts: harness.nowSec), isOffload: false, receivedAtMs: harness.nowMs)
        recorder.tick()
        XCTAssertEqual(harness.starts, 1)
        XCTAssertFalse(recorder.status.enabled)
        XCTAssertEqual(recorder.status.phase, .off)
        XCTAssertTrue(defaults.bool(forKey: ImuContinuousRecorder.enabledKey),
                      "runtime shutdown must not change the next runtime's saved choice")
        recorder.refreshCoverage()
        XCTAssertEqual(recorder.coverage.coveredSeconds, 0)
    }

    // MARK: - Acceptance 2 + 4: Off stops immediately, sends the hardware stop unconditionally

    func testOffStopsWritesAndSendsHardwareStopEvenWithRetentionEnabled() {
        defaults.set(true, forKey: "enableRawCapture")   // explicit opt-in for this retention test
        let recorder = makeRecorder()
        recorder.setEnabled(true)
        recorder.ingestFrame(imuFrame(ts: harness.nowSec), isOffload: false,
                             receivedAtMs: harness.nowMs)
        XCTAssertEqual(recorder.status.phase, .recording)

        recorder.setEnabled(false)
        XCTAssertEqual(harness.stops, 1,
                       "the hardware stop is sent even while enableRawCapture stays on")
        XCTAssertEqual(recorder.status.phase, .stopSent)

        // Local writes cease immediately: a live frame from the next second is not recorded.
        advance(seconds: 1)
        recorder.ingestFrame(imuFrame(ts: harness.nowSec), isOffload: false,
                             receivedAtMs: harness.nowMs)
        recorder.refreshCoverage()
        XCTAssertEqual(recorder.coverage.coveredSeconds, 1)

        // Packets ceasing for the silence window ends the stop handshake.
        advance(seconds: 6)
        recorder.tick()
        XCTAssertEqual(recorder.status.phase, .off)
    }

    func testOffWhileDisconnectedPersistsStopPendingAcrossRelaunchAndNeverRearms() {
        let recorder = makeRecorder()
        recorder.setEnabled(true)
        harness.linkReady = false
        recorder.handleDisconnect()
        recorder.setEnabled(false)
        XCTAssertEqual(harness.stops, 0, "no link — the stop cannot have been sent")
        XCTAssertEqual(recorder.status.phase, .offStopPending)
        XCTAssertTrue(recorder.status.hardwareStopPending)

        // Relaunch: the owed stop survives; the recorder comes up still owing it.
        let relaunched = makeRecorder()
        XCTAssertEqual(relaunched.status.phase, .offStopPending)
        XCTAssertFalse(relaunched.status.enabled)

        // Reconnect: the owed stop goes out BEFORE anything else, and no start is ever sent.
        harness.linkReady = true
        relaunched.handleBonded5MG()
        XCTAssertEqual(harness.stops, 1)
        XCTAssertEqual(harness.starts, 1, "only the original arm — Off never re-arms")
        XCTAssertEqual(relaunched.status.phase, .stopSent)
        advance(seconds: 6)
        relaunched.tick()
        XCTAssertEqual(relaunched.status.phase, .off)
    }

    func testOnPersistsAcrossRelaunchAndRearmsOnBond() {
        let recorder = makeRecorder()
        recorder.setEnabled(true)
        recorder.ingestFrame(imuFrame(ts: harness.nowSec), isOffload: false,
                             receivedAtMs: harness.nowMs)

        // Relaunch with the same defaults + store: still On, same open window, waiting for a link.
        let relaunched = makeRecorder()
        XCTAssertTrue(relaunched.status.enabled)
        XCTAssertEqual(relaunched.status.phase, .waitingForConnection)
        XCTAssertNotNil(relaunched.status.recordingSince)

        relaunched.handleBonded5MG()
        XCTAssertEqual(harness.starts, 2, "re-armed on the new link")
        advance(seconds: 1)
        relaunched.ingestFrame(imuFrame(ts: harness.nowSec), isOffload: false,
                               receivedAtMs: harness.nowMs)
        relaunched.refreshCoverage()
        XCTAssertEqual(relaunched.coverage.coveredSeconds, 2,
                       "the relaunched recorder keeps writing the SAME window")
    }

    // MARK: - Acceptance 3: disconnect gap is real; verified history repairs; no duplicates

    func testDisconnectGapIsReportedAndLateHistoryRepairsWithoutDuplicates() {
        let recorder = makeRecorder()
        recorder.setEnabled(true)
        recorder.ingestFrame(imuFrame(ts: harness.nowSec), isOffload: false,
                             receivedAtMs: harness.nowMs)
        advance(seconds: 1)
        recorder.ingestFrame(imuFrame(ts: harness.nowSec), isOffload: false,
                             receivedAtMs: harness.nowMs)

        // Link down for 5 seconds: those seconds stay absent.
        harness.linkReady = false
        recorder.handleDisconnect()
        XCTAssertEqual(recorder.status.phase, .waitingForConnection)
        advance(seconds: 5)
        harness.linkReady = true
        recorder.handleBonded5MG()
        recorder.ingestFrame(imuFrame(ts: harness.nowSec), isOffload: false,
                             receivedAtMs: harness.nowMs)

        recorder.refreshCoverage()
        XCTAssertEqual(recorder.coverage.coveredSeconds, 3)
        XCTAssertEqual(recorder.coverage.gapCount, 1, "the 4-second disconnect shows as one gap")

        // The strap retained part of the gap and offloads it later: verified history repairs it.
        let repairTs = harness.nowSec - 3
        recorder.ingestFrame(imuFrame(ts: repairTs), isOffload: true, receivedAtMs: harness.nowMs)
        recorder.refreshCoverage()
        XCTAssertEqual(recorder.coverage.coveredSeconds, 4)

        // The same second arriving twice (live + replay) is written once and counted.
        recorder.ingestFrame(imuFrame(ts: repairTs), isOffload: true, receivedAtMs: harness.nowMs)
        recorder.refreshCoverage()
        XCTAssertEqual(recorder.coverage.coveredSeconds, 4, "no duplicate seconds")
        XCTAssertEqual(recorder.status.duplicatesSkipped, 1)
    }

    func testSameSecondDifferentBytesSurfacesAConflictAndKeepsFirstWrite() throws {
        let recorder = makeRecorder()
        recorder.setEnabled(true)
        let ts = harness.nowSec
        recorder.ingestFrame(imuFrame(ts: ts, seed: 1), isOffload: false, receivedAtMs: harness.nowMs)
        recorder.ingestFrame(imuFrame(ts: ts, seed: 2), isOffload: true, receivedAtMs: harness.nowMs)
        XCTAssertEqual(recorder.status.conflicts, 1)
        XCTAssertTrue(harness.logs.contains { $0.contains("CONFLICT") })
        let segments = store.exportSegments(
            try XCTUnwrap(store.registeredWindows().first).id,
            from: Int(ts) - 1, to: Int(ts) + 1)
        let exported = segments.flatMap { [$0.startTs, $0.endTs] }
        XCTAssertEqual(exported, [Int(ts), Int(ts)], "one stored second, first write wins")
    }

    // MARK: - Producer ownership vs the bounded session

    func testStopSentStandsDownWhenBoundedSessionOwnsTheProducer() {
        let recorder = makeRecorder()
        recorder.setEnabled(true)
        recorder.ingestFrame(imuFrame(ts: harness.nowSec), isOffload: false,
                             receivedAtMs: harness.nowMs)
        recorder.setEnabled(false)
        XCTAssertEqual(recorder.status.phase, .stopSent)
        harness.otherProducer = true
        // Packets keep arriving (the bounded session's): no stop re-send, no stray alarm.
        advance(seconds: 1)
        recorder.ingestFrame(imuFrame(ts: harness.nowSec), isOffload: false,
                             receivedAtMs: harness.nowMs)
        advance(seconds: 31)
        recorder.tick()
        XCTAssertEqual(recorder.status.phase, .off)
        XCTAssertEqual(harness.stops, 1, "the recorder never stops another producer's stream")
        XCTAssertFalse(recorder.status.strayPacketsWhileOff)
    }

    func testPacketsPersistingAfterStopResendStopBounded() {
        let recorder = makeRecorder()
        recorder.setEnabled(true)
        recorder.ingestFrame(imuFrame(ts: harness.nowSec), isOffload: false,
                             receivedAtMs: harness.nowMs)
        recorder.setEnabled(false)
        advance(seconds: 1)
        recorder.ingestFrame(imuFrame(ts: harness.nowSec), isOffload: false,
                             receivedAtMs: harness.nowMs)
        // 31 s later the strap is STILL streaming (a packet arrives right before the tick): the
        // stop is re-sent on the bounded cadence and the phase never claims "stopped".
        advance(seconds: 30)
        recorder.ingestFrame(imuFrame(ts: harness.nowSec), isOffload: false,
                             receivedAtMs: harness.nowMs)
        recorder.tick()
        XCTAssertEqual(harness.stops, 2, "a strap still streaming after stop gets a bounded re-send")
        XCTAssertEqual(recorder.status.phase, .stopSent, "never claims stopped while packets flow")
    }

    // MARK: - Storage policy

    func testRetentionEvictsOldestSegmentAndLateHistoryCannotRegrowIt() throws {
        let recorder = makeRecorder()
        recorder.setEnabled(true)
        recorder.setRetentionCap(40_000)   // tiny, so two ~36 KB incompressible blocks exceed it

        // Fill one 30-second block (auto-flushes at 30 records) in the current segment.
        let firstBucketStart = harness.nowSec
        for offset in 0..<Int64(30) {
            recorder.ingestFrame(noisyFrame(ts: firstBucketStart + offset), isOffload: false,
                                 receivedAtMs: harness.nowMs + offset * 1_000)
        }
        // Roll into the next half-hour segment and flush a block there too.
        advance(seconds: 1_800)
        for offset in 0..<Int64(30) {
            recorder.ingestFrame(noisyFrame(ts: harness.nowSec + offset), isOffload: false,
                                 receivedAtMs: harness.nowMs + offset * 1_000)
        }
        XCTAssertEqual(store.segmentInventory().count, 2)

        let oldest = try XCTUnwrap(store.segmentInventory().min { $0.bucket < $1.bucket })
        let identity = try XCTUnwrap(store.segmentResourceIdentity(id: oldest.id, bucket: oldest.bucket))
        try store.recordSegmentReceipt(RawDurabilityReceipt(scope: identity.scope, lane: identity.lane,
            resourceKey: identity.resourceKey, contentSHA256: identity.contentSHA256,
            objectKey: "fixture/verified-object", receiptID: "fixture/verified-manifest",
            verifiedAt: 1, retainUntil: 1), id: oldest.id, bucket: oldest.bucket)

        recorder.tick()   // tick 1 — retention runs on tick 15; drive it directly below
        for _ in 0..<14 { recorder.tick() }
        XCTAssertEqual(store.segmentInventory().count, 1,
                       "the oldest segment is evicted once over the cap")
        XCTAssertEqual(recorder.status.evictedSegments, 1)
        XCTAssertEqual(store.segmentInventory().first?.bucket,
                       ImuContinuousRecorder.bucketStart(harness.nowSec),
                       "the live segment is never evicted")

        // Late history for an evicted second is refused — evicted stays evicted.
        recorder.ingestFrame(noisyFrame(ts: firstBucketStart), isOffload: true,
                             receivedAtMs: harness.nowMs)
        XCTAssertEqual(recorder.status.droppedAfterEviction, 1)
        XCTAssertEqual(store.segmentInventory().count, 1)
    }

    func testRetentionWithoutReceiptPreservesOldSegmentsAndPausesNewCapture() {
        let recorder = makeRecorder()
        recorder.setEnabled(true)
        recorder.setRetentionCap(40_000)
        for _ in 0..<2 {
            for offset in 0..<Int64(30) {
                recorder.ingestFrame(noisyFrame(ts: harness.nowSec + offset), isOffload: false,
                                     receivedAtMs: harness.nowMs + offset * 1_000)
            }
            advance(seconds: 1_800)
        }
        let before = store.totalBytes()
        for _ in 0..<15 { recorder.tick() }
        XCTAssertEqual(store.segmentInventory().count, 2)
        XCTAssertEqual(store.totalBytes(), before)
        XCTAssertEqual(recorder.status.evictedSegments, 0)
        XCTAssertTrue(recorder.status.lowDiskPaused)
        recorder.ingestFrame(noisyFrame(ts: harness.nowSec), isOffload: false, receivedAtMs: harness.nowMs)
        XCTAssertEqual(recorder.status.droppedForLowDisk, 1)
        XCTAssertEqual(store.totalBytes(), before)
    }

    func testLowDiskPausesWritesAndSurfacesIt() {
        let recorder = makeRecorder()
        recorder.setEnabled(true)
        harness.freeDisk = 1
        for _ in 0..<15 { recorder.tick() }   // reach the disk-check tick
        XCTAssertTrue(recorder.status.lowDiskPaused)
        recorder.ingestFrame(imuFrame(ts: harness.nowSec), isOffload: false,
                             receivedAtMs: harness.nowMs)
        XCTAssertEqual(recorder.status.droppedForLowDisk, 1)
        recorder.refreshCoverage()
        XCTAssertEqual(recorder.coverage.coveredSeconds, 0, "paused writes leave real gaps")

        harness.freeDisk = Int64.max
        for _ in 0..<15 { recorder.tick() }
        XCTAssertFalse(recorder.status.lowDiskPaused)
        recorder.ingestFrame(imuFrame(ts: harness.nowSec), isOffload: false,
                             receivedAtMs: harness.nowMs)
        XCTAssertEqual(recorder.status.droppedForLowDisk, 1)
    }

    func testDeleteAllRefusedWhileEnabledAndClearsEverythingWhenOff() {
        let recorder = makeRecorder()
        recorder.setEnabled(true)
        recorder.ingestFrame(imuFrame(ts: harness.nowSec), isOffload: false,
                             receivedAtMs: harness.nowMs)
        XCTAssertFalse(recorder.deleteAll(), "delete is refused while the switch is On")

        recorder.setEnabled(false)
        advance(seconds: 6)
        recorder.tick()
        XCTAssertTrue(recorder.deleteAll())
        XCTAssertTrue(store.registeredWindows().isEmpty)
        XCTAssertEqual(store.totalBytes(), 0)
        recorder.refreshCoverage()
        XCTAssertEqual(recorder.coverage.coveredSeconds, 0)
    }

    // MARK: - Export

    func testExportContainsSegmentsCoverageAndHonestMeta() throws {
        let recorder = makeRecorder()
        recorder.setEnabled(true)
        recorder.ingestFrame(imuFrame(ts: harness.nowSec), isOffload: false,
                             receivedAtMs: harness.nowMs)
        advance(seconds: 2)
        recorder.ingestFrame(imuFrame(ts: harness.nowSec), isOffload: false,
                             receivedAtMs: harness.nowMs)

        let entries = recorder.exportEntries()
        let names = entries.map(\.name)
        XCTAssertTrue(names.contains("meta.json"))
        XCTAssertTrue(names.contains("imu-coverage.json"))
        XCTAssertTrue(names.contains { $0.hasPrefix("imu/") && $0.hasSuffix(".imus") })

        let meta = try XCTUnwrap(entries.first { $0.name == "meta.json" })
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: meta.data) as? [String: Any])
        XCTAssertEqual(object["sample_rate_hz"] as? Int, 100)
        XCTAssertEqual(object["local_only"] as? Bool, true)
        let windows = try XCTUnwrap(object["windows"] as? [[String: Any]])
        XCTAssertEqual(windows.first?["covered_seconds"] as? Int, 2)
        XCTAssertEqual(windows.first?["gap_count"] as? Int, 1,
                       "the skipped second is exported as a real gap, not smoothed over")

        let coverage = try XCTUnwrap(entries.first { $0.name == "imu-coverage.json" })
        let coverageObject = try XCTUnwrap(JSONSerialization.jsonObject(with: coverage.data) as? [String: Any])
        let coverageWindows = try XCTUnwrap(coverageObject["windows"] as? [[String: Any]])
        let ranges = try XCTUnwrap(coverageWindows.first?["missing_ranges"] as? [[Int64]])
        XCTAssertEqual(ranges, [[harness.nowSec - 1, harness.nowSec - 1]])
    }
}
