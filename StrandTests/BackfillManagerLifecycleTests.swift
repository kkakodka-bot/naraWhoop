import XCTest
@testable import Strand
import WhoopProtocol
import WhoopStore

@MainActor
final class BackfillManagerLifecycleTests: XCTestCase {
    func testHistoricalAckLogCadenceIsBounded() {
        XCTAssertFalse(BLEManager.shouldLogHistoricalAck(number: 0))
        XCTAssertEqual((1...100).filter { BLEManager.shouldLogHistoricalAck(number: $0) },
                       [1, 25, 50, 75, 100])
    }

    func testHistorySubmissionMarkerRequiresAnAcceptedWrite() {
        for accepted in [false, true] {
            let manager = BLEManager(state: LiveState(), startCentral: false)
            manager.test_configureHistoryTransport { _, _ in accepted }
            manager.test_simulateActiveBackfillSessionForWatchdog()
            let submission = BackfillAckSubmission(now: { 5 })
            CaptureJobTrace.$ackSubmission.withValue(submission) {
                manager.ackHistoricalChunk(trim: 7, endData: [UInt8](repeating: 0, count: 8))
            }
            XCTAssertEqual(submission.milliseconds(since: 0), accepted ? 5_000 : nil)
            manager.test_invalidateHistoryLink()
        }
    }

    private final class Store: BackfillStoreWriting {
        func insert(_ streams: Streams, deviceId: String) async throws
            -> (hr: Int, rr: Int, events: Int, battery: Int, spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
            (0, 0, 0, 0, 0, 0, 0, 0)
        }
        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {}
        func setCursor(_ name: String, _ value: Int) async throws {}
        func cursor(_ name: String) async throws -> Int? { nil }
    }

    private func configuredActor() async -> BackfillActor {
        let actor = BackfillActor()
        let hooks = BackfillMainHooks(
            ackTrim: { _, _ in }, onBankedOffload: { _ in }, log: { _ in },
            rejectedSink: { _, _, _ in true }, onChunk: { _, _ in },
            connectionActive: { false }, connectionLog: { _ in }, firmwareLayout: { _ in },
            onPersistCircuitBreak: {}, onChunkCommitBegin: {}, onChunkCommitAborted: {},
            onOffloadComplete: {})
        await actor.configure(store: Store(), deviceId: "test", hooks: hooks,
                              enableRawCapture: false, postOffloadJobKinds: [])
        return actor
    }

    func testConcurrentTriggersReserveOneHistoryRequestBeforeAwait() async {
        let actor = await configuredActor()
        let manager = BLEManager(state: LiveState(), startCentral: false)
        let sent = expectation(description: "one history request")
        sent.assertForOverFulfill = true
        var commands: [WhoopCommand] = []
        manager.test_configureHistoryTransport(actor: actor) { command, _ in
            commands.append(command)
            sent.fulfill()
            return true
        }
        manager.requestSync(.manual)
        let reservation = manager.test_pendingBackfillStart
        XCTAssertNotNil(reservation)
        manager.requestSync(.manual)
        manager.requestSync(.strap)
        XCTAssertEqual(manager.test_pendingBackfillStart, reservation)
        await fulfillment(of: [sent], timeout: 2)
        XCTAssertEqual(commands, [.sendHistoricalData])
        manager.test_invalidateHistoryLink()
    }

    func testDisconnectBeforeStartTaskRunsCannotSendOnNewLink() async {
        let actor = await configuredActor()
        let manager = BLEManager(state: LiveState(), startCentral: false)
        var commands: [WhoopCommand] = []
        manager.test_configureHistoryTransport(actor: actor) { command, _ in commands.append(command); return true }
        manager.requestSync(.manual)
        manager.test_invalidateHistoryLink()
        // Reconnection alone must not validate the previous connection's reservation.
        manager.test_configureHistoryTransport(actor: actor) { command, _ in commands.append(command); return true }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(commands.isEmpty)
        XCTAssertNil(manager.test_pendingBackfillStart)
    }

