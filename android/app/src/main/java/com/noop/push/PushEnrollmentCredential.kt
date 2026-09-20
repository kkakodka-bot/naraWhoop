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
