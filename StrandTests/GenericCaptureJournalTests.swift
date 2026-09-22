import XCTest
import WhoopProtocol
import WhoopStore
#if !GENERIC_CAPTURE_NATIVE_TESTS
@testable import Strand
#endif

@MainActor
final class GenericCaptureJournalTests: XCTestCase {
    private enum Failure: Error { case unavailable }
    private let deviceID = "synthetic-standard-hr"
    private let start = 1_750_000_000
    // Two equal RR values must remain two beats, including after retrying an ambiguous receipt.
    private let measurement: [UInt8] = [0x16, 72, 0x00, 0x04, 0x00, 0x04]

    private func source(_ journal: GenericCaptureJournal) -> StandardHRSource {
        StandardHRSource(live: LiveState(), deviceId: deviceID, persist: { _ in
            XCTFail("production capture must use checked admission")
        }, admit: { [deviceID] in journal.admit($0, deviceID: deviceID) }, startCentral: false)
    }

    private func stopAndRetain(_ source: StandardHRSource, in journal: GenericCaptureJournal) {
        source.stop()
        if source.pendingCaptureCount > 0 {
            journal.retainFinalBuffer(owner: source) { [source] in source.retryBufferedPersistence() }
        }
    }

    private func samples(_ store: WhoopStore) async throws -> [HRSample] {
        try await store.hrSamples(deviceId: deviceID, from: start, to: start + 100, limit: 100)
    }

    func testActualStopFlushesSubthresholdBufferAndRejectsLateNotification() async throws {
        let store = try await WhoopStore.inMemory()
        let journal = GenericCaptureJournal(store: store)
        let source = source(journal)
        for index in 0..<3 { XCTAssertTrue(source.ingestHeartRateMeasurement(measurement, at: start + index)) }
        XCTAssertEqual(source.pendingCaptureCount, 3)
        XCTAssertEqual(journal.pendingBatchCount, 0)
        source.stop(); source.stop()
        journal.sealCapture()
        XCTAssertFalse(source.ingestHeartRateMeasurement(measurement, at: start + 3))
        let drained = await journal.drain()
        XCTAssertTrue(drained)
        let rows = try await samples(store)
        let rr = try await store.rrIntervals(deviceId: deviceID, from: start, to: start + 100, limit: 100)
        XCTAssertEqual(rows.map(\.ts), (0..<3).map { start + $0 })
        XCTAssertEqual(rows.map(\.bpm), [72, 72, 72])
        XCTAssertEqual(rr.count, 6)
        XCTAssertTrue(rr.allSatisfy { $0.rrMs == 1_000 })
        XCTAssertEqual(source.pendingCaptureCount, 0)
    }

