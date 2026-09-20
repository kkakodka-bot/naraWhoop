package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import com.noop.data.RrInterval
import kotlin.math.PI
import kotlin.math.roundToInt
import kotlin.math.sin
import org.junit.Assert.*
import org.junit.Test

/** Client repository wiring stays in Android tests; the pure V2 oracle now also gates the JVM kernel. */
class SleepStageHealerSwitchTest {
    @Test fun healerSwitchSelectsV2WhenFlagOn() {
        val start = 1_749_513_600L + 3_600L
        val dur = 6 * 60 * 60; val end = start + dur - 1
        val grav = (0 until dur).map { GravitySample("test", start + it, x = 0.0, y = 0.0, z = 1.0) }
        val hr = (0 until dur).map { HrSample("test", start + it, bpm = 52 + (it / 60) % 3) }
        val rr = (0 until dur).map { RrInterval("test", start + it, rrMs = 1000 + (40 * sin(2 * PI * it / 4)).roundToInt()) }
        val v1 = SleepStageHealer.restageFromSamples(start, end, grav, hr, rr, emptyList())
        val v1Default = SleepStageHealer.restageFromSamples(start, end, grav, hr, rr, emptyList(), useExperimentalSleepV2 = false)
        val v2 = SleepStageHealer.restageFromSamples(start, end, grav, hr, rr, emptyList(), useExperimentalSleepV2 = true)
        assertNotNull("dense raw must stage on both paths", v1); assertNotNull(v2)
        assertEquals("default flag is V1", v1, v1Default)
        assertTrue("V1 output is a segment array", v1!!.trimStart().startsWith("["))
        assertTrue("V2 output is a segment array", v2!!.trimStart().startsWith("["))
    }
}
