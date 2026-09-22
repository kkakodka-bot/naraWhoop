package com.frwhoop.scoring

import com.frwhoop.scoring.db.PostgresClient
import com.frwhoop.scoring.db.ScoringWorkQueue
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import java.sql.Connection
import java.sql.SQLException
import java.time.Instant
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Invoked against a freshly initialized local cluster by scripts/test-physiology-queue.sh. */
class ScoringWorkQueueIntegrationTest {
    private lateinit var db: PostgresClient
    private lateinit var queue: ScoringWorkQueue
    private val user = UUID.randomUUID()
    private val device = UUID.randomUUID()
    private val source = UUID.randomUUID()
    private val batch = UUID.randomUUID()
    private val day = "2026-09-17"
    private val ts = Instant.parse("2026-09-17T23:55:00Z").epochSecond

    @Before fun setup() {
        val url = System.getenv("PHYSIOLOGY_TEST_DATABASE_URL")
        assumeTrue("Run scripts/test-physiology-queue.sh for real PostgreSQL tests", url != null)
        require(url!!.contains("@127.0.0.1:") && url.endsWith("/physiology_queue_test"))
        db = PostgresClient(url)
        resetFleetTestState(db)
        queue = ScoringWorkQueue(db)
        sql("insert into auth.users values ('$user')")
        sql("insert into profiles(id,timezone) values ('$user','UTC')")
        sql("insert into devices(id,user_id) values ('$device','$user')")
    }

    @After fun close() { if (::db.isInitialized) db.close() }

    @Test fun migrationResetsLegacySuccessAttemptsAndCatchesExistingAuxiliarySignals() {
        val legacy="00000000-0000-0000-0000-000000000001"
        assertEquals(1L,scalar("select count(*) from physiology_work_items where user_id='$legacy' and day='2026-09-01' " +
            "and attempts=0 and consecutive_failures=0 and done_at is null and claimed_at is null and timezone_id='America/Los_Angeles'"))
        assertEquals(2L,scalar("select count(*) from physiology_work_items where user_id='$legacy' and day in ('2026-09-03','2026-09-04')"))
    }

    @Test fun moreThan350SuccessfulRevisionsRemainRunnable() {
        repeat(351) { index ->
            assertEquals(index + 1L, queue.dirtyWorkItem(user, device, day))
            val work = claim()
            fence(work)
            assertTrue(queue.markDone(work, 1))
            assertEquals(0L, scalar("select consecutive_failures from physiology_work_items where user_id='$user'"))
        }
        assertNull(queue.claimOne(user, device, day))
    }

    @Test fun candidateSelectionSkipsOnlyTheLeasedDeviceAndRecoversAfterExpiry() {
        val otherDevice=UUID.randomUUID()
        sql("insert into devices(id,user_id) values('$otherDevice','$user')")
        queue.dirtyWorkItem(user,device,day)
        queue.dirtyWorkItem(user,device,"2026-09-18")
        queue.dirtyWorkItem(user,otherDevice,day)
        assertNotNull(queue.claimOne(user,device,day))
        assertEquals(otherDevice,queue.peekOne(userId=user)?.deviceId)
        assertNull(queue.peekOne(userId=user,excludedDevices=setOf(ScoringWorkQueue.DeviceKey(user,otherDevice))))
        sql("update physiology_work_items set lease_expires_at=clock_timestamp()-interval '1 second' where user_id='$user' and device_id='$device'")
        sql("update scoring_fleet_reservations set expires_at=clock_timestamp()-interval '1 second' where user_id='$user' and device_id='$device'")
        assertNotNull(queue.peekOne(userId=user,deviceId=device,day=day))
    }

