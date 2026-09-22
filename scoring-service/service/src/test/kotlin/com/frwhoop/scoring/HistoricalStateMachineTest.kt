package com.frwhoop.scoring

import com.frwhoop.scoring.db.HistoryCheckpointReader
import com.frwhoop.scoring.db.HistoryInputReader
import com.frwhoop.scoring.db.SignalSampleReader
import com.frwhoop.scoring.scoring.*
import com.noop.analytics.*
import com.noop.data.DailyMetric
import com.noop.protocol.DeviceFamily
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneId
import java.util.UUID

class HistoricalStateMachineTest {
    private val owner=UUID.fromString("10000000-0000-4000-8000-000000000001")
    private val device="20000000-0000-4000-8000-000000000001"
    private fun inputs(day: String,config: JSONObject=JSONObject(),zone:String="UTC"): SignalSampleReader.DayInputs {
        val b=UserDayBounds.forDay(day,ZoneId.of(zone))
        return SignalSampleReader.DayInputs(owner,day,device,b.tzOffsetSeconds,b.dayLo,b.dayHi,UserProfile(),
            b.nightLo,b.nightHi,emptyList(),emptyList(),emptyList(),emptyList(),emptyList(),DeviceFamily.WHOOP5,zone,
            HistoryInputReader.Day(listOf(HistoryInputReader.Input("config","primary",1,false,config))))
    }
    private fun result(day: String,hrv:Double?=50.0,sleep:Double?=420.0): DayResult =
        DayResult(DailyMetric(device,day,totalSleepMin=sleep,avgHrv=hrv,restingHr=60,respRateBpm=15.0,strain=20.0),emptyList(),emptyList(),null,20.0)
    private fun replay(count:Int): List<HistoricalStateMachine.Commit> {
        val out=mutableListOf<HistoricalStateMachine.Commit>()
        repeat(count) { i ->
            val date=LocalDate.parse("2026-01-01").plusDays(i.toLong()).toString()
            val seed=HistoryCheckpointReader.Seed(out.lastOrNull()?.state,out.map { it.state.getJSONObject("observation") })
            val input=inputs(date)
            out+=HistoricalStateMachine.finish(input,result(date,50.0+i%3),HistoricalStateMachine.prepare(input,seed),emptyMap())
        }
        return out
    }

    @Test fun baselineBeforeDayExcludesTodaysValueAndReplayIsDeterministic() {
        val a=replay(40); val b=replay(40)
        assertTrue(a.last().state.similar(b.last().state))
        assertEquals(0,a.first().prepared.baselines.getValue("hrv").nValid)
        assertEquals(39,a.last().prepared.baselines.getValue("hrv").nValid)
        assertEquals(Baselines.foldHistory((0 until 39).map { 50.0+it%3 },Baselines.hrvCfg),a.last().prepared.baselines.getValue("hrv"))
    }

    @Test fun futureAndUnorderedObservationsAreRejected() {
        val rows=replay(3)
        for(history in listOf(rows.map { it.state.getJSONObject("observation") },rows.reversed().map { it.state.getJSONObject("observation") })) {
            assertThrows(IllegalArgumentException::class.java) {
                HistoricalStateMachine.prepare(inputs("2026-01-02"),HistoryCheckpointReader.Seed(null,history))
            }
        }
    }

    @Test fun missingCalendarDaysAgeBaselineWithoutCreatingSleepDebtNights() {
        val rows=replay(15)
        val input=inputs("2026-02-01")
        val p=HistoricalStateMachine.prepare(input,HistoryCheckpointReader.Seed(rows.last().state,rows.map { it.state.getJSONObject("observation") }))
        assertEquals(16,p.baselines.getValue("hrv").nightsSinceUpdate)
        assertEquals(BaselineStatus.STALE,p.baselines.getValue("hrv").status)
        val done=HistoricalStateMachine.finish(input,result(input.day,null,null),p,emptyMap())
        assertEquals(14,done.sleepDebt.nightCount)
        assertEquals("2026-01-15",done.sleepDebt.nights.last().day)
    }

