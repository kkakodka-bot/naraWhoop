package com.noop.push

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequest
import androidx.work.WorkManager
import androidx.work.await
import com.noop.R
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/** Exactly-once cleanup seam shared by synchronous throws and asynchronous Operation failures. */
internal class PushEnqueueCompletion(
    private val settleFailure: () -> Boolean,
    private val requeuePending: () -> Unit,
) {
    private val completed = AtomicBoolean(false)
    @Volatile var requeuedPending: Boolean = false
        private set

    fun success(): Boolean = completed.compareAndSet(false, true)

    fun failure(): Boolean {
        if (!completed.compareAndSet(false, true)) return false
        val pending = settleFailure()
        if (pending) {
            requeuedPending = true
            requeuePending()
        }
        return true
    }
}

internal fun continuationEnqueueCompletion(
    settleFailure: () -> Boolean,
    requeuePending: () -> Unit,
) = PushEnqueueCompletion(settleFailure, requeuePending)

internal fun requiredPushNetworkType(wifiOnly: Boolean): NetworkType =
    if (wifiOnly) NetworkType.UNMETERED else NetworkType.CONNECTED

/** The only entry point that queues pushes. Unique work serialises every trigger to one worker. */
object SelfHostedPushScheduler {
    internal const val UNIQUE_WORK = "self-hosted-health-push"
    internal const val BACKOFF_SECONDS = 30L
    // A new true offload supersedes stale/running work. Cancellable deterministic requests and exact
    // acks make replay safe, while REPLACE prevents an unbounded chain of rapid offload triggers.
    internal val EXISTING_WORK_POLICY = ExistingWorkPolicy.REPLACE
    internal val CONTINUATION_WORK_POLICY = ExistingWorkPolicy.APPEND_OR_REPLACE

    private val throttle = java.util.concurrent.ConcurrentHashMap<String, AtomicLong>()

    internal fun workName(context: AccountSessionContext) = "$UNIQUE_WORK.${context.scope.namespace}.${context.generation}"

    fun cancelSession(context: Context, captured: AccountSessionContext) {
        WorkManager.getInstance(com.noop.account.AccountStorageContext.platform(context)).cancelUniqueWork(workName(captured))
    }

    fun enqueueAfterSuccessfulOffload(context: Context) = enqueueExternal(context)

    fun enqueueLaunchCatchUp(context: Context) = enqueueExternal(context)

    fun enqueueManualCatchUp(context: Context) = enqueueExternal(context)

    /** Foreground idle cadence when server scoring is on (spec: 30–60 s). No-op when flag is off. */
    fun enqueueIfDue(context: Context, minIntervalMs: Long) {
        if (!ServerScoringSettings.isEnabled(context)) return
        val account = com.noop.account.AccountStorageContext.capture(context)
        val captured = account.identity.context ?: return
        if (!account.isCurrent()) return
        val lastThrottledEnqueueAt = throttle.getOrPut(workName(captured)) { AtomicLong(0) }
        val now = System.currentTimeMillis()
        val last = lastThrottledEnqueueAt.get()
        if (now - last < minIntervalMs) return
        if (!lastThrottledEnqueueAt.compareAndSet(last, now)) return
        enqueueExternal(account)
    }

    /** During offload: flush push on chunk commit, throttled to [ServerScoringSettings.SYNC_PUSH_INTERVAL_MS]. */
    fun enqueueOnChunkCommitted(context: Context) {
        if (!ServerScoringSettings.isEnabled(context)) return
        enqueueIfDue(context, ServerScoringSettings.SYNC_PUSH_INTERVAL_MS)
    }

    /** One flush when the app backgrounds (server scoring on). */
    fun flushOnBackground(context: Context) {
        if (!ServerScoringSettings.isEnabled(context)) return
        com.noop.account.AccountStorageContext.capture(context).identity.context?.let { throttle.remove(workName(it)) }
        enqueueExternal(context)
    }

    /** Replace queued work so a changed network policy takes effect immediately. */
    fun networkPolicyChanged(context: Context) {
        val app = com.noop.account.AccountStorageContext.capture(context)
        PushRunSignal.clear(app)
        WorkManager.getInstance(com.noop.account.AccountStorageContext.platform(app)).cancelUniqueWork(workName(app.identity.context ?: return))
        enqueueExternal(app)
    }