    @Test fun candidateCursorKeepsMicrosecondTimestampsAndAllIdentityTieBreakers() {
        val otherDevice=UUID.randomUUID()
        sql("insert into devices(id,user_id) values('$otherDevice','$user')")
        for(strap in listOf(device,otherDevice)) for(date in listOf(day,"2026-09-18")) {
            queue.dirtyWorkItem(user,strap,date)
        }
        sql("update physiology_work_items set next_attempt_at='2000-01-01T10:20:30.123456+05:30',dirty_at='2000-01-01T10:20:30.654321-07:00' where user_id='$user'")
        val candidates=mutableListOf<ScoringWorkQueue.Candidate>()
        var cursor:ScoringWorkQueue.Cursor?=null
        repeat(4) {
            val candidate=queue.peekOne(userId=user,after=cursor)!!
            assertEquals(Instant.parse("2000-01-01T04:50:30.123456Z"),candidate.cursor!!.nextAttemptAt)
            assertEquals(Instant.parse("2000-01-01T17:20:30.654321Z"),candidate.cursor.dirtyAt)
            candidates.add(candidate);cursor=candidate.cursor
        }
        assertEquals(4,candidates.map { it.deviceId to it.day }.toSet().size)
        assertNull(queue.peekOne(userId=user,after=cursor))
        assertEquals(candidates.first(),queue.peekOne(userId=user))
    }

    @Test fun failureBudgetBelongsToRevisionAndWaitingDoesNotConsumeIt() {
        queue.dirtyWorkItem(user, device, day)
        repeat(8) { count ->
            assertTrue(queue.markFailed(claim(), "controlled failure"))
            assertEquals(count+1L, scalar("select consecutive_failures from physiology_work_items where user_id='$user'"))
            makeDue()
        }
        assertNull(queue.claimOne(user, device, day))
        queue.dirtyWorkItem(user, device, day)
        val waiting = claim()
        assertTrue(queue.markWaiting(waiting, "interval acquisition pending"))
        assertEquals(0L, scalar("select consecutive_failures from physiology_work_items where user_id='$user'"))
        assertNull(queue.claimOne(user, device, day))
        makeDue()
        assertTrue(queue.markDone(claim(), 1))
    }

    @Test fun newInputAndExpiredLeaseFenceEveryOldMutation() {
        queue.dirtyWorkItem(user, device, day)
        val obsolete = claim()
        queue.dirtyWorkItem(user, device, day)
        assertNull("superseded computation still consumes its slot until settled",queue.claimOne(user,device,day))
        assertFalse(queue.markDone(obsolete,1))
        val current = claim()
        assertFalse(queue.renew(obsolete))
        assertFalse(queue.markDone(obsolete, 1))
        assertFalse(queue.markFailed(obsolete, "old error"))
        assertFalse(queue.markWaiting(obsolete, "old waiting"))
        expectStale { fence(obsolete) }
        assertTrue(queue.renew(current))
        sql("update physiology_work_items set lease_expires_at=clock_timestamp()-interval '1 second' where user_id='$user'")
        sql("update scoring_fleet_reservations set expires_at=clock_timestamp()-interval '1 second' where user_id='$user'")
        assertFalse(queue.renew(current))
        expectStale { fence(current) }
        val successor = claim()
        assertNotEquals(current.leaseToken, successor.leaseToken)
        assertNotEquals(current.runId, successor.runId)
        assertFalse(queue.markDone(current, 1))
        fence(successor)
        assertTrue(queue.markDone(successor, 1))
    }

    @Test fun pendingArrivalsKeepEarliestDueWithoutAllowingAnOldRevisionToPublish() {
        fun enqueue(delay: Int) = sql("select physiology_enqueue_day('$user','$device','$day','UTC',$delay)")
        fun due() = scalar("select floor(extract(epoch from next_attempt_at)*1000000)::bigint " +
            "from physiology_work_items where user_id='$user' and day='$day'")
        enqueue(120)
        val firstDue = due()
        enqueue(600)
        assertEquals(firstDue,due())
        assertEquals(2L,revision(day))

        // An earlier new deadline can make pending work runnable immediately.
        enqueue(0)
        assertTrue(due()<firstDue)
        val obsolete = queue.claimOne(user,device,day)!!
        assertEquals(3L,obsolete.inputRevision)
        enqueue(600)
        assertEquals(4L,revision(day))
        expectStale { fence(obsolete) }
        assertFalse(queue.markDone(obsolete,1))

        // A new arrival must not push an already-due pending job back into the future.
        makeDue()
        val alreadyDue = due()
        enqueue(600)
        assertEquals(alreadyDue,due())
        val current = queue.claimOne(user,device,day)!!
        assertEquals(5L,current.inputRevision)
        assertFalse(queue.markDone(obsolete,1))
        assertTrue(queue.renew(current))
    }

