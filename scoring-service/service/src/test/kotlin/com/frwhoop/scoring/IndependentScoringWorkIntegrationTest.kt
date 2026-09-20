package com.frwhoop.scoring

import com.frwhoop.scoring.db.PostgresClient
import com.frwhoop.scoring.db.ScoringWorkQueue
import com.frwhoop.scoring.derived.DerivedArchiveOutbox
import com.frwhoop.scoring.derived.DerivedArtifactWriter
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import java.sql.SQLException
import java.time.Instant
import java.util.UUID

/** Frozen v1 math with fenced transport and v2 shadow RPCs own independent work. */
class IndependentScoringWorkIntegrationTest {
    private lateinit var db: PostgresClient
    private lateinit var shadow: ScoringWorkQueue
    private val user=UUID.randomUUID()
    private val device=UUID.randomUUID()
    private val day="2026-09-17"

    @Before fun setup() {
        val url=System.getenv("PHYSIOLOGY_TEST_DATABASE_URL")
        assumeTrue("Run scripts/test-physiology-queue.sh",url!=null)
        require(url!!.contains("@127.0.0.1:") && url.endsWith("/physiology_queue_test"))
        db=PostgresClient(url);shadow=ScoringWorkQueue(db)
        sql("insert into auth.users values('$user')")
        sql("insert into profiles(id,timezone) values('$user','UTC')")
        sql("insert into devices(id,user_id) values('$device','$user')")
        // These cases deliberately verify the retained baseline transport. Fleet defaults may
        // select another version, so pin the version this test's assertions actually concern.
        sql("insert into physiology_source_selection(user_id,feature,device_id,algorithm_version) " +
            "select '$user',feature,'$device','frwhoop-server-1' from physiology_feature_defaults")
    }
    @After fun close() { if(::db.isInitialized) db.close() }

    @Test fun bothWorkersCompleteEitherOrderWithoutConsumingOtherVersion() {
        for(baselineFirst in listOf(false,true)) {
            dirtyBoth()
            val original=legacyClaim()
            val candidate=shadow.claimOne(user,device,day)!!
            assertNull(shadow.claimOne(user,device,day))
            assertEquals(0,legacyRunnable())
            if(baselineFirst) {
                legacyPublish();assertTrue(legacyDone(original))
                assertTrue(shadow.renew(candidate))
                assertEquals("available",readFeature().getString("status"))
                publish(candidate);assertTrue(shadow.markDone(candidate,1))
            } else {
                publish(candidate);assertTrue(shadow.markDone(candidate,1))
                assertEquals(1L,number("select count(*) from scoring_work_items where user_id='$user' and claimed_at is not null and done_at is null"))
                assertEquals("unavailable",readFeature().getString("status"))
                legacyPublish();assertTrue(legacyDone(original))
            }
            val feature=readFeature()
            assertEquals("frwhoop-server-1",feature.getString("algorithm_version"))
            assertEquals("available",feature.getString("status"))
            assertEquals("fenced_v1",feature.getString("revision_protocol"))
            assertTrue(feature.getLong("input_revision")>0)
            assertEquals(feature.getLong("input_revision"),feature.getLong("required_revision"))
            assertEquals(0,legacyRunnable())
            assertNull(shadow.claimOne(user,device,day))
        }
    }

    @Test fun shadowFinishesBeforeBaselineClaimsAndReplayLeavesBaselineCurrent() {
        dirtyBoth()
        val candidate=shadow.claimOne(user,device,day)!!
        publish(candidate);assertTrue(shadow.markDone(candidate,1))
        assertEquals(1,legacyRunnable())
        val original=legacyClaim();legacyPublish();assertTrue(legacyDone(original))
        assertEquals("available",readFeature().getString("status"))
        val baselineRevision=number("select input_revision from scoring_work_items where user_id='$user'")
        shadow.dirtyWorkItem(user,device,day)
        assertEquals(baselineRevision,number("select input_revision from scoring_work_items where user_id='$user'"))
        assertEquals("available",readFeature().getString("status"))
        assertEquals(0,legacyRunnable())
    }

    @Test fun moreThan350CompletedBaselineAndShadowRevisionsRemainRunnable() {
        repeat(351) {
            dirtyBoth()
            val original=legacyClaim();val candidate=shadow.claimOne(user,device,day)!!
            legacyPublish();assertTrue(legacyDone(original));assertTrue(shadow.markDone(candidate,1))
            assertEquals(0L,number("select attempts from scoring_work_items where user_id='$user'"))
            assertEquals(0L,number("select consecutive_failures from physiology_work_items where user_id='$user'"))
        }
        assertEquals(351L,number("select input_revision from scoring_work_items where user_id='$user'"))
        assertEquals(351L,number("select input_revision from physiology_work_items where user_id='$user'"))
    }

