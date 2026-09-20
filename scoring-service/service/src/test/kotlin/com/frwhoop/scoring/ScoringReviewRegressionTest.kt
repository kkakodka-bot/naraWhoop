package com.frwhoop.scoring

import com.frwhoop.scoring.db.EngineIngestWriter
import com.frwhoop.scoring.db.ScoringWorkQueue
import com.frwhoop.scoring.db.SignalSampleReader
import com.frwhoop.scoring.scoring.DayScorer
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
import java.sql.Connection
import java.time.Instant
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit

/** Reviewer schedules run against the actual queue, legacy RPC, projection tables and reader. */
class ScoringReviewRegressionTest : PgIntegrationBase() {
    private val version = "frwhoop-server-1"

    private fun legacyPayload(score: Double = 1.0, targetDay: String = day) = JSONObject()
        .put("user_id", u.toString()).put("algorithm_version", version)
        .put("daily_metrics", JSONArray().put(JSONObject().put("day", targetDay)
            .put("source_device_id", device2.toString()).put("hrv_rmssd_ms", score)))
        .put("sleep_nights", JSONArray().put(night().put("period_day", targetDay)
            .put("device_id", device2.toString())))

    private fun legacy(c: Connection, body: JSONObject = legacyPayload()): JSONObject =
        c.prepareStatement("select public.engine_ingest_scored(?, ?::jsonb)::text").use { s ->
            s.setString(1, "test-only"); s.setString(2, body.toString())
            s.executeQuery().use { r -> r.next(); JSONObject(r.getString(1)) }
        }

    private fun publish(c: Connection, item: ScoringWorkQueue.WorkItem, score: Double): Long =
        c.prepareStatement("select publish_scoring_snapshot_v2(?, ?, ?::jsonb, 1)").use { s ->
            s.setObject(1, item.leaseToken); s.setLong(2, item.inputRevision)
            s.setString(3, payload(score).toString())
            s.executeQuery().use { r -> r.next(); r.getLong(1).also { assertFalse(r.wasNull()) } }
        }

    private fun assertProjection(score: Double = 82.0) {
        assertEquals(score, scalar("select hrv_rmssd_ms from server_daily_scores where day='$day'")!!.toDouble(), 0.0)
        assertEquals(device.toString(), scalar("select source_device_id from server_daily_scores where day='$day'"))
        assertEquals("0", scalar("select count(*) from server_sleep_nights where period_day='$day'"))
        assertEquals(device.toString(), scalar("select selected_scoring_device_v2('$u','$day','$version')"))
    }