    @Test fun warmGapAcrossResetAgesOnlyEligibleDaysForEachMetricFamily() {
        val epoch=LocalDate.parse("2026-01-11").atStartOfDay(ZoneId.of("UTC")).toEpochSecond().toDouble()
        for(reset in listOf("hrvBaselineEpoch","recoveryBaselineEpoch")) {
            val config=JSONObject().put(reset,epoch)
            val firstInput=inputs("2026-01-01",config)
            val first=HistoricalStateMachine.finish(firstInput,result(firstInput.day),
                HistoricalStateMachine.prepare(firstInput,HistoryCheckpointReader.Seed(null,emptyList())),emptyMap())
            val history=listOf(first.state.getJSONObject("observation"))
            val next=inputs("2026-01-21",config)
            val warm=HistoricalStateMachine.prepare(next,HistoryCheckpointReader.Seed(first.state,history))
            val cold=HistoricalStateMachine.prepare(next,HistoryCheckpointReader.Seed(null,history))
            val resetKey=if(reset=="hrvBaselineEpoch") "hrv" else "resting_hr"
            val controlKey=if(reset=="hrvBaselineEpoch") "resting_hr" else "hrv"
            assertEquals(reset,10,warm.baselines.getValue(resetKey).nightsSinceUpdate)
            assertEquals(reset,19,warm.baselines.getValue(controlKey).nightsSinceUpdate)
            assertEquals(reset,cold.baselines,warm.baselines)
            assertTrue(HistoricalStateMachine.finish(next,result(next.day),warm,emptyMap()).state.similar(
                HistoricalStateMachine.finish(next,result(next.day),cold,emptyMap()).state))
        }
    }

    @Test fun warmGapIntersectsExactFractionalAndFutureResetEpochsUsingUTCDateKeys() {
        // Missing dates are Jan 2...20. The target Jan 21 is admitted only by finish.
        val cases=listOf(Triple(0,0.0,19),Triple(0,0.25,19),Triple(1,0.0,19),Triple(10,0.0,10),
            Triple(10,0.25,9),Triple(19,0.0,1),Triple(20,0.0,0),Triple(20,0.25,0),Triple(21,0.0,0))
        val start=LocalDate.parse("2026-01-01")
        for(reset in listOf("hrvBaselineEpoch","recoveryBaselineEpoch")) for(zone in listOf("UTC","Asia/Kathmandu")) {
            for((epochDay,fraction,age) in cases) {
                val epoch=start.plusDays(epochDay.toLong()).atStartOfDay(ZoneId.of("UTC")).toEpochSecond()+fraction
                val config=JSONObject().put(reset,epoch)
                val firstInput=inputs(start.toString(),config,zone)
                val first=HistoricalStateMachine.finish(firstInput,result(firstInput.day),
                    HistoricalStateMachine.prepare(firstInput,HistoryCheckpointReader.Seed(null,emptyList())),emptyMap())
                val history=listOf(first.state.getJSONObject("observation"))
                val next=inputs("2026-01-21",config,zone)
                val warm=HistoricalStateMachine.prepare(next,HistoryCheckpointReader.Seed(first.state,history))
                val cold=HistoricalStateMachine.prepare(next,HistoryCheckpointReader.Seed(null,history))
                val key=if(reset=="hrvBaselineEpoch") "hrv" else "resting_hr"
                val label="$reset/$zone/$epochDay+$fraction"
                assertEquals(label,age,warm.baselines.getValue(key).nightsSinceUpdate)
                assertEquals(label,cold.baselines,warm.baselines)
                val done=HistoricalStateMachine.finish(next,result(next.day),warm,emptyMap())
                assertTrue(label,done.state.similar(HistoricalStateMachine.finish(next,result(next.day),cold,emptyMap()).state))
                val firstValid=if(epochDay==0 && fraction==0.0) 1 else 0
                val currentValid=if(epochDay<20 || epochDay==20 && fraction==0.0) 1 else 0
                assertEquals(label,firstValid+currentValid,
                    HistoricalStateMachine.decodeBaselines(done.state.getJSONObject("baselinesAfter")).getValue(key).nValid)
            }
        }
    }

    @Test fun serializedWarmGapCanResumeBeforeOrOnResetWithoutAgingExcludedDays() {
        val epoch=LocalDate.parse("2026-01-11").atStartOfDay(ZoneId.of("UTC")).toEpochSecond()+0.25
        for(reset in listOf("hrvBaselineEpoch","recoveryBaselineEpoch")) for(middleDay in listOf("2026-01-06","2026-01-11","2026-01-12")) {
            val config=JSONObject().put(reset,epoch)
            val firstInput=inputs("2026-01-01",config)
            val first=HistoricalStateMachine.finish(firstInput,result(firstInput.day),
                HistoricalStateMachine.prepare(firstInput,HistoryCheckpointReader.Seed(null,emptyList())),emptyMap())
            val history=mutableListOf(first.state.getJSONObject("observation"))
            val middleInput=inputs(middleDay,config)
            val middle=HistoricalStateMachine.finish(middleInput,result(middleDay),
                HistoricalStateMachine.prepare(middleInput,HistoryCheckpointReader.Seed(first.state,history)),emptyMap())
            val restored=JSONObject(middle.state.toString())
            history+=restored.getJSONObject("observation")
            val next=inputs("2026-01-21",config)
            val warm=HistoricalStateMachine.prepare(next,HistoryCheckpointReader.Seed(restored,history))
            val cold=HistoricalStateMachine.prepare(next,HistoryCheckpointReader.Seed(null,history))
            assertEquals("$reset/$middleDay",cold.baselines,warm.baselines)
            assertTrue(HistoricalStateMachine.finish(next,result(next.day),warm,emptyMap()).state.similar(
                HistoricalStateMachine.finish(next,result(next.day),cold,emptyMap()).state))
        }
    }

