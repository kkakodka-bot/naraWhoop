package com.frwhoop.scoring

import com.frwhoop.scoring.db.PostgresClient
import com.frwhoop.scoring.db.ScoringWorkQueue
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import java.sql.Connection
import java.sql.SQLException
import java.time.LocalDate
import java.time.ZoneOffset
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Real transaction tests; no string inspection is accepted as evidence for dependency fencing. */
class PhysiologyDependencyIntegrationTest {
    private lateinit var db: PostgresClient
    private lateinit var queue: ScoringWorkQueue
    private val user=UUID.randomUUID()
    private val device=UUID.randomUUID()
    private val sourceDay=LocalDate.of(2026,7,1)
    private val windowStart=sourceDay.atTime(12,0).toEpochSecond(ZoneOffset.UTC)

    @Before fun setup() {
        val url=System.getenv("PHYSIOLOGY_TEST_DATABASE_URL")
        assumeTrue("Run scripts/test-physiology-queue.sh",url!=null)
        require(url!!.contains("@127.0.0.1:") && url.endsWith("/physiology_queue_test"))
        db=PostgresClient(url); queue=ScoringWorkQueue(db)
        sql("insert into auth.users values('$user')")
        sql("insert into profiles(id,timezone) values('$user','UTC')")
        sql("insert into devices(id,user_id) values('$device','$user')")
    }
    @After fun close() { if(::db.isInitialized) db.close() }

    @Test fun rawCorrectionCoversEachPriorNightWindowsHistoryButNotDay30() {
        val source=claim(sourceDay); publish(payload(source,windowStart)); assertTrue(queue.markDone(source,1))
        val targets=listOf(1L,7L,28L,29L,30L).associateWith { offset ->
            claim(sourceDay.plusDays(offset)).also { publish(payload(it)); assertTrue(queue.markDone(it,1)) }
        }
        // The projection insert and downstream revision advance commit atomically.
        val batch=UUID.randomUUID(); val producer=UUID.randomUUID()
        db.withConnection { c ->
            c.autoCommit=false
            c.createStatement().use { it.execute("insert into noop_hr_samples(user_id,device_id,source_id,ts,bpm,batch_id) "+
                "values('$user','$device','$producer',$windowStart,60,'$batch')") }
            assertEquals(targets.getValue(28).inputRevision,revision(sourceDay.plusDays(28)))
            c.commit()
        }
        for(offset in listOf(1L,7L,28L,29L)) assertTrue(revision(sourceDay.plusDays(offset))>targets.getValue(offset).inputRevision)
        assertEquals(targets.getValue(30).inputRevision,revision(sourceDay.plusDays(30)))
        assertEquals(0,available(sourceDay))
        val restored=claim(sourceDay,false)
        val before=revision(sourceDay.plusDays(28))
        publish(payload(restored,windowStart))
        assertTrue(revision(sourceDay.plusDays(28))>before)
        assertEquals(1,available(sourceDay))
    }

    @Test fun laterDayCanFinishWhileEarlierFailsAndIsRepairedOnArrival() {
        val early=claim(sourceDay)
        assertTrue(queue.markFailed(early,"controlled missing artifact failure"))
        val later=claim(sourceDay.plusDays(10))
        publish(payload(later)); assertTrue(queue.markDone(later,1))
        assertEquals(later.inputRevision,revision(sourceDay.plusDays(10)))
        val retry=claim(sourceDay,false)
        publish(payload(retry,windowStart))
        assertEquals(later.inputRevision+1,revision(sourceDay.plusDays(10)))
        assertNotNull(claim(sourceDay.plusDays(10),false))
    }

    @Test fun earlierArrivalRevokesAnAlreadyRunningLaterLease() {
        val early=claim(sourceDay)
        val later=claim(sourceDay.plusDays(8))
        publish(payload(early,windowStart))
        assertFalse(queue.markDone(later,1))
        assertFalse(queue.renew(later))
        expectStale { publish(payload(later)) }
        assertEquals(0,number("select count(*) from server_physiology_results where user_id='$user' and period_day='${later.day}'").toInt())
    }

    @Test fun identicalMeasurementRestorationStillRepairsAnAbsentHistoryRun() {
        val first=claim(sourceDay); publish(payload(first,windowStart)); assertTrue(queue.markDone(first,1))
        val laterDay=sourceDay.plusDays(20)
        val oldLater=claim(laterDay); publish(payload(oldLater)); assertTrue(queue.markDone(oldLater,1))
        val next=claim(sourceDay)
        assertEquals(0,available(sourceDay))
        val withoutHistory=claim(laterDay,false)
        publish(payload(withoutHistory)); assertTrue(queue.markDone(withoutHistory,1))
        publish(payload(next,windowStart))
        assertTrue(revision(laterDay)>withoutHistory.inputRevision)
        assertEquals(1,available(sourceDay))
    }

