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
    private val liveWakeups = mutableMapOf<String, kotlinx.coroutines.Job>()

    /** First commit arms a trailing wake; later commits cannot postpone it. Durable debt and
     * WorkManager recovery cover process loss between the Room commit and this in-memory wake. */
    fun enqueueOnLiveCommitted(context: Context) {
        val account = com.noop.account.AccountStorageContext.capture(context)
        if (!account.isCurrent() || account.identity.context == null) return
        val key = workName(account.identity.context)
        synchronized(liveWakeups) {
            if (liveWakeups.containsKey(key)) return
            liveWakeups[key] = enqueueObserverScope.launch {
                try {
                    kotlinx.coroutines.delay(10_000)
                    enqueueExternal(account)
                } finally { synchronized(liveWakeups) { liveWakeups.remove(key) } }
            }
        }
    }

    fun registerRecovery(context: Context) {
        val account = com.noop.account.AccountStorageContext.capture(context)
        val owner = account.identity.context ?: return
        val settings = SelfHostedPushSettings.from(account)
        if (!account.isCurrent() || settings.readyEndpoint() == null) return
        val input = androidx.work.Data.Builder().putString("namespace", owner.scope.namespace)
            .putString("source", settings.sourceId()).build()
        val work = androidx.work.PeriodicWorkRequestBuilder<BleUploadRecoveryWorker>(15, TimeUnit.MINUTES)
            .setInputData(input).addTag("ble-upload-recovery.${owner.scope.namespace}")
            .setConstraints(Constraints.Builder().setRequiredNetworkType(requiredPushNetworkType(settings.wifiOnly())).build())
            .build()
        WorkManager.getInstance(com.noop.account.AccountStorageContext.platform(account)).enqueueUniquePeriodicWork(
            "ble-upload-recovery.${owner.scope.namespace}", androidx.work.ExistingPeriodicWorkPolicy.UPDATE, work)
    }

    internal fun workName(context: AccountSessionContext?) =
        context?.let { "$UNIQUE_WORK.${it.scope.namespace}.${it.generation}" } ?: UNIQUE_WORK

    fun cancelSession(context: Context, captured: AccountSessionContext) {
        synchronized(liveWakeups) { liveWakeups.remove(workName(captured))?.cancel() }
        WorkManager.getInstance(com.noop.account.AccountStorageContext.platform(context))
            .cancelAllWorkByTag("ble-upload-recovery.${captured.scope.namespace}")
        WorkManager.getInstance(com.noop.account.AccountStorageContext.platform(context)).cancelUniqueWork(workName(captured))
    }

    fun enqueueAfterSuccessfulOffload(context: Context) = enqueueExternal(context)

    fun enqueueLaunchCatchUp(context: Context) = enqueueExternal(context)

    fun enqueueManualCatchUp(context: Context) = enqueueExternal(context)

    /** Runtime idle cadence. Raw transport remains independent of physiological computation. */
    fun enqueueIfDue(context: Context, minIntervalMs: Long) {
        val account = com.noop.account.AccountStorageContext.capture(context)
        val captured = account.identity.context
        if (captured != null && !account.isCurrent()) return
        val lastThrottledEnqueueAt = throttle.getOrPut(workName(captured)) { AtomicLong(0) }
        val now = System.currentTimeMillis()
        val last = lastThrottledEnqueueAt.get()
        if (now - last < minIntervalMs) return
        if (!lastThrottledEnqueueAt.compareAndSet(last, now)) return
        enqueueExternal(account)
    }

    /** History and live commits share the bounded trailing wake. */
    fun enqueueOnChunkCommitted(context: Context) {
        enqueueOnLiveCommitted(context)
    }

    /** One transport flush when the app backgrounds. */
    fun flushOnBackground(context: Context) {
        val app = com.noop.account.AccountStorageContext.capture(context)
        throttle.remove(workName(app.identity.context))
        enqueueExternal(app)
    }

    /** Replace queued work so a changed network policy takes effect immediately. */
    fun networkPolicyChanged(context: Context) {
        val app = com.noop.account.AccountStorageContext.capture(context)
        PushRunSignal.clear(app)
        WorkManager.getInstance(com.noop.account.AccountStorageContext.platform(app)).cancelUniqueWork(workName(app.identity.context))
        enqueueExternal(app)
    }

    fun credentialChanged(context: Context) {
        val app = com.noop.account.AccountStorageContext.capture(context)
        PushRunSignal.clear(app)
        WorkManager.getInstance(com.noop.account.AccountStorageContext.platform(app)).cancelUniqueWork(workName(app.identity.context))
        if (SelfHostedPushSettings.from(app).readyEndpoint() != null) enqueueExternal(app)
    }

    /** Queue the next healthy pagination/device slice without WorkManager's failure backoff. */
    internal suspend fun enqueueContinuation(
        context: Context,
        preserveTriggerOnFailure: Boolean = false,
    ): Boolean {
        val app = com.noop.account.AccountStorageContext.capture(context)
        val settings = SelfHostedPushSettings.from(app)
        if (settings.readyEndpoint() == null) return true
        val captured = app.identity.context
        if (captured != null && !app.isCurrent()) return true
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
        WorkManager.getInstance(com.noop.account.AccountStorageContext.platform(app)).cancelUniqueWork(workName(app.identity.context))
    }

    private fun enqueueExternal(context: Context) {
        val app = com.noop.account.AccountStorageContext.capture(context)
        if (!EnrollmentDataScope.active(app)) return
        val settings = SelfHostedPushSettings.from(app)
        if (settings.readyEndpoint() == null) return
        val captured = app.identity.context
        if (captured != null && !app.isCurrent()) return
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

    internal fun request(wifiOnly: Boolean, captured: AccountSessionContext?) = OneTimeWorkRequest.Builder(SelfHostedPushWorker::class.java)
        .apply { captured?.let { setInputData(SelfHostedPushWorker.accountInput(it)) } }
        .setConstraints(
            Constraints.Builder().setRequiredNetworkType(requiredPushNetworkType(wifiOnly)).build(),
        )
        .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, BACKOFF_SECONDS, TimeUnit.SECONDS)
        .build() // Only opaque owner namespace and generation; never credentials or payloads.

    private val enqueueObserverScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
}

/** Upload-only recovery. It never reconnects BLE or attempts a background FGS start. */
class BleUploadRecoveryWorker(context: Context, params: androidx.work.WorkerParameters) :
    androidx.work.CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val account = com.noop.account.AccountStorageContext.capture(applicationContext)
        if (!account.isCurrent() || account.namespace != inputData.getString("namespace") ||
            SelfHostedPushSettings.from(account).sourceId() != inputData.getString("source")) return Result.success()
        SelfHostedPushScheduler.enqueueLaunchCatchUp(account)
        return Result.success()
    }
}
