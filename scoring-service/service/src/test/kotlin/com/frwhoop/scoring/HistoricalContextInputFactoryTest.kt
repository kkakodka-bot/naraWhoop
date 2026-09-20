package com.frwhoop.scoring

import com.frwhoop.scoring.db.HistoryCheckpointReader
import com.frwhoop.scoring.db.HistoryInputReader
import com.frwhoop.scoring.db.SignalSampleReader
import com.frwhoop.scoring.scoring.*
import com.noop.analytics.*
import com.noop.data.DailyMetric
import com.noop.data.HrSample
import com.noop.protocol.DeviceFamily
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.temporal.ChronoUnit
import java.util.UUID

class HistoricalContextInputFactoryTest {
    private val owner = UUID.fromString("10000000-0000-4000-8000-000000000001")
    private val source = "20000000-0000-4000-8000-000000000001"
    private fun input(day: String, zone: String = "UTC"): SignalSampleReader.DayInputs {
        val bounds = UserDayBounds.forDay(day, ZoneId.of(zone))
        return SignalSampleReader.DayInputs(owner, day, source, bounds.tzOffsetSeconds, bounds.dayLo, bounds.dayHi,
            UserProfile(), bounds.nightLo, bounds.nightHi, emptyList(), emptyList(), emptyList(), emptyList(), emptyList(),
            DeviceFamily.WHOOP5, timezone = zone)
    }
    private fun result(input: SignalSampleReader.DayInputs, sleep: List<DetectedSleep> = emptyList()) =
        DayResult(DailyMetric(source, input.day), sleep, emptyList(), null, null, null, null)
    private fun prepared(input: SignalSampleReader.DayInputs, previous: JSONObject? = null) = HistoricalStateMachine.prepare(
        input, HistoryCheckpointReader.Seed(previous, listOfNotNull(previous?.getJSONObject("observation"))))
    private fun sleep(start: Long, end: Long, observed: Boolean = true) = DetectedSleep(start, end, 1.0,
        if (observed) listOf(StageSegment(start, end, "light")) else emptyList(), null, null)

    @Test fun canonicalObservedMainNightSurvivesCheckpointButLaterNapNeverBecomesWake() {
        val day = input("2026-09-18")
        val night = sleep(day.dayLo, day.dayLo + 7 * 3600)
        val nap = sleep(day.dayLo + 14 * 3600, day.dayLo + 16 * 3600)
        val r = result(day, listOf(night, nap))
        val p = prepared(day)
        val naps = mapOf(SleepBounds(nap.start, nap.end) to true)
        val live = HistoricalContextInputFactory.build(day, r, p, naps)
        assertEquals(listOf(SleepBounds(night.start, night.end)), live.sleepBounds)
        val checkpoint = HistoricalStateMachine.finish(day, r, p, naps).state
        val next = input("2026-09-19")
        val replay = HistoricalContextInputFactory.build(next, result(next), prepared(next, checkpoint))
        assertEquals(live.sleepBounds, replay.sleepBounds)
        assertEquals(2, checkpoint.getJSONObject("observation").getJSONArray("sleepBlocks").length())
    }

    @Test fun unobservedManualNightAndExplicitLongNapCannotFabricateCircadianWake() {
        val day = input("2026-09-18")
        val night = sleep(day.dayLo, day.dayLo + 7 * 3600, observed = false)
        val nap = sleep(day.dayLo + 12 * 3600, day.dayLo + 22 * 3600)
        val r = result(day, listOf(night, nap))
        val p = prepared(day)
        val naps = mapOf(SleepBounds(nap.start, nap.end) to true)
        assertTrue(HistoricalContextInputFactory.build(day, r, p, naps).sleepBounds.isEmpty())
        assertTrue(HistoricalStateMachine.finish(day, r, p, naps).state.getJSONObject("observation").isNull("mainNightBounds"))
    }

    @Test fun wallHoursAndStoredReplayMatchForFractionalDstMiddayTransitionAndNonIntegerOffset() {
        for ((date, zoneName) in listOf("2026-10-04" to "Australia/Lord_Howe", "2026-04-05" to "Australia/Lord_Howe",
            "2000-01-15" to "Africa/Khartoum", "2026-09-18" to "Asia/Kathmandu")) {
            val zone = ZoneId.of(zoneName)
            val base = input(date, zoneName)
            val samples = generateSequence(base.dayLo) { it + 600 }.takeWhile { it <= base.dayHi }
                .mapIndexed { i, ts -> HrSample(source, ts, 60 + i % 30) }.toList()
            val day = base.copy(hr = samples + HrSample(source, base.dayLo, 0) + HrSample(source, base.dayHi + 1, 200))
            val r = result(day); val p = prepared(day)
            val expected = samples.groupBy { Instant.ofEpochSecond(it.ts).atZone(zone).truncatedTo(ChronoUnit.HOURS).toEpochSecond() }
                .toSortedMap().map { (start, rows) -> HistoricalHourlyObservation(start, rows.map { it.bpm }.average(), rows.size) }
            val live = HistoricalContextInputFactory.build(day, r, p)
            assertEquals("live $date $zoneName", expected, live.hourlyHr)
            val checkpoint = HistoricalStateMachine.finish(day, r, p, emptyMap()).state
            val next = input(LocalDate.parse(date).plusDays(1).toString(), zoneName)
            assertEquals("replay $date $zoneName", expected,
                HistoricalContextInputFactory.build(next, result(next), prepared(next, checkpoint)).hourlyHr)
            if (zoneName == "Australia/Lord_Howe") assertTrue("fixture distinguishes elapsed-hour bins", samples.any {
                base.dayLo + Math.floorDiv(it.ts - base.dayLo, 3600) * 3600 !=
                    Instant.ofEpochSecond(it.ts).atZone(zone).truncatedTo(ChronoUnit.HOURS).toEpochSecond()
            })
        }
    }

