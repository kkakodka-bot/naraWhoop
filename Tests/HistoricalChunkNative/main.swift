import Darwin
import Foundation
import GRDB
import WhoopProtocol
import WhoopStore

private struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw ProbeFailure(message) }
}

private let fixtureScope = DurableIngestScope(environment: "https://historical-fixture.invalid",
    accountID: "00000000-0000-4000-8000-000000000001", deviceID: "synthetic-strap")
private let fixtureRef = ClockRef(device: 100, wall: 100)
private let recoveryFrames: [[UInt8]] = [[1, 2], [1, 2], [3, 4]]
private let crashBoundaries = ["before-transaction", "before-cursor", "after-cursor", "before-commit",
    "after-commit-before-return", "before-ack-submission", "after-ack-submission", "before-att-completion", "after-att-completion"]

private func openStore(_ path: String) async throws -> WhoopStore {
    let store = try await WhoopStore(path: path)
    try await store.bindAccountOwner(projectURL: fixtureScope.environment!, userID: fixtureScope.accountID!)
    try await store.upsertDevice(id: fixtureScope.deviceID, mac: nil, name: nil)
    return store
}

private func researchRaw() -> HistoricalRawCapture {
    let frames: [[UInt8]] = [[9, 8], [7, 6]]
    return HistoricalRawCapture(meta: RawBatchMeta(batchId: "synthetic-research", deviceId: fixtureScope.deviceID,
        clockRef: fixtureRef, capturedAt: 101, startTs: 100, endTs: 101, frameCount: 2, byteSize: 4,
        captureScope: fixtureScope), frames: frames)
}

@discardableResult
private func commitFixture(_ store: WhoopStore) async throws -> BackfillInsertOutcome {
    try await store.commitHistoricalChunk(Streams(hr: [HRSample(ts: 100, bpm: 60)],
        steps: [StepSample(ts: 100, counter: 1)]), scope: fixtureScope, family: "whoop5",
        trim: 42, recoveryFrames: recoveryFrames, clockRef: fixtureRef,
        postOffloadJobKinds: ["rescore", "cloudPush"], rawCapture: researchRaw())
}

private struct Snapshot: Codable, Equatable {
    let rows: [String: Int]
    let cursor: Int?
    let integrity: String
    let synchronous: Int
    let journalMode: String
    let quarantineBytes: Int
    let quarantineRecords: Int
}

