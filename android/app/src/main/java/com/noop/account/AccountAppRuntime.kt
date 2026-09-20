package com.noop.account

import android.content.Context
import android.util.Log
import com.noop.ble.SourceCoordinator
import com.noop.ble.SourceIdentity
import com.noop.ble.WhoopBleClient
import com.noop.ble.WhoopModel
import com.noop.data.DeviceRegistry
import com.noop.data.WhoopDatabase
import com.noop.data.WhoopRepository
import com.noop.ui.NoopPrefs
import com.noop.push.*
import com.noop.testcentre.ImuSessionFileStore
import kotlinx.coroutines.*

/** Every handle and closure in this object belongs to one immutable account session. */
class AccountAppRuntime(val context: AccountStorageContext) {
    val identity get() = context.identity
    val database = WhoopDatabase.get(context)
    val scoringInputs = ScoringInputRuntime(context)
    val scoringContextConsent = ScoringContextConsent(context, capture = { scoringSettings.captureConsent() })
    val gpsSession = com.noop.location.AccountGpsSession(context)
    private val applicationScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    @Volatile private var scoringDeviceId: String? = null
    val scoringSettings = ScoringSettingsSync(context, scoringInputs, applicationScope, source = {
        val selected = if (coordinatorHandle.isInitialized()) coordinatorHandle.value.activeDeviceId.value else scoringDeviceId
        selected?.let { scoringInputs.captureSource(it) }
    })
    @Volatile var closed = false
        private set
    val ble: WhoopBleClient get() = bleHandle.value
    val sourceCoordinator: SourceCoordinator get() = coordinatorHandle.value

    init { context.runtime = this; scoringSettings.start() }

    fun start() {
        applicationScope.launch {
            try {
                database.openHelper.writableDatabase
                identity.context?.let { captured ->
                    if (closed || !CloudAuthClient.isCurrent(context, captured)) return@launch
                    AccountPushCaptureBindings.bind(database, captured.scope,
                        SelfHostedPushSettings.from(context).sourceId(), ImuSessionFileStore(context))
                    if (repository.hasOwedSyncJobs()) ble.resumeOwedPostBackfillWork()
                    SelfHostedPushScheduler.enqueueLaunchCatchUp(context)
                    scoringContextConsent.load()
                    // Input APIs and the worker also recover under the same DB ordering barrier.
                    runCatching { scoringInputs.recoverConsent() }
                    ScoringInputWorker.enqueue(context)
                    com.noop.ui.BackupSync.reschedule(context)
                    com.noop.ui.DebugExportScheduler.reschedule(context)
                    com.noop.ui.CoachBriefScheduler.reschedule(context)
                }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { Log.w("AccountRuntime", "Account storage initialization deferred") }
        }
    }

    fun close() {
        closed = true
        scoringSettings.retire()
        database.retireWrites()
        scoringInputs.retire()
        scoringContextConsent.retire()
        if (serverScoreHandle.isInitialized()) serverScoreHandle.value.retire()
        gpsSession.retire()
        if (coordinatorHandle.isInitialized()) runCatching { coordinatorHandle.value.shutdown() }
        if (bleHandle.isInitialized()) {
            bleHandle.value.setWhoopIsActiveDevice(false)
            runCatching { bleHandle.value.disconnect() }
            runCatching { bleHandle.value.shutdown() }
        }
        applicationScope.cancel()
        // Keep the writer bound to its original files; delayed callbacks cannot enter a new DB.
    }

    /** One captured account store shared by this runtime's UI and BLE service. */
    val repository: WhoopRepository by lazy {
        WhoopRepository(database)
    }

    /** Opt-in server readback; local scoring stays enabled until metric activation is verified. */
    val serverScoreRepository: ServerScoreRepository get() = serverScoreHandle.value
    private val serverScoreHandle = lazy {
        ServerScoreRepository(context, applicationScope).also { repo ->
            if (ServerScoringSettings.isEnabled(context)) {
                applicationScope.launch {
                    val today = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US)
                        .format(java.util.Date())
                    repo.startPolling(today)
                }
            }
        }
    }

