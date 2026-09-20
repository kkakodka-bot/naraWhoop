package com.noop.location

import com.noop.analytics.RouteMath
import com.noop.analytics.RouteMath.LatLng
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import com.noop.account.AccountStorageContext
import com.noop.account.AccountWriteFence
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Legacy test facade; production owns an AccountGpsSession per immutable runtime. */
object GpsSession : AccountGpsSession()

/** The foreground service feeds this captured owner. Published points have committed to its journal.
 * The live track is bounded; finishing reads the complete route off-main and retains it until saved. */
open class AccountGpsSession(private val account: AccountStorageContext? = null) {
    @Volatile private var retired = false
    private val fence = account?.let(::AccountWriteFence)
    private val mutex = Mutex()
    private var loaded = false
    private var journal: AccountGpsJournal? = null
    private val retirement = CompletableDeferred<Unit>()

    /** A GPS workout's accumulated route. [startMs] anchors pace; [active] gates the service collector.
     *  [sportName] lets the UI rehydrate the active-workout card if the ViewModel was cleared mid-ride. */
    data class State(
        val active: Boolean = false,
        val startMs: Long = 0L,
        val sportName: String = "",
        val track: List<LatLng> = emptyList(),
        val distanceM: Double = 0.0,
        val paceSecPerKm: Double? = null,
        val paused: Boolean = false,
        val pausedAtMs: Long? = null,
        val pausedDurationMs: Long = 0L,
        val sessionId: String? = null,
        val deviceId: String? = null,
        val endMs: Long? = null,
        val pointCount: Int = 0,
        val storageBlocked: Boolean = false,
    )

    private val _state = MutableStateFlow(State())
    /** The live route, observed by the UI (via AppViewModel) and the service's collect-gate. */
    val state: StateFlow<State> = _state.asStateFlow()

    /** Workouts & GPS test mode (Test Centre): the tagged sink for the .workouts GPS-fix lines, wired by
     *  [com.noop.ble.WhoopConnectionService] (which holds the BLE client + the gate). Default null (inert) so
     *  the route fold is byte-identical when the mode is off. The service ALWAYS checks the WORKOUTS gate
     *  before setting this, so [append] pays nothing extra when off. Diagnostic only - it never changes the
     *  route. The Android LocationTracker pre-filters UPSTREAM, so every appended fix is already ACCEPTED and
     *  the raw pre-filter count is not available at this seam; the gps line passes rawFixes = null (reads
     *  `n/a`) rather than imply an accept rate the platform never measured (the macOS recorder, which sees
     *  the raw stream, passes a real count). L4. */
    var workoutsLog: ((String) -> Unit)? = null

    /** Begin a route for [sportName]'s workout started at [startMs]. A re-arm just resets the track. */
    fun start(startMs: Long, sportName: String) {
        if (retired) return
        check(account == null) { "Production GPS requires durable start" }
        _state.value = State(active = true, startMs = startMs, sportName = sportName)
    }

    /** Fold one accepted fix into the route, recomputing distance + pace. No-op when not active. */
    fun append(pt: LatLng) {
        if (retired) return
        check(account == null) { "Production GPS requires durable append" }
        val s = _state.value
        if (!s.active || s.paused) return
        val track = s.track + pt
        val dist = RouteMath.totalMeters(track)
        val secs = (System.currentTimeMillis() - s.startMs - s.pausedDurationMs) / 1000.0
        _state.value = s.copy(track = track, distanceM = dist, paceSecPerKm = RouteMath.paceSecPerKm(dist, secs))
        // Workouts & GPS test mode: one GPS-fix-progress line per accepted fix, only when the service wired a
        // sink (the WORKOUTS gate was on). The LocationTracker pre-filters UPSTREAM, so the raw pre-filter
        // count is not available at this seam (every fix here is already accepted). Pass rawFixes = null so
        // the line reads `rawFixes=n/a` instead of `rawFixes == accepted`, which would falsely imply a 100%
        // accept rate the platform never actually measured (macOS, which sees the raw stream, passes a real
        // count). L4.
        workoutsLog?.invoke(
            com.noop.analytics.WorkoutsTrace.gpsLine(
                rawFixes = null, acceptedPoints = track.size, distanceM = dist,
            ),
        )
    }

    /** End the route and clear it. Returns the final accumulated track for the saved WorkoutRow. */
    fun stop(): List<LatLng> {
        check(account == null) { "Production GPS requires durable settlement" }
        val track = _state.value.track
        _state.value = State()
        return track
    }

    fun pause() {
        if (retired) return
        check(account == null) { "Production GPS requires durable pause" }
        val s = _state.value
        if (s.active && !s.paused) _state.value = s.copy(paused = true, pausedAtMs = System.currentTimeMillis())
    }

    fun resume() {
        if (retired) return
        check(account == null) { "Production GPS requires durable resume" }
        val s = _state.value
        if (s.active && s.paused) {
            val added = s.pausedAtMs?.let { System.currentTimeMillis() - it } ?: 0L
            _state.value = s.copy(paused = false, pausedAtMs = null,
                pausedDurationMs = s.pausedDurationMs + added)
        }
    }

