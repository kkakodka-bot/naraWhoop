package com.frwhoop.scoring.scoring

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/** Zone-correct local-day bounds for scoring (java.time twin of LocalDayWindows window math). */
object UserDayBounds {
    data class Bounds(
        val dayLo: Long,
        val dayHi: Long,
        val tzOffsetSeconds: Long,
        val nightLo: Long,
        val nightHi: Long,
    )

    fun forDay(day: String, zoneId: ZoneId): Bounds {
        val localDay = LocalDate.parse(day)
        val dayStart = localDay.atStartOfDay(zoneId)
        val nextDayStart = localDay.plusDays(1).atStartOfDay(zoneId)
        val dayLo = dayStart.toEpochSecond()
        val dayHi = nextDayStart.toEpochSecond() - 1
        val tzOffset = zoneId.rules.getOffset(dayStart.toInstant()).totalSeconds.toLong()
        // Full scoring day plus the preceding local day. Calendar arithmetic preserves DST boundaries.
        val nightLo = localDay.minusDays(1).atStartOfDay(zoneId).toEpochSecond()
        val nightHi = dayHi
        return Bounds(dayLo, dayHi, tzOffset, nightLo, nightHi)
    }

    fun localDayKey(epochSeconds: Long, zoneId: ZoneId): String {
        val zdt = Instant.ofEpochSecond(epochSeconds).atZone(zoneId)
        return zdt.toLocalDate().toString()
    }

    fun parseZone(timezoneName: String): ZoneId =
        runCatching { ZoneId.of(timezoneName) }.getOrDefault(ZoneId.of("UTC"))
}
