import XCTest
import Foundation
import GRDB
import WhoopProtocol
import WhoopStore
#if !GENERIC_CAPTURE_NATIVE_TESTS
@testable import Strand
#endif

@MainActor
final class StandardHRDurableCaptureTests: XCTestCase {
    nonisolated static let expectedNativeCount = 31
    private let project = "https://standard-hr-fixture.invalid"
    private let account = "00000000-0000-0000-0000-0000000000a1"
    private let device = "synthetic-standard-hr"
    private let timestamp = 1_750_000_000
    private let measurement: [UInt8] = [0x16, 72, 0, 4, 0, 4]
    private enum Failure: Error { case injected }

    private actor Gate {
        let entered: XCTestExpectation
        private var announced = false
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        init(_ entered: XCTestExpectation) { self.entered = entered }
        func wait() async {
            if open { return }
            if !announced { announced = true; entered.fulfill() }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() { open = true; let saved = waiters; waiters = []; saved.forEach { $0.resume() } }
    }
    private actor FailOnce {
        var failing = true
        func check() throws { if failing { failing = false; throw Failure.injected } }
    }
    private actor PreparationCalls {
        private var calls: [String] = []
        func record(_ call: String) { calls.append(call) }
        func observed() -> [String] { calls }
    }
    private func owner(_ user: String? = nil) throws -> StandardHRCaptureOwner {
        try StandardHRCaptureOwner(projectURL: project, userID: user ?? account)
    }
    private func hooks() -> StandardHRJournalHooks {
        var value = StandardHRJournalHooks()
        value.automaticRetry = false
        value.availableBytes = { _ in 2_147_483_648 }
        return value
    }
    private func store(_ user: String? = nil) async throws -> WhoopStore {
        let base = ProcessInfo.processInfo.environment["STANDARD_HR_CAPTURE_FIXTURES"]
            .map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("standard-hr-durable-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try await WhoopStore(path: directory.appendingPathComponent("capture.sqlite").path)
        try await store.bindAccountOwner(projectURL: project, userID: user ?? account)
        try await store.upsertDevice(id: device, mac: nil, name: nil)
        addTeardownBlock { try store.registryWriter.close() }
        return store
    }
    private func prepare(_ store: WhoopStore, hooks supplied: StandardHRJournalHooks? = nil,
                         user: String? = nil) async throws -> GenericCaptureJournal {
        try await GenericCaptureJournal.prepareStandardHR(store: store, owner: owner(user),
            runtimeGeneration: UUID(), hooks: supplied ?? hooks())
    }
    private func source(_ journal: GenericCaptureJournal, id: String? = nil,
                        live: LiveState? = nil) throws -> StandardHRSource {
        let selected = id ?? device
        return try StandardHRSource(live: live ?? LiveState(), deviceId: selected,
            durableCapture: journal.standardHRSink(deviceID: selected), startCentral: false)
    }
    private func finish(_ journal: GenericCaptureJournal) async {
        journal.sealCapture()
        let success = await journal.drain()
        XCTAssertTrue(success)
        XCTAssertEqual(journal.pendingBatchCount, 0)
        XCTAssertEqual(journal.pendingBytes, 0)
    }
    private func occurrences(_ store: WhoopStore) throws -> [Row] {
        try store.registryWriter.read { db in
            try Row.fetchAll(db, sql: """
                SELECT o.* FROM standardHRCaptureOccurrence o
                JOIN standardHRCaptureSession s ON s.sessionID=o.sessionID
                ORDER BY s.ordinal,o.sequence
                """)
        }
    }
    private func hr(_ store: WhoopStore, id: String? = nil) async throws -> [HRSample] {
        try await store.hrSamples(deviceId: id ?? device, from: timestamp - 10, to: timestamp + 100, limit: 200)
    }

    func testSubthresholdOriginalBytesAndFrozenMappingCommitWithoutStopThreshold() async throws {
        let store = try await store(), journal = try await prepare(store)
        let source = try source(journal)
        var receipts: [StandardHRLocalReceipt] = []
        journal.didCommitStandardHR = { receipts.append($0) }
        XCTAssertTrue(source.ingestHeartRateMeasurement(measurement, at: timestamp))
        XCTAssertEqual(source.pendingCaptureCount, 0)
        XCTAssertEqual(receipts.count, 0, "the synchronous callback is not T1")
        let drained = await journal.drain()
        XCTAssertTrue(drained)
        let rows = try occurrences(store)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["rawBytes"] as Data, Data(measurement))
        XCTAssertEqual(rows[0]["projectionState"] as Int, 1)
        let streams = try JSONDecoder().decode(Streams.self, from: rows[0]["projectionJSON"] as Data)
        XCTAssertEqual(streams.hr, [HRSample(ts: timestamp, bpm: 72)])
        XCTAssertEqual(streams.rr.map(\.rrMs), [1000, 1000])
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts[0].intentSHA256, rows[0]["intentSHA256"] as String)
        source.stop(); await finish(journal)
    }

