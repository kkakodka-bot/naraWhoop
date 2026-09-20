import Foundation
import WhoopProtocol
import WhoopStore
import StrandAnalytics

/// Read-only offload session state for `BLEManager.exitBackfilling` (main actor).
struct BackfillSessionSnapshot: Sendable {
    let sessionRowsPersisted: Int
    let sessionMotionRows: Int
    let sessionSkinTempRows: Int
    let sessionNights: Int
    let sessionNightKeys: Set<Int>
    let sessionClockDevice: Int?
    let sessionClockWall: Int?
    let sessionUsedIdentityRef: Bool
    let sessionDroppedImplausible: Int
    let sessionDynAccel: Streams.DynAccelDiag
    let persistStalled: Bool
    let lastAckedTrim: UInt32?
    let family: DeviceFamily
    let phaseSamples: [BackfillChunkPhaseSample]
    let rrEmissionLine: String?
}

/// Main-actor callbacks the serial offload pipeline invokes (BLE writes, UI tallies, archives).
struct BackfillMainHooks: Sendable {
    let ackTrim: @Sendable (UInt32, [UInt8]) async -> Void
    let onBankedOffload: @Sendable ((hr: Int, rr: Int, events: Int, battery: Int,
                                    spo2: Int, skinTemp: Int, resp: Int, gravity: Int)) async -> Void
    let log: @Sendable (String) async -> Void
    let rejectedSink: @Sendable ([[UInt8]], UInt32, DeviceFamily) async -> Bool
    let onChunk: @Sendable (Bool, Bool) async -> Void
    let connectionActive: @Sendable () -> Bool
    let connectionLog: @Sendable (String) async -> Void
    let firmwareLayout: @Sendable (Int) async -> Void
    let onPersistCircuitBreak: @Sendable () async -> Void
    let onChunkCommitBegin: @Sendable () async -> Void
    let onChunkCommitAborted: @Sendable () async -> Void
    let onOffloadComplete: @Sendable () async -> Void
    /// Optional so existing injected hooks preserve their delivery behavior. Production uses a
    /// synchronous main-actor body: one batch cannot suspend between its ordered observations.
    var chunkInfo: (@MainActor @Sendable ([BackfillChunkInfo]) -> Void)? = nil
    var onQuarantined: @Sendable (Int) async -> Void = { _ in }
}

/// Thread-safe handoff for BLE notify-path frame yields into the actor pipeline.
private final class BackfillPipelineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<BackfillPipelineItem>.Continuation?
    private var currentSession: UUID?
    private var deliverySession: UUID?
    private var pendingFrames = 0
    private var pendingBytes = 0
    private let maxPendingBytes = 8 * 1_048_576

    func install(_ continuation: AsyncStream<BackfillPipelineItem>.Continuation) {
        lock.lock(); defer { lock.unlock() }
        self.continuation?.finish()
        self.continuation = continuation
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        continuation?.finish()
        continuation = nil
    }

    func reserve(_ sessionID: UUID) {
        lock.lock(); defer { lock.unlock() }
        currentSession = sessionID
    }

    func invalidate(_ sessionID: UUID?) {
        lock.lock(); defer { lock.unlock() }
        if sessionID == nil || currentSession == sessionID { currentSession = nil }
    }

    func isCurrent(_ sessionID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return currentSession == sessionID
    }

    var deliveryIsCurrent: Bool {
        lock.lock(); defer { lock.unlock() }
        return deliverySession != nil && deliverySession == currentSession
    }

    var currentID: UUID? {
        lock.lock(); defer { lock.unlock() }
        return currentSession
    }

    var hasQueuedFrames: Bool {
        lock.lock(); defer { lock.unlock() }
        return pendingFrames > 0
    }

    func setDelivery(_ sessionID: UUID?) {
        lock.lock(); defer { lock.unlock() }
        deliverySession = sessionID
    }

    func yieldFrame(_ frame: [UInt8], sessionID: UUID?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let currentSession, sessionID == nil || sessionID == currentSession,
              let continuation else { return false }
        guard pendingFrames < 16_384, frame.count <= maxPendingBytes - pendingBytes else {
            // Invalidate synchronously so an in-flight chunk cannot ACK after an overflow.
            self.currentSession = nil
            return false
        }
        pendingFrames += 1
        pendingBytes += frame.count
        continuation.yield(.frame(frame, sessionID: currentSession))
        return true
    }

    func consumedFrame(bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        pendingFrames -= 1
        pendingBytes -= bytes
    }

    @discardableResult
    func yield(_ item: BackfillPipelineItem) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let continuation else { return false }
        continuation.yield(item)
        return true
    }
}