    @Test fun repeatedWallHourRetainsBothOffsetsAndOnlyObservedBins() {
        val base = input("2026-11-01", "America/Los_Angeles")
        val times = listOf("2026-11-01T08:30:00Z", "2026-11-01T09:30:00Z")
        val day = base.copy(hr = times.mapIndexed { i, ts -> HrSample(source, Instant.parse(ts).epochSecond, 60 + i * 10) })
        val actual = HistoricalContextInputFactory.build(day, result(day), prepared(day)).hourlyHr
        assertEquals(listOf("2026-11-01T08:00:00Z", "2026-11-01T09:00:00Z").map { Instant.parse(it).epochSecond }, actual.map { it.start })
        assertEquals(listOf(60.0, 70.0), actual.map { it.meanHr })
        assertEquals(listOf(1, 1), actual.map { it.sampleCount })
    }

    @Test fun sparseObservedHistoryKeepsCalendarSlotsAndMissingYesterdayStaysNull() {
        val first=input("2026-03-22")
        val oldResult=result(first).copy(daily=DailyMetric(source,first.day,avgHrv=50.0,restingHr=60))
        val checkpoint=HistoricalStateMachine.finish(first,oldResult,prepared(first),emptyMap()).state
        val day=input("2026-09-18")
        val p=prepared(day,checkpoint)
        val built=HistoricalContextInputFactory.build(day,result(day),p)
        assertEquals(181,built.history.size)
        assertEquals("2026-09-17",built.history[built.history.lastIndex-1].day)
        assertNull(built.history[built.history.lastIndex-1].daily.avgHrv)
        assertTrue(built.history[built.history.lastIndex-1].baselinesBefore.isEmpty())
        assertNull(built.history.last().daily.restingHr)
        assertEquals(179,built.baselinesBefore.getValue("hrv").nightsSinceUpdate)
        assertFalse(built.baselinesBefore.getValue("hrv").usable)
        assertFalse(built.baselinesBefore.getValue("hrv").trusted)
        assertTrue(built.hourlyHr.isEmpty())
        assertTrue(built.sleepBounds.isEmpty())
        assertEquals(1,HistoricalContextInputFactory.build(day,result(day),prepared(day)).history.size)
    }

    @Test fun separateResetEpochsReachHelperAndCheckpointWithoutUsingDisplayOffset() {
        val base=input("2026-09-18","Pacific/Kiritimati")
        val hrv=Instant.parse("2026-09-12T12:00:00Z").epochSecond
        val recovery=Instant.parse("2026-09-15T00:00:00Z").epochSecond
        val config=JSONObject().put("hrvBaselineEpoch",hrv).put("recoveryBaselineEpoch",recovery)
        val day=base.copy(history=HistoryInputReader.Day(listOf(HistoryInputReader.Input("config","primary",1,false,config))))
        val p=prepared(day)
        val built=HistoricalContextInputFactory.build(day,result(day),p)
        assertEquals(hrv.toDouble(),built.baselineEpochSeconds.getValue("hrv"),0.0)
        assertEquals(hrv.toDouble(),built.baselineEpochSeconds.getValue("readiness_hrv_ln"),0.0)
        for(key in listOf("resting_hr","resp","skin_temp","daytime_hr","daytime_rmssd"))
            assertEquals(key,recovery.toDouble(),built.baselineEpochSeconds.getValue(key),0.0)
        val stored=HistoricalStateMachine.finish(day,result(day),p,emptyMap()).state.getJSONObject("observation")
            .getJSONObject("baselineEpochSeconds")
        assertEquals(built.baselineEpochSeconds.keys,stored.keySet())
        assertEquals(hrv.toDouble(),stored.getDouble("hrv"),0.0)
        assertEquals(recovery.toDouble(),stored.getDouble("resting_hr"),0.0)
    }

    @Test fun splitMainNightPreservesBothObservedFragmentsAcrossActualZoneTransitions() {
        for((date,name) in listOf("2026-03-08" to "America/Los_Angeles","2026-11-01" to "America/Los_Angeles",
            "2026-10-04" to "Australia/Lord_Howe","2026-04-05" to "Australia/Lord_Howe",
            "2026-09-18" to "Asia/Kathmandu")) {
            val zone=ZoneId.of(name);val day=LocalDate.parse(date);val i=input(date,name)
            val start=day.minusDays(1).atTime(23,0).atZone(zone).toEpochSecond()
            val finish=day.atTime(7,0).atZone(zone).toEpochSecond()
            val middle=start+(finish-start)/2
            val parts=listOf(sleep(start,middle),sleep(middle+15*60,finish))
            val nap=sleep(day.atTime(14,0).atZone(zone).toEpochSecond(),day.atTime(15,0).atZone(zone).toEpochSecond())
            val r=result(i,parts+nap);val p=prepared(i);val naps=mapOf(SleepBounds(nap.start,nap.end) to true)
            assertEquals("$date $name",listOf(SleepBounds(start,finish)),HistoricalContextInputFactory.build(i,r,p,naps).sleepBounds)
            val stored=HistoricalStateMachine.finish(i,r,p,naps).state.getJSONObject("observation")
            assertEquals(start,stored.getJSONObject("mainNightBounds").getLong("start"))
            assertEquals(finish,stored.getJSONObject("mainNightBounds").getLong("end"))
            assertEquals(3,stored.getJSONArray("sleepBlocks").length())
        }
    }
}