    @Test fun derivedOnlyRefreshKeepsHistoryAvailableAndDoesNotCascade() {
        val first=claim(sourceDay); publish(payload(first,windowStart)); assertTrue(queue.markDone(first,1))
        val later=claim(sourceDay.plusDays(20)); publish(payload(later)); assertTrue(queue.markDone(later,1))
        val directRevision=number("select measurement_revision from physiology_work_items where user_id='$user' and day='$sourceDay'")
        sql("select scoring_enqueue_dependency('$user','$device','$sourceDay')")
        assertEquals(1,available(sourceDay))
        val baselineOnly=claim(sourceDay,false)
        val nextPayload=payload(baselineOnly,windowStart)
        nextPayload.getJSONArray("measurements").getJSONObject(0).put("baseline",JSONObject().put("robust_z",9.0))
        nextPayload.put("computed_at","2026-08-02T03:04:05Z")
        publish(nextPayload)
        assertEquals(later.inputRevision,revision(sourceDay.plusDays(20)))
        assertEquals(directRevision,number("select measurement_revision from physiology_work_items where user_id='$user' and day='$sourceDay'"))
        assertEquals(1,available(sourceDay))
    }

    @Test fun eligibilityLossAndScalarChangesInvalidateButArrayOrderDoesNot() {
        val first=claim(sourceDay)
        val two=payload(first,windowStart).apply { getJSONArray("measurements").put(measurement(first,windowStart+300)) }
        publish(two); assertTrue(queue.markDone(first,1))
        val later=claim(sourceDay.plusDays(7)); publish(payload(later)); assertTrue(queue.markDone(later,1))
        sql("select scoring_enqueue_dependency('$user','$device','$sourceDay')")
        val reordered=claim(sourceDay,false)
        val same=payload(reordered,windowStart+300).apply { getJSONArray("measurements").put(measurement(reordered,windowStart)) }
        publish(same); assertTrue(queue.markDone(reordered,1))
        assertEquals(later.inputRevision,revision(sourceDay.plusDays(7)))
        sql("select scoring_enqueue_dependency('$user','$device','$sourceDay')")
        val changed=claim(sourceDay,false)
        val invalid=payload(changed,windowStart).apply {
            getJSONArray("measurements").getJSONObject(0).put("baseline_eligible",false)
        }
        publish(invalid)
        assertEquals(later.inputRevision+1,revision(sourceDay.plusDays(7)))
    }

    @Test fun dependenciesStayWithinOwnerDeviceAndDoNotCreateOrRunFutureJobs() {
        val otherDevice=UUID.randomUUID()
        sql("insert into devices(id,user_id) values('$otherDevice','$user')")
        queue.dirtyWorkItem(user,otherDevice,sourceDay.plusDays(7).toString())
        val otherUser=UUID.randomUUID(); val otherUsersDevice=UUID.randomUUID()
        sql("insert into auth.users values('$otherUser')")
        sql("insert into profiles(id,timezone) values('$otherUser','UTC')")
        sql("insert into devices(id,user_id) values('$otherUsersDevice','$otherUser')")
        queue.dirtyWorkItem(otherUser,otherUsersDevice,sourceDay.plusDays(7).toString())
        publish(payload(claim(sourceDay),windowStart))
        assertEquals(1,number("select input_revision from physiology_work_items where user_id='$user' and device_id='$otherDevice'").toInt())
        assertEquals(1,number("select input_revision from physiology_work_items where user_id='$otherUser'").toInt())
        assertEquals(1,number("select count(*) from physiology_work_items where user_id='$user' and device_id='$device'").toInt())
        val today=db.withConnection { c -> c.createStatement().use { s -> s.executeQuery("select (clock_timestamp() at time zone 'UTC')::date").use { r -> r.next(); LocalDate.parse(r.getString(1)) } } }
        val yesterday=today.minusDays(1)
        val future=claim(today.plusDays(1))
        publish(payload(claim(yesterday),yesterday.atTime(12,0).toEpochSecond(ZoneOffset.UTC)))
        assertEquals(future.inputRevision,revision(today.plusDays(1)))
    }

