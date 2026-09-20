package com.frwhoop.scoring

import com.frwhoop.scoring.db.PostgresClient
import com.frwhoop.scoring.db.SleepContextReader
import com.frwhoop.scoring.scoring.SleepBoundaryOverrides
import com.noop.analytics.DetectedSleep
import org.json.JSONArray
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import java.sql.SQLException
import java.sql.Statement
import java.time.Instant
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Explicit legacy continuation preserves source rows and fences their observed revision. */
class LegacySleepContinuationIntegrationTest {
    private lateinit var db: PostgresClient
    private val user=UUID.randomUUID(); private val device=UUID.randomUUID(); private val id=UUID.randomUUID()
    private val originalStart="2026-09-17T01:00:00.123456Z"
    private val originalEnd="2026-09-17T02:00:00.654321Z"
    private val currentStart="2026-09-17T01:10:00Z"; private val currentEnd="2026-09-17T02:10:00Z"
    private val from=Instant.parse("2026-09-16T00:00:00Z").epochSecond
    private val to=Instant.parse("2026-09-18T00:00:00Z").epochSecond

    @Before fun setup() {
        val url=System.getenv("PHYSIOLOGY_TEST_DATABASE_URL")
        assumeTrue("Run disposable PostgreSQL harness",url!=null)
        require(url!!.contains("@127.0.0.1:") && url.endsWith("/physiology_queue_test"))
        db=PostgresClient(url)
        sql("insert into auth.users values('$user')")
        sql("insert into profiles(id,timezone) values('$user','UTC')")
        sql("insert into devices(id,user_id) values('$device','$user')")
        sql("insert into sessions(id,user_id,device_id,start_at,end_at,user_modified) "+
            "values('$id','$user','$device','$originalStart','$originalEnd',true)")
        sql("insert into sleep_details(session_id,user_id,original_start_at,original_end_at,user_start_at,user_end_at) "+
            "values('$id','$user','$originalStart','$originalEnd','$currentStart','$currentEnd')")
        sql("grant usage on schema auth to authenticated")
    }
    @After fun close() { if(::db.isInitialized) db.close() }

    @Test fun readExposesOwnedLegacyIdentityTokenAndExactOriginalsWithoutMutatingSource() {
        val source=sourceSnapshot()
        val row=read().getJSONObject(0)
        assertEquals(id.toString(),row.getString("id"))
        assertEquals("legacy_user_boundary",row.getString("source"))
        assertEquals(0L,row.getLong("revision"))
        assertTrue(row.getString("legacy_revision").matches(Regex("[a-f0-9]{64}")))
        assertEquals(originalStart,row.getString("original_start_at"))
        assertEquals(originalEnd,row.getString("original_end_at"))
        val boundary=boundaries().single()
        assertEquals("legacy_user_boundary",boundary.provenance)
        assertEquals(0L,boundary.revision)
        assertEquals(source,sourceSnapshot())
        asOwner { s -> expectFailure("42501") {
            s.execute("select physiology_legacy_sleep_boundaries('$user','$device')")
        } }
    }

    @Test fun staleSourceTokenWrongBoundsOwnerAndUnfencedFirstWriteAreRejected() {
        val oldToken=token()
        sql("update sleep_details set user_start_at='2026-09-17T01:15:00Z',updated_at=clock_timestamp() where session_id='$id'")
        val latest=token(); assertNotEquals(oldToken,latest)
        asOwner { s ->
            expectFailure("40001") { s.execute(continueSql(oldToken)) }
            expectFailure("40001") { s.execute(continueSql(latest).replace(originalStart,"2026-09-17T01:00:00Z")) }
            expectFailure("40001") { s.execute(normalSql(0)) }
            expectFailure("42501") { s.execute(normalSql(0).replace("set_physiology_sleep_override","physiology_write_sleep_override")) }
        }
        asOwner(UUID.randomUUID()) { s -> expectFailure("42501") { s.execute(continueSql(latest)) } }
        val source=sourceSnapshot()
        asOwner { s -> assertEquals(1L,result(s,continueSql(latest))) }
        assertEquals(source,sourceSnapshot())
        val row=read().getJSONObject(0)
        assertEquals("physiology_override",row.getString("source")); assertEquals(1L,row.getLong("revision"))
        assertTrue(row.isNull("legacy_revision")); assertEquals(originalStart,row.getString("original_start_at"))
        assertEquals("physiology_override",boundaries().single().provenance)
        asOwner { s -> assertEquals(2L,result(s,normalSql(1))) }
    }

    @Test fun competingConversionsPublishExactlyOneOverrideAndRejectTheLoser() {
        val token=token(); val ready=CountDownLatch(2); val go=CountDownLatch(1)
        val executor=Executors.newFixedThreadPool(2)
        try {
            val attempts=(1..2).map { executor.submit<String> {
                asOwner { s ->
                    ready.countDown(); check(go.await(10,TimeUnit.SECONDS))
                    try { result(s,continueSql(token)); "ok" } catch(e:SQLException) { e.sqlState }
                }
            } }
            assertTrue(ready.await(10,TimeUnit.SECONDS)); go.countDown()
            assertEquals(listOf("40001","ok"),attempts.map { it.get(10,TimeUnit.SECONDS) }.sorted())
            assertEquals(1,read().length()); assertEquals(1L,boundaries().single().revision)
        } finally { go.countDown();executor.shutdownNow() }
    }

