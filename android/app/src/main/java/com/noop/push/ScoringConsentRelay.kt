package com.noop.push

import androidx.room.Entity
import androidx.room.ColumnInfo
import androidx.room.Index
import androidx.room.PrimaryKey
import com.noop.account.AccountStorageContext
import org.json.JSONObject
import java.time.Instant
import java.time.ZoneId

/** Frozen before suspension. Sensitive input producers and affirmative server flags remain inactive. */
class ScoringConsentCapture private constructor(val account: AccountSessionContext, val json: String) {
    companion object {
        fun capture(source: ScoringInputSource, config: ScoringConfigInput, timezone: String,
                    at: Instant = Instant.now()): ScoringConsentCapture {
            val day = at.atZone(ZoneId.of(timezone)).toLocalDate().toString()
            val owner = source.account.scope
            val json = SyncJson.canonical(JSONObject().put("projectURL", owner.projectURL).put("userID", owner.userID)
                .put("device", source.serverDeviceId).put("effectiveDay", day).put("timezone", timezone)
                .put("config", JSONObject(config.payload())))
            return ScoringConsentCapture(source.account, json)
        }
    }
}

@Entity(tableName = "consentIntent", indices = [Index(value = ["intentId"], unique = true)])
data class ScoringConsentIntent(@PrimaryKey(autoGenerate = true) val sequence: Long = 0,
    val intentId: String, val purpose: String, val enabled: Boolean, val decidedAt: Long,
    val capture: String?, val state: String, val mutationId: String? = null, val receipt: String? = null,
    @ColumnInfo(defaultValue = "0") val reserved: Boolean = false) {
    fun row() = ScoringConsentRow(purpose, intentId, enabled, decidedAt)
    fun payload(owner: AccountScope): JSONObject {
        require(requireNotNull(capture).toByteArray(Charsets.UTF_8).size <= ScoringConsentLimits.CAPTURE_BYTES)
        val frozen = JSONObject(requireNotNull(capture) { "Consent intent has no captured source/config" })
        require(SyncJson.string(frozen, "projectURL") == owner.projectURL && SyncJson.string(frozen, "userID") == owner.userID)
        require(SyncJson.uuid(intentId) == intentId && decidedAt >= 0)
        ScoringContextPurpose.values().single { it.wire == purpose }
        SyncJson.uuid(SyncJson.string(frozen, "device")); SyncJson.day(SyncJson.string(frozen, "effectiveDay"))
        ZoneId.of(SyncJson.string(frozen, "timezone"))
        val config = frozen.getJSONObject("config")
        require(SyncJson.long(config, "schemaVersion") == 1L)
        // Enabling context delivery requires a separate audited producer/admission contract.
        require(!SyncJson.bool(config, "journalContextEnabled") && !SyncJson.bool(config, "cycleAwarenessEnabled") &&
            !SyncJson.bool(config, "daytimePersonalBaselineEnabled"))
        return frozen
    }
    fun origin(): String = SyncJson.canonical(JSONObject().put("intentId", intentId).put("purpose", purpose)
        .put("enabled", enabled).put("decidedAt", decidedAt).put("capture", JSONObject(requireNotNull(capture))))
}

@Entity(tableName = "consentBarrier")
data class ScoringConsentBarrier(@PrimaryKey val purpose: String, val intentId: String)

/** Fixed-size fail-closed intent, committed before the bounded history can refuse admission. */
@Entity(tableName = "consentPause")
data class ScoringConsentPause(@PrimaryKey val purpose: String, val decisionId: String, val decidedAt: Long)
@Entity(tableName = "consentSource")
data class ScoringConsentSource(@PrimaryKey val singleton: Int = 1, val sourceId: String)
data class ScoringConsentPosition(val sourceId: String, val sequence: Long) {
    init { require(SyncJson.uuid(sourceId) == sourceId && sequence > 0) }
}

internal object ScoringConsentLimits {
    const val ROWS = 4096L
    const val BYTES = 16L * 1024 * 1024
    const val CAPTURE_BYTES = 128 * 1024
}

class ScoringConsentCapacity : IllegalStateException("Consent storage needs delivery or explicit resolution")
class ScoringConsentOriginRetired : IllegalStateException("Consent position already retired")

