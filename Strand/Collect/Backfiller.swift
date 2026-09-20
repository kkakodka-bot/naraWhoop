import Foundation
import WhoopProtocol
import WhoopStore
import StrandAnalytics

// MARK: - BackfillStoreWriting protocol

/// The async subset the Backfiller needs. Plain async protocol (not @MainActor) so both the
/// real WhoopStore actor and a @MainActor SpyBackfillStore in tests can satisfy it.
protocol BackfillStoreWriting: AnyObject {
    @discardableResult
    func insert(_ streams: Streams, deviceId: String) async throws
        -> (hr: Int, rr: Int, events: Int, battery: Int,
            spo2: Int, skinTemp: Int, resp: Int, gravity: Int)
    /// Insert AND, when any scoring row actually landed, upsert the durable post-offload debts in the
    /// same transaction. Production `WhoopStore` implements this atomically (safe-trim invariant: a
    /// crash between rows and debt must roll both back so the unacked chunk replays). Test/replay
    /// stores use the non-atomic default below; nothing in production takes it.
    @discardableResult
    func insertAndMarkJobsOwed(_ streams: Streams, deviceId: String,
                               postOffloadJobKinds: [String],
                               note: String?) async throws -> BackfillInsertOutcome
    func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws
    func setCursor(_ name: String, _ value: Int) async throws
    func cursor(_ name: String) async throws -> Int?
    @discardableResult
    func markJobsOwed(kinds: [String], note: String?) async throws -> [String: String]
}

/// Test/replay stores do not own the app's post-offload pipeline. Production `WhoopStore` supplies
/// the durable atomic implementation; these defaults keep the narrow spy stores source-compatible.
extension BackfillStoreWriting {
    @discardableResult
    func insertAndMarkJobsOwed(_ streams: Streams, deviceId: String,
                               postOffloadJobKinds: [String],
                               note: String? = nil) async throws -> BackfillInsertOutcome {
        let counts = try await insert(streams, deviceId: deviceId)
        let tokens = try await markJobsOwed(kinds: postOffloadJobKinds, note: note)
        return BackfillInsertOutcome(counts: counts, markedJobs: !tokens.isEmpty)
    }

    @discardableResult
    func markJobsOwed(kinds: [String], note: String?) async throws -> [String: String] { [:] }
}

extension WhoopStore: BackfillStoreWriting {}

// MARK: - Offload chunk phase timing (T2-0)

/// One HISTORY_END handler sample, including time awaiting main-actor callbacks.
/// Excludes time queued before the handler and the subsequent BLE write confirmation.
struct BackfillChunkPhaseSample: Sendable {
    let frameCount: Int
    let gapMs: Int?
    let decodeMs: Int
    let insertMs: Int
    let rawMs: Int
    let imuMs: Int
    let ackMs: Int
    var totalMs: Int = 0
    var diagnosticsMs: Int = 0
    var archiveMs: Int = 0
    var cursorMs: Int = 0
}

/// Ordered observations for one chunk. They do not control durability or BLE acknowledgements.
enum BackfillChunkInfo: Sendable {
    case log(String)
    case connectionLog(String)
    case firmwareLayout(Int)
    case chunk(decoded: Bool, console: Bool)
    case banked(hr: Int, rr: Int, events: Int, battery: Int,
                spo2: Int, skinTemp: Int, resp: Int, gravity: Int)
}

// MARK: - Backfiller

/// Historical-offload state machine (idle / backfilling).
///
/// Per-chunk local safe-trim invariant:
///   decode known → await insert (decoded durable) →
///   await enqueueRawBatch (raw durable) →
///   await setCursor(strap_trim) →
///   ackTrim (submit a .withResponse acknowledgement)
///
/// Required decoded/raw writes complete before submitting the acknowledgement.
/// The BLE callback submits the write; it does not await link-layer confirmation.
/// Never waits on the server.
///
/// Runs on `BackfillActor` (off the main actor). BLE writes and UI tallies hop to the main actor via injected async closures.
final class Backfiller {
    /// (parsed frames, deviceClockRef, wallClockRef, sessionOldestUnix?, sessionNewestUnix?) → Streams.
    /// The trailing session-range markers are the strap's GET_DATA_RANGE oldest/newest for THIS sync
    /// (#547 session-relative gate); nil when the range isn't known yet (the absolute-only floor applies).
    typealias Extractor = ([ParsedFrame], Int, Int, Int?, Int?) -> Streams

    private let store: BackfillStoreWriting
    /// Device id offloaded chunks persist under. MUTABLE so a WHOOP↔WHOOP switch
    /// (BLEManager.setActiveDeviceId) re-attributes the next finishChunk persist immediately, rather
    /// than freezing the id captured at construction. Single-WHOOP never switches, so this stays
    /// "my-whoop" exactly as a `let` would have.
    var deviceId: String
    /// Confirms one HISTORY_END chunk to the strap. Carries both the trim cursor (= first u32
    /// of end_data, used for the `strap_trim` cursor) and the 8-byte `end_data` (= the raw
    /// HISTORY_END metadata.data[10:18]) that the high-freq-sync ack form requires verbatim.
    private let ackTrim: (_ trim: UInt32, _ endData: [UInt8]) async -> Void
    /// #1635: one offload chunk's accepted-row counts, handed up so `BLEManager` can tally them per LINK.
    /// The offload is the only path that banks gravity/resp/skinTemp/SpO2/steps, so a link summary
    /// without it cannot tell an unbonded strap — which defers backfill — from a healthy one.
    private let onBankedOffload: (_ counts: (hr: Int, rr: Int, events: Int, battery: Int,
                                             spo2: Int, skinTemp: Int, resp: Int, gravity: Int)) async -> Void
    private let extract: Extractor
    /// Research toggle. When false (DEFAULT) no raw frames are persisted — the chunk's
    /// decoded streams are still durable and the trim is still acked (decoded is the product of
    /// record). Injected for tests; backed by UserDefaults in the production init site.
    private let enableRawCapture: Bool

    /// The clock reference set by BLEManager when GET_CLOCK confirms (required for decoding).
    var clockRef: ClockRef?

    /// #547 SESSION-RELATIVE gate: the strap's own GET_DATA_RANGE oldest/newest banked-record markers for
    /// the CURRENT offload, set by BLEManager when the range reply lands. A record dated months outside this
    /// window is wandering-clock pollution even if it clears the absolute 2023-11 floor, so the ingest gate
    /// rejects it. nil (both) until the range is known — the gate then falls back to the absolute floor only,
    /// so behaviour is unchanged on the no-range / replay paths. Reset in `begin`.
    var sessionOldestUnix: Int?
    var sessionNewestUnix: Int?

    /// True while a historical offload session is active.
    private(set) var isBackfilling = false

    /// Buffered data frames for the current open chunk (between START and END).
    private var chunk: [[UInt8]] = []
    /// Whether a START has been received and we're accumulating a chunk.
    private var chunkOpen = false
    /// Strap family for the current offload, set at begin(). Drives family-aware frame parsing (WHOOP 5/MG
    /// records sit at +4 offsets vs WHOOP 4.0) and the end_data slice the ack needs. Captured at begin()
    /// rather than init so it's correct even if the Backfiller was constructed before the strap was known.
    private(set) var family: DeviceFamily = .whoop4

    /// Diagnostic sink (strap log). Surfaces historical records whose firmware layout we can't decode.
    private let log: ((String) async -> Void)?
    /// Versions already reported this session, so the diagnostic logs each once (no spam).
    private var loggedUnmappedVersions: Set<Int> = []

    /// Per-session persistence tally — the success-side observability the log forensics flagged as the
    /// blind spot (#150): we logged FAILURES (decoded-to-0) but never SUCCESSES, so a strap log couldn't
    /// tell a banking strap from a broken one. Reset at begin(); read by BLEManager at session end to emit
    /// #1008/#1118 PRE-STORAGE R-R census, accumulated across the session. `offered` is what the decoder
    /// handed over; `inserted` is what survived the store's ON CONFLICT key, so the gap is how much the
    /// primary key already absorbs. The per-second histogram sums per chunk, so a second split across two
    /// chunks is counted in both — a rounding artifact at chunk edges only, and the ratio below (exact
    /// sums over the exact span) is the number that decides emission-vs-ingest. Instrumentation only.
    private(set) var sessionRrOffered = 0
    private(set) var sessionRrInserted = 0
    private(set) var sessionRrSumMs = 0
    private(set) var sessionRrMinTs: Int?
    private(set) var sessionRrMaxTs: Int?
    private(set) var sessionRrHist = [0, 0, 0, 0]
    private(set) var sessionRrGapHist = [0, 0, 0, 0, 0, 0, 0, 0]
    private(set) var sessionRrFill = [0, 0, 0, 0]

