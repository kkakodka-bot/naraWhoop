import Combine
import Foundation
import WhoopProtocol

/// Developer Options → "Record 100 Hz IMU locally" — the producer owner for continuous, locally
/// retained WHOOP 5/MG six-axis recording.
///
/// Why this exists separately from `noopRawCaptureEnabled` (raw-frame retention) and the bounded
/// Raw Data Collector: neither of those is an unambiguous recording switch. Retention defaults on
/// in this fork but only decides whether already-arrived frames are archived; it never arms the
/// hardware producer, and while it is on the bounded session's stop deliberately withholds the
/// hardware stop. This recorder owns its own state machine so the switch means exactly one thing:
///
///  - ON: while a 5/MG is bonded, request the hardware 100 Hz IMU mode (START_RAW_DATA +
///    TOGGLE_IMU_MODE [0x01,0x01] — the hardware-validated pair) and write every VERIFIED 1-second
///    buffer to a dedicated, time-segmented local store (`ImuSessionFileStore.continuous`). A
///    command acknowledgment never counts as recording: the `recording` phase is entered only
///    after the first valid decoded frame. The requested state persists across relaunch/reconnect
///    and re-arms on every new bonded link. Seconds with no data stay absent — coverage is
///    reported, never claimed. Delayed history is incorporated only when the strap actually
///    retained and re-sent it, deduplicated by strap timestamp; a same-second payload that
///    disagrees with what is already stored is surfaced as a conflict, not silently merged.
///  - OFF: close the current window immediately (late strap history inside the window's bounds can
///    still repair it — the strap timestamp decides), and request the hardware stop
///    (STOP_RAW_DATA + TOGGLE_IMU_MODE [0x01,0x00]) UNCONDITIONALLY — never gated on
///    `noopRawCaptureEnabled`, so the retention setting cannot silently keep this producer
///    running. If no link is up, the owed stop is persisted and sent on the next bond; the
///    recorder never re-arms while off.
///
/// Local-only by construction: the continuous store's directory/registry are separate from the
/// bounded-session store the rawImuSession cloud-push lane reads, so this data cannot leave the
/// device unless the user explicitly exports it.
///
/// CoreBluetooth-free: the BLE layer injects a `Transport` of closures, so the whole state machine
/// is unit-testable with a scripted transport and clock. Twin of Android's ImuContinuousRecorder.
@MainActor
final class ImuContinuousRecorder: ObservableObject {

    // MARK: - Public state

    /// The recording phase. Persisted intent is `enabled` + `hardwareStopPending`; the phase is the
    /// live view of how far that intent has gotten on the current link.
    enum Phase: String, Equatable {
        /// Switch off, no stop owed, no packets expected.
        case off
        /// Switch turned off while disconnected — a hardware stop is owed and will be sent on the
        /// next bonded link. Persisted; survives relaunch.
        case offStopPending
        /// On, but no bonded 5/MG link right now. The window stays open; the gap is real.
        case waitingForConnection
        /// On, start commands sent on this link, no verified 100 Hz packet yet. After
        /// `noPacketGraceSeconds` without one, `status.noPacketsObserved` is raised.
        case startSent
        /// On and at least one verified 100 Hz frame has arrived on this link.
        case recording
        /// Off, stop commands sent, waiting for packet silence before calling the producer stopped.
        case stopSent
    }

    /// Cheap status, refreshed on every state change and tick — safe to render at 1–2 Hz.
    struct Status: Equatable {
        var enabled = false
        var phase: Phase = .off
        /// startSent for longer than the grace period with no verified packet — the strap may not
        /// be honoring the request; shown instead of claiming coverage.
        var noPacketsObserved = false
        /// Verified 100 Hz packets are arriving while the switch is Off and no other producer
        /// (bounded session) explains them — surfaced, never silently ignored.
        var strayPacketsWhileOff = false
        var lastLivePacketAt: Date?
        /// A hardware stop is owed but no link is up (phase == offStopPending).
        var hardwareStopPending = false
        /// Writes are paused because free disk fell below `lowDiskThresholdBytes`.
        var lowDiskPaused = false
        var resourceConstrained = false
        var retentionCapBytes = defaultCapBytes
        var conflicts = 0
        var duplicatesSkipped = 0
        var evictedSegments = 0
        /// Late history dropped because its second was already evicted by retention.
        var droppedAfterEviction = 0
        var droppedForLowDisk = 0
        var droppedForResourceConstraint = 0
        /// Start of the current on-period (the open window's requested start), nil while Off.
        var recordingSince: Date?
    }

