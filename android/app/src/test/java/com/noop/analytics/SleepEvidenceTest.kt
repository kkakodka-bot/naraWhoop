package com.noop.analytics

import com.noop.data.HrSample
import com.noop.data.GravitySample
import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Test

class SleepEvidenceTest {
    @Test fun sharedEvidenceOracle() {
        val fixtures = JSONArray(javaClass.getResource("/sleep_evidence_oracle.json")!!.readText())
        for (i in 0 until fixtures.length()) {
            val f = fixtures.getJSONObject(i)
            val segments = SleepStageSemantics.normalized(AnalyticsEngine.decodeStages(f.getJSONArray("segments").toString()), 0, 120)
            assertEquals(f.getString("name"), 120L, segments.sumOf { it.end - it.start })
            assertEquals(f.getLong("sleepSeconds"), segments.filter(SleepStageSemantics::isSleep).sumOf { it.end - it.start })
            val json = AnalyticsEngine.encodeStages(segments)!!
            assertEquals(segments, AnalyticsEngine.decodeStages(json))
            assertEquals(f.getDouble("knownSeconds") / 120, HypnogramCoverage.fraction(json, 120.0)!!, 1e-9)
            val totals = SleepStageTotals.minutes(json)!!
            assertEquals(f.getDouble("sleepSeconds"), totals.asleep * 60, 1e-9)
            assertEquals(120.0, totals.inBed * 60, 1e-9)
            assertEquals(f.getInt("knownSeconds") == 0, SleepStageTotals.dailyAggregate(listOf(json)) == null)
        }
    }
    @Test fun emptyAndInteriorMissingEpochsAbstain() {
        assertFalse(SleepStagerV2.stageSession(0, 180, emptyList(), emptyList(), emptyList(), emptyList()).any(SleepStageSemantics::isSleep))
        val hr = ((0L until 60L) + (120L until 180L)).map { HrSample("test", it, 55) }
        val segments = SleepStagerV2.stageSession(0, 180, emptyList(), hr, emptyList(), emptyList())
        for (t in 60L until 120L) assertEquals("state_unknown", segments.first { it.start <= t && t < it.end }.state)
    }
    @Test fun independentContextAndCausalFutureInvariance() {
        val base = listOf(StageSegment(0, 120, "light"))
        val context = listOf(SleepContextSpan(0, 30, "reading", "user", availableAt = 0),
            SleepContextSpan(30, 60, "off_body", "event", availableAt = 30),
            SleepContextSpan(60, 90, "sleep", "qualified_binary", qualifiedBinarySleep = true, availableAt = 60))
        val causal = SleepStageSemantics.applyingContext(base, 0, 120, context, "causal", 90)
        assertEquals(listOf("awake", "off_body", "sleep_unstaged", "state_unknown"), causal.map { it.state })
        val future = SleepStageSemantics.applyingContext(listOf(StageSegment(0, 120, "rem")), 0, 120,
            context + SleepContextSpan(0, 120, "phone_use", "late_report", availableAt = 121), "causal", 90)
        assertEquals(causal, future)
        assertFalse(SleepStageSemantics.applyingContext(emptyList(), 0, 120,
            listOf(SleepContextSpan(0, 120, "sleep", "manual"))).any(SleepStageSemantics::isSleep))
        assertEquals("awake", SleepStageSemantics.applyingContext(base, 0, 120, context).first().state)
    }
    @Test fun unknownDayUnavailableAndLateShiftUsesExactBounds() {
        val profile = UserProfile(weightKg = 75.0, heightCm = 178.0, age = 30.0, sex = "male")
        val start = AnalyticsEngine.dayStartUtcSeconds("2026-11-01")
        val unknown = DetectedSleep(start + 3600, start + 7200, 1.0, emptyList(), null, null)
        assertNull(AnalyticsEngine.analyzeDay("2026-11-01", profile = profile, providedSleep = listOf(unknown)).daily.totalSleepMin)
        val lo = start + 4 * 3600; val end = lo + 25 * 3600
        val nap = DetectedSleep(end - 3600, end - 60, 1.0,
            listOf(StageSegment(end - 3600, end - 60, "light")), null, null, boundaryProvenance = "manual_boundary")
        val result = AnalyticsEngine.analyzeDay("2026-11-01", profile = profile, providedSleep = listOf(nap), localDayStart = lo, localDayEndExclusive = end)
        assertEquals(1, result.sleepSessions.size)
        assertEquals("manual_boundary", result.sleepSessions.first().boundaryProvenance)
        assertEquals(59.0, result.daily.totalSleepMin!!, 1e-9)
    }

    @Test fun invalidHrAndGravityDoNotCreateEvidenceInEitherStager() {
        val hr=(0L until 3600L).map { HrSample("test",it,listOf(0,-1,241)[(it%3).toInt()]) }
        val gravity=(0L until 3600L).map { GravitySample("test",it,
            listOf(0.0,Double.NaN,Double.POSITIVE_INFINITY,Double.MAX_VALUE)[(it%4).toInt()],0.0,0.0) }
        for(v2 in listOf(false,true)) {
            val stages=if(v2) SleepStagerV2.stageSession(0,3600,gravity,hr,emptyList(),emptyList())
                else SleepStager.stageSession(0,3600,gravity,hr,emptyList(),emptyList())
            assertEquals(3600L,stages.sumOf { it.end-it.start })
            assertTrue(stages.all { it.state=="state_unknown" && it.evidenceCoverage==0.0 })
        }
    }

    @Test fun invalidPlaceholdersCannotChangeSparseFeaturesOrCachedResults() {
        val hr=(0L until 3600L step 5).map { HrSample("test",it,55) }
        val gravity=hr.map { GravitySample("test",it.ts,0.0,0.0,1.0) }
        val placeholders=(0L until 3600L).filter { it%5!=0L }
        val dirtyHr=(hr+placeholders.map { HrSample("test",it,0) }).sortedBy { it.ts }
        val dirtyGravity=(gravity+placeholders.map { GravitySample("test",it,
            if(it%2==0L) Double.NaN else 0.0,0.0,0.0) }).sortedBy { it.ts }
        for(v2 in listOf(false,true)) {
            fun stage(h: List<HrSample>,g: List<GravitySample>)=if(v2)
                SleepStagerV2.stageSession(0,3600,g,h,emptyList(),emptyList())
                else SleepStager.stageSession(0,3600,g,h,emptyList(),emptyList())
            val clean=stage(hr,gravity)
            assertEquals(clean,stage(dirtyHr,dirtyGravity))
            assertEquals(clean,stage(hr,gravity))
            if(v2) assertTrue(clean.all { it.state=="state_unknown" && it.evidenceCoverage==0.2 })
        }
    }
}
