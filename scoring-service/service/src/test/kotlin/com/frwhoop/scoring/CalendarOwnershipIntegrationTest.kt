package com.frwhoop.scoring

import com.frwhoop.scoring.db.CalendarOwnershipReader
import com.frwhoop.scoring.db.PostgresClient
import com.frwhoop.scoring.db.ScoringWorkQueue
import com.frwhoop.scoring.db.SignalSampleReader
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class CalendarOwnershipIntegrationTest {
    private lateinit var db: PostgresClient
    private lateinit var queue: ScoringWorkQueue
    private val user = UUID.randomUUID()
    private val device = UUID.randomUUID()

    @Before fun setup() {
        val url = System.getenv("PHYSIOLOGY_TEST_DATABASE_URL")
        assumeTrue("Run scripts/test-physiology-queue.sh", url != null)
        require(url!!.contains("@127.0.0.1:") && url.endsWith("/physiology_queue_test"))
        db = PostgresClient(url); queue = ScoringWorkQueue(db)
        sql("insert into auth.users values('$user')")
        sql("insert into profiles(id,timezone) values('$user','UTC')")
        sql("insert into devices(id,user_id) values('$device','$user')")
    }
    @After fun close() { if (::db.isInitialized) db.close() }

    @Test fun precreatedUtcQueueIncludesTheNewZonesLateEvening() {
        hr("2026-09-17T10:00:00Z")
        history("2026-09-17T12:00:00Z", "America/Los_Angeles")
        hr("2026-09-18T05:00:00Z")
        val input = SignalSampleReader(db).loadDay(user, "2026-09-17", device, "UTC")!!
        val own = input.calendarOwnership!!
        assertEquals(listOf("UTC", "America/Los_Angeles"), own.timezoneIds)
        assertEquals(listOf(epoch("2026-09-17T00:00:00Z") to epoch("2026-09-18T07:00:00Z")), own.dayIntervals)
        assertEquals(2, input.hr.size)
        assertTrue(own.dayIntervals.any { epoch("2026-09-18T05:00:00Z") in it.first until it.second })
        assertEquals(epoch("2026-09-18T07:00:00Z") - 1, input.dayHi)
        assertEquals("UTC", string("select timezone_id from physiology_work_items where user_id='$user' and day='2026-09-17'"))
    }

    @Test fun disjointOwnershipExcludesSamplesInAnInterveningDifferentDate() {
        history("2026-09-17T06:00:00Z", "Pacific/Kiritimati")
        history("2026-09-17T12:00:00Z", "UTC")
        hr("2026-09-17T09:00:00Z"); hr("2026-09-17T11:00:00Z"); hr("2026-09-17T13:00:00Z")
        val input = SignalSampleReader(db).loadDay(user, "2026-09-17", device, "UTC")!!
        assertEquals(listOf(
            epoch("2026-09-17T00:00:00Z") to epoch("2026-09-17T10:00:00Z"),
            epoch("2026-09-17T12:00:00Z") to epoch("2026-09-18T00:00:00Z")), input.calendarOwnership!!.dayIntervals)
        assertEquals(listOf(epoch("2026-09-17T09:00:00Z"), epoch("2026-09-17T13:00:00Z")), input.hr.map { it.ts })
    }

    @Test fun historicEndpointZonesSurviveLaterProfileChangesAndTravelBoundaries() {
        history("2026-08-17T12:00:00Z", "America/Los_Angeles")
        val before=ownership("2026-08-17")
        val transition=epoch("2026-08-17T12:00:00Z")
        assertEquals("UTC",before.timezoneAt(transition,closingBound=true))
        assertEquals("America/Los_Angeles",before.timezoneAt(transition))
        assertEquals("America/Los_Angeles",before.timezoneAt(epoch("2026-08-18T07:00:00Z"),closingBound=true))
        sql("update profiles set timezone='Asia/Tokyo' where id='$user'")
        assertEquals(before,ownership("2026-08-17"))
    }

    @Test fun hrvDependenciesUseOwnedMidnightInsteadOfThePrecreatedQueueZone() {
        // Historical fixtures avoid any dependency enqueue guard against future days.
        queue.dirtyWorkItem(user, device, "2026-08-18")
        history("2026-08-17T12:00:00Z", "America/Los_Angeles")
        val before = revision("2026-08-18")
        val measurement = JSONObject().put("start", epoch("2026-08-18T03:55:00Z"))
            .put("end", epoch("2026-08-18T04:00:00Z"))
        sql("select scoring_dirty_hrv_dependents('$user','$device','2026-08-17','[$measurement]'::jsonb)")
        assertEquals(before + 1, revision("2026-08-18"))
        assertEquals("UTC", string("select timezone_id from physiology_work_items where user_id='$user' and day='2026-08-18'"))
        assertEquals(epoch("2026-08-18T07:00:00Z"), ownership("2026-08-18").dayLo)
    }

    @Test fun dstUsesActualTwentyThreeAndTwentyFiveHourDays() {
        sql("update scoring_timezone_history set timezone_id='America/Los_Angeles' where user_id='$user'")
        for ((day, hours) in listOf("2026-03-08" to 23, "2026-11-01" to 25)) {
            val value = ownership(day)
            assertEquals(hours * 3600L, value.dayIntervals.sumOf { it.second - it.first })
            assertNull(value.unavailableReason)
        }
    }

    @Test fun skippedDateAbstainsAndRepeatedDateRetainsSeventyFourHourContext() {
        sql("update scoring_timezone_history set timezone_id='Pacific/Pago_Pago' where user_id='$user'")
        history("2011-12-30T10:00:00Z", "Pacific/Apia")
        assertEquals("calendar_date_has_no_owned_time", ownership("2011-12-30").unavailableReason)
        sql("delete from scoring_timezone_history where user_id='$user' and effective_at<>'-infinity'")
        sql("update scoring_timezone_history set timezone_id='Pacific/Kiritimati' where user_id='$user'")
        history("2026-09-17T10:00:00Z", "Etc/GMT+12")
        val repeated = ownership("2026-09-17")
        assertEquals(2, repeated.dayIntervals.size)
        assertEquals(74 * 3600L, repeated.contextHiInclusive!! + 1 - repeated.contextLo!!)
        assertNull(repeated.unavailableReason)
    }

    @Test fun timezoneChangeCommitsWithAffectedRevisionsAndDoesNotRewriteOldDates() {
        val today = LocalDate.now(ZoneOffset.UTC)
        val historic = today.minusDays(14).toString()
        queue.dirtyWorkItem(user, device, historic)
        queue.dirtyWorkItem(user, device, today.toString())
        val before = revision(today.toString())
        db.withConnection { connection ->
            connection.autoCommit = false
            connection.createStatement().use { it.execute("update profiles set timezone='America/Los_Angeles' where id='$user'") }
            assertEquals(before, revision(today.toString()))
            assertEquals(1L, number("select count(*) from scoring_timezone_history where user_id='$user'"))
            connection.commit()
        }
        assertTrue(revision(today.toString()) > before)
        assertEquals(1L, revision(historic))
        assertEquals(listOf("UTC"), ownership(historic).timezoneIds)
    }

    @Test fun projectionWaitingForCalendarMutexReadsHistoryAfterTheChangeCommits() {
        val pool = Executors.newSingleThreadExecutor()
        try {
            db.withConnection { connection ->
                connection.autoCommit = false
                connection.createStatement().use { statement ->
                    statement.execute("select scoring_lock_device('$user','$device')")
                    statement.execute("insert into scoring_timezone_history values('$user','2026-09-17T12:00Z','America/Los_Angeles','test_history')")
                }
                val insert = pool.submit { hr("2026-09-18T05:00:00Z") }
                val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
                var waiting = false
                while (!waiting && System.nanoTime() < deadline) {
                    waiting = number("select count(*) from pg_stat_activity where wait_event_type='Lock' " +
                        "and query like 'insert into noop_hr_samples%' and query like '%$user%'") > 0
                    Thread.yield()
                }
                assertTrue("projection must wait before reading calendar history", waiting)
                connection.commit(); insert.get(5, TimeUnit.SECONDS)
            }
            assertEquals(1L, revision("2026-09-17"))
            assertEquals(0L, number("select count(*) from physiology_work_items where user_id='$user' and day='2026-09-19'"))
        } finally { pool.shutdownNow() }
    }

    @Test fun travelMetadataAndMovedOverrideUseTheFullOwnedCalendar() {
        hr("2026-09-17T10:00:00Z")
        history("2026-09-17T12:00:00Z", "America/Los_Angeles")
        val edit = UUID.randomUUID()
        sql("insert into physiology_sleep_overrides(id,user_id,device_id,original_start_at,original_end_at,start_at,end_at) " +
            "values('$edit','$user','$device','2026-09-18T04:00Z','2026-09-18T05:00Z','2026-09-18T04:00Z','2026-09-18T05:00Z')")
        db.withConnection { connection ->
            connection.createStatement().use { statement ->
                statement.execute("set role authenticated")
                statement.execute("set request.jwt.claim.sub='$user'")
                statement.execute("set request.jwt.claim.role='authenticated'")
                try {
                    statement.executeQuery("select physiology_processing_metadata('$user','$device','2026-09-17','frwhoop-physiology-2',null)").use { rows ->
                        assertTrue(rows.next())
                        val value = JSONObject(rows.getString(1))
                        assertEquals(2, value.getJSONArray("timezone_ids").length())
                        assertEquals(epoch("2026-09-18T07:00:00Z"), value.getJSONArray("day_intervals").getJSONArray(1).getLong(1))
                    }
                    statement.executeQuery("select physiology_owned_sleep_overrides('$user','$device','2026-09-17')").use { rows ->
                        assertTrue(rows.next()); assertTrue(rows.getString(1).contains(edit.toString()))
                    }
                } finally {
                    statement.execute("reset role"); statement.execute("reset request.jwt.claim.sub"); statement.execute("reset request.jwt.claim.role")
                }
            }
        }
    }

    private fun ownership(day: String) = db.withConnection { CalendarOwnershipReader.load(it, user, day) }
    private fun history(at: String, zone: String) = sql("insert into scoring_timezone_history values('$user','$at','$zone','test_history')")
    private fun hr(at: String) = sql("insert into noop_hr_samples(user_id,device_id,source_id,ts,bpm,batch_id) " +
        "values('$user','$device','${UUID.randomUUID()}',${epoch(at)},60,'${UUID.randomUUID()}')")
    private fun epoch(value: String) = Instant.parse(value).epochSecond
    private fun revision(day: String) = number("select input_revision from physiology_work_items where user_id='$user' and day='$day'")
    private fun sql(value: String) = db.withConnection { connection -> connection.createStatement().use { it.execute(value) }; Unit }
    private fun string(value: String) = db.withConnection { connection -> connection.createStatement().use { statement ->
        statement.executeQuery(value).use { rows -> check(rows.next()); rows.getString(1) }
    } }
    private fun number(value: String) = string(value).toLong()
}
