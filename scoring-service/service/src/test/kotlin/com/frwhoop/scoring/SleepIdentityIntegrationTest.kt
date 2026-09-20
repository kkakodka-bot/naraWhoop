package com.frwhoop.scoring

import com.frwhoop.scoring.db.ScoringWorkQueue
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

class SleepIdentityIntegrationTest : PgIntegrationBase() {
    @Test fun canonicalSleepIdSurvivesMultipleAlgorithmAndDayProjections() {
        val stable = "40000000-0000-4000-8000-000000000001"
        val start = Instant.parse("2026-09-15T00:00:00Z").epochSecond
        for ((version, date) in listOf("identity-a" to day, "identity-b" to day, "identity-b" to "2026-09-16")) {
            val q = ScoringWorkQueue(pg.db, version)
            sql("select register_scoring_algorithm_v2('$version')")
            q.dirtyWorkItem(u, device, date)
            sql("select expand_scoring_invalidations_v2(128)")
            val item = q.claim()!!
            assertEquals(date, item.day)
            val shift = if (date == day) 0 else 86400
            val s = JSONObject().put("id", stable).put("originalStart", start).put("originalEnd", start+28800)
                .put("editEntity", "sleep:$stable")
                .put("start_at", Instant.ofEpochSecond(start+shift).toString())
                .put("end_at", Instant.ofEpochSecond(start+shift+28800).toString())
                .put("is_nap", false).put("stages", JSONArray())
            assertNotNull(q.publish(item,payload(sleep=JSONArray().put(s)),1))
        }
        assertEquals("3", scalar("select count(*) from server_sleep_nights"))
        assertEquals("3", scalar("select count(distinct id) from server_sleep_nights"))
        assertEquals("1", scalar("select count(distinct payload->'sleep'->0->>'id') from scoring_snapshots_v2"))
        assertEquals(stable, scalar("select payload->'sleep'->0->>'id' from scoring_snapshots_v2 limit 1"))
    }
}