    /// Coverage aggregate across all of this store's windows. Heavier to compute than `status`
    /// (walks the timestamp indexes), so it refreshes only while the UI asks for it.
    struct Coverage: Equatable {
        var coveredSeconds = 0
        var expectedSeconds = 0
        var gapCount = 0
        var firstGap: (start: Int64, end: Int64)?
        var diskBytes: Int64 = 0
        var windowCount = 0

        static func == (lhs: Coverage, rhs: Coverage) -> Bool {
            lhs.coveredSeconds == rhs.coveredSeconds && lhs.expectedSeconds == rhs.expectedSeconds
                && lhs.gapCount == rhs.gapCount && lhs.diskBytes == rhs.diskBytes
                && lhs.windowCount == rhs.windowCount
                && lhs.firstGap?.start == rhs.firstGap?.start && lhs.firstGap?.end == rhs.firstGap?.end
        }
    }

    /// The BLE-facing seams. Every closure is set by the BLE layer at init; defaults are inert so
    /// tests can install only the ones they script.
    struct Transport {
        /// Send the hardware-validated start pair (START_RAW_DATA + TOGGLE_IMU_MODE [0x01,0x01]).
        var sendStart: () -> Void = {}
        /// Send the hardware stop pair (STOP_RAW_DATA + TOGGLE_IMU_MODE [0x01,0x00]).
        var sendStop: () -> Void = {}
        /// True only while a bonded 5/MG link can actually carry the commands.
        var linkReady: () -> Bool = { false }
        /// The registry's ACTIVE device id — reads are dynamic so a strap switch re-points writes.
        var activeDeviceId: () -> String = { "" }
        /// True while the bounded Raw Data Collector owns the hardware producer — its packets must
        /// never be read as this recorder's (or as strays to be stopped).
        var otherProducerActive: () -> Bool = { false }
        /// Free bytes on the data volume, nil if unknown (unknown = writes allowed).
        var freeDiskBytes: () -> Int64? = { nil }
        var log: (String) -> Void = { _ in }
    }

    // MARK: - Constants

    /// Retention cap choices surfaced in the UI. The default keeps roughly a week of typical
    /// motion; the cap is enforced oldest-segment-first and the live segment is never evicted.
    static let capOptionsBytes: [Int64] = [256, 512, 1_024, 2_048].map { $0 * 1_048_576 }
    static let defaultCapBytes: Int64 = 1_024 * 1_048_576
    /// Writes pause below this much free space, and the state is surfaced — silent disk pressure
    /// must not be the reason a long recording dies.
    static let lowDiskThresholdBytes: Int64 = 100 * 1_048_576
    /// Grace after sending start before "no 100 Hz packets observed" is raised.
    static let noPacketGraceSeconds: TimeInterval = 10
    /// While startSent stays silent, re-send the start pair at most this often (a lost write is
    /// recoverable; a strap that never answers is reported, not stormed).
    static let startRetrySeconds: TimeInterval = 30
    /// While recording, this much live-packet silence on a ready link re-arms the producer (the
    /// strap drops the mode on its own sometimes; a bounded session's stop also kills it).
    static let stallRearmSeconds: TimeInterval = 45
    /// After sending stop, this much packet silence before the producer is called stopped.
    static let stopSilenceSeconds: TimeInterval = 5
    /// While stopSent keeps seeing packets, re-send the stop at most this often.
    static let stopResendSeconds: TimeInterval = 30
    /// Window `from` is opened this far BEFORE the flip to On so frames already in flight land;
    /// coverage expectation starts after the slack, so the allowance is documented, not hidden.
    static let producerStartSlackSeconds: Int64 = 2

    // MARK: - Persistence keys