    @Test fun twoWorkersCannotClaimSameLiveRevision() {
        queue.dirtyWorkItem(user, device, day)
        val start = CountDownLatch(1)
        val pool = Executors.newFixedThreadPool(2)
        try {
            val tasks = (1..2).map { pool.submit<ScoringWorkQueue.WorkItem?> {
                start.await(); queue.claimOne(user,device,day)
            } }
            start.countDown()
            val claimed = tasks.map { it.get(10,TimeUnit.SECONDS) }
            assertEquals(1,claimed.count { it != null })
        } finally { pool.shutdownNow() }
    }

    @Test fun durableArrivalAndCorrectionCommitWithRevisionAndInvalidateFollowingDay() {
        db.withConnection { conn ->
            conn.autoCommit=false
            conn.createStatement().use { it.execute(hrInsert()) }
            assertEquals(0L, scalar("select count(*) from physiology_work_items where user_id='$user'"))
            conn.commit()
        }
        assertEquals(2L, scalar("select count(*) from physiology_work_items where user_id='$user'"))
        assertEquals(1L, revision(day))
        assertEquals(1L, revision("2026-09-18"))
        sql("update noop_hr_samples set ingested_at=clock_timestamp(),batch_id='${UUID.randomUUID()}' where user_id='$user'")
        assertEquals(1L, revision(day))
        sql("update noop_hr_samples set bpm=61 where user_id='$user'")
        assertEquals(2L, revision(day))
        sql("delete from noop_hr_samples where user_id='$user'")
        assertEquals(3L, revision(day))
        assertEquals(3L, revision("2026-09-18"))
    }

    @Test fun bulkArrivalCoalescesAndTransactionRollbackCannotDirty() {
        sql("insert into noop_hr_samples(user_id,device_id,source_id,ts,bpm,batch_id) " +
            "select '$user','$device','$source',$ts+n,60,'$batch' from generate_series(0,99) n")
        assertEquals(1L,revision(day))
        db.withConnection { conn ->
            conn.autoCommit=false
            conn.createStatement().use { it.execute("update noop_hr_samples set bpm=75 where user_id='$user'") }
            conn.rollback()
        }
        assertEquals(1L,revision(day))
    }

    @Test fun unrepresentableSensorClockIsPreservedWithoutBlockingDurableIngest() {
        sql("insert into noop_rr_intervals(user_id,device_id,source_id,ts,\"rrMs\",seq,\"tsSuspect\",batch_id) " +
            "values('$user','$device','$source',9223372036854775807,1000,1,1,'$batch')")
        assertEquals(1L,scalar("select count(*) from noop_rr_intervals where user_id='$user'"))
        assertEquals(0L,scalar("select count(*) from physiology_work_items where user_id='$user'"))
    }

    @Test fun deviceFamilyCorrectionInvalidatesButLastSeenDoesNot() {
        queue.dirtyWorkItem(user,device,day)
        sql("update devices set last_seen_at=clock_timestamp() where id='$device'")
        assertEquals(1L,revision(day))
        sql("update devices set device_family='whoop4' where id='$device'")
        assertEquals(2L,revision(day))
    }

