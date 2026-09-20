package com.frwhoop.scoring

import com.frwhoop.scoring.scoring.UserDayBounds
import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.ZoneId

class UserDayBoundsTest {
    @Test
    fun dstSpringForwardUsesOffsetAtDayStart() {
        val zone = ZoneId.of("America/New_York")
        // 2026-03-08 is US spring-forward Sunday; offset at midnight EST is -18000.
        val bounds = UserDayBounds.forDay("2026-03-08", zone)
        assertEquals(-18_000L, bounds.tzOffsetSeconds)
        assertEquals(23 * 3600L, bounds.dayHi - bounds.dayLo + 1)
        assertEquals(bounds.dayHi, bounds.nightHi)
        assertEquals(47 * 3600L, bounds.nightHi - bounds.nightLo + 1)
    }

    @Test fun autumnRepeatedHourAndAfternoonAreIncluded() {
        val zone = ZoneId.of("America/New_York")
        val bounds = UserDayBounds.forDay("2026-11-01", zone)
        assertEquals(25 * 3600L, bounds.dayHi - bounds.dayLo + 1)
        assertEquals(49 * 3600L, bounds.nightHi - bounds.nightLo + 1)
        val lateNap = java.time.LocalDateTime.parse("2026-11-01T23:30:00").atZone(zone).toEpochSecond()
        org.junit.Assert.assertTrue(lateNap in bounds.nightLo..bounds.nightHi)
    }

    @Test
    fun localDayKeyUsesUserZoneNotUtc() {
        val zone = ZoneId.of("America/Los_Angeles")
        // 2026-01-15 07:30 UTC is still 2026-01-14 evening in LA (PST).
        val ts = java.time.Instant.parse("2026-01-15T07:30:00Z").epochSecond
        assertEquals("2026-01-14", UserDayBounds.localDayKey(ts, zone))
        assertEquals("2026-01-15", UserDayBounds.localDayKey(ts, ZoneId.of("UTC")))
    }
}