    @Test fun publicationArrivalAfterLaterCommitStillInvalidatesThatCommit() {
        val early=claim(sourceDay); val later=claim(sourceDay.plusDays(7))
        val started=CountDownLatch(1); val pool=Executors.newSingleThreadExecutor()
        try {
            db.withConnection { c ->
                c.autoCommit=false
                publish(payload(later),c) // holds the later queue-row fence until commit
                val arrival=pool.submit {
                    started.countDown(); publish(payload(early,windowStart))
                }
                assertTrue(started.await(5,TimeUnit.SECONDS))
                assertFalse(arrival.isDone)
                c.commit()
                arrival.get(10,TimeUnit.SECONDS)
            }
            assertTrue(revision(sourceDay.plusDays(7))>later.inputRevision)
            assertFalse(queue.markDone(later,1))
        } finally { pool.shutdownNow() }
    }

    @Test fun historyDependencyIncludesEachPriorNightWindowsDstBound() {
        val spring=LocalDate.of(2026,3,8)
        sql("update scoring_timezone_history set timezone_id='America/Los_Angeles' where user_id='$user'")
        sql("select scoring_enqueue_day('$user','$device','$spring','America/Los_Angeles',0)")
        sql("select scoring_enqueue_day('$user','$device','2026-03-09','America/Los_Angeles',0)")
        val beforeSpringMidnight=java.time.Instant.parse("2026-02-07T07:30:00Z").epochSecond
        val measurements=JSONArray().put(JSONObject().put("start",beforeSpringMidnight).put("end",beforeSpringMidnight+300))
        db.withConnection { c -> c.prepareStatement("select scoring_dirty_hrv_dependents('$user','$device','2026-02-08',?::jsonb)").use {
            it.setString(1,measurements.toString()); it.execute()
        } }
        // Mar 8 owns prior-night context from Mar 7 08Z, whose oldest history is Feb 7 08Z.
        assertEquals(1,revision(spring).toInt())
        assertEquals(1,revision(spring.plusDays(1)).toInt())
        val oldestPriorNight=java.time.Instant.parse("2026-02-07T08:00:00Z").epochSecond
        sql("select scoring_dirty_hrv_dependents('$user','$device','2026-02-07',"+
            "'[{\"start\":$oldestPriorNight,\"end\":${oldestPriorNight+300}}]'::jsonb)")
        assertEquals(2,revision(spring).toInt())
        assertEquals(1,revision(spring.plusDays(1)).toInt())
    }

    @Test fun readerRetainsTheOldestPriorNightHistoryBandWithoutIncludingEarlierWindows() {
        fun fullWindow(start:Long,item:ScoringWorkQueue.WorkItem):JSONObject {
            val observations=(0 until 300).map { i -> com.noop.analytics.PhysiologyQuality.IntervalObservation(
                "old-$start-$i",user.toString(),device.toString(),source="synthetic_history",
                eventTime=start+i+0.5,originalRRMs=1000.0,startBeatId="b$i",endBeatId="b${i+1}",continuityGroup="history-$start",
                verifiedSpan=com.noop.analytics.PhysiologyQuality.Span(start+i.toDouble(),start+i+1.0),
                timestampPrecisionSeconds=0.001,clockVersion="fixture-clock") }
            val measured=com.noop.analytics.HrvWindow.measure(start.toInt(),observations,
                listOf(com.noop.analytics.PhysiologyQuality.ContextEpoch(start.toDouble(),start+300.0,"sleep",true)),
                inputRevision=item.inputRevision.toString())
            assertTrue(measured.measurementValid);assertTrue(measured.baselineEligible)
            return com.frwhoop.scoring.scoring.HrvPayloadCodec.encode(measured,user.toString(),device.toString())
        }
        val included=claim(sourceDay)
        publish(payload(included).put("measurements",JSONArray().put(fullWindow(windowStart,included))))
        assertTrue(queue.markDone(included,1))
        val excluded=claim(sourceDay.minusDays(1))
        val earlier=sourceDay.atStartOfDay().toEpochSecond(ZoneOffset.UTC)-300
        publish(payload(excluded).put("measurements",JSONArray().put(fullWindow(earlier,excluded))))
        assertTrue(queue.markDone(excluded,1))
        val target=sourceDay.plusDays(29)
        val input=com.frwhoop.scoring.db.SignalSampleReader(db).loadDay(user,target.toString(),device)!!
        assertTrue(windowStart<input.dayLo-28*86400L)
        assertEquals(listOf(windowStart.toInt()),input.hrvHistory.map { it.start })
    }

