package com.frwhoop.scoring

import com.frwhoop.scoring.db.*
import com.frwhoop.scoring.scoring.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDate
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class HistoricalQueueIntegrationTest : PgIntegrationBase() {
    private val version="frwhoop-server-2-history"
    private val historical get()=ScoringWorkQueue(pg.db,version)
    private fun bundle(item:ScoringWorkQueue.WorkItem): ServerScoreBundle {
        val input=SignalSampleReader(pg.db).loadHistoricalDay(item.userId,item.day,item.deviceId)!!
        return DayScorer().score(input,version,HistoricalStateMachine.prepare(input,HistoryCheckpointReader(pg.db).load(item)))
    }
    private fun publish(item:ScoringWorkQueue.WorkItem)=EngineIngestWriter(historical).write(item,bundle(item),1)
    private fun start(vararg dates:String) {
        historical.maintain(1000)
        dates.forEach { historical.dirtyWorkItem(u,device,it) }
        historical.maintain(1000)
    }

    @Test fun claimsAndPublishesMoreThanOneHundredDaysInOrderThenReplaysEntireSuffix() {
        val dates=(0 until 131).map { LocalDate.parse("2026-01-01").plusDays(it.toLong()).toString() }
        start(*dates.reversed().toTypedArray())
        var predecessor:Long?=null
        for(date in dates) {
            val item=historical.claim()!!
            assertEquals(date,item.day); assertEquals(predecessor,item.predecessorRevision)
            assertNull("later day must not run while predecessor is leased",historical.claim())
            predecessor=publish(item); assertNotNull(predecessor)
        }
        assertNull(historical.claim())
        assertEquals("131",scalar("select count(*) from scoring_history_checkpoints_v3"))
        historical.dirtyWorkItem(u,device,dates[1]); historical.maintain(1000)
        for(date in dates.drop(1)) {
            val item=historical.claim()!!; assertEquals(date,item.day); assertNotNull(publish(item))
        }
        assertNull(historical.claim())
        assertEquals("261",scalar("select count(*) from scoring_history_checkpoints_v3"))
        assertEquals("0",scalar("select count(*) from scoring_jobs_v2 where algorithm_version='$version' and completed_revision<>input_revision"))
    }

    @Test fun pastCorrectionFromSecondConnectionFencesAlreadyClaimedLaterDayBeforeExpansion() {
        start(day,"2026-09-16")
        assertNotNull(publish(historical.claim()!!))
        val later=historical.claim()!!; val stale=bundle(later)
        pg.connection().use { c -> c.createStatement().use { it.execute("select enqueue_scoring_v2('$u','$device','$day','$version','past_correction')") } }
        assertNull(EngineIngestWriter(historical).write(later,stale,1))
        assertEquals("1",scalar("select count(*) from scoring_history_checkpoints_v3"))
        assertTrue(historical.markFailed(later,"superseded"))
        historical.maintain(1000)
        assertEquals(day,historical.claim()!!.day)
    }

    @Test fun profileRevisionMismatchAndPredecessorMismatchPublishNothing() {
        start(day)
        val item=historical.claim()!!; val b=bundle(item); val commit=b.historyCommit!!
        assertNull(historical.publishHistory(item,EngineIngestWriter.buildSnapshot(b),commit.state,99,0,1))
        assertNull(historical.publishHistory(item.copy(predecessorRevision=99),EngineIngestWriter.buildSnapshot(b),commit.state,0,0,1))
        assertEquals("0",scalar("select count(*) from scoring_snapshots_v2"))
        assertNotNull(EngineIngestWriter(historical).write(item,b,1))
        val payload=JSONObject(scalar("select payload::text from scoring_snapshots_v2")!!)
        assertEquals(item.historyGeneration,payload.getJSONObject("dependency").getLong("generation"))
        assertTrue(payload.getJSONObject("coverage").getBoolean("historicalStateAvailable"))
    }

    @Test fun checkpointInsertFailureRollsBackResultLegacyArchiveAndSettlement() {
        start(day)
        val item=historical.claim()!!
        sql("""create function reject_history_fixture() returns trigger language plpgsql as
            'begin raise exception ''checkpoint_fixture_reject''; end';
            create trigger reject_history_fixture before insert on scoring_history_checkpoints_v3 for each row execute function reject_history_fixture();""")
        try {
            assertThrows(java.sql.SQLException::class.java) { publish(item) }
            assertEquals("0",scalar("select count(*) from scoring_snapshots_v2"))
            assertEquals("0",scalar("select count(*) from scoring_archive_jobs_v2"))
            assertEquals("0",scalar("select completed_revision from scoring_jobs_v2 where algorithm_version='$version'"))
        } finally { sql("drop trigger reject_history_fixture on scoring_history_checkpoints_v3; drop function reject_history_fixture()") }
        assertNotNull(publish(item))
    }

    @Test fun twoConnectionsCannotSkipLeasedOrLockedPredecessorAndLegacyClaimCannotSteal() {
        start(day,"2026-09-16")
        val executor=Executors.newSingleThreadExecutor()
        try {
            pg.connection().use { c ->
                c.autoCommit=false
                c.createStatement().use { it.executeQuery("select * from claim_scoring_history_v3('$version',300)").use { r -> assertTrue(r.next()); assertEquals(day,r.getString("day")) } }
                assertNull(executor.submit<ScoringWorkQueue.WorkItem?> { historical.claim() }.get(5,TimeUnit.SECONDS))
                assertNull(ScoringWorkQueue(pg.db,version,historyMode=false).claim())
                c.commit()
            }
        } finally { executor.shutdownNow() }
    }

    @Test fun historyReaderNeverBorrowsMutableProfileWithoutEligibleJournal() {
        sql("update profiles set reported_age_years=85,timezone='Pacific/Auckland' where id='$u'")
        val input=SignalSampleReader(pg.db).loadHistoricalDay(u,day,device)!!
        assertEquals(30.0,input.profile.age,0.0); assertEquals("UTC",input.timezone)
    }

    @Test fun rawCorrectionUsesConservativeHistoricalWindowNotMutableCurrentTimezone() {
        // Current UTC+14 maps the correction to Sep 16; the historical UTC-12 day is Sep 15.
        sql("update profiles set timezone='Pacific/Kiritimati' where id='$u'")
        start(day,"2026-09-16")
        assertNotNull(publish(historical.claim()!!))
        val later=historical.claim()!!; val stale=bundle(later)
        val ts=java.time.Instant.parse("2026-09-15T12:30:00Z").epochSecond
        pg.connection().use { c -> c.createStatement().use { it.execute("""
            insert into noop_hr_samples(user_id,device_id,source_id,ts,bpm,batch_id)
            values('$u','$device',gen_random_uuid(),$ts,65,gen_random_uuid())
        """.trimIndent()) } }
        assertNull(EngineIngestWriter(historical).write(later,stale,1))
        assertEquals("2026-09-14",scalar("select dirty_from from scoring_history_heads_v3 where user_id='$u' and device_id='$device' and algorithm_version='$version'"))
        assertEquals("1",scalar("select count(*) from scoring_history_checkpoints_v3"))
    }
}