    /// "persisted N rows (M with motion) across K night(s)". Nights are day-keys (ts / 86400).
    private(set) var sessionRowsPersisted = 0
    /// #42: set by `begin` when this session continues an auto-continue burst (#364) that already banked
    /// rows in an earlier session, so a trim=0xFFFFFFFF END here reads as "caught up", not "no history".
    /// Without it the fresh session's `sessionRowsPersisted` is 0 and the scary "charge to 100%" line
    /// false-fires on the empty tail of a sync that just offloaded real records.
    private(set) var continuedAfterRows = false
    /// #57: set true the moment ANY chunk's persist (decoded rows / reject archive / raw enqueue / trim
    /// cursor) fails this session. While set, `finishChunk` must NOT ack — not even a subsequent EMPTY END,
    /// which skips the insert and would otherwise advance the strap's trim PAST the held records-carrying
    /// chunks, freeing history we never stored. The offload stalls safely (strap keeps everything past the
    /// last GOOD ack); a fresh session (`begin`) clears it. Twin of the Android guard. Exposed read-only so
    /// the client can surface a "history isn't persisting" signal in the debug export (#57).
    private(set) var persistStalled = false
    private(set) var sessionMotionRows = 0
    /// #727: skin-temp samples banked this session. WHOOP 4.0 carries skin temp (and the raw SpO2 channel)
    /// ONLY in its full DSP sleep records; a strap banking HR/RR-only records reports 0 here even on a
    /// healthy-looking sync, so surfacing it makes "skin temp never appears" reports self-diagnosing.
    private(set) var sessionSkinTempRows = 0
    private(set) var sessionNightKeys: Set<Int> = []
    var sessionNights: Int { sessionNightKeys.count }

    /// #67 diag: the clock reference the offload ACTUALLY decoded with, captured on the first chunk of the
    /// session. Surfaces whether the stale-RTC timestamp correction (FIX #72's `correctedWall`) could even
    /// engage. `sessionUsedIdentityRef` = no clock correlation had landed when the first chunk decoded, so
    /// that decode fell back to an identity
    /// ref (device==wall==now) → clock offset 0 → correction OFF. On a WHOOP 4.0 whose RTC has reset, that
    /// silently stores the strap's stale (years-old) timestamps verbatim, so the night lands off the recent
    /// timeline and reads as "missed sleep". Paired with the persisted-nights DATE RANGE below, one strap
    /// log now shows both WHERE the rows landed and WHY. Reset in begin(). Log-only.
    ///
    /// #1598: read this WITH the family — it is family-agnostic on purpose (it records what the decode did),
    /// so it is `true` on EVERY 5/MG session, where identity is the correct ref rather than a fallback.
    /// `sessionClockDiagLine` is what applies that judgement; don't treat this flag alone as a fault.
    private(set) var sessionClockDevice: Int?
    private(set) var sessionClockWall: Int?
    private(set) var sessionUsedIdentityRef = false
    /// #1008: 1-based chunk counter for the per-chunk `hist clock` diag line, so a strap log can be read
    /// as a trajectory across one offload. Reset per session alongside the clock ref above.
    private var chunkIndex = 0
    /// Logged once per session when the strap reports trim=0xFFFFFFFF — the "no valid flash cursor"
    /// sentinel: it has no banked history to offload (a clock/charge state, not a decode bug).
    private var loggedNoCursor = false
    /// #773: logged once per session the first time a HISTORY_END's own timestamp is dated implausibly far
    /// in the FUTURE (a corrupt strap RTC). Distinct from #547's per-record drop tally: this fires on the
    /// chunk metadata's own clock, the earliest visible tell that the strap's RTC is bogus. Reset in begin().
    private var loggedFutureRtc = false

    /// #547: running count of historical records DROPPED this session for an implausible own-timestamp
    /// (a bad-clock strap — far-past / bogus-2027 / future-dated). Tallied across chunks and surfaced once
    /// at a session boundary so a clock-broken strap is visible in the strap log (observability only — the
    /// ingest gate already kept the garbage rows out of the DB).
    private(set) var sessionDroppedImplausible = 0

    /// #891 diagnostic: packet types this session's offload carried that the decoder has no rows for,
    /// folded across chunks. Each type is logged the FIRST time it appears — a 30k-record offload must not
    /// emit 30k lines — and the running total is what a later line can report. See
    /// `Streams.unhandledPacketTypes` for why this is not derivable from anything already logged: an
    /// unmapped type is dropped by the decoder AND excluded from the reject archive, so today it is
    /// invisible and the sync reports clean.
    private(set) var sessionUnhandledPacketTypes: [String: Int] = [:]

    /// #520 diagnostic: `dynamic_acceleration` folded across every chunk of this session, logged once at
    /// the session boundary. Session-scoped rather than per-chunk because a chunk is an arbitrary slice of
    /// an offload — a still-fraction only means something over a whole night's worth of records.
    private(set) var sessionDynAccel = Streams.DynAccelDiag()

    /// The trim cursor of the LAST chunk this Backfiller acked (durably persisted + confirmed to the
    /// strap). Survives across sessions on the same connection so the auto-continue gate (#364) can ask
    /// "did the offload actually advance the strap's trim this session?" — the spin-detector signal that
    /// stops it re-kicking forever when the cursor is frozen. nil until the first ack. NOT reset in
    /// `begin()` (it's a cross-session high-water mark, not a per-session tally).
    private(set) var lastAckedTrim: UInt32?

    /// Distinct historical layout versions logged this session. Unlike `loggedUnmappedVersions` (which
    /// only fires for layouts NOOP can't decode), this surfaces the layout on a HEALTHY sync too, so a
    /// shared strap log always reveals what the strap emits (v18/v24/v25/v26). Mirrors the Android
    /// Backfiller (PR #241, ryanbr); reset per session in `begin`.
    private var loggedLayoutVersions: Set<Int> = []

    /// SpO2 RE dump (PR #945, reimplemented): how many full-record dumps this session emitted, bounded by
    /// `Spo2ReTrace.maxSamples`. Session-scoped so the cap spans chunks; reset per session in `begin`.
    private var spo2Dumped = 0

    /// T2-0: per-chunk wall-clock samples for offload latency forensics. Each sample covers ONE
    /// `finishChunk` invocation (one HISTORY_END). Total includes callback/actor waits;
    /// queue wait before this handler and the subsequent BLE confirmation remain outside it.
    private var chunkPhaseSamples: [BackfillChunkPhaseSample] = []
    private var lastChunkArrival: CFAbsoluteTime?

    /// Durably archives undecodable record frames BEFORE the trim ack (#77 / #91). Returns true once
    /// the bytes are safe (written OR cap-reached — either way the chunk may be acked) and false on a
    /// genuine write failure, in which case `finishChunk` holds the cursor/ack so the strap re-sends.
    /// nil in non-production inits (tests/preview) → archiving is skipped and acks proceed as before.
    private let rejectedSink: ((_ frames: [[UInt8]], _ trim: UInt32, _ family: DeviceFamily) async -> Bool)?
    /// Session-IMU durability seam (FRWHOOP issue #1): receives the chunk's CRC-valid decoded 100 Hz IMU
    /// records at commit time and returns true iff every record that matched a registered Raw Data
    /// Collector window is durably on disk. nil (tests / non-prod inits) skips the seam entirely.
    /// A false return stalls the ack exactly like a decoded-insert failure (#57): the strap keeps
    /// and re-sends the chunk rather than trimming past session data we never persisted.
    private let imuSessionSink: ((_ deviceId: String, _ records: [(baseTs: Int, columns: [Int16])]) -> Bool)?
    /// Per-chunk outcome hook (#77 family): (didDecodeSensorRows, wasConsoleOnly). Lets BLEManager
    /// tally a session so a COMPLETED-but-empty offload (all console, no sensor records) can tell the
    /// user their strap isn't banking, without false-positiving a normal caught-up sync.
    private let onChunk: ((_ decoded: Bool, _ console: Bool) async -> Void)?

    /// Connection & Sync test mode (Test Centre): the cheap gate + tagged sink for the .connection
    /// diagnostic lines (offload progress / firmware layout / trim sentinel). `connectionActive` is one
    /// UserDefaults bool read; we ALWAYS check it BEFORE building any connection line, so the Backfiller
    /// pays nothing when the mode is off. `connectionLog` appends the already-built line tagged .connection.
    /// Both default inert (always-off / nil) so tests + non-prod inits get the byte-identical untraced path.
    private let connectionActive: () -> Bool
    private let connectionLog: ((String) async -> Void)?
    /// UNIVERSAL clock-drift wiring (RTC cluster): banks the strap's historical record-layout version
    /// (hist_version) onto LiveState so the export assembler's universal clock-drift line is firmware-aware
    /// on EVERY export, not only in Connection mode. Called UNCONDITIONALLY (it is observability, not gated)
    /// once per distinct layout this session. Default nil (inert) so tests / non-prod inits are untouched.
    private let firmwareLayout: ((Int) async -> Void)?
    /// Durable post-offload work to stamp after a chunk inserts new biometric rows and before trim ack.
    /// Raw string values keep this state machine independent of app-only scheduling types.
    private let postOffloadJobKinds: [String]
    /// T2-4: invoked after three consecutive chunk persist failures; must abort the offload session.
    private let onPersistCircuitBreak: (() async -> Void)?
    /// Idle-watchdog pause while decode + persist + IMU flush run (strap waits on our ack).
    private let onChunkCommitBegin: (() async -> Void)?
    /// Resume idle watchdog when a commit ends without ack (persist held).
    private let onChunkCommitAborted: (() async -> Void)?
    /// Production delivers ordered observations in one awaited main-actor hop. Legacy callback
    /// injection remains available for tests and replay clients; no observations are detached.
    private let chunkInfo: (([BackfillChunkInfo]) async -> Void)?
    /// T2-4: consecutive chunk commits that failed before ack (insert / archive / raw / imu / cursor).
    private var consecutivePersistFailures = 0

