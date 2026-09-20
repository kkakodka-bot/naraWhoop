package com.noop.ui

import android.content.SharedPreferences

/** Setup may finish offline; readiness is durable only after the exact device link was acknowledged. */
internal object OnboardingCompletion {
    fun record(prefs: SharedPreferences, deviceConfirmed: Boolean, version: String): Boolean {
        if (!deviceConfirmed) return false
        check(prefs.edit().putBoolean(NoopPrefs.KEY_ONBOARDED, true)
            .putString(NoopPrefs.KEY_LAST_SEEN_CHANGELOG, version).commit())
        return true
    }
}
