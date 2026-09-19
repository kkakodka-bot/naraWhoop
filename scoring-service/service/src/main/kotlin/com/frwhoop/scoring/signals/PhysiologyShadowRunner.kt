package com.frwhoop.scoring.signals

import com.noop.analytics.PhysiologyQuality
import com.noop.analytics.RespirationEstimator
import org.json.JSONArray
import org.json.JSONObject
import java.nio.file.Files
import java.nio.file.Path
import java.time.Duration
import java.util.UUID
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicReference
import javax.sql.DataSource
import com.frwhoop.scoring.b2.B2ObjectStore

/** Independent shadow lane. No output from this class is eligible for canonical physiology promotion. */
class PhysiologyShadowRunner(
    private val catalogue: RawSignalCatalogue? = null,
    private val models: List<Model> = emptyList(),
    private val executor: Executor? = null,
    private val assembler: JobAssembler? = null,
    private val totalTimeoutSeconds: Long = 60,
) {
    private val requestSlot = Semaphore(1)
    init { require(totalTimeoutSeconds in 1..120) }
    data class Context(val start: Double, val end: Double, val kind: String)
    data class ContaminationSpan(val start: Double, val end: Double, val contamination: RespirationEstimator.Contamination)
    data class Request(val userId: UUID, val deviceId: UUID, val inputRevision: String,
                       val start: Long, val end: Long, val intervals: List<PhysiologyQuality.IntervalObservation>,
                       val contexts: List<Context> = emptyList(),
                       val respirationContamination: List<ContaminationSpan> = emptyList())
    data class Model(val id: String, val activation: JSONObject, val assetRoot: Path)
    data class PreparedJob(val payload: JSONObject)
    fun interface Executor { fun run(model: Model, job: PreparedJob): JSONObject }
    /** A configured, versioned acquisition adapter must provide timing/channel proof; NPB1 alone cannot. */
    fun interface JobAssembler { fun prepare(model: Model, request: Request, raw: List<VerifiedRawObjectReader.Decoded>): PreparedJob? }
    data class ContextSummary(val start: Double, val end: Double, val summary: RespirationEstimator.Summary)
    data class Result(val windows: List<RespirationEstimator.Result>, val summaries: List<ContextSummary>,
                      val modelResults: List<JSONObject>, val rawReasons: List<String>, val verifiedObjects: Int) {
        fun json(): JSONObject = JSONObject().put("publication_mode", "shadow").put("canonical_outputs_allowed", false)
            .put("method_version", RespirationEstimator.VERSION).put("preprocess_version", RespirationEstimator.PREPROCESS_VERSION)
            .put("calibration_status", "not_reference_validated").put("verified_raw_objects", verifiedObjects)
            .put("raw_unavailable_reasons", JSONArray(rawReasons)).put("models", JSONArray(modelResults))
            .put("respiration_windows", JSONArray(windows.map { w -> JSONObject()
                .put("start", w.start).put("end", w.end).put("source", w.source).put("modality", w.modality)
                .put("input_revision", w.inputRevision).put("breaths_per_minute", w.breathsPerMinute ?: JSONObject.NULL)
                .put("reason", w.reason ?: JSONObject.NULL).put("observed_time_fraction", w.observedTimeFraction)
                .put("maximum_gap_seconds", w.maximumGapSeconds).put("spectral_rate", w.spectralRate ?: JSONObject.NULL)
                .put("autocorrelation_rate", w.autocorrelationRate ?: JSONObject.NULL)
                .put("spectral_fraction", w.spectralFraction ?: JSONObject.NULL).put("autocorrelation", w.autocorrelation ?: JSONObject.NULL)
                .put("effective_cycles", w.effectiveCycles ?: JSONObject.NULL).put("supported_min_bpm", w.minimumRate)
                .put("supported_max_bpm", w.maximumRate).put("method_version", w.methodVersion)
                .put("quality_policy_version", w.qualityPolicyVersion).put("quality_evidence_version", w.qualityEvidenceVersion)
                .put("motion_observed_fraction", w.motionObservedFraction ?: JSONObject.NULL)
                .put("rejection_reasons", JSONArray(w.rejectionReasons))
                .put("acquisition_identity", JSONArray(w.acquisitionIdentity))
                .put("preprocess_version", w.preprocessVersion).put("computation_mode", w.computationMode) }))
            .put("respiration_summaries", JSONArray(summaries.map { s -> JSONObject().put("start", s.start).put("end", s.end)
                .put("context", s.summary.context).put("median_bpm", s.summary.median ?: JSONObject.NULL)
                .put("mean_bpm", s.summary.mean ?: JSONObject.NULL).put("accepted_seconds", s.summary.acceptedSeconds)
                .put("distribution_bpm", JSONArray(s.summary.distributionBpm))
                .put("distribution_kind", "sorted_accepted_window_estimates")
                .put("coverage", s.summary.coverage).put("accepted_windows", s.summary.acceptedWindows)
                .put("reason", s.summary.reason ?: JSONObject.NULL).put("coverage_by_third", JSONArray(s.summary.coverageByThird))
                .put("rejection_reasons", JSONArray(s.summary.rejectionReasons)).put("quality_policy_version", s.summary.qualityPolicyVersion)
                .put("evidence_strength", s.summary.evidenceStrength ?: JSONObject.NULL)
                .put("evidence_strength_kind", "minimum_window_autocorrelation_not_calibrated_probability")
                .put("total_windows", s.summary.totalWindows) }))
    }

    /** Deterministic measurements never discover objects, prepare jobs, or invoke optional models. */
    fun evaluate(request: Request, remainingBudget: Duration? = null): Result = evaluateRequest(request, remainingBudget, false)

    fun configuredModels(): List<Model> = models.toList()

    /** Called only by an independently leased per-model worker. */
    fun evaluateModel(request: Request, modelId: String): JSONObject {
        val model = models.single { it.id == modelId }
        val isolated = PhysiologyShadowRunner(catalogue, listOf(model), executor, assembler, totalTimeoutSeconds)
        val result = isolated.evaluateRequest(request.copy(contexts = emptyList(), respirationContamination = emptyList()), null, true)
        return result.modelResults.single { it.getString("model_id") == modelId }
    }

    private fun evaluateRequest(request: Request, remainingBudget: Duration?, includeModels: Boolean): Result {
        fun unavailable(reason: String) = Result(emptyList(), emptyList(), MODEL_IDS.map { id -> JSONObject()
            .put("model_id", id).put("publication_mode", "shadow").put("canonical_outputs_allowed", false)
            .put("status", "abstained").put("reason", reason).put("user_id", request.userId)
            .put("device_id", request.deviceId).put("input_revision", request.inputRevision) }, listOf(reason), 0)
        val configured = Duration.ofSeconds(totalTimeoutSeconds)
        val allowed = remainingBudget?.let { if (it < configured) it else configured } ?: configured
        if (allowed.isNegative || allowed.isZero) return unavailable("shadow_publication_budget_exhausted")
        if (!requestSlot.tryAcquire()) return unavailable("shadow_request_busy")
        val deadline = System.nanoTime() + allowed.toNanos()
        val progress = AtomicReference(unavailable("shadow_request_pending"))
        val work = FutureTask { evaluateBounded(request,deadline,includeModels) { progress.set(it) } }
        val thread = Thread({ try { work.run() } finally { requestSlot.release() } }, "physiology-shadow-bounded")
        thread.isDaemon = true
        try {
            thread.start()
            return work.get((deadline-System.nanoTime()).coerceAtLeast(1), TimeUnit.NANOSECONDS)
        } catch (_: TimeoutException) {
            work.cancel(true)
            val partial = progress.get()
            return partial.copy(rawReasons = (partial.rawReasons + "shadow_request_timeout").distinct())
        } catch (_: InterruptedException) {
            work.cancel(true); Thread.currentThread().interrupt(); return unavailable("shadow_request_cancelled")
        } catch (error: java.util.concurrent.ExecutionException) {
            if (error.cause is InterruptedException && System.nanoTime() >= deadline) {
                val partial=progress.get()
                return partial.copy(rawReasons=(partial.rawReasons+"shadow_request_timeout").distinct())
            }
            val reason=if(error.cause is IllegalArgumentException) "shadow_input_contract_invalid" else "shadow_execution_failed"
            val partial=progress.get()
            return partial.copy(rawReasons=(partial.rawReasons+reason).distinct(),
                modelResults=unavailable(reason).modelResults)
        }
    }

    private fun evaluateBounded(request: Request, deadline: Long, includeModels: Boolean, onProgress: (Result) -> Unit): Result {
        require(request.end > request.start && request.end - request.start <= 76 * 3600 && request.inputRevision.isNotBlank())
        require(request.intervals.size <= 300_000 && request.contexts.size <= 512 && models.size <= 8 &&
            request.respirationContamination.size <= 300_000)
        require(request.respirationContamination.all { it.start.isFinite() && it.end.isFinite() && it.end > it.start &&
            it.start >= request.start && it.end <= request.end })
        fun checkCancellation() {
            if (Thread.currentThread().isInterrupted || System.nanoTime() >= deadline) throw InterruptedException("shadow_cancelled")
        }
        val contexts = request.contexts.sortedBy { it.start }
        require(contexts.all { it.start.isFinite() && it.end.isFinite() && it.start >= request.start && it.end <= request.end &&
            it.end > it.start && it.kind in setOf("qualified_sleep", "qualified_awake_rest") })
        require(contexts.zipWithNext().all { (a,b) -> a.end <= b.start })
        val windows = mutableListOf<RespirationEstimator.Result>()
        val summaries = mutableListOf<ContextSummary>()
        val ownerValid = request.intervals.all { it.userId == request.userId.toString() && it.deviceId == request.deviceId.toString() }
        for (context in contexts) {
            val local = mutableListOf<RespirationEstimator.Result>()
            var start = context.start
            while (start + 120 <= context.end && windows.size < 512) {
                checkCancellation()
                val end = start + 120
                val rows = if (ownerValid) request.intervals.filter { row -> row.verifiedSpan
                    ?.takeIf { it.start.isFinite() && it.end.isFinite() && it.end > it.start }
                    ?.let { it.end >= start - 2 && it.start <= end + 2 }
                    ?: (!row.eventTime.isFinite() || (row.eventTime >= start - 2 && row.eventTime <= end + 2)) } else emptyList()
                val evidence = request.respirationContamination.filter { it.end > start && it.start < end }
                val observed = evidence.filter { it.contamination.motionObservedFraction == 1.0 &&
                    it.contamination.evidenceVersion.isNotBlank() && it.contamination.evidenceVersion != "unverified" }
                    .map { PhysiologyQuality.Span(it.start, it.end) }
                var through = start
                var seconds = 0.0
                for (span in observed.sortedBy { it.start }) {
                    val lo = maxOf(start, through, span.start)
                    val hi = minOf(end, span.end)
                    if (hi > lo) { seconds += hi - lo; through = hi }
                }
                val contamination = RespirationEstimator.Contamination(seconds / 120,
                    evidence.any { it.contamination.motionContaminated },
                    evidence.flatMap { it.contamination.signalQualityReasons }.distinct().sorted(),
                    evidence.map { it.contamination.evidenceVersion }.distinct().sorted().joinToString("+").ifBlank { "unverified" })
                val output = RespirationEstimator.estimate(RespirationEstimator.fromIntervals(start, 120, rows,
                    request.inputRevision, contamination))
                val result = if (ownerValid) output else output.copy(reason = "interval_owner_mismatch", breathsPerMinute = null)
                windows += result; local += result; start += 60
            }
            summaries += ContextSummary(context.start, context.end, RespirationEstimator.summarize(local, context.start, context.end, context.kind))
        }
        val waitingModels = MODEL_IDS.map { id -> JSONObject().put("model_id", id).put("publication_mode", "shadow")
            .put("canonical_outputs_allowed", false).put("status", "abstained")
            .put("reason", if (includeModels) "shadow_deadline_before_models" else "independent_model_queue")
            .put("user_id", request.userId).put("device_id", request.deviceId).put("input_revision", request.inputRevision) }
        onProgress(Result(windows.toList(), summaries.toList(), waitingModels, emptyList(), 0))
        if (!includeModels) return Result(windows, summaries, waitingModels,
            if (windows.size >= 512) listOf("respiration_window_budget_reached") else emptyList(), 0)
        val rawReasons = mutableListOf<String>(); val decoded = mutableListOf<VerifiedRawObjectReader.Decoded>()
        if (contexts.isEmpty()) rawReasons += "no_qualified_respiration_context"
        if (catalogue == null) rawReasons += "raw_object_reader_not_configured" else {
            try {
                val manifests = catalogue.discover(request.userId, request.deviceId, request.start, request.end)
                if (manifests.isEmpty()) rawReasons += "raw_objects_unavailable"
                var bytes = 0L
                for (manifest in manifests) {
                    checkCancellation()
                    if (decoded.size >= 8 || bytes + manifest.uncompressedBytes > 64L * 1024 * 1024) {
                        rawReasons += "raw_verification_budget_exceeded"; break
                    }
                    bytes += manifest.uncompressedBytes
                    try { decoded += catalogue.verify(manifest) }
                    catch (interrupted: InterruptedException) { throw interrupted }
                    catch (_: Exception) { rawReasons += "raw_object_verification_failed" }
                }
                rawReasons += decoded.map { it.unavailableReason }
            } catch (interrupted: InterruptedException) { throw interrupted }
            catch (_: Exception) { rawReasons += "raw_catalogue_unavailable" }
        }
        onProgress(Result(windows.toList(), summaries.toList(), waitingModels, rawReasons.distinct(), decoded.size))
        val configured = models.associateBy { it.id }
        val outputs = models.map { it.id }.map { id ->
            checkCancellation()
            val model = configured[id]
            var reason = when {
                model == null -> "model_not_configured"
                executor == null -> "bounded_runtime_not_configured"
                assembler == null -> "verified_model_input_adapter_not_configured"
                rawReasons.any { it in setOf("raw_object_verification_failed", "raw_catalogue_unavailable") } -> "raw_input_temporarily_unavailable"
                else -> null
            }
            if (reason == null && model != null) {
                try {
                    val job = assembler!!.prepare(model, request, decoded)
                    if (job == null) reason = "required_verified_model_inputs_unavailable" else {
                        val payload = job.payload
                        if (payload.optString("user_id") != request.userId.toString() || payload.optString("device_id") != request.deviceId.toString() ||
                            payload.optString("input_revision") != request.inputRevision) reason = "model_input_owner_or_revision_mismatch"
                        else {
                            val output = executor!!.run(model, job)
                            if (output.optString("publication_mode") != "shadow" || output.opt("canonical_outputs_allowed") != false ||
                                output.optString("model_id") != id || listOf("user_id", "device_id", "input_revision").any { output.optString(it) != payload.optString(it) })
                                reason = "model_output_contract_invalid"
                            else return@map output
                        }
                    }
                } catch (_: Exception) { reason = "model_input_or_execution_failed" }
            }
            JSONObject().put("model_id", id).put("publication_mode", "shadow").put("canonical_outputs_allowed", false)
                .put("user_id", request.userId).put("device_id", request.deviceId).put("input_revision", request.inputRevision)
                .put("status", "abstained").put("reason", reason).put("output", JSONObject.NULL)
        }
        if (windows.size >= 512) rawReasons += "respiration_window_budget_reached"
        return Result(windows, summaries, outputs, rawReasons.distinct(), decoded.size)
    }

    companion object {
        val MODEL_IDS = listOf("wav2sleep-cardiorespiratory", "rr-estimation", "neurokit2", "feature-sleep-learner",
            "sleepecg", "walch-sleep-classifiers", "rrest", "correncoder")

        /** No configuration means no external model loading. Unknown WHOOP waveform proof stays unavailable. */
        fun fromEnvironment(dataSource: DataSource, objects: B2ObjectStore.GetClient?,
                            environment: Map<String, String> = System.getenv(), assembler: JobAssembler? = null,
                            modelId: String? = null): PhysiologyShadowRunner {
            require(modelId == null || modelId in MODEL_IDS)
            val catalogue = objects?.let { RawSignalCatalogue(dataSource, VerifiedRawObjectReader(it)) }
            val configPath = environment["PHYSIOLOGY_SHADOW_CONFIG"]?.takeIf { it.isNotBlank() }
                ?: return PhysiologyShadowRunner(catalogue = catalogue, assembler = assembler)
            val path = Path.of(configPath).toAbsolutePath()
            require(Files.size(path) <= 1024 * 1024) { "shadow_config_size_limit" }
            val config = JSONObject(Files.readString(path))
            val specifications = config.getJSONArray("models")
            require(specifications.length() <= 8)
            val selected = (0 until specifications.length()).map { specifications.getJSONObject(it) }
                .filter { modelId == null || it.optString("model_id") == modelId }
            val models = selected.map { specification ->
                val id = specification.getString("model_id"); require(id in MODEL_IDS)
                val activationPath = Path.of(specification.getString("activation_file")); require(Files.size(activationPath) <= 1024 * 1024)
                Model(id, JSONObject(Files.readString(activationPath)), Path.of(specification.getString("asset_root")))
            }
            require(models.map { it.id }.distinct().size == models.size)
            return PhysiologyShadowRunner(catalogue, models,
                PythonShadowExecutor(Path.of(config.getString("python")), config.getString("python_path"), config.optLong("model_timeout_seconds", 35)),
                assembler, config.optLong("total_timeout_seconds", 60))
        }
    }
}