    /** Queue the next healthy pagination/device slice without WorkManager's failure backoff. */
    internal suspend fun enqueueContinuation(
        context: Context,
        preserveTriggerOnFailure: Boolean = false,
    ): Boolean {
        val app = com.noop.account.AccountStorageContext.capture(context)
        val settings = SelfHostedPushSettings.from(app)
        if (settings.enabledEndpoint() == null) return true
        val captured = app.identity.context ?: return true
        if (!app.isCurrent()) return true
        val request = request(settings.wifiOnly(), captured)
        // Another real trigger won the release/enqueue race and now owns a queued request.
        if (!PushRunSignal.reserve(app, request.id.toString())) return true
        val completion = continuationEnqueueCompletion(
            settleFailure = {
                PushRunSignal.releaseReservation(app, request.id.toString()) || preserveTriggerOnFailure
            },
            // A real trigger may have coalesced while Operation.await() was in flight. Preserve it
            // as fresh external work; the current worker will observe its owner and return success.
            requeuePending = { enqueueExternal(app) },
        )
        return try {
            val operation = WorkManager.getInstance(com.noop.account.AccountStorageContext.platform(app)).enqueueUniqueWork(
                workName(captured), CONTINUATION_WORK_POLICY, request,
            )
            operation.await()
            completion.success()
            true
        } catch (cancelled: CancellationException) {
            completion.failure()
            throw cancelled
        } catch (_: Throwable) {
            completion.failure()
            completion.requeuedPending
        }
    }

    fun cancel(context: Context) {
        val app = com.noop.account.AccountStorageContext.capture(context)
        // This is the immediate correctness boundary; WorkManager cancellation itself is async.
        // Disabled settings make the UI idle now and cause all late worker status writes to no-op.
        SelfHostedPushSettings.from(app).setEnabled(false)
        PushRunSignal.clear(app)
        WorkManager.getInstance(com.noop.account.AccountStorageContext.platform(app)).cancelUniqueWork(workName(app.identity.context ?: return))
    }

    private fun enqueueExternal(context: Context) {
        val app = com.noop.account.AccountStorageContext.capture(context)
        val settings = SelfHostedPushSettings.from(app)
        if (settings.enabledEndpoint() == null) return
        val captured = app.identity.context ?: return
        if (!app.isCurrent()) return
        val request = request(settings.wifiOnly(), captured)
        if (!PushRunSignal.reserve(app, request.id.toString())) return
        val completion = PushEnqueueCompletion(
            settleFailure = {
                PushRunSignal.releaseReservation(app, request.id.toString()) { pending ->
                    if (!pending) settings.recordError(app.getString(R.string.push_error_enqueue_failed))
                }
            },
            // A trigger coalesced while WorkManager's async Operation was in flight. Recreate it
            // after releasing the failed owner; if a newer trigger wins the race, reserve coalesces.
            requeuePending = { enqueueExternal(app) },
        )
        try {
            settings.recordPushStarted()
            val operation = WorkManager.getInstance(com.noop.account.AccountStorageContext.platform(app)).enqueueUniqueWork(workName(captured), EXISTING_WORK_POLICY, request)
            enqueueObserverScope.launch {
                try {
                    operation.await()
                    completion.success()
                } catch (_: Throwable) {
                    completion.failure()
                }
            }
        } catch (_: Throwable) {
            completion.failure()
        }
    }

    internal fun request(wifiOnly: Boolean, captured: AccountSessionContext) = OneTimeWorkRequest.Builder(SelfHostedPushWorker::class.java)
        .setInputData(SelfHostedPushWorker.accountInput(captured))
        .setConstraints(
            Constraints.Builder().setRequiredNetworkType(requiredPushNetworkType(wifiOnly)).build(),
        )
        .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, BACKOFF_SECONDS, TimeUnit.SECONDS)
        .build() // Only opaque owner namespace and generation; never credentials or payloads.

    private val enqueueObserverScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
}
