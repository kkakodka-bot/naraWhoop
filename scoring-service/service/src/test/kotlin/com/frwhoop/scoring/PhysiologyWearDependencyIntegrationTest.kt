package com.frwhoop.scoring

import com.frwhoop.scoring.db.PostgresClient
import com.frwhoop.scoring.db.ScoringWorkQueue
import com.frwhoop.scoring.db.SignalSampleReader
import com.noop.analytics.AnalyticsEngine
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import java.time.Instant
import java.util.UUID

/** Real transaction tests for persistent OFF/ON state outside the two-date raw lookback. */
class PhysiologyWearDependencyIntegrationTest {
    private lateinit var db:PostgresClient
    private lateinit var queue:ScoringWorkQueue
    private val user=UUID.randomUUID();private val device=UUID.randomUUID()
    private val off=Instant.parse("2026-09-14T23:00:00Z").epochSecond
    @Before fun setup() {
        val url=System.getenv("PHYSIOLOGY_TEST_DATABASE_URL")
        assumeTrue("Run disposable PostgreSQL harness",url!=null)
        require(url!!.contains("@127.0.0.1:") && url.endsWith("/physiology_queue_test"))
        db=PostgresClient(url);queue=ScoringWorkQueue(db)
        sql("insert into auth.users values('$user')")
        sql("insert into profiles(id,timezone) values('$user','UTC')")
        sql("insert into devices(id,user_id) values('$device','$user')")
    }
    @After fun close() { if(::db.isInitialized) db.close() }
    @Test fun readerCarriesPrecedingOffAndClosedOnIntoCurrentContext() {
        event(off,"WRIST_OFF(10)")
        val reader=SignalSampleReader(db)
        val input=reader.loadDay(user,"2026-09-17",device)!!
        assertEquals(off,input.events.single().ts)
        assertEquals(listOf(off to input.nightHi+1),AnalyticsEngine.offWristIntervals(input.events,input.nightHi+1))
        event(off+3600,"WRIST_ON(11)")
        val worn=reader.loadDay(user,"2026-09-17",device)!!
        assertTrue(worn.events.single().kind.startsWith("WRIST_ON"))
        assertTrue(AnalyticsEngine.offWristIntervals(worn.events,worn.nightHi+1).isEmpty())
    }
    @Test fun delayedOffInsertAndDeleteDirtyExistingDistantDaysTransactionallyButReplayDoesNot() {
        queue.dirtyWorkItem(user,device,"2026-09-17")
        val before=revision("2026-09-17")
        db.withConnection { c ->
            c.autoCommit=false
            c.createStatement().use { it.execute(eventSql(off,"WRIST_OFF(10)")) }
            assertEquals(before,revision("2026-09-17"))
            c.commit()
        }
        assertTrue(revision("2026-09-17")>before)
        val changed=revision("2026-09-17")
        sql("update noop_events set ingested_at=clock_timestamp(),batch_id='${UUID.randomUUID()}' where user_id='$user'")
        assertEquals(changed,revision("2026-09-17"))
        sql("delete from noop_events where user_id='$user'")
        assertTrue(revision("2026-09-17")>changed)
    }
    @Test fun nextTransitionEndsInfluenceAndConflictingSameSecondStateRemainsOff() {
        event(off+3600,"WRIST_ON(11)")
        queue.dirtyWorkItem(user,device,"2026-09-17")
        val before=revision("2026-09-17")
        event(off,"WRIST_OFF(10)")
        assertEquals(before,revision("2026-09-17"))
        event(off+3600,"WRIST_OFF(10)")
        val input=SignalSampleReader(db).loadDay(user,"2026-09-17",device)!!
        assertTrue(AnalyticsEngine.offWristIntervals(input.events,input.nightHi+1).isNotEmpty())
    }
    private fun event(ts:Long,kind:String)=sql(eventSql(ts,kind))
    private fun eventSql(ts:Long,kind:String)="insert into noop_events(user_id,device_id,source_id,ts,kind,\"payloadJSON\",batch_id) "+
        "values('$user','$device','${UUID.randomUUID()}',$ts,'$kind','{}','${UUID.randomUUID()}')"
    private fun sql(query:String)=db.withConnection { c -> c.createStatement().use { it.execute(query) };Unit }
    private fun revision(day:String)=db.withConnection { c -> c.createStatement().use { s ->
        s.executeQuery("select input_revision from physiology_work_items where user_id='$user' and device_id='$device' and day='$day'")
            .use { it.next();it.getLong(1) }
    } }
}
