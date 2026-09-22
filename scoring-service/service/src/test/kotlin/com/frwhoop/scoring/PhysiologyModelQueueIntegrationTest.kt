package com.frwhoop.scoring

import com.frwhoop.scoring.db.PostgresClient
import com.frwhoop.scoring.db.ScoringWorkQueue
import com.frwhoop.scoring.signals.ModelWorkQueue
import com.frwhoop.scoring.signals.PhysiologyShadowRunner
import com.frwhoop.scoring.signals.JdbcAcquisitionContractResolver
import com.frwhoop.scoring.b2.B2ObjectStore
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import java.nio.file.Path
import java.sql.SQLException
import java.util.UUID

class PhysiologyModelQueueIntegrationTest {
    private lateinit var db: PostgresClient
    private lateinit var queue: ModelWorkQueue
    private val user=UUID.randomUUID()
    private val device=UUID.randomUUID()
    private val day="2026-09-17"
    private val model=model("queue-test-${UUID.randomUUID()}")

    @Before fun setup() {
        val url=System.getenv("PHYSIOLOGY_TEST_DATABASE_URL")
        assumeTrue("Run scripts/test-physiology-queue.sh",url!=null)
        require(url!!.contains("@127.0.0.1:") && url.endsWith("/physiology_queue_test"))
        db=PostgresClient(url);queue=ModelWorkQueue(db,10)
        resetFleetTestState(db)
        sql("insert into auth.users values('$user')")
        sql("insert into profiles(id,timezone) values('$user','UTC')")
        sql("insert into devices(id,user_id) values('$device','$user')")
        dirty();activate(model)
    }
    @After fun close() { if(::db.isInitialized) {
        sql("update physiology_model_selection set enabled=false where model_id like 'queue-test-%'")
        db.close()
    } }

    @Test fun modelLeaseNeverConsumesDeterministicOrOtherModelLease() {
        sql("update noop_fleet_intake_policy set model_slots=2")
        val first=queue.claim(model)!!
        assertNull(queue.claim(model))
        val other=model("queue-test-${UUID.randomUUID()}");activate(other)
        val second=queue.claim(other)!!
        val deterministic=ScoringWorkQueue(db).claimOne(user,device,day)!!
        assertTrue(queue.renew(first));assertTrue(queue.renew(second))
        assertTrue(ScoringWorkQueue(db).renew(deterministic))
        assertTrue(queue.finish(first,output(first,model)))
        assertEquals(0L,count("select count(*) from server_physiology_results where user_id='$user'"))
    }

    @Test fun failureBackoffDoesNotBlockAnotherUserAndNewRevisionRestartsBudget() {
        val job=queue.claim(model)!!
        assertTrue(queue.finish(job,failure="inference_timeout"));assertNull(queue.claim(model))
        val otherUser=UUID.randomUUID();val otherDevice=UUID.randomUUID()
        sql("insert into auth.users values('$otherUser')")
        sql("insert into profiles(id,timezone) values('$otherUser','UTC')")
        sql("insert into devices(id,user_id) values('$otherDevice','$otherUser')")
        ScoringWorkQueue(db).dirtyWorkItem(otherUser,otherDevice,day)
        val other=queue.claim(model)!!;assertEquals(otherUser,other.userId)
        assertTrue(queue.finish(other,output(other,model)))
        sql("update physiology_model_work_items set attempts=4,state='failed' where job_id='${job.jobId}'")
        dirty()
        val fresh=queue.claim(model)!!
        assertEquals(user,fresh.userId);assertTrue(fresh.inputRevision>job.inputRevision)
        assertTrue(queue.finish(fresh,output(fresh,model)))
    }

