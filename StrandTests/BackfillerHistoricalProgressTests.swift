import XCTest
import WhoopProtocol
import WhoopStore
@testable import Strand

@MainActor
final class BackfillerHistoricalProgressTests: XCTestCase {
    private func endFrame(trim: UInt32) -> [UInt8] {
        func le32(_ value: UInt32) -> [UInt8] {
            (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        }
        let payload = le32(1_700_000_100) + [0, 0] + le32(0) + le32(trim) + le32(0)
        return frameFromPayload(payload, type: 49, seq: 0, cmd: 2)
    }

    func testRawOnlyCommitUpdatesSessionProgressAndReplayRemainsEmpty() async throws {
        let store = try await WhoopStore.inMemory()
        let sourceTimestamp = 1_700_000_100
        let decoded = Streams(ppgWaveform: [
            PpgWaveformSample(ts: sourceTimestamp, samples: [1, -2], recordIndex: 10),
        ])
        var acknowledgements = 0
        var log: [String] = []
        let backfiller = Backfiller(
            store: store, deviceId: "test",
            ackTrim: { _, _ in acknowledgements += 1 },
            log: { log.append($0) },
            postOffloadJobKinds: [SyncJobKind.rescore.rawValue],
            extract: { _, _, _, _, _ in decoded })
        let record = frameFromPayload([0], type: 47, seq: 0, cmd: 0)

        backfiller.begin(family: .whoop4)
        await backfiller.ingest(record)
        await backfiller.ingest(endFrame(trim: .max))
        XCTAssertEqual(backfiller.sessionRowsPersisted, 1)
        XCTAssertEqual(backfiller.sessionNights, 1)
        XCTAssertEqual(acknowledgements, 1)
        XCTAssertFalse(log.contains { $0.contains("no banked history to offload") })
        let jobs = try await store.owedJobs()
        XCTAssertTrue(jobs.isEmpty, "raw-only progress must not request scoring")

        backfiller.begin(family: .whoop4)
        await backfiller.ingest(record)
        await backfiller.ingest(endFrame(trim: 2))
        XCTAssertEqual(backfiller.sessionRowsPersisted, 0)
        XCTAssertEqual(backfiller.sessionNights, 0)
        XCTAssertEqual(acknowledgements, 2, "durable duplicate replay may still be acknowledged")
    }

    func testAdditionalSensorProgressOverridesEmptyLegacyTuple() {
        let tally = Backfiller.chunkTally(
            counts: (0, 0, 0, 0, 0, 0, 0, 0), timestamps: [1_700_000_100],
            insertedHistoricalSensorRows: 3)
        XCTAssertEqual(tally.rows, 3)
        XCTAssertEqual(tally.motion, 0)
        XCTAssertEqual(tally.nights.count, 1)
    }
}