    static let enabledKey = "imu-continuous-enabled-v1"
    static let stopPendingKey = "imu-continuous-stop-pending-v1"
    static let retentionCapKey = "imu-continuous-retention-cap-v1"
    private static let evictedThroughKey = "imu-continuous-evicted-through-v1"
    private static let countersKey = "imu-continuous-counters-v1"

    private struct Counters: Codable {
        var conflicts = 0, duplicatesSkipped = 0, evictedSegments = 0
        var droppedAfterEviction = 0, droppedForLowDisk = 0
    }

    // MARK: - Stored state

    private let store: ImuSessionFileStore
    private let defaults: UserDefaults
    private let now: () -> Date
    var transport = Transport()

    @Published private(set) var status = Status()
    @Published private(set) var coverage = Coverage()

    private var phase: Phase = .off { didSet { if phase != oldValue { publish() } } }
    private var enabled: Bool
    private var stopPending: Bool
    private var counters = Counters()
    /// Per-device eviction floor: seconds <= the floor were evicted by retention and must not
    /// regrow from late history.
    private var evictedThrough: [String: Int64] = [:]
    private var openWindowId: String?
    private var startSentAt: Date?
    private var lastStartSendAt: Date?
    private var lastStopSendAt: Date?
    private var lastLivePacketAt: Date?
    private var noPacketsObserved = false
    private var strayPacketsWhileOff = false
    private var lowDiskPaused = false
    private var retentionBlocked = false
    private var resourceConstrained = false
    private var resourceStopPending = false
    private var lastResourceStopAt: Date?
    private var droppedForResourceConstraint = 0
    private var accountShutdown = false

    /// Transient thermal/low-power policy. The account runtime supplies its current policy before
    /// connecting and on every change; this never changes the user's persisted capture choice.
    func setResourceConstrained(_ constrained: Bool) {
        guard !accountShutdown, constrained != resourceConstrained else { return }
        resourceConstrained = constrained
        resourceStopPending = constrained && enabled
        lastResourceStopAt = nil
        if constrained {
            if let openWindowId { store.prepareForRead(openWindowId) }
            if enabled {
                phase = .waitingForConnection
                stopForResourceConstraintIfNeeded()
            }
        } else if enabled {
            arm()
        }
        publish()
    }
    /// Same-second conflict detection for the segment currently being written: strap ts → FNV-1a
    /// of the frame bytes. Reset on each segment roll; older duplicates are dropped by the store's
    /// own first-write-wins timestamp index.
    private var hashBucket: Int64 = .min
    private var bucketHashes: [Int64: UInt64] = [:]
    private var tickCount = 0
    private var timer: Timer?

    /// The old runtime may finish flushing only into its captured store. It must never re-arm.
    func shutdownForAccountChange() {
        accountShutdown = true
        timer?.invalidate()
        timer = nil
        transport = Transport()
        enabled = false
        if let openWindowId { store.prepareForRead(openWindowId) }
        phase = .off
        publish()
    }

    init(store: ImuSessionFileStore = .continuous,
         defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init,
         tickInterval: TimeInterval? = 2) {
        self.store = store
        self.defaults = defaults
        self.now = now
        enabled = defaults.bool(forKey: Self.enabledKey)
        stopPending = defaults.bool(forKey: Self.stopPendingKey)
        counters = Self.load(Counters.self, defaults: defaults, key: Self.countersKey) ?? Counters()
        evictedThrough = Self.load([String: Int64].self, defaults: defaults, key: Self.evictedThroughKey) ?? [:]
        if let cap = defaults.object(forKey: Self.retentionCapKey) as? Int64, cap > 0 {
            status.retentionCapBytes = cap
        }
        // Relaunch recovery: an On that survived the process restarts waiting for the next bonded
        // link (the post-bond hook re-arms); an owed stop survives as owed. Never re-arm while Off.
        phase = enabled ? .waitingForConnection : (stopPending ? .offStopPending : .off)
        if enabled, let open = store.registeredWindows().first(where: { $0.to == nil }) {
            openWindowId = open.id
            status.recordingSince = Date(timeIntervalSince1970: TimeInterval(open.from))
        }
        if let tickInterval {
            timer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        }
        publish()
    }

    deinit { timer?.invalidate() }

    // MARK: - The switch

