package com.frwhoop.scoring

import com.frwhoop.scoring.signals.PhysiologyShadowRunner
import com.noop.analytics.PhysiologyQuality
import com.noop.analytics.RespirationEstimator
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Path
import java.time.Duration
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.UUID
import kotlin.math.PI
import kotlin.math.sin

class PhysiologyShadowRunnerTest {
    private val user = UUID.fromString("11111111-1111-1111-1111-111111111111")
    private val device = UUID.fromString("22222222-2222-2222-2222-222222222222")
    private fun request(): PhysiologyShadowRunner.Request {
        var time = 0.0
        val rows = (0 until 400).map { i ->
            val duration = 0.8 + 0.04 * sin(2 * PI * 0.2 * time)
            val start = time; time += duration
            PhysiologyQuality.IntervalObservation("i:$i", user.toString(), device.toString(), source = "synthetic_not_reference",
                eventTime = start, originalRRMs = duration * 1000, startBeatId = "b:$i", endBeatId = "b:${i+1}",
                continuityGroup = "fixture", verifiedSpan = PhysiologyQuality.Span(start, time), timestampPrecisionSeconds = 0.001,
                decoderVersion = "fixture", clockVersion = "fixture")
        }
        return PhysiologyShadowRunner.Request(user, device, "revision-1", 0, 300, rows,
            listOf(PhysiologyShadowRunner.Context(0.0, 300.0, "qualified_sleep")),
            listOf(PhysiologyShadowRunner.ContaminationSpan(0.0, 300.0,
                RespirationEstimator.Contamination(1.0, evidenceVersion = "synthetic-motion-v1"))))
    }

    @Test fun `missing raw does not disable independently verified interval respiration`() {
        val result = PhysiologyShadowRunner().evaluate(request())
        assertEquals(4, result.windows.size)
        assertTrue(result.windows.any { it.breathsPerMinute != null })
        assertNull(result.summaries.single().summary.median)
        assertEquals("insufficient_accepted_duration", result.summaries.single().summary.reason)
        assertEquals(12.0, result.windows.first().breathsPerMinute!!, 0.5)
        assertTrue(result.rawReasons.isEmpty())
        assertTrue(result.modelResults.all { it.getString("reason") == "independent_model_queue" })
        assertEquals(8, result.modelResults.size)
        assertFalse(result.json().getBoolean("canonical_outputs_allowed"))
        assertTrue(result.json().has("respiration_summaries"))
        val encoded=result.json().getJSONArray("respiration_summaries").getJSONObject(0)
        assertEquals(result.summaries.single().summary.distributionBpm,encoded.getJSONArray("distribution_bpm").toList())
        assertEquals("sorted_accepted_window_estimates",encoded.getString("distribution_kind"))
    }

    @Test fun `coarse timing and wrong owner do not produce measurements`() {
        val request = request()
        val coarse = PhysiologyShadowRunner().evaluate(request.copy(intervals = request.intervals.map { it.copy(verifiedSpan = null) }))
        assertTrue(coarse.windows.all { it.breathsPerMinute == null && it.reason == "timing_unverified" })
        assertNull(coarse.summaries.single().summary.median)
        assertEquals(0,coarse.json().getJSONArray("respiration_summaries").getJSONObject(0).getJSONArray("distribution_bpm").length())
        val wrong = PhysiologyShadowRunner().evaluate(request.copy(intervals = request.intervals.map { it.copy(userId = "other") }))
        assertTrue(wrong.windows.all { it.reason == "interval_owner_mismatch" })
    }

    @Test fun `configured job path executes but cannot switch owner or revision`() {
        var calls = 0
        val model = PhysiologyShadowRunner.Model("neurokit2", JSONObject(), Path.of("."))
        val assembler = PhysiologyShadowRunner.JobAssembler { _, request, _ -> PhysiologyShadowRunner.PreparedJob(JSONObject()
            .put("user_id", request.userId).put("device_id", request.deviceId).put("input_revision", request.inputRevision)) }
        val executor = PhysiologyShadowRunner.Executor { selected, job -> calls++; JSONObject().put("model_id", selected.id)
            .put("canonical_outputs_allowed", false).put("publication_mode", "shadow")
            .put("user_id",job.payload.get("user_id")).put("device_id",job.payload.get("device_id"))
            .put("input_revision",job.payload.get("input_revision")) }
        val result = PhysiologyShadowRunner(models = listOf(model), executor = executor, assembler = assembler).evaluateModel(request(), "neurokit2")
        assertEquals(1, calls); assertEquals("neurokit2", result.getString("model_id"))
        val invalid = PhysiologyShadowRunner.JobAssembler { _, _, _ -> PhysiologyShadowRunner.PreparedJob(JSONObject().put("user_id", "other")) }
        val failed = PhysiologyShadowRunner(models = listOf(model), executor = executor, assembler = invalid).evaluateModel(request(), "neurokit2")
        assertEquals(1, calls)
        assertEquals("model_input_owner_or_revision_mismatch", failed.getString("reason"))
    }

