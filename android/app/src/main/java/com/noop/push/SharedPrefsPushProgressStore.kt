package com.noop.push

import android.content.Context
import android.content.SharedPreferences
import com.noop.data.SecurePrefs
import java.security.MessageDigest

/** Encrypted durable progress plus remembered device scopes; never endpoint URLs or bearer tokens. */
class SharedPrefsPushProgressStore internal constructor(
    private val prefs: SharedPreferences,
) : PushProgressStore {
    override suspend fun knownDeviceIds(): Set<String> = prefs.getStringSet(KEY_DEVICES, emptySet()).orEmpty()

    override suspend fun rememberDeviceId(deviceId: String) {
        val updated = knownDeviceIds() + deviceId
        check(prefs.edit().putStringSet(KEY_DEVICES, updated).commit()) { "Could not persist push device scope" }
    }

    override suspend fun cursor(table: PushAppendTable, deviceId: String): PushCursor? {
        val prefix = key("append", table.wireName, deviceId)
        val rowId = prefs.getLong("$prefix.row", 0L)
        val fingerprint = prefs.getString("$prefix.key", null)
        return if (rowId > 0 && fingerprint != null) PushCursor(rowId, fingerprint) else null
    }

    override suspend fun saveCursor(table: PushAppendTable, deviceId: String, cursor: PushCursor) {
        val prefix = key("append", table.wireName, deviceId)
        check(prefs.edit().putLong("$prefix.row", cursor.rowId)
            .putString("$prefix.key", cursor.naturalKeyFingerprint).commit()) {
            "Could not persist push cursor"
        }
    }

    override suspend fun binaryCursor(table: PushBinaryTable, deviceId: String): PushCursor? {
        val prefix = key("binary", table.wireName, deviceId)
        val rowId = prefs.getLong("$prefix.row", 0L)
        val fingerprint = prefs.getString("$prefix.key", null)
        return if (rowId > 0 && fingerprint != null) PushCursor(rowId, fingerprint) else null
    }

    override suspend fun saveBinaryCursor(table: PushBinaryTable, deviceId: String, cursor: PushCursor) {
        val prefix = key("binary", table.wireName, deviceId)
        check(prefs.edit().putLong("$prefix.row", cursor.rowId)
            .putString("$prefix.key", cursor.naturalKeyFingerprint).commit()) {
            "Could not persist push binary cursor"
        }
    }

    override suspend fun window(table: PushMutableTable, deviceId: String): PushWindowProgress? {
        val prefix = key("window", table.wireName, deviceId)
        val batch = prefs.getString("$prefix.batch", null) ?: return null
        val from = prefs.getString("$prefix.from", null) ?: return null
        val to = prefs.getString("$prefix.to", null) ?: return null
        return PushWindowProgress(
            PushWindow(
                fromDay = from,
                toDay = to,
                startTsInclusive = prefs.getLong("$prefix.start", 0L),
                endTsExclusive = prefs.getLong("$prefix.end", 0L),
            ),
            batch,
            parseDayHashes(prefs.getString("$prefix.dayHashes", null)),
        )
    }

    override suspend fun saveWindow(table: PushMutableTable, deviceId: String, progress: PushWindowProgress) {
        val prefix = key("window", table.wireName, deviceId)
        check(prefs.edit()
            .putString("$prefix.batch", progress.batchId)
            .putString("$prefix.from", progress.window.fromDay)
            .putString("$prefix.to", progress.window.toDay)
            .putLong("$prefix.start", progress.window.startTsInclusive)
            .putLong("$prefix.end", progress.window.endTsExclusive)
            .putString("$prefix.dayHashes", encodeDayHashes(progress.dayHashes))
            .commit()) { "Could not persist push window" }
    }

    override suspend fun inFlightObject(table: PushBinaryTable, deviceId: String): PushInFlightObject? {
        val prefix = key("inflight", table.wireName, deviceId)
        val objectId = prefs.getString("$prefix.objectId", null) ?: return null
        val objectKey = prefs.getString("$prefix.objectKey", null) ?: return null
        val sha = prefs.getString("$prefix.sha", null) ?: return null
        return PushInFlightObject(objectId, objectKey, sha, prefs.getBoolean("$prefix.uploaded", false))
    }

    override suspend fun saveInFlightObject(table: PushBinaryTable, deviceId: String, inFlight: PushInFlightObject?) {
        val prefix = key("inflight", table.wireName, deviceId)
        val editor = prefs.edit()
        if (inFlight == null) {
            editor.remove("$prefix.objectId")
                .remove("$prefix.objectKey")
                .remove("$prefix.sha")
                .remove("$prefix.uploaded")
        } else {
            editor.putString("$prefix.objectId", inFlight.objectId)
                .putString("$prefix.objectKey", inFlight.objectKey)
                .putString("$prefix.sha", inFlight.contentSha256)
                .putBoolean("$prefix.uploaded", inFlight.uploaded)
        }
        check(editor.commit()) { "Could not persist in-flight object" }
    }

    override suspend fun preparedBoundary(table: PushBinaryTable, deviceId: String): PushPreparedBoundary? {
        val encoded = prefs.getString(key("prepared", table.wireName, deviceId), null) ?: return null
        val o = org.json.JSONObject(encoded)
        check(o.get("v") == 1)
        fun cursor(name: String): PushCursor? {
            if (o.isNull(name)) return null
            val value = o.getJSONObject(name)
            val row = value.get("row")
            check(row is Long || row is Int)
            check((row as Number).toLong() > 0)
            return PushCursor(row.toLong(), value.getString("key"))
        }
        return PushPreparedBoundary(cursor("start"), requireNotNull(cursor("end")), o.getInt("count"),
            o.getString("content"), o.getString("payload"), o.getString("manifest"))
    }

    override suspend fun savePreparedBoundary(table: PushBinaryTable, deviceId: String, prepared: PushPreparedBoundary?) {
        fun cursor(value: PushCursor?): Any = value?.let {
            org.json.JSONObject().put("row", it.rowId).put("key", it.naturalKeyFingerprint)
        } ?: org.json.JSONObject.NULL
        val encoded = prepared?.let {
            org.json.JSONObject().put("v", 1).put("start", cursor(it.startCursor)).put("end", cursor(it.endCursor))
                .put("count", it.sampleCount).put("content", it.contentSha256).put("payload", it.payloadSha256)
                .put("manifest", it.manifestJSON).toString()
        }
        check(prefs.edit().putString(key("prepared", table.wireName, deviceId), encoded).commit()) {
            "Could not persist prepared auxiliary prefix"
        }
        check(preparedBoundary(table, deviceId) == prepared) { "Prepared prefix readback mismatch" }
    }

    private fun key(kind: String, table: String, deviceId: String): String =
        "$kind.$table.${sha256(deviceId)}"

    private fun encodeDayHashes(hashes: Map<String, String>): String {
        check(hashes.all { (day, hash) ->
            runCatching { java.time.LocalDate.parse(day) }.isSuccess && hash.matches(HASH_PATTERN)
        }) { "Invalid mutable day hash progress" }
        return hashes.toSortedMap().entries.joinToString(",") { (day, hash) -> "$day:$hash" }
    }

    private fun parseDayHashes(encoded: String?): Map<String, String> {
        if (encoded.isNullOrEmpty()) return emptyMap()
        return runCatching {
            encoded.split(',').associate { item ->
                val separator = item.indexOf(':')
                require(separator > 0)
                val day = item.substring(0, separator)
                val hash = item.substring(separator + 1)
                java.time.LocalDate.parse(day)
                require(hash.matches(HASH_PATTERN))
                day to hash
            }
        }.getOrDefault(emptyMap())
    }

    companion object {
        private const val PREFS = "self_hosted_push_progress"
        private const val KEY_DEVICES = "known_devices"
        private val HASH_PATTERN = Regex("[0-9a-f]{64}")

        fun from(context: Context) = SharedPrefsPushProgressStore(
            SecurePrefs.of(com.noop.account.AccountStorageContext.capture(context), PREFS),
        )

        internal fun sha256(value: String): String = MessageDigest.getInstance("SHA-256")
            .digest(value.toByteArray()).joinToString("") { "%02x".format(it) }
    }
}
