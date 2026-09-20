package com.frwhoop.scoring

import com.frwhoop.scoring.db.SignalSampleReader
import com.frwhoop.scoring.scoring.CanonicalScorePayload
import com.frwhoop.scoring.scoring.DayScorer
import com.frwhoop.scoring.scoring.SleepBoundaryOverride
import com.noop.analytics.AnalyticsEngine
import com.noop.analytics.UserProfile
import com.noop.data.GravitySample
import com.noop.data.HrSample
import com.noop.protocol.DeviceFamily
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.util.UUID

/** Synthetic pipeline regression controls, not physiological/reference validation. */
class SleepAuditRegressionTest {
    private val user=UUID.fromString("11111111-1111-1111-1111-111111111111")
    private val device="22222222-2222-2222-2222-222222222222"
    private val day=AnalyticsEngine.dayStartUtcSeconds("2026-09-17")
    private val at=Instant.ofEpochSecond(day+86400)
    private fun input(): SignalSampleReader.DayInputs {
        val ranges=listOf(day+3*3600 until day+4*3600,day+13*3600 until day+15*3600)
        val hr=(day until day+86400 step 5).map { HrSample(device,it,if(ranges.any { span -> it in span }) 55 else 80) }
        val gravity=hr.map { GravitySample(device,it.ts,0.0,0.0,1.0) }
        return SignalSampleReader.DayInputs(user,"2026-09-17",device,0,day,day+86399,UserProfile(),
            day-86400,day+86399,hr,emptyList(),emptyList(),gravity,emptyList(),DeviceFamily.WHOOP5)
    }

    @Test fun qualifiedShiftSleepSurvivesCompetingNapAndManualRegrouping() {
        val original=input()
        val edited=original.copy(sleepOverrides=listOf(SleepBoundaryOverride("nap-edit",
            day+3*3600,day+4*3600,day+3*3600+60,day+4*3600,false,1,"user_annotation")))
        for(inputs in listOf(original,edited)) {
            val score=DayScorer().score(inputs,CanonicalScorePayload.ALGORITHM_VERSION,"audit",at)
            val payload=CanonicalScorePayload.build(score)
            assertEquals(listOf("nap","main_sleep"),score.result.sleepSessions.map { it.episodeType })
            assertEquals(120.0,payload.getJSONObject("daily").getDouble("sleep_total_min"),0.0)
            assertEquals(120.0,payload.getJSONArray("nights").getJSONObject(1).getDouble("sleep_unstaged_min"),0.0)
            assertFalse(payload.getJSONObject("daily").isNull("main_sleep_group_id"))
            if(inputs===edited) assertTrue(payload.getJSONArray("nights").getJSONObject(0).getBoolean("manual_edit"))
        }
    }

    @Test fun invalidRowsCannotPromoteBinarySleepToStagedSleep() {
        val original=input()
        val times=(day until day+86400).filter { it%5!=0L }
        val polluted=original.copy(
            hr=(original.hr+times.map { HrSample(device,it,0) }).sortedBy { it.ts },
            gravity=(original.gravity+times.map { GravitySample(device,it,0.0,0.0,0.0) }).sortedBy { it.ts })
        val clean=DayScorer().score(original,CanonicalScorePayload.ALGORITHM_VERSION,"audit",at)
        val dirty=DayScorer().score(polluted,CanonicalScorePayload.ALGORITHM_VERSION,"audit",at)
        assertEquals(clean.result.sleepSessions,dirty.result.sleepSessions)
        val expected=CanonicalScorePayload.build(clean).getJSONArray("nights")
        val actual=CanonicalScorePayload.build(dirty).getJSONArray("nights")
        assertEquals(CanonicalScorePayload.encode(expected),CanonicalScorePayload.encode(actual))
        assertTrue(dirty.result.sleepSessions.flatMap { it.stages }.all { it.state=="sleep_unstaged" })
    }
}