    init(store: BackfillStoreWriting,
         deviceId: String,
         ackTrim: @escaping (_ trim: UInt32, _ endData: [UInt8]) async -> Void,
         onBankedOffload: @escaping (_ counts: (hr: Int, rr: Int, events: Int, battery: Int,
                                                spo2: Int, skinTemp: Int, resp: Int,
                                                gravity: Int)) async -> Void = { _ in },
         enableRawCapture: Bool = false,
         log: ((String) async -> Void)? = nil,
         rejectedSink: ((_ frames: [[UInt8]], _ trim: UInt32, _ family: DeviceFamily) async -> Bool)? = nil,
         imuSessionSink: ((_ deviceId: String, _ records: [(baseTs: Int, columns: [Int16])]) -> Bool)? = nil,
         onChunk: ((_ decoded: Bool, _ console: Bool) async -> Void)? = nil,
         connectionActive: @escaping () -> Bool = { false },
         connectionLog: ((String) async -> Void)? = nil,
         firmwareLayout: ((Int) async -> Void)? = nil,
         postOffloadJobKinds: [String] = [SyncJobKind.rescore.rawValue],
         onPersistCircuitBreak: (() async -> Void)? = nil,
         onChunkCommitBegin: (() async -> Void)? = nil,
         onChunkCommitAborted: (() async -> Void)? = nil,
         chunkInfo: (([BackfillChunkInfo]) async -> Void)? = nil,
         // The default (prod) Extractor reads the opt-in HR-from-PPG sub-lag interpolation flag (Test Centre →
         // Experimental algorithms) at decode time and threads it into the pure decoder, so the pure package
         // never reaches for UserDefaults. Default OFF = byte-identical to today. Tests inject their own seam.
         extract: @escaping Extractor = { extractHistoricalStreams($0, deviceClockRef: $1, wallClockRef: $2,
                                                                    sessionOldestUnix: $3, sessionNewestUnix: $4,
                                                                    subLagInterp: PuffinExperiment.ppgHrSubLagInterpEnabled) }) {
        self.store = store
        self.deviceId = deviceId
        self.ackTrim = ackTrim
        self.onBankedOffload = onBankedOffload
        self.enableRawCapture = enableRawCapture
        self.log = log
        self.rejectedSink = rejectedSink
        self.imuSessionSink = imuSessionSink
        self.onChunk = onChunk
        self.connectionActive = connectionActive
        self.connectionLog = connectionLog
        self.firmwareLayout = firmwareLayout
        self.postOffloadJobKinds = postOffloadJobKinds
        self.onPersistCircuitBreak = onPersistCircuitBreak
        self.onChunkCommitBegin = onChunkCommitBegin
        self.onChunkCommitAborted = onChunkCommitAborted
        self.chunkInfo = chunkInfo
        self.extract = extract
    }

    /// T2-4: record a chunk commit failure; abort the session after three consecutive failures.
    private func notePersistFailure(trim: UInt32, reason: String) async {
        consecutivePersistFailures += 1
        if consecutivePersistFailures >= 3 {
            await log?("Backfill: persist failed \(consecutivePersistFailures) consecutive chunk(s) (last trim=\(trim), \(reason)) — aborting offload session to stop unbounded decode CPU; no acks sent past the last good trim (#57).")
            isBackfilling = false
            chunkOpen = false
            chunk.removeAll(keepingCapacity: true)
            await onPersistCircuitBreak?()
        }
    }

    private func notePersistSuccess() {
        consecutivePersistFailures = 0
    }

    private func deliverChunkInfo(_ events: [BackfillChunkInfo]) async {
        if let chunkInfo {
            await chunkInfo(events)
            return
        }
        for event in events {
            switch event {
            case .log(let line): await log?(line)
            case .connectionLog(let line): await connectionLog?(line)
            case .firmwareLayout(let version): await firmwareLayout?(version)
            case .chunk(let decoded, let console): await onChunk?(decoded, console)
            case .banked(let hr, let rr, let events, let battery, let spo2, let skinTemp, let resp, let gravity):
                await onBankedOffload((hr, rr, events, battery, spo2, skinTemp, resp, gravity))
            }
        }
    }

    /// Emit one Connection & Sync test-mode line iff the mode is on. The cheap `connectionActive()` gate is
    /// checked BEFORE `build()` runs, so the line string is never constructed when the mode is off (the
    /// @autoclosure defers it). Diagnostic only - it never changes the offload path.
    private func emitConnection(_ build: @autoclosure () -> String) async {
        guard connectionActive(), let connectionLog else { return }
        await connectionLog(build())
    }

    /// Called by BLEManager when the strap signals a historical offload is beginning.
    /// chunkOpen starts TRUE: the high-freq-sync biometric replay streams records immediately and
    /// sends one HISTORY_START then repeated HISTORY_ENDs, so we must accumulate from the outset.
    func begin(family: DeviceFamily, continuedAfterRows: Bool = false) {
        self.family = family
        self.continuedAfterRows = continuedAfterRows
        isBackfilling = true
        persistStalled = false   // #57: fresh session starts un-stalled
        consecutivePersistFailures = 0
        chunk.removeAll(keepingCapacity: true)
        chunkOpen = true
        sessionRowsPersisted = 0
        sessionRrOffered = 0
        sessionRrInserted = 0
        sessionRrSumMs = 0
        sessionRrMinTs = nil
        sessionRrMaxTs = nil
        sessionRrHist = [0, 0, 0, 0]
        sessionRrGapHist = [0, 0, 0, 0, 0, 0, 0, 0]
        sessionRrFill = [0, 0, 0, 0]
        sessionMotionRows = 0
        sessionSkinTempRows = 0
        sessionNightKeys.removeAll(keepingCapacity: true)
        sessionClockDevice = nil          // #67: re-capture the decode clock ref for this session
        sessionClockWall = nil
        sessionUsedIdentityRef = false
        chunkIndex = 0
        loggedNoCursor = false
        loggedFutureRtc = false
        sessionDroppedImplausible = 0
        sessionUnhandledPacketTypes = [:]   // #891: a second offload must re-log its first sighting
        sessionDynAccel = Streams.DynAccelDiag()
        loggedLayoutVersions.removeAll(keepingCapacity: true)
        spo2Dumped = 0
        chunkPhaseSamples.removeAll(keepingCapacity: true)
        lastChunkArrival = nil
        // #547: the range markers belong to a connection's GET_DATA_RANGE, which BLEManager re-sets per
        // connect; clear them here so a fresh session never reuses a previous strap's window. BLEManager
        // re-publishes them as soon as the range reply arrives.
        sessionOldestUnix = nil
        sessionNewestUnix = nil
    }

    /// Feed one raw BLE frame into the state machine. May trigger async store operations.
    func ingest(_ frame: [UInt8]) async {
        // Records are decoded at chunk commit. Only metadata can change the offload state;
        // keep its full checksum-validated parse before acting on START, END, or COMPLETE.
        guard frameTypeName(frame, family: family) == "METADATA" else {
            if chunkOpen { chunk.append(frame) }
            return
        }
        switch classifyHistoricalMeta(parseFrame(frame, family: family)) {
        case .start:
            isBackfilling = true
            chunk.removeAll(keepingCapacity: true)
            chunkOpen = true
        case .end(let unix, let trim):
            await finishChunk(unix: unix, trim: trim, endFrame: frame)
        case .complete:
            isBackfilling = false
            chunk.removeAll(keepingCapacity: true)
            chunkOpen = false
        case .other:
            if chunkOpen { chunk.append(frame) }
        }
    }

    /// The 8-byte `end_data` the high-freq-sync ack requires: metadata.data[10:18].
    /// metadata.data begins at frame[7] (after [type,seq,cmd]), so end_data = frame[17:25].
    /// trim cursor = the first u32 of end_data (data[10:14]). Returns nil if the frame is too
    /// short to contain the field (shouldn't happen for a real HISTORY_END, which is >=14 data
    /// bytes, but guards against a malformed frame).
    static func endData(from frame: [UInt8], family: DeviceFamily) -> [UInt8]? {
        // metadata.data begins at frame[7] (WHOOP4) / frame[11] (WHOOP5, the +4 puffin envelope); the
        // ack's end_data = data[10:18] → frame[17:25] (WHOOP4) or frame[21:29] (WHOOP5). The WHOOP5 slice
        // is verified on a real HISTORY_END (trim=112193 = frame[21..25]) in Whoop5HistoricalTests.
        let start = family == .whoop5 ? 21 : 17
        guard frame.count >= start + 8 else { return nil }
        return Array(frame[start..<(start + 8)])
    }

