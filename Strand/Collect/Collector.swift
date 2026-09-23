import Foundation
import WhoopProtocol
import WhoopStore
import StrandAnalytics

extension UserDefaults {
    /// Raw capture defaults OFF (matches upstream NOOP). Set `enableRawCapture = true` in
    /// UserDefaults to opt in to persisting raw offload batches.
    var noopRawCaptureEnabled: Bool {
        if object(forKey: "enableRawCapture") == nil { return false }
        return bool(forKey: "enableRawCapture")
    }
}

/// The subset of WhoopStore the Collector needs. A protocol so tests can inject a spy
/// (WhoopStore is `final`). WhoopStore conforms via the extension below.
/// Not @MainActor — the WhoopStore actor's async methods satisfy the async requirements;
/// a @MainActor SpyStore in tests also conforms (async witnesses hop actors).
protocol StoreWriting: AnyObject {
    @discardableResult
    func insert(_ streams: Streams, deviceId: String) async throws
        -> (hr: Int, rr: Int, events: Int, battery: Int,
            spo2: Int, skinTemp: Int, resp: Int, gravity: Int)
    func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws
}
extension WhoopStore: StoreWriting {}

/// Cadence: flush after this many buffered frames OR this many seconds since the last
/// flush — whichever first. Also flushed explicitly on disconnect/foreground.
struct CollectorPolicy {
    var maxFrames: Int
    var maxInterval: TimeInterval
    /// Defensive cap on accepted frames, including pending failed writes. Generous default —
    /// ~4096 frames at ~60 bytes/frame is ~240KB, far beyond the handful seen pre-clock
    /// normally. Custom init keeps `.init(maxFrames:maxInterval:)` call sites compiling.
    var maxPreClockFrames: Int
    init(maxFrames: Int, maxInterval: TimeInterval, maxPreClockFrames: Int = 4096) {
        self.maxFrames = maxFrames
        self.maxInterval = maxInterval
        self.maxPreClockFrames = maxPreClockFrames
    }
    static let `default` = CollectorPolicy(maxFrames: 64, maxInterval: 0.2, maxPreClockFrames: 4096)
}

/// Buffers complete (reassembled) frames and periodically persists them:
/// parse → lossless extractStreams(clockRef) → one scoped decoded/raw/debt commit → clear buffer.
/// Exact raw frames remain in the existing receipt-gated outbox, including unknown decodes.
/// Unscoped compatibility stores retain their existing insert/enqueue seam.
@MainActor
final class Collector {
    private let store: StoreWriting
    /// Concrete store for prune + stats (the StoreWriting seam covers the hot insert/enqueue path;
    /// prune/stats are infrequent so a direct reference is clearer than widening the protocol).
    private let concreteStore: WhoopStore?
    private let imuStore: ImuSessionFileStore
    private let captureScope: DurableIngestScope?
    /// Device id new samples persist under. MUTABLE so a WHOOP↔WHOOP switch (BLEManager.setActiveDeviceId)
    /// re-attributes the next flush/standard-HR persist immediately, rather than freezing the id captured
    /// at construction. Single-WHOOP never switches, so this stays "my-whoop" exactly as a `let` would have.
    var deviceId: String
    private let policy: CollectorPolicy
    /// Research toggle. Missing-clock recovery still retains raw bytes even when this is off.
    private let enableRawCapture: Bool
    private let now: () -> Int
    private let monotonic: () -> TimeInterval

