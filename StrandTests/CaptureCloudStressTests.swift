import XCTest
import GRDB
import NoopPush
import WhoopProtocol
import WhoopStore
@testable import Strand

/// Real FIFO, chunk transactions and durable upload queue; the radio, decoder values and HTTP
/// callback boundary are synthetic. This is not a daemon, hardware throughput or power-loss test.
final class CaptureCloudStressTests: XCTestCase {
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var decoded = 0
        private var acknowledgements = 0
        private var heat = 0
        private var barrier: XCTestExpectation?
        func nextRow() -> Int { lock.lock(); defer { lock.unlock() }; decoded += 1; return decoded }
        func ack() -> Int {
            lock.lock(); defer { lock.unlock() }; acknowledgements += 1; return acknowledgements
        }
        func completeBatch() {
            lock.lock(); let completed = acknowledgements.isMultiple(of: 100) ? barrier : nil
            if completed != nil { barrier = nil }
            lock.unlock(); completed?.fulfill()
        }
        func waitForBatch(_ expectation: XCTestExpectation) { lock.lock(); barrier = expectation; lock.unlock() }
        var ackCount: Int { lock.lock(); defer { lock.unlock() }; return acknowledgements }
        var thermal: Int { lock.lock(); defer { lock.unlock() }; return heat }
        func setThermal(_ value: Int) { lock.lock(); heat = value; lock.unlock() }
    }

    private final class Adapter: CloudUploadSessionAdapter, @unchecked Sendable {
        private let lock = NSLock()
        private var active: [Int: CloudUploadTaskSnapshot] = [:]
        private var created: [CloudUploadTaskSnapshot] = []
        var submissions: [CloudUploadTaskSnapshot] { lock.lock(); defer { lock.unlock() }; return created }
        func tasks() async -> [CloudUploadTaskSnapshot] { snapshot() }
        private func snapshot() -> [CloudUploadTaskSnapshot] { lock.lock(); defer { lock.unlock() }; return Array(active.values) }
        func create(request: URLRequest, file: URL, description: String) -> CloudUploadTaskSnapshot {
            lock.lock(); defer { lock.unlock() }
            let value = CloudUploadTaskSnapshot(identifier: created.count + 1, description: description)
            active[value.identifier] = value; created.append(value)
            return value
        }
        func resume(_ identifier: Int) {}
        func cancel(_ identifier: Int) { finish(identifier) }
        func finish(_ identifier: Int) { lock.lock(); active[identifier] = nil; lock.unlock() }
    }

    private final class Transactions: TransactionObserver, @unchecked Sendable {
        private let lock = NSLock()
        private var touched = false
        private var commits = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return commits }
        func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { eventKind.tableName == "hrSample" }
        func databaseDidChange(with event: DatabaseEvent) { touched = true }
        func databaseDidCommit(_ db: Database) {
            if touched { lock.lock(); commits += 1; lock.unlock() }
            touched = false
        }
        func databaseDidRollback(_ db: Database) { touched = false }
    }

    private func endFrame(_ trim: UInt32) -> [UInt8] {
        func le(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
        return frameFromPayload(le(1_700_000_100) + [0, 0] + le(0) + le(trim) + le(0), type: 49, seq: 0, cmd: 2)
    }

    func testTenThousandFIFOChunksRemainDurableDuringCloudCallbackAndNetworkChaos() async throws {
        let parent = ProcessInfo.processInfo.environment["NARA_TEST_FIXTURE_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let root = parent.appendingPathComponent("capture-cloud-chaos-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let context = AccountSessionContext(scope: try .init(projectURL: "https://chaos.invalid",
            userID: "11111111-1111-4111-8111-111111111111"), generation: UUID())
        let scope = DurableIngestScope(environment: context.scope.projectURL,
            accountID: context.scope.userID, deviceID: "synthetic-strap")
        let store = try await WhoopStore(path: root.appendingPathComponent("capture.sqlite").path)
        addTeardownBlock {
            try store.registryWriter.close()
            try FileManager.default.removeItem(at: root)
        }
        try await store.bindAccountOwner(projectURL: context.scope.projectURL, userID: context.scope.userID)
        try await store.upsertDevice(id: scope.deviceID, mac: nil, name: nil)
        let state = State(), transactions = Transactions()
        store.registryWriter.add(transactionObserver: transactions)
        addTeardownBlock { store.registryWriter.remove(transactionObserver: transactions) }
        let budget = ResourceBudget(cooldown: 0, thermal: { state.thermal }, lowPower: { false })
        let layout = AccountStorageLayout(baseDirectory: root, scope: context.scope)
        let journal = try CloudUploadJournal(directory: layout.uploadDirectory, resourceBudget: budget)
        addTeardownBlock { journal.close() }
        let endpoint = context.scope.projectURL + "/functions/v1/push"
        for index in 0..<8 {
            let batch = try PushProtocol.appendBatch(table: .battery,
                sourceId: "22222222-2222-4222-8222-222222222222", deviceId: scope.deviceID,
                startCursor: nil, records: [.init(rowId: Int64(index + 1), key: ["ts": .int(Int64(1_700_000_000 + index))],
                    data: ["soc": .int(50), "mv": .null, "charging": .null])])
            var job = CloudUploadJob(id: AccountScope.digest("chaos-\(index)"), owner: context.scope,
                generation: context.generation, endpoint: endpoint, deviceID: scope.deviceID,
                createdAt: Date(), operation: .request, method: "POST", headers: ["Content-Type": "application/x-ndjson"])
            job.batchID = batch.batchId
            try journal.persistBody(batch.body, job: &job)
            try journal.save(job)
        }
        let adapter = Adapter()
        let queue = try CloudUploadQueue(context: context, layout: layout, adapter: adapter,
            authorize: { _ in "synthetic" }, isCurrent: { $0 == context },
            policy: { .init(concurrency: budget.snapshot(for: .cloudTransfer).maximumTransfers,
                allowsCellular: false, allowsConstrained: false, cancelTransfers: state.thermal >= 3) },
            control: { _ in throw CloudUploadError.unavailable }, randomUnit: { 0.25 }, resourceBudget: budget)
        addTeardownBlock { await queue.suspend() }
        try await queue.reconcile()
        let inFlight = adapter.submissions
        XCTAssertEqual(inFlight.count, 2)
        let owner = UUID()
        budget.history(owner: owner, active: true)
        addTeardownBlock { budget.history(owner: owner, active: false) }
        let (checkpoints, checkpointSink) = AsyncStream<Int>.makeStream()
        let pipeline = BackfillActor()
        addTeardownBlock { checkpointSink.finish(); await pipeline.timeoutFired() }
        let hooks = BackfillMainHooks(ackTrim: { trim, _ in
            do {
                let saved = try await store.cursor("strap_trim:\(scope.key)")
                let exists = try await store.registryWriter.read { db in
                    try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM hrSample WHERE deviceId=? AND ts=?)",
                                      arguments: [scope.deviceID, 1_700_000_000 + Int(trim)]) ?? false
                }
                XCTAssertEqual(saved, Int(trim)); XCTAssertTrue(exists, "ACK preceded durable row")
                let count = state.ack()
                XCTAssertEqual(count, Int(trim), "FIFO ACK order changed")
                XCTAssertEqual(transactions.count, count, "ordinary chunk required another source durability commit")
                CaptureJobTrace.ackSubmission?.markSubmitted()
                if count.isMultiple(of: 100) { checkpointSink.yield(count) }
                state.completeBatch()
            } catch { XCTFail("Durable ACK check failed") }
        }, onBankedOffload: { _ in }, log: { _ in }, rejectedSink: { _, _, _ in true },
            onChunk: { _, _ in }, connectionActive: { false }, connectionLog: { _ in }, firmwareLayout: { _ in },
            onPersistCircuitBreak: { XCTFail("Unexpected capture circuit break") },
            onChunkCommitBegin: {}, onChunkCommitAborted: { XCTFail("Unexpected aborted commit") }, onOffloadComplete: {})
        await pipeline.configure(store: store, deviceId: scope.deviceID, hooks: hooks, enableRawCapture: false,
            postOffloadJobKinds: ["cloudPush"], captureScope: scope,
            extract: { _, _, _, _, _ in Streams(hr: [HRSample(ts: 1_700_000_000 + state.nextRow(), bpm: 60)]) })
        let began = await pipeline.begin(family: .whoop4, continuedAfterRows: false)
        XCTAssertTrue(began)
        let chaos = Task {
            var visits = 0
            for await count in checkpoints {
                visits += 1
                if count == 2_500 { state.setThermal(2) }
                if count == 5_000 { state.setThermal(3) }
                if count == 7_500 { state.setThermal(0) }
                budget.network(permitted: visits.isMultiple(of: 2))
                for (index, task) in inFlight.enumerated() {
                    adapter.finish(task.identifier)
                    // First outcomes are real retry events; later conflicting and out-of-order
                    // callbacks for those attempts must be ignored, including truncated success.
                    let status = visits == 1 ? (index == 0 ? 429 : 503) : [200, 400, 401, 408, 422][visits % 5]
                    await queue.receive(task, status: status, body: Data("{".utf8),
                                        error: visits.isMultiple(of: 7), retryAfter: "120")
                }
                try await queue.reconcile()
                XCTAssertEqual(adapter.submissions.count, 2, "new transfer admitted during history backlog")
                XCTAssertTrue(budget.permits(.localCommit)); XCTAssertTrue(budget.permits(.acknowledgement))
                XCTAssertFalse(budget.permits(.cloudPreparation))
            }
            return visits
        }
        addTeardownBlock { checkpointSink.finish(); chaos.cancel(); _ = try? await chaos.value }
        let record = frameFromPayload([0], type: 47, seq: 0, cmd: 0)
        for batch in 0..<100 {
            let finished = expectation(description: "bounded FIFO batch completes")
            state.waitForBatch(finished)
            for index in 1...100 {
                let trim = UInt32(batch * 100 + index)
                XCTAssertTrue(pipeline.yieldFrame(record)); XCTAssertTrue(pipeline.yieldFrame(endFrame(trim)))
            }
            await fulfillment(of: [finished], timeout: 20)
        }
        checkpointSink.finish()
        let visits = try await chaos.value
        XCTAssertEqual(visits, 100); XCTAssertEqual(state.ackCount, 10_000)
        XCTAssertEqual(transactions.count, 10_000)
        let source = try await store.registryWriter.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hrSample") ?? 0,
             try String.fetchOne(db, sql: "PRAGMA integrity_check") ?? "missing",
             try Int.fetchOne(db, sql: "PRAGMA synchronous") ?? -1)
        }
        XCTAssertEqual(source.0, 10_000); XCTAssertEqual(source.1, "ok"); XCTAssertEqual(source.2, 2)
        let saved = try journal.load()
        XCTAssertEqual(saved.count, 8)
        XCTAssertEqual(saved.values.filter { $0.failures == 1 }.count, 2, "one callback incremented failure twice")
        XCTAssertTrue(saved.values.allSatisfy { !$0.acknowledged && $0.validatedReceipt == nil })
        for job in saved.values {
            XCTAssertTrue(FileManager.default.fileExists(atPath: try journal.bodyURL(job).path))
        }
        let debt = try await store.owedJobs()
        XCTAssertTrue(debt.contains { $0.kind == "cloudPush" })
    }
}