    @Test fun directLateInputInvalidatesBothButStaleLegacyCompletionCannotTouchShadowLease() {
        dirtyBoth();val original=legacyClaim();val staleShadow=shadow.claimOne(user,device,day)!!
        legacyPublish();assertTrue(legacyDone(original));publish(staleShadow);assertTrue(shadow.markDone(staleShadow,1))
        sql("insert into noop_hr_samples(user_id,device_id,source_id,ts,bpm,batch_id) values("+
            "'$user','$device','${UUID.randomUUID()}',${Instant.parse("2026-09-17T23:59:00Z").epochSecond},60,'${UUID.randomUUID()}')")
        makeDue()
        assertEquals("stale",readFeature().getString("status"))
        val current=shadow.claimOne(user,device,day)!!
        assertFalse(legacyDone(original))
        assertTrue(shadow.renew(current))
        assertFalse(shadow.markDone(staleShadow,1))
        val pending=legacyClaim();legacyPublish();assertTrue(legacyDone(pending))
        assertEquals("available",readFeature().getString("status"))
    }

    @Test fun legacyTableMutationCannotRewriteImmutablePublishedResult() {
        dirtyBoth();val original=legacyClaim();legacyPublish();assertTrue(legacyDone(original))
        assertEquals("available",readFeature().getString("status"))
        sql("update server_daily_scores set hrv_rmssd_ms=99 where user_id='$user'")
        assertEquals("available",readFeature().getString("status"))
        assertEquals(42L,number("select (payload#>>'{daily,hrv_rmssd_ms}')::bigint from server_physiology_results where user_id='$user' and algorithm_version='frwhoop-server-1'"))
    }

    @Test fun historicalDependencyUsesOwnedCurrentDateAfterDatelineTravel() {
        sql("update scoring_timezone_history set timezone_id='Pacific/Honolulu' where user_id='$user'")
        sql("update profiles set timezone='Pacific/Honolulu' where id='$user'")
        val target=db.withConnection { c -> c.createStatement().use { s ->
            s.executeQuery("select (clock_timestamp() at time zone 'Pacific/Kiritimati')::date::text").use { r -> r.next();r.getString(1) }
        } }
        sql("select scoring_enqueue_day('$user','$device','$target','Pacific/Honolulu',0)")
        sql("select scoring_enqueue_day('$user','$device','$target'::date+1,'Pacific/Honolulu',0)")
        sql("update profiles set timezone='Pacific/Kiritimati' where id='$user'")
        val before=number("select input_revision from physiology_work_items where user_id='$user' and day='$target'")
        val future=number("select input_revision from physiology_work_items where user_id='$user' and day='$target'::date+1")
        sql("select scoring_dirty_hrv_dependents('$user','$device','$target'::date-4,"+
            "jsonb_build_array(jsonb_build_object('start',extract(epoch from clock_timestamp()-interval '3 days'),"+
            "'end',extract(epoch from clock_timestamp()-interval '3 days')+300)))")
        assertEquals(before+1,number("select input_revision from physiology_work_items where user_id='$user' and day='$target'"))
        assertEquals(future,number("select input_revision from physiology_work_items where user_id='$user' and day='$target'::date+1"))
        assertEquals(0L,number("select count(*) from physiology_work_items where user_id='$user' and day>'$target'::date+1"))
    }

    @Test fun migrationPreservesExistingLegacyAndShadowClaimsWithoutDroppingRows() {
        val owner="10000000-0000-0000-0000-000000000001"
        assertEquals(1L,number("select count(*) from scoring_work_items where user_id='$owner' and day='2026-09-10' and claimed_at is null and attempts=0"))
        assertEquals(1L,number("select count(*) from physiology_work_items where user_id='$owner' and day='2026-09-10' and claimed_at is null and done_at is null"))
        assertEquals(1L,number("select count(*) from physiology_work_items s join scoring_work_items b using(user_id,device_id,day) "+
            "where s.user_id='$owner' and s.day='2026-09-11' and s.lease_token is not null and s.run_id is not null and b.lease_token is null and b.claimed_at is null"))
    }

