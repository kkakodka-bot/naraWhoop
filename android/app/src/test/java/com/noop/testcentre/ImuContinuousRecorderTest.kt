package com.noop.testcentre

import android.content.SharedPreferences
import java.io.File
import java.nio.file.Files
import java.util.UUID
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** State-machine tests for the Developer Options "Record 100 Hz IMU locally" producer owner.
 *  Every test drives the recorder through its injected transport/clock seams — no Bluetooth, no
 *  strap — over a real temp-dir [ImuSessionFileStore], so the store round-trip (append → flush →
 *  coverage) is exercised exactly as in production. Twin of StrandTests/ImuContinuousRecorderTests. */
class ImuContinuousRecorderTest {

    /** In-memory SharedPreferences: the recorder + store persist through it exactly as in
     *  production, so relaunch tests exercise the real recovery path. */
    private class FakeSharedPreferences : SharedPreferences {
        private val map = mutableMapOf<String, Any?>()
        override fun getAll(): MutableMap<String, *> = map.toMutableMap()
        override fun getString(key: String, defValue: String?): String? =
            map[key] as? String ?: defValue
        @Suppress("UNCHECKED_CAST")
        override fun getStringSet(key: String, defValues: MutableSet<String>?): MutableSet<String>? =
            (map[key] as? Set<String>)?.toMutableSet() ?: defValues
        override fun getInt(key: String, defValue: Int): Int = map[key] as? Int ?: defValue
        override fun getLong(key: String, defValue: Long): Long = map[key] as? Long ?: defValue
        override fun getFloat(key: String, defValue: Float): Float = map[key] as? Float ?: defValue
        override fun getBoolean(key: String, defValue: Boolean): Boolean = map[key] as? Boolean ?: defValue
        override fun contains(key: String): Boolean = map.containsKey(key)
        override fun edit(): SharedPreferences.Editor = Editor()
        override fun registerOnSharedPreferenceChangeListener(
            listener: SharedPreferences.OnSharedPreferenceChangeListener?,
        ) = Unit
        override fun unregisterOnSharedPreferenceChangeListener(
            listener: SharedPreferences.OnSharedPreferenceChangeListener?,
        ) = Unit

        inner class Editor : SharedPreferences.Editor {
            private val writes = mutableListOf<() -> Unit>()
            override fun putString(key: String, value: String?) = apply { writes += { map[key] = value } }
            override fun putStringSet(key: String, values: MutableSet<String>?) =
                apply { writes += { map[key] = values?.toSet() } }
            override fun putInt(key: String, value: Int) = apply { writes += { map[key] = value } }
            override fun putLong(key: String, value: Long) = apply { writes += { map[key] = value } }
            override fun putFloat(key: String, value: Float) = apply { writes += { map[key] = value } }
            override fun putBoolean(key: String, value: Boolean) = apply { writes += { map[key] = value } }
            override fun remove(key: String) = apply { writes += { map.remove(key) } }
            override fun clear() = apply { writes += { map.clear() } }
            override fun commit(): Boolean { apply(); return true }
            override fun apply() { writes.forEach { it() }; writes.clear() }
        }
    }

    /** Mutable script for the recorder's transport seams. */
    private class Harness {
        var nowMs = 1_800_000_000_000L
        var starts = 0; var stops = 0
        var linkReady = true
        var deviceId = "strap"
        var otherProducer = false
        var freeDisk: Long? = null
        val logs = mutableListOf<String>()
        val nowSec get() = nowMs / 1_000L
    }

    private lateinit var harness: Harness
    private lateinit var directory: File
    private lateinit var prefs: FakeSharedPreferences
    private lateinit var storePrefs: FakeSharedPreferences
    private lateinit var store: ImuSessionFileStore

    @Before fun setUp() {
        harness = Harness()
        directory = Files.createTempDirectory("imu-recorder-test").toFile()
        prefs = FakeSharedPreferences()
        storePrefs = FakeSharedPreferences()
        // A unique namespace per test: the store's process-wide pending/seen maps are keyed by
        // namespace + path, so no state can leak between tests in one JVM.
        store = ImuSessionFileStore(storePrefs, directory, "test-${UUID.randomUUID()}")
    }

    @After fun tearDown() {
        directory.deleteRecursively()
    }

    private fun makeRecorder(): ImuContinuousRecorder {
        val h = harness
        val recorder = ImuContinuousRecorder(store, prefs, nowMs = { h.nowMs }, tickIntervalMs = null)
        recorder.transport.sendStart = { h.starts += 1 }
        recorder.transport.sendStop = { h.stops += 1 }
        recorder.transport.linkReady = { h.linkReady }
        recorder.transport.activeDeviceId = { h.deviceId }
        recorder.transport.otherProducerActive = { h.otherProducer }
        recorder.transport.freeDiskBytes = { h.freeDisk }
        recorder.transport.log = { h.logs += it }
        return recorder
    }

