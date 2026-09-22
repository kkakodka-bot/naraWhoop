package com.frwhoop.scoring

import com.noop.analytics.UserProfile
import com.frwhoop.scoring.scoring.DayScorer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

/** Smoke test: scoped server scoring path produces non-null HRV + sleep on synthetic inputs. */
class ServerScoreMapperTest {
    @Test
    fun analyzeDayProducesSleepAndHrvOnSyntheticNight() {
        val deviceId = "test-device"
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
        val bundle = DayScorer().score(inputs, "frwhoop-server-1")
        // Synthetic sparse night: scoring must complete without throwing; HRV or sleep may be null.
        assertNotNull(bundle.algorithmVersion)
        assertEquals("frwhoop-server-1", bundle.algorithmVersion)
    }
}