    func testStopAndInFlightFailureRetainOldWriterAcrossRepositoryRevocation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("generic-capture-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var openedStores: [WhoopStore] = []
        defer {
            var allClosed = true
            for store in openedStores.reversed() {
                do { try store.registryWriter.close() }
                catch {
                    allClosed = false
                    XCTFail("Store close failed; retained fixture at \(directory.path): \(error)")
                }
            }
            if allClosed {
                do { try FileManager.default.removeItem(at: directory) }
                catch { XCTFail("Fixture cleanup failed; retained directory at \(directory.path): \(error)") }
            }
        }
        let oldPath = directory.appendingPathComponent("old.sqlite").path
        let oldStore = try await WhoopStore(path: oldPath)
        openedStores.append(oldStore)
        let newStore = try await WhoopStore(path: directory.appendingPathComponent("new.sqlite").path)
        openedStores.append(newStore)
        let project = "https://synthetic-capture.invalid"
        let oldOwner = "11111111-1111-4111-8111-111111111111"
        try await oldStore.bindAccountOwner(projectURL: project, userID: oldOwner)
        try await newStore.bindAccountOwner(projectURL: project, userID: "22222222-2222-4222-8222-222222222222")
        // This models Repository's separate, revocable presentation connection to the same file.
        let presentationStore = try await WhoopStore(path: oldPath)
        openedStores.append(presentationStore)
        let fence = StoreWriteFence()
        try await presentationStore.fenceWrites(untilRevoked: fence)

        let entered = expectation(description: "old writer is in flight")
        var release: CheckedContinuation<Void, Never>?
        var calls = 0
        var shouldFail = true
        let journal = GenericCaptureJournal { [oldStore] streams, id in
            calls += 1
            if calls == 1 {
                entered.fulfill()
                await withCheckedContinuation { release = $0 }
            }
            if shouldFail { throw Failure.unavailable }
            _ = try await oldStore.insert(streams, deviceId: id)
        }
        var source: StandardHRSource? = source(journal)
        for index in 0..<30 { XCTAssertTrue(source!.ingestHeartRateMeasurement(measurement, at: start + index)) }
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertTrue(source!.ingestHeartRateMeasurement(measurement, at: start + 30))
        stopAndRetain(source!, in: journal)
        journal.sealCapture()
        XCTAssertFalse(source!.ingestHeartRateMeasurement(measurement, at: start + 31))
        source = nil
        fence.invalidate()
        let retired = RetiredCaptureDrain(automaticRetry: false)
        retired.retain(id: UUID()) { [journal] in await journal.drain() }
        var completed = false
        let drain = Task { await retired.retry(); completed = true }
        let joined = Task { await journal.drain() }
        await Task.yield()
        XCTAssertFalse(completed, "retirement must join the earlier in-flight writer")
        XCTAssertEqual(journal.pendingBatchCount, 31)
        XCTAssertEqual(calls, 1)
        release?.resume()
        await drain.value
        let joinedResult = await joined.value
        XCTAssertFalse(joinedResult)
        XCTAssertEqual(retired.pendingCount, 1, "new-account capture stays held on persistence failure")
        XCTAssertEqual(journal.pendingBatchCount, 31)
        let emptyOld = try await samples(oldStore), emptyNew = try await samples(newStore)
        XCTAssertTrue(emptyOld.isEmpty)
        XCTAssertTrue(emptyNew.isEmpty)

        shouldFail = false
        await retired.retry()
        XCTAssertEqual(retired.pendingCount, 0)
        XCTAssertEqual(journal.pendingBatchCount, 0)
        XCTAssertEqual(calls, 32)
        let reopened = try await WhoopStore(path: oldPath)
        openedStores.append(reopened)
        try await reopened.bindAccountOwner(projectURL: project, userID: oldOwner)
        let oldRows = try await samples(reopened), newRows = try await samples(newStore)
        let oldRR = try await reopened.rrIntervals(deviceId: deviceID, from: start, to: start + 100, limit: 100)
        let newRR = try await newStore.rrIntervals(deviceId: deviceID, from: start, to: start + 100, limit: 100)
        XCTAssertEqual(oldRows.map(\.ts), (0..<31).map { start + $0 })
        XCTAssertTrue(oldRows.allSatisfy { $0.bpm == 72 })
        XCTAssertEqual(oldRR.count, 62)
        XCTAssertTrue(oldRR.allSatisfy { $0.rrMs == 1_000 })
        XCTAssertTrue(newRows.isEmpty)
        XCTAssertTrue(newRR.isEmpty)
        do {
            _ = try await presentationStore.insert(Streams(hr: [.init(ts: start + 99, bpm: 99)]), deviceId: deviceID)
            XCTFail("the presentation fence must remain revoked")
        } catch { XCTAssertEqual(error as? StoreWriteFence.Failure, .revoked) }
    }

    func testBoundedQueueRetainsActualSourceSuffixAndJoinsPauseBeforeSuccess() async {
        var written: [Int] = []
        let journal = GenericCaptureJournal(maxBatches: 1) { streams, _ in
            written.append(contentsOf: streams.hr.map(\.ts)) // deliberately completes without suspension
        }
        var source: StandardHRSource? = source(journal)
        weak var retainedSource = source
        var pauseCalls = 0
        journal.didHoldCapture = {
            pauseCalls += 1
            if let source { self.stopAndRetain(source, in: journal) }
            source = nil
        }
        defer { journal.didHoldCapture = nil }
        for index in 0..<30 { XCTAssertTrue(source!.ingestHeartRateMeasurement(measurement, at: start + index)) }
        XCTAssertEqual(journal.pendingBatchCount, 1)
        XCTAssertEqual(source?.pendingCaptureCount, 29)
        XCTAssertFalse(source!.ingestHeartRateMeasurement(measurement, at: start + 30))
        journal.sealCapture()
        let drained = await journal.drain()
        XCTAssertTrue(drained)
        XCTAssertEqual(pauseCalls, 1, "join the hold handoff once; replaying its buffer must not repeatedly stop transports")
        XCTAssertEqual(written, (0..<30).map { start + $0 })
        XCTAssertEqual(journal.pendingBatchCount, 0)
        XCTAssertEqual(journal.pendingFinalBufferCount, 0)
        XCTAssertEqual(journal.pendingBytes, 0)
        XCTAssertFalse(journal.isHeld)
        XCTAssertNil(retainedSource, "release the stopped source after its final suffix is persisted")
    }