    @Test fun inputRevisionCancellationAndLeaseTheftFenceStaleOutputs() {
        val old=queue.claim(model)!!;dirty()
        assertFalse(queue.renew(old));assertFalse(queue.finish(old,output(old,model)))
        val current=queue.claim(model)!!
        sql("update physiology_model_work_items set lease_expires_at=clock_timestamp()-interval '1 second' where job_id='${current.jobId}'")
        assertNull(queue.claim(model)) // expired attempt backs off instead of monopolizing the model
        sql("update physiology_model_work_items set next_attempt_at=clock_timestamp()-interval '1 second' where job_id='${current.jobId}'")
        val successor=queue.claim(model)!!
        assertNotEquals(current.leaseToken,successor.leaseToken)
        assertFalse(queue.finish(current,output(current,model)));assertTrue(queue.finish(successor,output(successor,model)))
    }

    @Test fun checkpointActivationAndHistoricalBackfillAreRevisionIsolated() {
        val old=queue.claim(model)!!
        val next=model(model.id,"b".repeat(64));val revision=activate(next)
        assertTrue(revision>old.activationRevision)
        assertNull(queue.claim(model));assertFalse(queue.finish(old,output(old,model)))
        val fresh=queue.claim(next)!!;assertEquals(old.inputRevision,fresh.inputRevision)
        assertEquals(revision,fresh.activationRevision)
        assertEquals(revision,activate(next)) // identical activation cannot accumulate duplicate work
        assertEquals(1L,count("select count(*) from physiology_model_work_items where model_id='${model.id}' and activation_revision=$revision and user_id='$user'"))
        assertTrue(queue.finish(fresh,output(fresh,next)))
    }

    @Test fun ownerDeviceRevisionCheckpointAndCanonicalTamperingCannotPublish() {
        val job=queue.claim(model)!!
        for ((key,value) in listOf("user_id" to UUID.randomUUID().toString(),"device_id" to UUID.randomUUID().toString(),
            "input_revision" to "999999", "checkpoint_sha256" to "c".repeat(64),
            "activation_sha256" to "d".repeat(64),"model_id" to "wrong-model","publication_mode" to "canonical")) {
            denied { queue.finish(job,output(job,model).put(key,value)) }
        }
        denied { queue.finish(job,output(job,model).put("canonical_outputs_allowed",true)) }
        assertEquals(0L,count("select count(*) from physiology_model_results where job_id='${job.jobId}'"))
        assertTrue(queue.finish(job,output(job,model)))
        assertFalse(queue.finish(job,output(job,model)))
    }

    @Test fun operatorCancellationRevokesInFlightAndQueuedWork() {
        val job=queue.claim(model)!!
        sql("select physiology_cancel_model('${model.id}',${job.activationRevision})")
        assertFalse(queue.renew(job));assertFalse(queue.finish(job,output(job,model)));assertNull(queue.claim(model))
        dirty();assertNull(queue.claim(model))
        val restarted=activate(model)
        assertTrue(restarted>job.activationRevision)
        assertNotNull(queue.claim(model))
    }

    @Test fun activationConcurrentWithUncommittedInputIsReconciledBeforeClaim() {
        val candidate=model("queue-test-${UUID.randomUUID()}")
        db.withConnection { input ->
            input.autoCommit=false
            try {
                input.createStatement().use { it.execute("select physiology_enqueue_day('$user','$device','2026-09-18','UTC',0)") }
                activate(candidate)
                val first=queue.claim(candidate)!! // committed older day is visible at activation
                assertTrue(queue.finish(first,output(first,candidate)))
                input.commit()
            } finally { input.rollback();input.autoCommit=true }
        }
        assertEquals(0L,count("select count(*) from physiology_model_work_items where model_id='${candidate.id}' and user_id='$user' and day='2026-09-18'"))
        val recovered=queue.claim(candidate)!!
        assertEquals("2026-09-18",recovered.day)
        assertTrue(queue.finish(recovered,output(recovered,candidate)))
    }