    @Test fun expiredSameInputBaselineWorkerCannotPublishOrReleaseSuccessor() {
        dirtyBoth();val stale=legacyClaim(1)
        sql("select pg_sleep(1.1)")
        val current=legacyClaim()
        assertEquals(stale.revision,current.revision)
        assertNotEquals(stale.token,current.token)
        expectState("40001") { legacyPublish(stale) }
        assertFalse(legacyDone(stale))
        assertEquals(1L,number("select scoring_legacy_renew_lease(${identity(current)},300)::int"))
        legacyPublish(current);assertTrue(legacyDone(current))
        assertEquals(1L,number("select count(*) from server_physiology_results where user_id='$user'"))
        assertEquals(1L,number("select count(*) from physiology_archive_outbox where user_id='$user'"))
    }

    @Test fun newInputFencesBaselineAndLegacyUnpatchedMutationsFailClosed() {
        dirtyBoth();val stale=legacyClaim();dirtyBoth();val current=legacyClaim()
        expectState("40001") { legacyPublish(stale) }
        assertFalse(legacyDone(stale))
        expectState("42501") { sql("update scoring_work_items set claimed_at=null where user_id='$user'") }
        expectState("42501") { sql("select engine_ingest_scored('test','{}'::jsonb)") }
        assertEquals(1L,number("select scoring_legacy_renew_lease(${identity(current)},300)::int"))
        legacyPublish(current);assertTrue(legacyDone(current))
    }

    @Test fun shadowPublicationCannotUseBaselineAlgorithmIdentity() {
        dirtyBoth();val candidate=shadow.claimOne(user,device,day)!!
        expectState("22023") { sql("select engine_publish_physiology('test',jsonb_build_object("+
            "'user_id','$user','device_id','$device','day','$day','algorithm_version','frwhoop-server-1',"+
            "'input_revision',${candidate.inputRevision},'lease_token','${candidate.leaseToken}','run_id','${candidate.runId}'))") }
        assertEquals(0L,number("select count(*) from server_physiology_results where user_id='$user'"))
    }

    @Test fun movedAndDeletedBaselineEpisodesReplaceTheImmutableCurrentSet() {
        fun episode(start:String,end:String)=JSONObject().put("device_id",device.toString()).put("period_day",day)
            .put("start_at",start).put("end_at",end).put("asleep_min",30)
        dirtyBoth();val first=legacyClaim()
        legacyPublish(first,"[${episode("2026-09-17T01:00:00Z","2026-09-17T01:30:00Z")},"+
            "${episode("2026-09-17T03:00:00Z","2026-09-17T03:30:00Z")}]")
        assertTrue(legacyDone(first))
        dirtyBoth();val moved=legacyClaim()
        legacyPublish(moved,"[${episode("2026-09-17T01:10:00Z","2026-09-17T01:40:00Z")}]")
        assertTrue(legacyDone(moved))
        assertEquals(1L,number("select jsonb_array_length(payload->'nights') from server_physiology_results "+
            "where user_id='$user' and algorithm_version='frwhoop-server-1' order by input_revision desc limit 1"))
        assertEquals(3L,number("select count(*) from server_sleep_nights where user_id='$user'"))
        dirtyBoth();val deleted=legacyClaim();legacyPublish(deleted);assertTrue(legacyDone(deleted))
        assertEquals(0L,number("select jsonb_array_length(payload->'nights') from server_physiology_results "+
            "where user_id='$user' and algorithm_version='frwhoop-server-1' order by input_revision desc limit 1"))
        assertEquals(3L,number("select count(*) from physiology_archive_outbox where user_id='$user'"))
    }

    @Test fun baselineArchiveRetriesExactCommittedSnapshotWithoutRescoring() {
        dirtyBoth();val original=legacyClaim();legacyPublish(original);assertTrue(legacyDone(original))
        val stored=db.withConnection { c -> c.createStatement().use { s ->
            s.executeQuery("select payload::text from server_physiology_results where user_id='$user'").use { r ->
                check(r.next());r.getString(1)
            }
        } }
        val outbox=DerivedArchiveOutbox(db,DerivedArtifactWriter(null,"http://127.0.0.1:1","unused"))
        val first=outbox.claimOne(user)!!
        val firstBytes=first.payload.toString().toByteArray(Charsets.UTF_8)
        assertEquals(JSONObject(stored).toMap(),first.payload.toMap())
        assertEquals("frwhoop-server-1",first.payload.getString("algorithm_version"))
        assertFalse(first.payload.has("lease_token"))
        assertTrue(outbox.finish(first,null,"controlled_archive_failure"))
        assertEquals("available",readFeature().getString("status"))
        assertEquals(0,legacyRunnable())
        assertEquals(original.revision,number("select input_revision from scoring_work_items where user_id='$user'"))
        sql("update physiology_archive_outbox set next_attempt_at=clock_timestamp() where id=${first.id}")
        val retry=outbox.claimOne(user)!!
        assertEquals(first.key,retry.key)
        assertArrayEquals(firstBytes,retry.payload.toString().toByteArray(Charsets.UTF_8))
        assertFalse(outbox.finish(first,"a".repeat(64),null))
        assertTrue(outbox.finish(retry,"b".repeat(64),null))
        assertEquals(1L,number("select count(*) from server_physiology_results where user_id='$user'"))
        assertEquals("verified",readFeature().getString("archive_status"))
        assertEquals(42,readSnapshot().getJSONObject("daily").getInt("hrv_rmssd_ms"))
    }