    /** A valid 1244-byte 5/MG IMU buffer: u32 LE strap ts @15, sample counts 100 @24/@630.
     *  `seed` varies the accel payload so same-ts frames can differ (conflict detection). */
    private fun imuFrame(ts: Long, seed: Int = 0): ByteArray {
        val frame = ByteArray(1244)
        frame[15] = (ts and 0xff).toByte(); frame[16] = ((ts shr 8) and 0xff).toByte()
        frame[17] = ((ts shr 16) and 0xff).toByte(); frame[18] = ((ts shr 24) and 0xff).toByte()
        frame[24] = 100; frame[630] = 100
        if (seed != 0) frame[28] = seed.toByte()
        return frame
    }

    /** A high-entropy variant so zlib cannot compress a block below the retention test's cap. */
    private fun noisyFrame(ts: Long): ByteArray {
        val frame = imuFrame(ts)
        var state = ts * 2_862_933_555_777_941_757L + 1
        for (index in 28 until 1244) {
            state = state * 6_364_136_223_846_793_005L + 1_442_695_040_888_963_407L
            frame[index] = (state shr 33).toByte()
        }
        frame[630] = 100; frame[631] = 0   // keep the gyro sample-count gate valid
        return frame
    }

    private fun advance(seconds: Long) { harness.nowMs += seconds * 1_000L }

    // MARK: - Acceptance 1: On records verified packets; an ack alone never counts

    @Test fun onArmsWhenBondedAndRecordsOnlyVerifiedFrames() {
        val recorder = makeRecorder()
        harness.linkReady = false
        recorder.setEnabled(true)
        assertEquals(ImuContinuousRecorder.Phase.WAITING_FOR_CONNECTION, recorder.status.value.phase)
        assertEquals(0, harness.starts)   // no link — the hardware start must not be claimed sent

        harness.linkReady = true
        recorder.handleBonded5MG()
        assertEquals(1, harness.starts)
        assertEquals(ImuContinuousRecorder.Phase.START_SENT, recorder.status.value.phase)

        // The start command being SENT is not recording: past the grace period with no valid
        // packet, the surface says so.
        advance(11)
        recorder.tick()
        assertEquals(ImuContinuousRecorder.Phase.START_SENT, recorder.status.value.phase)
        assertTrue(recorder.status.value.noPacketsObserved)

        // A non-IMU frame (e.g. a command ack) never counts as a packet.
        recorder.ingestFrame(ByteArray(40) { 1 }, isOffload = false, receivedAtMs = harness.nowMs)
        assertEquals(ImuContinuousRecorder.Phase.START_SENT, recorder.status.value.phase)

        // The first VERIFIED frame flips to recording and lands in the store under its strap ts.
        recorder.ingestFrame(imuFrame(harness.nowSec), isOffload = false, receivedAtMs = harness.nowMs)
        assertEquals(ImuContinuousRecorder.Phase.RECORDING, recorder.status.value.phase)
        assertFalse(recorder.status.value.noPacketsObserved)
        recorder.refreshCoverage()
        assertEquals(1, recorder.coverage.value.coveredSeconds)
        // The 11 silent seconds between arm and the first packet are a REAL gap — the strap never
        // sent them — and honest coverage says so instead of claiming them.
        assertEquals(1, recorder.coverage.value.gapCount)
    }

    @Test fun startIsResentOncePerRetryIntervalWhileSilent() {
        val recorder = makeRecorder()
        recorder.setEnabled(true)   // link already up: the switch itself arms
        assertEquals(1, harness.starts)
        advance(11)
        recorder.tick()
        assertTrue(recorder.status.value.noPacketsObserved)
        advance(30)
        recorder.tick()
        assertEquals("a lost start write gets one bounded retry per interval", 2, harness.starts)
    }

    @Test fun recordingStallRearmsOnReadyLink() {
        val recorder = makeRecorder()
        recorder.setEnabled(true)
        recorder.ingestFrame(imuFrame(harness.nowSec), isOffload = false, receivedAtMs = harness.nowMs)
        assertEquals(ImuContinuousRecorder.Phase.RECORDING, recorder.status.value.phase)
        advance(46)
        recorder.tick()
        assertEquals(ImuContinuousRecorder.Phase.START_SENT, recorder.status.value.phase)
        assertEquals("a stalled stream re-arms instead of silently gapping", 2, harness.starts)
    }