    /// Set once the GET_CLOCK correlation lands (E1). Until then, frames buffer un-persisted.
    var clockRef: ClockRef?
    /// Strap family for the LIVE decode path. WHOOP 4.0 (default) parses the 4.0 envelope; 5/MG
    /// parses the puffin envelope (records sit at +4 offsets). Set by BLEManager.configureCollector‐
    /// Family alongside an identity clockRef — 5/MG live timestamps are already real-unix seconds.
    var family: DeviceFamily = .whoop4
    /// On-demand bounded raw-capture window. ORs into the raw-persist gate so a "capture
    /// activity sample" action can persist raw even when `enableRawCapture` is off. The window's
    /// monotonic deadline auto-expires so a missed stop callback can't leak raw forever.
    private var rawCapture = RawCaptureWindow()
    /// #47: buffer the (raw frame, pre-parsed) pair. The raw bytes are still needed for the raw-capture
    /// outbox; the parse is the one the BLE seam already did, so `flush` doesn't re-decode the batch.
    private struct BufferedFrame {
        let frame: [UInt8]
        let parsed: ParsedFrame
        let deviceID: String
        let sessionID: String
        let family: DeviceFamily
        let clock: ClockRef?
        let capturedAt: Int
        let wantsRaw: Bool
    }
    private struct PendingLive {
        let batch: [BufferedFrame]
        let streams: Streams
        let meta: RawBatchMeta?
        let correlation: UUID
        var decodedCommitted = false
        var committedCounts: BankedCounts?
    }
    private var buffer: [BufferedFrame] = []
    private var bufferedWireBytes = 0
    private let maximumBufferedWireBytes = 8 * 1_048_576
    private var pendingLive: PendingLive?
    private var liveDrain: Task<Bool, Never>?
    private var standardDrain: Task<Bool, Never>?
    private var liveAllows: () -> Bool = { true }
    private var standardAllows: () -> Bool = { true }
    private var flushDeadline: Task<Void, Never>?
    private(set) var acceptingCapture = true
    private(set) var lastDrainSucceeded = true
    private(set) var lastWriteFailed = false
    private let onDurabilityFailure: (() -> Void)?
    /// #1118: strap-log sink for the per-transport R-R census. Optional and defaulted to nil so the
    /// test fakes that construct a Collector are untouched; `BLEManager` wires its own `log`.
    private let log: ((String) -> Void)?
    /// #1635: rows ACCEPTED per stream, handed up so `BLEManager` can tally them per LINK and say which
    /// streams banked when it writes the link epitaph. The counts already exist — `StreamStore.insert`
    /// returns them and the standard-HR path already binds them for its own trace line — so this carries
    /// a measurement that was being discarded, rather than taking a new one.
    private let onBanked: ((BankedCounts) -> Void)?
    /// #1118: last emit of each LIVE census line, unix seconds; 0 = never. Rate-limited — see
    /// `RrEmissionStats.shouldEmitLiveCensus`.
    ///
    /// Lifetime DIVERGES from the Kotlin twin. These reset whenever `BLEManager.bootstrapStore()`
    /// rebuilds the Collector (a store rebuild after unlock, among other paths), so a log can carry an
    /// extra line after one of those. Android keeps its stamps on the process-wide `WhoopBleClient`
    /// singleton, which a device switch mutates rather than rebuilds, so they never reset there.
    /// Harmless either way — a rate-limit on a diagnostic, not a measurement — but a reader comparing
    /// two logs should not have to work out why one has more lines than the other.
    ///
    /// @MainActor isolation makes these safe without a lock; the Kotlin fields are deliberately
    /// unsynchronized instead, since a stale read there costs one duplicate line.
    private var lastStdRrCensusSec: Int = 0
    private var lastRealtimeRrCensusSec: Int = 0

    /// Consecutive live-persist failures per transport, and when each last reported.
    ///
    /// Kept PER TRANSPORT because the standard 0x2A37 path and the puffin REALTIME_DATA path (#1118) fail
    /// independently — a shared counter would let one path's success reset the other's run and report a
    /// persistent failure as a string of first-failures. @MainActor isolation makes these safe without a
    /// lock; the Kotlin twin uses AtomicInteger because its two flushes can run concurrently on the io
    /// scope, and there the count is the load-bearing distinction between a transient and a run.
    private var stdInsertFailures = 0
    private var realtimeInsertFailures = 0
    private var lastStdInsertFailureLogMs: Int64 = 0
    private var lastRealtimeInsertFailureLogMs: Int64 = 0

    /// Standard 0x2A37 HR/RR/contact buffer — the reliable, always-on stream, recorded continuously
    /// (independent of the custom realtime stream or which screen is open).
    private var stdHR: [(deviceID: String, sample: HRSample)] = []
    private var stdRR: [(deviceID: String, sample: RRInterval)] = []
    private var stdReceipts: [(deviceID: String, row: StandardHRReceipt)] = []
    private var stdReceiptSessionId = UUID().uuidString.lowercased()
    private var stdReceiptOrdinal: Int64 = 0
    private var stdContact: [(deviceID: String, sample: WhoopEvent)] = []
    /// Last contact state buffered, so only transitions are recorded. See `shouldRecordContact`.
    private var lastStdContact: [String: StandardHRContact] = [:]
    private var batchStartedAt: TimeInterval
    var bufferedCount: Int { buffer.count + (pendingLive?.batch.count ?? 0) }

    /// The per-stream accepted-row counts `StreamStore.insert` returns, named so the closure that carries
    /// them is readable at both ends.
    typealias BankedCounts = (hr: Int, rr: Int, events: Int, battery: Int,
                              spo2: Int, skinTemp: Int, resp: Int, gravity: Int)