    /// True while the recorder wants the hardware producer armed — the fail-safe that stops
    /// unexpected realtime IMU must stand down while this holds.
    var expectsImuPackets: Bool { enabled }

    func setEnabled(_ on: Bool) {
        guard !accountShutdown, on != enabled else { return }
        enabled = on
        defaults.set(on, forKey: Self.enabledKey)
        if on {
            stopPending = false
            defaults.set(false, forKey: Self.stopPendingKey)
            strayPacketsWhileOff = false
            let deviceId = transport.activeDeviceId()
            if !deviceId.isEmpty { ensureWindow(deviceId: deviceId) }
            if resourceConstrained {
                resourceStopPending = true
                phase = .waitingForConnection
                stopForResourceConstraintIfNeeded()
            } else if transport.linkReady() {
                arm()
            } else {
                phase = .waitingForConnection
                transport.log("IMU recorder: on — waiting for a bonded WHOOP 5/MG link")
            }
        } else {
            resourceStopPending = false
            // Stop local writes + flush/close the current segment immediately. Late strap history
            // inside the closed window's bounds can still repair it; nothing newer is written.
            closeWindow()
            if transport.linkReady() {
                sendStop()
                phase = .stopSent
            } else {
                // Persist the owed hardware stop; the next bonded link sends it before anything
                // else, and the UI shows it as pending until then.
                stopPending = true
                defaults.set(true, forKey: Self.stopPendingKey)
                phase = .offStopPending
                transport.log("IMU recorder: off — hardware stop pending until reconnection")
            }
        }
        publish()
    }

    func setRetentionCap(_ bytes: Int64) {
        // The UI offers only `capOptionsBytes`; the guard is just a nonsense filter so tests can
        // exercise eviction with a tiny cap.
        guard !accountShutdown, bytes > 0 else { return }
        status.retentionCapBytes = bytes
        defaults.set(bytes, forKey: Self.retentionCapKey)
        enforceRetention()
    }

    // MARK: - BLE layer hooks

    /// Called once per bonded 5/MG link (the BLE layer gates re-entry). Idempotent.
    func handleBonded5MG() {
        guard !accountShutdown else { return }
        let deviceId = transport.activeDeviceId()
        guard !deviceId.isEmpty else { return }
        if !enabled {
            // Never re-arm while Off — but an owed stop is sent before anything else.
            if stopPending {
                sendStop()
                stopPending = false
                defaults.set(false, forKey: Self.stopPendingKey)
                phase = .stopSent
                transport.log("IMU recorder: sent the hardware stop owed from before this link")
            }
            return
        }
        ensureWindow(deviceId: deviceId)
        if resourceConstrained {
            phase = .waitingForConnection
            stopForResourceConstraintIfNeeded()
            return
        }
        arm()
    }

    /// The link dropped. An On recorder keeps its window open — the disconnect is a real gap and
    /// will report as one — and re-arms from the post-bond hook on the next link. An unfinished
    /// stop becomes owed again: the write may not have landed.
    func handleDisconnect() {
        guard !accountShutdown else { return }
        if resourceConstrained, enabled {
            resourceStopPending = true
            lastResourceStopAt = nil
        }
        switch phase {
        case .startSent, .recording, .waitingForConnection:
            if enabled { phase = .waitingForConnection }
        case .stopSent:
            stopPending = true
            defaults.set(true, forKey: Self.stopPendingKey)
            phase = .offStopPending
        case .off, .offStopPending:
            break
        }
    }

