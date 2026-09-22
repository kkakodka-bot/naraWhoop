package com.noop.push

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ServerScoreClientTest {
    @Test
    fun parseSnapshot_readsServerScoringOverlay() {
        val body = """
            {
              "day": "2026-09-16",
              "server_scoring": {
                "algorithm_version": "frwhoop-server-1",
                "daily": {
                  "hrv_rmssd_ms": 41.0,
                  "resting_hr_bpm": 53,
                  "sleep_total_min": 400
                },
                "nights": [],
                "computed_at": "2026-09-16T08:00:00Z",
                "stale": false
              }
            }
        """.trimIndent()
        val cache = ServerScoreClient.parseSnapshot(body, "2026-09-16")
        assertEquals(41.0, cache.daily?.hrvRmssdMs)
        assertEquals(53, cache.daily?.restingHrBpm)
        assertEquals(false, cache.stale)
    }

    @Test
    fun parseSnapshot_nullDailyMarksStalePayload() {
        val body = """
            {
              "server_scoring": {
                "algorithm_version": "frwhoop-server-1",
                "daily": null,
                "nights": [],
                "computed_at": null,
                "stale": true
              }
            }
        """.trimIndent()
        val cache = ServerScoreClient.parseSnapshot(body, "2026-09-16")
        assertNull(cache.daily)
        assertEquals(true, cache.stale)
    }
}
