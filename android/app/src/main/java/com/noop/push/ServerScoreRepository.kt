package com.noop.push

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

class ServerScoreRepository(
    private val appContext: Context,
    private val scope: CoroutineScope,
) {
    private fun cacheStore(identity: String?) = ServerScoreCacheStore(appContext.getSharedPreferences(
        "noop_enrolled_scores_" + EnrollmentDataScope.digest(identity.orEmpty()), Context.MODE_PRIVATE))
    private val session = ServerScoreSessionState()
    private val visibleDays = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
    private var pollingDay: String? = null
    private fun currentOwnerId() = EnrollmentDataScope.credential(appContext)?.userId
    private fun currentIdentityKey() = ServerScoreClient.requestIdentity(appContext)
    private var activeIdentityKey: String? = currentIdentityKey()
    private var pollJob: Job? = null

    private val _enabled = MutableStateFlow(ServerScoringSettings.isEnabled(appContext))
    val enabled: StateFlow<Boolean> = _enabled.asStateFlow()

    fun setEnabled(enabled: Boolean) {
        ServerScoringSettings.setEnabled(appContext, enabled)
        _enabled.value = enabled
        if (enabled) startPolling(pollingDay ?: java.time.LocalDate.now().toString()) else stopPolling()
    }

    suspend fun refreshVisibleDays() {
        if (visibleDays.isEmpty()) visibleDays.add(pollingDay ?: java.time.LocalDate.now().toString())
        for (day in visibleDays.sorted()) refreshDay(day)
    }

    private val _lastError = MutableStateFlow<String?>(null)
    val lastError: StateFlow<String?> = _lastError.asStateFlow()
    private val _sleepEditMessage = MutableStateFlow<String?>(null)
    val sleepEditMessage: StateFlow<String?> = _sleepEditMessage.asStateFlow()

    private val _lastFetchedAtMs = MutableStateFlow<Long?>(null)
    val lastFetchedAtMs: StateFlow<Long?> = _lastFetchedAtMs.asStateFlow()

    private val _signedIn = MutableStateFlow(currentOwnerId() != null)
    val signedIn: StateFlow<Boolean> = _signedIn.asStateFlow()

    init {
        session.activate(currentOwnerId())
        preloadRecentDays()
    }

    fun overlay(day: String): ServerScoreDayCache? {
        if (!ServerScoringSettings.isEnabled(appContext)) return null
        synchronizeOwner()
        visibleDays.add(day)
        return session.overlay(day, currentOwnerId())
    }

    fun signOut() {
        PushEnrollmentManager.from(appContext).clear()
        _signedIn.value = false
        stopPolling()
        session.activate(null)
        _lastFetchedAtMs.value = null
        _lastError.value = null
        _sleepEditMessage.value = null
    }

    fun startPolling(todayKey: String) {
        pollingDay = todayKey
        synchronizeOwner()
        if (!ServerScoringSettings.ready(appContext) || !_signedIn.value) return
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

    /** Authenticated boundary writes never mutate the local sleep database or invoke local scoring. */
    suspend fun saveSleepOverride(target: ServerSleepEditTarget,start: Long,end: Long,tombstone: Boolean): Boolean {
        synchronizeOwner()
        val cache=session.overlay(target.day,currentOwnerId())
        if(!ServerScoringSettings.ready(appContext) || target.ownerId!=session.ownerId() ||
            cache?.features?.get("sleep")?.deviceId!=target.deviceId || cache?.features?.get("sleep")?.supportsBoundaryOverrides!=true) {
            _lastError.value="The account or sleep source changed. Refresh before editing."
            return false
        }
        val generation=session.generation(); val key="override:${target.id}"; val request=session.beginRequest(key)
        _lastError.value=null
        try {
            ServerScoreClient.saveSleepOverride(appContext,target,start,end,tombstone)
            currentCoroutineContext().ensureActive()
            synchronizeOwner()
            if(!session.isCurrentRequest(key,generation,currentOwnerId(),request)) return false
            _sleepEditMessage.value=if(tombstone) "Sleep deleted. Server recomputation queued." else "Sleep boundaries saved. Server recomputation queued."
            refreshDay(target.day)
            return generation==session.generation() && currentOwnerId()==target.ownerId
        } catch(error: Exception) {
            if(error is CancellationException) throw error
            synchronizeOwner()
            if(!session.isCurrentRequest(key,generation,currentOwnerId(),request)) return false
            when(error) {
                is ServerScoreClient.Unauthorized -> {
                    if(!clearCredentialIfCurrent(error.accessToken,target.ownerId)) return false
                    synchronizeOwner()
                    _lastError.value="Enrollment expired — enter a fresh code"
                }
                is ServerScoreClient.Conflict -> {
                    refreshDay(target.day)
                    if(generation!=session.generation() || currentOwnerId()!=target.ownerId) return false
                    _lastError.value="This sleep was changed elsewhere. Close the editor and reopen it to use the latest revision."
                }
                else -> _lastError.value="Sleep changes were not confirmed. Refresh before retrying; local sleep records were not changed."
            }
            return false
        }
    }

    suspend fun refreshDay(day: String) {
        synchronizeOwner()
        if (!ServerScoringSettings.ready(appContext) || !_signedIn.value) return
        visibleDays.add(day)
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
            ServerScoringSettings.markOverlayLive(ServerScoringSettings.prefs(appContext),
                ServerScoringSettings.overlayIsLive(cache))
            store.upsert(cache)
            _lastFetchedAtMs.value = cache.fetchedAtMs
            _lastError.value = null
        }.onFailure { err ->
            if (err is CancellationException) throw err
            synchronizeOwner()
            if (!session.isCurrentRequest(day, generation, currentOwnerId(), request)) return
            if (err is ServerScoreClient.Unauthorized) {
                if (!clearCredentialIfCurrent(err.accessToken, owner)) return
                _signedIn.value = false
                session.activate(null)
                _lastError.value = "Enrollment expired — enter a fresh code"
            } else {
                _lastError.value = "Server scores unavailable"
                store.load(owner, day)?.let { session.accept(it, generation, currentOwnerId(), request) }
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
        if (session.ownerId() == current && activeIdentityKey == identity) return
        activeIdentityKey = identity
        stopPolling()
        session.activate(current)
        _signedIn.value = current != null
        _lastFetchedAtMs.value = null
        _lastError.value = null
        _sleepEditMessage.value = null
        preloadRecentDays()
    }
}