    func testDistinctEqualOccurrencesPreserveOriginalsButNotInventCanonicalMultiplicity() async throws {
        let store = try await store(), journal = try await prepare(store)
        let source = try source(journal)
        for _ in 0..<2 { XCTAssertTrue(source.ingestHeartRateMeasurement(measurement, at: timestamp)) }
        source.stop(); await finish(journal)
        let rows = try occurrences(store)
        XCTAssertEqual(rows.map { $0["sequence"] as Int }, [0, 1])
        XCTAssertEqual(rows.map { $0["rawBytes"] as Data }, [Data(measurement), Data(measurement)])
        let canonical = try await hr(store)
        let rr = try await store.rrIntervals(deviceId: device, from: timestamp, to: timestamp + 1, limit: 20)
        XCTAssertEqual(canonical.count, 1)
        XCTAssertEqual(rr.count, 2, "one notification is one original fixed mapping batch")
        XCTAssertEqual(rr.map(\.seq), [0, 1])
    }

    func testEnergyAndMutableCallerBytesRetainedIndependentlyOfProjection() async throws {
        let store = try await store(), journal = try await prepare(store)
        let source = try source(journal)
        var input: [UInt8] = [0x1e, 72, 0x34, 0x12, 0, 4, 0, 4]
        let original = Data(input)
        XCTAssertTrue(source.ingestHeartRateMeasurement(input, at: timestamp))
        input[2] = 0xff
        XCTAssertTrue(source.ingestHeartRateMeasurement(measurement, at: timestamp))
        source.stop(); await finish(journal)
        let rows = try occurrences(store)
        XCTAssertEqual(rows[0]["rawBytes"] as Data, original)
        XCTAssertEqual(rows[0]["projectionJSON"] as Data, rows[1]["projectionJSON"] as Data)
        XCTAssertNotEqual(rows[0]["rawSHA256"] as String, rows[1]["rawSHA256"] as String)
    }

    func testStoppedSinkCannotResumeButSharedJournalAcceptsNewSource() async throws {
        let store = try await store(), journal = try await prepare(store)
        let old = try source(journal)
        XCTAssertTrue(old.ingestHeartRateMeasurement(measurement, at: timestamp))
        old.stop(); old.scan(); old.connect(UUID())
        XCTAssertFalse(old.ingestHeartRateMeasurement(measurement, at: timestamp + 1))
        let next = try source(journal)
        XCTAssertTrue(next.ingestHeartRateMeasurement(measurement, at: timestamp + 2))
        next.stop(); await finish(journal)
        XCTAssertEqual(try occurrences(store).map { $0["hostTimestampSeconds"] as Int }, [timestamp, timestamp + 2])
    }

    func testWholeJournalSealRejectsOldSourceAndNewSinkBeforePublication() async throws {
        let store = try await store(), journal = try await prepare(store)
        let live = LiveState(), source = try source(journal, live: live)
        journal.sealCapture()
        XCTAssertFalse(source.ingestHeartRateMeasurement(measurement, at: timestamp))
        XCTAssertNil(live.heartRate)
        XCTAssertThrowsError(try journal.standardHRSink(deviceID: device))
        await finish(journal)
        XCTAssertTrue(try occurrences(store).isEmpty)
    }

    func testMissingMismatchedSealedOrLegacySinkCannotConstructDurableSource() async throws {
        XCTAssertThrowsError(try StandardHRSource(live: LiveState(), deviceId: device,
            durableCapture: nil, startCentral: false))
        let store = try await store()
        XCTAssertThrowsError(try GenericCaptureJournal(store: store).standardHRSink(deviceID: device))
        let journal = try await prepare(store), sink = try journal.standardHRSink(deviceID: device)
        XCTAssertThrowsError(try journal.standardHRSink(deviceID: "invalid\0device"))
        XCTAssertThrowsError(try StandardHRSource(live: LiveState(), deviceId: "different",
            durableCapture: sink, startCentral: false))
        sink.sealIntake()
        XCTAssertThrowsError(try StandardHRSource(live: LiveState(), deviceId: device,
            durableCapture: sink, startCentral: false))
        await finish(journal)
    }

    func testConcurrentPreparationClaimsSlotBeforeFirstAwaitAndJoinsNoOtherOwner() async throws {
        let store = try await store(), entered = expectation(description: "preparation held")
        let gate = Gate(entered)
        var firstHooks = hooks(); firstHooks.beforeRecovery = { await gate.wait() }
        let first = Task { try await self.prepare(store, hooks: firstHooks) }
        await fulfillment(of: [entered], timeout: 5)
        do { _ = try await prepare(store); XCTFail("second preparation must not steal slot") }
        catch { XCTAssertEqual(error as? StandardHRCaptureError, .concurrentCapture) }
        await gate.release()
        let journal = try await first.value
        await finish(journal)
        let reopened = try await prepare(store)
        await finish(reopened)
    }