data class ScoringConsentDelivery(val intentId: String, val state: String, val mutationId: String?, val receipt: String?)

class ScoringConsentRelayHeld : IllegalStateException("Consent transition requires explicit retry or captured source/config")

/** Consent DB -> input DB lock order is shared by capture, startup and the worker. No network under these locks. */
object ScoringConsentRelay {
    fun <T> recoverBefore(account: AccountStorageContext, store: ScoringSyncStore, action: () -> T): T {
        ScoringConsentDatabase.open(account).use { db ->
            require(store.account.identity == account.identity)
            // Commit the journal identity before any cross-DB import. Rolling back local progress
            // must not regenerate a different source after the input DB already accepted it.
            db.ensureSource()
            db.runInTransaction { db.dao().pruneAbandonedGrants() }
            // Each progress/retirement boundary must COMMIT separately. An action failure must
            // never roll back the copied receipt after the input origin has already been deleted.
            compactAccepted(db, store)
            var after = 0L
            while (true) {
                val imported = db.dao().importedPage(after)
                if (imported.isEmpty()) break
                for (intent in imported) {
                    db.runInTransaction { progress(db, store, intent) }
                    after = intent.sequence
                }
            }
            compactAccepted(db, store)
            return db.runInTransaction(java.util.concurrent.Callable {
                recover(account, db, store)
                action()
            })
        }
    }

    internal fun recover(account: AccountStorageContext, db: ScoringConsentDatabase, store: ScoringSyncStore) {
        require(store.account.identity == account.identity)
        while (true) {
            val page = db.dao().unimportedPage()
            if (page.isEmpty()) return
            for (intent in page) {
                if (intent.state == "prepared" || intent.capture == null) throw ScoringConsentRelayHeld()
                progress(db, store, intent)
            }
        }
    }

    private fun progress(db: ScoringConsentDatabase, store: ScoringSyncStore, intent: ScoringConsentIntent) {
        val mutation = store.importConsent(intent, db.position(intent))
        val state = when (mutation.state) {
            "settled" -> "remote_accepted"
            "conflict", "rejected", "resolved" -> "conflict_held"
            else -> "queued"
        }
        if (intent.mutationId != null) check(intent.mutationId == mutation.mutationId)
        if (intent.state != state || intent.mutationId != mutation.mutationId || intent.receipt != mutation.receipt)
            check(db.dao().progress(intent.intentId, state, mutation.mutationId, mutation.receipt) == 1)
    }

    /** Retain at most 64 recent receipts for presentation; payload/origin lifetime is not unbounded. */
    internal fun compactAccepted(db: ScoringConsentDatabase, store: ScoringSyncStore, keepRecent: Int = 64) {
        require(keepRecent in 0..64)
        // Presentation retention must not occupy a denial slot while ordinary work stays held.
        // A settled input alone is insufficient: its exact receipt must first be durable here.
        for (id in store.acceptedControlIds()) {
            val intent = db.dao().intent(id) ?: continue
            if (intent.state == "remote_accepted") retireAccepted(db, store, intent)
        }
        while (true) {
            val page = db.dao().acceptedPage(keepRecent)
            if (page.isEmpty()) break
            for (intent in page) retireAccepted(db, store, intent)
        }
        // Recover the crash gap after input/control retirement but before local receipt deletion.
        // At this point at most keepRecent rows remain; ordinary retained receipts keep their origins.
        for (intent in db.dao().acceptedPage(0)) {
            if (!store.hasConsentOrigin(intent.intentId)) retireAccepted(db, store, intent)
        }
    }

    private fun retireAccepted(db: ScoringConsentDatabase, store: ScoringSyncStore, intent: ScoringConsentIntent) {
        val position = db.position(intent)
        store.retireConsent(intent, position)
        db.runInTransaction {
            val saved = db.dao().intent(intent.intentId) ?: return@runInTransaction
            require(saved == intent)
            db.dao().clearBarrier(intent.purpose, intent.intentId)
            check(db.dao().deleteIntent(intent.intentId) == 1)
            // consentPause survives: an earlier failed visible-decision commit stays denied.
        }
    }
}
