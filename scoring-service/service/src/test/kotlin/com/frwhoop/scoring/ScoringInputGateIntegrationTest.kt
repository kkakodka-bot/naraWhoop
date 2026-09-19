package com.frwhoop.scoring

import com.frwhoop.scoring.db.EngineIngestWriter
import com.frwhoop.scoring.db.PostgresClient
import com.frwhoop.scoring.db.ScoringInputGate
import com.frwhoop.scoring.db.ScoringWorkQueue
import com.frwhoop.scoring.scoring.ServerScoreBundle
import com.frwhoop.scoring.signals.PhysiologyShadowRunner
import com.noop.analytics.DayResult
import com.noop.data.DailyMetric
import com.sun.net.httpserver.HttpServer
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import java.net.InetSocketAddress
import java.nio.file.Path
import java.sql.SQLException
import java.time.Duration
import java.time.Instant
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Real projection triggers and RPC publication; the HTTP adapter only replaces PostgREST. */
class ScoringInputGateIntegrationTest {
    private lateinit var db: PostgresClient
    private lateinit var queue: ScoringWorkQueue
    private val user = UUID.randomUUID()
    private val device = UUID.randomUUID()
    private val source = UUID.randomUUID()
    private val batch = UUID.randomUUID()
    private val day = "2026-09-17"
    private val ts = Instant.parse("2026-09-17T12:00:00Z").epochSecond

    @Before fun setup() {
        val url = System.getenv("PHYSIOLOGY_TEST_DATABASE_URL")
        assumeTrue("Run scripts/test-physiology-queue.sh for real PostgreSQL",url != null)
        require(url!!.contains("@127.0.0.1:") && url.endsWith("/physiology_queue_test"))
        db = PostgresClient(url); queue = ScoringWorkQueue(db)
        owner(user,device)
    }
    @After fun close() { if (::db.isInitialized) db.close() }

    @Test fun moreThan300LiveArrivalCyclesPublishThroughSeparateHttpSessionsWithoutDroppingInputs() {
        val server = HttpServer.create(InetSocketAddress("127.0.0.1",0),0)
        val executor = Executors.newSingleThreadExecutor()
        server.executor = executor
        server.createContext("/rpc/engine_publish_physiology") { exchange ->
            try {
                val body = JSONObject(exchange.requestBody.bufferedReader().readText())
                publish(body.getJSONObject("p_payload"))
                val bytes = "{\"ok\":true}".toByteArray()
                exchange.sendResponseHeaders(200,bytes.size.toLong())
                exchange.responseBody.use { it.write(bytes) }
            } catch (error: Exception) {
                val bytes = error.javaClass.simpleName.toByteArray()
                exchange.sendResponseHeaders(500,bytes.size.toLong())
                exchange.responseBody.use { it.write(bytes) }
            } finally { exchange.close() }
        }
        server.start()
        try {
            val writer = EngineIngestWriter("http://127.0.0.1:${server.address.port}","test","test")
            sql(hrInsert(ts))
            repeat(305) { index ->
                makeDue()
                val candidate = queue.peekOne(user,device,day)!!
                val completed = queue.withInputGate(candidate) { guard ->
                    val item = queue.claimOne(user,device,day)!!
                    assertEquals(index+1L,item.inputRevision)
                    // Same shape as a separate PostgREST projection request arriving during score.
                    busy { sql(hrInsert(ts+index+1)) }
                    assertEquals(index+1L,rows("noop_hr_samples"))
                    guard.requireActive()
                    writer.write(emptyTransportFixture(),item)
                    assertTrue(queue.renew(item))
                    queue.markDone(item,1)
                }
                assertEquals(true,completed)
                // No ACK was sent for the rejected projection; retry exact original row.
                sql(hrInsert(ts+index+1))
                assertEquals(index+2L,revision())
            }
            assertEquals(306L,rows("noop_hr_samples"))
            assertEquals(305L,rows("server_physiology_results"))
            assertEquals(305L,rows("physiology_archive_outbox"))
            assertEquals(0L,number("select consecutive_failures from physiology_work_items where user_id='$user' and day='$day'"))
        } finally { server.stop(0); executor.shutdownNow() }
    }

    @Test fun inputCommittedBeforeGateAcquisitionBelongsToTheClaim() {
        queue.dirtyWorkItem(user,device,day)
        val executor = Executors.newSingleThreadExecutor()
        try {
            db.withConnection { writer ->
                writer.autoCommit=false
                writer.createStatement().use { it.execute(hrInsert(ts)) }
                val starting = CountDownLatch(1)
                val future = executor.submit<Long> {
                    starting.countDown()
                    ScoringInputGate(db).withGate(user,device) {
                        queue.claimOne(user,device,day)!!.inputRevision
                    }!!
                }
                assertTrue(starting.await(2,TimeUnit.SECONDS))
                assertFalse("gate must wait for the earlier input transaction",future.isDone)
                writer.commit(); writer.autoCommit=true
                assertEquals(2L,future.get(5,TimeUnit.SECONDS))
            }
        } finally { executor.shutdownNow() }
    }

