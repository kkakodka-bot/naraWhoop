import XCTest
@testable import Strand

@MainActor
final class CloudUploadProgressTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testFractionIsUploadedOverTotalAndEmptyStoreReadsComplete() {
        let half = CloudUploadProgress.Backlog(pendingRows: 500, totalRows: 1_000, measuredAt: now)
        XCTAssertEqual(half.fraction, 0.5, accuracy: 0.0001)
        XCTAssertEqual(half.uploadedRows, 500)

        let empty = CloudUploadProgress.Backlog(pendingRows: 0, totalRows: 0, measuredAt: now)
        XCTAssertEqual(empty.fraction, 1)

        // A cursor past the last row (rows trimmed after upload) must not produce a negative count.
        let overshoot = CloudUploadProgress.Backlog(pendingRows: 10, totalRows: 4, measuredAt: now)
        XCTAssertEqual(overshoot.uploadedRows, 0)
        XCTAssertEqual(overshoot.fraction, 0)
    }

    func testRunningResetsPassCountersAndLaterStatesAccumulate() {
        var progress = CloudUploadProgress()
        progress.apply(state: .retrying, message: "Upload will retry.", batches: 3, records: 900, at: now)
        XCTAssertEqual(progress.phase, .retrying)
        XCTAssertEqual(progress.acceptedBatches, 3)
        XCTAssertEqual(progress.acceptedRecords, 900)
        XCTAssertEqual(progress.lastError, "Upload will retry.")
        XCTAssertTrue(progress.isActive)

        progress.apply(state: .running, message: nil, batches: 0, records: 0, at: now)
        XCTAssertEqual(progress.phase, .uploading)
        XCTAssertEqual(progress.acceptedBatches, 0)
        XCTAssertEqual(progress.acceptedRecords, 0)
        XCTAssertNil(progress.lastError)

        progress.apply(state: .continuing, message: nil, batches: 2, records: 100, at: now)
        progress.apply(state: .complete, message: nil, batches: 1, records: 50, at: now)
        XCTAssertEqual(progress.phase, .complete)
        XCTAssertEqual(progress.acceptedBatches, 3)
        XCTAssertEqual(progress.acceptedRecords, 150)
        XCTAssertEqual(progress.lastSuccessAt, now)
        XCTAssertFalse(progress.isActive)
    }

    func testEveryRunStateMapsToAPhase() {
        XCTAssertEqual(CloudUploadProgress.phase(for: .idle), .idle)
        XCTAssertEqual(CloudUploadProgress.phase(for: .queued), .queued)
        XCTAssertEqual(CloudUploadProgress.phase(for: .running), .uploading)
        XCTAssertEqual(CloudUploadProgress.phase(for: .continuing), .uploading)
        XCTAssertEqual(CloudUploadProgress.phase(for: .retrying), .retrying)
        XCTAssertEqual(CloudUploadProgress.phase(for: .complete), .complete)
        XCTAssertEqual(CloudUploadProgress.phase(for: .failed), .failed)
    }

    func testCenterSkipsRecountYoungerThanMinimumInterval() async {
        let center = CloudUploadProgressCenter()
        let calls = Counter()
        center.install {
            await calls.increment()
            return CloudUploadProgress.Backlog(pendingRows: 1, totalRows: 2, measuredAt: Date())
        }
        await Task.yield()
        await settle()
        let first = await calls.value
        XCTAssertEqual(first, 1)
        XCTAssertEqual(center.current.backlog?.pendingRows, 1)

        center.refresh(minimumInterval: 60)
        await settle()
        let afterSkip = await calls.value
        XCTAssertEqual(afterSkip, 1, "a fresh measurement must not be recounted")

        center.refresh(minimumInterval: 0)
        await settle()
        let afterForce = await calls.value
        XCTAssertEqual(afterForce, 2)
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    private actor Counter {
        var value = 0
        func increment() { value += 1 }
    }
}
