package com.noop.push

import androidx.work.*
import android.content.Context
import com.noop.account.AccountStorageContext
import com.noop.account.AccountWorkContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.time.Clock
import java.time.LocalDate
import java.time.ZoneId
import java.util.concurrent.TimeUnit

/** Typed intent is frozen before scheduling. These APIs do not activate server editing UI. */
class ScoringInputCoordinator(
    private val account: AccountStorageContext,
    private val store: ScoringSyncStore,
    private val rpc: AccountScoringRpc = AccountScoringRpc(account),
    private val clock: Clock = Clock.systemUTC(),
    private val scheduled: () -> Unit = { ScoringInputWorker.enqueue(account) },
    private val canDeliver: () -> Boolean = { true },
) {
    private val owner = requireNotNull(account.identity.scope)
    suspend fun head(key: ScoringInputKey): ScoringInputHead = ScoringInputHead.decode(
        rpc.call("get_scoring_history_input_head_v3", key.rpc().toString()), owner, key)
    suspend fun read(key: ScoringInputKey, asOfDay: String): ScoringHistoryValue {
        SyncJson.day(asOfDay)
        return ScoringHistoryValue.decode(rpc.call("get_scoring_history_input_v3",
            key.rpc().put("p_as_of_day", asOfDay).toString()), owner, key, asOfDay)
    }
    suspend fun saveProfile(value: ScoringProfileInput, source: ScoringInputSource, resolving: String? = null): ScoringInputMutation = withContext(Dispatchers.IO) {
        require(source.account == account.identity.context)
        val key = ScoringInputKey(source.serverDeviceId, "profile", "primary")
        save(key, today(value.timezone), value.payload(), resolving = resolving)
    }
    suspend fun saveConfig(value: ScoringConfigInput, capturedProfileTimezone: String, source: ScoringInputSource, resolving: String? = null): ScoringInputMutation = withContext(Dispatchers.IO) {
        require(source.account == account.identity.context)
        val key = ScoringInputKey(source.serverDeviceId, "config", "primary")
        save(key, today(capturedProfileTimezone), value.payload(), resolving = resolving)
    }
    internal suspend fun captureProfile(value: ScoringProfileInput, source: ScoringInputSource): ScoringInputMutation = withContext(Dispatchers.IO) {
        require(source.account == account.identity.context)
        save(ScoringInputKey(source.serverDeviceId, "profile", "primary"), today(value.timezone), value.payload(), queueFollowing = true)
    }
    internal suspend fun captureConfig(value: ScoringConfigInput, timezone: String, source: ScoringInputSource): ScoringInputMutation = withContext(Dispatchers.IO) {
        require(source.account == account.identity.context)
        save(ScoringInputKey(source.serverDeviceId, "config", "primary"), today(timezone), value.payload(), queueFollowing = true)
    }
    suspend fun queueSleepEdit(snapshot: ServerSnapshotV2, edit: ScoringSleepEdit, resolving: String? = null): ScoringInputMutation = withContext(Dispatchers.IO) {
        require(snapshot.userId == owner.userID && snapshot.sleep.any { it == edit.session })
        save(ScoringInputKey(snapshot.sourceDeviceId, "sleep_edit", edit.session.editEntity),
            edit.earliestDay(snapshot.timezone), edit.payload(), resolving = resolving)
    }
    suspend fun queueSleepTombstone(snapshot: ServerSnapshotV2, session: ScoreSleep, resolving: String? = null): ScoringInputMutation = withContext(Dispatchers.IO) {
        require(snapshot.userId == owner.userID && snapshot.sleep.contains(session))
        val day = listOf(session.originalEnd, session.end).minOf {
            java.time.Instant.ofEpochSecond(it).atZone(ZoneId.of(snapshot.timezone)).toLocalDate().toString()
        }
        save(ScoringInputKey(snapshot.sourceDeviceId, "sleep_edit", session.editEntity), day, "{}", true, resolving)
    }
    private fun today(timezone: String) = LocalDate.now(clock.withZone(ZoneId.of(timezone))).toString()
    private suspend fun save(key: ScoringInputKey, day: String, payload: String, deleted: Boolean = false, resolving: String? = null,
                             queueFollowing: Boolean = false): ScoringInputMutation {
        // Fresh offline intent is durable before metadata lookup; only an explicit rebase reads now.
        val revision = if (resolving == null) null else head(key)
        val mutation = ScoringConsentRelay.recoverBefore(account, store) {
            store.enqueue(key, revision, day, payload, deleted, resolving, queueFollowing)
        }
        try { scheduled() }
        catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
        catch (_: Exception) { android.util.Log.w("ScoringInput", "Durable input scheduling deferred") }
        return mutation
    }
    internal fun recoverConsent() = ScoringConsentRelay.recoverBefore(account, store) { Unit }
    // Fresh producers still require recoverBefore. A blocked relay must not prevent delivery of
    // already-journaled older work that can release storage. None of these APIs admits sensitive input.
    private fun recoverForDrain(): Boolean = try { recoverConsent(); false }
        catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
        catch (failure: AccountAuthException) { throw failure }
        catch (_: ScoringConsentRelayHeld) { false } // Explicit capture/retry needed; no busy retry loop.
        catch (_: Exception) { true }
    suspend fun drain(): Boolean = withContext(Dispatchers.IO) {
        var retry = recoverForDrain()
        if (!canDeliver()) return@withContext false
        for (draft in store.pending()) {
            var request = draft
            try {
                if (!canDeliver()) return@withContext false
                if (draft.state == "awaiting_head") request = store.admitDraft(draft, ScoringInputHead.decode(
                    rpc.call("get_scoring_history_input_head_v3", draft.key().rpc().toString(), canDeliver), owner, draft.key()))
                if (request.state != "pending") continue
                store.recordReceipt(request, rpc.call("put_scoring_history_input_v3", request.body, canDeliver))
            } catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
            catch (failure: ScoringRpcException) {
                when {
                    failure.conflict -> store.retainFailure(request, "conflict")
                    failure.permanent -> store.retainFailure(request, "rejected")
                    failure.authentication -> return@withContext true
                    else -> retry = true
                }
            } catch (failure: AccountAuthException) {
                if (failure.failure in setOf(AuthFailure.STALE, AuthFailure.SIGNED_OUT, AuthFailure.REVOKED)) throw failure
                retry = true
            } catch (_: Exception) { retry = true } // Invalid ACK/lost reply keeps the exact intent.
        }
        retry = recoverForDrain() || retry
        retry || store.pending(1).isNotEmpty()
    }
}

class ScoringInputWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val account = AccountWorkContext.resolve(applicationContext, inputData) ?: return@withContext Result.success()
        if (!SelfHostedPushSettings.from(account).snapshot().ready) return@withContext Result.success()
        try {
            ScoringSyncDatabase.open(account).use { database ->
                if (ScoringInputCoordinator(account, ScoringSyncStore(account, database),
                    canDeliver = { SelfHostedPushSettings.from(account).snapshot().ready }).drain()) Result.retry() else Result.success()
            }
        } catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
        catch (failure: AccountAuthException) { if (failure.failure == AuthFailure.STALE) Result.success() else Result.retry() }
        catch (_: Exception) { Result.retry() }
    }
    companion object {
        fun request(account: AccountStorageContext): OneTimeWorkRequest = OneTimeWorkRequestBuilder<ScoringInputWorker>()
            .setInputData(AccountWorkContext.input(account)).addTag(AccountWorkContext.tag(account))
            .setConstraints(Constraints.Builder().setRequiredNetworkType(
                if (SelfHostedPushSettings.from(account).wifiOnly()) NetworkType.UNMETERED else NetworkType.CONNECTED).build())
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS).build()
        fun enqueue(account: AccountStorageContext) {
            if (account.identity.scope == null || !account.isCurrent()) return
            WorkManager.getInstance(AccountStorageContext.platform(account)).enqueueUniqueWork(
                AccountWorkContext.name("scoring-input", account), ExistingWorkPolicy.APPEND_OR_REPLACE, request(account))
        }
    }
}