    // MARK: - Acceptance 2 + 4: Off stops immediately, sends the hardware stop unconditionally

    @Test fun offStopsWritesAndSendsHardwareStopEvenWithRetentionEnabled() {
        // Fork default: raw-frame retention ON. The recorder never reads it — that is the point.
        prefs.edit().putBoolean("enableRawCapture", true).apply()
        val recorder = makeRecorder()
        recorder.setEnabled(true)
        recorder.ingestFrame(imuFrame(harness.nowSec), isOffload = false, receivedAtMs = harness.nowMs)
        assertEquals(ImuContinuousRecorder.Phase.RECORDING, recorder.status.value.phase)

        recorder.setEnabled(false)
        assertEquals("the hardware stop is sent even while enableRawCapture stays on", 1, harness.stops)
        assertEquals(ImuContinuousRecorder.Phase.STOP_SENT, recorder.status.value.phase)

        // Local writes cease immediately: a live frame from the next second is not recorded.
        advance(1)
        recorder.ingestFrame(imuFrame(harness.nowSec), isOffload = false, receivedAtMs = harness.nowMs)
        recorder.refreshCoverage()
        assertEquals(1, recorder.coverage.value.coveredSeconds)

        // Packets ceasing for the silence window ends the stop handshake.
        advance(6)
        recorder.tick()
        assertEquals(ImuContinuousRecorder.Phase.OFF, recorder.status.value.phase)
    }

    @Test fun offWhileDisconnectedPersistsStopPendingAcrossRelaunchAndNeverRearms() {
        val recorder = makeRecorder()
        recorder.setEnabled(true)
        harness.linkReady = false
        recorder.handleDisconnect()
        recorder.setEnabled(false)
        assertEquals("no link — the stop cannot have been sent", 0, harness.stops)
        assertEquals(ImuContinuousRecorder.Phase.OFF_STOP_PENDING, recorder.status.value.phase)
        assertTrue(recorder.status.value.hardwareStopPending)

        // Relaunch: the owed stop survives; the recorder comes up still owing it.
        val relaunched = makeRecorder()
        assertEquals(ImuContinuousRecorder.Phase.OFF_STOP_PENDING, relaunched.status.value.phase)
        assertFalse(relaunched.status.value.enabled)

        // Reconnect: the owed stop goes out BEFORE anything else, and no start is ever sent.
        harness.linkReady = true
        relaunched.handleBonded5MG()
        assertEquals(1, harness.stops)
        assertEquals("only the original arm — Off never re-arms", 1, harness.starts)
        assertEquals(ImuContinuousRecorder.Phase.STOP_SENT, relaunched.status.value.phase)
        advance(6)
        relaunched.tick()
        assertEquals(ImuContinuousRecorder.Phase.OFF, relaunched.status.value.phase)
    }

    @Test fun onPersistsAcrossRelaunchAndRearmsOnBond() {
        val recorder = makeRecorder()
        recorder.setEnabled(true)
        recorder.ingestFrame(imuFrame(harness.nowSec), isOffload = false, receivedAtMs = harness.nowMs)

        // Relaunch with the same prefs + store: still On, same open window, waiting for a link.
        val relaunched = makeRecorder()
        assertTrue(relaunched.status.value.enabled)
        assertEquals(ImuContinuousRecorder.Phase.WAITING_FOR_CONNECTION, relaunched.status.value.phase)
        assertNotNull(relaunched.status.value.recordingSince)

        relaunched.handleBonded5MG()
        assertEquals("re-armed on the new link", 2, harness.starts)
        advance(1)
        relaunched.ingestFrame(imuFrame(harness.nowSec), isOffload = false, receivedAtMs = harness.nowMs)
        relaunched.refreshCoverage()
        assertEquals("the relaunched recorder keeps writing the SAME window",
            2, relaunched.coverage.value.coveredSeconds)
    }

    // MARK: - Acceptance 3: disconnect gap is real; verified history repairs; no duplicates