    func testActorInstalledAfterRequestReservationReceivesHistoryRequest() async {
        let actor = await configuredActor()
        let manager = BLEManager(state: LiveState(), startCentral: false)
        let sent = expectation(description: "history request after bootstrap")
        sent.assertForOverFulfill = true
        var commands: [WhoopCommand] = []
        let writer: (WhoopCommand, [UInt8]) -> Bool = { command, _ in
            commands.append(command)
            sent.fulfill()
            return true
        }
        manager.test_configureHistoryTransport(writer: writer)
        manager.requestSync(.manual)
        XCTAssertNotNil(manager.test_pendingBackfillStart)
        // Complete bootstrap synchronously before the reserved start task can run.
        manager.test_configureHistoryTransport(actor: actor, writer: writer)
        await fulfillment(of: [sent], timeout: 2)
        XCTAssertEqual(commands, [.sendHistoricalData])
        XCTAssertNil(manager.test_pendingBackfillStart)
        manager.test_invalidateHistoryLink()
    }

    func testSubmittedAckDoesNotCountUntilSuccessfulWriteCompletion() {
        let manager = BLEManager(state: LiveState(), startCentral: false)
        manager.test_configureHistoryTransport { _, _ in true }
        manager.test_simulateActiveBackfillSessionForWatchdog()
        manager.pauseBackfillIdleWatchdogForCommit()
        manager.ackHistoricalChunk(trim: 1, endData: [UInt8](repeating: 0, count: 8))
        XCTAssertEqual(manager.test_confirmedHistoryChunks, 0)
        XCTAssertTrue(manager.chunkCommitInFlight)
        manager.test_completeNextHistoryWrite()
        XCTAssertEqual(manager.test_confirmedHistoryChunks, 1)
        XCTAssertFalse(manager.chunkCommitInFlight)
        manager.test_invalidateHistoryLink()
    }

    func testLeaseExpirationBeforeAuthorizationFencesDelayedAckAndEndsOnce() {
        let manager = BLEManager(state: LiveState(), startCentral: false)
        var expire: (() -> Void)?, ended = 0, submissions = 0
        manager.historicalCommitLeaseFactoryForTesting = { expired in
            HistoricalCommitLease(begin: { expire = $0; return 41 },
                                  end: { _ in ended += 1 }, expired: expired)
        }
        manager.test_configureHistoryTransport { _, _ in submissions += 1; return true }
        manager.test_simulateActiveBackfillSessionForWatchdog()
        manager.pauseBackfillIdleWatchdogForCommit()
        XCTAssertEqual(manager.test_activeCommitLeaseCount, 1)
        expire?()
        manager.ackHistoricalChunk(trim: 1, endData: [UInt8](repeating: 0, count: 8))
        expire?()
        manager.test_invalidateHistoryLink()
        XCTAssertEqual(ended, 1)
        XCTAssertEqual(submissions, 0)
        XCTAssertFalse(manager.chunkCommitInFlight)
        XCTAssertEqual(manager.test_activeCommitLeaseCount, 0)
    }

    func testLeaseExpirationAfterSubmissionCannotCreditLateATTCompletion() {
        let state = LiveState()
        let manager = BLEManager(state: state, startCentral: false)
        var expire: (() -> Void)?, ended = 0
        manager.historicalCommitLeaseFactoryForTesting = { expired in
            HistoricalCommitLease(begin: { expire = $0; return 42 },
                                  end: { _ in ended += 1 }, expired: expired)
        }
        manager.test_configureHistoryTransport { _, _ in true }
        manager.test_simulateActiveBackfillSessionForWatchdog()
        manager.pauseBackfillIdleWatchdogForCommit()
        manager.ackHistoricalChunk(trim: 1, endData: [UInt8](repeating: 0, count: 8))
        expire?()
        XCTAssertFalse(state.backfilling)
        XCTAssertFalse(state.postOffloadBurstInProgress)
        manager.test_completeNextHistoryWrite()
        XCTAssertEqual(manager.test_confirmedHistoryChunks, 0)
        XCTAssertEqual(ended, 1)
        XCTAssertNil(state.lastSyncedAt)
        manager.test_invalidateHistoryLink()
    }

    func testDisconnectReleasesOverlappingChunkLeasesExactlyOnce() {
        let manager = BLEManager(state: LiveState(), startCentral: false)
        var expirations: [() -> Void] = [], ended: [Int] = []
        manager.historicalCommitLeaseFactoryForTesting = { expired in
            HistoricalCommitLease(begin: { expirations.append($0); return expirations.count },
                                  end: { ended.append($0) }, expired: expired)
        }
        manager.test_configureHistoryTransport { _, _ in true }
        manager.test_simulateActiveBackfillSessionForWatchdog()
        manager.pauseBackfillIdleWatchdogForCommit()
        manager.ackHistoricalChunk(trim: 1, endData: [UInt8](repeating: 0, count: 8))
        manager.pauseBackfillIdleWatchdogForCommit()
        XCTAssertEqual(manager.test_activeCommitLeaseCount, 2)
        manager.test_invalidateHistoryLink()
        for expire in expirations { expire() }
        manager.test_completeNextHistoryWrite()
        XCTAssertEqual(ended.sorted(), [1, 2])
        XCTAssertEqual(manager.test_activeCommitLeaseCount, 0)
    }