    @Synchronized fun retire() {
        if (retired) return
        retired = true
        fence?.retire()
        workoutsLog = null
        _state.value = State()
        val cleanup = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        cleanup.launch {
            try { mutex.withLock { journal?.close(); journal = null }; retirement.complete(Unit) }
            catch (failure: Throwable) { retirement.completeExceptionally(failure) }
            finally { cleanup.cancel() }
        }
    }

    suspend fun retireAndJoin() { retire(); retirement.await() }

    internal fun requireAccount(expected: AccountStorageContext) {
        val owned = checkNotNull(account)
        check(owned.identity == expected.identity && owned.root == expected.root && !retired)
    }

    private fun store(): AccountGpsJournal {
        check(!retired)
        return journal ?: AccountGpsJournal(checkNotNull(account), checkNotNull(fence)).also { journal = it }
    }

    private fun publish(s: AccountGpsJournal.Snapshot?, active: Boolean = false): State {
        val next = s?.let {
            State(active = active && it.endMs == null && it.pausedAtMs == null, startMs = it.startMs, sportName = it.sport,
                track = it.track.takeLast(AccountGpsJournal.DISPLAY_POINTS), distanceM = it.distanceM,
                paceSecPerKm = RouteMath.paceSecPerKm(it.distanceM,
                    ((it.endMs ?: it.pausedAtMs ?: System.currentTimeMillis()) - it.startMs - it.pausedDurationMs).coerceAtLeast(0) / 1000.0),
                paused = it.pausedAtMs != null, pausedAtMs = it.pausedAtMs, pausedDurationMs = it.pausedDurationMs,
                sessionId = it.id, deviceId = it.deviceId, endMs = it.endMs, pointCount = it.pointCount)
        } ?: State()
        checkNotNull(fence).commit { check(!retired); _state.value = next }
        return next
    }

    private suspend fun <T> durable(body: () -> T): T = withContext(Dispatchers.IO) {
        mutex.withLock {
            try { body() }
            catch (failure: Exception) {
                if (!retired) runCatching { checkNotNull(fence).commit {
                    _state.value = _state.value.copy(active = false, storageBlocked = true)
                } }
                throw failure
            }
        }
    }

    suspend fun recoverDurable(): State = durable {
        if (loaded) return@durable state.value
        val s = store().read()
        val recovered = s?.let { store().pause(it.id, System.currentTimeMillis(), recovering = true) }
        publish(recovered).also { loaded = true }
    }

    suspend fun startDurable(startMs: Long, sportName: String, deviceId: String): State = durable {
        publish(store().start(startMs, sportName, deviceId), active = true).also { loaded = true }
    }

    suspend fun appendDurable(pt: LatLng, expectedSessionId: String? = state.value.sessionId): Boolean = durable {
        val s = state.value
        if (retired || !s.active || s.paused || s.sessionId != expectedSessionId) return@durable false
        val saved = store().append(checkNotNull(s.sessionId), pt, System.currentTimeMillis())
        publish(saved, active = true)
        workoutsLog?.invoke(com.noop.analytics.WorkoutsTrace.gpsLine(rawFixes = null,
            acceptedPoints = saved.pointCount, distanceM = saved.distanceM))
        true
    }

    suspend fun pauseDurable(): State = durable {
        publish(store().pause(checkNotNull(state.value.sessionId), System.currentTimeMillis()))
    }

    suspend fun resumeDurable(): State = durable {
        if (state.value.storageBlocked) store().pause(checkNotNull(state.value.sessionId), System.currentTimeMillis(), recovering = true)
        publish(store().resume(checkNotNull(state.value.sessionId), System.currentTimeMillis()), active = true)
    }

    internal suspend fun finishDurable(): AccountGpsJournal.Snapshot = durable {
        store().finish(checkNotNull(state.value.sessionId), System.currentTimeMillis()).also { publish(it) }
    }

    internal suspend fun prepareFinalization(sessionId: String, nowMs: Long,
        admit: (AccountGpsJournal.Snapshot) -> Unit,
        build: (AccountGpsJournal.Snapshot) -> GpsWorkoutPayload): GpsWorkoutPayload = durable {
        store().finalization(sessionId)?.let { return@durable it }
        admit(checkNotNull(store().read()))
        val frozen = store().finish(sessionId, nowMs).also { publish(it) }
        store().freezeFinalization(build(frozen))
    }

    internal suspend fun settleFinalization(payload: GpsWorkoutPayload, beforeDelete: () -> Unit = {},
        durabilityView: (androidx.sqlite.db.SupportSQLiteDatabase) -> androidx.sqlite.db.SupportSQLiteDatabase = { it },
        destinationBarrier: com.noop.data.GpsDestinationDurabilityBarrier = com.noop.data.GpsDestinationDurabilityBarrier()) = durable {
        val bytes = payload.encode()
        GpsWorkoutFinalizer.settleCurrent(checkNotNull(account), payload, durabilityView, destinationBarrier) {
            beforeDelete()
            store().settle(payload.sessionId, expectedPayload = bytes)
        }
        publish(null)
    }

    suspend fun discardDurable(sessionId: String) = durable {
        store().settle(sessionId, explicitDiscard = true)
        publish(null)
    }
}