    @Test fun disconnectGapIsReportedAndLateHistoryRepairsWithoutDuplicates() {
        val recorder = makeRecorder()
        recorder.setEnabled(true)
        recorder.ingestFrame(imuFrame(harness.nowSec), isOffload = false, receivedAtMs = harness.nowMs)
        advance(1)
        recorder.ingestFrame(imuFrame(harness.nowSec), isOffload = false, receivedAtMs = harness.nowMs)

        // Link down for 5 seconds: those seconds stay absent.
        harness.linkReady = false
        recorder.handleDisconnect()
        assertEquals(ImuContinuousRecorder.Phase.WAITING_FOR_CONNECTION, recorder.status.value.phase)
        advance(5)
        harness.linkReady = true
        recorder.handleBonded5MG()
        recorder.ingestFrame(imuFrame(harness.nowSec), isOffload = false, receivedAtMs = harness.nowMs)

        recorder.refreshCoverage()
        assertEquals(3, recorder.coverage.value.coveredSeconds)
        assertEquals("the 4-second disconnect shows as one gap", 1, recorder.coverage.value.gapCount)

        // The strap retained part of the gap and offloads it later: verified history repairs it.
        val repairTs = harness.nowSec - 3
        recorder.ingestFrame(imuFrame(repairTs), isOffload = true, receivedAtMs = harness.nowMs)
        recorder.refreshCoverage()
        assertEquals(4, recorder.coverage.value.coveredSeconds)

        // The same second arriving twice (live + replay) is written once and counted.
        recorder.ingestFrame(imuFrame(repairTs), isOffload = true, receivedAtMs = harness.nowMs)
        recorder.refreshCoverage()
        assertEquals("no duplicate seconds", 4, recorder.coverage.value.coveredSeconds)
        assertEquals(1, recorder.status.value.duplicatesSkipped)
    }

    @Test fun sameSecondDifferentBytesSurfacesAConflictAndKeepsFirstWrite() {
        val recorder = makeRecorder()
        recorder.setEnabled(true)
        val ts = harness.nowSec
        recorder.ingestFrame(imuFrame(ts, seed = 1), isOffload = false, receivedAtMs = harness.nowMs)
        recorder.ingestFrame(imuFrame(ts, seed = 2), isOffload = true, receivedAtMs = harness.nowMs)
        assertEquals(1, recorder.status.value.conflicts)
        assertTrue(harness.logs.any { it.contains("CONFLICT") })
        val windowId = store.registeredWindows().first().id
        val segments = store.exportSegments(windowId, ts - 1, ts + 1)
        val exported = segments.flatMap { listOf(it.startTs, it.endTs) }
        assertEquals("one stored second, first write wins", listOf(ts, ts), exported)
    }

    // MARK: - Producer ownership vs the bounded session

    @Test fun stopSentStandsDownWhenBoundedSessionOwnsTheProducer() {
        val recorder = makeRecorder()
        recorder.setEnabled(true)
        recorder.ingestFrame(imuFrame(harness.nowSec), isOffload = false, receivedAtMs = harness.nowMs)
        recorder.setEnabled(false)
        assertEquals(ImuContinuousRecorder.Phase.STOP_SENT, recorder.status.value.phase)
        harness.otherProducer = true
        // Packets keep arriving (the bounded session's): no stop re-send, no stray alarm.
        advance(1)
        recorder.ingestFrame(imuFrame(harness.nowSec), isOffload = false, receivedAtMs = harness.nowMs)
        advance(31)
        recorder.tick()
        assertEquals(ImuContinuousRecorder.Phase.OFF, recorder.status.value.phase)
        assertEquals("the recorder never stops another producer's stream", 1, harness.stops)
        assertFalse(recorder.status.value.strayPacketsWhileOff)
    }

    @Test fun packetsPersistingAfterStopResendStopBounded() {
        val recorder = makeRecorder()
        recorder.setEnabled(true)
        recorder.ingestFrame(imuFrame(harness.nowSec), isOffload = false, receivedAtMs = harness.nowMs)
        recorder.setEnabled(false)
        advance(1)
        recorder.ingestFrame(imuFrame(harness.nowSec), isOffload = false, receivedAtMs = harness.nowMs)
        // 31 s later the strap is STILL streaming (a packet arrives right before the tick): the
        // stop is re-sent on the bounded cadence and the phase never claims "stopped".
        advance(30)
        recorder.ingestFrame(imuFrame(harness.nowSec), isOffload = false, receivedAtMs = harness.nowMs)
        recorder.tick()
        assertEquals("a strap still streaming after stop gets a bounded re-send", 2, harness.stops)
        assertEquals("never claims stopped while packets flow",
            ImuContinuousRecorder.Phase.STOP_SENT, recorder.status.value.phase)
    }

    // MARK: - Storage policy

