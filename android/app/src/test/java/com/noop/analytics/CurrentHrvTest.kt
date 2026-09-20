package com.noop.analytics

import com.noop.data.RrInterval
import org.junit.Assert.*
import org.junit.Test

class CurrentHrvTest {
    @Test fun queryWindowMatchesCompletedUtcMeasurement() {
        assertEquals(0 until 300, CurrentHrv.completedWindow(300))
        assertEquals(0 until 300, CurrentHrv.completedWindow(599))
        assertEquals(300 until 600, CurrentHrv.completedWindow(600))
        assertEquals(-300 until 0, CurrentHrv.completedWindow(0))
    }
    @Test fun provenFullWindowPreservesTrueZero() {
        val r = CurrentHrv.deriveObservations(hrvEvidence(), 300)!!
        assertEquals(0.0, r.rmssdMs, 1e-9); assertEquals(300, r.cleanBeats); assertEquals(1.0, r.coverage, 1e-9)
    }
    @Test fun cleanHighVariabilitySurvives() {
        assertEquals(800.0, CurrentHrv.deriveObservations(hrvEvidence(pattern = listOf(600.0, 1400.0)), 599)!!.rmssdMs, 1e-9)
    }
    @Test fun latestCompletedWindowCannotBorrowOldOrFutureData() {
        assertNull(CurrentHrv.deriveObservations(hrvEvidence(start = -300) + hrvEvidence(start = 300), 300))
        assertNull(CurrentHrv.deriveObservations(hrvEvidence(count = 30), 300))
    }
    @Test fun legacyRowsDoNotProveConsecutiveOriginalBeats() {
        assertNull(CurrentHrv.derive((0 until 300).map { RrInterval(deviceId = "d", ts = it.toLong(), rrMs = 1000) }, 300))
    }
}
