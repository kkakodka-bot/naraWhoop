import Foundation
import XCTest
import WhoopProtocol
import WhoopStore
@testable import Strand

@MainActor
final class BackfillerCriticalPathTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 100
        func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) { lock.lock(); value += seconds; lock.unlock() }
    }

    private final class CursorStore: BackfillStoreWriting {
        var failCursor = false
        func insert(_ streams: Streams, deviceId: String) async throws
            -> (hr: Int, rr: Int, events: Int, battery: Int, spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
            (0, 0, 0, 0, 0, 0, 0, 0)
        }
        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {}
        func setCursor(_ name: String, _ value: Int) async throws {
            if failCursor { throw NSError(domain: "synthetic.cursor", code: 1) }
        }
        func cursor(_ name: String) async throws -> Int? { nil }
    }

    private func endFrame(trim: UInt32 = 7) -> [UInt8] {
        func le32(_ value: UInt32) -> [UInt8] {
            (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        }
        return frameFromPayload(le32(1_700_000_100) + [0, 0] + le32(0) + le32(trim) + le32(0),
                                type: 49, seq: 0, cmd: 2)
    }

    func testOrdinaryEvidenceAndCursorPrecedeAckButPresentationDoesNot() async throws {
        let store = try await WhoopStore.inMemory()
        let scope = DurableIngestScope.unassigned(deviceID: "synthetic")
        let record = frameFromPayload([0], type: 47, seq: 0, cmd: 0)
        let clock = Clock()
        var observed: [String] = []
        let backfiller = Backfiller(store: store, deviceId: "synthetic", ackTrim: { _, _ in
            do {
                let cursor = try await store.cursor("strap_trim:\(scope.key)")
                let archived = try await store.pendingSensorQuarantine(scope: scope)
                XCTAssertEqual(cursor, 7)
                XCTAssertEqual(archived.map { Array($0.frame) }, [record])
            } catch { XCTFail("Durable evidence must be readable before ACK: \(error)") }
            XCTAssertTrue(observed.isEmpty, "ordinary UI delivery must not delay ACK submission")
            clock.advance(2)
            CaptureJobTrace.ackSubmission?.markSubmitted()
            observed.append("ack")
            clock.advance(3) // Callback work after the transport submitted the write.
        }, chunkInfo: { events in
            XCTAssertEqual(observed, ["ack"])
            XCTAssertEqual(events.compactMap { event -> Int? in
                if case .quarantined(let count) = event { return count }
                return nil
            }, [1])
            observed.append("presentation")
            clock.advance(4)
        }, onQuarantined: { _ in
            XCTFail("The production batch owns ordinary quarantine presentation")
        }, monotonic: { clock.now() }, extract: { _, _, _, _, _ in
            Streams(hr: [HRSample(ts: 1_700_000_100, bpm: 60)])
        })
        backfiller.captureScope = scope
        backfiller.begin(family: .whoop4)
        await backfiller.ingest(record)
        await backfiller.ingest(endFrame())

        XCTAssertEqual(observed, ["ack", "presentation"])
        let sample = try XCTUnwrap(backfiller.sessionPhaseTimingSamples().last)
        XCTAssertEqual(sample.ackSubmissionMs, 2_000)
        XCTAssertEqual(sample.ackMs, 5_000)
        XCTAssertEqual(sample.postAckPresentationMs, 4_000)
        XCTAssertEqual(sample.totalMs, 9_000)
        let summary = try XCTUnwrap(Backfiller.sessionPhaseTimingSummaryLine([sample]))
        XCTAssertTrue(summary.contains("end-to-ACK-submit n=1 p50/p99=2000/2000ms"))
        XCTAssertTrue(summary.contains("excludes FIFO wait and ATT confirmation"))
    }

    func testOrdinaryLegacyQuarantineCallbackAlsoFollowsAck() async throws {
        let store = try await WhoopStore.inMemory()
        var observed: [String] = []
        let backfiller = Backfiller(store: store, deviceId: "synthetic",
            ackTrim: { _, _ in observed.append("ack") },
            onQuarantined: { count in
                XCTAssertEqual(count, 1)
                observed.append("quarantine-count")
            }, extract: { _, _, _, _, _ in Streams() })
        backfiller.begin(family: .whoop4)
        await backfiller.ingest(frameFromPayload([0], type: 47, seq: 0, cmd: 0))
        await backfiller.ingest(endFrame())
        XCTAssertEqual(observed, ["ack", "quarantine-count"])
    }

    func testCallbackWithoutTransportSubmissionHasNoSubmissionSample() async throws {
        var callbackRan = false
        let backfiller = Backfiller(store: CursorStore(), deviceId: "synthetic",
            ackTrim: { _, _ in callbackRan = true })
        backfiller.begin(family: .whoop4)
        await backfiller.ingest(endFrame())
        XCTAssertTrue(callbackRan)
        let sample = try XCTUnwrap(backfiller.sessionPhaseTimingSamples().last)
        XCTAssertNil(sample.ackSubmissionMs)
        XCTAssertFalse(Backfiller.sessionPhaseTimingSummaryLine([sample])!.contains("end-to-ACK-submit"))
    }

    func testCursorFailureCannotProduceSubmissionTiming() async throws {
        let store = CursorStore()
        store.failCursor = true
        let backfiller = Backfiller(store: store, deviceId: "synthetic",
            ackTrim: { _, _ in XCTFail("Failed durability must not reach ACK") })
        backfiller.begin(family: .whoop4)
        await backfiller.ingest(endFrame())
        XCTAssertTrue(backfiller.persistStalled)
        let sample = try XCTUnwrap(backfiller.sessionPhaseTimingSamples().last)
        XCTAssertNil(sample.ackSubmissionMs)
        XCTAssertEqual(sample.postAckPresentationMs, 0)
    }

    func testSubmissionTimestampIsRecordedExactlyOnce() {
        let clock = Clock()
        let start = clock.now()
        let submission = BackfillAckSubmission(now: { clock.now() })
        XCTAssertNil(submission.milliseconds(since: start))
        clock.advance(1)
        submission.markSubmitted()
        clock.advance(9)
        submission.markSubmitted()
        XCTAssertEqual(submission.milliseconds(since: start), 1_000)
    }
}