    @Test fun retentionStopsNewCaptureWithoutDeletingUnreceiptedSegments() {
        val recorder = makeRecorder()
        recorder.setEnabled(true)
        recorder.setRetentionCap(40_000)   // tiny, so two ~36 KB incompressible blocks exceed it

        // Fill one 30-second block (auto-flushes at 30 records) in the current segment.
        val firstBucketStart = harness.nowSec
        for (offset in 0L until 30L) {
            recorder.ingestFrame(noisyFrame(firstBucketStart + offset), isOffload = false,
                receivedAtMs = harness.nowMs + offset * 1_000)
        }
        // Roll into the next half-hour segment and flush a block there too.
        advance(1_800)
        for (offset in 0L until 30L) {
            recorder.ingestFrame(noisyFrame(harness.nowSec + offset), isOffload = false,
                receivedAtMs = harness.nowMs + offset * 1_000)
        }
        assertEquals(2, store.segmentInventory().size)
        val before = store.segmentInventory()
        val beforeBytes = store.totalBytes()

        recorder.tick()   // tick 1 — retention runs on tick 15; drive it directly below
        repeat(14) { recorder.tick() }
        assertEquals("all raw segments survive the cap", before, store.segmentInventory())
        assertEquals(beforeBytes, store.totalBytes())
        assertEquals(0, recorder.status.value.evictedSegments)
        assertFalse("new capture is stopped at the cap", recorder.status.value.enabled)

        // Late history for an evicted second is refused — evicted stays evicted.
        recorder.ingestFrame(noisyFrame(firstBucketStart), isOffload = true, receivedAtMs = harness.nowMs)
        assertEquals(0, recorder.status.value.droppedAfterEviction)
        assertEquals(before, store.segmentInventory())
    }

    @Test fun lowDiskPausesWritesAndSurfacesIt() {
        val recorder = makeRecorder()
        recorder.setEnabled(true)
        harness.freeDisk = 1
        repeat(15) { recorder.tick() }   // reach the disk-check tick
        assertTrue(recorder.status.value.lowDiskPaused)
        recorder.ingestFrame(imuFrame(harness.nowSec), isOffload = false, receivedAtMs = harness.nowMs)
        assertEquals(1, recorder.status.value.droppedForLowDisk)
        recorder.refreshCoverage()
        assertEquals("paused writes leave real gaps", 0, recorder.coverage.value.coveredSeconds)

        harness.freeDisk = Long.MAX_VALUE
        repeat(15) { recorder.tick() }
        assertFalse(recorder.status.value.lowDiskPaused)
        recorder.ingestFrame(imuFrame(harness.nowSec), isOffload = false, receivedAtMs = harness.nowMs)
        assertEquals(1, recorder.status.value.droppedForLowDisk)
    }

    @Test fun deleteAllRefusedWhileEnabledAndClearsEverythingWhenOff() {
        val recorder = makeRecorder()
        recorder.setEnabled(true)
        recorder.ingestFrame(imuFrame(harness.nowSec), isOffload = false, receivedAtMs = harness.nowMs)
        assertFalse("delete is refused while the switch is On", recorder.deleteAll())

        recorder.setEnabled(false)
        advance(6)
        recorder.tick()
        assertTrue(recorder.deleteAll())
        assertTrue(store.registeredWindows().isEmpty())
        assertEquals(0, store.totalBytes())
        recorder.refreshCoverage()
        assertEquals(0, recorder.coverage.value.coveredSeconds)
    }

    // MARK: - Export

    @Test fun exportContainsSegmentsCoverageAndHonestMeta() {
        val recorder = makeRecorder()
        recorder.setEnabled(true)
        recorder.ingestFrame(imuFrame(harness.nowSec), isOffload = false, receivedAtMs = harness.nowMs)
        advance(2)
        recorder.ingestFrame(imuFrame(harness.nowSec), isOffload = false, receivedAtMs = harness.nowMs)

        val entries = recorder.exportEntries()
        val names = entries.map { it.name }
        assertTrue("meta.json" in names)
        assertTrue("imu-coverage.json" in names)
        assertTrue(names.any { it.startsWith("imu/") && it.endsWith(".imus") })

        val meta = JSONObject(entries.first { it.name == "meta.json" }.data.toString(Charsets.UTF_8))
        assertEquals(100, meta.getInt("sample_rate_hz"))
        assertTrue(meta.getBoolean("local_only"))
        val windows = meta.getJSONArray("windows")
        assertEquals(2, windows.getJSONObject(0).getLong("covered_seconds"))
        assertEquals("the skipped second is exported as a real gap, not smoothed over",
            1, windows.getJSONObject(0).getInt("gap_count"))

        val coverage = JSONObject(entries.first { it.name == "imu-coverage.json" }.data.toString(Charsets.UTF_8))
        val ranges = coverage.getJSONArray("windows").getJSONObject(0).getJSONArray("missing_ranges")
        assertEquals(1, ranges.length())
        val range = ranges.getJSONArray(0)
        assertEquals(harness.nowSec - 1, range.getLong(0))
        assertEquals(harness.nowSec - 1, range.getLong(1))
    }
}
