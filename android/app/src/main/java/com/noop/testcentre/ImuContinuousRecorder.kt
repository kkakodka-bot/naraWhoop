package com.noop.testcentre

import android.content.Context
import android.content.SharedPreferences
import com.noop.protocol.Whoop5RawImu
import java.util.Timer
import java.util.TimerTask
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONObject

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
///    buffer to a dedicated, time-segmented local store (`ImuSessionFileStore` NAMESPACE_CONTINUOUS).
///    A command acknowledgment never counts as recording: the `RECORDING` phase is entered only
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
/// Android-framework-free apart from SharedPreferences: the BLE layer injects a `Transport` of
/// lambdas, so the whole state machine is unit-testable on plain JVM with a scripted transport
/// and clock. Twin of Swift's ImuContinuousRecorder.
class ImuContinuousRecorder internal constructor(
    private val store: ImuSessionFileStore,
    private val prefs: SharedPreferences,
    private val nowMs: () -> Long = System::currentTimeMillis,
    tickIntervalMs: Long? = 2_000L,
) {

    // MARK: - Public state

    /** The recording phase. Persisted intent is `enabled` + `hardwareStopPending`; the phase is the
     * live view of how far that intent has gotten on the current link. */
    enum class Phase {
        /** Switch off, no stop owed, no packets expected. */
        OFF,
        /** Switch turned off while disconnected — a hardware stop is owed and will be sent on the
         * next bonded link. Persisted; survives relaunch. */
        OFF_STOP_PENDING,
        /** On, but no bonded 5/MG link right now. The window stays open; the gap is real. */
        WAITING_FOR_CONNECTION,
        /** On, start commands sent on this link, no verified 100 Hz packet yet. After
         * `NO_PACKET_GRACE_MS` without one, `status.noPacketsObserved` is raised. */
        START_SENT,
        /** On and at least one verified 100 Hz frame has arrived on this link. */
        RECORDING,
        /** Off, stop commands sent, waiting for packet silence before calling the producer stopped. */
        STOP_SENT,
    }

    /** Cheap status, refreshed on every state change and tick — safe to render at 1–2 Hz. */
    data class Status(
        val enabled: Boolean = false,
        val phase: Phase = Phase.OFF,
        /** START_SENT for longer than the grace period with no verified packet — the strap may not
         * be honoring the request; shown instead of claiming coverage. */
        val noPacketsObserved: Boolean = false,
        /** Verified 100 Hz packets are arriving while the switch is Off and no other producer
         * (bounded session) explains them — surfaced, never silently ignored. */
        val strayPacketsWhileOff: Boolean = false,
        /** Epoch ms of the last live (non-offload) verified packet. */
        val lastLivePacketAt: Long? = null,
        /** A hardware stop is owed but no link is up (phase == OFF_STOP_PENDING). */
        val hardwareStopPending: Boolean = false,
        /** Writes are paused because free disk fell below `LOW_DISK_THRESHOLD_BYTES`. */
        val lowDiskPaused: Boolean = false,
        val retentionCapBytes: Long = DEFAULT_CAP_BYTES,
        val conflicts: Int = 0,
        val duplicatesSkipped: Int = 0,
        val evictedSegments: Int = 0,
        /** Late history dropped because its second was already evicted by retention. */
        val droppedAfterEviction: Int = 0,
        val droppedForLowDisk: Int = 0,
        /** Start of the current on-period (the open window's requested start), epoch ms; null while Off. */
        val recordingSince: Long? = null,
    )

    /** Coverage aggregate across all of this store's windows. Heavier to compute than `status`
     * (walks the timestamp indexes), so it refreshes only while the UI asks for it. */
    data class Coverage(
        val coveredSeconds: Long = 0,
        val expectedSeconds: Long = 0,
        val gapCount: Int = 0,
        val firstGap: Pair<Long, Long>? = null,
        val diskBytes: Long = 0,
        val windowCount: Int = 0,
    )

    /** The BLE-facing seams. Every lambda is set by the BLE layer at init; defaults are inert so
     * tests can install only the ones they script. */
    class Transport {
        /** Send the hardware-validated start pair (START_RAW_DATA + TOGGLE_IMU_MODE [0x01,0x01]). */
        var sendStart: () -> Unit = {}
        /** Send the hardware stop pair (STOP_RAW_DATA + TOGGLE_IMU_MODE [0x01,0x00]). */
        var sendStop: () -> Unit = {}
        /** True only while a bonded 5/MG link can actually carry the commands. */
        var linkReady: () -> Boolean = { false }
        /** The registry's ACTIVE device id — reads are dynamic so a strap switch re-points writes. */
        var activeDeviceId: () -> String = { "" }
        /** True while the bounded Raw Data Collector owns the hardware producer — its packets must
         * never be read as this recorder's (or as strays to be stopped). */
        var otherProducerActive: () -> Boolean = { false }
        /** Free bytes on the data volume, null if unknown (unknown = writes allowed). */
        var freeDiskBytes: () -> Long? = { null }
        var log: (String) -> Unit = {}
    }

    /** One export-bundle member: zip path + bytes. */
    data class ExportEntry(val name: String, val data: ByteArray)

    // MARK: - Stored state

    val transport = Transport()

    private val stateLock = Any()
    private val _status = MutableStateFlow(Status())
    val status: StateFlow<Status> = _status.asStateFlow()
    private val _coverage = MutableStateFlow(Coverage())
    val coverage: StateFlow<Coverage> = _coverage.asStateFlow()

    private var phase: Phase = Phase.OFF
        set(value) { if (field != value) { field = value; publish() } }
    private var enabled: Boolean
    private var stopPending: Boolean
    private var counters = Counters()
    /** Per-device eviction floor: seconds <= the floor were evicted by retention and must not
     * regrow from late history. */
    private var evictedThrough = mutableMapOf<String, Long>()
    private var openWindowId: String? = null
    private var recordingSinceMs: Long? = null
    private var startSentAtMs: Long? = null
    private var lastStartSendAtMs: Long? = null
    private var lastStopSendAtMs: Long? = null
    private var lastLivePacketAtMs: Long? = null
    private var noPacketsObserved = false
    private var strayPacketsWhileOff = false
    private var lowDiskPaused = false
    private var retentionCapBytes = DEFAULT_CAP_BYTES
    /** Same-second conflict detection for the segment currently being written: strap ts → FNV-1a
     * of the frame bytes. Reset on each segment roll; older duplicates are dropped by the store's
     * own first-write-wins timestamp index. */
    private var hashBucket = Long.MIN_VALUE
    private val bucketHashes = mutableMapOf<Long, ULong>()
    private var tickCount = 0
    private var timer: Timer? = null

    init {
        enabled = prefs.getBoolean(ENABLED_KEY, false)
        stopPending = prefs.getBoolean(STOP_PENDING_KEY, false)
        counters = loadCounters()
        evictedThrough.putAll(loadEvictedThrough())
        if (prefs.contains(RETENTION_CAP_KEY)) {
            val cap = prefs.getLong(RETENTION_CAP_KEY, 0L)
            if (cap > 0) retentionCapBytes = cap
        }
        // Relaunch recovery: an On that survived the process restarts waiting for the next bonded
        // link (the post-bond hook re-arms); an owed stop survives as owed. Never re-arm while Off.
        phase = if (enabled) Phase.WAITING_FOR_CONNECTION
            else if (stopPending) Phase.OFF_STOP_PENDING else Phase.OFF
        if (enabled) {
            store.registeredWindows().firstOrNull { it.to == null }?.let { open ->
                openWindowId = open.id
                recordingSinceMs = open.from * 1_000L
            }
        }
        if (tickIntervalMs != null) {
            timer = Timer("ImuContinuousRecorder", true).apply {
                schedule(object : TimerTask() {
                    override fun run() { tick() }
                }, tickIntervalMs, tickIntervalMs)
            }
        }
        publish()
    }

    /** Cancel the tick timer. The recorder is a process-lifetime object in production; tests and
     * teardown paths use this to avoid leaking the daemon thread. */
    fun shutdown() = synchronized(stateLock) {
        timer?.cancel(); timer = null
        store.flushAll()
    }

    // MARK: - The switch

    /** True while the recorder wants the hardware producer armed — the fail-safe that stops
     * unexpected realtime IMU must stand down while this holds. */
    val expectsImuPackets: Boolean get() = enabled

    fun setEnabled(on: Boolean) = synchronized(stateLock) {
        if (on == enabled) return@synchronized
        enabled = on
        prefs.edit().putBoolean(ENABLED_KEY, on).apply()
        if (on) {
            stopPending = false
            prefs.edit().putBoolean(STOP_PENDING_KEY, false).apply()
            strayPacketsWhileOff = false
            val deviceId = transport.activeDeviceId()
            if (deviceId.isNotEmpty()) ensureWindow(deviceId)
            if (transport.linkReady()) {
                arm()
            } else {
                phase = Phase.WAITING_FOR_CONNECTION
                transport.log("IMU recorder: on — waiting for a bonded WHOOP 5/MG link")
            }
        } else {
            // Stop local writes + flush/close the current segment immediately. Late strap history
            // inside the closed window's bounds can still repair it; nothing newer is written.
            closeWindow()
            if (transport.linkReady()) {
                sendStop()
                phase = Phase.STOP_SENT
            } else {
                // Persist the owed hardware stop; the next bonded link sends it before anything
                // else, and the UI shows it as pending until then.
                stopPending = true
                prefs.edit().putBoolean(STOP_PENDING_KEY, true).apply()
                phase = Phase.OFF_STOP_PENDING
                transport.log("IMU recorder: off — hardware stop pending until reconnection")
            }
        }
        publish()
    }

    fun setRetentionCap(bytes: Long) = synchronized(stateLock) {
        // The UI offers only CAP_OPTIONS_BYTES; the guard is just a nonsense filter so tests can
        // exercise eviction with a tiny cap.
        if (bytes <= 0) return@synchronized
        retentionCapBytes = bytes
        prefs.edit().putLong(RETENTION_CAP_KEY, bytes).apply()
        enforceRetention()
    }

    // MARK: - BLE layer hooks

    /** Called once per bonded 5/MG link (the BLE layer gates re-entry). Idempotent. */
    fun handleBonded5MG() = synchronized(stateLock) {
        val deviceId = transport.activeDeviceId()
        if (deviceId.isEmpty()) return@synchronized
        if (!enabled) {
            // Never re-arm while Off — but an owed stop is sent before anything else.
            if (stopPending) {
                sendStop()
                stopPending = false
                prefs.edit().putBoolean(STOP_PENDING_KEY, false).apply()
                phase = Phase.STOP_SENT
                transport.log("IMU recorder: sent the hardware stop owed from before this link")
            }
            return@synchronized
        }
        ensureWindow(deviceId)
        arm()
    }

    /** The link dropped. An On recorder keeps its window open — the disconnect is a real gap and
     * will report as one — and re-arms from the post-bond hook on the next link. An unfinished
     * stop becomes owed again: the write may not have landed. */
    fun handleDisconnect() = synchronized(stateLock) {
        when (phase) {
            Phase.START_SENT, Phase.RECORDING, Phase.WAITING_FOR_CONNECTION ->
                if (enabled) phase = Phase.WAITING_FOR_CONNECTION
            Phase.STOP_SENT -> {
                stopPending = true
                prefs.edit().putBoolean(STOP_PENDING_KEY, true).apply()
                phase = Phase.OFF_STOP_PENDING
            }
            Phase.OFF, Phase.OFF_STOP_PENDING -> Unit
        }
    }

    /** Every reassembled 5/MG frame, live or offload replay. Verification is the decoder's full
     * length + sample-count gate — a command acknowledgment or a same-type non-IMU frame never
     * counts as a packet. */
    fun ingestFrame(frame: ByteArray, isOffload: Boolean, receivedAtMs: Long) = synchronized(stateLock) {
        val decoded = Whoop5RawImu.decode(frame) ?: return@synchronized
        if (Whoop5RawImu.rawColumns(frame) == null) return@synchronized
        val ts = decoded.baseTs
        if (!isOffload) {
            lastLivePacketAtMs = nowMs()
            if (enabled && (phase == Phase.START_SENT || phase == Phase.WAITING_FOR_CONNECTION)) {
                noPacketsObserved = false
                phase = Phase.RECORDING
                transport.log("IMU recorder: first verified 100 Hz packet — recording")
            }
        }
        if (!enabled) {
            // Packets while Off: either our stop hasn't taken effect (STOP_SENT re-sends), or
            // another producer owns them (bounded session — leave it alone), or something else
            // armed the strap. Surface the observation; never write while Off.
            if (!isOffload && !transport.otherProducerActive()) {
                if (!strayPacketsWhileOff) {
                    transport.log("IMU recorder: 100 Hz packets arriving while off (type ${frame[8].toInt() and 0xff})")
                }
                strayPacketsWhileOff = true
                publish()
            }
            return@synchronized
        }
        // Retention floor: a second already evicted must not regrow from late history.
        val deviceId = transport.activeDeviceId()
        evictedThrough[deviceId]?.let { floor ->
            if (ts <= floor) {
                counters.droppedAfterEviction += 1
                publish()
                return@synchronized
            }
        }
        if (lowDiskPaused) {
            counters.droppedForLowDisk += 1
            publish()
            return@synchronized
        }
        if (openWindowId == null && deviceId.isNotEmpty()) ensureWindow(deviceId)
        trackConflict(ts, frame)
        store.append(deviceId, frame, receivedAtMs)
        publish()
    }

    // MARK: - Tick (timer in production, direct calls in tests)

    fun tick() = synchronized(stateLock) {
        tickCount += 1
        val now = nowMs()
        when (phase) {
            Phase.OFF, Phase.OFF_STOP_PENDING -> Unit
            Phase.WAITING_FOR_CONNECTION -> if (transport.linkReady()) arm()
            Phase.START_SENT -> {
                if (!transport.linkReady()) {
                    phase = Phase.WAITING_FOR_CONNECTION
                } else {
                    val sentAt = startSentAtMs
                    if (sentAt != null && now - sentAt >= NO_PACKET_GRACE_MS && !noPacketsObserved) {
                        noPacketsObserved = true
                        transport.log("IMU recorder: no 100 Hz packets ${NO_PACKET_GRACE_MS / 1_000}s after start — the strap may not be honoring the mode")
                    }
                }
                val lastSend = lastStartSendAtMs
                if (noPacketsObserved && (lastSend == null || now - lastSend >= START_RETRY_MS)) {
                    transport.log("IMU recorder: re-sending 100 Hz start (still no packets)")
                    sendStart()
                }
            }
            Phase.RECORDING -> {
                if (!transport.linkReady()) {
                    phase = Phase.WAITING_FOR_CONNECTION
                } else {
                    val last = lastLivePacketAtMs
                    if (last != null && now - last >= STALL_REARM_MS) {
                        // The strap drops the mode on its own sometimes, and a bounded session's
                        // stop kills it too — re-arm rather than silently gap.
                        transport.log("IMU recorder: no live 100 Hz packet for ${STALL_REARM_MS / 1_000}s on a ready link — re-arming")
                        phase = Phase.START_SENT
                        startSentAtMs = now
                        sendStart()
                    }
                }
            }
            Phase.STOP_SENT -> {
                if (transport.otherProducerActive()) {
                    // The packets still arriving belong to a bounded session — our stop was sent;
                    // stopping again would kill that session's producer.
                    phase = Phase.OFF
                    strayPacketsWhileOff = false
                } else {
                    val last = lastLivePacketAtMs ?: lastStopSendAtMs
                    if (last != null && now - last >= STOP_SILENCE_MS) {
                        phase = Phase.OFF
                        strayPacketsWhileOff = false
                        transport.log("IMU recorder: 100 Hz packets ceased — producer stopped")
                    } else if (transport.linkReady()
                        && (lastStopSendAtMs == null || now - lastStopSendAtMs!! >= STOP_RESEND_MS)) {
                        transport.log("IMU recorder: packets persist after stop — re-sending hardware stop")
                        sendStop()
                    }
                }
            }
        }
        if (tickCount % 15 == 0) {
            enforceRetention()
            checkDisk()
        }
        publish()
    }

    // MARK: - Coverage + storage

    /** Recompute the coverage aggregate. Called by the UI while its screen is visible, and after
     * export/delete — not on the 2 s tick (it walks the timestamp indexes). */
    fun refreshCoverage() = synchronized(stateLock) {
        val nowSec = nowMs() / 1_000L
        var covered = 0L; var expected = 0L; var gaps = 0; var firstGap: Pair<Long, Long>? = null
        val windows = store.registeredWindows()
        for (window in windows) {
            val effectiveTo = minOf(window.to ?: nowSec, nowSec)
            val expectedFrom = window.from + PRODUCER_START_SLACK_SECONDS
            if (effectiveTo < expectedFrom) continue
            expected += effectiveTo - expectedFrom + 1
            val missing = store.missingRanges(window.id, expectedFrom, effectiveTo)
            val missingSeconds = missing.sumOf { it.second - it.first + 1 }
            covered += effectiveTo - expectedFrom + 1 - missingSeconds
            gaps += missing.size
            if (firstGap == null) firstGap = missing.firstOrNull()
        }
        _coverage.value = Coverage(covered, expected, gaps, firstGap, store.totalBytes(), windows.size)
    }

    /** Unreceipted IMU is retained. Reaching the cap pauses optional capture. */
    private fun enforceRetention() {
        if (store.totalBytes() >= retentionCapBytes && enabled) {
            transport.log("IMU recorder: account storage cap reached; retained pending files and paused capture")
            setEnabled(false)
        }
    }

    private fun checkDisk() {
        val free = transport.freeDiskBytes() ?: return
        val paused = free < LOW_DISK_THRESHOLD_BYTES
        if (paused != lowDiskPaused) {
            lowDiskPaused = paused
            transport.log(if (paused)
                "IMU recorder: free disk below ${LOW_DISK_THRESHOLD_BYTES / 1_048_576} MB — writes paused"
                else "IMU recorder: free disk recovered — writes resumed")
        }
    }

    /** Delete every window's files and routing metadata. Refused while the switch is On: the user
     * turns recording off first, so a delete can never race a live write. */
    fun deleteAll(): Boolean = synchronized(stateLock) {
        if (enabled) return false
        for (window in store.registeredWindows()) {
            if (!store.deleteFiles(window.id)) return false
            store.remove(window.id)
        }
        counters = Counters()
        evictedThrough.clear()
        persistCounters()
        persistEvictedThrough()
        refreshCoverage()
        true
    }

    // MARK: - Export

    /** The export bundle: one meta.json, one imu-coverage.json, and every window's decoded .imus
     * segments. Exporting is the ONLY way this data leaves the device — an explicit user gesture. */
    fun exportEntries(): List<ExportEntry> = synchronized(stateLock) {
        val nowSec = nowMs() / 1_000L
        val windows = store.registeredWindows()
        val entries = mutableListOf<ExportEntry>()
        val windowReports = mutableListOf<JSONObject>()
        val coverageWindows = mutableListOf<JSONObject>()
        for (window in windows) {
            val effectiveTo = minOf(window.to ?: nowSec, nowSec)
            val expectedFrom = window.from + PRODUCER_START_SLACK_SECONDS
            val expected = maxOf(0L, effectiveTo - expectedFrom + 1)
            val missing = if (expected > 0) store.missingRanges(window.id, expectedFrom, effectiveTo) else emptyList()
            val missingSeconds = missing.sumOf { it.second - it.first + 1 }
            windowReports += JSONObject()
                .put("id", window.id)
                .put("device_id", window.deviceId)
                .put("from", window.from)
                .put("to", window.to ?: JSONObject.NULL)
                .put("open", window.to == null)
                .put("expected_seconds", expected)
                .put("covered_seconds", maxOf(0L, expected - missingSeconds))
                .put("gap_count", missing.size)
            // Cap the rendered range list; the .imus files are the ground truth.
            val truncated = missing.size > 1_000
            val ranges = org.json.JSONArray()
            missing.take(1_000).forEach { ranges.put(org.json.JSONArray().put(it.first).put(it.second)) }
            coverageWindows += JSONObject()
                .put("id", window.id)
                .put("missing_ranges", ranges)
                .put("missing_ranges_truncated", truncated)
            for (segment in store.exportSegments(window.id, window.from, effectiveTo)) {
                entries += ExportEntry("imu/${window.id}/${segment.name}", segment.data)
            }
        }
        val countersJson = JSONObject()
            .put("conflicts", counters.conflicts)
            .put("duplicates_skipped", counters.duplicatesSkipped)
            .put("evicted_segments", counters.evictedSegments)
            .put("dropped_after_eviction", counters.droppedAfterEviction)
            .put("dropped_for_low_disk", counters.droppedForLowDisk)
        val evictedJson = JSONObject()
        evictedThrough.forEach { (device, floor) -> evictedJson.put(device, floor) }
        val windowsJson = org.json.JSONArray(); windowReports.forEach(windowsJson::put)
        val meta = JSONObject()
            .put("generator", "NOOP continuous IMU recorder")
            .put("format", 1)
            .put("exported_at", iso8601(nowMs()))
            .put("device_id", transport.activeDeviceId())
            .put("sample_rate_hz", ImuSessionFileStore.SAMPLE_RATE)
            .put("axes", ImuSessionFileStore.AXES)
            .put("producer_start_slack_seconds", PRODUCER_START_SLACK_SECONDS)
            .put("retention_cap_bytes", retentionCapBytes)
            .put("evicted_through", evictedJson)
            .put("counters", countersJson)
            .put("local_only", true)
            .put("windows", windowsJson)
        entries.add(0, ExportEntry("meta.json", meta.toString(2).toByteArray(Charsets.UTF_8)))
        val coverageJson = org.json.JSONArray(); coverageWindows.forEach(coverageJson::put)
        val coverageDoc = JSONObject()
            .put("note", "Seconds with no verified 100 Hz sample. Gaps are real: no samples are invented, and seconds evicted by the retention cap stay absent (see meta.json evicted_through).")
            .put("windows", coverageJson)
        entries.add(1, ExportEntry("imu-coverage.json", coverageDoc.toString(2).toByteArray(Charsets.UTF_8)))
        entries
    }

    // MARK: - Internals

    private fun arm() {
        if (!enabled || !transport.linkReady()) return
        if (openWindowId == null) {
            val deviceId = transport.activeDeviceId()
            if (deviceId.isEmpty()) return
            ensureWindow(deviceId)
        }
        phase = Phase.START_SENT
        startSentAtMs = nowMs()
        noPacketsObserved = false
        sendStart()
        transport.log("IMU recorder: 100 Hz IMU start requested (window ${openWindowId ?: "?"})")
    }

    private fun sendStart() {
        lastStartSendAtMs = nowMs()
        transport.sendStart()
    }

    private fun sendStop() {
        lastStopSendAtMs = nowMs()
        transport.sendStop()
    }

    /** Open a window for this on-period, recovering the still-open one across a relaunch. Windows
     * left open for a DIFFERENT device (strap switched while on) are completed now. */
    private fun ensureWindow(deviceId: String) {
        val now = nowMs()
        val open = store.registeredWindows().filter { it.to == null }
        for (stale in open) {
            if (stale.deviceId != deviceId) store.complete(stale.id, now)
        }
        val existing = open.firstOrNull { it.deviceId == deviceId }
        if (existing != null) {
            openWindowId = existing.id
            recordingSinceMs = existing.from * 1_000L
        } else {
            val id = "continuous-$deviceId-$now"
            store.start(id, deviceId, now - PRODUCER_START_SLACK_SECONDS * 1_000L)
            openWindowId = id
            recordingSinceMs = now - PRODUCER_START_SLACK_SECONDS * 1_000L
        }
    }

    private fun closeWindow() {
        val now = nowMs()
        // Defensive: NO window of this recorder stays open while Off — that is what makes
        // "enableRawCapture cannot silently keep this producer running" true for the local store
        // too: with no open window, live frames match nothing and are never written.
        for (window in store.registeredWindows()) {
            if (window.to == null) store.complete(window.id, now)
        }
        openWindowId = null
        recordingSinceMs = null
    }

    /** Same strap second, different bytes → a surfaced conflict (first write wins in the store).
     * Same bytes → a counted duplicate. Only the segment currently being written is tracked;
     * older re-deliveries are deduplicated by the store's timestamp index. */
    private fun trackConflict(ts: Long, frame: ByteArray) {
        val bucket = ImuSessionFileStore.bucketStart(ts)
        if (bucket != hashBucket) {
            if (bucket <= hashBucket) return   // late repair into an older segment
            hashBucket = bucket
            bucketHashes.clear()
        }
        val hash = fnv1a(frame)
        val existing = bucketHashes[ts]
        if (existing != null) {
            if (existing != hash) {
                counters.conflicts += 1
                persistCounters()
                transport.log("IMU recorder: CONFLICT at strap second $ts — stored copy kept, conflicting copy dropped")
            } else {
                counters.duplicatesSkipped += 1
            }
        } else {
            bucketHashes[ts] = hash
        }
    }

    private fun publish() {
        _status.value = Status(
            enabled = enabled,
            phase = phase,
            noPacketsObserved = noPacketsObserved,
            strayPacketsWhileOff = strayPacketsWhileOff,
            lastLivePacketAt = lastLivePacketAtMs,
            hardwareStopPending = phase == Phase.OFF_STOP_PENDING,
            lowDiskPaused = lowDiskPaused,
            retentionCapBytes = retentionCapBytes,
            conflicts = counters.conflicts,
            duplicatesSkipped = counters.duplicatesSkipped,
            evictedSegments = counters.evictedSegments,
            droppedAfterEviction = counters.droppedAfterEviction,
            droppedForLowDisk = counters.droppedForLowDisk,
            recordingSince = recordingSinceMs,
        )
    }

    private data class Counters(
        var conflicts: Int = 0, var duplicatesSkipped: Int = 0, var evictedSegments: Int = 0,
        var droppedAfterEviction: Int = 0, var droppedForLowDisk: Int = 0,
    )

    private fun loadCounters(): Counters {
        val text = prefs.getString(COUNTERS_KEY, null) ?: return Counters()
        val json = runCatching { JSONObject(text) }.getOrNull() ?: return Counters()
        return Counters(
            conflicts = json.optInt("conflicts"),
            duplicatesSkipped = json.optInt("duplicatesSkipped"),
            evictedSegments = json.optInt("evictedSegments"),
            droppedAfterEviction = json.optInt("droppedAfterEviction"),
            droppedForLowDisk = json.optInt("droppedForLowDisk"),
        )
    }

    private fun persistCounters() {
        prefs.edit().putString(COUNTERS_KEY, JSONObject()
            .put("conflicts", counters.conflicts)
            .put("duplicatesSkipped", counters.duplicatesSkipped)
            .put("evictedSegments", counters.evictedSegments)
            .put("droppedAfterEviction", counters.droppedAfterEviction)
            .put("droppedForLowDisk", counters.droppedForLowDisk)
            .toString()).apply()
    }

    private fun loadEvictedThrough(): Map<String, Long> {
        val text = prefs.getString(EVICTED_THROUGH_KEY, null) ?: return emptyMap()
        val json = runCatching { JSONObject(text) }.getOrNull() ?: return emptyMap()
        return json.keys().asSequence().associateWith { json.optLong(it) }
    }

    private fun persistEvictedThrough() {
        val json = JSONObject()
        evictedThrough.forEach { (device, floor) -> json.put(device, floor) }
        prefs.edit().putString(EVICTED_THROUGH_KEY, json.toString()).apply()
    }

    companion object {
        // MARK: Constants

        /** Retention cap choices surfaced in the UI. The default keeps roughly a week of typical
         * motion; the cap is enforced oldest-segment-first and the live segment is never evicted. */
        val CAP_OPTIONS_BYTES: List<Long> = listOf(256L, 512L, 1_024L, 2_048L).map { it * 1_048_576L }
        const val DEFAULT_CAP_BYTES: Long = 1_024L * 1_048_576L
        /** Writes pause below this much free space, and the state is surfaced — silent disk pressure
         * must not be the reason a long recording dies. */
        const val LOW_DISK_THRESHOLD_BYTES: Long = 100L * 1_048_576L
        /** Grace after sending start before "no 100 Hz packets observed" is raised. */
        const val NO_PACKET_GRACE_MS: Long = 10_000L
        /** While START_SENT stays silent, re-send the start pair at most this often (a lost write is
         * recoverable; a strap that never answers is reported, not stormed). */
        const val START_RETRY_MS: Long = 30_000L
        /** While RECORDING, this much live-packet silence on a ready link re-arms the producer (the
         * strap drops the mode on its own sometimes; a bounded session's stop also kills it). */
        const val STALL_REARM_MS: Long = 45_000L
        /** After sending stop, this much packet silence before the producer is called stopped. */
        const val STOP_SILENCE_MS: Long = 5_000L
        /** While STOP_SENT keeps seeing packets, re-send the stop at most this often. */
        const val STOP_RESEND_MS: Long = 30_000L
        /** Window `from` is opened this far BEFORE the flip to On so frames already in flight land;
         * coverage expectation starts after the slack, so the allowance is documented, not hidden. */
        const val PRODUCER_START_SLACK_SECONDS: Long = 2L

        // MARK: Persistence keys

        const val ENABLED_KEY = "imu-continuous-enabled-v1"
        const val STOP_PENDING_KEY = "imu-continuous-stop-pending-v1"
        const val RETENTION_CAP_KEY = "imu-continuous-retention-cap-v1"
        private const val EVICTED_THROUGH_KEY = "imu-continuous-evicted-through-v1"
        private const val COUNTERS_KEY = "imu-continuous-counters-v1"

        private const val PREFS_NAME = "imu-continuous-recorder"

        /** Production factory: the continuous-namespace store + the recorder's own prefs file. */
        fun create(context: Context, nowMs: () -> Long = System::currentTimeMillis): ImuContinuousRecorder =
            ImuContinuousRecorder(
                ImuSessionFileStore(context, ImuSessionFileStore.NAMESPACE_CONTINUOUS),
                com.noop.account.AccountStorageContext.capture(context).getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE),
                nowMs,
            )

        /** FNV-1a 64-bit over the raw frame bytes — platform-neutral, so a conflict counted here
         * means the same thing on iOS (which hashes the identical reassembled frame). */
        internal fun fnv1a(bytes: ByteArray): ULong {
            var hash = 0xcbf29ce484222325uL
            for (byte in bytes) {
                hash = hash xor byte.toUByte().toULong()
                hash *= 0x00000100000001b3uL
            }
            return hash
        }

        private fun iso8601(epochMs: Long): String =
            java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'")
                .withZone(java.time.ZoneOffset.UTC)
                .format(java.time.Instant.ofEpochMilli(epochMs))
    }
}
