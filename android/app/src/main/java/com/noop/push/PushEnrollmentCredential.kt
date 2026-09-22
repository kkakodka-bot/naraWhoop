package com.noop.push

import android.content.Context
import android.content.SharedPreferences
import com.noop.data.SecurePrefs
import java.util.UUID

/** A per-person upload credential bound to one app installation. */
data class PushEnrollmentCredential(
    val userId: String,
    val sourceId: String,
    val tokenId: String,
    val uploadToken: String,
) {
    init {
        require(isCanonicalUuid(userId)) { "userId must be a canonical UUID" }
        require(isCanonicalUuid(sourceId)) { "sourceId must be a canonical UUID" }
        require(isCanonicalUuid(tokenId)) { "tokenId must be a canonical UUID" }
        require(isValidUploadToken(uploadToken)) { "uploadToken has an invalid shape" }
    }

    override fun toString(): String =
        "PushEnrollmentCredential(userId=$userId, sourceId=$sourceId, tokenId=$tokenId, uploadToken=[REDACTED])"

    companion object {
        const val STORAGE_VERSION = 1
        const val MAX_FLEET_TOKEN_CHARS = 4096
        private val UPLOAD_TOKEN_PATTERN = Regex("noop_[A-Za-z0-9_-]{43}")

        internal fun isCanonicalUuid(value: String): Boolean = runCatching {
            UUID.fromString(value).toString() == value
        }.getOrDefault(false)

        internal fun isValidUploadToken(value: String): Boolean = UPLOAD_TOKEN_PATTERN.matches(value)

        internal fun isValidFleetToken(value: String): Boolean =
            value.isNotEmpty() && value.length <= MAX_FLEET_TOKEN_CHARS && value.all { it.code in 0x21..0x7e }
    }
}

/** Keystore-backed persistence for the upload credential. The enrollment code is never stored. */
class PushEnrollmentStore private constructor(
    private val prefs: SharedPreferences,
) {
    private var generation = 0L
    data class Retirement(val credential: PushEnrollmentCredential, val nextSourceId: String)
    @Synchronized fun pendingRetirement(): Retirement? {
        val encoded = prefs.getString("retirement_v1", null) ?: return null
        val row = org.json.JSONObject(encoded)
        val credential = PushEnrollmentCredential(row.getString("user"), row.getString("source"),
            row.getString("tokenId"), row.getString("token"))
        val next = row.getString("next")
        check(PushEnrollmentCredential.isCanonicalUuid(next) && next != credential.sourceId)
        return Retirement(credential, next)
    }
    @Synchronized fun beginRetirement(credential: PushEnrollmentCredential): Retirement {
        pendingRetirement()?.let { check(it.credential == credential); return it }
        check(load(credential.sourceId) == credential)
        val next = UUID.randomUUID().toString()
        val row = org.json.JSONObject().put("user",credential.userId).put("source",credential.sourceId)
            .put("tokenId",credential.tokenId).put("token",credential.uploadToken).put("next",next)
        check(prefs.edit().putString("retirement_v1",row.toString()).remove(KEY_VERSION).remove(KEY_USER_ID)
            .remove(KEY_SOURCE_ID).remove(KEY_TOKEN_ID).remove(KEY_UPLOAD_TOKEN).commit())
        generation++
        return Retirement(credential,next)
    }
    @Synchronized fun completeRetirement(pending: Retirement) {
        check(pendingRetirement() == pending)
        check(prefs.edit().putString("retired_owner.${pending.credential.sourceId}",pending.credential.userId)
            .remove(KEY_BOUND_USER).remove("retirement_v1").commit())
        generation++
    }
    @Synchronized fun generation(): Long = generation

    @Synchronized fun saveIfCurrent(expectedGeneration: Long, sourceId: String, credential: PushEnrollmentCredential): Boolean {
        if (generation != expectedGeneration) return false
        save(sourceId, credential)
        return true
    }

    @Synchronized fun clearIfCurrent(credential: PushEnrollmentCredential): Boolean {
        if (load(credential.sourceId) != credential) return false
        clear()
        return true
    }

    /** Retained after sign-out: a code cannot relabel this installation's retained health data. */
    @Synchronized
    fun boundUserId(): String? = prefs.getString(KEY_BOUND_USER, null)
        ?.takeIf(PushEnrollmentCredential::isCanonicalUuid)

    @Synchronized
    fun load(expectedSourceId: String): PushEnrollmentCredential? {
        if (pendingRetirement() != null) return null
        if (!PushEnrollmentCredential.isCanonicalUuid(expectedSourceId)) {
            clearBestEffort()
            return null
        }
        val credential = try {
            if (prefs.getInt(KEY_VERSION, 0) != PushEnrollmentCredential.STORAGE_VERSION) null else
            PushEnrollmentCredential(
                userId = prefs.getString(KEY_USER_ID, null) ?: "",
                sourceId = prefs.getString(KEY_SOURCE_ID, null) ?: "",
                tokenId = prefs.getString(KEY_TOKEN_ID, null) ?: "",
                uploadToken = prefs.getString(KEY_UPLOAD_TOKEN, null) ?: "",
            )
        } catch (unavailable: SecurityException) {
            // A temporarily locked/unavailable keystore is not evidence of an invalid credential.
            throw unavailable
        } catch (_: IllegalArgumentException) { null }
        catch (_: ClassCastException) { null }
        if (credential == null || credential.sourceId != expectedSourceId) {
            clearBestEffort()
            return null
        }
        return credential
    }

    @Synchronized
    fun save(expectedSourceId: String, credential: PushEnrollmentCredential) {
        check(pendingRetirement() == null) { "Installation retirement pending" }
        require(credential.sourceId == expectedSourceId) { "enrollment source mismatch" }
        require(PushEnrollmentCredential.isCanonicalUuid(expectedSourceId)) { "sourceId must be a canonical UUID" }
        require(boundUserId()?.let { it == credential.userId } != false) { "installation owner mismatch" }
        check(
            prefs.edit()
                .putString(KEY_BOUND_USER, credential.userId)
                .putInt(KEY_VERSION, PushEnrollmentCredential.STORAGE_VERSION)
                .putString(KEY_USER_ID, credential.userId)
                .putString(KEY_SOURCE_ID, credential.sourceId)
                .putString(KEY_TOKEN_ID, credential.tokenId)
                .putString(KEY_UPLOAD_TOKEN, credential.uploadToken)
                .commit(),
        ) { "Could not persist enrollment credential" }
        generation++
    }

    @Synchronized
    fun clear() {
        check(prefs.edit().remove(KEY_VERSION).remove(KEY_USER_ID).remove(KEY_SOURCE_ID)
            .remove(KEY_TOKEN_ID).remove(KEY_UPLOAD_TOKEN).commit()) { "Could not clear enrollment credential" }
        generation++
    }

    private fun clearBestEffort() {
        if (listOf(KEY_VERSION, KEY_USER_ID, KEY_SOURCE_ID, KEY_TOKEN_ID, KEY_UPLOAD_TOKEN).any(prefs::contains)) {
            runCatching { clear() }
        }
    }

    companion object {
        private const val PREFS = "self_hosted_push_enrollment"
        private const val KEY_VERSION = "version"
        private const val KEY_BOUND_USER = "bound_user_id"
        private const val KEY_USER_ID = "user_id"
        private const val KEY_SOURCE_ID = "source_id"
        private const val KEY_TOKEN_ID = "token_id"
        private const val KEY_UPLOAD_TOKEN = "upload_token"

        @Volatile private var instance: PushEnrollmentStore? = null
        fun from(context: Context): PushEnrollmentStore = instance ?: synchronized(this) {
            instance ?: PushEnrollmentStore(SecurePrefs.of(context.applicationContext, PREFS)).also { instance = it }
        }

        internal fun forTest(prefs: SharedPreferences): PushEnrollmentStore = PushEnrollmentStore(prefs)
    }
}

