package com.noop.push

import android.content.Context
import com.noop.account.AccountStorageContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.time.LocalDate
import java.time.ZoneId

data class ServerSnapshotDayState(
    val snapshot: ServerSnapshotV2?,
    val phase: String,
    val cached: Boolean,
    val pending: Boolean,
    val requestedInputRevision: Long?,
    val fetchedAt: Long?,
)

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

    private fun cacheStore(identity: String?) = ServerScoreCacheStore(
        account.getSharedPreferences(
            "noop_enrolled_scores_" + EnrollmentDataScope.digest(identity.orEmpty()),
            Context.MODE_PRIVATE,
        ),
    )
    private val session = ServerScoreSessionState()
    private val visibleDays = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
    private var pollingDay: String? = null
    private fun currentOwnerId() = EnrollmentDataScope.credential(appContext)?.userId
    private fun currentIdentityKey() = ServerScoreClient.requestIdentity(appContext)
    private var activeIdentityKey: String? = currentIdentityKey()

    private val _enabled = MutableStateFlow(ServerScoringSettings.isEnabled(appContext))
    val enabled: StateFlow<Boolean> = _enabled.asStateFlow()

    private val _days = MutableStateFlow<Map<String, ServerSnapshotDayState>>(emptyMap())
    val days: StateFlow<Map<String, ServerSnapshotDayState>> = _days.asStateFlow()
    private val _sleepDays = MutableStateFlow<Map<String, ServerSleepPresentation>>(emptyMap())
    val sleepDays: StateFlow<Map<String, ServerSleepPresentation>> = _sleepDays.asStateFlow()
    private val _lastError = MutableStateFlow<String?>(null)
    val lastError: StateFlow<String?> = _lastError.asStateFlow()
    private val _sleepEditMessage = MutableStateFlow<String?>(null)
    val sleepEditMessage: StateFlow<String?> = _sleepEditMessage.asStateFlow()
    private val _lastFetchedAtMs = MutableStateFlow<Long?>(null)
    val lastFetchedAtMs: StateFlow<Long?> = _lastFetchedAtMs.asStateFlow()
    private val _signedIn = MutableStateFlow(currentOwnerId() != null || account.identity.scope != null)
    val signedIn: StateFlow<Boolean> = _signedIn.asStateFlow()

    init {
        session.activate(currentOwnerId())
        preloadRecentDays()
        scope.launch(Dispatchers.IO) {
            mutex.withLock {
                if (!current()) return@withLock
                val zone = timezone(); val today = LocalDate.now(ZoneId.of(zone))
                repeat(14) { hydrate(today.minusDays(it.toLong()).toString(), zone) }
            }
        }
    }

    fun setEnabled(enabled: Boolean) {
        ServerScoringSettings.setEnabled(appContext, enabled)
        _enabled.value = enabled
        if (enabled) startPolling(pollingDay ?: LocalDate.now().toString()) else stopPolling()
    }

    suspend fun refreshVisibleDays() {
        if (visibleDays.isEmpty()) visibleDays.add(pollingDay ?: LocalDate.now().toString())
        for (day in visibleDays.sorted()) refreshDay(day)
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
        if (!ServerScoringSettings.isEnabled(appContext)) return null
        synchronizeOwner()
        visibleDays.add(day)
        session.overlay(day, currentOwnerId())?.let { return it }
        if (!current()) return null
        val state = _days.value[day] ?: return null
        val snapshot = state.snapshot?.takeIf { it.timezone == timezone() } ?: return null
        return snapshot.legacy(state.fetchedAt ?: 0, state.pending || state.cached || state.phase !in setOf("available", "no_data"))
    }

    suspend fun signIn(email: String, password: String) {
        try { CloudAuthClient.signIn(appContext, email, password) }
        catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { if (account.isCurrent()) _lastError.value = "Sign-in failed" }
    }

    fun signOut() {
        PushEnrollmentManager.from(appContext).clear()
        CloudAuthClient.clearSession(appContext)
        _signedIn.value = false
        stopPolling()
        session.activate(null)
        _days.value = emptyMap()
        _sleepDays.value = emptyMap()
        _lastFetchedAtMs.value = null
        _lastError.value = null
        _sleepEditMessage.value = null
    }

    fun startPolling(todayKey: String) {
        pollingDay = todayKey
        synchronizeOwner()
        if (!ready() || (!_signedIn.value && !current())) return
        stopPolling()
        pollJob = scope.launch {
            while (isActive) {
                refreshDay(todayKey)
                delay(ServerScoringSettings.POLL_INTERVAL_SECONDS * 1000L)
            }
        }
    }

    fun stopPolling() {
        pollJob?.cancel()
        pollJob = null
    }

    fun retire() {
        synchronized(publicationLock) {
            retired = true
            _days.value = emptyMap()
            _sleepDays.value = emptyMap()
        }
        stopPolling()
        if (storeHandle.isInitialized()) storeHandle.value.database.retireWrites()
        if (retirement == null) retirement = CoroutineScope(Dispatchers.IO).launch {
            mutex.withLock { if (storeHandle.isInitialized()) storeHandle.value.database.close() }
        }
    }

    internal suspend fun awaitRetirement() { retirement?.join() }

    /** Authenticated boundary writes never mutate the local sleep database or invoke local scoring. */
    suspend fun saveSleepOverride(target: ServerSleepEditTarget, start: Long, end: Long, tombstone: Boolean): Boolean {
        synchronizeOwner()
        val cache = session.overlay(target.day, currentOwnerId())
        if (!ServerScoringSettings.enrollmentReady(appContext) || target.ownerId != session.ownerId() ||
            cache?.features?.get("sleep")?.deviceId != target.deviceId ||
            cache.features["sleep"]?.supportsBoundaryOverrides != true) {
            _lastError.value = "The account or sleep source changed. Refresh before editing."
            return false
        }
        val generation = session.generation(); val key = "override:${target.id}"; val request = session.beginRequest(key)
        _lastError.value = null
        try {
            ServerScoreClient.saveSleepOverride(appContext, target, start, end, tombstone)
            currentCoroutineContext().ensureActive()
            synchronizeOwner()
            if (!session.isCurrentRequest(key, generation, currentOwnerId(), request)) return false
            _sleepEditMessage.value = if (tombstone) "Sleep deleted. Server recomputation queued." else "Sleep boundaries saved. Server recomputation queued."
            refreshDay(target.day)
            return generation == session.generation() && currentOwnerId() == target.ownerId
        } catch (error: Exception) {
            if (error is CancellationException) throw error
            synchronizeOwner()
            if (!session.isCurrentRequest(key, generation, currentOwnerId(), request)) return false
            when (error) {
                is ServerScoreClient.Unauthorized -> {
                    if (!clearCredentialIfCurrent(error.accessToken, target.ownerId)) return false
                    synchronizeOwner()
                    _lastError.value = "Enrollment expired — enter a fresh code"
                }
                is ServerScoreClient.Conflict -> {
                    refreshDay(target.day)
                    if (generation != session.generation() || currentOwnerId() != target.ownerId) return false
                    _lastError.value = "This sleep was changed elsewhere. Close the editor and reopen it to use the latest revision."
                }
                else -> _lastError.value = "Sleep changes were not confirmed. Refresh before retrying; local sleep records were not changed."
            }
            return false
        }
    }

    suspend fun refreshDay(day: String) {
        if (retired) return
        synchronizeOwner()
        visibleDays.add(day)
        if (ServerScoringSettings.enrollmentReady(appContext) && currentOwnerId() != null) {
            refreshPhysiology(day)
        }
        refreshAccountSnapshot(day)
    }

    private suspend fun refreshPhysiology(day: String) {
        val owner = session.ownerId() ?: return
        val identity = activeIdentityKey ?: return
        val store = cacheStore(identity)
        val generation = session.generation()
        val request = session.beginRequest(day)
        runCatching {
            val cache = ServerScoreClient.fetchDaySnapshot(appContext, day, owner)
            currentCoroutineContext().ensureActive()
            synchronizeOwner()
            if (!session.accept(cache, generation, currentOwnerId(), request)) return
            ServerScoringSettings.markOverlayLive(
                ServerScoringSettings.prefs(appContext),
                ServerScoringSettings.overlayIsLive(cache),
            )
            store.upsert(cache)
            _lastFetchedAtMs.value = cache.fetchedAtMs
            _lastError.value = null
        }.onFailure { err ->
            if (err is CancellationException) throw err
            synchronizeOwner()
            if (!session.isCurrentRequest(day, generation, currentOwnerId(), request)) return
            if (err is ServerScoreClient.Unauthorized) {
                if (!clearCredentialIfCurrent(err.accessToken, owner)) return
                _signedIn.value = current()
                session.activate(null)
                _lastError.value = "Enrollment expired — enter a fresh code"
            } else {
                _lastError.value = "Server scores unavailable"
                store.load(owner, day)?.let { session.accept(it, generation, currentOwnerId(), request) }
            }
        }
    }

    private suspend fun refreshAccountSnapshot(day: String) = withContext(Dispatchers.IO) {
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
                if (_lastError.value == null || _lastError.value == "Server scores unavailable") {
                    _lastError.value = null
                }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) {
                if (!current()) return@withLock
                val old = _days.value[day]
                publish(day, ServerSnapshotDayState(old?.snapshot, "unavailable", old?.snapshot != null, old?.pending ?: false,
                    old?.requestedInputRevision, old?.fetchedAt))
                if (session.overlay(day, currentOwnerId()) == null) {
                    _lastError.value = "Server scores unavailable"
                }
            }
        }
    }

    private fun preloadRecentDays() {
        val owner = session.ownerId() ?: return
        val identity = activeIdentityKey ?: return
        val store = cacheStore(identity)
        val cal = java.util.Calendar.getInstance()
        val fmt = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US)
        repeat(14) { offset ->
            cal.timeInMillis = System.currentTimeMillis()
            cal.add(java.util.Calendar.DAY_OF_YEAR, -offset)
            val key = fmt.format(cal.time)
            if (identity == currentIdentityKey()) store.load(owner, key)?.let { session.accept(it, session.generation(), currentOwnerId()) }
        }
    }

    private fun clearCredentialIfCurrent(token: String, owner: String): Boolean {
        val current = EnrollmentDataScope.credential(appContext) ?: return false
        if (current.userId != owner || current.uploadToken != token) return false
        val store = PushEnrollmentStore.from(appContext)
        val settings = SelfHostedPushSettings.from(appContext)
        synchronized(store) {
            if (!store.clearIfCurrent(current)) return false
            settings.clearEnrollmentBinding()
        }
        SelfHostedPushScheduler.credentialChanged(appContext)
        return true
    }

    private fun synchronizeOwner() {
        val current = currentOwnerId()
        val identity = currentIdentityKey()
        _signedIn.value = current != null || this.current()
        if (session.ownerId() == current && activeIdentityKey == identity) return
        activeIdentityKey = identity
        stopPolling()
        session.activate(current)
        _lastFetchedAtMs.value = null
        _lastError.value = null
        _sleepEditMessage.value = null
        preloadRecentDays()
    }
}
