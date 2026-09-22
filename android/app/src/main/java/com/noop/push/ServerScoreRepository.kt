package com.noop.push

import android.content.Context
import com.noop.account.AccountStorageContext
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.time.LocalDate
import java.time.ZoneId

data class ServerSnapshotDayState(val snapshot: ServerSnapshotV2?, val phase: String, val cached: Boolean,
    val pending: Boolean, val requestedInputRevision: Long?, val fetchedAt: Long?)

class ServerScoreRepository(
    private val appContext: Context,
    private val scope: CoroutineScope,
    private val timezone: () -> String = { ZoneId.systemDefault().id },
    private val rpc: AccountScoringRpc = AccountScoringRpc(AccountStorageContext.capture(appContext)),
    private val ready: () -> Boolean = { ServerScoringSettings.ready(appContext) },
) {
    private val account = AccountStorageContext.capture(appContext)
    private val publicationLock = Any()
    @Volatile private var retired = false
    private fun current() = !retired && account.identity.scope != null && account.isCurrent()
    private val storeHandle = lazy { ScoringSyncStore(account, ScoringSyncDatabase.open(account)) }
    private val mutex = Mutex()
    private var pollJob: Job? = null
    private var retirement: Job? = null
    private val _days = MutableStateFlow<Map<String, ServerSnapshotDayState>>(emptyMap())
    val days: StateFlow<Map<String, ServerSnapshotDayState>> = _days.asStateFlow()
    private val _sleepDays = MutableStateFlow<Map<String, ServerSleepPresentation>>(emptyMap())
    val sleepDays: StateFlow<Map<String, ServerSleepPresentation>> = _sleepDays.asStateFlow()
    private val _lastError = MutableStateFlow<String?>(null)
    val lastError: StateFlow<String?> = _lastError.asStateFlow()
    private val _lastFetchedAtMs = MutableStateFlow<Long?>(null)
    val lastFetchedAtMs: StateFlow<Long?> = _lastFetchedAtMs.asStateFlow()
    private val _signedIn = MutableStateFlow(account.identity.scope != null)
    val signedIn: StateFlow<Boolean> = _signedIn.asStateFlow()

    init {
        scope.launch(Dispatchers.IO) {
            mutex.withLock {
                if (!current()) return@withLock
                val zone = timezone(); val today = LocalDate.now(ZoneId.of(zone))
                repeat(14) { hydrate(today.minusDays(it.toLong()).toString(), zone) }
            }
        }
    }
    private fun publish(day: String, state: ServerSnapshotDayState) {
        try {
            CloudAuthClient.withIdentity(account, account.identity) {
                synchronized(publicationLock) {
                    if (retired || account.identity.scope == null) return@synchronized
                    _days.value = (_days.value + (day to state)).entries.sortedByDescending { it.key }.take(56).associate { it.toPair() }
                    _sleepDays.value = _days.value.mapNotNull { (key, value) -> ServerSleepPresentation.from(value)?.let { key to it } }.toMap()
                    _lastFetchedAtMs.value = state.fetchedAt
                }
            }
        } catch (failure: AccountAuthException) {
            if (failure.failure != AuthFailure.STALE) throw failure
        }
    }
    private fun hydrate(day: String, zone: String) {
        runCatching { storeHandle.value.load(day, zone) }.getOrNull()?.let { (snapshot, fetched) ->
            val envelope = org.json.JSONObject(snapshot.json)
            publish(day, ServerSnapshotDayState(snapshot, snapshot.status, true, envelope.optBoolean("pending", false),
                if (envelope.isNull("requestedInputRevision")) null else SyncJson.long(envelope, "requestedInputRevision"), fetched))
        }
    }
    fun overlay(day: String): ServerScoreDayCache? {
        if (!current() || !ServerScoringSettings.isEnabled(appContext)) return null
        val state = _days.value[day] ?: return null
        val snapshot = state.snapshot?.takeIf { it.timezone == timezone() } ?: return null
        return snapshot.legacy(state.fetchedAt ?: 0, state.pending || state.cached || state.phase !in setOf("available", "no_data"))
    }
    suspend fun signIn(email: String, password: String) {
        try { CloudAuthClient.signIn(appContext, email, password) }
        catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { if (account.isCurrent()) _lastError.value = "Sign-in failed" }
        // AccountAppRuntime rebuilds with the new identity; this old object never adopts it.
    }
    fun signOut() { CloudAuthClient.clearSession(appContext); _signedIn.value = false; stopPolling(); _days.value = emptyMap(); _sleepDays.value = emptyMap() }
    fun startPolling(todayKey: String) {
        if (!current() || !ready()) return
        stopPolling()
        pollJob = scope.launch {
            while (isActive) {
                refreshDay(LocalDate.now(ZoneId.of(timezone())).toString())
                delay(ServerScoringSettings.POLL_INTERVAL_SECONDS * 1000)
            }
        }
    }
    fun stopPolling() { pollJob?.cancel(); pollJob = null }
    fun retire() {
        synchronized(publicationLock) { retired = true; _days.value = emptyMap(); _sleepDays.value = emptyMap() }
        stopPolling()
        if (storeHandle.isInitialized()) storeHandle.value.database.retireWrites()
        if (retirement == null) retirement = CoroutineScope(Dispatchers.IO).launch {
            mutex.withLock { if (storeHandle.isInitialized()) storeHandle.value.database.close() }
        }
    }
    internal suspend fun awaitRetirement() { retirement?.join() }
    suspend fun refreshDay(day: String) = withContext(Dispatchers.IO) {
        mutex.withLock {
            if (!current() || !ready()) return@withLock
            val zone = timezone()
            if (_days.value[day]?.snapshot?.timezone != zone) {
                _days.value = _days.value - day; _sleepDays.value = _sleepDays.value - day; hydrate(day, zone)
            }
            try {
                val response = rpc.snapshot(day, zone)
                if (!current() || timezone() != zone) return@withLock
                val fetched = System.currentTimeMillis()
                val snapshot = response.snapshot?.let { storeHandle.value.accept(it, fetched) }
                val old = _days.value[day]?.snapshot?.takeIf {
                    (response.sourceDeviceId == null || it.sourceDeviceId == response.sourceDeviceId) &&
                        (response.algorithmVersion == null || it.algorithmVersion == response.algorithmVersion || response.status == "unsupported")
                }
                publish(day, ServerSnapshotDayState(snapshot ?: old, response.status, snapshot == null,
                    response.pending, response.requestedInputRevision, if (snapshot == null) _days.value[day]?.fetchedAt else fetched))
                _lastError.value = null
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) {
                if (!current()) return@withLock
                val old = _days.value[day]
                publish(day, ServerSnapshotDayState(old?.snapshot, "unavailable", old?.snapshot != null, old?.pending ?: false,
                    old?.requestedInputRevision, old?.fetchedAt))
                _lastError.value = "Server scores unavailable"
            }
        }
    }
}
