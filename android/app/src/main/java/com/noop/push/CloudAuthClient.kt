package com.noop.push

import android.content.Context
import com.noop.data.SecurePrefs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/** Supabase GoTrue session for authenticated score reads (JWT only). */
object CloudAuthClient {
    private var generation: Long = 0
    data class Session(
        val accessToken: String,
        val refreshToken: String,
        val expiresAtMs: Long,
        val userId: String,
    ) {
        fun isExpired(nowMs: Long = System.currentTimeMillis()): Boolean =
            nowMs + 60_000 >= expiresAtMs
    }

    private const val PREFS = "noop_cloud_auth"
    private const val SECURE_PREFS = "noop_cloud_auth_encrypted"

    private fun store(context: Context) = CloudAuthSessionStore(
        SecurePrefs.of(context, SECURE_PREFS), context.getSharedPreferences(PREFS, Context.MODE_PRIVATE))

    @Synchronized fun storedSession(context: Context): Session? {
        // Keystore unavailability means signed out/unavailable, never plaintext credential fallback.
        val raw = runCatching { store(context).read() }.getOrNull() ?: return null
        return runCatching {
            val o = JSONObject(raw)
            Session(
                accessToken = o.getString("accessToken"),
                refreshToken = o.getString("refreshToken"),
                expiresAtMs = o.getLong("expiresAtMs"),
                userId = o.getString("userId"),
            )
        }.getOrNull()
    }

    @Synchronized fun clearSession(context: Context) {
        generation++
        store(context).clear()
    }

    @Synchronized fun clearSessionIfCurrent(context: Context, accessToken: String, ownerId: String): Boolean {
        val current = storedSession(context) ?: return false
        if (current.accessToken != accessToken || current.userId.lowercase() != ownerId.lowercase()) return false
        clearSession(context)
        return true
    }

    suspend fun signIn(context: Context, email: String, password: String): Session =
        withContext(Dispatchers.IO) {
            val requestGeneration = synchronized(this@CloudAuthClient) { ++generation }
            val base = ServerScoringSettings.supabaseProjectUrl()
                ?: error("not configured")
            val anon = ServerScoringSettings.anonKey()
                ?: error("not configured")
            val url = URL("$base/auth/v1/token?grant_type=password")
            val conn = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 15_000; readTimeout = 30_000
                setRequestProperty("Content-Type", "application/json")
                setRequestProperty("apikey", anon)
                doOutput = true
            }
            try {
                conn.outputStream.use {
                    it.write(JSONObject(mapOf("email" to email, "password" to password)).toString().toByteArray())
                }
                if (conn.responseCode != 200) error("invalid credentials")
                val body = conn.inputStream.bufferedReader().use { it.readText() }
                val session = parseSession(body)
                currentCoroutineContext().ensureActive()
                synchronized(this@CloudAuthClient) {
                    check(generation == requestGeneration) { "session changed" }
                    persist(context, session)
                }
                ServerScoringSettings.setAuthEmail(context, email)
                session
            } finally {
                conn.disconnect()
            }
        }

    suspend fun validAccessToken(context: Context): String =
        withContext(Dispatchers.IO) {
            var session = storedSession(context) ?: error("not signed in")
            if (!session.isExpired()) return@withContext session.accessToken
            session = refresh(context, session)
            session.accessToken
        }

    private suspend fun refresh(context: Context, session: Session): Session {
        val requestGeneration = synchronized(this) { generation }
        val base = ServerScoringSettings.supabaseProjectUrl() ?: error("not configured")
        val anon = ServerScoringSettings.anonKey() ?: error("not configured")
        val url = URL("$base/auth/v1/token?grant_type=refresh_token")
        val conn = (url.openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            connectTimeout = 15_000; readTimeout = 30_000
            setRequestProperty("Content-Type", "application/json")
            setRequestProperty("apikey", anon)
            doOutput = true
        }
        try {
            conn.outputStream.use {
                it.write(JSONObject(mapOf("refresh_token" to session.refreshToken)).toString().toByteArray())
            }
            if (conn.responseCode != 200) {
                synchronized(this) {
                    if (generation == requestGeneration && storedSession(context)?.refreshToken == session.refreshToken) clearSession(context)
                }
                error("session expired")
            }
            val refreshed = parseSession(conn.inputStream.bufferedReader().use { it.readText() })
            currentCoroutineContext().ensureActive()
            synchronized(this) {
                check(generation == requestGeneration && storedSession(context)?.refreshToken == session.refreshToken &&
                    refreshed.userId == session.userId) { "session changed" }
                persist(context, refreshed)
            }
            return refreshed
        } finally {
            conn.disconnect()
        }
    }

    private fun parseSession(body: String): Session {
        val o = JSONObject(body)
        val user = o.getJSONObject("user")
        val expiresIn = o.getLong("expires_in")
        return Session(
            accessToken = o.getString("access_token"),
            refreshToken = o.getString("refresh_token"),
            expiresAtMs = System.currentTimeMillis() + expiresIn * 1000L,
            userId = user.getString("id"),
        )
    }

    private fun persist(context: Context, session: Session) {
        val json = JSONObject()
            .put("accessToken", session.accessToken)
            .put("refreshToken", session.refreshToken)
            .put("expiresAtMs", session.expiresAtMs)
            .put("userId", session.userId)
            .toString()
        store(context).write(json)
    }
}