    @Test fun allAuxiliarySignalsAndManualChangesDirtyWithoutHrArrival() {
        val inserts = listOf(
            "insert into noop_rr_intervals(user_id,device_id,source_id,ts,\"rrMs\",seq,batch_id) values('$user','$device','$source',$ts,1000,1,'$batch')",
            "insert into noop_resp_samples(user_id,device_id,source_id,ts,raw,batch_id) values('$user','$device','$source',$ts,10,'$batch')",
            "insert into noop_gravity_samples(user_id,device_id,source_id,ts,x,y,z,batch_id) values('$user','$device','$source',$ts,0,0,1,'$batch')",
            "insert into noop_events(user_id,device_id,source_id,ts,kind,\"payloadJSON\",batch_id) values('$user','$device','$source',$ts,'off_wrist','{}','$batch')",
            "insert into noop_sleep_state_samples(user_id,device_id,source_id,ts,state,batch_id) values('$user','$device','$source',$ts,2,'$batch')",
            "insert into noop_step_samples(user_id,device_id,source_id,ts,counter,batch_id) values('$user','$device','$source',$ts,120,'$batch')",
            "insert into noop_event_labels(user_id,device_id,label,start_ts,source,confidence) values('$user','$device','quiet_awake',$ts,'patient','confirmed')",
            "insert into sessions(user_id,device_id,start_at,end_at,user_modified) values('$user','$device',to_timestamp($ts),to_timestamp($ts+120),true)",
            "insert into sleep_details(session_id,user_id,user_start_at) select id,user_id,to_timestamp($ts+10) from sessions where user_id='$user'",
        )
        inserts.forEachIndexed { index, statement ->
            sql(statement)
            assertEquals("Missing input invalidation for $statement",index+1L,revision(day))
        }
        sql("delete from sessions where user_id='$user'")
        assertTrue(revision(day)>inserts.size)
    }

    @Test fun timezoneChangeDoesNotMoveLateHistoricalRecordsAndDstUsesCalendarDays() {
        sql("update profiles set timezone='America/Los_Angeles' where id='$user'")
        // Before the prospective profile edit the historical timezone remains UTC.
        sql(hrInsert())
        assertEquals(1L,revision(day))
        assertEquals(0L,scalar("select count(*) from physiology_work_items where user_id='$user' and day='2026-09-17' and timezone_id<>'UTC'"))
        sql("insert into scoring_timezone_history values('$user','2026-01-01','America/Los_Angeles','explicit_history')")
        val dst = Instant.parse("2026-03-08T08:30:00Z").epochSecond
        assertEquals(2L,scalar("select count(*) from scoring_affected_days('$user',$dst,${dst+3600})"))
        assertEquals(1L,scalar("select count(*) from scoring_affected_days('$user',$dst,${dst+3600}) where day='2026-03-09'"))
    }

    @Test fun movedManualDetailBoundsInvalidateOldAndNewPeriods() {
        val id=UUID.randomUUID()
        sql("insert into sessions(id,user_id,device_id,start_at,end_at,user_modified) " +
            "values('$id','$user','$device','2026-09-17T01:00Z','2026-09-17T02:00Z',true)")
        sql("insert into sleep_details(session_id,user_id,user_start_at,user_end_at) " +
            "values('$id','$user','2026-09-17T01:00Z','2026-09-17T02:00Z')")
        sql("update sleep_details set user_start_at='2026-09-19T01:00Z',user_end_at='2026-09-19T02:00Z' where session_id='$id'")
        assertEquals(3L,revision(day))
        assertEquals(1L,revision("2026-09-19"))
        assertEquals(1L,revision("2026-09-20"))
    }

    @Test fun fractionalTimezoneMidnightIncludesLastPointOfBulkStatement() {
        sql("update scoring_timezone_history set timezone_id='Asia/Kolkata' where user_id='$user'")
        val midnight=Instant.parse("2026-09-17T18:30:00Z").epochSecond
        sql("insert into noop_hr_samples(user_id,device_id,source_id,ts,bpm,batch_id) " +
            "select '$user','$device','$source',$midnight+n,60,'$batch' from generate_series(-1,0) n")
        assertEquals(3L,scalar("select count(*) from physiology_work_items where user_id='$user'"))
        assertEquals(1L,revision("2026-09-19"))
    }

