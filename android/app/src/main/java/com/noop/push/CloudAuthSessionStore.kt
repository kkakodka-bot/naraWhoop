package com.noop.push

import android.content.SharedPreferences

/** Opaque credential storage; injected prefs keep migration durability testable without Keystore. */
internal class CloudAuthSessionStore(
    private val secure: SharedPreferences,
    private val legacy: SharedPreferences,
) {
    fun read(): String? {
        secure.getString(KEY, null)?.let { current ->
            // A failed commit may still update SharedPreferences' process-local value. Retry a
            // durable write before removing a surviving legacy copy, even when secure reads exist.
            if (legacy.contains(KEY)) write(current)
            return current
        }
        val old = legacy.getString(KEY, null) ?: return null
        write(old)
        return old
    }

    fun write(blob: String) {
        check(secure.edit().putString(KEY, blob).commit() && secure.getString(KEY, null) == blob) {
            "secure session persistence failed"
        }
        // Never remove the recoverable legacy copy until encrypted persistence/readback succeeds.
        removeLegacy()
    }

    fun clear() {
        removeLegacy()
        check(secure.edit().remove(KEY).commit() && !secure.contains(KEY)) { "secure session removal failed" }
    }

    private fun removeLegacy() {
        if (legacy.contains(KEY)) {
            check(legacy.edit().remove(KEY).commit() && !legacy.contains(KEY)) { "legacy session removal failed" }
        }
    }

    companion object { const val KEY = "session_json" }
}
