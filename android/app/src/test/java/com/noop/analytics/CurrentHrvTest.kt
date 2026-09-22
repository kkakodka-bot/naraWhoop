package com.noop.analytics

import com.noop.data.RrInterval
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Trailing-window current HRV — Kotlin twin of `CurrentHRVTests.swift`.
 *
 * Expected literals for the fresh + ectopic cases are exported from unchanged Swift production:
 * `current-hrv-native-oracle.json`, Maxwell's 2026-09-18 CURRENT-HRV-NATIVE-ORACLE.md,
 * native `swift test --filter CurrentHRV` (6 passing tests). The original 0.8 expectation
 * incorrectly assumed coverage used filtered RR; both platforms sum RAW RR before HRV cleaning.
 */
class CurrentHrvTest {

    private fun rr(ts: Long, ms: Int, seq: Int = 0) = RrInterval(deviceId = "d", ts = ts, rrMs = ms, seq = seq)

    private fun steadyRows(now: Int, count: Int, rrMs: Int = 820): List<RrInterval> =
        (0 until count).map { i -> rr((now - (count - 1 - i)).toLong(), rrMs) }

    @Test
    fun freshWindowProducesValue() {
        val now = 1_700_000_000
        val snap = CurrentHrv.derive(steadyRows(now, 30), now)
        assertNotNull(snap)
        assertEquals(30, snap!!.cleanBeats)
        assertTrue(snap.coverage > 0.5)
        // Swift oracle: rmssd=0.0 clean=30 cov=0.8482758620689655
        assertEquals(0.0, snap.rmssdMs, 1e-9)
        assertEquals(0.8482758620689655, snap.coverage, 1e-12)
        assertEquals(now, snap.computedAtUnix)
    }

    @Test
    fun midWindowEctopicIsGapAware() {
        val now = 1_700_000_100
        val rrMs = MutableList(24) { 800 }
        rrMs[12] = 5000
        val rows = rrMs.mapIndexed { i, ms -> rr((now - (rrMs.size - 1 - i)).toLong(), ms) }
        val snap = CurrentHrv.derive(rows, now)
        assertNotNull(snap)
        // Actual Swift export: raw sum 23400 ms / 23000 ms span, not 23*800/23000.
        assertEquals(23_400, rrMs.sum())
        assertEquals(23L, rows.last().ts - rows.first().ts)
        assertEquals(23, snap!!.cleanBeats)
        assertEquals(0.0, snap.rmssdMs, 1e-9)
        assertEquals(1.017391304347826, snap.coverage, 1e-12)
        assertEquals(23_400.0 / 23_000.0, snap.coverage, 0.0)
        assertEquals(now, snap.computedAtUnix)
    }

    @Test
    fun rawCoverageHonestyGateStillRejectsEvenWhenInvalidBeatsWouldBeCleaned() {
        val now = 1_700_000_100
        val rows = steadyRows(now, 24, 800).toMutableList()
        rows[11] = rows[11].copy(rrMs = 5000)
        rows[12] = rows[12].copy(rrMs = 5000)
        assertEquals(1.2, HrvAnalyzer.rrCoverage(rows.map { it.ts }, rows.map { it.rrMs.toDouble() }), 0.0)
        assertNull(CurrentHrv.derive(rows, now))
    }

    @Test
    fun sparseWindowReturnsNull() {
        val now = 1_700_000_200
        assertNull(CurrentHrv.derive(steadyRows(now, 8), now))
    }

    @Test
    fun overCountedWindowReturnsNull() {
        val now = 1_700_000_300
        val base = steadyRows(now, 25, 820)
        val doubled = base.flatMap { listOf(rr(it.ts, it.rrMs, 0), rr(it.ts, it.rrMs, 1)) }
        assertNull(CurrentHrv.derive(doubled, now))
    }

    @Test
    fun rowsOutsideWindowIgnored() {
        val now = 1_700_000_400
        val inside = steadyRows(now, 25)
        val outside = steadyRows(now - CurrentHrv.WINDOW_SECONDS - 60, 25)
        val snap = CurrentHrv.derive(inside + outside, now)
        assertNotNull(snap)
        assertEquals(25, snap!!.cleanBeats)
    }
}