    @Test fun `deterministic publication never invokes slow optional model`() {
        val model = PhysiologyShadowRunner.Model("neurokit2", JSONObject(), Path.of("."))
        val assembler = PhysiologyShadowRunner.JobAssembler { _, request, _ -> PhysiologyShadowRunner.PreparedJob(JSONObject()
            .put("user_id", request.userId).put("device_id", request.deviceId).put("input_revision", request.inputRevision)) }
        var calls=0
        val slow = PhysiologyShadowRunner.Executor { _, _ -> calls++; Thread.sleep(5000); JSONObject() }
        val runner = PhysiologyShadowRunner(models=listOf(model),executor=slow,assembler=assembler,totalTimeoutSeconds=1)
        val result = runner.evaluate(request())
        assertEquals(0,calls)
        assertTrue(result.rawReasons.isEmpty())
        assertEquals(12.0,result.windows.first().breathsPerMinute!!,0.5)
        assertNull(result.summaries.single().summary.median)
        assertTrue(result.windows.any { it.breathsPerMinute != null })
    }

    @Test fun `publication budget is independent of configured two minute model lane`() {
        val stopped=CountDownLatch(1)
        val model=PhysiologyShadowRunner.Model("neurokit2",JSONObject(),Path.of("."))
        val assembler=PhysiologyShadowRunner.JobAssembler { _,request,_ -> PhysiologyShadowRunner.PreparedJob(JSONObject()
            .put("user_id",request.userId).put("device_id",request.deviceId).put("input_revision",request.inputRevision)) }
        val slow=PhysiologyShadowRunner.Executor { _,_ ->
            try { Thread.sleep(5000);JSONObject() } finally { stopped.countDown() }
        }
        val runner=PhysiologyShadowRunner(models=listOf(model),executor=slow,assembler=assembler,totalTimeoutSeconds=120)
        val start=System.nanoTime()
        val result=runner.evaluate(request(),Duration.ofMillis(200))
        assertTrue(Duration.ofNanos(System.nanoTime()-start)<Duration.ofSeconds(2))
        assertTrue(result.rawReasons.isEmpty())
        assertEquals(1L,stopped.count)
        assertEquals(12.0,result.windows.first().breathsPerMinute!!,.5)
        assertNull(result.summaries.single().summary.median)
        assertTrue(result.windows.any { it.breathsPerMinute != null })
        assertFalse(result.json().getBoolean("canonical_outputs_allowed"))
    }

    @Test fun `isolated model deadline is an unavailable retryable output`() {
        val model=PhysiologyShadowRunner.Model("neurokit2",JSONObject(),Path.of("."))
        val assembler=PhysiologyShadowRunner.JobAssembler { _,r,_ -> PhysiologyShadowRunner.PreparedJob(JSONObject()
            .put("user_id",r.userId).put("device_id",r.deviceId).put("input_revision",r.inputRevision)) }
        val runner=PhysiologyShadowRunner(models=listOf(model),assembler=assembler,totalTimeoutSeconds=1,
            executor=PhysiologyShadowRunner.Executor { _,_ -> Thread.sleep(5000); JSONObject() })
        val started=System.nanoTime()
        val result=runner.evaluateModel(request(),"neurokit2")
        assertTrue(Duration.ofNanos(System.nanoTime()-started)<Duration.ofSeconds(3))
        assertEquals("abstained",result.getString("status"))
        assertNotNull(com.frwhoop.scoring.signals.ModelQueueWorker.transientFailure(result))
    }

    @Test fun `catalogue outage is retryable instead of terminal missing physiology`() {
        val source=java.lang.reflect.Proxy.newProxyInstance(javax.sql.DataSource::class.java.classLoader,
            arrayOf(javax.sql.DataSource::class.java)) { _,_,_ -> throw java.sql.SQLException("synthetic outage") } as javax.sql.DataSource
        val objects=object:com.frwhoop.scoring.b2.B2ObjectStore.GetClient {
            override fun getObject(key:String,maximumBytes:Int):ByteArray=error("must not fetch")
        }
        val catalogue=com.frwhoop.scoring.signals.RawSignalCatalogue(source,com.frwhoop.scoring.signals.VerifiedRawObjectReader(objects))
        var assembled=0
        val runner=PhysiologyShadowRunner(catalogue=catalogue,
            models=listOf(PhysiologyShadowRunner.Model("neurokit2",JSONObject(),Path.of("."))),
            assembler=PhysiologyShadowRunner.JobAssembler { _,_,_ -> assembled++;null },
            executor=PhysiologyShadowRunner.Executor { _,_ -> error("must not execute") })
        val result=runner.evaluateModel(request(),"neurokit2")
        assertEquals("raw_input_temporarily_unavailable",result.getString("reason"))
        assertNotNull(com.frwhoop.scoring.signals.ModelQueueWorker.transientFailure(result))
        assertEquals(0,assembled)
        assertNotNull(com.frwhoop.scoring.signals.ModelQueueWorker.transientFailure(JSONObject()
            .put("status","abstained").put("reason","shadow_request_cancelled")))
    }