    /** Process-wide device registry over the same Room DB — the single source of the active device id. */
    val deviceRegistry: DeviceRegistry by lazy { DeviceRegistry(database) }

    /**
     * Active device id, resolved once at startup from the registry and falling back to the legacy
     * "my-whoop" if the registry has none yet. Read with a guarded blocking call — a one-off indexed
     * `LIMIT 1` query at composition time. Any failure (e.g. an early read before migration) is swallowed
     * and falls back, so startup can never be broken by this.
     *
     * #1303: NOT a `by lazy`. Serial adoption re-points the ACTIVE device mid-process, and a lazy is
     * frozen for the life of the process — so every consumer below kept the pre-adoption id until the next
     * cold start, and the engine went on deriving days under it. Field-confirmed on a 5/MG: the registry
     * read `whoop-<serial>` while the diagnostics export, and the scoring pass, still used the old
     * address-based id, splitting the computed history across both until the phone was restarted. Adoption
     * now calls [onActiveDeviceAdopted] and the handle follows within the process.
     */
    @Volatile
    var activeDeviceId: String = ""
        get() {
            if (field.isEmpty()) {
                field = runCatching { runBlocking { deviceRegistry.activeDeviceId() } }
                    .onFailure { Log.w("NoopApplication", "activeDeviceId resolve failed; using fallback", it) }
                    .getOrNull() ?: WhoopBleClient.DEFAULT_DEVICE_ID
            }
            scoringDeviceId = field
            return field
        }
        private set

    /**
     * Point this process at the id a strap just adopted (#1303).
     *
     * Only the handle moves: the registry write and the row migration have already happened inside
     * `adoptSerialIdentity`, and the BLE client is re-pointed by its own caller. Kept narrow and
     * idempotent so a reconnect that re-adopts the same id costs nothing.
     */
    fun onActiveDeviceAdopted(newId: String) {
        if (newId.isNotEmpty() && newId != activeDeviceId) activeDeviceId = newId
        if (newId.isNotEmpty()) scoringDeviceId = newId
    }

    /**
     * The id the BLE client should stamp WHOOP samples with at startup (#1881).
     *
     * [activeDeviceId] answers "which device did the user select", which is NOT the same question once a
     * non-WHOOP device can be active: handing it to the client made every WHOOP live sample and historical
     * chunk persist under, say, an Oura ring. `adoptSourceIdentity` corrects the id when a strap actually
     * connects, but not for the window between construction and that connect, so the wrong value must not
     * be adopted in the first place.
     *
     * Fail-open: an unreadable registry or an unclassifiable row keeps today's behaviour. Only a
     * POSITIVELY non-WHOOP active device falls back to the legacy id. Swift twin: `BLEManager.bootstrapStore`.
     */
    private fun whoopStartupDeviceId(): String {
        val id = activeDeviceId
        val rows = runCatching { runBlocking { deviceRegistry.all() } }.getOrNull() ?: return id
        val row = rows.firstOrNull { it.id == id } ?: return id
        return if (SourceIdentity.isWhoop(row)) id else WhoopBleClient.DEFAULT_DEVICE_ID
    }

    /** Process-wide BLE client. Owns the GATT connection and outlives any single Activity/ViewModel. */
    private val bleHandle = lazy {
        val startupId = whoopStartupDeviceId()
        WhoopBleClient(
            context,
            repository = repository,
            deviceId = startupId,
            successfulOffloadSink = {
                SelfHostedPushScheduler.enqueueAfterSuccessfulOffload(context)
            },
        ).apply {
            // #1881: the same fact seeds the connect gate, closing the launch race where the radio can
            // reach the WHOOP flow before SourceCoordinator has wired up and asserted it.
            if (startupId != activeDeviceId) setWhoopIsActiveDevice(false)
            // Apply the persisted "Debug logging" preference at the composition root so the low-level
            // client never has to read the UI/prefs layer. Default OFF — see WhoopBleClient.debugLogcat.
            debugLogcat = NoopPrefs.debugLogging(context)
        }
    }