    @Test fun rawRequiresDigestAndDecoderVerificationAndBeforeTriggerDoesNotCancelDml() {
        val objectId = UUID.randomUUID()
        sql("insert into object_manifests(id,user_id,device_id,object_key,status,sha256_source,sha256) " +
            "values('$objectId','$user','$device','test/$objectId','ready','client_claimed',repeat('a',64))")
        sql("insert into noop_signal_windows(user_id,device_id,stream,hour_start,object_id,object_key,start_ts,end_ts) " +
            "values('$user','$device','ppg',$ts,'$objectId','test/$objectId',$ts,${ts+30})")
        assertEquals(0L,scalar("select count(*) from physiology_work_items where user_id='$user'"))
        sql("update object_manifests set sha256_source='server_verified',sha256=repeat('a',64) where id='$objectId'")
        assertEquals(0L,scalar("select count(*) from physiology_work_items where user_id='$user'"))
        assertEquals(1L,scalar("select count(*) from object_manifests where id='$objectId' and sha256_source='server_verified'"))
        sql("update object_manifests set decode_verified_at=clock_timestamp(),decoder_version='fixture-1' where id='$objectId'")
        assertEquals(1L,revision(day))
        sql("update object_manifests set updated_at=clock_timestamp() where id='$objectId'")
        assertEquals(1L,revision(day))
        sql("delete from object_manifests where id='$objectId'")
        assertEquals(0L,scalar("select count(*) from object_manifests where id='$objectId'"))
        assertEquals(2L,revision(day))
    }

    @Test fun deletingUnverifiedRawObjectDoesNotCreatePhysiologyWork() {
        val objectId=UUID.randomUUID()
        sql("insert into object_manifests(id,user_id,device_id,object_key,status,sha256_source) " +
            "values('$objectId','$user','$device','test/$objectId','ready','client_claimed')")
        sql("insert into noop_signal_windows(user_id,device_id,stream,hour_start,object_id,object_key,start_ts,end_ts) " +
            "values('$user','$device','ppg',$ts,'$objectId','test/$objectId',$ts,${ts+30})")
        sql("delete from object_manifests where id='$objectId'")
        assertEquals(0L,scalar("select count(*) from object_manifests where id='$objectId'"))
        assertEquals(0L,scalar("select count(*) from physiology_work_items where user_id='$user'"))
    }

    @Test fun publicationRowLockSerializesConcurrentNewInputUntilCommit() {
        queue.dirtyWorkItem(user,device,day)
        val item=claim()
        val started=CountDownLatch(1)
        val pool=Executors.newSingleThreadExecutor()
        try {
            db.withConnection { conn ->
                conn.autoCommit=false
                fence(item,conn)
                conn.createStatement().use { it.execute("insert into queue_test_publications values('$user','$device','$day',${item.inputRevision})") }
                val dirty = pool.submit<Long> { started.countDown(); queue.dirtyWorkItem(user,device,day) }
                assertTrue(started.await(5,TimeUnit.SECONDS))
                // PostgreSQL wait evidence, rather than elapsed time, proves the transaction waits on the fence.
                val deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(5)
                var waiting=false
                while(!waiting && System.nanoTime()<deadline) {
                    waiting=scalar("select count(*) from pg_stat_activity where wait_event_type='Lock' and query like 'select public.physiology_enqueue_day%' ")>0
                    Thread.yield()
                }
                assertTrue("arrival must wait for publication lock",waiting)
                assertFalse(dirty.isDone)
                conn.commit()
                assertEquals(2L,dirty.get(5,TimeUnit.SECONDS))
            }
            expectStale { fence(item) }
            assertFalse(queue.markDone(item,1))
            assertEquals(1L,scalar("select revision from queue_test_publications where user_id='$user'"))
            assertEquals(2L,revision(day))
        } finally { pool.shutdownNow() }
    }

