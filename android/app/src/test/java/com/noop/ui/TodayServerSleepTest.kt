package com.noop.ui

import com.noop.analytics.SkinTempDisplay
import com.noop.data.DailyMetric
import com.noop.push.ServerScoreClient
import com.noop.push.ServerScoreDayCache
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class TodayServerSleepTest {
    private val day = "2026-09-16"
    private fun snapshot(minutes: Double?, status: String = "available"): ServerScoreDayCache {
        val root = JSONObject(javaClass.getResource("/server_physiology_snapshot.json")!!.readText())
        root.getJSONObject("server_scoring").getJSONObject("daily").put("sleep_total_min", minutes ?: JSONObject.NULL)
        root.getJSONObject("server_scoring").getJSONObject("features").getJSONObject("sleep").put("status", status)
        return ServerScoreClient.parseSnapshot(root.toString(), day, "11111111-1111-1111-1111-111111111111", 1000)
    }
    private fun value(local: Double?, cache: ServerScoreDayCache?, enabled: Boolean = true, selectedDay: String = day): String {
        val method = Class.forName("com.noop.ui.TodayScreenKt").declaredMethods.single { it.name == "dashboardCardValue" }
        method.isAccessible = true
        return method.invoke(null, DashboardCard.SLEEP, local?.let { DailyMetric("local", day, totalSleepMin = it) },
            null, null, null, null, null, null, null, null, null, null, null, null, null, null,
            0.0, 2000, emptyMap<String, Double>(), false, SkinTempDisplay.Kind.ABSOLUTE, cache, enabled, selectedDay) as String
    }
    private fun fraction(local: Double?, cache: ServerScoreDayCache?, enabled: Boolean = true): Double? {
        val method = Class.forName("com.noop.ui.TodayScreenKt").declaredMethods.single { it.name == "dashboardCardFraction" }
        method.isAccessible = true
        return method.invoke(null, DashboardCard.SLEEP, local?.let { DailyMetric("local", day, totalSleepMin = it) },
            null, null, null, null, null, null, null, null, null, cache, enabled, day) as Double?
    }
    @Test fun selectedServerSleepWinsOnTheActualDashboardWithMatchingFraction() {
        val cache = snapshot(480.0)
        assertEquals("8h 0m", value(120.0, cache)); assertEquals("8h 0m", value(null, cache))
        assertEquals(1.0, fraction(120.0, cache)!!, 0.0)
        assertEquals("2h 0m", value(120.0, cache, false)); assertEquals(0.25, fraction(120.0, cache, false)!!, 0.0)
    }
    @Test fun missingUnknownAndWrongDayServerSleepNeverBorrowLocalHistory() {
        for (cache in listOf(null, snapshot(null), snapshot(480.0, "unavailable"))) {
            assertEquals("noop:no-data", value(120.0, cache)); assertNull(fraction(120.0, cache))
        }
        assertEquals("noop:no-data", value(120.0, snapshot(480.0), selectedDay = "2026-09-15"))
    }
    @Test fun realZeroAndStaleServerSleepStayVisible() {
        assertEquals("0h 0m", value(120.0, snapshot(0.0))); assertEquals(0.0, fraction(120.0, snapshot(0.0))!!, 0.0)
        assertEquals("8h 0m", value(120.0, snapshot(480.0, "stale")))
    }
}