    func testPreparationFailureReleasesSlotAndLeavesNoNewIntake() async throws {
        let store = try await store()
        var failed = hooks(); failed.beforeRecovery = { throw Failure.injected }
        do { _ = try await prepare(store, hooks: failed); XCTFail("must fail") } catch {}
        XCTAssertTrue(try occurrences(store).isEmpty)
        let recovered = try await prepare(store)
        await finish(recovered)
    }

    func testT1CommittedButCallerFailureHasNoPrematureReceiptAndRetriesSameIdentity() async throws {
        let store = try await store(), fault = FailOnce()
        var injected = hooks(); injected.afterAppend = { _ in try await fault.check() }
        let journal = try await prepare(store, hooks: injected), source = try source(journal)
        var receipts: [StandardHRLocalReceipt] = []
        journal.didCommitStandardHR = { receipts.append($0) }
        XCTAssertTrue(source.ingestHeartRateMeasurement(measurement, at: timestamp))
        source.stop(); journal.sealCapture()
        let first = await journal.drain()
        XCTAssertFalse(first)
        XCTAssertEqual(receipts.count, 0)
        let pending = try occurrences(store)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0]["projectionState"] as Int, 0)
        XCTAssertEqual(journal.pendingBatchCount, 1)
        await finish(journal)
        XCTAssertEqual(try occurrences(store).count, 1)
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts[0].id.sequence, 0)
    }

    func testProjectionFailureRetainsRawDebtAndDoesNotRepeatReceiptOnRetry() async throws {
        let store = try await store(), fault = FailOnce()
        var injected = hooks(); injected.beforeProjection = { try await fault.check() }
        let journal = try await prepare(store, hooks: injected), source = try source(journal)
        var receipts = 0
        journal.didCommitStandardHR = { _ in receipts += 1 }
        XCTAssertTrue(source.ingestHeartRateMeasurement(measurement, at: timestamp))
        source.stop(); journal.sealCapture()
        let first = await journal.drain()
        XCTAssertFalse(first)
        XCTAssertEqual(receipts, 1)
        XCTAssertEqual(try occurrences(store)[0]["projectionState"] as Int, 0)
        let canonical = try await hr(store)
        XCTAssertTrue(canonical.isEmpty)
        await finish(journal)
        XCTAssertEqual(receipts, 1)
        XCTAssertEqual(try occurrences(store)[0]["projectionState"] as Int, 1)
    }

    func testReceiptObserverCanReentrantlySealAndJoinAfterAccounting() async throws {
        let store = try await store(), journal = try await prepare(store), source = try source(journal)
        var observed = 0
        var joined: Task<Bool, Never>?
        journal.didCommitStandardHR = { _ in
            observed += 1
            XCTAssertEqual(journal.pendingBatchCount, 1)
            XCTAssertEqual(journal.pendingBytes, 16_384)
            journal.sealCapture()
            XCTAssertFalse(source.ingestHeartRateMeasurement(self.measurement, at: self.timestamp + 1))
            joined = Task { await journal.drain() }
        }
        XCTAssertTrue(source.ingestHeartRateMeasurement(measurement, at: timestamp))
        let drained = await journal.drain()
        XCTAssertTrue(drained)
        let joinedResult = await joined?.value
        XCTAssertEqual(joinedResult, true)
        XCTAssertEqual(observed, 1)
        journal.didCommitStandardHR = nil
        await finish(journal)
    }

    func testReceiptObserverReentrantNextOfferKeepsFIFOAndOneReceiptPerIdentity() async throws {
        let store = try await store(), journal = try await prepare(store), source = try source(journal)
        var sequences: [Int64] = []
        journal.didCommitStandardHR = { receipt in
            sequences.append(receipt.id.sequence)
            if receipt.id.sequence == 0 {
                XCTAssertTrue(source.ingestHeartRateMeasurement(self.measurement, at: self.timestamp + 1))
            }
        }
        XCTAssertTrue(source.ingestHeartRateMeasurement(measurement, at: timestamp))
        let drained = await journal.drain()
        XCTAssertTrue(drained)
        XCTAssertEqual(sequences, [0, 1])
        journal.didCommitStandardHR = nil
        source.stop(); await finish(journal)
    }

    func testSixtyFourReservationsHoldWithoutEvictionAndDrainSealedLastOffer() async throws {
        let store = try await store(), journal = try await prepare(store), source = try source(journal)
        var holds = 0
        journal.didHoldCapture = {
            holds += 1
            source.stop()
            if source.pendingCaptureCount > 0 {
                journal.retainFinalBuffer(owner: source) { source.retryBufferedPersistence() }
            }
        }
        for index in 0..<64 { XCTAssertTrue(source.ingestHeartRateMeasurement(measurement, at: timestamp + index)) }
        XCTAssertEqual(journal.pendingBatchCount, 64)
        XCTAssertEqual(journal.pendingBytes, 1_048_576)
        XCTAssertEqual(source.pendingCaptureCount, 1)
        XCTAssertTrue(journal.isHeld)
        XCTAssertFalse(source.ingestHeartRateMeasurement(measurement, at: timestamp + 64))
        source.stop(); journal.sealCapture()
        await finish(journal)
        XCTAssertEqual(holds, 1)
        let rows = try occurrences(store)
        XCTAssertEqual(rows.count, 64)
        XCTAssertEqual(rows.map { $0["sequence"] as Int }, Array(0..<64))
        XCTAssertEqual(source.pendingCaptureCount, 0)
        XCTAssertEqual(journal.pendingFinalBufferCount, 0)
        journal.didHoldCapture = nil
    }

    func testCancelledDrainWaiterDoesNotCancelOwnedWrite() async throws {
        let store = try await store(), entered = expectation(description: "append blocked")
        let gate = Gate(entered)
        var injected = hooks(); injected.beforeAppend = { _ in await gate.wait() }
        let journal = try await prepare(store, hooks: injected), source = try source(journal)
        XCTAssertTrue(source.ingestHeartRateMeasurement(measurement, at: timestamp))
        let waiter = Task { await journal.drain() }
        await fulfillment(of: [entered], timeout: 5)
        source.stop(); journal.sealCapture(); waiter.cancel()
        await gate.release()
        let result = await waiter.value
        XCTAssertTrue(result)
        await finish(journal)
        XCTAssertEqual(try occurrences(store).count, 1)
    }

    func testOldOwnerRetirementAndNewAccountStayDisjoint() async throws {
        let a = try await store(), entered = expectation(description: "old A append blocked"), gate = Gate(entered)
        var injected = hooks(); injected.beforeAppend = { _ in await gate.wait() }
        let journalA = try await prepare(a, hooks: injected), sourceA = try source(journalA)
        XCTAssertTrue(sourceA.ingestHeartRateMeasurement(measurement, at: timestamp))
        await fulfillment(of: [entered], timeout: 5)
        sourceA.stop(); journalA.sealCapture()
        let bID = "00000000-0000-0000-0000-0000000000b2"
        let b = try await store(bID), journalB = try await prepare(b, user: bID)
        XCTAssertTrue(try occurrences(b).isEmpty)
        do { _ = try await prepare(a, user: bID); XCTFail("wrong-owner preparation must fail") } catch {}
        XCTAssertFalse(sourceA.ingestHeartRateMeasurement(measurement, at: timestamp + 1))
        await gate.release()
        await finish(journalA); await finish(journalB)
        XCTAssertEqual(try occurrences(a).count, 1)
        XCTAssertTrue(try occurrences(b).isEmpty)
        let sameAccountReturn = try await prepare(a)
        XCTAssertFalse(sourceA.ingestHeartRateMeasurement(measurement, at: timestamp + 2))
        await finish(sameAccountReturn)
    }

    func testRecoveryProjectsExistingT1BeforeOpeningFreshSession() async throws {
        let store = try await store(), owner = try owner()
        let old = try await store.beginStandardHRCapture(owner: owner, sessionID: UUID(),
            runtimeGeneration: UUID(), openedAtUnixSeconds: 10)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let batch = try StandardHRFrozenBatch(id: StandardHRCaptureID(sessionID: old.sessionID, sequence: 0),
            scope: DurableIngestScope(environment: project, accountID: account, deviceID: device),
            hostTimestampSeconds: Int64(timestamp), rawBytes: Data(measurement),
            projectionJSON: encoder.encode(StandardHRMapping.samples(fromHR: 72, rr: [1000, 1000],
                contact: .supportedDetected, at: timestamp)))
        _ = try await store.appendStandardHRCapture(batch, session: old)
        let journal = try await prepare(store)
        let rows = try occurrences(store)
        XCTAssertEqual(rows[0]["projectionState"] as Int, 1)
        let oldClosed = try await store.registryWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT sealed FROM standardHRCaptureSession WHERE sessionID=?",
                arguments: [old.sessionID.uuidString.lowercased()])
        }
        XCTAssertEqual(oldClosed, 1)
        await finish(journal)
    }

    func testEncodingAndDigestWorkAreOffMainActor() async throws {
        let store = try await store(), observed = expectation(description: "encoder observed")
        var injected = hooks()
        injected.didEncode = { onMain in XCTAssertFalse(onMain); observed.fulfill() }
        let journal = try await prepare(store, hooks: injected), source = try source(journal)
        XCTAssertTrue(source.ingestHeartRateMeasurement(measurement, at: timestamp))
        source.stop(); await finish(journal)
        await fulfillment(of: [observed], timeout: 5)
    }

    func testLowOrUnknownFreeSpaceRejectsPreparationWithoutSlotLeak() async throws {
        let store = try await store()
        for free in [Int64?.none, Int64(1_073_741_823)] {
            var injected = hooks(); injected.availableBytes = { _ in free }
            do { _ = try await prepare(store, hooks: injected); XCTFail("must hold") }
            catch { XCTAssertEqual(error as? StandardHRCaptureError, .capacity) }
        }
        let journal = try await prepare(store)
        await finish(journal)
    }

    func testInMemoryPreparationRejectsBeforeCapacityRecoveryOrAdmissionAndFileStillWorks() async throws {
        let memory = try await WhoopStore.inMemory()
        defer { try? memory.registryWriter.close() }
        try await memory.bindAccountOwner(projectURL: project, userID: account)
        let calls = PreparationCalls()
        var injected = hooks()
        injected.availableBytes = { _ in await calls.record("capacity"); return 2_147_483_648 }
        injected.beforeRecovery = { await calls.record("recovery") }
        injected.beforeAppend = { _ in await calls.record("admission") }
        injected.afterAppend = { _ in await calls.record("receipt") }
        var unexpected: GenericCaptureJournal?
        do {
            unexpected = try await prepare(memory, hooks: injected)
            XCTFail("in-memory storage cannot grant a durable capture session")
        } catch { XCTAssertEqual(error as? StandardHRCaptureError, .storageUnavailable) }
        let observed = await calls.observed()
        XCTAssertEqual(observed, [], "reject the raw path before any preparation work")
        try await memory.registryWriter.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM standardHRCaptureSession"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM standardHRCaptureOccurrence"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM syncJob"), 0)
        }
        if let unexpected { await finish(unexpected) }
        let file = try await store(), journal = try await prepare(file)
        let source = try source(journal)
        XCTAssertTrue(source.ingestHeartRateMeasurement(measurement, at: timestamp))
        source.stop(); await finish(journal)
        XCTAssertEqual(try occurrences(file).count, 1)
    }

    func testEachSourceKeepsItsCapturedDeviceAcrossSwitchAndClockRollback() async throws {
        let store = try await store(), journal = try await prepare(store)
        try await store.upsertDevice(id: "second-strap", mac: nil, name: nil)
        let first = try source(journal)
        XCTAssertTrue(first.ingestHeartRateMeasurement(measurement, at: timestamp + 5))
        first.stop()
        let second = try source(journal, id: "second-strap")
        XCTAssertTrue(second.ingestHeartRateMeasurement(measurement, at: timestamp))
        second.stop(); await finish(journal)
        let rows = try occurrences(store)
        XCTAssertEqual(rows.map { $0["deviceID"] as String }, [device, "second-strap"])
        XCTAssertEqual(rows.map { $0["hostTimestampSeconds"] as Int }, [timestamp + 5, timestamp])
    }

    func testMalformedAndOversizedNotificationsClaimNoReservation() async throws {
        let store = try await store(), journal = try await prepare(store), source = try source(journal)
        XCTAssertFalse(source.ingestHeartRateMeasurement([], at: timestamp))
        XCTAssertFalse(source.ingestHeartRateMeasurement([0x01, 72], at: timestamp))
        XCTAssertFalse(source.ingestHeartRateMeasurement(Array(repeating: 1, count: 513), at: timestamp))
        XCTAssertEqual(journal.pendingBatchCount, 0)
        XCTAssertTrue(source.ingestHeartRateMeasurement(measurement, at: timestamp))
        source.stop(); await finish(journal)
        XCTAssertEqual(try occurrences(store).count, 1)
    }

    func testPreparedJournalRejectsLegacyStreamsAdmission() async throws {
        let store = try await store(), journal = try await prepare(store)
        XCTAssertFalse(journal.admit(StandardHRMapping.samples(fromHR: 72, rr: [], at: timestamp), deviceID: device))
        XCTAssertEqual(journal.pendingBatchCount, 0)
        await finish(journal)
        XCTAssertTrue(try occurrences(store).isEmpty)
    }

    func testMaximumAcceptedRawValueKeepsAll255RRObservationsInOneFrozenBatch() async throws {
        let store = try await store(), journal = try await prepare(store), source = try source(journal)
        let bytes: [UInt8] = [0x16, 72] + Array(repeating: [UInt8(0xff), 0xff], count: 255).flatMap { $0 }
        XCTAssertEqual(bytes.count, 512)
        XCTAssertTrue(source.ingestHeartRateMeasurement(bytes, at: timestamp))
        source.stop(); await finish(journal)
        let rows = try occurrences(store)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["rawBytes"] as Data, Data(bytes))
        let projection = try JSONDecoder().decode(Streams.self, from: rows[0]["projectionJSON"] as Data)
        XCTAssertEqual(projection.rr.map(\.rrMs), Array(repeating: 63999, count: 255))
        let canonical = try await store.rrIntervals(deviceId: device, from: timestamp, to: timestamp + 1, limit: 300)
        XCTAssertEqual(canonical.count, 255)
        XCTAssertEqual(canonical.map(\.seq), Array(0..<255))
    }

    func testSixteenBitHRAndAcceptedTrailingByteStayFaithfulToExistingParser() async throws {
        let store = try await store(), journal = try await prepare(store), source = try source(journal)
        let bytes: [UInt8] = [0x1f, 0x2c, 0x01, 0xcd, 0xab, 0xff, 0x03, 0xa5]
        XCTAssertTrue(source.ingestHeartRateMeasurement(bytes, at: timestamp))
        source.stop(); await finish(journal)
        let row = try XCTUnwrap(occurrences(store).first)
        XCTAssertEqual(row["rawBytes"] as Data, Data(bytes))
        let projection = try JSONDecoder().decode(Streams.self, from: row["projectionJSON"] as Data)
        XCTAssertEqual(projection.hr.map(\.bpm), [300])
        XCTAssertEqual(projection.rr.map(\.rrMs), [999])
        XCTAssertEqual(projection.events[0].payload["contact"], .string("supported_detected"))
    }

    func testFailureAfterProjectionReturnRetriesWithoutRepublishingReceiptOrUploadDebt() async throws {
        let store = try await store(), fault = FailOnce()
        var injected = hooks(); injected.afterProjection = { _ in try await fault.check() }
        let journal = try await prepare(store, hooks: injected), source = try source(journal)
        var receipts = 0
        journal.didCommitStandardHR = { _ in receipts += 1 }
        XCTAssertTrue(source.ingestHeartRateMeasurement(measurement, at: timestamp))
        source.stop(); journal.sealCapture()
        let first = await journal.drain()
        XCTAssertFalse(first)
        XCTAssertEqual(try occurrences(store)[0]["projectionState"] as Int, 1)
        XCTAssertEqual(receipts, 1)
        let token = try await store.registryWriter.read { db in
            try String.fetchOne(db, sql: "SELECT token FROM syncJob WHERE kind='cloudPush'")
        }
        XCTAssertNotNil(token)
        await finish(journal)
        let retriedToken = try await store.registryWriter.read { db in
            try String.fetchOne(db, sql: "SELECT token FROM syncJob WHERE kind='cloudPush'")
        }
        XCTAssertEqual(retriedToken, token)
        XCTAssertEqual(receipts, 1)
    }

    func testActualSQLSealFailureRetainsSlotUntilExactRetryCompletes() async throws {
        let store = try await store(), journal = try await prepare(store)
        try await store.registryWriter.write { db in
            try db.execute(sql: """
                CREATE TRIGGER standardHR_test_seal_failure BEFORE UPDATE OF sealed ON standardHRCaptureSession
                WHEN OLD.sealed=0 AND NEW.sealed=1 BEGIN SELECT RAISE(ABORT,'injected seal failure'); END
                """)
        }
        journal.sealCapture()
        let first = await journal.drain()
        XCTAssertFalse(first)
        do { _ = try await prepare(store); XCTFail("failed seal must retain live-slot ownership") }
        catch { XCTAssertEqual(error as? StandardHRCaptureError, .concurrentCapture) }
        try await store.registryWriter.write { db in try db.execute(sql: "DROP TRIGGER standardHR_test_seal_failure") }
        await finish(journal)
        let replacement = try await prepare(store)
        await finish(replacement)
    }

    func testSameDatabaseThroughPathAliasCannotAcquireCompetingLiveSlot() async throws {
        let store = try await store(), journal = try await prepare(store)
        let directory = URL(fileURLWithPath: store.registryWriter.path).deletingLastPathComponent()
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        let second = try await WhoopStore(path: alias.appendingPathComponent("capture.sqlite").path)
        defer { try? second.registryWriter.close() }
        do { _ = try await prepare(second); XCTFail("same file alias must not close the first session") }
        catch { XCTAssertEqual(error as? StandardHRCaptureError, .concurrentCapture) }
        let actual = try source(journal)
        XCTAssertTrue(actual.ingestHeartRateMeasurement(measurement, at: timestamp))
        actual.stop(); await finish(journal)
        XCTAssertEqual(try occurrences(store).count, 1)
    }

    #if GENERIC_CAPTURE_NATIVE_TESTS
    private typealias CaptureSQLRow = [String: DatabaseValue]
    private struct CrashSnapshot: Equatable {
        let owner: [CaptureSQLRow]
        let originals: [CaptureSQLRow]
        let occurrences: [CaptureSQLRow]
        let hr: [CaptureSQLRow]
        let rr: [CaptureSQLRow]
        let events: [CaptureSQLRow]
        let debt: [CaptureSQLRow]
    }

    private func crashSnapshot(_ store: WhoopStore) throws -> CrashSnapshot {
        try store.registryWriter.read { db in
            func rows(_ sql: String) throws -> [CaptureSQLRow] {
                try Row.fetchAll(db, sql: sql).map { Dictionary(uniqueKeysWithValues: $0) }
            }
            return try CrashSnapshot(
                owner: rows("SELECT * FROM localAccountOwner ORDER BY singleton"),
                originals: rows("""
                    SELECT s.ordinal,s.projectURL,s.userID,s.runtimeGeneration,s.openedAt,s.sessionChargeBytes,
                      o.sessionID,o.sequence,o.deviceID,o.hostTimestampSeconds,o.schemaVersion,o.decoderVersion,
                      o.mappingVersion,o.rawBytes,o.projectionJSON,o.rawSHA256,o.intentSHA256,o.chargeBytes
                    FROM standardHRCaptureOccurrence o JOIN standardHRCaptureSession s ON s.sessionID=o.sessionID
                    ORDER BY s.ordinal,o.sequence
                    """),
                occurrences: rows("SELECT rowid,* FROM standardHRCaptureOccurrence ORDER BY sessionID,sequence"),
                hr: rows("SELECT rowid,* FROM hrSample ORDER BY deviceId,ts"),
                rr: rows("SELECT rowid,* FROM rrInterval ORDER BY deviceId,ts,seq"),
                events: rows("SELECT rowid,* FROM event ORDER BY deviceId,ts,kind"),
                debt: rows("SELECT rowid,* FROM syncJob ORDER BY kind"))
        }
    }

    private func assertCrashOriginals(_ snapshot: CrashSnapshot, count: Int) throws {
        XCTAssertEqual(snapshot.owner.count, 1)
        XCTAssertEqual(snapshot.owner.first?["projectURL"], project.databaseValue)
        XCTAssertEqual(snapshot.owner.first?["userID"], account.databaseValue)
        XCTAssertEqual(snapshot.originals.count, count)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let projection = try encoder.encode(StandardHRMapping.samples(fromHR: 72, rr: [1000, 1000],
            contact: .supportedDetected, at: timestamp))
        for row in snapshot.originals {
            let sessionText = try XCTUnwrap(String.fromDatabaseValue(try XCTUnwrap(row["sessionID"])))
            let session = try XCTUnwrap(UUID(uuidString: sessionText))
            XCTAssertEqual(sessionText, session.uuidString.lowercased())
            let generation = try XCTUnwrap(String.fromDatabaseValue(try XCTUnwrap(row["runtimeGeneration"])))
            XCTAssertNotNil(UUID(uuidString: generation))
            XCTAssertEqual(row["projectURL"], project.databaseValue)
            XCTAssertEqual(row["userID"], account.databaseValue)
            XCTAssertEqual(row["deviceID"], device.databaseValue)
            XCTAssertEqual(row["sequence"], 0.databaseValue)
            XCTAssertEqual(row["hostTimestampSeconds"], timestamp.databaseValue)
            XCTAssertEqual(row["schemaVersion"], 1.databaseValue)
            XCTAssertEqual(row["decoderVersion"], "standard-hr-current-v1".databaseValue)
            XCTAssertEqual(row["mappingVersion"], "standard-hr-one-notification-v1".databaseValue)
            let expected = try StandardHRFrozenBatch(id: StandardHRCaptureID(sessionID: session, sequence: 0),
                scope: DurableIngestScope(environment: project, accountID: account, deviceID: device),
                hostTimestampSeconds: Int64(timestamp), rawBytes: Data(measurement), projectionJSON: projection)
            XCTAssertEqual(row["rawBytes"], expected.rawBytes.databaseValue)
            XCTAssertEqual(row["projectionJSON"], projection.databaseValue)
            XCTAssertEqual(row["rawSHA256"], expected.rawSHA256.databaseValue)
            XCTAssertEqual(row["intentSHA256"], expected.intentSHA256.databaseValue)
            XCTAssertEqual(row["chargeBytes"], expected.chargeBytes.databaseValue)
        }
    }

    private func assertCrashProjection(_ snapshot: CrashSnapshot, count: Int) throws {
        XCTAssertEqual(snapshot.hr.count, count)
        XCTAssertEqual(snapshot.rr.count, count * 2)
        XCTAssertEqual(snapshot.events.count, count)
        XCTAssertEqual(snapshot.debt.count, count)
        guard count == 1, snapshot.hr.count == 1, snapshot.rr.count == 2,
              snapshot.events.count == 1, snapshot.debt.count == 1 else { return }
        XCTAssertEqual(snapshot.hr[0]["deviceId"], device.databaseValue)
        XCTAssertEqual(snapshot.hr[0]["ts"], timestamp.databaseValue)
        XCTAssertEqual(snapshot.hr[0]["bpm"], 72.databaseValue)
        for (index, row) in snapshot.rr.enumerated() {
            XCTAssertEqual(row["deviceId"], device.databaseValue)
            XCTAssertEqual(row["ts"], timestamp.databaseValue)
            XCTAssertEqual(row["rrMs"], 1000.databaseValue)
            XCTAssertEqual(row["seq"], index.databaseValue)
            XCTAssertEqual(row["ord"], index.databaseValue)
            XCTAssertEqual(row["srcChannel"], DatabaseValue.null)
        }
        XCTAssertEqual(snapshot.events[0]["deviceId"], device.databaseValue)
        XCTAssertEqual(snapshot.events[0]["ts"], timestamp.databaseValue)
        XCTAssertEqual(snapshot.events[0]["kind"], StandardHRMapping.contactEventKind.databaseValue)
        XCTAssertEqual(snapshot.events[0]["payloadJSON"], "{\"contact\":\"supported_detected\"}".databaseValue)
        XCTAssertEqual(snapshot.debt[0]["kind"], "cloudPush".databaseValue)
        XCTAssertEqual(snapshot.debt[0]["attempts"], 0.databaseValue)
        let token = try XCTUnwrap(String.fromDatabaseValue(try XCTUnwrap(snapshot.debt[0]["token"])))
        XCTAssertNotNil(UUID(uuidString: token))
    }

    private func crash(_ boundary: String, expectedOriginals: Int, expectedBeforeRecovery: Int) async throws {
        let base = ProcessInfo.processInfo.environment["STANDARD_HR_CAPTURE_FIXTURES"]
            .map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("standard-hr-cold-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = CommandLine.arguments[0], path = directory.appendingPathComponent("capture.sqlite").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "only the producer may open the file before death")
        let status = try await Task.detached {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: executable)
            child.arguments = ["--capture-crash-child", boundary, path]
            try child.run(); child.waitUntilExit()
            return (child.terminationReason, child.terminationStatus)
        }.value
        XCTAssertEqual(status.0, .uncaughtSignal)
        XCTAssertEqual(status.1, SIGKILL)
        let settled: CrashSnapshot
        do {
            let store = try await WhoopStore(path: path)
            defer { try? store.registryWriter.close() }
            let before = try occurrences(store)
            XCTAssertEqual(before.count, expectedOriginals)
            XCTAssertEqual(before.filter { ($0["projectionState"] as Int) == 1 }.count, expectedBeforeRecovery)
            let original = try crashSnapshot(store)
            try assertCrashOriginals(original, count: expectedOriginals)
            try assertCrashProjection(original, count: expectedBeforeRecovery)
            let journal = try await prepare(store)
            let after = try occurrences(store)
            XCTAssertEqual(after.count, expectedOriginals)
            XCTAssertTrue(after.allSatisfy { ($0["rawBytes"] as Data) == Data(measurement) })
            XCTAssertTrue(after.allSatisfy { ($0["projectionState"] as Int) == 1 })
            await finish(journal)
            settled = try crashSnapshot(store)
            try assertCrashOriginals(settled, count: expectedOriginals)
            try assertCrashProjection(settled, count: expectedOriginals)
            XCTAssertEqual(settled.originals, original.originals, "all immutable bytes/identity survive recovery")
            XCTAssertEqual(settled.owner, original.owner)
            if expectedBeforeRecovery == expectedOriginals {
                XCTAssertEqual(settled, original, "completed work must not change canonical rows or debt tokens")
            }
            try store.registryWriter.close()
        }
        let reopened = try await WhoopStore(path: path)
        defer { try? reopened.registryWriter.close() }
        XCTAssertEqual(try crashSnapshot(reopened), settled, "fresh Store sees exactly the settled witnesses")
        let recovered = try await reopened.recoverStandardHRCapture(owner: owner())
        XCTAssertEqual(recovered, 0)
        XCTAssertEqual(try crashSnapshot(reopened), settled, "second recovery is a byte/token preserving no-op")
        let secondJournal = try await prepare(reopened)
        await finish(secondJournal)
        XCTAssertEqual(try crashSnapshot(reopened), settled, "new empty runtime does not revise old evidence")
        try reopened.registryWriter.close()
    }
    func testSIGKILLBeforeT1DoesNotClaimLocalDurability() async throws {
        try await crash("before-t1", expectedOriginals: 0, expectedBeforeRecovery: 0)
    }
    func testSIGKILLAfterT1RecoversExactOriginalAndPendingProjection() async throws {
        try await crash("after-t1", expectedOriginals: 1, expectedBeforeRecovery: 0)
    }
    func testSIGKILLAfterProjectionBeforeRAMSettlementPreservesCompletedOccurrence() async throws {
        try await crash("after-projection", expectedOriginals: 1, expectedBeforeRecovery: 1)
    }
    func testSIGKILLAfterT3AndSealRetainsOriginalWithoutPruneAuthority() async throws {
        try await crash("after-t3", expectedOriginals: 1, expectedBeforeRecovery: 1)
    }
    #endif
}