    @Test fun recalibrationAndSourceEraDoNotReuseOldBaseline() {
        val rows=replay(15); val seed=HistoryCheckpointReader.Seed(rows.last().state,rows.map { it.state.getJSONObject("observation") })
        val epoch=LocalDate.parse("2026-01-12").atStartOfDay(ZoneId.of("UTC")).toEpochSecond()
        val p=HistoricalStateMachine.prepare(inputs("2026-01-16",JSONObject().put("hrvBaselineEpoch",epoch)),seed)
        assertEquals(4,p.baselines.getValue("hrv").nValid)
        assertEquals(15,p.baselines.getValue("resting_hr").nValid)
        val era=HistoricalStateMachine.prepare(inputs("2026-01-16",JSONObject().put("sourceEra","replacement")),seed)
        assertEquals(0,era.baselines.getValue("hrv").nValid)
        assertTrue(era.history.isEmpty())
    }

    @Test fun debtUsesExistingCappedRecurrenceAndNoDataIsNotZero() {
        val rows=replay(30)
        val expected=SleepDebt.ledger((0 until 30).map { LocalDate.parse("2026-01-01").plusDays(it.toLong()).toString() to 420.0 },8.0)
        assertEquals(expected,rows.last().sleepDebt)
    }

    @Test fun fullDailyMetricCodecPreservesNullsBooleansAndAllExistingFields() {
        val daily=DailyMetric(device,"2026-01-01",480.0,0.9,80.0,100.0,300.0,3,54,66.0,70.0,42.0,2,
            97.0,0.2,15.5,12000,800.0,400,500,80.0,33.0,true)
        assertEquals(daily,DailyMetricJson.decode(DailyMetricJson.encode(daily)))
        assertEquals(DailyMetric(device,"2026-01-01"),DailyMetricJson.decode(DailyMetricJson.encode(DailyMetric(device,"2026-01-01"))))
    }

    @Test fun checkpointRestartAndFreshReplayAgreeAcrossIndependentResetPolicies() {
        val initial=replay(40)
        val epoch=LocalDate.parse("2026-02-08").atStartOfDay(ZoneId.of("UTC")).toEpochSecond()
        for(reset in listOf("hrvBaselineEpoch","recoveryBaselineEpoch")) {
            val config=JSONObject().put(reset,epoch)
            val rows=initial.map { it.state.getJSONObject("observation") }.toMutableList()
            val firstInput=inputs("2026-02-10",config)
            val first=HistoricalStateMachine.prepare(firstInput,HistoryCheckpointReader.Seed(initial.last().state,rows))
            assertEquals(if(reset=="hrvBaselineEpoch") 2 else 40,first.baselines.getValue("hrv").nValid)
            assertEquals(if(reset=="recoveryBaselineEpoch") 2 else 40,first.baselines.getValue("resting_hr").nValid)
            val committed=HistoricalStateMachine.finish(firstInput,result(firstInput.day),first,emptyMap()).state
            // A process restart receives only immutable JSON, not retained baseline objects.
            val reopened=JSONObject(committed.toString())
            rows+=reopened.getJSONObject("observation")
            val next=inputs("2026-02-13",config)
            val resumed=HistoricalStateMachine.prepare(next,HistoryCheckpointReader.Seed(reopened,rows))
            val refolded=HistoricalStateMachine.prepare(next,HistoryCheckpointReader.Seed(null,rows))
            assertEquals(reset,refolded.baselines,resumed.baselines)
            assertEquals(2,resumed.baselines.getValue("hrv").nightsSinceUpdate)
            val resetKey=if(reset=="hrvBaselineEpoch") "hrv" else "resting_hr"
            assertFalse(resumed.baselines.getValue(resetKey).trusted)
            val current=HistoricalContextInputFactory.build(next,result(next.day),resumed)
            assertNull(current.history[current.history.lastIndex-1].daily.restingHr)
            assertEquals(epoch.toDouble(),current.baselineEpochSeconds.getValue(resetKey),0.0)
        }
    }
}
