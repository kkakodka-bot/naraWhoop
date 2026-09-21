package com.noop.push

import android.content.Context
import android.content.SharedPreferences
import com.noop.BuildConfig

/** Phase 4: server HRV/sleep readback. Default on for this fork. */
object ServerScoringSettings {
    const val DEFAULTS_KEY = "noop.serverScoring"
    const val AUTH_EMAIL_KEY = "noop.serverScoring.authEmail"
    const val POLL_INTERVAL_SECONDS = 60L
    const val STALE_AFTER_SECONDS = 6 * 60 * 60L
    const val ALGORITHM_VERSION = "frwhoop-physiology-2"
    const val OVERLAY_LIVE_KEY = "noop.serverScoring.overlayLive"
    /** Foreground idle push cadence when server scoring is on (spec: 30–60 s). */
    const val IDLE_PUSH_INTERVAL_MS = 45_000L
    /** During an active offload, flush push at most once per this interval (spec: ≤10 s). */
    const val SYNC_PUSH_INTERVAL_MS = 10_000L

    fun skipsSyncCoupledRescore(context: Context): Boolean = skipsSyncCoupledRescore(prefs(context))
    // A server physiology snapshot does not cover the whole local analysis pass or its history.
    // Preserve the existing coalesced/fingerprint-gated schedule for the remaining local metrics.
    @Suppress("UNUSED_PARAMETER")
    fun skipsSyncCoupledRescore(prefs: SharedPreferences): Boolean = false

    fun overlayLive(prefs: SharedPreferences): Boolean = prefs.getBoolean(OVERLAY_LIVE_KEY, false)
    fun markOverlayLive(prefs: SharedPreferences, live: Boolean) {
        prefs.edit().putBoolean(OVERLAY_LIVE_KEY, live).apply()
    }
    fun overlayIsLive(cache: ServerScoreDayCache): Boolean =
        cache.daily != null && !cache.stale && cache.features.values.any { it.status == "available" && it.hasCanonicalAuthorization }

    fun prefs(context: Context): SharedPreferences =
        com.noop.account.AccountStorageContext.capture(context)
            .getSharedPreferences("noop_server_scoring", Context.MODE_PRIVATE)

    fun isEnabled(context: Context): Boolean =
        isEnabled(prefs(context))
    fun isEnabled(prefs: SharedPreferences): Boolean = prefs.getBoolean(DEFAULTS_KEY, true)

    fun setEnabled(context: Context, enabled: Boolean) {
        setEnabled(prefs(context), enabled)
    }
    fun setEnabled(prefs: SharedPreferences, enabled: Boolean) { prefs.edit().putBoolean(DEFAULTS_KEY, enabled).apply() }

    fun authEmail(context: Context): String =
        prefs(context).getString(AUTH_EMAIL_KEY, "") ?: ""

    fun setAuthEmail(context: Context, email: String) {
        prefs(context).edit().putString(AUTH_EMAIL_KEY, email.trim()).apply()
    }

    fun supabaseProjectUrl(): String? {
        val endpoint = SelfHostedPushSettings.endpointText().ifBlank { BuildConfig.NOOP_PUSH_ENDPOINT }
            .trim().removeSuffix("/")
        if (!endpoint.endsWith("/functions/v1/push")) return null
        return endpoint.removeSuffix("/functions/v1/push")
    }

    fun anonKey(): String? =
        BuildConfig.NOOP_SUPABASE_ANON_KEY.trim().takeIf { it.isNotEmpty() }

    fun enrollmentReady(context: Context): Boolean =
        SelfHostedPushSettings.from(context).fleetToken() != null &&
            EnrollmentDataScope.credential(context) != null

    fun accountReady(context: Context): Boolean =
        anonKey() != null && CloudAuthClient.identitySnapshot(context).context != null

    fun ready(context: Context): Boolean =
        isEnabled(context) && supabaseProjectUrl() != null && (enrollmentReady(context) || accountReady(context))
}