    @Test fun leaseThatExpiresWhileWaitingForLockCannotPublishOrRenew() {
        val pool=Executors.newSingleThreadExecutor()
        try {
            for (renew in listOf(false,true)) {
                queue.dirtyWorkItem(user,device,day)
                val item=claim()
                sql("update physiology_work_items set lease_expires_at=clock_timestamp()+interval '700 milliseconds' where user_id='$user'")
                db.withConnection { conn ->
                    conn.autoCommit=false
                    conn.createStatement().use { it.execute("select 1 from physiology_work_items where user_id='$user' for update") }
                    val waiting=pool.submit<Boolean> {
                        if (renew) queue.renew(item) else {
                            try { fence(item); true } catch(e: SQLException) { assertEquals("40001",e.sqlState); false }
                        }
                    }
                    conn.createStatement().use { it.execute("select pg_sleep(0.9)") }
                    assertFalse(waiting.isDone)
                    conn.commit()
                    assertFalse("expired waiter gained authority",waiting.get(5,TimeUnit.SECONDS))
                }
                assertFalse(queue.markDone(item,1))
            }
        } finally { pool.shutdownNow() }
    }

    @Test fun nullLeaseArgumentsCannotBypassFence() {
        queue.dirtyWorkItem(user,device,day)
        val work=claim()
        expectStale { sql("select scoring_begin_publication('$user','$device','$day',null,'${work.leaseToken}','${work.runId}')") }
        expectStale { sql("select scoring_begin_publication('$user','$device','$day',${work.inputRevision},null,'${work.runId}')") }
        expectStale { sql("select scoring_begin_publication('$user','$device','$day',${work.inputRevision},'${work.leaseToken}',null)") }
    }

    @Test fun tenantAndDeviceOwnershipCannotBeForgedAndAuthenticatedCannotOperateQueue() {
        val otherUser=UUID.randomUUID()
        val secondDevice=UUID.randomUUID()
        sql("insert into auth.users values('$otherUser')")
        sql("insert into profiles(id,timezone) values('$otherUser','UTC')")
        sql("insert into devices(id,user_id) values('$secondDevice','$user')")
        queue.dirtyWorkItem(user,device,day)
        queue.dirtyWorkItem(user,secondDevice,day)
        assertEquals(2L,scalar("select count(*) from physiology_work_items where user_id='$user'"))
        try { queue.dirtyWorkItem(otherUser,device,day); fail("cross-user device accepted") }
        catch (expected: SQLException) { assertEquals("23503",expected.sqlState) }
        val item=claim()
        expectStale { fence(item.copy(deviceId=secondDevice)) }
        db.withConnection { conn ->
            conn.createStatement().use { s ->
                s.execute("set role authenticated")
                try { s.execute("select * from scoring_claim_one()"); fail("authenticated claimed queue") }
                catch(expected: SQLException) { assertEquals("42501",expected.sqlState) }
                finally { s.execute("reset role") }
            }
        }
    }

    private fun claim() = queue.claimOne(user,device,day) ?: error("No runnable item for $user/$day")
    private fun makeDue() = sql("update physiology_work_items set next_attempt_at=clock_timestamp()-interval '1 second' where user_id='$user'")
    private fun revision(date: String)=scalar("select input_revision from physiology_work_items where user_id='$user' and device_id='$device' and day='$date'")
    private fun hrInsert()="insert into noop_hr_samples(user_id,device_id,source_id,ts,bpm,batch_id) values('$user','$device','$source',$ts,60,'$batch')"
    private fun sql(statement: String)=db.withConnection { conn -> conn.createStatement().use { it.execute(statement) }; Unit }
    private fun scalar(statement: String): Long=db.withConnection { conn -> conn.createStatement().use { s ->
        s.executeQuery(statement).use { rs -> assertTrue("No row for $statement",rs.next()); rs.getLong(1) }
    } }
    private fun fence(item: ScoringWorkQueue.WorkItem) = db.withConnection { fence(item,it) }
    private fun fence(item: ScoringWorkQueue.WorkItem,conn: Connection) {
        conn.prepareStatement("select scoring_begin_publication(?,?,?::date,?,?,?)").use { ps ->
            ps.setObject(1,item.userId); ps.setObject(2,item.deviceId); ps.setString(3,item.day)
            ps.setLong(4,item.inputRevision); ps.setObject(5,item.leaseToken); ps.setObject(6,item.runId)
            ps.execute()
        }
    }
    private fun expectStale(block: () -> Unit) {
        try { block(); fail("stale publication accepted") }
        catch (expected: SQLException) { assertEquals("40001",expected.sqlState) }
    }
}
