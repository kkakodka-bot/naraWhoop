package com.frwhoop.scoring

import com.frwhoop.scoring.scoring.RespirationContexts
import com.frwhoop.scoring.signals.PhysiologyShadowRunner
import com.noop.analytics.HeartRateWindows
import com.noop.analytics.SleepContextSpan
import com.noop.analytics.StageSegment
import org.junit.Assert.*
import org.junit.Test

class RespirationContextsTest {
    private fun quiet(start: Long = 0) = HeartRateWindows.Measurement(start, start + 300,
        60.0, 60.0, 1.0, 1.0, null, null, motionObservedSeconds = 300)
    private fun awake(start: Long = 0, end: Long = 300) = SleepContextSpan(start, end, "awake", "fixture")

    @Test fun quietMotionAloneDoesNotEstablishAwakeRest() {
        assertTrue(RespirationContexts.withAwakeRest(emptyList(), listOf(quiet()), emptyList(), emptyList()).isEmpty())
        val joined = listOf(awake(0, 120), awake(120, 300))
        assertEquals("qualified_awake_rest", RespirationContexts.withAwakeRest(emptyList(),
            listOf(quiet()), emptyList(), joined).single().kind)
        assertTrue(RespirationContexts.withAwakeRest(emptyList(), listOf(quiet()), emptyList(),
            listOf(awake(0, 120), awake(121, 300))).isEmpty())
    }

    @Test fun movingMissingAndOffBodyWindowsNeverQualify() {
        for (reason in listOf("insufficient_motion_matched_samples", "off_body_evidence")) {
            val window = quiet().copy(lowMotionBpm = null, lowMotionReason = reason)
            assertTrue(RespirationContexts.withAwakeRest(emptyList(), listOf(window), emptyList(), listOf(awake())).isEmpty())
        }
        assertTrue(RespirationContexts.withAwakeRest(emptyList(), listOf(quiet()), emptyList(),
            listOf(awake(), SleepContextSpan(299, 300, "off_body", "fixture"))).isEmpty())
        // Frequent sampled HR may tolerate and exclude a few moving seconds, but that does not
        // certify the full five-minute interval as a motion-clean respiration context.
        assertNotNull(quiet().copy(lowMotionSampleFraction = 280.0 / 300.0, movingSeconds = 20).lowMotionBpm)
        assertTrue(RespirationContexts.withAwakeRest(emptyList(),
            listOf(quiet().copy(lowMotionSampleFraction = 280.0 / 300.0, movingSeconds = 20)),
            emptyList(), listOf(awake())).isEmpty())

        val hr = (0L until 300).map { com.noop.data.HrSample("d", it, 60) }
        val gravity = (30L until 300).map { com.noop.data.GravitySample("d", it, 0.0, 0.0, 1.0, dynAccel = .01) }
        val missingMotion = HeartRateWindows.windows(0, 300, hr, gravity).single()
        assertNotNull(missingMotion.lowMotionBpm)
        assertEquals(270, missingMotion.motionObservedSeconds)
        assertTrue(RespirationContexts.withAwakeRest(emptyList(), listOf(missingMotion), emptyList(),
            listOf(awake())).isEmpty())
    }

    @Test fun conflictingSleepOrUnknownStateCannotBecomeRest() {
        for (state in listOf("state_unknown", "off_body", "sleep_unstaged")) {
            val stage = StageSegment(120, 150, "unknown", state = state)
            assertTrue(RespirationContexts.withAwakeRest(emptyList(), listOf(quiet()), listOf(stage), listOf(awake())).isEmpty())
        }
        val sleep = listOf(PhysiologyShadowRunner.Context(120.0, 240.0, "qualified_sleep"))
        assertEquals(sleep, RespirationContexts.withAwakeRest(sleep, listOf(quiet()), emptyList(), listOf(awake())))
    }

    @Test fun observedAwakeEpochsQualifyButUnknownEpochsDoNot() {
        val stages = listOf(StageSegment(0, 300, "wake", state = "awake"))
        assertEquals(1, RespirationContexts.withAwakeRest(emptyList(), listOf(quiet()), stages, emptyList()).size)
        assertTrue(RespirationContexts.withAwakeRest(emptyList(), listOf(quiet()),
            listOf(StageSegment(0, 300, "unknown", state = "awake")), emptyList()).isEmpty())
    }

    @Test fun touchingRestWindowsMergeWithoutBridgingAnIneligibleWindowOrSleep() {
        val sleep = listOf(PhysiologyShadowRunner.Context(1200.0, 1500.0, "qualified_sleep"))
        val contexts = RespirationContexts.withAwakeRest(sleep,
            listOf(quiet(0), quiet(300), quiet(600).copy(lowMotionBpm = null), quiet(900)),
            emptyList(), listOf(awake(0, 1200)))
        assertEquals(listOf(0.0 to 600.0, 900.0 to 1200.0, 1200.0 to 1500.0), contexts.map { it.start to it.end })
        assertEquals(listOf("qualified_awake_rest", "qualified_awake_rest", "qualified_sleep"), contexts.map { it.kind })
    }
}
