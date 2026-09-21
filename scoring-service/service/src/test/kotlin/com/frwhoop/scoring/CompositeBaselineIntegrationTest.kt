package com.frwhoop.scoring

import com.frwhoop.scoring.db.CanonicalBaselineReader
import com.frwhoop.scoring.db.PostgresClient
import com.frwhoop.scoring.db.ScoringWorkQueue
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import java.time.LocalDate
import java.util.UUID

/** Synthetic publication controls on real PostgreSQL; not physiological accuracy evidence. */
class CompositeBaselineIntegrationTest {
    private lateinit var db: PostgresClient
    private lateinit var queue: ScoringWorkQueue
    private val user = UUID.randomUUID()
    private val device = UUID.randomUUID()
    private val day = LocalDate.of(2026, 7, 20)

    @Before fun setup() {
        val url = System.getenv("PHYSIOLOGY_TEST_DATABASE_URL")
        assumeTrue("Run scripts/test-physiology-queue.sh", url != null)
        require(url!!.contains("@127.0.0.1:") && url.endsWith("/physiology_queue_test"))
        db = PostgresClient(url); queue = ScoringWorkQueue(db)
        sql("insert into auth.users values('$user')")
        sql("insert into profiles(id,timezone) values('$user','UTC')")
        sql("insert into devices(id,user_id) values('$device','$user')")
        for (feature in listOf("hrv", "sleep", "respiration")) {
            SignedPromotionFixtures.register(db, SignedPromotionFixtures.prepare(db, feature))
            SignedPromotionFixtures.qualify(db, feature)
        }
        sql("insert into physiology_source_selection(user_id,feature,device_id,algorithm_version) " +
            "select '$user',feature,'$device','frwhoop-physiology-2' from physiology_feature_defaults")
    }

    @After fun close() { if (::db.isInitialized) { SignedPromotionFixtures.reset(db); db.close() } }

    @Test fun priorCalendarBaselinesRespectGapsCutoffAndExactDevice() {
        for (offset in 1L..4L) publish(claim(day.minusDays(offset)), daily())
        publish(claim(day), daily(90.0))
        publish(claim(day.plusDays(1)), daily(90.0))
        publish(claim(day.minusDays(29)), daily(90.0))
        val other = UUID.randomUUID()
        sql("insert into devices(id,user_id) values('$other','$user')")
        publish(claim(day.minusDays(5), other), daily(90.0))
        val baseline = load(day)
        assertEquals(4, baseline.hrv!!.nValid)
        assertTrue(baseline.hrv!!.usable)
        assertEquals(42.0, baseline.hrv!!.baseline, .00001)
        assertEquals(55.0, baseline.restingHR!!.baseline, .00001)
        assertEquals(14.0, baseline.resp!!.baseline, .00001)
        assertEquals(33.3, baseline.skinTemp!!.baseline, .00001)
        val gap = load(day.plusDays(17))
        assertFalse(gap.hrv!!.usable)
        assertTrue(gap.hrv!!.nightsSinceUpdate > com.noop.analytics.Baselines.staleDays)
        val wrongOwner = db.withConnection { CanonicalBaselineReader.load(it, UUID.randomUUID(), device, day.toString()) }
        assertEquals(0, wrongOwner.hrv!!.nValid)
    }

    @Test fun measurementCorrectionImmediatelyRemovesHistoryAndRestorationReturnsIt() {
        val source = day.minusDays(1)
        val first = claim(source)
        publish(first, daily())
        assertEquals(1, load(day).hrv!!.nValid)
        val correction = claim(source)
        assertEquals(0, load(day).hrv!!.nValid)
        publish(correction, daily())
        assertEquals(1, load(day).hrv!!.nValid)
    }

    @Test fun ineligibleOrOpenMeasurementsDoNotSeedBaselines() {
        val unrepresentative = daily().put("hrv_summary", JSONObject().put("representative", false))
        publish(claim(day.minusDays(1)), unrepresentative)
        publish(claim(day.minusDays(2)), daily(), closed = false)
        publish(claim(day.minusDays(3)), daily(), unavailable = "calendar_ownership_unavailable")
        val baseline = load(day)
        assertEquals(0, baseline.hrv!!.nValid)
        assertFalse(baseline.hrv!!.usable)
        assertEquals(1, baseline.restingHR!!.nValid)
        assertEquals(1, baseline.resp!!.nValid)
        assertEquals(1, baseline.skinTemp!!.nValid)
    }