    init(store: StoreWriting, deviceId: String,
         policy: CollectorPolicy = .default,
         enableRawCapture: Bool = false,
         log: ((String) -> Void)? = nil,
         onBanked: ((BankedCounts) -> Void)? = nil,
         now: @escaping () -> Int = { Int(Date().timeIntervalSince1970) },
         monotonic: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate },
         imuStore: ImuSessionFileStore = .shared, captureScope: DurableIngestScope? = nil,
         onDurabilityFailure: (() -> Void)? = nil) {
        self.store = store; self.deviceId = deviceId; self.policy = policy
        self.imuStore = imuStore
        self.captureScope = captureScope
        self.onDurabilityFailure = onDurabilityFailure
        self.enableRawCapture = enableRawCapture
        self.log = log
        self.onBanked = onBanked
        self.now = now; self.monotonic = monotonic
        self.batchStartedAt = monotonic()
        self.concreteStore = store as? WhoopStore
    }

    /// Light storage summary for the UI. nil if there's no concrete store or the read throws.
    func storageStats() async -> (decodedRows: Int, rawBatches: Int, rawBytes: Int)? {
        guard let s = concreteStore else { return nil }
        return try? await s.storageStats()
    }

    /// Decoded history rows in a stable long-form CSV for arbitrary user-selected export windows.
    func historySensorsCSV(from: Int, to: Int) async -> Data {
        guard let store = concreteStore, from <= to else { return Data("stream,unix_s,v1,v2,v3,v4\n".utf8) }
        let limit = min(max(to - from + 1, 1) * 4, 1_000_000)
        async let hr = try? store.hrSamples(deviceId: deviceId, from: from, to: to, limit: limit)
        async let battery = try? store.batterySamples(deviceId: deviceId, from: from, to: to, limit: limit)
        async let spo2 = try? store.spo2Samples(deviceId: deviceId, from: from, to: to, limit: limit)
        async let temp = try? store.skinTempSamples(deviceId: deviceId, from: from, to: to, limit: limit)
        async let steps = try? store.stepSamples(deviceId: deviceId, from: from, to: to, limit: limit)
        async let resp = try? store.respSamples(deviceId: deviceId, from: from, to: to, limit: limit)
        async let gravity = try? store.gravitySamples(deviceId: deviceId, from: from, to: to, limit: limit)
        var lines = ["stream,unix_s,v1,v2,v3,v4"]
        lines += await (hr ?? []).map { "heart_rate,\($0.ts),\($0.bpm),,," }
        lines += await (battery ?? []).map { "battery,\($0.ts),\($0.soc.map { String($0) } ?? ""),\($0.mv.map { String($0) } ?? ""),," }
        lines += await (spo2 ?? []).map { "spo2_raw,\($0.ts),\($0.red),\($0.ir),," }
        lines += await (temp ?? []).map { "skin_temp_raw,\($0.ts),\($0.raw),\($0.aux1Raw.map { String($0) } ?? ""),\($0.aux2Raw.map { String($0) } ?? "")," }
        lines += await (steps ?? []).map { "steps,\($0.ts),\($0.counter),\($0.activityClass.map { String($0) } ?? ""),," }
        lines += await (resp ?? []).map { "resp_raw,\($0.ts),\($0.raw),,," }
        lines += await (gravity ?? []).map { "gravity,\($0.ts),\($0.x),\($0.y),\($0.z),\($0.dynAccel.map { String($0) } ?? "")" }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    /// Max persisted HR sample ts (the biometric "data frontier" for the stuck-strap watchdog).
    /// nil if there's no concrete store or nothing persisted yet. Mirrors storageStats().
    func latestHRSampleTs() async -> Int? {
        guard let s = concreteStore else { return nil }
        return try? await s.latestHRSampleTs(deviceId: deviceId)
    }

    /// Recent gravity samples for the inactivity reminder (#419): the strap's motion over `[from, to]`,
    /// the input to the shipped `SedentaryDetector`. Empty if there's no concrete store or the read
    /// throws. Mirrors latestHRSampleTs() — the BLE offload hook reads gravity through the Collector
    /// because the Collector owns the concrete store.
    func recentGravity(from: Int, to: Int, limit: Int = 100_000) async -> [GravitySample] {
        guard let s = concreteStore else { return [] }
        return (try? await s.gravitySamples(deviceId: deviceId, from: from, to: to, limit: limit)) ?? []
    }

    /// Apply the raw-retention policy. Returns rows pruned (0 if no concrete store).
    @discardableResult
    func prune() async -> Int {
        guard let s = concreteStore else { return 0 }
        let quarantine = (try? await s.pruneSensorQuarantine(now: now())) ?? 0
        return quarantine + ((try? await s.pruneRaw(now: now(),
                                keepWindowSeconds: PrunePolicy.keepWindowSeconds,
                                maxUnsyncedBytes: PrunePolicy.maxUnsyncedBytes)) ?? 0)
    }

    /// Parse-then-buffer shim (#47). Kept for callers/tests that pass raw bytes; the live seam calls
    /// `ingest(frame:parsed:)` with the parse it already did.
    @discardableResult
    func ingest(_ frame: [UInt8]) -> Bool {
        guard acceptingCapture else { return false }
        return ingest(frame: frame, parsed: parseFrame(frame, family: family))
    }

    /// Buffer one complete frame + its pre-parsed decode (synchronous: preserves delegate arrival order).
    /// Auto-flushes via a detached Task when the cadence threshold is hit (flush is async). (#47)
    @discardableResult
    func ingest(frame: [UInt8], parsed: ParsedFrame) -> Bool {
        guard acceptingCapture else { return false }
        SyncPipelineTrace.event(.receive)
        guard bufferedCount < max(1, policy.maxPreClockFrames),
              frame.count <= maximumBufferedWireBytes - bufferedWireBytes else {
            lastDrainSucceeded = false
            onDurabilityFailure?()
            return false
        }
        #if DEBUG
        assert(parsed == parseFrame(frame, family: family),
               "Collector.ingest: threaded ParsedFrame != fresh parse (#47 parse-once invariant)")
        #endif
        recordGroundTruthImu(frame)
        buffer.append(BufferedFrame(frame: frame, parsed: parsed, deviceID: deviceId, sessionID: stdReceiptSessionId,
            family: family, clock: clockRef, capturedAt: now(),
            wantsRaw: enableRawCapture || rawCapture.isActive(at: monotonic())))
        bufferedWireBytes += frame.count
        armFlushDeadline()
        // Missing clock is not permission to drop accepted frames: flush archives exact bytes
        // without inventing decoded timestamps. Memory pressure rejects NEW intake visibly.
        if buffer.count >= policy.maxFrames || bufferedWireBytes >= 256 * 1_024 ||
            (monotonic() - batchStartedAt) >= policy.maxInterval {
            Task { @MainActor in await self.flush() }
        }
        return true
    }

    /// Synchronous fence. Existing tasks retain this collector and its immutable old store.
    func shutdownForAccountChange() {
        acceptingCapture = false
        flushDeadline?.cancel()
        flushDeadline = nil
    }

    /// A deadline is armed by the first item, never postponed by later arrivals. It runs only
    /// while the OS grants execution; lifecycle drains and the durable outbox cover later wakes.
    private func armFlushDeadline(retrying: Bool = false) {
        guard acceptingCapture, flushDeadline == nil else { return }
        let seconds = retrying ? max(5, policy.maxInterval) : max(0.001, policy.maxInterval)
        flushDeadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            catch { return }
            guard let self else { return }
            let live = await self.flush()
            let standard = await self.flushStandardHR(reason: .cadence)
            self.flushDeadline = nil
            if self.bufferedCount > 0 || !self.stdHR.isEmpty || !self.stdRR.isEmpty ||
                !self.stdContact.isEmpty || !self.stdReceipts.isEmpty {
                self.armFlushDeadline(retrying: !live || !standard)
            }
        }
    }

    /// May be retried after failure; false means retained work still needs durable storage.
    @discardableResult
    func drainForShutdown() async -> Bool {
        shutdownForAccountChange()
        _ = await flush()
        // An earlier in-flight pass may have admitted only its original snapshot.
        let live = bufferedCount == 0 ? true : await flush()
        _ = await flushStandardHR()
        let standard = hasPendingCapture ? await flushStandardHR() : true
        lastDrainSucceeded = live && standard && !hasPendingCapture
        return lastDrainSucceeded
    }


    /// Join the single active drain, or start one. Accepted frames leave memory only after all
    /// required writes commit. New arrivals accumulate behind the immutable pending batch.
    @discardableResult
    func flush(maximumBatches: Int = 64, allowing: @escaping () -> Bool = { true }) async -> Bool {
        let previous = liveAllows, inherited = RetiredCaptureDrain.allowsWork
        liveAllows = { previous() && allowing() && (inherited?() ?? true) }
        if let liveDrain { return await liveDrain.value }
        let admittedCount = bufferedCount
        let task = Task { @MainActor in
            defer { self.liveDrain = nil; self.liveAllows = { true } }
            var remaining = admittedCount
            for _ in 0..<max(0, min(64, maximumBatches)) {
                guard remaining > 0 else { break }
                guard !Task.isCancelled, self.liveAllows(), self.prepareLiveBatch(maximumFrames: remaining),
                      let pending = self.pendingLive else { return false }
                guard await self.flushLiveBatch() else { return false }
                remaining -= pending.batch.count
            }
            return remaining == 0
        }
        liveDrain = task
        let result = await task.value
        lastDrainSucceeded = result
        return result
    }

    /// One finite wake services both independent lanes. A continuous custom stream cannot
    /// keep standard HR behind an until-empty loop. No new transaction starts after expiry.
    @discardableResult
    func drainOpportunity(allowing: @escaping () -> Bool) async -> Bool {
        guard allowing(), !Task.isCancelled else { return false }
        _ = await flushStandardHR(maximumBatches: 1, allowing: allowing)
        guard allowing(), !Task.isCancelled else { return !hasPendingCapture }
        _ = await flush(maximumBatches: 1, allowing: allowing)
        return !hasPendingCapture
    }

    var hasPendingCapture: Bool {
        bufferedCount > 0 || !stdHR.isEmpty || !stdRR.isEmpty || !stdContact.isEmpty || !stdReceipts.isEmpty
    }

    private func prepareLiveBatch(maximumFrames: Int) -> Bool {
        if pendingLive == nil {
            guard let first = buffer.first else { return true }
            let batch = Array(buffer.prefix {
                $0.deviceID == first.deviceID && $0.sessionID == first.sessionID && $0.family == first.family && $0.wantsRaw == first.wantsRaw
                    && $0.clock?.device == first.clock?.device && $0.clock?.wall == first.clock?.wall
            }.prefix(max(1, min(policy.maxFrames, maximumFrames))))
            let ref = first.clock ?? (first.deviceID == deviceId && first.sessionID == stdReceiptSessionId &&
                first.family == family ? clockRef : nil)
            let streams = ref.map { extractStreams(batch.map(\.parsed), deviceClockRef: $0.device, wallClockRef: $0.wall) } ?? Streams()
            let correlation = UUID()
            let frames = batch.map(\.frame)
            let meta: RawBatchMeta?
            do {
                if captureScope != nil || first.wantsRaw || ref == nil {
                    let bounds = try RawBatchMeta.captureBounds(streams: streams, fallbackTimestamp: first.capturedAt)
                    // Missing sensor time remains missing: Streams are empty above. The legacy
                    // archive header requires an anchor, so retain receipt identity only; kind 3
                    // rawBatch is excluded from waveform qualification on the server.
                    meta = RawBatchMeta(batchId: correlation.uuidString, deviceId: first.deviceID,
                        clockRef: ref ?? ClockRef(device: first.capturedAt, wall: first.capturedAt),
                        capturedAt: first.capturedAt, startTs: bounds.startTs, endTs: bounds.endTs,
                        frameCount: batch.count, byteSize: frames.reduce(0) { $0 + $1.count },
                        captureScope: captureScope?.forDevice(first.deviceID))
                } else { meta = nil }
            } catch {
                lastWriteFailed = true
                onDurabilityFailure?()
                return false
            }
            pendingLive = PendingLive(batch: batch, streams: streams, meta: meta, correlation: correlation)
            buffer.removeFirst(batch.count)
        }
        return true
    }

    private func flushLiveBatch() async -> Bool {
        guard let pending = pendingLive else { return true }
        let interval = SyncPipelineTrace.begin(.chunkPersistence, correlation: pending.correlation)
        var outcome: SyncPipelineTrace.Outcome = .failed
        defer { SyncPipelineTrace.end(interval, outcome: outcome) }
        // The immutable pending batch is selected before any await; its raw envelope and
        // decoded rows share one production transaction, with no intermediate durable gap.
        let deviceId = pending.batch[0].deviceID
        let frames = pending.batch.map(\.frame)
        let streams = pending.streams
        // #1118: the SECOND live transport. `flushStandardHR` stamps a beat at the second it arrived over
        // 0x2A37; this one stamps it from the strap's own record clock. The same beat reaching both lands
        // on two different seconds, which no same-second de-dup can collapse — the signature every
        // affected night prints as `crossSecondOverCount`.
        if !streams.rr.isEmpty {
            let nowSec = now()
            if RrEmissionStats.shouldEmitLiveCensus(lastEmitSec: lastRealtimeRrCensusSec, nowSec: nowSec) {
                lastRealtimeRrCensusSec = nowSec
                let census = RrEmissionStats.compute(streams.rr.map { (ts: $0.ts, rrMs: $0.rrMs) })
                log?(RrEmissionStats.logLine(path: "live-realtime", offered: streams.rr.count,
                                             inserted: nil, census))
            }
        }
        do {
            lastWriteFailed = false
            if !pending.decodedCommitted {
                let inserted: BankedCounts
                if let concreteStore, let captureScope, let meta = pending.meta {
                    inserted = try await concreteStore.commitLiveCapture(streams,
                        scope: captureScope.forDevice(deviceId),
                        rawCapture: HistoricalRawCapture(meta: meta, frames: frames),
                        note: "live raw and decoded rows committed").counts
                } else {
                    inserted = try await store.insert(streams, deviceId: deviceId)
                }
                realtimeInsertFailures = 0
                pendingLive?.decodedCommitted = true
                pendingLive?.committedCounts = inserted
            }
            if let meta = pending.meta, concreteStore == nil || captureScope == nil {
                let assembly = SyncPipelineTrace.begin(.uploadPreparation, correlation: pending.correlation)
                var assemblyOutcome: SyncPipelineTrace.Outcome = .failed
                defer { SyncPipelineTrace.end(assembly, outcome: assemblyOutcome) }
                try await store.enqueueRawBatch(meta, frames: frames)
                assemblyOutcome = .succeeded
            }
        } catch {
            lastWriteFailed = true
            // Retain the exact pending batch, metadata and decoded-commit state. A raw retry must
            // neither replay decoded inserts nor change its UUID/time bounds when the clock moves.
            // Swallowing this made the census above read like success: a store rejecting everything still
            // reported what was OFFERED, with nothing to say none of it landed.
            realtimeInsertFailures += 1
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            if LivePersistTrace.shouldEmitLiveInsertFailure(lastEmitMs: lastRealtimeInsertFailureLogMs,
                                                            nowMs: nowMs) {
                lastRealtimeInsertFailureLogMs = nowMs
                log?(LivePersistTrace.liveInsertFailedLine(
                    transport: "live-realtime", errorName: String(describing: type(of: error)),
                    message: error.localizedDescription, hrFrames: streams.hr.count,
                    rrFrames: streams.rr.count, consecutiveFailures: realtimeInsertFailures))
            }
            onDurabilityFailure?()
            return false
        }
        // Reset only after a successful insert so the interval trigger keeps firing if
        // inserts fail (batchStartedAt must NOT advance on a failed drain).
        batchStartedAt = monotonic()
        bufferedWireBytes -= frames.reduce(0) { $0 + $1.count }
        if acceptingCapture, let counts = pendingLive?.committedCounts { onBanked?(counts) }
        pendingLive = nil
        SyncPipelineTrace.event(.localCommit, correlation: pending.correlation)
        outcome = .succeeded
        return true
    }

    // MARK: - Standard 0x2A37 HR/RR (continuous recording)

    /// Start a new receipt identity namespace on reconnect. Buffered old-session receipts keep their
    /// original identities and can retry safely. A session is not a sensor continuity assertion.
    func beginStandardHRReceiptSession() {
        stdReceiptSessionId = UUID().uuidString.lowercased()
        stdReceiptOrdinal = 0
    }

    func ingestStandardHRReceipt(_ bytes: [UInt8], receivedUnixMs: Int64, receivedMonotonicNs: Int64) {
        guard acceptingCapture else { return }
        guard stdHR.count + stdRR.count + stdContact.count + stdReceipts.count < max(30, policy.maxPreClockFrames) else {
            lastDrainSucceeded = false
            onDurabilityFailure?()
            return
        }
        if let receipt = StandardHRReceipt.capture(bytes, sessionId: stdReceiptSessionId,
            notificationOrdinal: stdReceiptOrdinal, receivedUnixMs: receivedUnixMs,
            receivedMonotonicNs: receivedMonotonicNs) {
            stdReceipts.append((deviceId, receipt))
            armFlushDeadline()
        }
        if stdReceiptOrdinal == Int64.max { beginStandardHRReceiptSession() }
        else { stdReceiptOrdinal += 1 }
        if stdReceipts.count >= 30 { Task { @MainActor in await self.flushStandardHR(reason: .cadence) } }
    }

    /// Buffer one standard Heart-Rate-Measurement reading. No clock correlation needed —
    /// these carry a wall-clock `ts` directly. Auto-flushes ~every 30 readings (~30s).
    func ingestStandardHR(hr: Int, rr: [Int], contact: StandardHRContact? = nil,
                          family: DeviceFamily? = nil, at ts: Int) {
        guard acceptingCapture else { return }
        SyncPipelineTrace.freshness(.receive, sourceDate: Date(timeIntervalSince1970: TimeInterval(ts)))
        guard stdHR.count + stdRR.count + stdContact.count + stdReceipts.count + rr.count + 3 <= max(30, policy.maxPreClockFrames) else {
            lastDrainSucceeded = false
            onDurabilityFailure?()
            return
        }
        let acceptedHR = (30...220).contains(hr) ? 1 : 0
        let acceptedRR = rr.filter { (250...3000).contains($0) }
        if acceptedHR == 1 { stdHR.append((deviceId, HRSample(ts: ts, bpm: hr))) }
        let source: RRSourceChannel? = family == .whoop5 ? .whoop5Standard : nil
        stdRR.append(contentsOf: acceptedRR.map { (deviceId, RRInterval(ts: ts, rrMs: $0, srcChannel: source)) })
        // Only the CHANGES. Advanced here rather than at flush because the event travels in the buffer
        // until it persists: a failed insert re-inserts it at the front, so nothing has to be unwound.
        if let contact, StandardHRMapping.shouldRecordContact(previous: lastStdContact[deviceId], current: contact) {
            lastStdContact[deviceId] = contact
            stdContact.append(contentsOf: StandardHRMapping.samples(
                fromHR: hr, rr: [], contact: contact, at: ts
            ).events.map { (deviceId, $0) })
        }
        log?(LivePersistTrace.standardHRHostReceivedLine(
            hostUnixSeconds: ts,
            acceptedHRRows: acceptedHR, acceptedRRRows: acceptedRR.count,
            rejectedHRRows: 1 - acceptedHR, rejectedRRRows: rr.count - acceptedRR.count,
            pendingHRRows: stdHR.count, pendingRRRows: stdRR.count))
        armFlushDeadline()
        if stdHR.count + stdRR.count + stdContact.count >= 30 {
            Task { @MainActor in await self.flushStandardHR(reason: .cadence) }
        }
    }

    /// Persist the buffered standard HR/RR/contact. Re-buffers on failure so nothing is lost.
    @discardableResult
    func flushStandardHR(reason: LivePersistTrace.StandardHRFlushReason = .explicit,
                         maximumBatches: Int = 64, allowing: @escaping () -> Bool = { true }) async -> Bool {
        let previous = standardAllows, inherited = RetiredCaptureDrain.allowsWork
        standardAllows = { previous() && allowing() && (inherited?() ?? true) }
        if let standardDrain { return await standardDrain.value }
        // Capture device order before suspending. New arrivals belong to the next bounded pass.
        var devices: [String] = []
        for device in stdHR.map(\.deviceID) + stdRR.map(\.deviceID) + stdContact.map(\.deviceID) + stdReceipts.map(\.deviceID) {
            if !devices.contains(device) { devices.append(device) }
        }
        let batches = devices.map { device in
            (device: device, hr: stdHR.filter { $0.deviceID == device }.count,
             rr: stdRR.filter { $0.deviceID == device }.count,
             contact: stdContact.filter { $0.deviceID == device }.count,
             receipts: stdReceipts.filter { $0.deviceID == device }.count)
        }
        let task = Task { @MainActor in
            defer { self.standardDrain = nil; self.standardAllows = { true } }
            for batch in batches.prefix(max(0, min(64, maximumBatches))) {
                guard !Task.isCancelled, self.standardAllows() else { return false }
                guard await self.flushStandardBatch(deviceId: batch.device, hrCount: batch.hr, rrCount: batch.rr,
                    contactCount: batch.contact, receiptCount: batch.receipts, reason: reason) else { return false }
            }
            return devices.count <= max(0, min(64, maximumBatches))
        }
        standardDrain = task
        let result = await task.value
        lastDrainSucceeded = result
        return result
    }

    private func takeStandardPrefix<Element>(_ buffer: inout [Element], count: Int,
                                            matching: (Element) -> Bool) -> [Element] {
        var selected: [Element] = [], retained: [Element] = []
        for item in buffer {
            if selected.count < count, matching(item) { selected.append(item) }
            else { retained.append(item) }
        }
        buffer = retained
        return selected
    }

    private func flushStandardBatch(deviceId: String, hrCount: Int, rrCount: Int,
                                    contactCount: Int, receiptCount: Int,
                                    reason: LivePersistTrace.StandardHRFlushReason) async -> Bool {
        let interval = SyncPipelineTrace.begin(.chunkPersistence)
        var outcome: SyncPipelineTrace.Outcome = .failed
        defer { SyncPipelineTrace.end(interval, outcome: outcome) }
        let hr = takeStandardPrefix(&stdHR, count: hrCount) { $0.deviceID == deviceId }.map(\.sample)
        let rr = takeStandardPrefix(&stdRR, count: rrCount) { $0.deviceID == deviceId }.map(\.sample)
        let contact = takeStandardPrefix(&stdContact, count: contactCount) { $0.deviceID == deviceId }.map(\.sample)
        let receipts = takeStandardPrefix(&stdReceipts, count: receiptCount) { $0.deviceID == deviceId }.map(\.row)
        log?(LivePersistTrace.standardHRFlushAttemptLine(
            reason: reason, offeredHRRows: hr.count, offeredRRRows: rr.count))
        // #1118: census this batch BEFORE it is stored, exactly as the historical path does, so a strap
        // log carries one `ratioRep` per transport. If each transport reports ~1.0 while the stored night
        // reads 2.77, the over-count is the UNION of the transports and no single decoder is at fault —
        // which is the question this instrumentation exists to settle.
        if !rr.isEmpty {
            let nowSec = now()
            if RrEmissionStats.shouldEmitLiveCensus(lastEmitSec: lastStdRrCensusSec, nowSec: nowSec) {
                lastStdRrCensusSec = nowSec
                let census = RrEmissionStats.compute(rr.map { (ts: $0.ts, rrMs: $0.rrMs) })
                // `inserted` is NIL, not echoed from `offered`: the store's conflict key decides that and
                // this census runs before the insert. The line renders `inserted=n/a`.
                log?(RrEmissionStats.logLine(path: "live-standard", offered: rr.count,
                                             inserted: nil, census))
            }
        }
        do {
            lastWriteFailed = false
            let streams = Streams(hr: hr, rr: rr, events: contact, standardHrReceipts: receipts)
            let inserted: BankedCounts
            if let concreteStore, let captureScope {
                inserted = try await concreteStore.insertAndMarkJobsOwed(streams, deviceId: deviceId,
                    postOffloadJobKinds: ["cloudPush"], note: "standard HR rows committed",
                    captureScope: captureScope.forDevice(deviceId)).counts
            } else { inserted = try await store.insert(streams, deviceId: deviceId) }
            stdInsertFailures = 0
            SyncPipelineTrace.event(.localCommit)
            if acceptingCapture { onBanked?(inserted) }
            log?(LivePersistTrace.standardHRFlushSucceededLine(
                reason: reason, offeredHRRows: hr.count, offeredRRRows: rr.count,
                insertedHRRows: inserted.hr, insertedRRRows: inserted.rr))
            outcome = .succeeded
            return true
        } catch {
            lastWriteFailed = true
            stdHR.insert(contentsOf: hr.map { (deviceId, $0) }, at: 0)
            stdRR.insert(contentsOf: rr.map { (deviceId, $0) }, at: 0)
            stdContact.insert(contentsOf: contact.map { (deviceId, $0) }, at: 0)
            stdReceipts.insert(contentsOf: receipts.map { (deviceId, $0) }, at: 0)
            stdInsertFailures += 1
            log?(LivePersistTrace.standardHRRebufferedForRetryLine(
                reason: reason, attemptedHRRows: hr.count, attemptedRRRows: rr.count,
                pendingHRRows: stdHR.count, pendingRRRows: stdRR.count,
                consecutiveFailures: stdInsertFailures))
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            if LivePersistTrace.shouldEmitLiveInsertFailure(lastEmitMs: lastStdInsertFailureLogMs,
                                                            nowMs: nowMs) {
                lastStdInsertFailureLogMs = nowMs
                log?(LivePersistTrace.liveInsertFailedLine(
                    transport: "live-standard", errorName: String(describing: type(of: error)),
                    message: error.localizedDescription, hrFrames: hr.count, rrFrames: rr.count,
                    consecutiveFailures: stdInsertFailures))
            }
            onDurabilityFailure?()
            return false
        }
    }

    // MARK: - On-demand raw capture

    /// Open a bounded raw-capture window so the next flushes persist raw even with the global
    /// research toggle off. Auto-expires at the (clamped) monotonic deadline.
    func beginRawCapture(seconds: TimeInterval) {
        guard acceptingCapture else { return }
        rawCapture.open(at: monotonic(), duration: seconds)
    }

    @discardableResult
    func recordValidatedWhoop5Imu(_ frame: [UInt8], deviceId explicitDeviceId: String? = nil) -> Int {
        guard acceptingCapture else { return 0 }
        // `rawColumns` requires a complete WHOOP5 envelope, valid header/payload CRCs,
        // an evidenced carrier type, and the complete 100 x 6 shape. Corrupt or
        // unknown frames remain wire evidence but never enter interpreted storage.
        return imuStore.append(
            deviceId: explicitDeviceId ?? deviceId,
            frame: frame,
            receivedAtMs: Int64(Date().timeIntervalSince1970 * 1_000)
        )
    }

    private func recordGroundTruthImu(_ frame: [UInt8]) {
        _ = recordValidatedWhoop5Imu(frame)
    }

    /// Best-effort repair of already-archived history (FRWHOOP issue #1): scan this device's retained
    /// rawBatch rows, and route every CRC-valid 100 Hz IMU frame into any session window covering its
    /// strap timestamp. Returns the number of NEWLY queued one-second records (exact duplicates and
    /// conflicts count as 0 — the store's duplicate policy applies here too). Best-effort by design:
    /// rawBatch is size-capped transient working data, not canonical storage, so frames evicted before
    /// the repair runs are simply absent. The scan ignores each batch's meta startTs/endTs — those are
    /// capture-time wall-clock values, not the contained frames' strap timestamps.
    @discardableResult
    func repairImuSessionsFromRawArchive(imuStore override: ImuSessionFileStore? = nil,
        allowsWork: @escaping () -> Bool = { ResourceBudget.shared.permits(.rawBulk) }) async -> Int {
        let imuStore = override ?? self.imuStore
        let capturedDevice = deviceId
        let admitted = { self.acceptingCapture && self.deviceId == capturedDevice && !Task.isCancelled && allowsWork() }
        guard admitted(), let store = concreteStore, imuStore.hasWindows(deviceId: capturedDevice) else { return 0 }
        var repaired = 0
        var cursor: RawBatchMeta?
        while admitted(),
              let page = try? await store.rawBatchMetas(deviceId: capturedDevice, after: cursor, limit: 20),
              !page.isEmpty {
            for meta in page {
                guard admitted() else { return repaired }
                let frames = (try? await store.rawFrames(batchId: meta.batchId)) ?? []
                let receivedAtMs = Int64(meta.capturedAt) * 1_000
                for frame in frames {
                    guard admitted() else { return repaired }
                    if Whoop5RawImu.rawColumns(frame) != nil,
                       verifyFrame(frame, family: .whoop5).crc32OK == true {
                        repaired += imuStore.append(deviceId: capturedDevice, frame: frame, receivedAtMs: receivedAtMs)
                    }
                }
            }
            cursor = page.last
        }
        return repaired
    }

    /// Flush WHILE the window is still active so the just-captured frames get persisted as raw,
    /// THEN close the window.
    func endRawCapture() async {
        await flush()
        rawCapture.close()
    }
}
