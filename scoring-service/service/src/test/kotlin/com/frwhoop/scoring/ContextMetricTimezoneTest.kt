package com.frwhoop.scoring

import com.frwhoop.scoring.scoring.*
import com.noop.analytics.DaytimeBaselines
import com.noop.analytics.DaytimeStress
import com.noop.data.HrSample
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

class ContextMetricTimezoneTest {
    @Test fun actualShortLongAndFractionalOffsetDayBoundsPreserveWakingBuckets() {
        for ((date, zoneName, hours) in listOf(
            Triple("2026-03-08", "America/Los_Angeles", 23L),
            Triple("2026-11-01", "America/Los_Angeles", 25L),
            Triple("2026-09-18", "Asia/Kathmandu", 24L),
            Triple("2000-01-15", "Africa/Khartoum", 23L),
        )) {
            val day = LocalDate.parse(date); val zone = ZoneId.of(zoneName)
            val lo = day.atStartOfDay(zone).toEpochSecond(); val hi = day.plusDays(1).atStartOfDay(zone).toEpochSecond()
            assertEquals(hours * 3600L, hi - lo)
            val samples = mutableListOf<HrSample>()
            var start = lo - 3600
            while (start <= hi) {
                repeat(300) { samples += HrSample("s", start + it, 65 + (start / 3600 % 7).toInt()) }
                start += 3600
            }
            val input = HistoricalContextInputs(date, zoneName, emptyList(), emptyMap(), samples, emptyList(),
                emptyList(), emptyList(), emptyList(), false, false, emptyMap(), emptyList())
            val result = ContextMetricOrchestrator.evaluate(input)
            val timeline = result.charts.getJSONArray("daytime_stress")
            val starts = (0 until timeline.length()).map { timeline.getJSONObject(it).getLong("start") }
            assertEquals(starts.sorted().distinct(), starts)
            assertTrue(starts.all { it in lo until hi && Instant.ofEpochSecond(it).atZone(zone).hour in 6 until 22 })
            val expected = samples.filter { it.ts in lo until hi }
            val native = DaytimeStress.analyze(expected, emptyList(), timezone = zone)
            assertEquals(native.hours.map { it.startTs }, starts)
            val aggregate = DaytimeBaselines.dayDaytimeAggregate(expected, emptyList(), 0, timezone = zone)
            assertEquals(aggregate.hr, result.baselineObservations["daytime_hr"])
        }
    }

    @Test fun additiveTimezonePathMatchesLegacyFixedOffsetWithoutTransition() {
        val zone = ZoneId.of("Asia/Kathmandu")
        val lo = LocalDate.parse("2026-09-18").atStartOfDay(zone).toEpochSecond()
        val samples = (0L until 24L).flatMap { hour -> (0L until 300L).map { HrSample("s", lo + hour * 3600 + it, 60 + hour.toInt()) } }
        val offset = zone.rules.getOffset(Instant.ofEpochSecond(lo)).totalSeconds.toLong()
        assertEquals(DaytimeStress.analyze(samples, emptyList(), tzOffsetSeconds = offset),
            DaytimeStress.analyze(samples, emptyList(), timezone = zone))
        assertEquals(DaytimeBaselines.dayDaytimeAggregate(samples, emptyList(), offset),
            DaytimeBaselines.dayDaytimeAggregate(samples, emptyList(), 0, timezone = zone))
    }
}