    @Test fun eachScalarChangeInvalidatesOnlyExistingForward28DayJobsAndBaselineOnlyIsFixedPoint() {
        val source = claim(day)
        publish(source, daily())
        val near = claim(day.plusDays(28)); publish(near, JSONObject(), closed = false)
        val distant = claim(day.plusDays(29)); publish(distant, JSONObject(), closed = false)
        var expected = revision(day.plusDays(28))
        val values = daily()
        for ((key, value) in listOf("resting_hr_bpm" to 56.0, "resp_rate_bpm" to 15.0, "skin_temp_c" to 33.6)) {
            sql("select scoring_enqueue_dependency('$user','$device','$day')")
            values.put(key, value)
            publish(claim(day, dirty = false), values)
            expected++
            assertEquals(key, expected, revision(day.plusDays(28)))
            assertEquals(distant.inputRevision, revision(day.plusDays(29)))
        }
        sql("select scoring_enqueue_dependency('$user','$device','$day')")
        publish(claim(day, dirty = false), values.put("recovery", 99.0).put("rest", 95.0).put("skin_temp_dev_c", .6))
        assertEquals(expected, revision(day.plusDays(28)))
        val correction = claim(day)
        assertEquals(expected + 1, revision(day.plusDays(28)))
        publish(correction, values)
        assertEquals(expected + 2, revision(day.plusDays(28)))
    }

    @Test fun readbackPublishesRestUnderTheQualifiedSelectedSleepSource() {
        publish(claim(day), daily().put("rest", 72.5))
        val result = db.withConnection { connection ->
            connection.createStatement().use { it.execute("set request.jwt.claim.role='service_role'") }
            connection.createStatement().use { statement ->
                statement.executeQuery("select server_scoring_for_device_day('$user','$day','$device')::text").use {
                    it.next(); JSONObject(it.getString(1))
                }
            }
        }
        assertEquals(72.5, result.getJSONObject("daily").getDouble("rest"), 0.0)
        assertEquals(device.toString(), result.getJSONObject("features").getJSONObject("sleep").getString("device_id"))
    }

    @Test fun qualificationRevocationDropsBaselineAndInvalidatesDerivedDay() {
        publish(claim(day.minusDays(1)), daily())
        val target = claim(day); publish(target, JSONObject(), closed = false)
        assertEquals(1, load(day).hrv!!.nValid)
        try {
            sql("update physiology_feature_qualifications set qualification='shadow' where algorithm_version='frwhoop-physiology-2' and feature='hrv'")
            assertEquals(0, load(day).hrv!!.nValid)
            assertTrue(revision(day) > target.inputRevision)
        } finally {
            SignedPromotionFixtures.qualify(db, "hrv")
        }
    }

    private fun daily(hrv: Double = 42.0) = JSONObject().put("hrv_rmssd_ms", hrv)
        .put("hrv_summary", JSONObject().put("representative", true)).put("resting_hr_bpm", 55.0)
        .put("resp_rate_bpm", 14.0).put("respiration_summary", JSONObject().put("measurement_context", "qualified_sleep").put("accepted_windows", 2))
        .put("skin_temp_c", 33.3).put("sleep_total_min", 420.0)

    private fun load(day: LocalDate) = db.withConnection { CanonicalBaselineReader.load(it, user, device, day.toString()) }
    private fun claim(day: LocalDate, source: UUID = device, dirty: Boolean = true): ScoringWorkQueue.WorkItem {
        if (dirty) queue.dirtyWorkItem(user, source, day.toString())
        sql("update physiology_work_items set next_attempt_at=clock_timestamp() where user_id='$user' and device_id='$source' and day='$day'")
        return queue.claimOne(user, source, day.toString())!!
    }
    private fun publish(item: ScoringWorkQueue.WorkItem, daily: JSONObject, closed: Boolean = true, unavailable: String? = null) {
        val payload = JSONObject().put("schema_version", 2).put("user_id", user.toString()).put("device_id", item.deviceId.toString())
            .put("day", item.day).put("algorithm_version", "frwhoop-physiology-2").put("input_revision", item.inputRevision)
            .put("lease_token", item.leaseToken.toString()).put("run_id", item.runId.toString())
            .put("computed_at", "2026-09-18T00:00:00Z").put("publication_status", "provisional").put("period_closed", closed)
            .put("feature_manifest_hashes", SignedPromotionFixtures.hashes(db))
            .put("daily", daily.put("day", item.day).put("source_device_id", item.deviceId.toString()))
            .put("nights", JSONArray()).put("measurements", JSONArray())
        if (unavailable != null) payload.put("unavailable_reason", unavailable)
        db.withConnection { connection -> connection.prepareStatement("select engine_publish_physiology('test',?::jsonb)").use {
            it.setString(1, payload.toString()); it.execute()
        } }
        assertTrue(queue.markDone(item, 1))
    }
    private fun revision(day: LocalDate) = db.withConnection { connection -> connection.createStatement().use { statement ->
        statement.executeQuery("select input_revision from physiology_work_items where user_id='$user' and device_id='$device' and day='$day'").use {
            it.next(); it.getLong(1)
        }
    } }
    private fun sql(value: String) { db.withConnection { connection -> connection.createStatement().use { it.execute(value) } } }
}
