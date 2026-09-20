package com.noop.push

import android.content.Context
import com.noop.BuildConfig
import java.io.File
import java.security.MessageDigest
import java.util.UUID

/** Pinned once per process. Enrollment never redirects existing Room/BLE/file handles. */
object EnrollmentDataScope {
    data class Scope(val userId: String, val sourceId: String) {
        val suffix: String = digest("$userId\u0000$sourceId")
        val databaseName: String = "noop_enrolled_$suffix.db"
    }
    private var initialized = false
    private var pinned: Scope? = null

    @Synchronized fun initialize(context: Context) {
        if (initialized) return
        val settings = SelfHostedPushSettings.from(context)
        val source = settings.sourceId()
        pinned = PushEnrollmentStore.from(context).boundUserId()?.let { Scope(it, source) }
        initialized = true
    }

    fun scope(context: Context): Scope? { initialize(context); return pinned }
    fun databaseName(context: Context): String = if (BuildConfig.ENABLE_DEMO) "noop_whoop.db"
        else scope(context)?.databaseName ?: "noop_unenrolled_quarantine.db"
    fun storageName(context: Context, legacy: String): String = if (BuildConfig.ENABLE_DEMO) legacy
        else "$legacy-${scope(context)?.suffix ?: "unenrolled"}"

    fun credential(context: Context): PushEnrollmentCredential? = runCatching {
        if (com.noop.ui.NoopPrefs.of(context).getString(com.noop.ui.NoopPrefs.KEY_ACCEPTED_TERMS_VERSION, "") !=
            com.noop.ui.Terms.CURRENT_VERSION) return null
        val scope = scope(context) ?: return null
        PushEnrollmentStore.from(context).load(SelfHostedPushSettings.from(context).sourceId())
            ?.takeIf { it.userId == scope.userId && it.sourceId == scope.sourceId }
    }.getOrNull()
    fun active(context: Context): Boolean = BuildConfig.ENABLE_DEMO || credential(context) != null

    /** A non-backed-up witness rejects a copied preference identity after restore/reinstallation. */
    @Synchronized internal fun installationSource(context: Context, prefs: android.content.SharedPreferences): String {
        return installationSource(context.noBackupFilesDir, prefs)
    }

    @Synchronized internal fun installationSource(directory: File, prefs: android.content.SharedPreferences): String {
        val file = File(directory, "noop-installation-source")
        val saved = prefs.getString("source_id", null)
        val witness = runCatching { file.readText() }.getOrNull()
        if (saved != null && saved == witness && PushEnrollmentCredential.isCanonicalUuid(saved)) return saved
        val fresh = UUID.randomUUID().toString()
        file.parentFile?.mkdirs()
        val pending = File(file.parentFile, "${file.name}.pending")
        java.io.FileOutputStream(pending).use { it.write(fresh.toByteArray()); it.fd.sync() }
        check(pending.renameTo(file)) { "Could not persist installation identity" }
        check(prefs.edit().putString("source_id", fresh).remove("enrollment_source_id").commit())
        return fresh
    }

    internal fun digest(value: String): String = MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray()).take(16).joinToString("") { "%02x".format(it) }
}