    @Test fun `unrelated corrupt activation cannot block selected model startup`() {
        val directory=java.nio.file.Files.createTempDirectory("model-selection-fixture-")
        val activation=directory.resolve("activation.json");val config=directory.resolve("runner.json")
        try {
            java.nio.file.Files.writeString(activation,JSONObject().put("model_id","neurokit2").toString())
            java.nio.file.Files.writeString(config,JSONObject().put("python","/usr/bin/true").put("python_path","fixture")
                .put("models",org.json.JSONArray().put(JSONObject().put("model_id","neurokit2")
                    .put("activation_file",activation.toString()).put("asset_root",directory.toString()))
                    .put(JSONObject().put("model_id","wav2sleep-cardiorespiratory")
                        .put("activation_file",directory.resolve("absent-corrupt-model.json").toString())
                        .put("asset_root",directory.toString()))).toString())
            val source=java.lang.reflect.Proxy.newProxyInstance(javax.sql.DataSource::class.java.classLoader,
                arrayOf(javax.sql.DataSource::class.java)) { _,_,_ -> error("no database access expected") } as javax.sql.DataSource
            val runner=PhysiologyShadowRunner.fromEnvironment(source,null,
                mapOf("PHYSIOLOGY_SHADOW_CONFIG" to config.toString()),modelId="neurokit2")
            assertEquals(listOf("neurokit2"),runner.configuredModels().map { it.id })
        } finally {
            java.nio.file.Files.deleteIfExists(config);java.nio.file.Files.deleteIfExists(activation)
            java.nio.file.Files.deleteIfExists(directory)
        }
    }

    @Test fun `expired publication budget abstains before starting model work`() {
        var calls=0
        val runner=PhysiologyShadowRunner(executor=PhysiologyShadowRunner.Executor { _,_ -> calls++;JSONObject() })
        for (budget in listOf(Duration.ZERO,Duration.ofMillis(-1))) {
            val result=runner.evaluate(request(),budget)
            assertEquals(listOf("shadow_publication_budget_exhausted"),result.rawReasons)
            assertTrue(result.modelResults.all { it.getString("status")=="abstained" &&
                it.getString("reason")=="shadow_publication_budget_exhausted" })
            assertFalse(result.json().getBoolean("canonical_outputs_allowed"))
        }
        assertEquals(0,calls)
        assertTrue(runner.evaluate(request()).windows.any { it.breathsPerMinute!=null })
    }
    @Test fun `invalid oversized shadow request abstains without failing caller or poisoning slot`() {
        val input=request()
        val runner=PhysiologyShadowRunner()
        val failed=runner.evaluate(input.copy(contexts=List(513) { i ->
            PhysiologyShadowRunner.Context(i*2.0,i*2.0+1,"qualified_sleep") }))
        assertTrue(failed.rawReasons.contains("shadow_input_contract_invalid"))
        assertTrue(failed.modelResults.all { it.getString("reason")=="shadow_input_contract_invalid" })
        assertTrue(runner.evaluate(input).windows.any { it.breathsPerMinute!=null })
    }
    @Test fun `motion gaps aggregate fractions contamination and quality failures cannot certify windows`() {
        val original = request()
        val runner = PhysiologyShadowRunner()
        for (spans in listOf(emptyList(), listOf(PhysiologyShadowRunner.ContaminationSpan(0.0, 300.0,
            RespirationEstimator.Contamination(.99, evidenceVersion = "aggregate_only"))))) {
            val output = runner.evaluate(original.copy(respirationContamination = spans))
            assertTrue(output.windows.all { it.reason == "motion_evidence_unavailable" && it.breathsPerMinute == null })
        }
        val moving = original.respirationContamination + PhysiologyShadowRunner.ContaminationSpan(50.0, 51.0,
            RespirationEstimator.Contamination(1.0, true, evidenceVersion = "synthetic-motion-v1"))
        val rejected = runner.evaluate(original.copy(respirationContamination = moving))
        assertEquals("motion_contamination", rejected.windows.first().reason)
        assertTrue(rejected.windows.drop(1).all { it.breathsPerMinute != null })
        val quality = original.respirationContamination + PhysiologyShadowRunner.ContaminationSpan(50.0, 51.0,
            RespirationEstimator.Contamination(signalQualityReasons = listOf("off_body"), evidenceVersion = "wear-event"))
        val qualityResult = runner.evaluate(original.copy(respirationContamination = quality))
        assertEquals("signal_quality_contamination", qualityResult.windows.first().reason)
        assertTrue("off_body" in qualityResult.windows.first().rejectionReasons)
        val duplicate = runner.evaluate(original.copy(respirationContamination = original.respirationContamination + original.respirationContamination))
        assertTrue(duplicate.windows.all { it.motionObservedFraction == 1.0 })
    }
}