private enum BackfillPipelineItem {
    case frame([UInt8], sessionID: UUID)
    case begin(family: DeviceFamily, continuedAfterRows: Bool, sessionID: UUID, done: CheckedContinuation<Bool, Never>)
    case timeout(sessionID: UUID?, done: CheckedContinuation<Void, Never>)
    case deviceID(String)
    case clockRef(ClockRef?)
    case oldest(Int?)
    case newest(Int?)
    case drain(CheckedContinuation<Void, Never>)
}

/// Serial offload pipeline: FIFO frame/control queue, chunk commits, and IMU session persistence off the main actor.
actor BackfillActor {
    private var backfiller: Backfiller?
    private let pipelineSink = BackfillPipelineSink()
    private var processingTask: Task<Void, Never>?
    private var onOffloadComplete: (() async -> Void)?
    /// False after `timeout` until the next `begin`; stray frames from a torn-down session are dropped.
    private var acceptingFrames = false
    /// True while `runLoop` is inside `ingest` (or between dequeue and loop exit for one frame).
    private var ingestInFlight = false
    private var activeSessionID: UUID?
    private var completedSnapshot: BackfillSessionSnapshot?

    func configure(store: BackfillStoreWriting,
                   deviceId: String,
                   hooks: BackfillMainHooks,
                   enableRawCapture: Bool,
                   postOffloadJobKinds: [String],
                   captureScope: DurableIngestScope? = nil,
                   imuStore: ImuSessionFileStore = .shared,
                   extract: @escaping Backfiller.Extractor = { extractHistoricalStreams($0, deviceClockRef: $1, wallClockRef: $2,
                                                                                         sessionOldestUnix: $3, sessionNewestUnix: $4,
                                                                                         subLagInterp: PuffinExperiment.ppgHrSubLagInterpEnabled) }) {
        let sink = pipelineSink
        let chunkInfoSink: (([BackfillChunkInfo]) async -> Void)?
        if let deliver = hooks.chunkInfo {
            chunkInfoSink = { events in
                guard sink.deliveryIsCurrent else { return }
                await MainActor.run {
                    guard sink.deliveryIsCurrent else { return }
                    deliver(events)
                }
            }
        } else {
            chunkInfoSink = nil
        }
        onOffloadComplete = {
            guard sink.deliveryIsCurrent else { return }
            await hooks.onOffloadComplete()
        }
        backfiller = Backfiller(
            store: store,
            deviceId: deviceId,
            ackTrim: { trim, endData in
                guard sink.deliveryIsCurrent else { return }
                await hooks.ackTrim(trim, endData)
            },
            onBankedOffload: { counts in
                guard sink.deliveryIsCurrent else { return }
                await hooks.onBankedOffload(counts)
            },
            enableRawCapture: enableRawCapture,
            log: { line in
                guard sink.deliveryIsCurrent else { return }
                await hooks.log(line)
            },
            rejectedSink: { frames, trim, family in
                guard sink.deliveryIsCurrent else { return false }
                return await hooks.rejectedSink(frames, trim, family)
            },
            imuSessionSink: { deviceId, records in
                guard sink.deliveryIsCurrent else { return false }
                return imuStore.persistHistoricalImu(deviceId: deviceId, records: records)
            },
            onChunk: { decoded, console in
                guard sink.deliveryIsCurrent else { return }
                await hooks.onChunk(decoded, console)
            },
            connectionActive: { sink.deliveryIsCurrent && hooks.connectionActive() },
            connectionLog: { line in
                guard sink.deliveryIsCurrent else { return }
                await hooks.connectionLog(line)
            },
            firmwareLayout: { version in
                guard sink.deliveryIsCurrent else { return }
                await hooks.firmwareLayout(version)
            },
            postOffloadJobKinds: postOffloadJobKinds,
            onPersistCircuitBreak: {
                guard sink.deliveryIsCurrent else { return }
                await hooks.onPersistCircuitBreak()
            },
            onChunkCommitBegin: {
                guard sink.deliveryIsCurrent else { return }
                await hooks.onChunkCommitBegin()
            },
            onChunkCommitAborted: {
                guard sink.deliveryIsCurrent else { return }
                await hooks.onChunkCommitAborted()
            },
            chunkInfo: chunkInfoSink,
            onQuarantined: { count in
                guard sink.deliveryIsCurrent else { return }
                await hooks.onQuarantined(count)
            },
            extract: extract)
        backfiller?.captureScope = captureScope
        let (stream, continuation) = AsyncStream<BackfillPipelineItem>.makeStream()
        pipelineSink.install(continuation)
        processingTask?.cancel()
        processingTask = Task { await self.runLoop(stream) }
    }

    /// Thread-safe frame handoff from the BLE notify path — no per-frame `Task`.
    @discardableResult
    nonisolated func yieldFrame(_ frame: [UInt8], sessionID: UUID? = nil) -> Bool {
        pipelineSink.yieldFrame(frame, sessionID: sessionID)
    }

    /// A barrier behind any suspended commit. Invalidation itself is synchronous at the call site.
    func drainAfterInvalidation() async {
        await withCheckedContinuation { done in
            if !pipelineSink.yield(.drain(done)) { done.resume() }
        }
    }

    /// Reserve synchronously with the manager's start admission, before its first await.
    nonisolated func reserveSession(_ sessionID: UUID) { pipelineSink.reserve(sessionID) }

    /// Immediately fences callbacks and queued frames, including an in-flight persistence operation.
    nonisolated func invalidateSession(_ sessionID: UUID? = nil) { pipelineSink.invalidate(sessionID) }

    /// Main-actor hook bodies recheck this after their actor hop, immediately before BLE/UI effects.
    nonisolated var deliverySessionIsCurrent: Bool { pipelineSink.deliveryIsCurrent }

    func setDeviceId(_ id: String) {
        pipelineSink.yield(.deviceID(id))
    }

    func setClockRef(_ ref: ClockRef?) {
        pipelineSink.yield(.clockRef(ref))
    }

    func setSessionOldestUnix(_ value: Int?) {
        pipelineSink.yield(.oldest(value))
    }

    func setSessionNewestUnix(_ value: Int?) {
        pipelineSink.yield(.newest(value))
    }

    /// Reset session state. Does not return until any in-flight ingest and prior queued items finish.
    @discardableResult
    func begin(family: DeviceFamily, continuedAfterRows: Bool, sessionID: UUID? = nil) async -> Bool {
        let id = sessionID ?? UUID()
        if sessionID == nil { pipelineSink.reserve(id) }
        guard pipelineSink.isCurrent(id) else { return false }
        return await withCheckedContinuation { done in
            if !pipelineSink.yield(.begin(family: family, continuedAfterRows: continuedAfterRows,
                                         sessionID: id, done: done)) { done.resume(returning: false) }
        }
    }

    /// Tear down backfiller state after the idle watchdog fires. Serialized behind any in-flight ingest.
    func timeoutFired(sessionID: UUID? = nil) async {
        let id = sessionID ?? pipelineSink.currentID
        pipelineSink.invalidate(id)
        await withCheckedContinuation { done in
            if !pipelineSink.yield(.timeout(sessionID: id, done: done)) { done.resume() }
        }
    }

    func isBackfilling() async -> Bool {
        acceptingFrames && activeSessionID.map(pipelineSink.isCurrent) == true
            && (backfiller?.isBackfilling ?? false)
    }

    func historyInFlight() -> Bool {
        ingestInFlight || pipelineSink.hasQueuedFrames
            || (acceptingFrames && activeSessionID.map(pipelineSink.isCurrent) == true)
    }

    func sessionSnapshot() -> BackfillSessionSnapshot? {
        // Ingest can be suspended in a store or callback while this actor serves the
        // watchdog. Publish only state captured after a complete pipeline item.
        completedSnapshot
    }

    private func captureSessionSnapshot() -> BackfillSessionSnapshot? {
        guard let bf = backfiller else { return nil }
        return BackfillSessionSnapshot(
            sessionRowsPersisted: bf.sessionRowsPersisted,
            sessionMotionRows: bf.sessionMotionRows,
            sessionSkinTempRows: bf.sessionSkinTempRows,
            sessionNights: bf.sessionNights,
            sessionNightKeys: bf.sessionNightKeys,
            sessionClockDevice: bf.sessionClockDevice,
            sessionClockWall: bf.sessionClockWall,
            sessionUsedIdentityRef: bf.sessionUsedIdentityRef,
            sessionDroppedImplausible: bf.sessionDroppedImplausible,
            sessionDynAccel: bf.sessionDynAccel,
            persistStalled: bf.persistStalled,
            lastAckedTrim: bf.lastAckedTrim,
            family: bf.family,
            phaseSamples: bf.sessionPhaseTimingSamples(),
            rrEmissionLine: bf.sessionRrEmissionLine())
    }

    private func runLoop(_ stream: AsyncStream<BackfillPipelineItem>) async {
        for await item in stream {
            switch item {
            case .begin(let family, let continuedAfterRows, let sessionID, let done):
                guard pipelineSink.isCurrent(sessionID) else { done.resume(returning: false); continue }
                activeSessionID = sessionID
                acceptingFrames = true
                backfiller?.begin(family: family, continuedAfterRows: continuedAfterRows)
                completedSnapshot = captureSessionSnapshot()
                done.resume(returning: true)
            case .timeout(let sessionID, let done):
                if sessionID == activeSessionID {
                    acceptingFrames = false
                    backfiller?.timeoutFired()
                    completedSnapshot = captureSessionSnapshot()
                }
                done.resume()
            case .deviceID(let id): backfiller?.deviceId = id
            case .clockRef(let ref): backfiller?.clockRef = ref
            case .oldest(let value): backfiller?.sessionOldestUnix = value
            case .newest(let value): backfiller?.sessionNewestUnix = value
            case .drain(let done):
                acceptingFrames = false
                backfiller?.timeoutFired()
                pipelineSink.finish()
                done.resume()
            case .frame(let frame, let sessionID):
                defer { pipelineSink.consumedFrame(bytes: frame.count) }
                guard acceptingFrames, activeSessionID == sessionID,
                      pipelineSink.isCurrent(sessionID) else { continue }
                pipelineSink.setDelivery(sessionID)
                ingestInFlight = true
                defer {
                    ingestInFlight = false
                    pipelineSink.setDelivery(nil)
                }
                guard let backfiller else { continue }
                await backfiller.ingest(frame)
                // Summaries scale with the session. Rebuild only after a chunk or
                // completion, not for each sensor record within the chunk.
                if backfiller.sessionPhaseTimingSamples().count != completedSnapshot?.phaseSamples.count
                    || !backfiller.isBackfilling {
                    completedSnapshot = captureSessionSnapshot()
                }
                if !backfiller.isBackfilling, pipelineSink.isCurrent(sessionID) {
                    acceptingFrames = false
                    await onOffloadComplete?()
                }
            }
        }
    }
}
