package com.frwhoop.scoring

import com.frwhoop.scoring.signals.PhysiologyShadowRunner
import com.noop.analytics.PhysiologyQuality
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.lang.reflect.Proxy
import java.nio.file.Files
import java.nio.file.Path
import java.time.Duration
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.UUID
import javax.sql.DataSource
import kotlin.math.PI
import kotlin.math.sin

class PhysiologyShadowRunnerTest {
    private val user = UUID.fromString("11111111-1111-1111-1111-111111111111")
    private val device = UUID.fromString("22222222-2222-2222-2222-222222222222")
    private val unusedDataSource = Proxy.newProxyInstance(DataSource::class.java.classLoader,
        arrayOf(DataSource::class.java)) { _, _, _ -> error("Unexpected database access in configuration test") } as DataSource

    private fun configuredRunner(path: Path) = PhysiologyShadowRunner.fromEnvironment(unusedDataSource, null,
        mapOf("PHYSIOLOGY_SHADOW_CONFIG" to path.toString()))

    private fun assertConfigurationFailureIsIsolated(path: Path) {
        val input = request()
        val runner = configuredRunner(path)
        repeat(2) {
            val result = runner.evaluate(input)
            assertEquals(12.0, result.summaries.single().summary.median!!, 0.5)
            assertTrue(result.windows.any { it.breathsPerMinute != null })
            assertTrue(result.rawReasons.contains("shadow_configuration_unavailable"))
            assertEquals(8, result.modelResults.size)
            assertTrue(result.modelResults.map { JSONObject(it.toString()) }.all { model -> model.getString("status") == "abstained" &&
                model.getString("reason") == "shadow_configuration_unavailable" &&
                !model.getBoolean("canonical_outputs_allowed") && model.getString("publication_mode") == "shadow" &&
                model.getString("user_id") == input.userId.toString() &&
                model.getString("device_id") == input.deviceId.toString() &&
                model.getString("input_revision") == input.inputRevision })
            val serialized = result.json().toString()
            assertFalse(serialized.contains(path.parent.toString()))
            assertFalse(serialized.contains("private-configuration-marker"))
        }
    }

    private fun shadowConfig(directory: Path, activation: Path, python: Path = Path.of(System.getProperty("java.home"), "bin", "java")): Path {
        val config = JSONObject().put("python", python.toString()).put("python_path", directory.toString())
            .put("models", org.json.JSONArray().put(JSONObject().put("model_id", "neurokit2")
                .put("activation_file", activation.toString()).put("asset_root", directory.toString())))
        return Files.writeString(directory.resolve("shadow.json"), config.toString())
    }

    @Test fun `missing optional configuration preserves repeated interval respiration`() {
        val directory = Files.createTempDirectory("shadow-startup-")
        try { assertConfigurationFailureIsIsolated(directory.resolve("missing.json")) }
        finally { directory.toFile().deleteRecursively() }
    }

    @Test fun `malformed optional configuration is unavailable without leaking contents`() {
        val directory = Files.createTempDirectory("shadow-startup-")
        try {
            val config = Files.writeString(directory.resolve("shadow.json"), "private-configuration-marker")
            assertConfigurationFailureIsIsolated(config)
        } finally { directory.toFile().deleteRecursively() }
    }

    @Test fun `missing and malformed activations preserve interval respiration`() {
        val directory = Files.createTempDirectory("shadow-startup-")
        try {
            val activation = directory.resolve("activation.json")
            val config = shadowConfig(directory, activation)
            assertConfigurationFailureIsIsolated(config)
            Files.writeString(activation, "private-configuration-marker")
            assertConfigurationFailureIsIsolated(config)
        } finally { directory.toFile().deleteRecursively() }
    }

    @Test fun `unavailable python cannot prevent canonical worker construction`() {
        val directory = Files.createTempDirectory("shadow-startup-")
        try {
            val activation = Files.writeString(directory.resolve("activation.json"), "{}")
            assertConfigurationFailureIsIsolated(shadowConfig(directory, activation, directory.resolve("missing-python")))
        } finally { directory.toFile().deleteRecursively() }
    }