    @Test fun concurrentSourceUpdateIsObservedAfterItsRowLockReleases() {
        val token=token(); val executor=Executors.newSingleThreadExecutor(); val attempted=CountDownLatch(1)
        try {
            db.withConnection { c ->
                c.autoCommit=false
                try {
                    c.createStatement().use { it.execute("update sleep_details set user_end_at='2026-09-17T02:15:00Z',"+
                        "updated_at=clock_timestamp() where session_id='$id'") }
                    val future=executor.submit<String> { asOwner { s ->
                        attempted.countDown()
                        try { result(s,continueSql(token)); "unexpected_success" } catch(e:SQLException) { e.sqlState }
                    } }
                    assertTrue(attempted.await(10,TimeUnit.SECONDS)); c.commit()
                    assertEquals("40001",future.get(10,TimeUnit.SECONDS))
                } finally { c.rollback();c.autoCommit=true }
            }
            assertEquals(0L,boundaries().single().revision)
        } finally { executor.shutdownNow() }
    }

    @Test fun continuedTombstoneSuppressesLegacyAndLateGeneratedEpisodesAndCanBeRestored() {
        val token=token(); val source=sourceSnapshot()
        asOwner { s -> assertEquals(1L,result(s,continueSql(token,true))) }
        assertEquals(source,sourceSnapshot())
        sql("update sleep_details set user_end_at='2026-09-17T02:20:00Z',updated_at=clock_timestamp() where session_id='$id'")
        val edits=boundaries(); assertEquals(1,edits.size); assertTrue(edits.single().tombstone)
        val generated=DetectedSleep(Instant.parse(currentStart).epochSecond,Instant.parse(currentEnd).epochSecond,
            0.0,emptyList(),null,null)
        assertTrue(SleepBoundaryOverrides.apply(listOf(generated),edits).isEmpty())
        asOwner { s ->
            expectFailure("40001") { s.execute(continueSql(token)) }
            assertEquals(2L,result(s,normalSql(1)))
        }
        val restored=boundaries().single(); assertFalse(restored.tombstone); assertEquals(2L,restored.revision)
        assertEquals(originalStart,read().getJSONObject(0).getString("original_start_at"))
    }

    @Test fun detailOnlyManualBoundaryRemainsContinuableButAnotherDeviceDoesNotSeeIt() {
        sql("update sessions set user_modified=false where id='$id'")
        val token=token()
        asOwner { s ->
            val other=UUID.randomUUID()
            s.executeQuery("select physiology_owned_sleep_overrides('$user','$other','2026-09-17')").use {
                it.next(); assertEquals(0,JSONArray(it.getString(1)).length())
            }
            assertEquals(1L,result(s,continueSql(token)))
        }
    }

    private fun continueSql(token:String,tombstone:Boolean=false)="select continue_legacy_physiology_sleep_override("+
        "'$id','$device','$originalStart','$originalEnd','$currentStart','$currentEnd',$tombstone,0,'$token')"
    private fun normalSql(revision:Long)="select set_physiology_sleep_override("+
        "'$id','$device','$originalStart','$originalEnd','$currentStart','$currentEnd',false,$revision)"
    private fun read():JSONArray=asOwner { s -> s.executeQuery(
        "select physiology_owned_sleep_overrides('$user','$device','2026-09-17')").use { it.next();JSONArray(it.getString(1)) } }
    private fun token()=read().getJSONObject(0).getString("legacy_revision")
    private fun boundaries()=db.withConnection { SleepContextReader.overrides(it,user,device,from,to) }
    private fun sourceSnapshot()=db.withConnection { c -> c.createStatement().use { s ->
        s.executeQuery("select jsonb_build_array(to_jsonb(s),to_jsonb(d))::text from sessions s "+
            "join sleep_details d on d.session_id=s.id where s.id='$id'").use { it.next();it.getString(1) }
    } }
    private fun <T> asOwner(owner:UUID=user,block:(Statement)->T):T=db.withConnection { c -> c.createStatement().use { s ->
        s.execute("set role authenticated");s.execute("select set_config('request.jwt.claim.sub','$owner',false)")
        try { block(s) } finally {
            s.execute("reset role");s.execute("select set_config('request.jwt.claim.sub','',false)")
        }
    } }
    private fun result(s:Statement,query:String)=s.executeQuery(query).use { it.next();it.getLong(1) }
    private fun sql(query:String)=db.withConnection { c -> c.createStatement().use { it.execute(query) };Unit }
    private fun expectFailure(state:String,block:()->Unit) {
        try { block();fail("Expected SQLSTATE $state") } catch(e:SQLException) { assertEquals(state,e.sqlState) }
    }
}
