package com.frwhoop.scoring

import com.frwhoop.scoring.db.*
import com.frwhoop.scoring.scoring.*
import com.noop.analytics.*
import com.noop.data.DailyMetric
import com.noop.data.HrSample
import com.noop.data.SkinTempSample
import com.noop.protocol.DeviceFamily
import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneId
import java.util.UUID

class HistoricalThermalStateTest {
    private val source="20000000-0000-4000-8000-000000000001"
    private fun input(day:String,anchor:Double,raw:Int):SignalSampleReader.DayInputs {
        val b=UserDayBounds.forDay(day,ZoneId.of("UTC"))
        return SignalSampleReader.DayInputs(UUID.fromString("10000000-0000-4000-8000-000000000001"),day,source,
            0,b.dayLo,b.dayHi,UserProfile(),b.nightLo,b.nightHi,List(300) { HrSample(source,b.dayLo+it,60) },
            emptyList(),emptyList(),emptyList(),emptyList(),DeviceFamily.WHOOP4,
            skinTemp=List(300) { SkinTempSample(source,b.dayLo+it,raw) },skinTempAnchorRaw=anchor)
    }
    private fun result(i:SignalSampleReader.DayInputs):DayResult {
        val sleep=DetectedSleep(i.dayLo,i.dayLo+300,1.0,listOf(StageSegment(i.dayLo,i.dayLo+300,"light")),60,50.0)
        val mean=AnalyticsEngine.skinTempFunnel(listOf(sleep),i.hr,i.skinTemp,i.deviceFamily,i.skinTempAnchorRaw).mean
        return DayResult(DailyMetric(source,i.day,skinTempC=mean),listOf(sleep),emptyList(),null,null,nightlySkinTempC=mean)
    }

    @Test fun anchorChangeRefoldsStrictlyPriorRawEvidenceOnCommonScaleInsteadOfFakingDeviation() {
        val states=mutableListOf<HistoricalStateMachine.Commit>()
        repeat(15) { index ->
            val day=LocalDate.parse("2026-09-01").plusDays(index.toLong()).toString()
            val i=input(day,1100.0,1100)
            val seed=HistoryCheckpointReader.Seed(states.lastOrNull()?.state,states.map { it.state.getJSONObject("observation") })
            states+=HistoricalStateMachine.finish(i,result(i),HistoricalStateMachine.prepare(i,seed),emptyMap())
        }
        val original=states.first().state.toString()
        val i=input("2026-09-16",1150.0,1110)
        val p=HistoricalStateMachine.prepare(i,HistoryCheckpointReader.Seed(states.last().state,states.map { it.state.getJSONObject("observation") }))
        val expected=AnalyticsEngine.skinTempHistogramMean(mapOf(1100 to 300),DeviceFamily.WHOOP4,1150.0)!!
        assertEquals(expected,p.baselines.getValue("skin_temp").baseline,1e-10)
        assertEquals(15,p.baselines.getValue("skin_temp").nValid)
        val nightly=result(i).nightlySkinTempC!!
        assertEquals(.5,nightly-expected,1e-10)
        assertEquals(original,states.first().state.toString())
    }

    @Test fun histogramUsesExistingFunnelPlausibilityAndSampleCountGates() {
        for(anchor in listOf(826.0,1000.0,1100.0,1200.0,1290.0)) {
            val i=input("2026-09-18",anchor,1100)
            val rows=i.skinTemp.mapIndexed { index,s -> s.copy(raw=if(index<100) 2047 else if(index<200) 1000 else 1100) }
            val sleep=result(i).sleepSessions
            val expected=AnalyticsEngine.skinTempFunnel(sleep,i.hr,rows,DeviceFamily.WHOOP4,anchor).mean
            val actual=AnalyticsEngine.skinTempHistogramMean(rows.groupingBy { it.raw }.eachCount(),DeviceFamily.WHOOP4,anchor)
            assertEquals(expected,actual)
        }
        val i=input("2026-09-18",1100.0,1100)
        assertEquals(result(i).nightlySkinTempC,AnalyticsEngine.skinTempHistogramMean(mapOf(1100 to 300),DeviceFamily.WHOOP4,1100.0))
        assertNull(AnalyticsEngine.skinTempHistogramMean(mapOf(1100 to 299),DeviceFamily.WHOOP4,1100.0))
    }
}