    @Test fun activationIsImmutableAndUnprivilegedReadersCannotConsumeResearchOutput() {
        denied { sql("update physiology_model_activations set checkpoint_sha256=repeat('f',64) where model_id='${model.id}'") }
        db.withConnection { c -> c.createStatement().use { s ->
            s.execute("set role authenticated")
            try { denied { s.executeQuery("select * from physiology_model_results") } }
            finally { s.execute("reset role") }
        } }
    }

    @Test fun shadowReadbackIsOwnerScopedCurrentRevisionAndExplicitlyNonCanonical() {
        val job=queue.claim(model)!!;assertTrue(queue.finish(job,output(job,model)))
        fun read(owner:UUID)=db.withConnection { c -> c.createStatement().use { s ->
            s.execute("select set_config('request.jwt.claim.sub','$owner',false)")
            s.execute("set role authenticated")
            try { s.executeQuery("select physiology_shadow_model_for_day('${model.id}','$day','$device')").use { r ->
                r.next();JSONObject(r.getString(1)) } }
            finally { s.execute("reset role");s.execute("select set_config('request.jwt.claim.sub','',false)") }
        } }
        val result=read(user)
        assertEquals("shadow",result.getString("publication_mode"));assertFalse(result.getBoolean("canonical_outputs_allowed"))
        assertEquals(job.inputRevision.toString(),result.getString("input_revision"));assertFalse(result.isNull("output"))
        denied { read(UUID.randomUUID()) }
        dirty()
        assertTrue(read(user).isNull("output"))
    }

    @Test fun absentAcquisitionProofWaitsWithoutConsumingRetriesAndReceiptArrivalWakesIt() {
        val job=queue.claim(model)!!
        assertTrue(queue.finish(job,failure="verified_model_inputs_waiting"))
        assertNull(queue.claim(model))
        assertEquals(0L,count("select attempts from physiology_model_work_items where job_id='${job.jobId}'"))
        sql("insert into physiology_model_acquisition_contracts(user_id,device_id,input_revision,model_id,checkpoint_sha256,"+
            "preprocess_version,quality_policy_version,scope_start_s,scope_end_s,contract_sha256,contract_bytes) values("+
            "'$user','$device',${job.inputRevision},'${model.id}','${ModelWorkQueue.checkpointHash(model)}','fixture','fixture',0,300,"+
            "encode(extensions.digest(convert_to('{}','UTF8'),'sha256'),'hex'),convert_to('{}','UTF8'))")
        val awakened=queue.claim(model)!!
        assertEquals(job.jobId,awakened.jobId)
        denied { sql("update physiology_model_acquisition_contracts set contract_bytes=convert_to('changed','UTF8') where user_id='$user'") }
    }

    @Test fun noCheckpointReceiptResolvesUsingQueueDigestAndOvernightSizedMasksAreSupported() {
        val candidate = model("neurokit2")
        candidate.activation.getJSONObject("assets").remove("weights")
        candidate.activation.put("preprocess_version", "fixture").put("quality_policy_version", "fixture")
        val request = PhysiologyShadowRunner.Request(user, device, "1", 0, 3600, emptyList())
        // Valid JSON padding models a long observed-mask receipt, not physiological reference evidence.
        val receipt = ("{\"checkpoint_sha256\":\"not_applicable\",\"fixture_padding\":\"" + "x".repeat(1024 * 1024) + "\"}").toByteArray()
        val digest = B2ObjectStore.sha256Hex(receipt)
        db.withConnection { c -> c.prepareStatement("insert into physiology_model_acquisition_contracts(" +
            "user_id,device_id,input_revision,model_id,checkpoint_sha256,preprocess_version,quality_policy_version," +
            "scope_start_s,scope_end_s,contract_sha256,contract_bytes) values(?,?,1,?,?, 'fixture','fixture',0,3600,?,?)").use { s ->
            s.setObject(1,user);s.setObject(2,device);s.setString(3,candidate.id)
            s.setString(4,ModelWorkQueue.checkpointHash(candidate));s.setString(5,digest);s.setBytes(6,receipt)
            s.executeUpdate()
        } }
        val resolver = JdbcAcquisitionContractResolver(db.dataSource)
        val resolved = resolver.resolve(candidate,request)!!
        assertEquals(digest,resolved.sha256);assertArrayEquals(receipt,resolved.bytes)
        assertNull(resolver.resolve(candidate,request.copy(inputRevision="2")))
        assertNull(resolver.resolve(candidate,request.copy(end=3601)))
        assertNull(resolver.resolve(candidate,request.copy(deviceId=UUID.randomUUID())))
    }