    func testBoundedFinalSourceSurvivesRepeatedFailureUntilRetiredDrainCommits() async throws {
        let oldStore = try await WhoopStore.inMemory()
        let newStore = try await WhoopStore.inMemory()
        var fail = true
        let journal = GenericCaptureJournal(maxBatches: 1) { [oldStore] streams, id in
            if fail { throw Failure.unavailable }
            _ = try await oldStore.insert(streams, deviceId: id)
        }
        var source: StandardHRSource? = source(journal)
        weak var retainedSource = source
        let paused = expectation(description: "failed source stopped and retained")
        journal.didHoldCapture = {
            if let source { self.stopAndRetain(source, in: journal) }
            source = nil
            paused.fulfill()
        }
        defer { journal.didHoldCapture = nil }
        for index in 0..<30 { XCTAssertTrue(source!.ingestHeartRateMeasurement(measurement, at: start + index)) }
        journal.sealCapture()
        let retired = RetiredCaptureDrain(automaticRetry: false)
        retired.retain(id: UUID()) { [journal] in await journal.drain() }
        await retired.retry()
        await fulfillment(of: [paused], timeout: 3)
        XCTAssertEqual(retired.pendingCount, 1)
        XCTAssertEqual(journal.pendingBatchCount, 1)
        XCTAssertEqual(journal.pendingFinalBufferCount, 1)
        XCTAssertEqual(retainedSource?.pendingCaptureCount, 29)
        await retired.retry()
        XCTAssertEqual(retired.pendingCount, 1)
        XCTAssertEqual(retainedSource?.pendingCaptureCount, 29)
        fail = false
        await retired.retry()
        XCTAssertEqual(retired.pendingCount, 0)
        XCTAssertNil(retainedSource)
        let oldRows = try await samples(oldStore), newRows = try await samples(newStore)
        let rr = try await oldStore.rrIntervals(deviceId: deviceID, from: start, to: start + 100, limit: 100)
        XCTAssertEqual(oldRows.map(\.ts), (0..<30).map { start + $0 })
        XCTAssertEqual(rr.count, 60)
        XCTAssertTrue(newRows.isEmpty)
        XCTAssertEqual(journal.pendingFinalBufferCount, 0)
    }

    func testByteLimitRejectsWithoutEvictingAcceptedBatchAndSealedGateStaysClosed() async throws {
        let streams = StandardHRMapping.samples(fromHR: 72, rr: [1_000, 1_000], contact: .supportedDetected, at: start)
        let size = try JSONEncoder().encode(streams).count + deviceID.utf8.count
        var written: [Streams] = []
        let journal = GenericCaptureJournal(maxBatches: 50, maxBytes: size) { streams, _ in written.append(streams) }
        XCTAssertTrue(journal.admit(streams, deviceID: deviceID))
        XCTAssertFalse(journal.admit(streams, deviceID: deviceID))
        XCTAssertEqual(journal.pendingBatchCount, 1)
        XCTAssertEqual(journal.pendingBytes, size)
        XCTAssertTrue(journal.isHeld)
        journal.sealCapture()
        let drained = await journal.drain()
        XCTAssertTrue(drained)
        XCTAssertEqual(written, [streams])
        XCTAssertFalse(journal.admit(streams, deviceID: deviceID))
    }

    func testAmbiguousCommitRetryKeepsEqualRRMultiplicityWithoutDuplication() async throws {
        let store = try await WhoopStore.inMemory()
        var first = true
        let journal = GenericCaptureJournal { streams, id in
            _ = try await store.insert(streams, deviceId: id)
            if first { first = false; throw Failure.unavailable }
        }
        let source = source(journal)
        XCTAssertTrue(source.ingestHeartRateMeasurement(measurement, at: start))
        source.stop(); journal.sealCapture()
        let failed = await journal.drain()
        XCTAssertFalse(failed)
        XCTAssertEqual(journal.pendingBatchCount, 1)
        let retried = await journal.drain()
        XCTAssertTrue(retried)
        let rows = try await samples(store)
        let rr = try await store.rrIntervals(deviceId: deviceID, from: start, to: start + 100, limit: 100)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rr.count, 2)
        XCTAssertEqual(Set(rr.map(\.seq)), [0, 1])
    }

    func testAdmissionCapturesValueAndDeviceAndCancellationDoesNotAbandonWriter() async {
        let entered = expectation(description: "writer captured")
        var release: CheckedContinuation<Void, Never>?
        var received: [(Streams, String)] = []
        let journal = GenericCaptureJournal { streams, id in
            entered.fulfill()
            await withCheckedContinuation { release = $0 }
            received.append((streams, id))
        }
        var streams = Streams(hr: [.init(ts: start, bpm: 72)])
        var id = deviceID
        XCTAssertTrue(journal.admit(streams, deviceID: id))
        streams.hr.append(.init(ts: start + 1, bpm: 99)); id = "other-device"
        journal.sealCapture()
        let first = Task { await journal.drain() }
        await fulfillment(of: [entered], timeout: 3)
        first.cancel()
        let second = Task { await journal.drain() }
        release?.resume()
        let firstResult = await first.value, secondResult = await second.value
        XCTAssertTrue(firstResult && secondResult)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.0.hr, [.init(ts: start, bpm: 72)])
        XCTAssertEqual(received.first?.1, deviceID)
    }

    func testMalformedOrOversizedNotificationsAreNotAcceptedIntoBoundedBuffer() async {
        let journal = GenericCaptureJournal { _, _ in XCTFail("no accepted measurement") }
        let source = source(journal)
        XCTAssertFalse(source.ingestHeartRateMeasurement([], at: start))
        XCTAssertFalse(source.ingestHeartRateMeasurement([0x10, 72] + Array(repeating: 0, count: 512), at: start))
        source.stop(); journal.sealCapture()
        let drained = await journal.drain()
        XCTAssertTrue(drained)
        XCTAssertEqual(source.pendingCaptureCount, 0)
        XCTAssertEqual(journal.pendingBatchCount, 0)
    }
}