    @Test fun `valid configuration remains gated on verified model input adapter`() {
        val directory = Files.createTempDirectory("shadow-startup-")
        try {
            val activation = Files.writeString(directory.resolve("activation.json"), "{}")
            val result = configuredRunner(shadowConfig(directory, activation)).evaluate(request())
            assertEquals(12.0, result.summaries.single().summary.median!!, 0.5)
            assertFalse(result.rawReasons.contains("shadow_configuration_unavailable"))
            val model = result.modelResults.single { it.getString("model_id") == "neurokit2" }
            assertEquals("verified_model_input_adapter_not_configured", model.getString("reason"))
            assertFalse(model.getBoolean("canonical_outputs_allowed"))
        } finally { directory.toFile().deleteRecursively() }
    }

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
            listOf(PhysiologyShadowRunner.Context(0.0, 300.0, "qualified_sleep")))
    }

    @Test fun `missing raw does not disable independently verified interval respiration`() {
        val result = PhysiologyShadowRunner().evaluate(request())
        assertEquals(4, result.windows.size)
        assertTrue(result.windows.any { it.breathsPerMinute != null })
        assertEquals(12.0, result.summaries.single().summary.median!!, 0.5)
        assertTrue(result.rawReasons.contains("raw_object_reader_not_configured"))
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
        val result = PhysiologyShadowRunner(models = listOf(model), executor = executor, assembler = assembler).evaluate(request())
        assertEquals(1, calls); assertEquals(8, result.modelResults.size)
        val invalid = PhysiologyShadowRunner.JobAssembler { _, _, _ -> PhysiologyShadowRunner.PreparedJob(JSONObject().put("user_id", "other")) }
        val failed = PhysiologyShadowRunner(models = listOf(model), executor = executor, assembler = invalid).evaluate(request())
        assertEquals(1, calls)
        assertEquals("model_input_owner_or_revision_mismatch", failed.modelResults.first { it.getString("model_id") == "neurokit2" }.getString("reason"))
    }

    @Test fun `total deadline preserves deterministic respiration and interrupts model`() {
        val model = PhysiologyShadowRunner.Model("neurokit2", JSONObject(), Path.of("."))
        val assembler = PhysiologyShadowRunner.JobAssembler { _, request, _ -> PhysiologyShadowRunner.PreparedJob(JSONObject()
            .put("user_id", request.userId).put("device_id", request.deviceId).put("input_revision", request.inputRevision)) }
        val slow = PhysiologyShadowRunner.Executor { _, _ -> Thread.sleep(5000); JSONObject() }
        val runner = PhysiologyShadowRunner(models=listOf(model),executor=slow,assembler=assembler,totalTimeoutSeconds=1)
        val result = runner.evaluate(request())
        assertTrue(result.rawReasons.contains("shadow_request_timeout"))
        assertEquals(12.0,result.summaries.single().summary.median!!,0.5)
        assertTrue(result.windows.any { it.breathsPerMinute != null })
    }

    @Test fun `remaining publication budget bounds a configured two minute model lane`() {
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
        assertTrue(result.rawReasons.contains("shadow_request_timeout"))
        assertTrue(stopped.await(1,TimeUnit.SECONDS))
        assertEquals(12.0,result.summaries.single().summary.median!!,.5)
        assertTrue(result.windows.any { it.breathsPerMinute != null })
        assertFalse(result.json().getBoolean("canonical_outputs_allowed"))
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

    @Test fun `bounded respiration attempts are shared across qualified contexts`() {
        val input=request().copy(
            start=0,
            end=75_000,
            intervals=emptyList(),
            contexts=listOf(
                PhysiologyShadowRunner.Context(0.0,37_000.0,"qualified_sleep"),
                PhysiologyShadowRunner.Context(38_000.0,75_000.0,"qualified_awake_rest"),
            ),
        )
        val result=PhysiologyShadowRunner().evaluate(input)
        assertEquals(512,result.windows.size)
        assertEquals(2,result.summaries.size)
        assertEquals(256,result.summaries[0].summary.totalWindows)
        assertEquals(256,result.summaries[1].summary.totalWindows)
        assertTrue(result.rawReasons.contains("respiration_window_budget_reached"))
    }

    @Test fun `bounded respiration samples a long sleep across its full span despite fragmented awake rest`() {
        val sleep = PhysiologyShadowRunner.Context(0.0, 36_000.0, "qualified_sleep")
        val awake = (0 until 100).map { index ->
            val start = 36_000.0 + index * 300.0
            PhysiologyShadowRunner.Context(start, start + 300.0, "qualified_awake_rest")
        }
        val input=request().copy(start=0,end=66_000,intervals=emptyList(),contexts=listOf(sleep)+awake)
        val result=PhysiologyShadowRunner().evaluate(input)
        assertEquals(512,result.windows.size)
        assertTrue(result.rawReasons.contains("respiration_window_budget_reached"))
        assertEquals(101,result.summaries.size)
        val sleepStarts=result.windows.filter { it.start < sleep.end }.map { it.start }
        assertTrue(sleepStarts.size in 300..315)
        assertTrue(sleepStarts.minOrNull()!! < 120)
        assertTrue(sleepStarts.maxOrNull()!! > sleep.end - 240)
    }

    @Test fun `maximum fragmented context count cannot consume the long sleep budget`() {
        val sleep = PhysiologyShadowRunner.Context(0.0, 36_000.0, "qualified_sleep")
        val awake = (0 until 511).map { index ->
            val start = 36_000.0 + index * 300.0
            PhysiologyShadowRunner.Context(start, start + 300.0, "qualified_awake_rest")
        }
        val input=request().copy(start=0,end=189_300,intervals=emptyList(),contexts=listOf(sleep)+awake)
        val result=PhysiologyShadowRunner().evaluate(input)
        assertEquals(512,result.windows.size)
        assertEquals(512,result.summaries.size)
        val sleepStarts=result.windows.filter { it.start < sleep.end }.map { it.start }
        // Sleep contributes 599 of 2,643 opportunities, so equal-weight sampling should retain
        // about 116 attempts and cover the night rather than reducing it to one midpoint.
        assertTrue(sleepStarts.size in 110..122)
        assertTrue(sleepStarts.minOrNull()!! < 240)
        assertTrue(sleepStarts.maxOrNull()!! > sleep.end - 300)
    }

    @Test fun `respiration candidate sets below the budget remain exhaustive`() {
        val input=request().copy(start=0,end=600,intervals=emptyList(),
            contexts=listOf(PhysiologyShadowRunner.Context(0.0,600.0,"qualified_sleep")))
        val result=PhysiologyShadowRunner().evaluate(input)
        assertEquals((0..480 step 60).map(Int::toDouble),result.windows.map { it.start })
        assertFalse(result.rawReasons.contains("respiration_window_budget_reached"))
    }
}
