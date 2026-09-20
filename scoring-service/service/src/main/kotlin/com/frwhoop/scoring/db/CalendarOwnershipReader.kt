package com.frwhoop.scoring.db

import java.sql.Connection
import java.util.UUID

/** A local date can own disjoint UTC intervals after travel across midnight or the date line. */
object CalendarOwnershipReader {
    const val MAX_CONTEXT_SECONDS = 76 * 3600L

    data class ZonedSegment(val start:Long,val end:Long,val timezoneId:String)

    data class Ownership(
        val dayIntervals: List<Pair<Long, Long>>,
        val contextIntervals: List<Pair<Long, Long>>,
        val timezoneIds: List<String>,
        val unavailableReason: String? = null,
        val zonedContext: List<ZonedSegment> = emptyList(),
    ) {
        val dayLo: Long? get() = dayIntervals.firstOrNull()?.first
        val dayHiInclusive: Long? get() = dayIntervals.lastOrNull()?.second?.minus(1)
        val contextLo: Long? get() = contextIntervals.firstOrNull()?.first
        val contextHiInclusive: Long? get() = contextIntervals.lastOrNull()?.second?.minus(1)
        /** Exclusive closing bounds use the zone of the final instant inside that interval. */
        fun timezoneAt(timestamp:Long,closingBound:Boolean=false):String? {
            val instant=if(closingBound) timestamp-1 else timestamp
            return zonedContext.singleOrNull { instant>=it.start && instant<it.end }?.timezoneId
        }
    }

    fun load(connection: Connection, userId: UUID, day: String): Ownership {
        val own = mutableListOf<Pair<Long, Long>>()
        val context = mutableListOf<Pair<Long, Long>>()
        val zones = linkedSetOf<String>()
        val zonedContext = mutableListOf<ZonedSegment>()
        connection.prepareStatement("""
            select calendar_day, s.* from (values (?::date-1), (?::date)) days(calendar_day)
            cross join lateral public.scoring_day_segments(?, calendar_day) s
            order by s.start_ts, s.end_ts, s.timezone_id
        """.trimIndent()).use { statement ->
            statement.setString(1, day); statement.setString(2, day); statement.setObject(3, userId)
            statement.executeQuery().use { rows ->
                while (rows.next()) {
                    val interval = rows.getLong("start_ts") to rows.getLong("end_ts")
                    context += interval
                    zonedContext += ZonedSegment(interval.first,interval.second,rows.getString("timezone_id"))
                    if (rows.getDate("calendar_day").toString() == day) {
                        own += interval
                        zones += rows.getString("timezone_id")
                    }
                }
            }
        }
        val dayIntervals = merge(own)
        val contextIntervals = merge(context)
        val reason = when {
            dayIntervals.isEmpty() -> "calendar_date_has_no_owned_time"
            contextIntervals.last().second - contextIntervals.first().first > MAX_CONTEXT_SECONDS -> "calendar_context_exceeds_limit"
            else -> null
        }
        return Ownership(dayIntervals, contextIntervals, zones.toList(), reason,zonedContext.distinct())
    }

    private fun merge(intervals: List<Pair<Long, Long>>): List<Pair<Long, Long>> {
        val result = mutableListOf<Pair<Long, Long>>()
        for (interval in intervals.sortedWith(compareBy({ it.first }, { it.second }))) {
            val previous = result.lastOrNull()
            if (previous != null && interval.first <= previous.second) {
                result[result.lastIndex] = previous.first to maxOf(previous.second, interval.second)
            } else result += interval
        }
        return result
    }
}