/** Fixed operator configuration, one child, bounded files/time, credential-stripped environment. */
class PythonShadowExecutor(private val python: Path, private val pythonPath: String, private val timeoutSeconds: Long = 35) : PhysiologyShadowRunner.Executor {
    private val slot = Semaphore(1)
    init { require(Files.isExecutable(python) && timeoutSeconds in 2..305 && pythonPath.isNotBlank()) }
    override fun run(model: PhysiologyShadowRunner.Model, job: PhysiologyShadowRunner.PreparedJob): JSONObject {
        fun abstain(reason: String) = JSONObject().put("model_id", model.id).put("publication_mode", "shadow")
            .put("canonical_outputs_allowed", false).put("status", "abstained").put("reason", reason)
            .put("user_id", job.payload.optString("user_id")).put("device_id", job.payload.optString("device_id"))
            .put("input_revision", job.payload.optString("input_revision")).put("input_hash", job.payload.optString("input_hash"))
        if (!slot.tryAcquire()) return abstain("inference_busy")
        var requestFile: Path? = null; var outputFile: Path? = null; var child: Process? = null
        try {
            requestFile = Files.createTempFile("physiology-input-", ".json")
            outputFile = Files.createTempFile("physiology-output-", ".json")
            val request = JSONObject().put("model_id", model.id).put("job", job.payload).put("activation", model.activation)
                .put("asset_root", model.assetRoot.toAbsolutePath().toString()).put("limits", JSONObject().put("timeout_seconds", timeoutSeconds - 1))
                .toString().toByteArray(Charsets.UTF_8)
            if (request.size > 16 * 1024 * 1024) return abstain("inference_input_limit")
            Files.write(requestFile, request)
            val builder = ProcessBuilder(python.toString(), "-m", "physiology_inference.service")
                .redirectInput(requestFile.toFile()).redirectOutput(outputFile.toFile()).redirectError(ProcessBuilder.Redirect.DISCARD)
            val environment = builder.environment(); val path = environment["PATH"]; val temporary = environment["TMPDIR"]
            environment.clear(); if (path != null) environment["PATH"] = path; if (temporary != null) environment["TMPDIR"] = temporary
            environment["PYTHONPATH"] = pythonPath; environment["PYTHONHASHSEED"] = "55"
            child = builder.start()
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(timeoutSeconds)
            while (!child.waitFor(50, TimeUnit.MILLISECONDS)) {
                if (Files.size(outputFile) > 4 * 1024 * 1024) return abstain("inference_output_limit")
                if (System.nanoTime() >= deadline) return abstain("inference_timeout")
            }
            if (child.exitValue() != 0) return abstain("inference_worker_failed")
            if (Files.size(outputFile) > 4 * 1024 * 1024) return abstain("inference_output_limit")
            val result = JSONObject(Files.readString(outputFile))
            if (result.optString("publication_mode") != "shadow" || result.opt("canonical_outputs_allowed") != false || result.optString("model_id") != model.id ||
                listOf("user_id", "device_id", "input_revision", "input_hash").any { result.optString(it) != job.payload.optString(it) })
                return abstain("inference_output_contract_invalid")
            return result
        } catch (_: InterruptedException) { Thread.currentThread().interrupt(); return abstain("inference_cancelled") }
        catch (_: Exception) { return abstain("inference_request_failed") }
        finally {
            try {
                child?.let { process -> if (process.isAlive) {
                    process.descendants().forEach { it.destroyForcibly() }; process.destroyForcibly()
                } }
                requestFile?.let { Files.deleteIfExists(it) }; outputFile?.let { Files.deleteIfExists(it) }
            } finally { slot.release() }
        }
    }
}
