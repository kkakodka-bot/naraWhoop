package com.frwhoop.scoring

import com.frwhoop.scoring.db.EngineIngestWriter
import com.frwhoop.scoring.derived.DerivedArchivePayload
import com.frwhoop.scoring.scoring.CanonicalScorePayload
import com.frwhoop.scoring.scoring.ServerScoreBundle
import com.noop.analytics.DayResult
import com.noop.analytics.DetectedSleep
import com.noop.analytics.StageSegment
import com.noop.data.DailyMetric
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.util.UUID

class CanonicalScorePayloadTest {
    private val start = Instant.parse("2026-09-17T00:00:00Z").epochSecond

    @Test fun missingStagesRemainUnknownAndDoNotBecomeZeroSleepOrLowestHrAsMeanHr() {
        val payload = CanonicalScorePayload.build(bundle(emptyList()))
        val night = payload.getJSONArray("nights").getJSONObject(0)
        assertTrue(night.isNull("asleep_min"))
        assertFalse(night.getBoolean("measurement_available"))
        assertTrue(night.isNull("estimated_sleep_onset_at"))
        assertTrue(night.isNull("final_known_sleep_at"))
        assertEquals(5.0,night.getDouble("state_unknown_min"),0.0)
        assertEquals("uncertain",night.getString("episode_type"))
        assertTrue(payload.getJSONObject("daily").isNull("sleep_total_min"))
        assertTrue(payload.getJSONObject("daily").isNull("overnight_hr_bpm"))
        assertEquals(48,payload.getJSONObject("daily").getInt("resting_hr_bpm"))
    }

    @Test fun qualifiedUnstagedSleepAndStateUnknownReconcileWithoutCarryForward() {
        val stages = listOf(
            StageSegment(start,start+60,"deep"),
            StageSegment(start+120,start+180,"unknown",state="sleep_unstaged",evidenceCoverage=0.95),
            StageSegment(start+180,start+240,"wake"),
        )
        val night = CanonicalScorePayload.build(bundle(stages)).getJSONArray("nights").getJSONObject(0)
        assertEquals(2.0,night.getDouble("asleep_min"),0.0)
        assertEquals(1.0,night.getDouble("sleep_unstaged_min"),0.0)
        assertEquals(2.0,night.getDouble("state_unknown_min"),0.0)
        assertEquals(5.0,night.getDouble("asleep_min")+night.getDouble("awake_min")+
            night.getDouble("state_unknown_min"),0.0)
        assertEquals(10,night.getJSONArray("stages").length())
        val gap = night.getJSONArray("stages").getJSONObject(2)
        assertEquals("unknown",gap.getString("stage"))
        assertEquals("state_unknown",gap.getString("state"))
    }
    @Test fun conflictingEpochsCannotClaimKnownSleepBounds() {
        val night=CanonicalScorePayload.build(bundle(listOf(
            StageSegment(start,start+300,"deep"),StageSegment(start,start+300,"wake")
        ))).getJSONArray("nights").getJSONObject(0)
        assertTrue(night.isNull("estimated_sleep_onset_at"))
        assertTrue(night.isNull("final_known_sleep_at"))
        assertTrue(night.isNull("asleep_min"))
        assertEquals(5.0,night.getDouble("state_unknown_min"),0.0)
    }

    @Test fun publicationAndArchiveUseTheSameMappingAndComputationTimestamp() {
        val input=bundle(listOf(StageSegment(start,start+300,"light",pLight=0.7,
            pWake=0.1,pDeep=0.1,pRem=0.1,probabilitiesCalibrated=false)))
        val publication=EngineIngestWriter.buildPayload(input)
        val archive=DerivedArchivePayload.build(input)
        assertEquals(archive.getJSONObject("daily").toMap(),publication.getJSONArray("daily_metrics").getJSONObject(0).toMap())
        assertEquals(archive.getJSONArray("nights").toList(),publication.getJSONArray("sleep_nights").toList())
        val epoch=archive.getJSONArray("nights").getJSONObject(0).getJSONArray("stages").getJSONObject(0)
        assertEquals(0.7,epoch.getDouble("p_light"),0.0)
        assertEquals("uncalibrated",epoch.getString("calibration_status"))
        assertEquals(CanonicalScorePayload.hash(archive),CanonicalScorePayload.hash(DerivedArchivePayload.build(input)))
    }