    @Test fun callerAlreadyHoldingPublicationMutexRollsBackInsteadOfDeadlocking() {
        sql(hrInsert(ts)); makeDue()
        ScoringInputGate(db).withGate(user,device) {
            val item = queue.claimOne(user,device,day)!!
            db.withConnection { incoming ->
                incoming.autoCommit=false
                try {
                    incoming.createStatement().use { statement ->
                        statement.execute("set local statement_timeout='1s'")
                        statement.execute("select scoring_lock_device('$user','$device')")
                        busy { statement.execute(hrInsert(ts+1)) }
                    }
                } finally { incoming.rollback(); incoming.autoCommit=true }
            }
            publish(payload(item)); assertTrue(queue.markDone(item,1))
        }
        assertEquals(1L,rows("noop_hr_samples")); sql(hrInsert(ts+1))
        assertEquals(2L,rows("noop_hr_samples"))
    }

    @Test fun changedAuxiliaryProjectionsCannotCommitWithoutTheirRevisions() {
        sql(hrInsert(ts)); val before=revision()
        ScoringInputGate(db).withGate(user,device) {
            val writes = listOf(
                "insert into noop_rr_intervals(user_id,device_id,source_id,ts,\"rrMs\",seq,batch_id) values('$user','$device','$source',$ts,1000,1,'$batch')",
                "insert into noop_resp_samples(user_id,device_id,source_id,ts,raw,batch_id) values('$user','$device','$source',$ts,10,'$batch')",
                "insert into noop_gravity_samples(user_id,device_id,source_id,ts,x,y,z,batch_id) values('$user','$device','$source',$ts,0,0,1,'$batch')",
                "insert into noop_events(user_id,device_id,source_id,ts,kind,\"payloadJSON\",batch_id) values('$user','$device','$source',$ts,'WRIST_OFF','{}','$batch')",
                "update noop_hr_samples set bpm=75 where user_id='$user'",
                "delete from noop_hr_samples where user_id='$user'",
            )
            writes.forEach { query -> busy { sql(query) } }
            // Metadata-only retries do not alter physiology and must remain harmless.
            sql("update noop_hr_samples set ingested_at=clock_timestamp() where user_id='$user'")
            assertEquals(before,revision())
            assertEquals(60L,number("select bpm from noop_hr_samples where user_id='$user'"))
        }
        assertEquals(0L,rows("noop_rr_intervals")); assertEquals(0L,rows("noop_events"))
    }

    @Test fun otherOwnersAndDevicesContinueIngestingAndGateIsServiceOnly() {
        val otherUser=UUID.randomUUID(); val otherDevice=UUID.randomUUID()
        owner(otherUser,otherDevice)
        ScoringInputGate(db).withGate(user,device) {
            sql(hrInsert(ts,otherUser,otherDevice))
            assertEquals(1L,number("select count(*) from noop_hr_samples where user_id='$otherUser'"))
            db.withConnection { conn -> conn.createStatement().use { statement ->
                statement.execute("set role authenticated")
                try { failure("42501") { statement.execute("select scoring_acquire_input_gate('$otherUser','$otherDevice')") } }
                finally { statement.execute("reset role") }
            } }
        }
        failure("23503") { ScoringInputGate(db).withGate(user,otherDevice) { true } }
    }

    @Test fun expiredGateReleasesConnectionAndOldClaimCannotPublishOrReleaseSuccessor() {
        sql(hrInsert(ts)); makeDue()
        var obsolete: ScoringWorkQueue.WorkItem?=null
        ScoringInputGate(db,Duration.ofMillis(150)).withGate(user,device) { guard ->
            obsolete=queue.claimOne(user,device,day)!!
            CountDownLatch(1).await(350,TimeUnit.MILLISECONDS)
            assertFalse(guard.active)
            // Runs before withGate returns: its deadline, not finally, must release the lock.
            sql(hrInsert(ts+1))
        }
        makeDue()
        ScoringInputGate(db).withGate(user,device) {
            val successor=queue.claimOne(user,device,day)!!
            failure("40001") { publish(payload(obsolete!!)) }
            assertFalse(queue.markDone(obsolete!!,1)); assertFalse(queue.markFailed(obsolete!!,"old"))
            publish(payload(successor)); assertTrue(queue.markDone(successor,1))
        }
        sql(hrInsert(ts+2)); assertEquals(3L,rows("noop_hr_samples"))
    }

