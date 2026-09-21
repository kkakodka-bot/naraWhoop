package com.frwhoop.scoring

import com.frwhoop.scoring.db.EngineIngestWriter
import com.frwhoop.scoring.db.PostgresClient
import com.frwhoop.scoring.db.ScoringInputGate
import com.frwhoop.scoring.db.ScoringWorkQueue
import com.frwhoop.scoring.db.ScoreInputProvider
import com.frwhoop.scoring.db.SignalSampleReader
import com.frwhoop.scoring.health.HeartbeatReporter
import com.frwhoop.scoring.scoring.DayScorer
import com.frwhoop.scoring.scoring.ScoringPoller
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
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicBoolean

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
            failure("PT409") { publish(payload(obsolete!!)) }
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

    @Test fun deterministicInputDeadlineCancelsActualJdbcAndBacksOffBeforeAnotherOwnerRuns() {
        val otherUser=UUID.randomUUID(); val otherDevice=UUID.randomUUID()
        owner(otherUser,otherDevice)
        sql(hrInsert(ts)); makeDue()
        sql(hrInsert(ts,otherUser,otherDevice))
        sql("update physiology_work_items set next_attempt_at=clock_timestamp() where user_id='$otherUser'")
        val nextOwnerCalls=AtomicInteger()
        val provider=object:ScoreInputProvider {
            override fun loadDay(userId:UUID,day:String,deviceId:UUID):SignalSampleReader.DayInputs? {
                if(userId==user) db.withConnection { c -> c.createStatement().use { it.execute("select pg_sleep(30)") } }
                else nextOwnerCalls.incrementAndGet()
                return null
            }
        }
        val poller=poller(provider)
        val began=System.nanoTime()
        assertEquals(false,poller.processCandidate(ScoringWorkQueue.Candidate(user,device,day)))
        assertTrue("JDBC input must not keep the attempt alive",(System.nanoTime()-began)/1e9<4)
        assertEquals(1L,number("select count(*) from physiology_work_items where user_id='$user' and status='retry' " +
            "and last_error='scoring_attempt_timeout' and lease_token is null and consecutive_failures=1 and next_attempt_at>clock_timestamp()"))
        assertNull(queue.peekOne(user,device,day))
        assertEquals(false,poller.processCandidate(ScoringWorkQueue.Candidate(otherUser,otherDevice,day)))
        assertEquals(1,nextOwnerCalls.get())
        assertEquals(1L,number("select count(*) from physiology_work_items where user_id='$otherUser' and status='waiting'"))
        assertEquals(0L,rows("server_physiology_results"))
        // Cancellation released the input gate; the next real arrival remains writable and revises the failed job.
        sql(hrInsert(ts+1)); assertEquals(2L,revision())
    }

    @Test fun capturedInputReleasesProjectionGateBeforePublicationAndRejectsSupersededResult() {
        sql(hrInsert(ts)); makeDue()
        val incoming = AtomicInteger()
        val rejected = AtomicInteger()
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/rpc/engine_publish_physiology") { exchange ->
            try {
                val payload = JSONObject(exchange.requestBody.bufferedReader().readText()).getJSONObject("p_payload")
                sql(hrInsert(ts + 1))
                incoming.incrementAndGet()
                try { publish(payload) }
                catch (error: SQLException) {
                    if (error.sqlState == "PT409") rejected.incrementAndGet() else throw error
                }
                exchange.sendResponseHeaders(409, -1)
            } finally { exchange.close() }
        }
        server.start()
        try {
            val worker = poller(SignalSampleReader(db), "http://127.0.0.1:${server.address.port}", Duration.ofSeconds(5))
            assertEquals(false, worker.processCandidate(ScoringWorkQueue.Candidate(user, device, day)))
            assertEquals(1, incoming.get())
            assertEquals(1, rejected.get())
            assertEquals(2L, revision())
            assertEquals(2L, rows("noop_hr_samples"))
            assertEquals(0L, rows("server_physiology_results"))
            makeDue()
            assertNotNull(queue.peekOne(user, device, day))
        } finally { server.stop(0) }
    }

    @Test fun realReaderBlockedOnProjectionLockIsCancelledWithoutAbortingUnrelatedConnection() {
        sql(hrInsert(ts)); makeDue()
        db.withConnection { blocker ->
            blocker.autoCommit=false
            blocker.createStatement().use { it.execute("lock table noop_hr_samples in access exclusive mode") }
            try {
                val began=System.nanoTime()
                assertEquals(false,poller(SignalSampleReader(db)).processCandidate(ScoringWorkQueue.Candidate(user,device,day)))
                assertTrue((System.nanoTime()-began)/1e9<4)
                assertTrue("Cancellation must leave other DB owners/connections intact",blocker.isValid(1))
                assertEquals(1L,number("select count(*) from physiology_work_items where user_id='$user' and status='retry'"))
            } finally { blocker.rollback(); blocker.autoCommit=true }
        }
        sql(hrInsert(ts+1))
    }

    @Test fun deadlineStopsAnAlreadyRenewingClaimAndClearsItsLease() {
        sql(hrInsert(ts)); makeDue()
        val renewed=AtomicBoolean(false)
        val provider=object:ScoreInputProvider {
            override fun loadDay(userId:UUID,day:String,deviceId:UUID):SignalSampleReader.DayInputs? {
                CountDownLatch(1).await(450,TimeUnit.MILLISECONDS)
                renewed.set(number("select count(*) from physiology_work_items where user_id='$user' and day='$day' " +
                    "and lease_expires_at>claimed_at+interval '1.1 seconds'")==1L)
                db.withConnection { c -> c.createStatement().use { it.execute("select pg_sleep(30)") } }
                return null
            }
        }
        val shortLease=ScoringWorkQueue(db,claimLease=Duration.ofSeconds(1))
        assertEquals(false,poller(provider,duration=Duration.ofMillis(900),workQueue=shortLease)
            .processCandidate(ScoringWorkQueue.Candidate(user,device,day)))
        assertTrue("The deadline must interrupt a claim whose renewal actually ran",renewed.get())
        CountDownLatch(1).await(400,TimeUnit.MILLISECONDS)
        assertEquals(1L,number("select count(*) from physiology_work_items where user_id='$user' and day='$day' " +
            "and status='retry' and lease_token is null and lease_expires_at is null and consecutive_failures=1"))
        assertEquals(0,Thread.getAllStackTraces().keys.count { it.name=="scoring-lease-renewal" && it.isAlive })
    }

    @Test fun followingOwnerCompletesFencedPublicationAfterTimedOutInput() {
        val otherUser=UUID.randomUUID(); val otherDevice=UUID.randomUUID()
        owner(otherUser,otherDevice)
        sql(hrInsert(ts)); makeDue()
        sql(hrInsert(ts,otherUser,otherDevice))
        sql("update physiology_work_items set next_attempt_at=clock_timestamp() where user_id='$otherUser'")
        val provider=object:ScoreInputProvider {
            override fun loadDay(userId:UUID,day:String,deviceId:UUID):SignalSampleReader.DayInputs? {
                if(userId==user) CountDownLatch(1).await(30,TimeUnit.SECONDS)
                return SignalSampleReader(db).loadDay(userId,day,deviceId)
            }
        }
        val server=HttpServer.create(InetSocketAddress("127.0.0.1",0),0)
        server.createContext("/rpc/engine_publish_physiology") { exchange ->
            try {
                val body=JSONObject(exchange.requestBody.bufferedReader().readText())
                publish(body.getJSONObject("p_payload"))
                exchange.sendResponseHeaders(200,2)
                exchange.responseBody.use { it.write("{}".toByteArray()) }
            } finally { exchange.close() }
        }
        server.start()
        try {
            val url="http://127.0.0.1:${server.address.port}"
            assertEquals(false,poller(provider,url).processCandidate(ScoringWorkQueue.Candidate(user,device,day)))
            assertNull(queue.peekOne(user,device,day))
            assertEquals(true,poller(provider,url,Duration.ofSeconds(5))
                .processCandidate(ScoringWorkQueue.Candidate(otherUser,otherDevice,day)))
            assertEquals(1L,number("select count(*) from server_physiology_results where user_id='$otherUser' and device_id='$otherDevice'"))
            assertEquals(1L,number("select count(*) from physiology_work_items where user_id='$otherUser' and day='$day' and status='done' and lease_token is null"))
            assertEquals(0L,rows("server_physiology_results"))
        } finally { server.stop(0) }
    }

    @Test fun ignoredInterruptionStopsWorkerAfterFencedBackoffAndCannotPublishLate() {
        sql(hrInsert(ts)); makeDue()
        val inputs=SignalSampleReader(db).loadDay(user,day,device)!!
        val release=CountDownLatch(1); val returned=CountDownLatch(1)
        val provider=object:ScoreInputProvider {
            override fun loadDay(userId:UUID,day:String,deviceId:UUID):SignalSampleReader.DayInputs {
                while(release.count>0) { try { release.await() } catch(_:InterruptedException) {} }
                returned.countDown(); return inputs
            }
        }
        val requests=AtomicInteger()
        val server=HttpServer.create(InetSocketAddress("127.0.0.1",0),0)
        server.createContext("/rpc/engine_publish_physiology") { exchange ->
            requests.incrementAndGet(); exchange.sendResponseHeaders(500,-1); exchange.close()
        }
        server.start()
        try {
            val runner=poller(provider,"http://127.0.0.1:${server.address.port}")
            val began=System.nanoTime()
            try { runner.processCandidate(ScoringWorkQueue.Candidate(user,device,day)); fail("Expected terminal cancellation failure") }
            catch(_:ScoringPoller.UnresponsiveAttempt) {}
            assertTrue((System.nanoTime()-began)/1e9<4)
            assertEquals(1L,number("select count(*) from physiology_work_items where user_id='$user' and status='retry' and lease_token is null"))
            release.countDown(); assertTrue(returned.await(1,TimeUnit.SECONDS))
            // Let the abandoned task pass its post-input cancellation check; no publication may follow.
            CountDownLatch(1).await(100,TimeUnit.MILLISECONDS)
            assertEquals(0,requests.get()); assertEquals(0L,rows("server_physiology_results"))
            sql(hrInsert(ts+1))
        } finally { release.countDown(); server.stop(0) }
    }

    @Test fun boundedDatabaseClientEnforcesServerTimeoutAndKeepsSocketBoundsDespiteUrlOverrides() {
        val url=System.getenv("PHYSIOLOGY_TEST_DATABASE_URL")!!
        PostgresClient("$url?socketTimeout=0&connectTimeout=0&options=-c%20statement_timeout%3D0",queryTimeoutSeconds=1).use { bounded ->
            assertEquals("6",bounded.dataSource.dataSourceProperties["socketTimeout"].toString())
            assertEquals("5",bounded.dataSource.dataSourceProperties["connectTimeout"].toString())
            bounded.withConnection { c ->
                c.createStatement().use { s ->
                    s.executeQuery("show statement_timeout").use { r -> r.next();assertEquals("1s",r.getString(1)) }
                    val began=System.nanoTime()
                    try { s.execute("select pg_sleep(30)");fail("Expected statement timeout") }
                    catch(error:SQLException) { assertEquals("57014",error.sqlState) }
                    assertTrue((System.nanoTime()-began)/1e9<4)
                }
            }
        }
    }

    @Test fun anotherWorkersLiveDayDoesNotBlockASeparateUsersPendingWork() = busyDeviceDoesNotBlockOtherOwner(true)

    @Test fun busyGateBeforeClaimSkipsEveryPendingDayForThatDeviceAndVisitsOtherOwner() = busyDeviceDoesNotBlockOtherOwner(false)

    @Test fun boundedScanProgressesPastEightBusyDevicesAndWrapsToRevisedEarlierWork() {
        val busyOwners=(0 until 8).map { UUID.randomUUID() to UUID.randomUUID() }
        val freeOwner=UUID.randomUUID() to UUID.randomUUID()
        val owners=busyOwners+freeOwner
        owners.forEachIndexed { index,(ownerId,strap) ->
            owner(ownerId,strap);queue.dirtyWorkItem(ownerId,strap,day)
            sql("update physiology_work_items set next_attempt_at='2000-01-01'::timestamptz+interval '$index seconds' where user_id='$ownerId'")
        }
        val reads=mutableMapOf<UUID,Int>()
        val reader=object:ScoreInputProvider {
            override fun loadDay(userId:UUID,day:String,deviceId:UUID):SignalSampleReader.DayInputs? {
                reads[userId]=(reads[userId]?:0)+1
                return null
            }
        }
        val poller=poller(reader,duration=Duration.ofSeconds(5))
        onlyOwnersDue(owners.map { it.first }.toSet()) {
            db.withConnection { holder ->
                holder.autoCommit=false
                try {
                    holder.prepareStatement("select scoring_acquire_input_gate(?,?)").use { p ->
                        busyOwners.forEach { (owner,strap) -> p.setObject(1,owner);p.setObject(2,strap);p.execute() }
                    }
                    val before=busyOwners.associate { it.first to queueRows(it.first) }
                    poller.pollOnce()
                    assertTrue("one bounded poll may examine only the eight busy devices",reads.isEmpty())
                    poller.pollOnce()
                    assertEquals("the next poll must reach the ninth owner without releasing the first eight gates",1,reads[freeOwner.first])
                    busyOwners.forEach { (owner,_) ->
                        assertNull(reads[owner]);assertEquals(before[owner],queueRows(owner))
                    }
                } finally { holder.rollback();holder.autoCommit=true }
            }
            // Replace every queued revision and move the ordering keys before the saved cursor.
            // The cursor is a fair scan position, never permission to discard earlier work.
            owners.forEach { (owner,strap) ->
                assertEquals(2L,queue.dirtyWorkItem(owner,strap,day))
                sql("update physiology_work_items set next_attempt_at='1999-01-01' where user_id='$owner'")
            }
            repeat(2) { poller.pollOnce() }
            busyOwners.forEach { (owner,_) -> assertEquals("released/revised owner must be revisited",1,reads[owner]) }
            assertEquals(2,reads[freeOwner.first])
        }
    }

    private fun busyDeviceDoesNotBlockOtherOwner(hasRunningClaim:Boolean) {
        val otherUser=UUID.randomUUID();val otherDevice=UUID.randomUUID()
        owner(otherUser,otherDevice)
        queue.dirtyWorkItem(user,device,day)
        queue.dirtyWorkItem(user,device,"2026-09-18")
        queue.dirtyWorkItem(otherUser,otherDevice,day)
        sql("update physiology_work_items set next_attempt_at='2000-01-01' where user_id='$user'")
        sql("update physiology_work_items set next_attempt_at='2000-01-02' where user_id='$otherUser'")
        val busyReads=AtomicInteger();val otherReads=AtomicInteger()
        val reader=object:ScoreInputProvider {
            override fun loadDay(userId:UUID,day:String,deviceId:UUID):SignalSampleReader.DayInputs? {
                if(userId==user) busyReads.incrementAndGet()
                if(userId==otherUser) otherReads.incrementAndGet()
                return null // The waiting result exercises completion without any HTTP publisher.
            }
        }
        val poller=poller(reader,duration=Duration.ofSeconds(5))
        onlyOwnersDue(setOf(user,otherUser)) {
            queue.withInputGate(ScoringWorkQueue.Candidate(user,device,day)) {
                if(hasRunningClaim) assertNotNull(queue.claimOne(user,device,day))
                val before=queueRows(user)
                poller.pollOnce()
                assertEquals("unrelated owner must progress while the original gate remains held",1,otherReads.get())
                assertEquals(0,busyReads.get())
                assertEquals("polling must not claim, release, retry or mutate busy device work",before,queueRows(user))
                assertEquals(1L,number("select count(*) from physiology_work_items where user_id='$otherUser' and status='waiting' and consecutive_failures=0"))
            }
        }
    }

    private fun poller(provider:ScoreInputProvider,url:String="http://127.0.0.1:1",duration:Duration=Duration.ofMillis(250),
                       workQueue:ScoringWorkQueue=queue)=ScoringPoller(
        ScoringConfig(System.getenv("PHYSIOLOGY_TEST_DATABASE_URL"),"test",url,"test"),provider,workQueue,DayScorer(),
        EngineIngestWriter(url,"test","test"),HeartbeatReporter(db,"frwhoop-physiology-2",
            com.frwhoop.scoring.health.WorkerHeartbeatIdentity(UUID.randomUUID(),"a".repeat(40))),
        maximumAttemptDuration=duration,cancellationGrace=Duration.ofMillis(500))

    /** Existing integration fixtures share this disposable database; preserve their due times. */
    private fun onlyOwnersDue(owners:Set<UUID>,block:()->Unit) {
        val excluded=owners.joinToString(",") { "'$it'" }
        val held=db.withConnection { conn -> conn.createStatement().use { statement ->
            statement.executeQuery("select user_id,device_id,day,next_attempt_at from physiology_work_items where user_id not in ($excluded)").use { rows ->
                buildList { while(rows.next()) add(listOf(rows.getString(1),rows.getString(2),rows.getString(3),rows.getString(4))) }
            }
        } }
        sql("update physiology_work_items set next_attempt_at='infinity' where user_id not in ($excluded)")
        try { block() } finally {
            db.withConnection { conn -> conn.prepareStatement("update physiology_work_items set next_attempt_at=?::timestamptz where user_id=?::uuid and device_id=?::uuid and day=?::date").use { p ->
                held.forEach { row -> p.setString(1,row[3]);p.setString(2,row[0]);p.setString(3,row[1]);p.setString(4,row[2]);p.addBatch() }
                p.executeBatch()
            } }
        }
    }

    private fun queueRows(owner:UUID):String=db.withConnection { conn -> conn.createStatement().use { statement ->
        statement.executeQuery("select jsonb_agg(to_jsonb(w) order by day)::text from physiology_work_items w where user_id='$owner'").use { rows -> rows.next();rows.getString(1) }
    } }

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
