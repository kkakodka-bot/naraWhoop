package com.frwhoop.scoring

import com.noop.analytics.UserProfile
import com.frwhoop.scoring.scoring.DayScorer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

/** Sparse scalar input cannot establish either observed beat continuity or sleep. */
class ServerScoreMapperTest {
    @Test
    fun sparseNightKeepsHrvAndSleepUnavailable() {
        val deviceId = "00000000-0000-4000-8000-000000000002"
        val day = "2026-06-15"
        val nightStart = 1_749_513_600L - 8 * 3_600L
        val hr = (0 until 480).map { i ->
            com.noop.data.HrSample(deviceId, nightStart + i * 60L, if (i < 240) 52 else 68)
        }
        val rr = (0 until 200).map { i ->
            com.noop.data.RrInterval(deviceId, nightStart + i * 30L, 800 + (i % 5) * 10, 0)
        }
        val inputs = com.frwhoop.scoring.db.SignalSampleReader.DayInputs(
            userId = java.util.UUID.randomUUID(),
            day = day,
            deviceId = deviceId,
            tzOffsetSeconds = 0L,
            dayLo = nightStart - 8 * 3_600L,
            dayHi = nightStart + 16 * 3_600L - 1,
            profile = UserProfile(age = 35.0, sex = "male"),
            nightLo = nightStart - 3_600L,
            nightHi = nightStart + 12 * 3_600L,
            hr = hr,
            rr = rr,
            resp = emptyList(),
            gravity = emptyList(),
            events = emptyList(),
            deviceFamily = com.noop.protocol.DeviceFamily.WHOOP5,
        )
        val bundle = DayScorer().score(inputs, "frwhoop-physiology-2")
        assertNotNull(bundle.algorithmVersion)
        assertEquals("frwhoop-physiology-2", bundle.algorithmVersion)
        org.junit.Assert.assertNull(bundle.result.daily.avgHrv)
        org.junit.Assert.assertTrue(bundle.result.sleepSessions.isEmpty())
        try { DayScorer().score(inputs,"frwhoop-server-1"); org.junit.Assert.fail("version spoof must fail") }
        catch(_: IllegalArgumentException) {}
    }
}
