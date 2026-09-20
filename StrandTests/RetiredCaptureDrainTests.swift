import XCTest
@testable import Strand

@MainActor
final class RetiredCaptureDrainTests: XCTestCase {
    private final class Capture {
        var succeeds = false
        var calls = 0
        let account: String
        var recordedAccounts: [String] = []
        init(_ account: String) { self.account = account }
        func drain() -> Bool { calls += 1; recordedAccounts.append(account); return succeeds }
    }

    func testFailedDrainRetainsCapturedWriterUntilDurableSuccess() async {
        let retired = RetiredCaptureDrain(automaticRetry: false)
        var source: Capture? = Capture("old-account")
        weak var retained = source
        let id = UUID()
        retired.retain(id: id) { [captured = source!] in captured.drain() }
        source = nil
        XCTAssertNotNil(retained)
        await retired.retry()
        XCTAssertEqual(retired.pendingCount, 1)
        XCTAssertEqual(retained?.recordedAccounts, ["old-account"])
        // Another owner's success cannot consume or relabel the failed captured writer.
        let next = Capture("new-account"); next.succeeds = true
        retired.retain(id: UUID()) { next.drain() }
        await retired.retry()
        XCTAssertEqual(retired.pendingCount, 1)
        XCTAssertEqual(retained?.recordedAccounts, ["old-account", "old-account"])
        XCTAssertEqual(next.recordedAccounts, ["new-account"])
        retained?.succeeds = true
        await retired.retry()
        XCTAssertEqual(retired.pendingCount, 0)
        XCTAssertNil(retained, "release the old writer only after the successful drain")
    }

    func testSameGenerationCannotReplaceFailedCaptureAndPassesAreBoundedFairly() async {
        let retired = RetiredCaptureDrain(automaticRetry: false)
        let original = Capture("original"), replacement = Capture("must-not-replace")
        let id = UUID()
        retired.retain(id: id) { original.drain() }
        retired.retain(id: id) { replacement.drain() }
        let others = (0..<19).map { Capture("fixture-\($0)") }
        for value in others { retired.retain(id: UUID()) { value.drain() } }
        XCTAssertEqual(retired.pendingCount, 20)
        await retired.retry()
        XCTAssertEqual(original.calls + others.reduce(0) { $0 + $1.calls }, 16)
        XCTAssertEqual(replacement.calls, 0)
        await retired.retry()
        XCTAssertTrue(others.allSatisfy { $0.calls > 0 }, "rotating failures must not starve later owners")
        XCTAssertEqual(retired.pendingCount, 20)
        original.succeeds = true; others.forEach { $0.succeeds = true }
        await retired.retry(); await retired.retry()
        XCTAssertEqual(retired.pendingCount, 0)
    }

    func testConcurrentRetryJoinsOneDrainAndNewArrivalRemainsRetained() async {
        let retired = RetiredCaptureDrain(automaticRetry: false)
        let entered = expectation(description: "first drain entered")
        var release: CheckedContinuation<Bool, Never>?
        var calls = 0
        retired.retain(id: UUID()) {
            calls += 1; entered.fulfill()
            return await withCheckedContinuation { release = $0 }
        }
        let first = Task { await retired.retry() }
        await fulfillment(of: [entered], timeout: 2)
        let joined = Task { await retired.retry() }
        let later = Capture("later"); later.succeeds = true
        retired.retain(id: UUID()) { later.drain() }
        await Task.yield()
        XCTAssertEqual(calls, 1)
        release?.resume(returning: true)
        await first.value; await joined.value
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(retired.pendingCount, 1)
        XCTAssertEqual(later.calls, 0)
        await retired.retry()
        XCTAssertEqual(later.calls, 1)
        XCTAssertEqual(retired.pendingCount, 0)
    }
}