    @Test fun newCalendarCreationAndPublicationCannotMissEachOthersUncommittedRows() {
        val early=claim(sourceDay)
        val pool=Executors.newSingleThreadExecutor()
        val laterDay=sourceDay.plusDays(7)
        try {
            // Publication wins the mutex: a new day cannot commit and read history until it commits.
            db.withConnection { c ->
                c.autoCommit=false; publish(payload(early,windowStart),c)
                val app="dependency-create-$user"
                val creation=pool.submit { db.withConnection { other ->
                    other.createStatement().use { s ->
                        s.execute("set application_name='$app'")
                        s.execute("select scoring_enqueue_day('$user','$device','$laterDay','UTC',0)")
                    }
                } }
                awaitAdvisoryWait(app)
                assertEquals(0,number("select count(*) from physiology_work_items where user_id='$user' and day='$laterDay'").toInt())
                c.commit(); creation.get(10,TimeUnit.SECONDS)
            }
            assertEquals(1,available(sourceDay))
            assertEquals(1,revision(laterDay).toInt())
            assertTrue(queue.markDone(early,1))
            val next=claim(sourceDay)
            val anotherDay=sourceDay.plusDays(8)
            // Creation wins: the publication waits, then sees and invalidates that now-committed day.
            db.withConnection { c ->
                c.autoCommit=false
                c.createStatement().use { it.execute("select scoring_enqueue_day('$user','$device','$anotherDay','UTC',0)") }
                val app="dependency-publish-$user"
                val publication=pool.submit { db.withConnection { other ->
                    other.createStatement().use { it.execute("set application_name='$app'") }
                    publish(payload(next,windowStart),other)
                } }
                awaitAdvisoryWait(app)
                c.commit(); publication.get(10,TimeUnit.SECONDS)
            }
            assertEquals(2,revision(anotherDay).toInt())
        } finally { pool.shutdownNow() }
    }

    private fun awaitAdvisoryWait(application: String) {
        repeat(200) {
            if(number("select count(*) from pg_stat_activity where application_name='$application' and wait_event='advisory'")>0) return
            Thread.sleep(10)
        }
        fail("expected real PostgreSQL advisory-lock wait for $application")
    }

    private fun claim(day: LocalDate,dirty: Boolean=true): ScoringWorkQueue.WorkItem {
        if(dirty) queue.dirtyWorkItem(user,device,day.toString())
        sql("update physiology_work_items set next_attempt_at=clock_timestamp() where user_id='$user' and device_id='$device' and day='$day'")
        return queue.claimOne(user,device,day.toString())!!
    }
    private fun measurement(item: ScoringWorkQueue.WorkItem,start: Long)=JSONObject()
        .put("feature","hrv").put("measurement_schema_version",1).put("window_id","window-$start")
        .put("user_id",user.toString()).put("device_id",device.toString())
        .put("input_revision",item.inputRevision.toString()).put("algorithm_version","hrv-window-v2")
        .put("quality_version","original-beat-continuity-v2").put("start",start).put("end",start+300)
        .put("measurement_valid",true).put("baseline_eligible",true).put("context","sleep")
        .put("observed_rmssd_ms",42.0).put("baseline",JSONObject().put("robust_z",0.1))
    private fun payload(item: ScoringWorkQueue.WorkItem,start: Long?=null)=JSONObject()
        .put("schema_version",2).put("user_id",user.toString()).put("device_id",device.toString())
        .put("day",item.day).put("algorithm_version","frwhoop-physiology-2")
        .put("input_revision",item.inputRevision).put("lease_token",item.leaseToken.toString())
        .put("run_id",item.runId.toString()).put("computed_at","2026-09-18T00:00:00Z")
        .put("publication_status","provisional")
        .put("daily",JSONObject().put("day",item.day).put("source_device_id",device.toString()))
        .put("nights",JSONArray()).put("measurements",JSONArray().apply { if(start!=null) put(measurement(item,start)) })
    private fun publish(payload: JSONObject,connection: Connection?=null) {
        if(connection==null) db.withConnection { publish(payload,it) }
        else connection.prepareStatement("select engine_publish_physiology('test',?::jsonb)").use { p ->
            p.setString(1,payload.toString()); p.execute()
        }
    }
    private fun available(day: LocalDate)=number("select count(distinct r.period_day) from server_physiology_results r join physiology_work_items q "+
        "on q.user_id=r.user_id and q.device_id=r.device_id and q.day=r.period_day "+
        "where r.user_id='$user' and r.device_id='$device' and r.period_day='$day' and r.measurement_revision=q.measurement_revision").toInt()
    private fun revision(day: LocalDate)=number("select input_revision from physiology_work_items where user_id='$user' and device_id='$device' and day='$day'")
    private fun sql(query: String) { db.withConnection { c -> c.createStatement().use { it.execute(query) } } }
    private fun number(query: String)=db.withConnection { c -> c.createStatement().use { s -> s.executeQuery(query).use { r -> r.next(); r.getLong(1) } } }
    private fun expectStale(operation: () -> Unit) {
        try { operation(); fail("expected SQLSTATE 40001") } catch(error: SQLException) { assertEquals("40001",error.sqlState) }
    }
}