    private fun awaitLockWait(future: Future<*>) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
        while (!future.isDone && System.nanoTime() < deadline &&
            scalar("select count(*) from pg_locks where not granted") == "0") Thread.sleep(10)
        assertFalse("second publisher must wait for the first transaction", future.isDone)
        assertNotEquals("0", scalar("select count(*) from pg_locks where not granted"))
    }

    @Test fun delayedLegacyResultCannotOverwriteCorrectionOrResurrectSleep() {
        queue.dirtyWorkItem(u, device, day)
        queue.publish(queue.claim()!!, payload(40.0, JSONArray().put(night())), 1)
        queue.dirtyWorkItem(u, device, day)
        val revision = queue.publish(queue.claim()!!, payload(82.0), 1)!!
        pg.connection().use { legacy(it) }
        assertProjection()
        assertEquals(revision.toString(), scalar("select provenance->>'resultRevision' from server_daily_scores"))
        assertEquals("2", scalar("select count(*) from scoring_snapshots_v2"))
    }

    @Test fun legacyWaitsForUncommittedV2ThenCannotRestoreRemovedSleep() {
        queue.dirtyWorkItem(u, device, day)
        val item = queue.claim()!!
        val executor = Executors.newSingleThreadExecutor()
        try {
            pg.connection().use { first ->
                first.autoCommit = false
                publish(first, item, 82.0)
                val late = executor.submit { pg.connection().use { legacy(it) } }
                try { awaitLockWait(late) } finally { first.commit() }
                late.get(5, TimeUnit.SECONDS)
            }
            assertProjection()
        } finally { executor.shutdownNow() }
    }

    @Test fun v2WaitsForUncommittedLegacyThenReplacesItsCompleteProjection() {
        val executor = Executors.newSingleThreadExecutor()
        try {
            pg.connection().use { first ->
                first.autoCommit = false
                legacy(first)
                queue.dirtyWorkItem(u, device, day)
                val item = queue.claim()!!
                val newer = executor.submit<Long?> { queue.publish(item, payload(82.0), 1) }
                try { awaitLockWait(newer) } finally { first.commit() }
                assertNotNull(newer.get(5, TimeUnit.SECONDS))
            }
            assertProjection()
        } finally { executor.shutdownNow() }
    }

    @Test fun legacyOnlyKeysAndResponseShapeRemainCompatible() {
        pg.connection().use { c ->
            c.createStatement().use { it.execute("set role service_role") }
            val result = legacy(c)
            assertTrue(result.getBoolean("ok"))
            assertEquals(1, result.getInt("daily_metrics"))
            assertEquals(1, result.getInt("sleep_nights"))
        }
        assertEquals(1.0, scalar("select hrv_rmssd_ms from server_daily_scores")!!.toDouble(), 0.0)
        assertEquals("1", scalar("select count(*) from server_sleep_nights"))
    }

    @Test fun legacyCannotMutatePendingV2KeysOrCallThePrivateImplementation() {
        queue.dirtyWorkItem(u, device, day)
        val held = queue.claim()!!
        pg.connection().use { c ->
            c.createStatement().use { it.execute("set role service_role") }
            val result = legacy(c)
            assertEquals(0, result.getInt("daily_metrics"))
            assertEquals(0, result.getInt("sleep_nights"))
        }
        assertEquals("0", scalar("select count(*) from server_daily_scores"))
        assertEquals("0", scalar("select count(*) from server_sleep_nights"))
        assertEquals("f", scalar("select has_function_privilege('service_role','internal.engine_ingest_scored(text,jsonb)','EXECUTE')"))
        assertEquals("f", scalar("select has_function_privilege('authenticated','public.engine_ingest_scored(text,jsonb)','EXECUTE')"))
        assertEquals("f", scalar("select has_function_privilege('authenticated','public.reconcile_scoring_versions_v2(integer)','EXECUTE')"))
        assertTrue(queue.renew(held))
        assertNotNull(queue.publish(held, payload(), 1))
    }

    @Test fun legacyCannotMoveAV2SleepToAnUnownedDayThroughStartKeyConflict() {
        queue.dirtyWorkItem(u, device, day)
        queue.publish(queue.claim()!!, payload(82.0, JSONArray().put(night())), 1)
        pg.connection().use { legacy(it, legacyPayload(targetDay = "2026-09-16")) }
        assertEquals(day, scalar("select period_day from server_sleep_nights"))
        assertEquals(device.toString(), scalar("select device_id from server_sleep_nights"))
    }

    @Test fun registrationSeesNeitherUncommittedInputNorLegacyWorkButMaintenanceRepairsIt() {
        val next = ScoringWorkQueue(pg.db, algorithmVersion = "review-version-2")
        pg.connection().use { input ->
            input.autoCommit = false
            input.createStatement().use { it.execute("""insert into noop_hr_samples
                (user_id,device_id,source_id,ts,bpm,batch_id) values
                ('$u','$device','$u',extract(epoch from timestamptz '$day 10:00:00Z'),60,'$u')""") }
            // A second real connection registers while the first input and its V1 jobs are invisible.
            pg.connection().use { registration ->
                registration.createStatement().use { it.execute("select register_scoring_algorithm_v2('review-version-2')") }
            }
            assertEquals("0", scalar("select count(*) from scoring_work_items"))
            assertEquals("0", scalar("select count(*) from scoring_jobs_v2"))
            input.commit()
        }
        assertEquals("0", scalar("select count(*) from scoring_jobs_v2 where algorithm_version='review-version-2'"))
        repeat(4) { next.maintain(1) }
        assertEquals("3", scalar("select count(*) from scoring_jobs_v2 where algorithm_version='review-version-2'"))
        val claimedDays = mutableSetOf<String>()
        repeat(3) {
            val item = next.claim()
            assertNotNull("maintenance must recover all days without another upload", item)
            claimedDays += item!!.day
            assertNotNull(next.publish(item, payload(), 1))
        }
        assertTrue(claimedDays.contains(day))
        assertNull(next.claim())
        repeat(4) { next.maintain(1) }
        assertEquals("3", scalar("select count(*) from scoring_jobs_v2 where algorithm_version='review-version-2' and input_revision=completed_revision"))
    }

    @Test fun versionRepairIsBoundedIdempotentAndDoesNotInvalidateExistingLeases() {
        sql("select register_scoring_algorithm_v2('review-version-2')")
        repeat(4) { offset ->
            queue.dirtyWorkItem(u, device, java.time.LocalDate.parse(day).plusDays(offset.toLong()).toString())
        }
        val held = queue.claim()!!
        val next = ScoringWorkQueue(pg.db, algorithmVersion = "review-version-2")
        next.maintain(0)
        assertEquals("0", scalar("select count(*) from scoring_jobs_v2 where algorithm_version='review-version-2'"))
        next.maintain(2)
        assertEquals("2", scalar("select count(*) from scoring_jobs_v2 where algorithm_version='review-version-2'"))
        next.maintain(2)
        assertEquals("4", scalar("select count(*) from scoring_jobs_v2 where algorithm_version='review-version-2'"))
        repeat(3) { next.maintain(2) }
        assertTrue(queue.renew(held))
        assertNotNull(queue.publish(held, payload(), 1))
        assertEquals("4", scalar("select count(*) from scoring_jobs_v2 where algorithm_version='$version' and input_revision=1"))
    }

    @Test fun concurrentVersionRepairIsIdempotentAndDisabledVersionsStayUnscheduled() {
        sql("select register_scoring_algorithm_v2('review-version-2')")
        sql("select register_scoring_algorithm_v2('review-disabled')")
        sql("update scoring_algorithms_v2 set enabled=false where algorithm_version='review-disabled'")
        queue.dirtyWorkItem(u, device, day)
        val executor = Executors.newSingleThreadExecutor()
        try {
            pg.connection().use { first ->
                first.autoCommit = false
                first.createStatement().use { it.execute("select reconcile_scoring_versions_v2(2)") }
                val second = executor.submit<String?> { scalar("select reconcile_scoring_versions_v2(2)") }
                try { awaitLockWait(second) } finally { first.commit() }
                assertEquals("0", second.get(5, TimeUnit.SECONDS))
            }
        } finally { executor.shutdownNow() }
        assertEquals("1", scalar("select count(*) from scoring_jobs_v2 where algorithm_version='review-version-2' and input_revision=1"))
        assertEquals("0", scalar("select count(*) from scoring_jobs_v2 where algorithm_version='review-disabled'"))
    }

    private fun insertRr(ts: Long, channel: Int?, rr: Int = 800, ord: Int = 0) {
        sql("""insert into noop_rr_intervals(user_id,device_id,source_id,ts,"rrMs",seq,ord,"srcChannel","tsSuspect",batch_id)
            values('$u','$device','$u',$ts,$rr,0,$ord,${channel ?: "null"},0,'$u')""")
    }

    private fun historicalInput() = SignalSampleReader(pg.db).loadDay(u, day, device)!!
    private fun beats() = historicalInput().rr.map { listOf(it.ts, it.rrMs.toLong(), it.ord?.toLong(), it.srcChannel?.toLong()) }
    private fun inputRevision() = scalar("select input_revision from scoring_jobs_v2 where day='$day' and algorithm_version='$version'")
    private fun coverage() = EngineIngestWriter.buildSnapshot(DayScorer().score(historicalInput(), version))
        .getJSONObject("coverage").getInt("rrIntervals")

    @Test fun futureModernRrInsertionAndDeletionDoNotChangeHistoricalInputsOrCoverage() {
        sql("update devices set device_family=null where id='$device'")
        val ts = Instant.parse("${day}T04:00:00Z").epochSecond
        insertRr(ts, null, 800, 0); insertRr(ts, null, 820, 1)
        val before = beats()
        assertEquals(2, before.size)
        assertEquals(2, coverage())
        // Publish the actual reader/scorer/writer coverage, then keep that settled revision unchanged.
        repeat(3) {
            val item = queue.claim()!!
            val inputs = SignalSampleReader(pg.db).loadDay(u, item.day, device)!!
            assertNotNull(EngineIngestWriter(queue).write(item, DayScorer().score(inputs, version), 1))
        }
        val revision = inputRevision()
        val snapshot = scalar("select payload::text from scoring_snapshots_v2 where day='$day'")
        val future = ts + 10 * 86400
        insertRr(future, 5)
        assertEquals(before, beats()); assertEquals(2, coverage()); assertEquals(revision, inputRevision())
        assertEquals(snapshot, scalar("select payload::text from scoring_snapshots_v2 where day='$day'"))
        sql("delete from noop_rr_intervals where ts=$future")
        assertEquals(before, beats()); assertEquals(2, coverage()); assertEquals(revision, inputRevision())
        assertEquals(snapshot, scalar("select payload::text from scoring_snapshots_v2 where day='$day'"))
    }

    @Test fun windowLocalModernEvidenceChangesExactBeatsCoverageAndInputRevisionBothWays() {
        sql("update devices set device_family=null where id='$device'")
        val ts = Instant.parse("${day}T04:00:00Z").epochSecond
        insertRr(ts, null, 800, 0); insertRr(ts, null, 820, 1)
        val legacy = beats()
        val before = inputRevision()!!.toLong()
        insertRr(ts + 1, 5, 900, 2)
        assertEquals(listOf(listOf(ts + 1, 900L, 2L, 5L)), beats())
        assertEquals(1, coverage()); assertEquals(before + 1, inputRevision()!!.toLong())
        sql("delete from noop_rr_intervals where \"srcChannel\"=5")
        assertEquals(legacy, beats())
        assertEquals(2, coverage()); assertEquals(before + 2, inputRevision()!!.toLong())
    }

    @Test fun upgradeSchedulesUnknownFamilyHistoryEvenAfterLastEvidenceWasDeleted() {
        sql("update devices set device_family=null where id='$device'")
        queue.dirtyWorkItem(u, device, day)
        queue.publish(queue.claim()!!, payload(), 1)
        val future = Instant.parse("${day}T04:00:00Z").epochSecond + 10 * 86400
        insertRr(future, 5)
        sql("delete from noop_rr_intervals where ts=$future")
        val snapshot = scalar("select payload::text from scoring_snapshots_v2 where day='$day'")
        pg.connection().use { c ->
            c.autoCommit = false
            try {
                c.createStatement().use { s ->
                    // Restore only the pre-review function layout inside this rollback-only fixture.
                    // All v2 data and public queue/result functions are the actual installed W3 schema.
                    s.execute("drop function public.engine_ingest_scored(text,jsonb)")
                    s.execute("alter function internal.engine_ingest_scored(text,jsonb) set schema public")
                    s.execute("drop function public.reconcile_scoring_versions_v2(integer)")
                    s.execute(Files.readString(pg.root.resolve(
                        "supabase/migrations/20260918030000_production_scoring_review_repairs.sql")))
                    s.executeQuery("""select count(*) from scoring_invalidations_v2
                        where user_id='$u' and device_id='$device' and '$day'::date between next_day and through_day
                        and reason='rr_window_inference_repair'""").use { r ->
                        r.next(); assertEquals(1, r.getInt(1))
                    }
                    s.executeQuery("select payload::text from scoring_snapshots_v2 where day='$day'").use { r ->
                        r.next(); assertEquals(snapshot, r.getString(1))
                    }
                }
            } finally { c.rollback() }
        }
    }
}
