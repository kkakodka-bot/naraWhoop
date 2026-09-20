package com.noop.push

import com.noop.account.AccountStorageContext
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.time.Clock

/** Owns one generation's input journal. Construction does not open a DB or import local defaults. */
class ScoringInputRuntime(
    private val account: AccountStorageContext,
    private val rpc: AccountScoringRpc = AccountScoringRpc(account),
    private val clock: Clock = Clock.systemUTC(),
    private val scheduled: () -> Unit = { ScoringInputWorker.enqueue(account) },
    private val openDatabase: (AccountStorageContext) -> ScoringSyncDatabase = { ScoringSyncDatabase.open(it) },
) {
    private val lifecycle = Any()
    private val operations = Mutex()
    @Volatile private var retired = false
    private var database: ScoringSyncDatabase? = null
    private var coordinator: ScoringInputCoordinator? = null
    private var retirement: Job? = null

    private fun active() {
        if (retired || !account.isCurrent()) throw AccountAuthException(AuthFailure.STALE)
        if (account.identity.scope == null) throw AccountAuthException(AuthFailure.SIGNED_OUT)
    }

    fun captureSource(rawDeviceId: String): ScoringInputSource {
        active()
        return ScoringInputSource.capture(account, rawDeviceId)
    }

    suspend fun saveProfile(value: ScoringProfileInput, source: ScoringInputSource,
                            resolving: String? = null): ScoringInputMutation = use {
        it.saveProfile(value, source, resolving)
    }

    suspend fun saveConfig(value: ScoringConfigInput, capturedProfileTimezone: String,
                           source: ScoringInputSource, resolving: String? = null): ScoringInputMutation = use {
        it.saveConfig(value, capturedProfileTimezone, source, resolving)
    }

    suspend fun queueSleepEdit(snapshot: ServerSnapshotV2, edit: ScoringSleepEdit,
                              resolving: String? = null): ScoringInputMutation = use {
        it.queueSleepEdit(snapshot, edit, resolving)
    }

    suspend fun queueSleepTombstone(snapshot: ServerSnapshotV2, session: ScoreSleep,
                                   resolving: String? = null): ScoringInputMutation = use {
        it.queueSleepTombstone(snapshot, session, resolving)
    }

    suspend fun head(key: ScoringInputKey): ScoringInputHead = use { it.head(key) }
    suspend fun read(key: ScoringInputKey, asOfDay: String): ScoringHistoryValue = use { it.read(key, asOfDay) }
    internal suspend fun captureProfile(value: ScoringProfileInput, source: ScoringInputSource): ScoringInputMutation = use { it.captureProfile(value, source) }
    internal suspend fun captureConfig(value: ScoringConfigInput, timezone: String, source: ScoringInputSource): ScoringInputMutation = use { it.captureConfig(value, timezone, source) }
    suspend fun recoverConsent() = use { it.recoverConsent() }

    private suspend fun <T> use(body: suspend (ScoringInputCoordinator) -> T): T = withContext(Dispatchers.IO) {
        operations.withLock {
            active()
            val handle = coordinator ?: openCoordinator().also { coordinator = it }
            val result = body(handle)
            active()
            result
        }
    }

    private fun openCoordinator(): ScoringInputCoordinator {
        val opened = openDatabase(account)
        try {
            synchronized(lifecycle) {
                active()
                database = opened
            }
            return ScoringInputCoordinator(account, ScoringSyncStore(account, opened), rpc, clock, scheduled)
        } catch (failure: Throwable) {
            opened.close()
            throw failure
        }
    }

    fun retire() {
        synchronized(lifecycle) {
            if (retired) return
            retired = true
            database?.retireWrites()
            // Independent of the cancelled presentation scope; pending rows are retained on disk.
            retirement = CoroutineScope(Dispatchers.IO).launch {
                operations.withLock {
                    database?.close()
                    database = null
                    coordinator = null
                }
            }
        }
    }

    internal suspend fun awaitRetirement() { synchronized(lifecycle) { retirement }?.join() }
}