    /// Pure per-chunk persistence tally (#150). `rows` = biometric rows actually inserted (HR, R-R, SpO2,
    /// skin-temp, resp, gravity — battery/events are housekeeping, not biometric history). `motion` =
    /// gravity rows (the sleep-critical signal). `nights` = the distinct day-keys (ts / 86400) the chunk's
    /// records covered. Summed across a session by finishChunk to drive the success summary line.
    nonisolated static func chunkTally(
        counts: (hr: Int, rr: Int, events: Int, battery: Int, spo2: Int, skinTemp: Int, resp: Int, gravity: Int),
        timestamps: [Int], insertedHistoricalSensorRows: Int? = nil
    ) -> (rows: Int, motion: Int, nights: Set<Int>) {
        let rows = insertedHistoricalSensorRows
            ?? (counts.hr + counts.rr + counts.spo2 + counts.skinTemp + counts.resp + counts.gravity)
        return (rows, counts.gravity, Set(timestamps.map { $0 / 86400 }))
    }

    /// The one-line session success summary (#150) — the success-side log that never existed. Returns nil
    /// when nothing persisted (so a console-only / caught-up session stays quiet and the existing
    /// empty-banking diagnostics speak instead).
    nonisolated static func sessionSummaryLine(rows: Int, motion: Int, skinTemp: Int, nights: Int) -> String? {
        guard rows > 0 else { return nil }
        return "Backfill: session persisted \(rows) rows (\(motion) with motion, \(skinTemp) skin-temp) across \(nights) night(s)."
    }

    /// T2-0: one session-level offload latency summary. Each phase names exactly what was timed; nil when
    /// no HISTORY_END arrived this session. Percentiles are over per-chunk samples (p50/p99).
    nonisolated static func sessionPhaseTimingSummaryLine(_ samples: [BackfillChunkPhaseSample]) -> String? {
        guard !samples.isEmpty else { return nil }
        func p(_ values: [Int], _ pct: Int) -> Int {
            percentileMs(values, percentile: pct) ?? 0
        }
        let decode = samples.map(\.decodeMs)
        let insert = samples.map(\.insertMs)
        let raw = samples.map(\.rawMs)
        let imu = samples.map(\.imuMs)
        let ack = samples.map(\.ackMs)
        let frames = samples.map(\.frameCount)
        let gaps = samples.compactMap(\.gapMs)
        var line = "Backfill: chunk phase timing n=\(samples.count) chunks"
        line += " total p50/p99=\(p(samples.map(\.totalMs), 50))/\(p(samples.map(\.totalMs), 99))ms"
        line += " (HISTORY_END processing through ACK submission, including callback waits)"
        line += " diagnostics p50/p99=\(p(samples.map(\.diagnosticsMs), 50))/\(p(samples.map(\.diagnosticsMs), 99))ms"
        line += " archive p50/p99=\(p(samples.map(\.archiveMs), 50))/\(p(samples.map(\.archiveMs), 99))ms"
        line += " decode p50/p99=\(p(decode, 50))/\(p(decode, 99))ms"
        line += " (parseFrame+extractHistoricalStreams+reject scan, Task.detached)"
        line += " insert p50/p99=\(p(insert, 50))/\(p(insert, 99))ms (store.insertAndMarkJobsOwed)"
        line += " raw p50/p99=\(p(raw, 50))/\(p(raw, 99))ms (enqueueRawBatch when enabled, else 0)"
        line += " imu p50/p99=\(p(imu, 50))/\(p(imu, 99))ms (persistHistoricalImu flush when routed)"
        line += " cursor p50/p99=\(p(samples.map(\.cursorMs), 50))/\(p(samples.map(\.cursorMs), 99))ms (setCursor strap_trim)"
        line += " ack p50/p99=\(p(ack, 50))/\(p(ack, 99))ms (ackTrim callback, including main-actor wait; excludes ATT confirmation)"
        line += " frames/chunk p50/p99=\(p(frames, 50))/\(p(frames, 99))"
        if !gaps.isEmpty {
            line += " inter-chunk gap p50/p99=\(p(gaps, 50))/\(p(gaps, 99))ms (between HISTORY_END processing starts; includes queueing)"
        }
        return line
    }

    /// Per-chunk elapsed time for Connection test mode; total includes callback waits, not BLE RTT.
    nonisolated static func chunkPhaseDetailLine(trim: UInt32, sample: BackfillChunkPhaseSample) -> String {
        var line = "offload chunk trim=\(trim) frames=\(sample.frameCount)"
        if let gap = sample.gapMs { line += " gapMs=\(gap)" }
        line += " decodeMs=\(sample.decodeMs) insertMs=\(sample.insertMs)"
        line += " rawMs=\(sample.rawMs) imuMs=\(sample.imuMs) cursorMs=\(sample.cursorMs) ackMs=\(sample.ackMs)"
        line += " totalMs=\(sample.totalMs) diagnosticsMs=\(sample.diagnosticsMs) archiveMs=\(sample.archiveMs)"
        return line
    }

