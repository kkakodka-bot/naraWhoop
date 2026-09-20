package com.noop.push

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject

/** Separate namespace: ownerless legacy preferences are retained but never read. */
class ServerScoreCacheStore(private val prefs: SharedPreferences) {
    constructor(context: Context) : this(context.getSharedPreferences("noop_physiology_cache_v2", Context.MODE_PRIVATE))

    fun upsert(cache: ServerScoreDayCache) {
        require(cache.ownerId.isNotBlank() && cache.schemaVersion == 2 && cache.features.isNotEmpty())
        val raw = requireNotNull(cache.rawSnapshotJSON)
        val parsed = ServerScoreClient.parseSnapshot(raw, cache.day, cache.ownerId, cache.fetchedAtMs)
        require(parsed.scopeKey == cache.scopeKey)
        val key = key(cache.ownerId, cache.day, cache.scopeKey)
        val value = JSONObject().put("snapshot", raw).put("fetchedAtMs", cache.fetchedAtMs).toString()
        prefs.edit().putString(key, value).putString(pointer(cache.ownerId, cache.day), cache.scopeKey).apply()
    }

    fun load(ownerId: String, day: String, scopeKey: String? = null): ServerScoreDayCache? {
        if (ownerId.isBlank()) return null
        val selected = scopeKey ?: prefs.getString(pointer(ownerId, day), null) ?: return null
        return runCatching {
            val value = JSONObject(prefs.getString(key(ownerId, day, selected), null) ?: return null)
            ServerScoreClient.parseSnapshot(value.getString("snapshot"), day, ownerId, value.getLong("fetchedAtMs"))
                .takeIf { it.scopeKey == selected }
        }.getOrNull()
    }

    private fun key(owner: String, day: String, scope: String) = JSONArray(listOf("v2", owner.lowercase(), day, scope)).toString()
    private fun pointer(owner: String, day: String) = JSONArray(listOf("selection", owner.lowercase(), day)).toString()
}