    /// Every reassembled 5/MG frame, live or offload replay. Verification is the decoder's full
    /// length + sample-count gate — a command acknowledgment or a same-type non-IMU frame never
    /// counts as a packet.
    func ingestFrame(_ frame: [UInt8], isOffload: Bool, receivedAtMs: Int64) {
        guard !accountShutdown else { return }
        // Historical IMU is owned by the Backfiller session sink — skip decode entirely while disabled.
        if !enabled && isOffload { return }
        guard let decoded = Whoop5RawImu.decodeColumns(frame) else { return }
        let ts64 = Int64(decoded.baseTs)
        if !isOffload {
            lastLivePacketAt = now()
            if enabled, !resourceConstrained, !lowDiskPaused, !retentionBlocked,
               phase == .startSent || phase == .waitingForConnection {
                noPacketsObserved = false
                phase = .recording
                transport.log("IMU recorder: first verified 100 Hz packet — recording")
            }
        }
        guard enabled else {
            // Packets while Off: either our stop hasn't taken effect (stopSent re-sends), or
            // another producer owns them (bounded session — leave it alone), or something else
            // armed the strap. Surface the observation; never write while Off.
            if !isOffload, !transport.otherProducerActive() {
                if !strayPacketsWhileOff {
                    transport.log("IMU recorder: 100 Hz packets arriving while off (type \(frame[8]))")
                }
                strayPacketsWhileOff = true
                publish()
            }
            return
        }
        if resourceConstrained {
            droppedForResourceConstraint += 1
            if !isOffload {
                resourceStopPending = true
                stopForResourceConstraintIfNeeded()
            }
            publish()
            return
        }
        // Retention floor: a second already evicted must not regrow from late history.
        let deviceId = transport.activeDeviceId()
        if let floor = evictedThrough[deviceId], ts64 <= floor {
            counters.droppedAfterEviction += 1
            publish()
            return
        }
        if lowDiskPaused || retentionBlocked {
            counters.droppedForLowDisk += 1
            publish()
            return
        }
        if openWindowId == nil, !deviceId.isEmpty { ensureWindow(deviceId: deviceId) }
        trackConflict(ts: ts64, frame: frame)
        _ = store.append(deviceId: deviceId, ts: ts64, columns: decoded.columns, receivedAtMs: receivedAtMs)
        publish()
    }

    // MARK: - Tick (timer in production, direct calls in tests)

    func tick() {
        guard !accountShutdown else { return }
        tickCount += 1
        let now = now()
        stopForResourceConstraintIfNeeded()
        switch phase {
        case .off, .offStopPending:
            break
        case .waitingForConnection:
            if transport.linkReady() { arm() }
        case .startSent:
            if !transport.linkReady() {
                phase = .waitingForConnection
            } else if let sentAt = startSentAt,
                      now.timeIntervalSince(sentAt) >= Self.noPacketGraceSeconds, !noPacketsObserved {
                noPacketsObserved = true
                transport.log("IMU recorder: no 100 Hz packets \(Int(Self.noPacketGraceSeconds))s after start — the strap may not be honoring the mode")
            }
            if noPacketsObserved,
               now.timeIntervalSince(lastStartSendAt ?? .distantPast) >= Self.startRetrySeconds {
                transport.log("IMU recorder: re-sending 100 Hz start (still no packets)")
                sendStart()
            }
        case .recording:
            if !transport.linkReady() {
                phase = .waitingForConnection
            } else if let last = lastLivePacketAt,
                      now.timeIntervalSince(last) >= Self.stallRearmSeconds {
                // The strap drops the mode on its own sometimes, and a bounded session's stop
                // kills it too — re-arm rather than silently gap.
                transport.log("IMU recorder: no live 100 Hz packet for \(Int(Self.stallRearmSeconds))s on a ready link — re-arming")
                phase = .startSent
                startSentAt = now
                sendStart()
            }
        case .stopSent:
            if transport.otherProducerActive() {
                // The packets still arriving belong to a bounded session — our stop was sent;
                // stopping again would kill that session's producer.
                phase = .off
                strayPacketsWhileOff = false
            } else if let last = lastLivePacketAt ?? lastStopSendAt,
                      now.timeIntervalSince(last) >= Self.stopSilenceSeconds {
                phase = .off
                strayPacketsWhileOff = false
                transport.log("IMU recorder: 100 Hz packets ceased — producer stopped")
            } else if transport.linkReady(),
                      now.timeIntervalSince(lastStopSendAt ?? .distantPast) >= Self.stopResendSeconds {
                transport.log("IMU recorder: packets persist after stop — re-sending hardware stop")
                sendStop()
            }
        }
        if tickCount % 15 == 0 {
            enforceRetention()
            checkDisk()
        }
        publish()
    }

    // MARK: - Coverage + storage