    func testFailedAckDoesNotCountOrLeaveSyncRunning() {
        let state = LiveState()
        let manager = BLEManager(state: state, startCentral: false)
        manager.test_configureHistoryTransport { _, _ in true }
        manager.test_simulateActiveBackfillSessionForWatchdog()
        manager.ackHistoricalChunk(trim: 1, endData: [UInt8](repeating: 0, count: 8))
        manager.test_completeNextHistoryWrite(error: NSError(domain: "test", code: 1))
        XCTAssertEqual(manager.test_confirmedHistoryChunks, 0)
        XCTAssertFalse(state.backfilling)
        XCTAssertNotNil(state.lastSyncError)
        manager.test_invalidateHistoryLink()
    }

    func testCompletionWaitsForOutstandingAck() async {
        let state = LiveState()
        let manager = BLEManager(state: state, startCentral: false)
        manager.test_configureHistoryTransport { _, _ in true }
        manager.test_simulateActiveBackfillSessionForWatchdog()
        manager.ackHistoricalChunk(trim: 1, endData: [UInt8](repeating: 0, count: 8))
        manager.test_completeHistory()
        XCTAssertTrue(state.backfilling)
        XCTAssertNil(state.lastSyncedAt)
        manager.test_completeNextHistoryWrite()
        XCTAssertFalse(state.backfilling)
        manager.test_invalidateHistoryLink()
    }

    func testLateWriteCompletionCannotCreditNewSession() {
        let manager = BLEManager(state: LiveState(), startCentral: false)
        manager.test_configureHistoryTransport { _, _ in true }
        manager.test_simulateActiveBackfillSessionForWatchdog()
        manager.ackHistoricalChunk(trim: 1, endData: [UInt8](repeating: 0, count: 8))
        manager.test_invalidateHistoryLink()
        manager.test_simulateActiveBackfillSessionForWatchdog()
        manager.test_completeNextHistoryWrite()
        XCTAssertEqual(manager.test_confirmedHistoryChunks, 0)
        manager.test_invalidateHistoryLink()
    }

    func testEarlierAckCompletionCannotCancelNextChunkCommitDeadline() {
        let manager = BLEManager(state: LiveState(), startCentral: false)
        manager.test_configureHistoryTransport { _, _ in true }
        manager.test_simulateActiveBackfillSessionForWatchdog()
        manager.pauseBackfillIdleWatchdogForCommit()
        manager.ackHistoricalChunk(trim: 1, endData: [UInt8](repeating: 0, count: 8))
        // The strap can begin its next chunk before CoreBluetooth delivers the earlier write callback.
        manager.pauseBackfillIdleWatchdogForCommit()
        manager.test_completeNextHistoryWrite()
        XCTAssertTrue(manager.chunkCommitInFlight)
        XCTAssertEqual(manager.test_confirmedHistoryChunks, 1)
        manager.ackHistoricalChunk(trim: 2, endData: [UInt8](repeating: 0, count: 8))
        manager.test_completeNextHistoryWrite()
        XCTAssertFalse(manager.chunkCommitInFlight)
        XCTAssertEqual(manager.test_confirmedHistoryChunks, 2)
        manager.test_invalidateHistoryLink()
    }

    func testMissingAckCompletionHitsDeadlineAndCannotLaterCreditProgress() async {
        BLEManager.backfillCommitTimeoutSecondsForTesting = 1
        defer { BLEManager.backfillCommitTimeoutSecondsForTesting = nil }
        let state = LiveState()
        let manager = BLEManager(state: state, startCentral: false)
        manager.test_configureHistoryTransport { _, _ in true }
        manager.test_simulateActiveBackfillSessionForWatchdog()
        manager.pauseBackfillIdleWatchdogForCommit()
        manager.ackHistoricalChunk(trim: 1, endData: [UInt8](repeating: 0, count: 8))
        try? await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertFalse(state.backfilling)
        XCTAssertNotNil(state.lastSyncError)
        manager.test_completeNextHistoryWrite()
        XCTAssertEqual(manager.test_confirmedHistoryChunks, 0)
        manager.test_invalidateHistoryLink()
    }
}