    @Test fun workerDatabaseConnectionDeathReleasesTheGateWithoutAcknowledgingAnything() {
        db.withConnection { holder ->
            holder.autoCommit=false
            val pid=holder.createStatement().use { statement ->
                statement.execute("select scoring_acquire_input_gate('$user','$device')")
                statement.executeQuery("select pg_backend_pid()").use { r -> r.next();r.getInt(1) }
            }
            busy { sql(hrInsert(ts)) }
            sql("select pg_terminate_backend($pid)")
            sql(hrInsert(ts))
            runCatching { holder.rollback() }
        }
        assertEquals(1L,rows("noop_hr_samples")); assertEquals(1L,revision())
    }

    @Test fun slowOrExpiredShadowBudgetStillLeavesTimeForFencedPublication() {
        val model=PhysiologyShadowRunner.Model("neurokit2",JSONObject(),Path.of("."))
        val assembler=PhysiologyShadowRunner.JobAssembler { _,request,_ -> PhysiologyShadowRunner.PreparedJob(JSONObject()
            .put("user_id",request.userId).put("device_id",request.deviceId).put("input_revision",request.inputRevision)) }
        var modelCalls=0
        val slow=PhysiologyShadowRunner.Executor { _,_ -> modelCalls++;Thread.sleep(5000);JSONObject() }
        val runner=PhysiologyShadowRunner(models=listOf(model),executor=slow,assembler=assembler,totalTimeoutSeconds=120)
        repeat(2) { index ->
            sql(hrInsert(ts+index));makeDue()
            ScoringInputGate(db,Duration.ofSeconds(3)).withGate(user,device) { guard ->
                val item=queue.claimOne(user,device,day)!!
                val budget=if(index==0) guard.remainingDuration.minusSeconds(2) else Duration.ZERO
                val shadow=runner.evaluate(PhysiologyShadowRunner.Request(user,device,item.inputRevision.toString(),
                    ts,ts+300,emptyList()),budget)
                if(index==0) assertTrue(shadow.rawReasons.isEmpty())
                else assertTrue(shadow.rawReasons.contains("shadow_publication_budget_exhausted"))
                assertEquals(0,modelCalls)
                guard.requireActive()
                publish(EngineIngestWriter.publicationPayload(emptyTransportFixture().copy(physiologyShadow=shadow),item))
                assertTrue(queue.markDone(item,1))
            }
        }
        assertEquals(2L,rows("server_physiology_results"));assertEquals(2L,rows("physiology_archive_outbox"))
    }

    private fun emptyTransportFixture()=ServerScoreBundle(user,day,device.toString(),"frwhoop-physiology-2",
        DayResult(DailyMetric(deviceId=device.toString(),day=day),emptyList(),emptyList(),null,null))
    private fun payload(item:ScoringWorkQueue.WorkItem)=EngineIngestWriter.publicationPayload(emptyTransportFixture(),item)
    private fun publish(value:JSONObject) { db.withConnection { conn ->
        conn.prepareStatement("select engine_publish_physiology('test',?::jsonb)").use { p ->
            p.setString(1,value.toString());p.execute()
        }
    } }
    private fun owner(owner:UUID,strap:UUID) {
        sql("insert into auth.users values('$owner')")
        sql("insert into profiles(id,timezone) values('$owner','UTC')")
        sql("insert into devices(id,user_id) values('$strap','$owner')")
    }
    private fun hrInsert(at:Long,owner:UUID=user,strap:UUID=device)=
        "insert into noop_hr_samples(user_id,device_id,source_id,ts,bpm,batch_id) values('$owner','$strap','$source',$at,60,'$batch')"
    private fun makeDue()=sql("update physiology_work_items set next_attempt_at=clock_timestamp() where user_id='$user'")
    private fun revision()=number("select input_revision from physiology_work_items where user_id='$user' and day='$day'")
    private fun rows(table:String)=number("select count(*) from $table where user_id='$user'")
    private fun sql(query:String) { db.withConnection { c -> c.createStatement().use { it.execute(query) } } }
    private fun number(query:String):Long=db.withConnection { c -> c.createStatement().use { s ->
        s.executeQuery(query).use { r -> r.next();r.getLong(1) }
    } }
    private fun busy(block:()->Unit) {
        try { block();fail("expected retryable projection contention") }
        catch(error:SQLException) { assertEquals("55P03",error.sqlState); assertTrue(error.message.orEmpty().contains("scoring_input_gate_busy")) }
    }
    private fun failure(state:String,block:()->Unit) {
        try { block();fail("expected SQLSTATE $state") }
        catch(error:SQLException) { assertEquals(state,error.sqlState) }
    }
}
