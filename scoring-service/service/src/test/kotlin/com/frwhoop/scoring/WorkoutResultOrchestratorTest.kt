package com.frwhoop.scoring

import com.frwhoop.scoring.db.*
import com.frwhoop.scoring.scoring.*
import com.noop.analytics.*
import com.noop.data.DailyMetric
import com.noop.data.StepSample
import com.noop.protocol.DeviceFamily
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.time.ZoneId
import java.util.UUID

class WorkoutResultOrchestratorTest {
    private val source="20000000-0000-4000-8000-000000000001"
    private val b=UserDayBounds.forDay("2026-09-18",ZoneId.of("UTC"))
    private val start=b.dayLo+3600
    private fun input(sport:String="Running",end:Long=start+4):SignalSampleReader.DayInputs {
        val edit=HistoryInputReader.Input("manual_workout","workout:40000000-0000-4000-8000-000000000001",1,false,JSONObject()
            .put("start",start).put("end",end).put("originalStart",start).put("originalSport",sport)
            .put("sport",sport).put("dismissed",false).put("steps",999))
        return SignalSampleReader.DayInputs(UUID.randomUUID(),"2026-09-18",source,0,b.dayLo,b.dayHi,UserProfile(stepTicksPerStep=2.0),
            b.nightLo,b.nightHi,emptyList(),emptyList(),emptyList(),emptyList(),emptyList(),DeviceFamily.WHOOP5,
            history=HistoryInputReader.Day(listOf(edit)),steps=listOf(
                StepSample(source,start-1,65530,1),StepSample(source,start,65534,1),StepSample(source,start+1,0,1),
                StepSample(source,start+2,2,0),StepSample(source,start+3,4,2),StepSample(source,start+4,6,2),
                StepSample(source,start+5,8,1)))
    }
    private fun output(i:SignalSampleReader.DayInputs)=WorkoutResultOrchestrator.evaluate(i,
        DayResult(DailyMetric(source,i.day),emptyList(),emptyList(),null,null))

    @Test fun inclusiveWorkoutCounterWrapActivityAndScaleMatchExistingSwiftDetailPolicy() {
        val w=output(input()).sessions.getJSONObject(0)
        assertEquals(6,w.getInt("stepCounterTicks"))
        assertEquals(3,w.getInt("strapSteps"))
        assertEquals(999,w.getInt("steps")) // Retained imported/manual value has separate provenance.
        assertTrue(w.isNull("avgHr"))
        val floor=output(input("  TREADMILL WALK  ").copy(profile=UserProfile(stepTicksPerStep=.1))).sessions.getJSONObject(0)
        assertEquals(12,floor.getInt("strapSteps"))
    }
    @Test fun missingStationaryAndNonFootCountersNeverFabricateZeroStepsOrCadence() {
        for(i in listOf(input("Cycling"),input().copy(steps=emptyList()),input().copy(steps=listOf(
            StepSample(source,start,42,1),StepSample(source,start+4,42,1))))) {
            val w=output(i).sessions.getJSONObject(0)
            assertTrue(w.isNull("strapSteps"));assertFalse(w.has("cadence"))
        }
    }
    @Test fun futureManualWorkoutCompletionCannotEnterHistoricalCountsOrStrengthMinutes() {
        val i=input("strength",b.dayHi+3600)
        val out=output(i)
        assertEquals(0,out.sessions.length());assertNull(out.count);assertNull(out.strengthMin)
        assertTrue(out.gaps.contains("manual_workout_ends_after_asof_cutoff"))
        val scored=DayScorer().score(i,"frwhoop-server-2-history",HistoricalStateMachine.prepare(i,HistoryCheckpointReader.Seed(null,emptyList())))
        assertFalse(scored.hasNonRawObservations)
        assertFalse(scored.coverageGaps.contains("context_derived_algorithms_not_integrated"))
    }
    @Test fun strengthDurationUsesTheExistingImportedActivityNamePredicate() {
        for(sport in listOf("Traditional Strength Training","Bodyweight training","WEIGHTLIFTING"))
            assertEquals(60.0,output(input(sport,start+3600)).strengthMin!!,0.0)
        assertEquals(0.0,output(input("Running",start+3600)).strengthMin!!,0.0)
    }
}