    /// Recompute the coverage aggregate. Called by the UI while its screen is visible, and after
    /// export/delete — not on the 2 s tick (it walks the timestamp indexes).
    func refreshCoverage() {
        let nowSec = Int64(now().timeIntervalSince1970)
        var result = Coverage()
        for window in store.registeredWindows() {
            result.windowCount += 1
            let effectiveTo = min(window.to ?? nowSec, nowSec)
            let expectedFrom = window.from + Self.producerStartSlackSeconds
            guard effectiveTo >= expectedFrom else { continue }
            result.expectedSeconds += Int(effectiveTo - expectedFrom + 1)
            let missing = store.missingRanges(window.id, from: expectedFrom, to: effectiveTo)
            let missingSeconds = missing.reduce(0) { $0 + Int($1.1 - $1.0 + 1) }
            result.coveredSeconds += Int(effectiveTo - expectedFrom + 1) - missingSeconds
            result.gapCount += missing.count
            if result.firstGap == nil { result.firstGap = missing.first }
        }
        result.diskBytes = store.totalBytes()
        coverage = result
    }

    /// Evict oldest segments first while over the cap — never the segment currently being written —
    /// and raise the per-device eviction floor so evicted seconds cannot regrow from late history.
    private func enforceRetention() {
        let cap = status.retentionCapBytes
        var inventory = store.segmentInventory()
        var total = inventory.reduce(Int64(0)) { $0 + $1.bytes }
        guard total > cap else { retentionBlocked = false; return }
        let nowBucket = Self.bucketStart(Int64(now().timeIntervalSince1970))
        let deviceByWindow = Dictionary(uniqueKeysWithValues: store.registeredWindows().map { ($0.id, $0.deviceId) })
        for segment in inventory where total > cap {
            if segment.id == openWindowId && segment.bucket == nowBucket { continue }
            guard store.deleteSegment(id: segment.id, bucket: segment.bucket) else { continue }
            total -= segment.bytes
            counters.evictedSegments += 1
            let floor = segment.bucket + ImuSessionFileStore.segmentSeconds - 1
            let device = deviceByWindow[segment.id] ?? ""
            if floor > evictedThrough[device] ?? .min { evictedThrough[device] = floor }
            transport.log("IMU recorder: retention evicted segment \(segment.id)/\(segment.bucket) (cap \(cap) bytes)")
        }
        if total > cap, !retentionBlocked {
            retentionBlocked = true
            transport.log("IMU recorder: retention limit reached; waiting for verified durability receipts")
            if transport.linkReady() { sendStop() }
        }
        persistCounters()
        Self.save(evictedThrough, defaults: defaults, key: Self.evictedThroughKey)
        publish()
    }

    private func checkDisk() {
        guard let free = transport.freeDiskBytes() else { return }
        let paused = free < Self.lowDiskThresholdBytes
        if paused != lowDiskPaused {
            lowDiskPaused = paused
            transport.log(paused
                ? "IMU recorder: free disk below \(Self.lowDiskThresholdBytes / 1_048_576) MB — writes paused"
                : "IMU recorder: free disk recovered — writes resumed")
        }
    }

    /// Delete every window's files and routing metadata. Refused while the switch is On: the user
    /// turns recording off first, so a delete can never race a live write.
    @discardableResult
    func deleteAll() -> Bool {
        guard !enabled else { return false }
        for window in store.registeredWindows() {
            guard store.deleteFiles(window.id) else { return false }
            store.remove(id: window.id)
        }
        counters = Counters()
        evictedThrough = [:]
        persistCounters()
        Self.save(evictedThrough, defaults: defaults, key: Self.evictedThroughKey)
        refreshCoverage()
        return true
    }

    // MARK: - Export