    @Test fun blockedDatabaseAssemblyHasWholeAttemptDeadlineAndAnotherUserCanRun() {
        val provider=object:com.frwhoop.scoring.db.ScoreInputProvider {
            override fun loadDay(userId:UUID,day:String,deviceId:UUID):com.frwhoop.scoring.db.SignalSampleReader.DayInputs? {
                db.withConnection { c -> c.createStatement().use { it.execute("select pg_sleep(30)") } }
                return null
            }
        }
        val runner=PhysiologyShadowRunner(models=listOf(model))
        val worker=com.frwhoop.scoring.signals.ModelQueueWorker(queue,provider,runner,model.id,
            maximumAttemptSeconds=1,abortInputs=db::abortActiveConnections)
        val start=System.nanoTime()
        try { worker.processOne();fail("Expected full-attempt deadline") }
        catch(_:com.frwhoop.scoring.signals.ModelQueueWorker.AttemptDeadlineExceeded) {}
        assertTrue((System.nanoTime()-start)/1e9<6)
        assertEquals(1L,count("select count(*) from physiology_model_work_items where model_id='${model.id}' and user_id='$user' and state='retry'"))
        val otherUser=UUID.randomUUID();val otherDevice=UUID.randomUUID()
        sql("insert into auth.users values('$otherUser')")
        sql("insert into profiles(id,timezone) values('$otherUser','UTC')")
        sql("insert into devices(id,user_id) values('$otherDevice','$otherUser')")
        ScoringWorkQueue(db).dirtyWorkItem(otherUser,otherDevice,day)
        assertEquals(otherUser,queue.claim(model)!!.userId)
    }

    private fun model(id:String,checkpoint:String="a".repeat(64))=PhysiologyShadowRunner.Model(id,JSONObject()
        .put("model_id",id).put("publication_mode","shadow").put("canonical_outputs_allowed",false)
        .put("assets",JSONObject().put("weights",JSONObject().put("sha256",checkpoint))),Path.of("."))
    private fun activate(value:PhysiologyShadowRunner.Model):Long {
        val revision=queue.activate(value)
        sql("update physiology_model_work_items set state='cancelled' where model_id='${value.id}' and user_id<>'$user'")
        return revision
    }
    private fun dirty()=ScoringWorkQueue(db).dirtyWorkItem(user,device,day)
    private fun output(item:ModelWorkQueue.Item,value:PhysiologyShadowRunner.Model)=JSONObject()
        .put("model_id",value.id).put("user_id",item.userId).put("device_id",item.deviceId)
        .put("input_revision",item.inputRevision.toString()).put("activation_sha256",ModelWorkQueue.activationHash(value))
        .put("checkpoint_sha256",ModelWorkQueue.checkpointHash(value)).put("publication_mode","shadow")
        .put("canonical_outputs_allowed",false).put("status","abstained").put("reason","synthetic_queue_test")
    private fun sql(value:String)=db.withConnection { c -> c.createStatement().use { it.execute(value) } }
    private fun count(value:String)=db.withConnection { c -> c.createStatement().use { s -> s.executeQuery(value).use { r -> r.next();r.getLong(1) } } }
    private fun denied(action:()->Unit) { try { action();fail("Expected rejection") } catch(_:SQLException) {} }
}
