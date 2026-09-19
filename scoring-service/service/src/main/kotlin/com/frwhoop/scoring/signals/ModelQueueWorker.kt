package com.frwhoop.scoring.signals

import com.frwhoop.scoring.db.ScoreInputProvider
import org.json.JSONObject
import org.slf4j.LoggerFactory
import java.time.Duration
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** One separately resource-limited process per model; no deterministic publication dependency. */
class ModelQueueWorker(private val queue: ModelWorkQueue, private val inputs: ScoreInputProvider,
                       private val runner: PhysiologyShadowRunner, modelId: String,
                       private val maximumAttemptSeconds: Long = 180,
                       private val abortInputs: () -> Unit = {}) {
    init { require(maximumAttemptSeconds in 1..300) }
    class AttemptDeadlineExceeded : RuntimeException("model_attempt_deadline_exceeded")
    private val model = runner.configuredModels().single { it.id == modelId }
    private val log = LoggerFactory.getLogger(ModelQueueWorker::class.java)

    fun runForever(pollInterval: Duration) {
        while (!Thread.currentThread().isInterrupted) {
            val worked = try { processOne() } catch (error: Exception) {
                if (error is AttemptDeadlineExceeded) throw error
                log.warn("Model queue unavailable: {}", error.javaClass.simpleName); false
            }
            if (!worked) Thread.sleep(pollInterval.toMillis())
        }
    }

    fun processOne(): Boolean {
        val item = queue.claim(model) ?: return false
        val lost = AtomicBoolean(false)
        val deadlineExceeded = AtomicBoolean(false)
        val ownerThread = Thread.currentThread()
        val renewal = Executors.newSingleThreadScheduledExecutor { task -> Thread(task, "model-lease").apply { isDaemon = true } }
        val interval = (queue.leaseSeconds / 3).coerceAtLeast(1).toLong()
        renewal.schedule({
            deadlineExceeded.set(true); lost.set(true)
            runCatching { abortInputs() }
            ownerThread.interrupt()
        }, maximumAttemptSeconds, TimeUnit.SECONDS)
        renewal.scheduleAtFixedRate({
            if (!deadlineExceeded.get() && !runCatching { queue.renew(item) }.getOrDefault(false)) {
                lost.set(true); ownerThread.interrupt()
            }
        }, interval, interval, TimeUnit.SECONDS)
        try {
            val day = inputs.loadDay(item.userId, item.day, item.deviceId, item.timezoneId)
            val request = if (day == null) null else PhysiologyShadowRunner.Request(item.userId, item.deviceId,
                item.inputRevision.toString(), day.nightLo, day.nightHi + 1, day.hrvObservations.orEmpty())
            val output = if (request == null) JSONObject().put("model_id", model.id).put("user_id", item.userId)
                .put("device_id", item.deviceId).put("input_revision", item.inputRevision.toString())
                .put("publication_mode", "shadow").put("canonical_outputs_allowed", false)
                .put("status", "abstained").put("reason", "owned_device_inputs_unavailable")
            else runner.evaluateModel(request, model.id)
            if (lost.get()) return true
            val failure = transientFailure(output)
            if (output.optString("reason") == "required_verified_model_inputs_unavailable")
                queue.finish(item, failure = "verified_model_inputs_waiting")
            else if (failure != null) queue.finish(item, failure = failure) else {
                val requiresCheckpoint = model.activation.optJSONObject("assets")?.has("weights") == true
                if (output.optString("status") == "complete" && (requiresCheckpoint || !output.isNull("checkpoint_sha256")) &&
                    output.optString("checkpoint_sha256") != ModelWorkQueue.checkpointHash(model)) {
                    queue.finish(item, failure = "inference_checkpoint_mismatch")
                } else {
                    output.put("activation_sha256", ModelWorkQueue.activationHash(model))
                        .put("checkpoint_sha256", ModelWorkQueue.checkpointHash(model))
                        .put("activation_revision", item.activationRevision)
                    queue.finish(item, output)
                }
            }
        } catch (error: Exception) {
            if (!lost.get()) queue.finish(item, failure = "model_worker_${error.javaClass.simpleName}")
        } finally {
            renewal.shutdownNow()
            if (deadlineExceeded.get()) {
                Thread.interrupted()
                runCatching { queue.finish(item, failure = "model_attempt_timeout") }
                throw AttemptDeadlineExceeded()
            }
            if (lost.get()) Thread.interrupted() // Cancellation is scoped to this lease, not the next user.
        }
        return true
    }

    companion object {
        fun transientFailure(output: JSONObject): String? {
            val reason = output.optString("reason")
            return if (reason in setOf("inference_timeout", "inference_worker_failed", "inference_output_limit",
                    "inference_output_contract_invalid", "inference_request_failed", "inference_cancelled", "inference_busy",
                    "shadow_request_timeout", "shadow_deadline_before_models", "shadow_execution_failed",
                    "shadow_request_cancelled", "raw_input_temporarily_unavailable",
                    "model_output_contract_invalid", "model_input_or_execution_failed", "model_execution_failed") ||
                output.optString("status") !in setOf("complete", "abstained")) reason.ifBlank { "invalid_model_status" } else null
        }
    }
}