    /// The export bundle: one meta.json, one imu-coverage.json, and every window's decoded .imus
    /// segments. Exporting is the ONLY way this data leaves the device — an explicit user gesture.
    func exportEntries() -> [FileExport.BundleEntry] {
        let nowSec = Int64(now().timeIntervalSince1970)
        let windows = store.registeredWindows()
        var entries: [FileExport.BundleEntry] = []
        var windowReports: [[String: Any]] = []
        var coverageWindows: [[String: Any]] = []
        for window in windows {
            let effectiveTo = min(window.to ?? nowSec, nowSec)
            let expectedFrom = window.from + Self.producerStartSlackSeconds
            let expected = max(0, Int(effectiveTo - expectedFrom + 1))
            let missing = expected > 0 ? store.missingRanges(window.id, from: expectedFrom, to: effectiveTo) : []
            let missingSeconds = missing.reduce(0) { $0 + Int($1.1 - $1.0 + 1) }
            windowReports.append([
                "id": window.id, "device_id": window.deviceId,
                "from": window.from, "to": window.to ?? NSNull(),
                "open": window.to == nil,
                "expected_seconds": expected,
                "covered_seconds": max(0, expected - missingSeconds),
                "gap_count": missing.count,
            ])
            // Cap the rendered range list; the .imus files are the ground truth.
            let truncated = missing.count > 1_000
            coverageWindows.append([
                "id": window.id,
                "missing_ranges": missing.prefix(1_000).map { [$0.0, $0.1] },
                "missing_ranges_truncated": truncated,
            ])
            for segment in store.exportSegments(window.id, from: Int(window.from), to: Int(effectiveTo)) {
                entries.append(FileExport.BundleEntry(name: "imu/\(window.id)/\(segment.name)", data: segment.data))
            }
        }
        let meta: [String: Any] = [
            "generator": "NOOP continuous IMU recorder",
            "format": 1,
            "exported_at": Self.iso8601(now()),
            "device_id": transport.activeDeviceId(),
            "sample_rate_hz": ImuSessionFileStore.sampleRate,
            "axes": ImuSessionFileStore.axes,
            "producer_start_slack_seconds": Self.producerStartSlackSeconds,
            "retention_cap_bytes": status.retentionCapBytes,
            "evicted_through": evictedThrough,
            "counters": [
                "conflicts": counters.conflicts,
                "duplicates_skipped": counters.duplicatesSkipped,
                "evicted_segments": counters.evictedSegments,
                "dropped_after_eviction": counters.droppedAfterEviction,
                "dropped_for_low_disk": counters.droppedForLowDisk,
            ],
            "local_only": true,
            "windows": windowReports,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            entries.insert(FileExport.BundleEntry(name: "meta.json", data: data), at: 0)
        }
        let coverageDoc: [String: Any] = [
            "note": "Seconds with no verified 100 Hz sample. Gaps are real: no samples are invented, and seconds evicted by the retention cap stay absent (see meta.json evicted_through).",
            "windows": coverageWindows,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: coverageDoc, options: [.prettyPrinted, .sortedKeys]) {
            entries.insert(FileExport.BundleEntry(name: "imu-coverage.json", data: data), at: 1)
        }
        return entries
    }

    // MARK: - Internals

    private func arm() {
        guard !accountShutdown, enabled, !resourceConstrained, !retentionBlocked, !lowDiskPaused,
              transport.linkReady() else { return }
        if openWindowId == nil {
            let deviceId = transport.activeDeviceId()
            guard !deviceId.isEmpty else { return }
            ensureWindow(deviceId: deviceId)
        }
        phase = .startSent
        startSentAt = now()
        noPacketsObserved = false
        sendStart()
        transport.log("IMU recorder: 100 Hz IMU start requested (window \(openWindowId ?? "?"))")
    }

    private func sendStart() {
        guard !accountShutdown, enabled, !resourceConstrained, !retentionBlocked, !lowDiskPaused else { return }
        lastStartSendAt = now()
        transport.sendStart()
    }

    private func sendStop() {
        lastStopSendAt = now()
        transport.sendStop()
    }

    private func stopForResourceConstraintIfNeeded() {
        guard !accountShutdown, enabled, resourceConstrained, resourceStopPending,
              transport.linkReady(), !transport.otherProducerActive() else { return }
        let timestamp = now()
        guard lastResourceStopAt.map({ timestamp.timeIntervalSince($0) >= Self.stopResendSeconds }) ?? true
        else { return }
        resourceStopPending = false
        lastResourceStopAt = timestamp
        sendStop()
    }