/** Installation-scoped immutable serial witnesses survive retries and local device adoption. */
class WearableAssociationStore(private val prefs: SharedPreferences) {
    data class Association(val provisional: String, val serial: String, val confirmed: Boolean = false)
    private fun key(c: PushEnrollmentCredential) = "wearables.${c.userId}.${c.sourceId}"
    private fun read(c: PushEnrollmentCredential) = org.json.JSONObject(prefs.getString(key(c), null) ?: "{\"records\":[],\"conflicted\":false}")
    private fun write(c: PushEnrollmentCredential, journal: org.json.JSONObject) {
        check(prefs.edit().putString(key(c),journal.toString()).commit()) { "Wearable evidence storage unavailable" }
    }
    @Synchronized fun record(provisional: String, serial: String, credential: PushEnrollmentCredential) {
        val normalized = serial.trim().uppercase(java.util.Locale.ROOT)
        require(Regex("[A-Z0-9-]{6,64}").matches(normalized) && !PushEnrollmentCredential.isCanonicalUuid(normalized.lowercase()))
        require(provisional.isNotBlank() && provisional.length <= 128)
        if (provisional == "whoop-$normalized") return
        val journal = read(credential); val records = journal.getJSONArray("records")
        val previous = (0 until records.length()).map(records::getJSONObject).find { it.getString("provisional") == provisional }
        if (previous != null) {
            if (previous.getString("serial") != normalized) { journal.put("conflicted",true); write(credential,journal) }
        } else {
            check(records.length() < 64)
            records.put(org.json.JSONObject().put("provisional",provisional).put("serial",normalized).put("confirmed",false))
            write(credential,journal)
        }
        check(!journal.getBoolean("conflicted")) { "Wearable identity conflict requires installation retirement" }
    }
    @Synchronized fun pending(credential: PushEnrollmentCredential): List<Association> {
        val journal = read(credential)
        check(!journal.getBoolean("conflicted")) { "Wearable identity conflict requires installation retirement" }
        val records = journal.getJSONArray("records")
        return (0 until records.length()).map(records::getJSONObject).filter { !it.getBoolean("confirmed") }
            .map { Association(it.getString("provisional"),it.getString("serial")) }
    }
    @Synchronized fun acknowledge(item: Association, credential: PushEnrollmentCredential) {
        val journal = read(credential); check(!journal.getBoolean("conflicted"))
        val records = journal.getJSONArray("records")
        val row = (0 until records.length()).map(records::getJSONObject).first {
            it.getString("provisional") == item.provisional && it.getString("serial") == item.serial
        }
        row.put("confirmed",true); write(credential,journal)
    }
    companion object {
        @Volatile private var instance: WearableAssociationStore? = null
        fun from(context: Context): WearableAssociationStore = instance ?: synchronized(this) {
            instance ?: WearableAssociationStore(SecurePrefs.of(com.noop.account.AccountStorageContext.platform(context),
                "wearable_associations")).also { instance = it }
        }
    }
}
