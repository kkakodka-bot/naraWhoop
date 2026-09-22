package com.noop.push

import android.content.Context
import android.content.SharedPreferences
import com.noop.BuildConfig
import java.security.MessageDigest
import java.util.UUID

/** Account-scoped state; installation-wide toggles remain policy only. */
class SelfHostedPushSettings private constructor(
    private val prefs: SharedPreferences,
    private val bundleEndpoint: String,
    private val tokenProvider: () -> String?,
    private val policyPrefs: SharedPreferences = prefs,
    val capturedContext: AccountSessionContext? = null,
    private val stillCurrent: () -> Boolean = { true },
    private val consentCurrent: () -> Boolean = { true },
) {
    enum class RunState { IDLE, QUEUED, RUNNING, CONTINUING, RETRYING, COMPLETE, FAILED }

    data class Snapshot(
        val enabled: Boolean,
        val wifiOnly: Boolean,
        val binaryObjectsEnabled: Boolean,
        val endpoint: PushEndpointPolicy.ValidEndpoint?,
        val hasToken: Boolean,
        val lastSuccessAt: Long?,
        val lastError: String?,
        val runState: RunState,
        val acceptedBatches: Int,
        val acceptedRecords: Long,
        val currentStream: String?,
        val supportedStreams: List<String>?,
        val capabilitiesCheckedAt: Long?,
    ) {
        val ready: Boolean get() = enabled && endpoint != null && hasToken
    }

    fun snapshot(): Snapshot {
        val enabled = prefs.getBoolean(KEY_ENABLED, DEFAULT_ENABLED) && consentCurrent()
        val endpoint = (PushEndpointPolicy.validate(endpointText()) as? PushEndpointPolicy.Result.Valid)?.endpoint
        val capabilities = capabilitiesFor(endpoint)
        return Snapshot(
            enabled = enabled,
            wifiOnly = wifiOnly(),
            binaryObjectsEnabled = binaryObjectsEnabled(),
            endpoint = endpoint,
            hasToken = token() != null,
            lastSuccessAt = prefs.getLong(KEY_LAST_SUCCESS, 0L).takeIf { it > 0 },
            lastError = prefs.getString(KEY_LAST_ERROR, null),
            runState = if (!enabled) RunState.IDLE else runCatching {
                RunState.valueOf(prefs.getString(KEY_RUN_STATE, RunState.IDLE.name).orEmpty())
            }.getOrDefault(RunState.IDLE),
            acceptedBatches = prefs.getInt(KEY_ACCEPTED_BATCHES, 0).coerceAtLeast(0),
            acceptedRecords = prefs.getLong(KEY_ACCEPTED_RECORDS, 0L).coerceAtLeast(0L),
            currentStream = prefs.getString(KEY_CURRENT_STREAM, null),
            supportedStreams = capabilities,
            capabilitiesCheckedAt = prefs.getLong(KEY_CAPABILITIES_AT, 0L)
                .takeIf { it > 0 && capabilities != null },
        )
    }

    fun endpointText(): String = bundleEndpoint
    fun wifiOnly(): Boolean = policyPrefs.getBoolean(KEY_WIFI_ONLY, true)
    fun binaryObjectsEnabled(): Boolean = policyPrefs.getBoolean(KEY_BINARY_OBJECTS, DEFAULT_BINARY_OBJECTS)

    fun setWifiOnly(wifiOnly: Boolean) {
        check(policyPrefs.edit().putBoolean(KEY_WIFI_ONLY, wifiOnly).commit()) {
            "Could not persist push network policy"
        }
    }

    fun setBinaryObjectsEnabled(enabled: Boolean) {
        check(policyPrefs.edit().putBoolean(KEY_BINARY_OBJECTS, enabled).commit()) {
            "Could not persist push binary export setting"
        }
    }

    /** Plain-pref gate used by stale workers before opening Room or Android Keystore. */
    fun enabledEndpoint(): PushEndpointPolicy.ValidEndpoint? {
        if (!prefs.getBoolean(KEY_ENABLED, DEFAULT_ENABLED) || !consentCurrent() || !stillCurrent()) return null
        return (PushEndpointPolicy.validate(endpointText()) as? PushEndpointPolicy.Result.Valid)?.endpoint
    }

    fun token(): String? = if (stillCurrent()) tokenProvider()?.takeIf { it.isNotBlank() } else null
    fun isCurrent(): Boolean = stillCurrent()

    /** Stable, non-secret receiver namespace. Generated only after the worker's stale-work gates pass. */
    @Synchronized
    fun sourceId(): String = synchronized(statusLock) {
        prefs.getString(KEY_SOURCE_ID, null)?.let { existing ->
            runCatching { UUID.fromString(existing) }.getOrNull()?.let { return it.toString() }
        }
        val generated = UUID.randomUUID().toString()
        check(prefs.edit().putString(KEY_SOURCE_ID, generated).commit()) { "Could not persist push source id" }
        return generated
    }

    fun setEnabled(enabled: Boolean): Boolean = synchronized(statusLock) {
        if (enabled && !snapshot().copy(enabled = true).ready) return@synchronized false
        check(prefs.edit().putBoolean(KEY_ENABLED, enabled).commit()) { "Could not persist push policy" }
        val edit = prefs.edit()
        if (!enabled) edit.putString(KEY_RUN_STATE, RunState.IDLE.name)
            .remove(KEY_LAST_ERROR).remove(KEY_CURRENT_STREAM)
        check(edit.commit()) { "Could not persist push enabled state" }
        true
    }

    fun progressNamespace(
        sourceId: String,
        endpoint: PushEndpointPolicy.ValidEndpoint,
        protocolVersion: String = PushProtocol.VERSION,
        receiverStateId: String = PushCapabilities.UNSCOPED_RECEIVER_STATE_ID,
    ): String =
        MessageDigest.getInstance("SHA-256").digest(
            ("push-v2\u0000" + (capturedContext?.scope?.namespace ?: "unassigned") + "\u0000" +
                sourceId + "\u0000" + endpoint.url + "\u0000" + (if (protocolVersion == "1.4") "1.3" else protocolVersion) + "\u0000" + receiverStateId).toByteArray(Charsets.UTF_8),
        )
            .joinToString("") { "%02x".format(it) }

    fun recordSuccess(atMillis: Long = System.currentTimeMillis()) = updateWhileEnabled {
        it.putLong(KEY_LAST_SUCCESS, atMillis).remove(KEY_LAST_ERROR)
            .remove(KEY_CURRENT_STREAM)
            .putString(KEY_RUN_STATE, RunState.COMPLETE.name)
    }

    fun recordError(message: String) = updateWhileEnabled {
        it.putString(KEY_LAST_ERROR, message.take(MAX_STATUS_CHARS))
            .putString(KEY_RUN_STATE, RunState.FAILED.name)
    }

    /** Starts a new logical catch-up. Continuation workers deliberately do not reset these counters. */
    fun recordPushStarted() = updateWhileEnabled {
        it.remove(KEY_LAST_ERROR)
            .remove(KEY_CURRENT_STREAM)
            .putInt(KEY_ACCEPTED_BATCHES, 0).putLong(KEY_ACCEPTED_RECORDS, 0L)
            .putString(KEY_RUN_STATE, RunState.QUEUED.name)
    }

    fun recordRunning() = updateWhileEnabled { it.putString(KEY_RUN_STATE, RunState.RUNNING.name) }

    fun recordCurrentStream(stream: String) = updateWhileEnabled {
        require(stream in PushCapabilities.ALL.wireNames) { "unknown push stream" }
        if (prefs.getString(KEY_CURRENT_STREAM, null) == stream) return@updateWhileEnabled it
        it.putString(KEY_CURRENT_STREAM, stream)
    }

    fun recordCapabilities(
        endpoint: PushEndpointPolicy.ValidEndpoint,
        capabilities: PushCapabilities,
        atMillis: Long = System.currentTimeMillis(),
    ) = synchronized(statusLock) {
        check(prefs.edit()
            .putString(KEY_CAPABILITIES_ENDPOINT, endpoint.url)
            .putString(KEY_CAPABILITIES_STREAMS, capabilities.wireNames.joinToString(","))
            .putLong(KEY_CAPABILITIES_AT, atMillis)
            .commit()) { "Could not persist receiver capabilities" }
    }

    @Synchronized
    fun recordAcceptedBatches(batches: Int, records: Long = 0L) = synchronized(statusLock) {
        if (batches <= 0 && records <= 0) return
        if (!stillCurrent() || !consentCurrent() || !prefs.getBoolean(KEY_ENABLED, DEFAULT_ENABLED)) return
        check(prefs.edit()
            .putInt(
                KEY_ACCEPTED_BATCHES,
                prefs.getInt(KEY_ACCEPTED_BATCHES, 0).coerceAtLeast(0) + batches.coerceAtLeast(0),
            )
            .putLong(
                KEY_ACCEPTED_RECORDS,
                prefs.getLong(KEY_ACCEPTED_RECORDS, 0L).coerceAtLeast(0L) + records.coerceAtLeast(0L),
            )
            .commit()) { "Could not persist push progress" }
    }

    /** Pagination and device rotation are healthy progress, never an error. */
    fun recordContinuation() = updateWhileEnabled {
        it.remove(KEY_LAST_ERROR).remove(KEY_CURRENT_STREAM)
            .putString(KEY_RUN_STATE, RunState.CONTINUING.name)
    }

    fun recordRetrying(message: String) = updateWhileEnabled {
        it.putString(KEY_LAST_ERROR, message.take(MAX_STATUS_CHARS))
            .putString(KEY_RUN_STATE, RunState.RETRYING.name)
    }

    private inline fun updateWhileEnabled(change: (SharedPreferences.Editor) -> SharedPreferences.Editor) =
        synchronized(statusLock) {
            if (!stillCurrent() || !consentCurrent() || !prefs.getBoolean(KEY_ENABLED, DEFAULT_ENABLED)) return@synchronized
            check(change(prefs.edit()).commit()) { "Could not persist push status" }
        }

    private fun capabilitiesFor(endpoint: PushEndpointPolicy.ValidEndpoint?): List<String>? {
        if (endpoint == null || prefs.getString(KEY_CAPABILITIES_ENDPOINT, null) != endpoint.url) return null
        if (!prefs.contains(KEY_CAPABILITIES_STREAMS)) return null
        val encoded = prefs.getString(KEY_CAPABILITIES_STREAMS, "").orEmpty()
        if (encoded.isEmpty()) return emptyList()
        val names = encoded.split(',')
        val known = PushCapabilities.ALL.wireNames.toSet()
        return names.takeIf { it.size == it.distinct().size && it.all(known::contains) }
    }

    fun nextDeviceIndex(namespace: String): Int = prefs.getInt("$KEY_NEXT_DEVICE.$namespace", 0).coerceAtLeast(0)

    fun saveNextDeviceIndex(namespace: String, index: Int) {
        require(index >= 0)
        prefs.edit().putInt("$KEY_NEXT_DEVICE.$namespace", index).apply()
    }

    fun cycleNeedsAnotherPass(namespace: String): Boolean =
        prefs.getBoolean("$KEY_CYCLE_MORE.$namespace", false)

    fun saveCycleNeedsAnotherPass(namespace: String, needed: Boolean) {
        prefs.edit().putBoolean("$KEY_CYCLE_MORE.$namespace", needed).apply()
    }

    fun cycleHadRejection(namespace: String): Boolean = prefs.getBoolean("$KEY_CYCLE_REJECTED.$namespace", false)

    fun saveCycleHadRejection(namespace: String, rejected: Boolean) {
        prefs.edit().putBoolean("$KEY_CYCLE_REJECTED.$namespace", rejected).apply()
    }

    /** Persists only a safe category/status, never an exception message or response body. */
    fun cycleFailure(namespace: String): PushFailure? {
        val code = prefs.getString("$KEY_CYCLE_FAILURE_CODE.$namespace", null)
            ?.let { stored -> PushFailureCode.entries.firstOrNull { it.name == stored } }
            ?: return null
        val status = prefs.getInt("$KEY_CYCLE_FAILURE_STATUS.$namespace", 0)
            .takeIf { it in 100..599 }
        val receiverCode = prefs.getString("$KEY_CYCLE_FAILURE_RECEIVER_CODE.$namespace", null)
            ?.takeIf { it.matches(Regex("[a-z][a-z0-9_]{0,63}")) }
        return PushFailure(code, status, receiverCode)
    }

    fun saveCycleFailure(namespace: String, failure: PushFailure?) {
        val editor = prefs.edit()
        if (failure == null) {
            editor.remove("$KEY_CYCLE_FAILURE_CODE.$namespace")
                .remove("$KEY_CYCLE_FAILURE_STATUS.$namespace")
                .remove("$KEY_CYCLE_FAILURE_RECEIVER_CODE.$namespace")
        } else {
            editor.putString("$KEY_CYCLE_FAILURE_CODE.$namespace", failure.code.name)
            failure.httpStatus?.let {
                editor.putInt("$KEY_CYCLE_FAILURE_STATUS.$namespace", it)
            } ?: editor.remove("$KEY_CYCLE_FAILURE_STATUS.$namespace")
            failure.receiverCode?.let {
                editor.putString("$KEY_CYCLE_FAILURE_RECEIVER_CODE.$namespace", it)
            } ?: editor.remove("$KEY_CYCLE_FAILURE_RECEIVER_CODE.$namespace")
        }
        check(editor.commit()) { "Could not persist push failure category" }
    }

    companion object {
        private const val PREFS = "self_hosted_push"
        private const val KEY_ENABLED = "enabled"
        private const val DEFAULT_ENABLED = true
        private const val KEY_BINARY_OBJECTS = "binary_objects_enabled"
        private const val DEFAULT_BINARY_OBJECTS = true
        private const val KEY_WIFI_ONLY = "wifi_only"
        private const val KEY_SOURCE_ID = "source_id"
        private const val KEY_LAST_SUCCESS = "last_success_at"
        private const val KEY_LAST_ERROR = "last_error"
        private const val KEY_RUN_STATE = "run_state"
        private const val KEY_ACCEPTED_BATCHES = "accepted_batches"
        private const val KEY_ACCEPTED_RECORDS = "accepted_records"
        private const val KEY_CURRENT_STREAM = "current_stream"
        private const val KEY_CAPABILITIES_ENDPOINT = "capabilities_endpoint"
        private const val KEY_CAPABILITIES_STREAMS = "capabilities_streams"
        private const val KEY_CAPABILITIES_AT = "capabilities_at"
        private const val KEY_NEXT_DEVICE = "next_device"
        private const val KEY_CYCLE_MORE = "cycle_more"
        private const val KEY_CYCLE_REJECTED = "cycle_rejected"
        private const val KEY_CYCLE_FAILURE_CODE = "cycle_failure_code"
        private const val KEY_CYCLE_FAILURE_STATUS = "cycle_failure_status"
        private const val KEY_CYCLE_FAILURE_RECEIVER_CODE = "cycle_failure_receiver_code"
        private const val MAX_STATUS_CHARS = 300
        private val statusLock = Any()

        fun endpointText(): String = BuildConfig.NOOP_PUSH_ENDPOINT.trim()

        fun from(context: Context): SelfHostedPushSettings {
            val app = com.noop.account.AccountStorageContext.platform(context)
            val captured = (context as? com.noop.account.AccountStorageContext)?.identity?.context
                ?: if (context is com.noop.account.AccountStorageContext) null else CloudAuthClient.identitySnapshot(app).context
            return SelfHostedPushSettings(
                app.getSharedPreferences(PREFS + ".account." + (captured?.scope?.namespace ?: "unassigned"), Context.MODE_PRIVATE),
                captured?.scope?.projectURL?.plus("/functions/v1/push") ?: endpointText(),
                tokenProvider = { CloudAuthClient.storedSession(app)?.takeIf { it.scope == captured?.scope }?.accessToken },
                policyPrefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE),
                capturedContext = captured,
                stillCurrent = { captured != null && CloudAuthClient.isCurrent(app, captured) },
                consentCurrent = {
                    captured != null && com.noop.ui.NoopPrefs.of(
                        com.noop.account.AccountStorageContext(app,
                            AccountIdentitySnapshot(captured.scope.projectURL, captured.scope, captured.generation)))
                        .getString(com.noop.ui.NoopPrefs.KEY_ACCEPTED_TERMS_VERSION, "") == com.noop.ui.Terms.CURRENT_VERSION
                },
            )
        }

        internal fun forTest(
            prefs: SharedPreferences,
            bundleEndpoint: String = "",
            bundleToken: String = "",
        ) = SelfHostedPushSettings(prefs, bundleEndpoint, { bundleToken })
    }
}