    /// Open a window for this on-period, recovering the still-open one across a relaunch. Windows
    /// left open for a DIFFERENT device (strap switched while on) are completed now.
    private func ensureWindow(deviceId: String) {
        let nowMs = Int64(now().timeIntervalSince1970 * 1_000)
        let open = store.registeredWindows().filter { $0.to == nil }
        for stale in open where stale.deviceId != deviceId {
            store.complete(id: stale.id, toMs: nowMs)
        }
        if let existing = open.first(where: { $0.deviceId == deviceId }) {
            openWindowId = existing.id
            status.recordingSince = Date(timeIntervalSince1970: TimeInterval(existing.from))
        } else {
            let id = "continuous-\(deviceId)-\(nowMs)"
            store.start(id: id, deviceId: deviceId,
                        fromMs: nowMs - Self.producerStartSlackSeconds * 1_000)
            openWindowId = id
            status.recordingSince = Date(timeIntervalSince1970: TimeInterval(nowMs) / 1_000
                                         - TimeInterval(Self.producerStartSlackSeconds))
        }
    }

    private func closeWindow() {
        let nowMs = Int64(now().timeIntervalSince1970 * 1_000)
        // Defensive: NO window of this recorder stays open while Off — that is what makes
        // "enableRawCapture cannot silently keep this producer running" true for the local store
        // too: with no open window, live frames match nothing and are never written.
        for window in store.registeredWindows() where window.to == nil {
            store.complete(id: window.id, toMs: nowMs)
        }
        openWindowId = nil
        status.recordingSince = nil
    }

    /// Same strap second, different bytes → a surfaced conflict (first write wins in the store).
    /// Same bytes → a counted duplicate. Only the segment currently being written is tracked;
    /// older re-deliveries are deduplicated by the store's timestamp index.
    private func trackConflict(ts: Int64, frame: [UInt8]) {
        let bucket = Self.bucketStart(ts)
        if bucket != hashBucket {
            guard bucket > hashBucket else { return }   // late repair into an older segment
            hashBucket = bucket
            bucketHashes.removeAll(keepingCapacity: true)
        }
        let hash = Self.fnv1a(frame)
        if let existing = bucketHashes[ts] {
            if existing != hash {
                counters.conflicts += 1
                persistCounters()
                transport.log("IMU recorder: CONFLICT at strap second \(ts) — stored copy kept, conflicting copy dropped")
            } else {
                counters.duplicatesSkipped += 1
            }
        } else {
            bucketHashes[ts] = hash
        }
    }

    /// FNV-1a 64-bit over the raw frame bytes — platform-neutral, so a conflict counted here means
    /// the same thing on Android (which hashes the identical reassembled frame).
    static func fnv1a(_ bytes: [UInt8]) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes { hash ^= UInt64(byte); hash &*= 0x0000_0100_0000_01b3 }
        return hash
    }

    static func bucketStart(_ ts: Int64) -> Int64 {
        ts >= 0 ? ts / ImuSessionFileStore.segmentSeconds * ImuSessionFileStore.segmentSeconds
                : ((ts - ImuSessionFileStore.segmentSeconds + 1) / ImuSessionFileStore.segmentSeconds) * ImuSessionFileStore.segmentSeconds
    }

    private func publish() {
        status.enabled = enabled
        status.phase = phase
        status.noPacketsObserved = noPacketsObserved
        status.strayPacketsWhileOff = strayPacketsWhileOff
        status.lastLivePacketAt = lastLivePacketAt
        status.hardwareStopPending = phase == .offStopPending
        status.lowDiskPaused = lowDiskPaused || retentionBlocked
        status.resourceConstrained = resourceConstrained
        status.conflicts = counters.conflicts
        status.duplicatesSkipped = counters.duplicatesSkipped
        status.evictedSegments = counters.evictedSegments
        status.droppedAfterEviction = counters.droppedAfterEviction
        status.droppedForLowDisk = counters.droppedForLowDisk
        status.droppedForResourceConstraint = droppedForResourceConstraint
    }

    private func persistCounters() {
        Self.save(counters, defaults: defaults, key: Self.countersKey)
    }

    private static func load<T: Decodable>(_ type: T.Type, defaults: UserDefaults, key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private static func save<T: Encodable>(_ value: T, defaults: UserDefaults, key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: date)
    }
}
