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
    const val ALGORITHM_VERSION = "frwhoop-server-1"
    /** Foreground idle push cadence when server scoring is on (spec: 30–60 s). */
    const val IDLE_PUSH_INTERVAL_MS = 45_000L
    /** During an active offload, flush push at most once per this interval (spec: ≤10 s). */
    const val SYNC_PUSH_INTERVAL_MS = 10_000L

    // Android has not activated complete per-metric server ownership yet.
    fun skipsSyncCoupledRescore(context: Context): Boolean = false

    fun prefs(context: Context): SharedPreferences =
        com.noop.account.AccountStorageContext.capture(context).getSharedPreferences("noop_server_scoring", Context.MODE_PRIVATE)

    fun isEnabled(context: Context): Boolean =
        prefs(context).getBoolean(DEFAULTS_KEY, false)

    fun setEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(DEFAULTS_KEY, enabled).apply()
    }

    fun authEmail(context: Context): String =
        prefs(context).getString(AUTH_EMAIL_KEY, "") ?: ""

    fun setAuthEmail(context: Context, email: String) {
        prefs(context).edit().putString(AUTH_EMAIL_KEY, email.trim()).apply()
    }

    fun supabaseProjectUrl(): String? {
        val endpoint = SelfHostedPushSettings.endpointText().trim().removeSuffix("/")
        if (!endpoint.endsWith("/functions/v1/push")) return null
        return endpoint.removeSuffix("/functions/v1/push")
    }

    fun anonKey(): String? =
        BuildConfig.NOOP_SUPABASE_ANON_KEY.trim().takeIf { it.isNotEmpty() }

    fun ready(context: Context): Boolean =
        isEnabled(context) && supabaseProjectUrl() != null && anonKey() != null
}