    private fun expectState(state:String,operation:()->Unit) {
        try { operation();fail("expected SQLSTATE $state") } catch(error:SQLException) { assertEquals(state,error.sqlState) }
    }

    private data class LegacyClaim(val revision:Long,val token:UUID,val run:UUID)
    private lateinit var activeLegacy:LegacyClaim
    private fun dirtyBoth() { sql("select scoring_enqueue_day('$user','$device','$day','UTC',0)") }
    private fun makeDue() { sql("update physiology_work_items set next_attempt_at=clock_timestamp() where user_id='$user'")
        db.withConnection { c -> c.autoCommit=false;try { c.createStatement().use { s ->
            s.execute("select set_config('physiology.legacy_queue_write',txid_current()::text,true)")
            s.execute("update scoring_work_items set next_attempt_at=clock_timestamp() where user_id='$user'")
        };c.commit() } finally { c.autoCommit=true } }
    }
    private fun legacyRunnable()=number("select count(*) from scoring_work_items where user_id='$user' and device_id='$device' and day='$day' "+
        "and done_at is null and (lease_expires_at is null or lease_expires_at<=clock_timestamp()) and consecutive_failures<8").toInt()
    private fun legacyClaim(leaseSeconds:Int=300):LegacyClaim=db.withConnection { c -> c.createStatement().use { s ->
        s.executeQuery("select * from scoring_legacy_claim_one($leaseSeconds,8,'$user','$device','$day')").use { r ->
            check(r.next());LegacyClaim(r.getLong("input_revision"),r.getObject("lease_token",UUID::class.java),
                r.getObject("run_id",UUID::class.java)).also { activeLegacy=it }
        }
    } }
    private fun identity(claim:LegacyClaim)="'$user','$device','$day',${claim.revision},'${claim.token}','${claim.run}'"
    private fun legacyDone(claim:LegacyClaim):Boolean=number("select scoring_legacy_finish_work(${identity(claim)},'done',1,null)::int")>0
    private fun legacyPublish(claim:LegacyClaim=activeLegacy, episodes:String="[]") { sql("select engine_publish_legacy_fenced('test',jsonb_build_object("+
        "'user_id','$user','device_id','$device','day','$day','algorithm_version','frwhoop-server-1',"+
        "'input_revision',${claim.revision},'lease_token','${claim.token}','run_id','${claim.run}',"+
        "'daily_metrics',jsonb_build_array(jsonb_build_object('day','$day','source_device_id','$device','hrv_rmssd_ms',42,'computed_at',clock_timestamp())),"+
        "'sleep_nights','$episodes'::jsonb))") }
    private fun publish(item:ScoringWorkQueue.WorkItem) { sql("select engine_publish_physiology('test',jsonb_build_object("+
        "'schema_version',2,'user_id','$user','device_id','$device','day','$day','algorithm_version','frwhoop-physiology-2',"+
        "'input_revision',${item.inputRevision},'lease_token','${item.leaseToken}','run_id','${item.runId}','computed_at',clock_timestamp(),"+
        "'daily',jsonb_build_object('day','$day','source_device_id','$device'),'nights','[]'::jsonb,'measurements','[]'::jsonb))") }
    private fun readFeature():JSONObject=readSnapshot().getJSONObject("features").getJSONObject("hrv")
    private fun readSnapshot():JSONObject=db.withConnection { c -> c.createStatement().use { s ->
        s.execute("select set_config('request.jwt.claim.sub','$user',false)")
        try { s.executeQuery("select server_scoring_for_day('$user','$day')").use { r ->
            r.next();JSONObject(r.getString(1))
        } } finally { s.execute("select set_config('request.jwt.claim.sub','',false)") }
    } }
    private fun sql(query:String) { db.withConnection { c -> c.createStatement().use { it.execute(query) } } }
    private fun number(query:String):Long=db.withConnection { c -> c.createStatement().use { s -> s.executeQuery(query).use { r ->
        check(r.next());r.getLong(1)
    } } }
}