    /**
     * Multi-source coordinator (Phase 1B): runs exactly one device's live BLE at a time, driven by the
     * registry's active device id. DORMANT whenever the active device is the WHOOP (the default and every
     * single-WHOOP install), so the existing WHOOP flow is untouched. Only when a non-WHOOP generic HR
     * strap becomes active does it pause WHOOP and run the isolated [com.noop.ble.StandardHrSource].
     *
     * Wired to the EXISTING [ble] entry points via closures — it never touches [WhoopBleClient]
     * internals. Strap live HR is pushed into the same [ble] state flow the UI observes via
     * [WhoopBleClient.publishExternalLiveHr]. [SourceCoordinator.start] reconciles once against the
     * current active id at launch (a no-op for a single-WHOOP install); the Devices screen (next task)
     * calls [SourceCoordinator.onActiveDeviceChanged] after a setActive.
     *
     * Multi-WHOOP identity adoption: AppViewModel's init collects [WhoopBleClient.connectedPeripheralAddress]
     * (distinctUntilChanged) into [SourceCoordinator.connectedPeripheralChanged] — the Kotlin analogue of
     * macOS wiring `BLEManager.connectedPeripheralUUID` into the coordinator's adoption sink. Kept beside
     * the other `ble`-flow collectors there (this Application owns no CoroutineScope of its own).
     */
    private val coordinatorHandle = lazy {
        SourceCoordinator(
            context = context,
            registry = deviceRegistry,
            repository = repository,
            liveSink = { hr, rr -> ble.publishExternalLiveHr(hr, rr) },
            // #74: reconnect on the PERSISTED family, not the WhoopModel.WHOOP4 default - otherwise a
            // 5/MG WHOOP->WHOOP switch rescans the wrong service and misses the 5/MG direct-bond fast
            // path (status=133 on an OS-bonded strap). Mirrors macOS AppModel.scan() reading the persisted
            // "selectedWhoopModel". Same-strap switches now adopt in place (no reconnect) via the
            // coordinator, so this only fires for a genuinely different WHOOP.
            // #1881: the flag rides the SAME two closures, so it inherits the coordinator's semantics
            // exactly. `stopWhoop` alone was edge-triggered: it dropped the link once and nothing stopped
            // `onBluetoothRadioOn` bringing it straight back — every Bluetooth toggle reached it, and it
            // clears `intentionalDisconnect` before reconnecting. Swift twin: AppModel.wireSourceCoordinator.
            startWhoop = { ble.setWhoopIsActiveDevice(true); ble.connect(persistedWhoopModel()) },
            stopWhoop = { ble.setWhoopIsActiveDevice(false); ble.disconnect() },
            // Multi-WHOOP (MW-2/MW-3): pin the connection to the active WHOOP's persisted address and
            // re-attribute live samples to it on a WHOOP→WHOOP switch. Both inert on the single-WHOOP
            // path — the coordinator only invokes them for a non-legacy WHOOP / a non-null peripheralId.
            setWhoopPreferredAddress = { addr -> ble.preferredAddress = addr },
            setWhoopActiveDeviceId = { id -> ble.setActiveDeviceId(id) },
            // Generic-HR connect lifecycle → the SAME in-app strap log the user exports, so a
            // "connected but no data" report (issue #421) is no longer blind to the Polar/Wahoo/etc path.
            straplog = { ble.externalLog(it) },
            // A generic strap's standard battery (0x180F) → the same live battery field the WHOOP uses.
            batterySink = { pct -> ble.publishExternalBattery(pct) },
            initialActiveDeviceId = activeDeviceId,
        )
    }

    /** The WHOOP family last seen advertising, persisted by [WhoopBleClient.persistSelectedModel] under
     *  "noop.selectedWhoopModel" in the shared noop_prefs store. Defaults to [WhoopModel.WHOOP4] when
     *  unset or unparseable (the historical connect() default), so a fresh install is unchanged. Used to
     *  reconnect on the right service after a WHOOP->WHOOP switch (#74). */
    private fun persistedWhoopModel(): WhoopModel =
        NoopPrefs.of(context).getString("noop.selectedWhoopModel", null)
            ?.let { runCatching { WhoopModel.valueOf(it) }.getOrNull() }
            ?: WhoopModel.WHOOP4

}