    /// T2-0: percentile over integer millisecond samples. Pure for unit tests.
    nonisolated static func percentileMs(_ values: [Int], percentile: Int) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = (percentile * sorted.count + 99) / 100
        let index = min(sorted.count - 1, max(0, rank - 1))
        return sorted[index]
    }

    /// Session phase samples for the Connection test-mode summary at offload end.
    func sessionPhaseTimingSamples() -> [BackfillChunkPhaseSample] { chunkPhaseSamples }

    /// #1008/#1118: the session's PRE-STORAGE R-R census. `ratio` is beat-time per second of wall time
    /// over the whole session — above 1.0 is physically impossible, and because it is measured on what the
    /// DECODER produced it separates an emission/decode defect (ratio already high here) from an ingest
    /// one (ratio ~1 here while the stored night still reads high). nil when the session banked no R-R.
    func sessionRrEmissionLine() -> String? {
        guard sessionRrOffered > 0, let lo = sessionRrMinTs, let hi = sessionRrMaxTs else { return nil }
        let span = max(hi - lo + 1, 1)
        let ratio = Double(sessionRrSumMs) / 1000.0 / Double(span)
        let r = RrEmissionStats.Result(secondsWithRr: sessionRrHist.reduce(0, +),
                                       intervals: sessionRrOffered, sumRrMs: sessionRrSumMs,
                                       spanSec: span, ratio: ratio, perSecond: sessionRrHist,
                                       gapHist: sessionRrGapHist, fill: sessionRrFill)
        return RrEmissionStats.logLine(path: "historical", offered: sessionRrOffered,
                                       inserted: sessionRrInserted, r)
    }

    /// #67 diag: the persisted-nights DATE RANGE plus the offload's effective clock state — the two facts
    /// the summary above omits. `nightKeys` are UTC day-keys (ts / 86400); their min/max are the day(s) the
    /// rows LANDED on. When those days sit years in the past while the clock ref reads ~now (an identity
    /// fallback, or an in-sync ref on a strap that banked stale), the night is misdated off the recent
    /// timeline — the "missed sleep" signature (#67). Returns nil when nothing landed. Log-only, pure.
    nonisolated static func sessionClockDiagLine(nightKeys: Set<Int>,
                                                 device: Int?, wall: Int?, usedIdentityRef: Bool,
                                                 family: DeviceFamily) -> String? {
        guard let lo = nightKeys.min(), let hi = nightKeys.max() else { return nil }
        let day: (Int) -> String = { key in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")   // fixed Gregorian yyyy — not the device calendar
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = TimeZone(identifier: "UTC")
            return f.string(from: Date(timeIntervalSince1970: Double(key) * 86_400))
        }
        let range = lo == hi ? day(lo) : "\(day(lo))…\(day(hi))"
        var line = "Backfill: rows landed on \(range)"
        if let device, let wall {
            let offset = wall - device
            let days = offset / 86_400
            if usedIdentityRef && family == .whoop5 {
                // #1598: identity is the DESIGNED ref for a 5/MG — its records carry real-unix seconds, so
                // offset 0 is correct and there is nothing to correct FOR. Labelling it "IDENTITY fallback"
                // made every healthy 5/MG log look like the #700 misdating bug.
                line += " · clock ref: identity - correct for 5/MG (records carry real-unix timestamps, no correlation needed)"
            } else if usedIdentityRef {
                line += " · clock ref: IDENTITY fallback (no clock correlation at decode) - stale-record correction OFF"
            } else if abs(offset) > 86_400 {
                line += " · strap clock \(days >= 0 ? "\(days)d behind" : "\(-days)d ahead") wall - correction engaged"
            } else {
                line += " · clock ref in sync"
            }
        }
        return line
    }

    /// The trim=0xFFFFFFFF sentinel line (#783). 0xFFFFFFFF means two different things depending on whether
    /// THIS run already banked rows. On the first end of a fresh offload it's the "no valid flash cursor"
    /// state (no banked history, a clock/charge problem). But the #364 auto-continuation re-kicks
    /// SEND_HISTORICAL after a run that DID persist rows, and the next end then carries 0xFFFFFFFF to mean
    /// "caught up, nothing left past the last trim", NOT "no history". Emitting the alarming "fully charge
    /// it" line there falsely scared users whose strap had just synced fine. So pick by `rowsPersisted`:
    /// > 0 gives a neutral caught-up line; 0 gives the genuine no-history guidance. Pure so a fixture pins both.
    nonisolated static func noCursorLine(rowsPersisted: Int, continuedAfterRows: Bool = false) -> String {
        if rowsPersisted > 0 {
            return "Backfill: reached the end of available history (trim=0xFFFFFFFF) - caught up after persisting \(rowsPersisted) row(s) this run. Nothing more to offload."
        }
        // #42: the empty tail of an auto-continue burst (#364) that banked rows in an EARLIER session. The
        // strap synced fine — this pass just confirms we're caught up — so DON'T false-alarm "no banked
        // history / charge to 100%".
        if continuedAfterRows {
            return "Backfill: reached the end of available history (trim=0xFFFFFFFF) - caught up; the strap handed over its banked history earlier this sync. Nothing more to offload."
        }
        return "Backfill: strap reported no flash cursor (trim=0xFFFFFFFF) - it has no banked history to offload. This is a clock/charge state on the strap, not a decode problem; fully charge it and reconnect so it starts banking."
    }

    /// #773: how far ahead of the wall clock a HISTORY_END's own timestamp may sit before we call the strap
    /// RTC corrupt. The strap RTC and the phone normally agree within seconds; a genuine offload is always
    /// dated in the PAST (it's banked history). A timestamp dated days into the FUTURE can only be a corrupt
    /// strap clock. Generous (1 day) so ordinary skew or a timezone confusion never trips it.
    nonisolated static let futureRtcToleranceSeconds = 86_400

    /// #773: is this HISTORY_END timestamp an implausible FUTURE date (a corrupt strap RTC)? `endUnix` and
    /// `wallNowUnix` are unix seconds in the same wall domain. Pure so a fixture pins the boundary.
    nonisolated static func isCorruptFutureRtc(endUnix: Int, wallNowUnix: Int) -> Bool {
        endUnix > wallNowUnix + futureRtcToleranceSeconds
    }

    /// #773: the recovery-hint line for a corrupt future-dated strap RTC. Names the cause plainly (the
    /// strap's clock, not a NOOP bug) and gives the fix (charge + reconnect re-syncs the RTC). Byte-identical
    /// to the Android twin. No em-dash (project rule).
    nonisolated static func futureRtcLine(endUnix: Int, wallNowUnix: Int) -> String {
        let aheadDays = max(0, (endUnix - wallNowUnix)) / 86_400
        return "Backfill: the strap reported a record dated about \(aheadDays) day(s) in the FUTURE - its clock (RTC) is corrupt, not a NARA problem. Those records can't be filed onto the right day. Fully charge the strap to 100% and reconnect so it re-syncs its clock; if it persists, forget and re-pair the strap."
    }

    /// #1683: how far BEHIND the wall clock the strap's newest stored record may sit before a sync that
    /// banked nothing is worth explaining. Two days, not one: a strap left off-wrist overnight is ordinary,
    /// and this line only ever accompanies a completed offload that banked nothing anyway.
    nonisolated static let staleRecordToleranceSeconds = 2 * 86_400

    /// Is the strap's newest stored record far enough in the past to be worth naming? A nil or
    /// non-positive value is not a date and never qualifies.
    nonisolated static func isStaleNewestRecord(newestUnix: Int?, wallNowUnix: Int) -> Bool {
        guard let newestUnix, newestUnix > 0 else { return false }
        return newestUnix <= wallNowUnix - staleRecordToleranceSeconds
    }

    /// #1683: the counterpart `futureRtcLine` never had. A strap that stopped banking weeks ago and one
    /// that is simply caught up produce the SAME "banked no sensor history" line today, so neither the user
    /// nor anyone reading their log can tell them apart. #1541 stayed open and vague for exactly that
    /// reason.
    ///
    /// Deliberately states the FACT and lets the condition carry the interpretation. A newest record two
    /// weeks old means the strap stopped recording IF it was being worn; if it sat in a drawer, the same
    /// number is unremarkable. Asserting a corrupt RTC here would claim more than the data supports, which
    /// is how this area has misled people before.
    ///
    /// It also says the part the existing advice omits: NOOP re-sends SET_CLOCK on every connect, so
    /// "charge it" alone has already been retried every session.
    ///
    /// Byte-identical to the Android twin. No em-dash (project rule).
    nonisolated static func staleRecordLine(newestUnix: Int, wallNowUnix: Int) -> String {
        let ageDays = max(0, wallNowUnix - newestUnix) / 86_400
        return "Backfill: this sync banked nothing and the strap's newest stored record is about \(ageDays) day(s) old. If you have worn it since then, it has stopped saving history to its flash. NARA already re-sends the clock on every connect, so charging alone may not be enough: charge to 100% and reconnect, then use Restart strap in Devices, and if that does not help forget and re-pair. If the official WHOOP app is also missing these days, the strap is the cause and not NARA."
    }


    /// #1683: the same honesty as `staleRecordLine`, for the message the user actually READS.
    ///
    /// The standing banner says "fully charge it to 100%, then reconnect, and it should start banking
    /// again". It omits the one fact that makes the situation legible - how long the strap has been
    /// silent - and it PROMISES a recovery that has already failed every session for weeks, because NOOP
    /// re-sends SET_CLOCK on every connect and the charge advice has therefore been retried all along. A
    /// banner that keeps promising something that keeps not happening teaches people to distrust the app
    /// rather than their strap.
    ///
    /// Byte-identical to the Android twin. Not localized, matching the sibling `lastSyncError` copy on
    /// both platforms; localizing that surface is its own change. No em-dash (project rule).
    nonisolated static func staleRecordBanner(newestUnix: Int, wallNowUnix: Int) -> String {
        let ageDays = max(0, wallNowUnix - newestUnix) / 86_400
        return "Synced, but your strap handed over no stored history, and its newest saved record is about \(ageDays) day(s) old. If you have been wearing it since then, it has stopped saving to flash. Charge it to 100% and reconnect; NARA already re-sets its clock every connect, so if that does not help, try Restart strap in Devices, then forget and re-pair. If the official WHOOP app is missing these days too, the strap is the cause and not NARA."
    }

    /// Commit one HISTORY_END chunk: (persist decoded → enqueueRaw when present) → setCursor → ackTrim.
    /// Early-returns on any throw to preserve the safe-trim invariant.
    ///
    /// CRITICAL: high-freq-sync sends ONE HISTORY_START then REPEATED HISTORY_ENDs (a chunk-close
    /// every ~50 records). So we must ack EVERY end and keep accumulating afterwards — NOT close
    /// the chunk after the first. We snapshot+clear the accumulated frames but leave `chunkOpen`
    /// TRUE so the records following this END become the next chunk. An END with no accumulated
    /// records is still acked (it advances the strap's trim) — that's how the offload progresses.
    /// `endFrame` carries the 8-byte `end_data` the ack requires.
    /// The pure decode result of one offload chunk, produced OFF the main actor (see finishChunk).
    private struct DecodedChunk {
        let parsed: [ParsedFrame]
        let decoded: Streams
        let rejected: [[UInt8]]
    }

    private func finishChunk(unix: UInt32, trim: UInt32, endFrame: [UInt8]) async {
        guard let endData = Backfiller.endData(from: endFrame, family: family) else { return }

        var commitWatchdogPaused = false
        func resumeCommitWatchdogIfNeeded() async {
            guard commitWatchdogPaused else { return }
            commitWatchdogPaused = false
            await onChunkCommitAborted?()
        }

        let chunkArrival = CFAbsoluteTimeGetCurrent()
        let gapMs = lastChunkArrival.map { Int((chunkArrival - $0) * 1000) }
        lastChunkArrival = chunkArrival
        var decodeMs = 0, insertMs = 0, rawMs = 0, imuMs = 0, ackMs = 0
        var diagnosticsMs = 0, archiveMs = 0, cursorMs = 0
        var pendingInfo: [BackfillChunkInfo] = []
        func info(_ event: BackfillChunkInfo) async {
            if chunkInfo != nil {
                pendingInfo.append(event)
            } else {
                await deliverChunkInfo([event])
            }
        }
        func infoLog(_ line: String) async { await info(.log(line)) }
        func infoConnection(_ line: @autoclosure () -> String) async {
            guard connectionActive(), connectionLog != nil || chunkInfo != nil else { return }
            await info(.connectionLog(line()))
        }
        func flushInfo() async {
            guard !pendingInfo.isEmpty else { return }
            let events = pendingInfo
            pendingInfo.removeAll(keepingCapacity: true)
            let started = CFAbsoluteTimeGetCurrent()
            await deliverChunkInfo(events)
            diagnosticsMs += Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
        }

        // The strap waits for this chunk's ACK throughout decode, diagnostics, and persistence,
        // including an empty END's cursor write. None of that work is radio inactivity.
        await onChunkCommitBegin?()
        commitWatchdogPaused = true

        // #773: corrupt future-RTC detection. A HISTORY_END carries the strap's own clock; a genuine offload
        // is always PAST-dated (it's banked history), so an end dated days into the future can only be a
        // corrupt strap RTC. Surface it ONCE per session with a recovery hint so the cause (the strap clock,
        // not a NOOP bug) is named and the fix (charge + reconnect re-syncs the RTC) is given. Observability
        // only - the ack still proceeds and the #547 ingest gate already keeps the bad-dated rows out of the
        // DB. The 0xFFFFFFFF sentinel above is a different state (it isn't a real date), so skip it here.
        if trim != 0xFFFFFFFF, !loggedFutureRtc {
            let wallNow = Int(Date().timeIntervalSince1970)
            if Backfiller.isCorruptFutureRtc(endUnix: Int(unix), wallNowUnix: wallNow) {
                loggedFutureRtc = true
                await infoLog(Backfiller.futureRtcLine(endUnix: Int(unix), wallNowUnix: wallNow))
            }
        }

        let frames = chunk
        let frameCount = frames.count
        chunk.removeAll(keepingCapacity: true)   // next records accumulate into the next chunk

        func recordPhaseSample() async {
            let sample = BackfillChunkPhaseSample(frameCount: frameCount, gapMs: gapMs,
                                          decodeMs: decodeMs, insertMs: insertMs,
                                          rawMs: rawMs, imuMs: imuMs, ackMs: ackMs,
                                          totalMs: Int((CFAbsoluteTimeGetCurrent() - chunkArrival) * 1000),
                                          diagnosticsMs: diagnosticsMs, archiveMs: archiveMs,
                                          cursorMs: cursorMs)
            chunkPhaseSamples.append(sample)
            await emitConnection(Backfiller.chunkPhaseDetailLine(trim: trim, sample: sample))
        }

        if !frames.isEmpty {
            // type-47 HISTORICAL_DATA carries its OWN real-unix timestamp — extractHistoricalStreams
            // ignores the clock offset for it — so the historical offload does NOT need GET_CLOCK.
            // If the (device,wall) correlation isn't established yet (e.g. GET_CLOCK silent), fall back
            // to an identity ref (device==wall==now): the offset math becomes a no-op, type-47 still
            // decodes to correct wall time, and we can persist + ack + upload. The correlation is only
            // truly required to map REALTIME (type-40/43) device-epoch timestamps, never in a hist chunk.
            let ref = clockRef ?? { let now = Int(Date().timeIntervalSince1970); return ClockRef(device: now, wall: now) }()
            // #67 diag: remember the ref (and whether it was the identity fallback) for the session summary,
            // so a strap log shows whether stale-RTC correction could engage. Captured on the first chunk.
            if sessionClockDevice == nil {
                sessionClockDevice = ref.device
                sessionClockWall = ref.wall
                sessionUsedIdentityRef = (clockRef == nil)
            }
            // The heavy decode — one parseFrame per record, extractHistoricalStreams, and the
            // reject classifier reusing that parse — runs OFF the main actor so a long history offload no
            // longer freezes the UI (was ~54K parseFrame calls on main for a 27K-row import). Decoding
            // and persistence remain serial in this pipeline; only BLE/UI callbacks hop to the main
            // actor. Information batching does not change persist→archive→cursor→ack trim-safety.
            let fam = family
            let dev = ref.device, wall = ref.wall
            let oldest = sessionOldestUnix, newest = sessionNewestUnix
            let extractFn = extract   // keep the injected Extractor seam (tests override it); prod == extractHistoricalStreams
            let decodeStart = CFAbsoluteTimeGetCurrent()
            let d = await Task.detached(priority: .utility) { () -> DecodedChunk in
                let parsed = frames.map { parseFrame($0, family: fam) }
                let decoded = extractFn(parsed, dev, wall, oldest, newest)
                let rejected = rejectedHistoricalRecords(frames, family: fam, parsedFrames: parsed)
                return DecodedChunk(parsed: parsed, decoded: decoded, rejected: rejected)
            }.value
            decodeMs = Int((CFAbsoluteTimeGetCurrent() - decodeStart) * 1000)
            let parsed = d.parsed
            // #1008: per-chunk clock basis + R-R packing. The session summary logs only the FIRST chunk's
            // correlation, which cannot show the offset moving across a long offload nor separate "the same
            // beats arrived twice" from "one record stamped 8 intervals on one second". Log-only.
            chunkIndex += 1
            if let l = ChunkClockDiag.line(chunk: chunkIndex,
                                           deviceClockRef: ref.device,
                                           wallClockRef: ref.wall,
                                           rrTimestamps: d.decoded.rr.map(\.ts)) {
                await infoLog(l)
            }
            // Observability (PR #241): log which layout this strap emits on a HEALTHY sync too — the
            // unmapped-version path below only fires for layouts NOOP can't decode, so a normal log
            // never revealed v18/v24/v25/v26. Once per distinct layout this session.
            if let v = parsed.lazy.compactMap({ $0.parsed["hist_version"]?.intValue }).first,
               loggedLayoutVersions.insert(v).inserted {
                await infoLog("Backfill: historical records use layout v\(v)")
                // UNIVERSAL clock-drift: bank the layout so the export's universal clock-drift line is
                // firmware-aware on every export (not only Connection mode). Unconditional observability.
                await info(.firmwareLayout(v))
                // Connection test mode: the firmware layout as a compact tagged line. A layout that decoded
                // a signature field (heart_rate / gravity_x / ppg_waveform) is decodable; otherwise the
                // unmapped-version path below fires too. Gated zero-cost.
                await infoConnection({
                    let decodable = parsed.contains {
                        $0.parsed["heart_rate"] != nil || $0.parsed["gravity_x"] != nil
                            || $0.parsed["ppg_waveform"] != nil
                    }
                    return ConnectionTrace.firmwareLine(version: v, decodable: decodable)
                }())
            }
            // SpO2 RE dump (PR #945, reimplemented): while the Connection test mode is on, dump a few FULL
            // historical records + their mapped raw SpO2 channels so an offline pass can tell whether the
            // strap banks a COMPUTED SpO2 (a byte tracking the WHOOP app's nightly %) vs only the raw
            // red/IR ADC we already decode. Log-only and bounded per session across chunks (`spo2Dumped`,
            // reset in begin); zero-cost when the mode is off (one Bool short-circuit). Only genuine
            // historical records (a decoded `unix`) spend the sample budget - the strap's type-50 console
            // frames carry no record bytes to correlate. Records dump whether or not they carry SpO2
            // channels, so "nothing banked" is provable too. Never a user-facing number (never-fabricate;
            // the #194 lesson). Twin of the Android Backfiller emit.
            if spo2Dumped < Spo2ReTrace.maxSamples, connectionActive(), connectionLog != nil || chunkInfo != nil {
                for (raw, p) in zip(frames, parsed) where spo2Dumped < Spo2ReTrace.maxSamples {
                    guard let unix = p.parsed["unix"]?.intValue else { continue }
                    await infoConnection(Spo2ReTrace.recordLine(
                        frame: raw,
                        version: p.parsed["hist_version"]?.intValue,
                        unix: unix,
                        red: p.parsed["spo2_red"]?.intValue,
                        ir: p.parsed["spo2_ir"]?.intValue,
                        skinRaw: p.parsed["skin_temp_raw"]?.intValue))
                    spo2Dumped += 1
                }
            }
            // Diagnostic (#30): a historical record whose firmware version we don't have a field map for
            // bails out of decode entirely — no HR, no R-R, no GRAVITY — so sleep (which is gravity/
            // motion-driven) can never be computed from it, even though the offload "completes". Surface
            // each unmapped version once so the user's strap log reveals what their firmware emits.
            // "Decoded nothing" must cover every mapped layout's signature field: v18 emits heart_rate,
            // v25 emits gravity_x (no per-second HR — it's PPG-derived), v26 emits ppg_waveform (no HR
            // either) — checking heart_rate alone false-flagged v25/v26 as unmapped (#156, sudden-break).
            for p in parsed {
                guard let v = p.parsed["hist_version"]?.intValue,
                      p.parsed["heart_rate"] == nil,
                      p.parsed["gravity_x"] == nil,
                      p.parsed["ppg_waveform"] == nil,
                      !loggedUnmappedVersions.contains(v) else { continue }
                loggedUnmappedVersions.insert(v)
                await infoLog("Historical records use firmware layout v\(v), which NOOP doesn't decode yet — no motion data, so sleep can't be computed from the strap. Please report this (issue #30).")
            }
            let decoded = d.decoded
            // #520: accumulate the motion-magnitude diagnostic across the session; logged once at the
            // session boundary by BLEManager, never per chunk. Merge logic lives in WhoopProtocol so it is
            // covered by swift-packages CI — this app-target file is not.
            sessionDynAccel.merge(decoded.dynAccel)
            // #547: surface a bad-clock strap. extractHistoricalStreams DROPPED any record whose own unix
            // timestamp was implausible (far-past / bogus-2027 / future-dated) before it could pollute the
            // DB. Log it (once it's accrued at least one this session, on the first chunk that sees it) so
            // the user's strap log explains why a clock-broken strap banks fewer rows than expected — this
            // is the strap's clock, not a NOOP decode bug. Observability only; the gate already did the work.
            if decoded.droppedImplausible > 0 {
                let wasZero = sessionDroppedImplausible == 0
                sessionDroppedImplausible += decoded.droppedImplausible
                if wasZero {
                    // #324: append the epoch SPAN of the dropped block + how far off it sits, so the strap log
                    // shows WHETHER the whole banked range is future-dated (safe to fast-forward-discard) or
                    // just a slice. `droppedImplausibleOldestTs/NewestTs` are the records' OWN dated values
                    // (the strap's wrong clock), captured by the #547 gate as it dropped them.
                    let span = BadClockDiagnostics.droppedSpanClause(
                        oldest: decoded.droppedImplausibleOldestTs,
                        newest: decoded.droppedImplausibleNewestTs,
                        now: Int(Date().timeIntervalSince1970))
                    await infoLog("Backfill: dropped record(s) with an implausible timestamp (trim=\(trim))\(span) — the strap's clock is wrong (records dated far in the past or future), so those samples were skipped rather than misfiled onto the wrong day. Fully charge and reconnect the strap so its clock re-syncs.")
                }
            }
            // #324: the strap RTC-state events (RTC_LOST / BOOT / SET_RTC) the #547 gate dropped for a bad
            // own-timestamp — the GROUND TRUTH that the clock reset. Sparse (not per-record), so log each as
            // it appears; the bad `rawTs` is the future/past base the RTC jumped to.
            let nowForRtc = Int(Date().timeIntervalSince1970)
            for ev in decoded.droppedRtcEvents {
                await infoLog("Backfill: strap reported \(ev.kind) with an implausible own-timestamp \(BadClockDiagnostics.isoDay(ev.rawTs)) (\(BadClockDiagnostics.hoursOffset(ev.rawTs, now: nowForRtc)) vs now) — the strap's RTC reset to a wrong base (#324/#928); this is the ground-truth cause of the future-dated banking, not a NOOP decode bug.")
            }
            // #891: packet types this chunk carried that the decoder has no case for. Logged the first
            // time each type appears so a long offload stays readable. This is the only place such a
            // record becomes visible: `default:` drops it and `rejectedHistoricalRecords` archives only
            // type-47, so without this line an offload full of an unmapped type reports a clean sync.
            for (typeName, n) in decoded.unhandledPacketTypes.sorted(by: { $0.key < $1.key }) {
                let firstSighting = sessionUnhandledPacketTypes[typeName] == nil
                sessionUnhandledPacketTypes[typeName, default: 0] += n
                if firstSighting {
                    await infoLog("Backfill: the strap sent \(n) record(s) of packet type \(typeName), which this " +
                         "decoder has no rows for — they are being dropped. If \(typeName) is not a name " +
                         "you recognise, this is a firmware record type NOOP has never mapped: please " +
                         "report it on #891 with the strap model and firmware build.")
                }
            }
            // Diagnostic (#77): the AGGREGATE silent-loss case — frames arrived but produced no rows at
            // all (CRC fail / unmapped layout / out-of-range timestamp), so this chunk persists nothing
            // yet still acks below and the strap trims past it. The per-version log above only catches
            // unmapped layouts; this catches CRC drops too. Observability only — behaviour unchanged
            // (not acking would wedge the offload on a re-send loop). Surfaces in the user's strap log.
            // Classify FIRST: separate genuinely-undecodable SENSOR records from the strap's own
            // type-50 console/diagnostic frames, which decode to 0 rows by design and are NOT a loss
            // (the "rejected frames" red herring users kept reporting — #77/#120). Drives both the
            // log wording below and the archive guard further down.
            let rejected = d.rejected
            let diagnosticsStart = CFAbsoluteTimeGetCurrent()
            // Tally this chunk's outcome so a completed-but-empty session is distinguishable from a
            // caught-up one (#77 family): did it decode sensor rows, and was it console-only?
            await info(.chunk(decoded: !decoded.isEmpty, console: decoded.isEmpty && rejected.isEmpty))
            // A chunk that produced no rows AND held no genuine rejects was pure console output — say
            // so calmly so it doesn't read as data loss (the "rejected frames" red herring, #77/#120).
            if decoded.isEmpty && rejected.isEmpty {
                await infoLog("Backfill: \(frames.count) frame(s) this chunk carried no sensor records (strap console/diagnostic output) — normal, nothing to persist (trim=\(trim)).")
            }
            // Log + hex-sample the GENUINE rejects whenever there are any — INCLUDING a partially-decoded
            // chunk (some good rows alongside CRC-failed / unmapped records), which used to archive those
            // raw bytes with no log line at all (only the all-empty case was observable). (ryanbr, PR #123)
            if !rejected.isEmpty {
                await infoLog("Backfill: \(rejected.count) undecodable sensor record(s) of \(frames.count) frame(s) (trim=\(trim)) — archiving raw bytes before ack (CRC/unmapped layout).")
                // #91 / #30: dump a hex sample of the genuine rejects so an unmapped firmware's record
                // layout can be mapped from a user's strap log. Dump the FULL frame (not a 64-byte
                // prefix — v25/v26 records run ~84 B and the truncated tail is exactly where the
                // unmapped motion/HR fields sit), and sample a few more so one log carries enough
                // records to triangulate offsets. These only ever fire for unmapped firmware.
                let sample = Array(rejected.prefix(8))
                var emptySkipped = 0
                for (i, f) in sample.enumerated() {
                    // #1007: an all-zero frame has no record layout to map, so its hex dump is pure log
                    // bloat (a strap emitting these produced ~4 MB of all-00). Keep the WARNING count above.
                    if isEmptyRecordFrame(f) { emptySkipped += 1; continue }
                    let hex = f.map { String(format: "%02x", $0) }.joined()
                    await infoLog("Backfill: rejected frame[\(i)] \(f.count)B: \(hex)")
                }
                if emptySkipped > 0 {
                    await infoLog("Backfill: #1007 \(emptySkipped)/\(sample.count) sampled frame(s) all-zero (empty payload) - hex dump skipped")
                }
            }
            diagnosticsMs += Int((CFAbsoluteTimeGetCurrent() - diagnosticsStart) * 1000)
            // Commit the decoded rows FIRST (durable). Doing this before the reject archive means a
            // rare insert failure — which returns and re-sends the whole chunk next session — can't
            // leave duplicate lines in the append-only reject archive.
            let outcome: BackfillInsertOutcome
            // #1008/#1118: census the batch BEFORE it is stored — the only place the decoder's own
            // emission can be measured, since every existing R-R number is taken after the ON CONFLICT key
            // has already absorbed part of it.
            let rrCensus = RrEmissionStats.compute(decoded.rr.map { (ts: $0.ts, rrMs: $0.rrMs) })
            let insertStart = CFAbsoluteTimeGetCurrent()
            do {
                // The durable debt is part of the SAME transaction as the decoded rows (safe trim): if the
                // job upsert fails, the insert rolls back too and this chunk stays on the strap for replay.
                outcome = try await store.insertAndMarkJobsOwed(
                    decoded,
                    deviceId: deviceId,
                    postOffloadJobKinds: postOffloadJobKinds,
                    note: "historical rows committed before trim=\(trim)")
            } catch {
                insertMs = Int((CFAbsoluteTimeGetCurrent() - insertStart) * 1000)
                // Diag (#601): the decoded rows and/or the post-offload debt couldn't be written — we
                // return WITHOUT acking so the strap keeps this chunk and re-sends everything next
                // session (no data loss, and the debt is re-recorded with the rows).
                await flushInfo()
                await log?("Backfill: failed to persist decoded rows/debt (trim=\(trim)): \(error) — holding ack so the strap re-sends this chunk; history won't advance until the write succeeds.")
                persistStalled = true   // #57: stall ALL further acks so an empty END can't advance past this
                await notePersistFailure(trim: trim, reason: "decoded insert/debt failed")
                await recordPhaseSample()
                await resumeCommitWatchdogIfNeeded()
                return
            }
            insertMs = Int((CFAbsoluteTimeGetCurrent() - insertStart) * 1000)
            let counts = outcome.counts
            await info(.banked(hr: counts.hr, rr: counts.rr, events: counts.events, battery: counts.battery,
                               spo2: counts.spo2, skinTemp: counts.skinTemp, resp: counts.resp, gravity: counts.gravity))
            // Success-side observability (#150): tally what actually persisted so the session can emit
            // "persisted N rows (M with motion) across K night(s)" — the win-rate signal a log never had.
            let sensorTimestamps = [decoded.hr.map(\.ts), decoded.rr.map(\.ts),
                                    decoded.spo2.map(\.ts), decoded.skinTemp.map(\.ts),
                                    decoded.resp.map(\.ts), decoded.gravity.map(\.ts),
                                    decoded.steps.map(\.ts), decoded.sleepState.map(\.ts),
                                    decoded.ppgHr.map(\.ts), decoded.ppgWaveform.map(\.ts),
                                    decoded.v18Aux.map(\.ts)].flatMap { $0 }
            let tally = Backfiller.chunkTally(
                counts: counts,
                timestamps: outcome.insertedHistoricalSensorRows > 0 ? sensorTimestamps : [],
                insertedHistoricalSensorRows: outcome.insertedHistoricalSensorRows)
            sessionRowsPersisted += tally.rows
            // #1008/#1118 census accumulation (pre-storage `offered` vs post-key `inserted`).
            sessionRrOffered += rrCensus.intervals
            sessionRrInserted += counts.rr
            sessionRrSumMs += rrCensus.sumRrMs
            if rrCensus.intervals > 0 {
                let lo = decoded.rr.map(\.ts).min() ?? 0
                let hi = decoded.rr.map(\.ts).max() ?? 0
                sessionRrMinTs = min(sessionRrMinTs ?? lo, lo)
                sessionRrMaxTs = max(sessionRrMaxTs ?? hi, hi)
                for i in 0..<4 { sessionRrHist[i] += rrCensus.perSecond[i] }
                for i in 0..<8 { sessionRrGapHist[i] += rrCensus.gapHist[i] }
                for i in 0..<4 { sessionRrFill[i] += rrCensus.fill[i] }
            }
            sessionMotionRows += tally.motion
            sessionSkinTempRows += counts.skinTemp
            sessionNightKeys.formUnion(tally.nights)

            // Connection test mode: per-chunk offload PROGRESS (running session totals), so a report shows
            // the offload advancing rather than only its final outcome. Gated zero-cost.
            await infoConnection("offload progress trim=\(trim) chunkRows=\(tally.rows) "
                + "sessionRows=\(sessionRowsPersisted) sessionMotion=\(sessionMotionRows) nights=\(sessionNights)")

            // #77 / #91: any genuinely-undecodable type-47 record in this chunk must be ARCHIVED
            // before we ack — the ack frees the strap's copy, so the archive is the only remaining
            // copy of an unmapped firmware's records. A genuine archive write FAILURE aborts the
            // chunk (no setCursor, no ack) so the strap re-sends it next session — no data loss
            // either way. (A full archive is reported as success by the sink; we still ack.)
            if !rejected.isEmpty, let rejectedSink {
                await flushInfo()   // Archive warnings retain their order before the durable archive.
                let archiveStart = CFAbsoluteTimeGetCurrent()
                let archived = await rejectedSink(rejected, trim, family)
                archiveMs = Int((CFAbsoluteTimeGetCurrent() - archiveStart) * 1000)
                guard archived else {
                    await log?("Backfill: rejected-frame archive failed (trim=\(trim)) — holding ack so the strap re-sends.")
                    persistStalled = true   // #57
                    await notePersistFailure(trim: trim, reason: "rejected archive failed")
                    await recordPhaseSample()
                    await resumeCommitWatchdogIfNeeded()
                    return
                }
            }

            // RAW: only persisted when the research toggle is ON. Default OFF → decoded-only; the
            // chunk is still durably committed (decoded) so the trim is safe to advance + ack.
            if enableRawCapture {
                let meta = RawBatchMeta(
                    batchId: "hist-\(deviceId)-\(trim)",
                    deviceId: deviceId,
                    clockRef: ref,
                    capturedAt: Int(Date().timeIntervalSince1970),
                    startTs: ref.wall,
                    endTs: ref.wall,
                    frameCount: frames.count,
                    byteSize: frames.reduce(0) { $0 + $1.count })
                let rawStart = CFAbsoluteTimeGetCurrent()
                do { try await store.enqueueRawBatch(meta, frames: frames) } catch {
                    rawMs = Int((CFAbsoluteTimeGetCurrent() - rawStart) * 1000)
                    // Diag (#601): raw-capture is ON and the raw batch couldn't be enqueued. Hold the ack
                    // (return) so the strap re-sends — the research toggle's contract is that raw is durable
                    // before the trim advances. Surface it so a stalled offload with raw-capture on is visible.
                    await flushInfo()
                    await log?("Backfill: failed to enqueue raw batch (trim=\(trim)): \(error) — holding ack so the strap re-sends this chunk; raw capture must be durable before the trim advances.")
                    persistStalled = true   // #57
                    await notePersistFailure(trim: trim, reason: "raw enqueue failed")
                    await recordPhaseSample()
                    await resumeCommitWatchdogIfNeeded()
                    return
                }
                rawMs = Int((CFAbsoluteTimeGetCurrent() - rawStart) * 1000)
            }

            // FRWHOOP issue #1: historical 100 Hz IMU buffers in this chunk belong to any registered
            // Raw Data Collector session window covering their strap timestamp. Persist + FLUSH them
            // here — before the cursor advances and the ack frees the strap's copy — under the same
            // safe-trim invariant as the decoded rows above. Only CRC-valid IMU-shaped frames are
            // offered; a flush failure holds the ack so the strap re-sends the chunk next session
            // rather than trimming past session data we never durably stored.
            if let imuSessionSink {
                let imuRecords = zip(frames, parsed).compactMap { frame, p -> (baseTs: Int, columns: [Int16])? in
                    guard p.ok && p.crcOK == true else { return nil }
                    return Whoop5RawImu.decodeColumns(frame)
                }
                if !imuRecords.isEmpty {
                    let imuStart = CFAbsoluteTimeGetCurrent()
                    let imuOk = imuSessionSink(deviceId, imuRecords)
                    imuMs = Int((CFAbsoluteTimeGetCurrent() - imuStart) * 1000)
                    if !imuOk {
                        await flushInfo()
                        await log?("Backfill: failed to durably persist session IMU data (trim=\(trim)) — holding ack so the strap re-sends this chunk; session .imus must be on disk before the trim advances.")
                        persistStalled = true   // #57
                        await notePersistFailure(trim: trim, reason: "session IMU flush failed")
                        await recordPhaseSample()
                        await resumeCommitWatchdogIfNeeded()
                        return
                    }
                }
            }
        }

        // #150 / #783 / #1: trim=0xFFFFFFFF is the strap's "no valid flash cursor" sentinel. Its MEANING
        // depends on whether this run already banked anything. On the FIRST end of a fresh offload it means
        // "no banked history" (a clock/charge state). But the auto-continuation (#364) re-kicks
        // SEND_HISTORICAL after a run that DID persist rows, and the very next end then carries 0xFFFFFFFF
        // to mean "you are caught up, nothing left past the last trim", NOT "no history". Emitting the scary
        // "fully charge it" line there was wrong and alarmed users whose strap had just synced fine (#783).
        // We gate this AFTER the persist block (#1): a bad-clock/flash strap can emit records on the SAME
        // 0xFFFFFFFF END, so `sessionRowsPersisted` must already include THIS end's own rows before the
        // pick, otherwise a records-bearing no-cursor END false-alarms "no banked history". So gate on
        // `sessionRowsPersisted == 0` HERE: if rows landed (this run or this END), log the neutral caught-up
        // line; a genuinely empty session (0 rows) still gets the real no-history guidance. Logs once per
        // session (loggedNoCursor) and the ack still proceeds below.
        if trim == 0xFFFFFFFF, !loggedNoCursor {
            loggedNoCursor = true
            await infoLog(Backfiller.noCursorLine(rowsPersisted: sessionRowsPersisted, continuedAfterRows: continuedAfterRows))
            // Connection test mode: the no-cursor sentinel as a compact tagged line (gated zero-cost).
            await infoConnection(ConnectionTrace.noCursorLine())
        }

        await flushInfo()   // Publish this chunk synchronously before any cursor/ACK transition.

        // #57: if an EARLIER chunk this session failed to persist, do NOT advance the cursor or ack — not
        // even for this (possibly empty/metadata) END. An empty END skips the insert and never throws;
        // acking it would trim the strap PAST the held records-carrying chunks, freeing history we never
        // stored. Stall the whole offload until a fresh session with a working store re-offers everything
        // past the last GOOD ack. Twin of the Android guard.
        if persistStalled {
            await log?("Backfill: persist stalled earlier this session — NOT acking trim=\(trim) so the strap can't trim past un-stored history. Reconnect once the store is healthy (#57).")
            await recordPhaseSample()
            await resumeCommitWatchdogIfNeeded()
            return
        }

        let cursorStart = CFAbsoluteTimeGetCurrent()
        do { try await store.setCursor("strap_trim", Int(trim)) } catch {
            cursorMs = Int((CFAbsoluteTimeGetCurrent() - cursorStart) * 1000)
            await log?("Backfill: failed to write strap_trim cursor (trim=\(trim)): \(error) — holding ack so the strap re-sends this chunk; history won't advance until the cursor write succeeds.")
            persistStalled = true   // #57
            await notePersistFailure(trim: trim, reason: "strap_trim cursor failed")
            await recordPhaseSample()
            await resumeCommitWatchdogIfNeeded()
            return
        }

        cursorMs = Int((CFAbsoluteTimeGetCurrent() - cursorStart) * 1000)
        commitWatchdogPaused = false
        let ackStart = CFAbsoluteTimeGetCurrent()
        await ackTrim(trim, endData)
        ackMs = Int((CFAbsoluteTimeGetCurrent() - ackStart) * 1000)
        lastAckedTrim = trim   // #364: record the advanced cursor for the auto-continue spin-detector
        notePersistSuccess()
        await recordPhaseSample()
    }

    /// Called when a backfill watchdog timer fires (strap went silent mid-offload).
    /// Clears state without acking — the chunk was never durably committed.
    func timeoutFired() {
        isBackfilling = false
        chunk.removeAll(keepingCapacity: true)
        chunkOpen = false
    }
}