private func snapshot(_ store: WhoopStore) async throws -> Snapshot {
    let rows = try await store.registryWriter.read { db in
        var counts: [String: Int] = [:]
        for table in ["hrSample", "stepSample", "sensorQuarantine", "rawBatch", "ingestRawResource", "syncJob", "backfillFrontier", "quarantineArchiveMembership"] {
            counts[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
        return counts
    }
    let cursor = try await store.cursor("strap_trim:\(fixtureScope.key)")
    let accounting = try await store.registryWriter.read { db in
        guard let row = try Row.fetchOne(db, sql: "SELECT retainedBytes,retainedRecords FROM quarantineMaintenance WHERE singleton=1") else {
            throw ProbeFailure("Quarantine accounting is absent")
        }
        return (row["retainedBytes"] as Int,row["retainedRecords"] as Int)
    }
    let settings = try await store.registryWriter.writeWithoutTransaction { db in
        (try String.fetchOne(db, sql: "PRAGMA integrity_check") ?? "missing",
         try Int.fetchOne(db, sql: "PRAGMA synchronous") ?? -1,
         try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "missing")
    }
    return Snapshot(rows: rows, cursor: cursor, integrity: settings.0,
                    synchronous: settings.1, journalMode: settings.2,
                    quarantineBytes: accounting.0, quarantineRecords: accounting.1)
}

private func validateFixture(_ store: WhoopStore, committed: Bool) async throws -> Snapshot {
    let saved = try await snapshot(store)
    try require(saved.integrity == "ok", "SQLite integrity failed")
    try require(saved.synchronous == 2 && saved.journalMode == "wal", "Durability mode changed")
    if !committed {
        try require(saved.rows.values.allSatisfy { $0 == 0 }, "Partial chunk survived an uncommitted transaction")
        try require(saved.cursor == nil, "Cursor survived without committed rows")
        try require(saved.quarantineBytes == 0 && saved.quarantineRecords == 0, "Uncommitted accounting survived")
        return saved
    }
    try require(saved.rows["hrSample"] == 1 && saved.rows["stepSample"] == 1, "Committed sensor rows are missing")
    try require(saved.rows["sensorQuarantine"] == 3 && saved.rows["rawBatch"] == 4, "Committed raw evidence is missing")
    try require(saved.rows["ingestRawResource"] == 7 && saved.rows["syncJob"] == 2, "Committed ownership or debt is missing")
    try require(saved.cursor == 42, "Committed cursor is missing")
    try require(saved.rows["quarantineArchiveMembership"] == 3 && saved.quarantineBytes == 6 && saved.quarantineRecords == 3,
                "Committed quarantine membership/accounting is missing")
    let archived = try await store.pendingSensorQuarantine(scope: fixtureScope)
    var ordered: [Int: [UInt8]] = [:]
    for row in archived {
        let identity = QuarantineArchiveIdentity(recordID: row.id, family: row.family, trim: row.trim)
        guard let ordinal = identity.ordinal else { throw ProbeFailure("Quarantine membership lost its ordinal") }
        let raw = try await store.rawFrames(batchId: identity.batchID)
        try require(raw == [Array(row.frame)], "Recovery archive bytes changed")
        ordered[ordinal] = Array(row.frame)
    }
    try require((0..<3).compactMap { ordered[$0] } == recoveryFrames, "Recovery order or multiplicity changed")
    let research = try await store.rawFrames(batchId: "synthetic-research")
    try require(research == researchRaw().frames, "Research raw bytes changed")
    return saved
}

private func terminateAt(_ boundary: String) -> Never {
    print("HISTORICAL_FAULT \(boundary)")
    fflush(stdout)
    guard kill(getpid(), SIGKILL) == 0 else { _exit(90) }
    while true { _ = Darwin.pause() }
}

private final class CrashObserver: TransactionObserver {
    let boundary: String
    init(_ boundary: String) { self.boundary = boundary }
    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { false }
    func databaseDidChange(with event: DatabaseEvent) {}
    func databaseWillCommit() throws {
        if boundary == "before-commit" { terminateAt(boundary) }
    }
    func databaseDidCommit(_ db: Database) {
        if boundary == "after-commit-before-return" { terminateAt(boundary) }
    }
    func databaseDidRollback(_ db: Database) {}
}

private func appendWitness(_ value: String, to url: URL) throws {
    if !FileManager.default.fileExists(atPath: url.path) {
        try Data().write(to: url, options: .atomic)
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("\(value)\n".utf8))
    try handle.synchronize()
}

private func child(boundary: String, directory: URL) async throws {
    guard crashBoundaries.contains(boundary) else { throw ProbeFailure("Unknown child boundary") }
    let store = try await openStore(directory.appendingPathComponent("capture.sqlite").path)
    try await store.registryWriter.write { db in
        db.add(function: DatabaseFunction("historical_fault", argumentCount: 1) { values in
            let phase = String.fromDatabaseValue(values[0]) ?? "invalid"
            if boundary == phase { terminateAt(phase) }
            return 0
        })
        try db.execute(sql: """
            CREATE TEMP TRIGGER historical_before_cursor BEFORE INSERT ON cursors
            BEGIN SELECT historical_fault('before-cursor'); END;
            CREATE TEMP TRIGGER historical_after_cursor AFTER INSERT ON cursors
            BEGIN SELECT historical_fault('after-cursor'); END;
            """)
    }
    let observer = CrashObserver(boundary)
    store.registryWriter.add(transactionObserver: observer)
    if boundary == "before-transaction" { terminateAt(boundary) }
    try await commitFixture(store)
    store.registryWriter.remove(transactionObserver: observer)
    _ = try await validateFixture(store, committed: true)
    if boundary == "before-ack-submission" { terminateAt(boundary) }
    let witness = directory.appendingPathComponent("transport-witness.txt")
    try appendWitness("ack_submitted", to: witness)
    if boundary == "after-ack-submission" || boundary == "before-att-completion" { terminateAt(boundary) }
    try appendWitness("att_completed", to: witness)
    terminateAt("after-att-completion")
}

private struct CrashResult: Codable {
    let boundary: String
    let signal: Int32
    let beforeReplay: Snapshot
    let afterReplay: Snapshot
    let submittedWitnesses: Int
    let completedWitnesses: Int
}

private func runCrash(_ boundary: String, root: URL) async throws -> CrashResult {
    let directory = root.appendingPathComponent(boundary)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let executable = CommandLine.arguments[0]
    let result = try await Task.detached {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--child", boundary, directory.path]
        process.environment = ["PATH": "/usr/bin:/bin", "TMPDIR": root.path]
        try process.run()
        process.waitUntilExit()
        return (process.terminationReason, process.terminationStatus)
    }.value
    try require(result.0 == .uncaughtSignal && result.1 == SIGKILL, "Child did not stop by SIGKILL at \(boundary)")
    let path = directory.appendingPathComponent("capture.sqlite").path
    let store = try await WhoopStore(path: path)
    defer { try? store.registryWriter.close() }
    let committed = !["before-transaction", "before-cursor", "after-cursor", "before-commit"].contains(boundary)
    let before = try await validateFixture(store, committed: committed)
    let log = (try? String(contentsOf: directory.appendingPathComponent("transport-witness.txt"), encoding: .utf8)) ?? ""
    let submitted = log.split(separator: "\n").filter { $0 == "ack_submitted" }.count
    let completed = log.split(separator: "\n").filter { $0 == "att_completed" }.count
    try require(submitted == 0 || committed, "ACK was submitted without a durable chunk")
    try require(completed <= submitted && submitted <= 1, "Transport witness ordering failed")
    let previousJobs = try await store.owedJobs().map(\.token)
    try await commitFixture(store)
    let after = try await validateFixture(store, committed: true)
    if committed {
        let jobs = try await store.owedJobs().map(\.token)
        try require(before == after && jobs == previousJobs, "Committed replay changed source rows or debt tokens")
    }
    try await commitFixture(store)
    let second = try await validateFixture(store, committed: true)
    try require(second == after, "Second replay created logical duplicates")
    return CrashResult(boundary: boundary, signal: result.1, beforeReplay: before, afterReplay: after,
                       submittedWitnesses: submitted, completedWitnesses: completed)
}

private struct FullResult: Codable {
    let sqliteResultCode: Int32
    let beforeFailure: Snapshot
    let afterFailure: Snapshot
    let recoveredIntegrity: String
}

private func runFull(root: URL) async throws -> FullResult {
    let store = try await openStore(root.appendingPathComponent("sqlite-full.sqlite").path)
    defer { try? store.registryWriter.close() }
    let before = try await snapshot(store)
    try await store.registryWriter.writeWithoutTransaction { db in
        let pages = try Int.fetchOne(db, sql: "PRAGMA page_count")!
        try db.execute(sql: "PRAGMA max_page_count = \(pages)")
    }
    var code: Int32 = 0
    do {
        _ = try await store.commitHistoricalChunk(Streams(hr: [HRSample(ts: 100, bpm: 60)]),
            scope: fixtureScope, family: "whoop5", trim: 42,
            recoveryFrames: [[UInt8](repeating: 0xA5, count: 1_048_576)], clockRef: fixtureRef,
            postOffloadJobKinds: ["cloudPush"])
        throw ProbeFailure("SQLITE_FULL unexpectedly authorized ACK")
    } catch let error as DatabaseError {
        code = error.resultCode.rawValue
        try require(error.resultCode == .SQLITE_FULL, "Expected SQLITE_FULL at real SQLite write")
    }
    let after = try await snapshot(store)
    try require(before == after, "SQLITE_FULL left partial source, debt or cursor")
    try await store.registryWriter.writeWithoutTransaction { db in
        try db.execute(sql: "PRAGMA max_page_count = 2147483646")
    }
    try await commitFixture(store)
    let recovered = try await validateFixture(store, committed: true)
    return FullResult(sqliteResultCode: code, beforeFailure: before, afterFailure: after,
                      recoveredIntegrity: recovered.integrity)
}

private actor SimulatedTransfer {
    private(set) var transient = 0
    private(set) var terminal = 0
    private(set) var invalidReceipt = 0
    private(set) var verified = 0

    func step(store: WhoopStore, identity: RawResourceIdentity, iteration: Int) async throws {
        switch iteration % 5 {
        case 0, 1: transient += 1 // Synthetic offline/429/5xx leaves source untouched.
        case 2: terminal += 1 // Synthetic terminal HTTP outcome leaves source untouched.
        case 3:
            do {
                try await store.recordRawDurabilityReceipt(RawDurabilityReceipt(scope: fixtureScope,
                    lane: identity.lane, resourceKey: identity.resourceKey,
                    contentSHA256: String(repeating: "0", count: 64), objectKey: "synthetic/object",
                    receiptID: "invalid", verifiedAt: 1, retainUntil: 2))
                throw ProbeFailure("Mismatched receipt accepted")
            } catch DurableIngestError.invalidReceipt { invalidReceipt += 1 }
        default:
            try await store.recordRawDurabilityReceipt(RawDurabilityReceipt(scope: fixtureScope,
                lane: identity.lane, resourceKey: identity.resourceKey,
                contentSHA256: identity.contentSHA256, objectKey: "synthetic/object",
                receiptID: "verified", verifiedAt: 1, retainUntil: 2))
            verified += 1
        }
    }
}

private struct StressResult: Codable {
    let chunks: Int
    let duplicateReplays: Int
    let accountRevocations: Int
    let wrongOwnerRejections: Int
    let syntheticTransferOutcomes: [String: Int]
    let integrity: String
    let peakHostRSSBytes: Int64
    let durationSeconds: Double
}

private func runStress(root: URL, chunks: Int) async throws -> StressResult {
    let start = Date()
    let path = root.appendingPathComponent("stress.sqlite").path
    var store = try await openStore(path)
    var fence = StoreWriteFence()
    try await store.fenceWrites(untilRevoked: fence)
    try await commitFixture(store)
    guard let identity = try await store.rawResourceIdentity(scope: fixtureScope, lane: "rawBatch",
                                                            resourceKey: "synthetic-research") else {
        throw ProbeFailure("Stress fixture identity missing")
    }
    let transfer = SimulatedTransfer()
    var duplicateReplays = 0, accountRevocations = 0, wrongOwners = 0
    func commit(_ store: WhoopStore, _ index: Int, scope: DurableIngestScope = fixtureScope) async throws {
        _ = try await store.commitHistoricalChunk(Streams(hr: [HRSample(ts: 1_000 + index, bpm: 60)]),
            scope: scope, family: "whoop5", trim: UInt32(index + 100), recoveryFrames: [],
            clockRef: fixtureRef, postOffloadJobKinds: ["cloudPush"])
    }
    for index in 0..<chunks {
        if index > 0 && index % 257 == 0 {
            fence.invalidate()
            do { try await commit(store, index); throw ProbeFailure("Revoked runtime authorized commit") }
            catch StoreWriteFence.Failure.revoked { accountRevocations += 1 }
            try store.registryWriter.close()
            store = try await WhoopStore(path: path)
            fence = StoreWriteFence()
            try await store.fenceWrites(untilRevoked: fence)
        }
        if index % 113 == 0 {
            let wrong = DurableIngestScope(environment: fixtureScope.environment,
                accountID: "00000000-0000-4000-8000-000000000002", deviceID: fixtureScope.deviceID)
            do { try await commit(store, index, scope: wrong); throw ProbeFailure("Wrong owner authorized commit") }
            catch DurableIngestError.identityConflict { wrongOwners += 1 }
        }
        let currentStore = store
        async let transferStep: Void = transfer.step(store: currentStore, identity: identity, iteration: index)
        try await commit(currentStore, index)
        try await transferStep
        if index % 17 == 0 {
            let jobs = try await store.owedJobs().map(\.token)
            try await commit(store, index)
            let replayJobs = try await store.owedJobs().map(\.token)
            try require(jobs == replayJobs, "Duplicate stress chunk revised debt")
            duplicateReplays += 1
        }
    }
    let end = try await snapshot(store)
    try require(end.integrity == "ok", "Stress integrity failed")
    try require(end.rows["hrSample"] == chunks + 1, "Stress lost or duplicated sensor rows")
    try require(end.rows["rawBatch"] == 4 && end.rows["sensorQuarantine"] == 3, "Transfer chaos removed source bytes")
    try require(end.cursor == chunks + 99, "Stress cursor does not cover the last committed chunk")
    try store.registryWriter.close()
    let reopened = try await WhoopStore(path: path)
    let reopenedSnapshot = try await snapshot(reopened)
    try require(reopenedSnapshot == end, "Stress reopen changed durable state")
    try reopened.registryWriter.close()
    var usage = rusage()
    _ = getrusage(RUSAGE_SELF, &usage)
    return await StressResult(chunks: chunks, duplicateReplays: duplicateReplays,
        accountRevocations: accountRevocations, wrongOwnerRejections: wrongOwners,
        syntheticTransferOutcomes: ["transient_preserved": transfer.transient, "terminal_preserved": transfer.terminal,
            "invalid_receipt_rejected": transfer.invalidReceipt, "verified_receipt_recorded": transfer.verified],
        integrity: end.integrity, peakHostRSSBytes: Int64(usage.ru_maxrss),
        durationSeconds: Date().timeIntervalSince(start))
}

private struct Manifest: Encodable {
    let schemaVersion = 1
    let scope = "Synthetic macOS SQLite process-death and scripted transport witness; no CoreBluetooth, UIKit or network daemon"
    let sha: String
    let os: String
    let build = "native Debug production WhoopStore"
    let device = "host-only synthetic fixture"
    let ios = "NOT_MEASURED"
    let whoopFamily = "synthetic whoop5 tag; no strap"
    let firmware = "NOT_MEASURED"
    let network = "scripted outcomes; no remote requests"
    let thermal = "NOT_MEASURED"
    let lowPowerMode = "NOT_MEASURED"
    let physicalAcceptance = "NOT_MEASURED"
    let abruptPowerLoss = "NOT_MEASURED"
    let actualENOSPC = "NOT_MEASURED; SQLite SQLITE_FULL injected through max_page_count"
    let crashResults: [CrashResult]
    let sqliteFull: FullResult
    let stress: StressResult
}

@main
private struct HistoricalChunkNative {
    static func main() async {
        do {
            let args = CommandLine.arguments
            if args.count == 4 && args[1] == "--child" {
                try await child(boundary: args[2], directory: URL(fileURLWithPath: args[3]))
                throw ProbeFailure("Crash child returned")
            }
            guard args.count == 3, let chunks = Int(args[2]), chunks > 0 else {
                throw ProbeFailure("Usage: HistoricalChunkNative artifact-directory chunk-count")
            }
            let root = URL(fileURLWithPath: args[1], isDirectory: true)
            var crashes: [CrashResult] = []
            for boundary in crashBoundaries {
                crashes.append(try await runCrash(boundary, root: root))
                print("PASS process death and replay: \(boundary)")
            }
            let full = try await runFull(root: root)
            print("PASS real SQLITE_FULL rollback and replay")
            let stress = try await runStress(root: root, chunks: chunks)
            print("PASS \(chunks) chunks with bounded concurrent scripted transfer outcomes")
            let manifest = Manifest(sha: ProcessInfo.processInfo.environment["NARA_SOURCE_SHA"] ?? "unknown",
                os: ProcessInfo.processInfo.operatingSystemVersionString, crashResults: crashes,
                sqliteFull: full, stress: stress)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
        } catch {
            fputs("Historical native integrity failure: \(error)\n", stderr)
            exit(1)
        }
    }
}
