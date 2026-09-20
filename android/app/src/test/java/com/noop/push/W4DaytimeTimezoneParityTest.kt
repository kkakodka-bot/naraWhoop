package com.noop.push

import com.noop.analytics.DaytimeBaselines
import com.noop.analytics.DaytimeStress
import com.noop.data.HrSample
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/** Android app-source parity for the root-owned kernel extension; no copied formula implementation. */
class W4DaytimeTimezoneParityTest {
    private fun samples(date: String, zone: ZoneId): List<HrSample> {
        val day = LocalDate.parse(date)
        val lo = day.atStartOfDay(zone).toEpochSecond()
        val hi = day.plusDays(1).atStartOfDay(zone).toEpochSecond()
        return (lo until hi step 3600).flatMap { start ->
            val localHour = Instant.ofEpochSecond(start).atZone(zone).hour
            (0 until 300).map { HrSample("synthetic", start + it, 60 + localHour) }
        }
    }

    @Test fun shortLongAndFractionalLocalDaysPreserveExpectedWakingHours() {
        for ((date, zoneName) in listOf("2026-03-08" to "America/Los_Angeles", "2026-11-01" to "America/Los_Angeles",
            "2026-09-18" to "Asia/Kathmandu", "2000-01-15" to "Africa/Khartoum")) {
            val zone = ZoneId.of(zoneName); val day = LocalDate.parse(date); val hr = samples(date, zone)
            val result = DaytimeStress.analyze(hr, emptyList(), timezone = zone)
            val expected = (6 until 22).filter { zoneName != "Africa/Khartoum" || it != 12 }
            assertEquals(zoneName, expected, result.hours.map { it.hour })
            assertEquals(result.hours.map { it.startTs }.sorted().distinct(), result.hours.map { it.startTs })
            result.hours.forEach { hour ->
                val local = Instant.ofEpochSecond(hour.startTs).atZone(zone)
                assertEquals(day, local.toLocalDate()); assertEquals(0, local.minute)
                assertEquals(60.0 + hour.hour, hour.meanHr!!, 0.0)
            }
            val aggregate = DaytimeBaselines.dayDaytimeAggregate(hr, emptyList(), 0, zone)
            assertEquals(if (zoneName == "Africa/Khartoum") 67.4 else 67.5, aggregate.hr!!, 1e-10)
            assertNull(aggregate.rmssd)
        }
    }

    @Test fun additiveZonePathMatchesFixedOffsetWhenNoTransitionOccurs() {
        val zone = ZoneId.of("Asia/Kathmandu"); val hr = samples("2026-09-18", zone)
        val offset = zone.rules.getOffset(Instant.ofEpochSecond(hr.first().ts)).totalSeconds.toLong()
        assertEquals(DaytimeStress.analyze(hr, emptyList(), tzOffsetSeconds = offset),
            DaytimeStress.analyze(hr, emptyList(), timezone = zone))
        assertEquals(DaytimeBaselines.dayDaytimeAggregate(hr, emptyList(), offset),
            DaytimeBaselines.dayDaytimeAggregate(hr, emptyList(), 0, zone))
    }

    @Test fun explicitTimezoneControlsScorerAndHistoryFoldEvenWithWrongFixedOffset() {
        val zone = ZoneId.of("America/Los_Angeles"); val hr = samples("2026-03-08", zone)
        val expected = DaytimeStress.analyze(hr, emptyList(), timezone = zone)
        assertEquals(expected, DaytimeStress.analyze(hr, emptyList(), tzOffsetSeconds = 14 * 3600, timezone = zone))
        val correct = List(8) { DaytimeBaselines.DaytimeDayStreams(hr, emptyList(), 0, zone) }
        val wrongOffset = correct.map { it.copy(tzOffsetSeconds = 14 * 3600) }
        assertEquals(DaytimeBaselines.foldDaytimeBaselines(correct), DaytimeBaselines.foldDaytimeBaselines(wrongOffset))
    }
}
