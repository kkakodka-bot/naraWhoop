package com.frwhoop.scoring

import com.frwhoop.scoring.scoring.UserDayBounds
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test
import java.time.ZoneId

class UserDayBoundsTest {
    @Test
    fun dstSpringForwardUsesOffsetAtDayStart() {
        val zone = ZoneId.of("America/New_York")
        // 2026-03-08 is US spring-forward Sunday; offset at midnight EST is -18000.
        val bounds = UserDayBounds.forDay("2026-03-08", zone)
        assertEquals(-18_000L, bounds.tzOffsetSeconds)
        assertEquals(23L * 3600, bounds.dayHi - bounds.dayLo + 1)
        assertEquals(bounds.dayHi, bounds.nightHi)
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