    @Test fun canonicalEncodingIgnoresObjectInsertionOrder() {
        val first=JSONObject().put("a",1).put("b",JSONObject().put("z",false).put("x",JSONObject.NULL))
        val second=JSONObject().put("b",JSONObject().put("x",JSONObject.NULL).put("z",false)).put("a",1)
        assertEquals(CanonicalScorePayload.hash(first),CanonicalScorePayload.hash(second))
    }
    @Test fun respirationSummaryRetainsAcceptedDistributionAndEmptyUnavailability() {
        val summary=com.noop.analytics.RespirationEstimator.Summary(15.0,15.0,180.0,0.6,2,4,
            "qualified_sleep",listOf(12.0,18.0))
        val encoded=CanonicalScorePayload.build(bundle(emptyList()).copy(respirationSummary=summary))
            .getJSONObject("daily").getJSONObject("respiration_summary")
        assertEquals(listOf(12.0,18.0),encoded.getJSONArray("distribution_bpm").toList())
        assertEquals("sorted_accepted_window_estimates",encoded.getString("distribution_kind"))
        assertEquals("main_sleep",encoded.getString("context"))
        assertEquals("qualified_sleep",encoded.getString("measurement_context"))
        val empty=com.noop.analytics.RespirationEstimator.summarize(emptyList(),0.0,300.0,"qualified_sleep")
        val unavailable=CanonicalScorePayload.build(bundle(emptyList()).copy(respirationSummary=empty))
            .getJSONObject("daily").getJSONObject("respiration_summary")
        assertTrue(unavailable.isNull("median_bpm"));assertEquals(0,unavailable.getJSONArray("distribution_bpm").length())
    }

    @Test fun invalidProbabilityVectorsCannotPublishAndLegacyRespirationCannotMasqueradeAsV2() {
        for(stage in listOf(StageSegment(start,start+300,"light",pLight=0.7),
            StageSegment(start,start+300,"light",pWake=0.1,pLight=0.7,pDeep=0.2,pRem=0.2),
            StageSegment(start,start+300,"light",evidenceCoverage=1.1))) {
            try { CanonicalScorePayload.build(bundle(listOf(stage))); fail("invalid probability must be rejected") }
            catch(_: IllegalArgumentException) {}
        }
        val old=bundle(emptyList()).let { it.copy(result=it.result.copy(daily=it.result.daily.copy(respRateBpm=18.0))) }
        val payload=CanonicalScorePayload.build(old)
        assertTrue(payload.getJSONObject("daily").isNull("resp_rate_bpm"))
        assertEquals("sleep_context_unavailable",payload.getJSONObject("daily").getString("respiration_unavailable_reason"))
        assertEquals("acquisition_completeness_not_attested",payload.getString("publication_status_reason"))
    }

    private fun bundle(stages: List<StageSegment>): ServerScoreBundle {
        val device=UUID.fromString("00000000-0000-4000-8000-000000000002").toString()
        return ServerScoreBundle(UUID.fromString("00000000-0000-4000-8000-000000000001"),"2026-09-17",device,
            CanonicalScorePayload.ALGORITHM_VERSION,
            DayResult(DailyMetric(deviceId=device,day="2026-09-17",restingHr=48),
                listOf(DetectedSleep(start,start+300,1.0,stages,48,null)),emptyList(),null,null),
            computedAt=Instant.parse("2026-09-18T00:00:00Z"))
    }
}
