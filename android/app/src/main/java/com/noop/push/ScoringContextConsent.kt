package com.noop.push

import androidx.room.*
import com.noop.account.AccountFencedOpenHelperFactory
import com.noop.account.AccountStorageContext
import com.noop.account.AccountWriteFence
import com.noop.data.WhoopDatabase
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject
import java.util.UUID

enum class ScoringContextPurpose(val wire: String) {
    JOURNAL("journal_context"), CYCLE("cycle_context"), IMPORTS("imported_metrics"), WORKOUTS("manual_workouts")
}

data class ScoringContextDecision(val purpose: ScoringContextPurpose, val id: String, val enabled: Boolean,
                                  val decidedAt: Long) {
    fun payload(): JSONObject = JSONObject().put("purpose", purpose.wire).put("policyVersion", 1).put("decisionId", id)
}

@Entity(tableName = "consentDecision")
data class ScoringConsentRow(@PrimaryKey val purpose: String, val decisionId: String, val enabled: Boolean, val decidedAt: Long)

@Dao
interface ScoringConsentDao {
    @Query("SELECT * FROM consentDecision") fun all(): List<ScoringConsentRow>
    @Query("SELECT * FROM consentDecision WHERE purpose=:purpose") fun get(purpose: String): ScoringConsentRow?
    @Insert fun insert(row: ScoringConsentRow)
    @Update fun update(row: ScoringConsentRow): Int
    @Query("SELECT * FROM consentBarrier") fun barriers(): List<ScoringConsentBarrier>
    @Query("SELECT * FROM consentPause") fun pauses(): List<ScoringConsentPause>
    @Insert(onConflict = OnConflictStrategy.REPLACE) fun pause(row: ScoringConsentPause)
    @Query("DELETE FROM consentPause WHERE purpose=:purpose") fun clearPause(purpose: String)
    @Query("SELECT * FROM consentSource WHERE singleton=1") fun source(): ScoringConsentSource?
    @Insert fun source(row: ScoringConsentSource)
    @Query("SELECT * FROM consentBarrier WHERE purpose=:purpose") fun barrier(purpose: String): ScoringConsentBarrier?
    @Insert(onConflict = OnConflictStrategy.REPLACE) fun barrier(row: ScoringConsentBarrier)
    @Query("DELETE FROM consentBarrier WHERE purpose=:purpose AND intentId=:id") fun clearBarrier(purpose: String, id: String): Int
    @Insert fun intent(row: ScoringConsentIntent): Long
    @Query("SELECT * FROM consentIntent WHERE intentId=:id") fun intent(id: String): ScoringConsentIntent?
    @Query("SELECT * FROM consentIntent ORDER BY sequence") fun intents(): List<ScoringConsentIntent>
    @Query("SELECT COUNT(*) FROM consentIntent WHERE reserved=0") fun ordinaryCount(): Long
    @Query("SELECT COALESCE(SUM(length(CAST(capture AS BLOB))),0) FROM consentIntent WHERE reserved=0") fun ordinaryBytes(): Long
    @Query("SELECT COUNT(*) FROM consentIntent WHERE reserved=1 AND purpose=:purpose") fun reservedCount(purpose: String): Long
    @Query("SELECT * FROM consentIntent WHERE state='remote_accepted' AND sequence NOT IN (SELECT sequence FROM consentIntent WHERE state='remote_accepted' ORDER BY sequence DESC LIMIT :keepRecent) ORDER BY sequence LIMIT 64")
    fun acceptedPage(keepRecent: Int = 64): List<ScoringConsentIntent>
    @Query("SELECT * FROM consentIntent WHERE mutationId IS NOT NULL AND state NOT IN ('remote_accepted','abandoned') AND sequence>:after ORDER BY sequence LIMIT 64")
    fun importedPage(after: Long): List<ScoringConsentIntent>
    @Query("SELECT * FROM consentIntent WHERE mutationId IS NULL AND state NOT IN ('remote_accepted','abandoned') ORDER BY sequence LIMIT 64")
    fun unimportedPage(): List<ScoringConsentIntent>
    @Query("DELETE FROM consentIntent WHERE intentId=:id") fun deleteIntent(id: String): Int
    @Query("""DELETE FROM consentIntent WHERE state='abandoned' AND enabled=1 AND mutationId IS NULL AND receipt IS NULL
        AND intentId NOT IN (SELECT intentId FROM consentBarrier) AND intentId NOT IN (SELECT decisionId FROM consentDecision)""")
    fun pruneAbandonedGrants(): Int
    @Query("SELECT * FROM consentIntent WHERE sequence>:after AND state NOT IN ('remote_accepted','abandoned') ORDER BY sequence LIMIT 64")
    fun relayPage(after: Long): List<ScoringConsentIntent>
    @Query("""SELECT intentId,CASE WHEN capture IS NULL AND state!='abandoned' THEN 'held_capture' ELSE state END AS state,
        mutationId,receipt FROM consentIntent ORDER BY sequence DESC LIMIT 64""")
    fun recentDelivery(): List<ScoringConsentDelivery>
    @Query("UPDATE consentIntent SET state=:state,mutationId=:mutationId,receipt=:receipt WHERE intentId=:id")
    fun progress(id: String, state: String, mutationId: String?, receipt: String?): Int
}

@Database(entities = [ScoringConsentRow::class, ScoringConsentIntent::class, ScoringConsentBarrier::class,
    ScoringConsentPause::class, ScoringConsentSource::class], version = 3, exportSchema = true)
abstract class ScoringConsentDatabase : RoomDatabase(), java.io.Closeable {
    internal lateinit var fence: AccountWriteFence
    abstract fun dao(): ScoringConsentDao
    fun ensureSource(): ScoringConsentSource = runInTransaction(java.util.concurrent.Callable {
        dao().source() ?: ScoringConsentSource(sourceId = UUID.randomUUID().toString()).also { dao().source(it) }
    })
    fun position(intent: ScoringConsentIntent): ScoringConsentPosition = runInTransaction(java.util.concurrent.Callable {
        require(dao().intent(intent.intentId)?.sequence == intent.sequence)
        val source = ensureSource()
        ScoringConsentPosition(source.sourceId, intent.sequence)
    })
    fun retireWrites() = fence.retire()
    override fun close() { retireWrites(); super.close() }
    companion object {
        internal val MIGRATION_1_2 = object : androidx.room.migration.Migration(1, 2) {
            override fun migrate(db: androidx.sqlite.db.SupportSQLiteDatabase) {
                db.execSQL("CREATE TABLE consentIntent(sequence INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,intentId TEXT NOT NULL,purpose TEXT NOT NULL,enabled INTEGER NOT NULL,decidedAt INTEGER NOT NULL,capture TEXT,state TEXT NOT NULL,mutationId TEXT,receipt TEXT)")
                db.execSQL("CREATE UNIQUE INDEX index_consentIntent_intentId ON consentIntent(intentId)")
                db.execSQL("CREATE TABLE consentBarrier(purpose TEXT NOT NULL PRIMARY KEY,intentId TEXT NOT NULL)")
            }
        }
        internal val MIGRATION_2_3 = object : androidx.room.migration.Migration(2, 3) {
            override fun migrate(db: androidx.sqlite.db.SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE consentIntent ADD COLUMN reserved INTEGER NOT NULL DEFAULT 0")
                db.execSQL("CREATE TABLE consentPause(purpose TEXT NOT NULL PRIMARY KEY,decisionId TEXT NOT NULL,decidedAt INTEGER NOT NULL)")
                db.execSQL("CREATE TABLE consentSource(singleton INTEGER NOT NULL PRIMARY KEY,sourceId TEXT NOT NULL)")
                db.execSQL("INSERT INTO consentPause SELECT b.purpose,i.intentId,i.decidedAt FROM consentBarrier b JOIN consentIntent i ON i.intentId=b.intentId")
            }
        }
        fun open(account: AccountStorageContext): ScoringConsentDatabase {
            val owner = requireNotNull(account.identity.scope)
            check(account.isCurrent())
            val path = account.getDatabasePath("scoring_context_consent.sqlite").absolutePath
            WhoopDatabase.verifyExistingOwner(account, path)
            val fence = AccountWriteFence(account)
            return Room.databaseBuilder(account, ScoringConsentDatabase::class.java, path)
                .openHelperFactory(AccountFencedOpenHelperFactory(fence))
                .addMigrations(MIGRATION_1_2, MIGRATION_2_3)
                .addCallback(object : Callback() {
                    override fun onCreate(db: androidx.sqlite.db.SupportSQLiteDatabase) {
                        db.execSQL("CREATE TABLE localAccountOwner(singleton INTEGER PRIMARY KEY CHECK(singleton=1),projectURL TEXT NOT NULL,userID TEXT NOT NULL)")
                        db.execSQL("INSERT INTO localAccountOwner VALUES(1,?,?)", arrayOf(owner.projectURL, owner.userID))
                    }
                    override fun onOpen(db: androidx.sqlite.db.SupportSQLiteDatabase) {
                        db.execSQL("PRAGMA synchronous=FULL")
                        db.query("PRAGMA synchronous").use { check(it.moveToFirst() && it.getInt(0) == 2) }
                        db.query("SELECT projectURL,userID FROM localAccountOwner WHERE singleton=1").use {
                            check(it.moveToFirst()); AccountPushAdmission.verifyOwner(owner, it.getString(0), it.getString(1))
                        }
                    }
                }).build().also { it.fence = fence }
        }
    }
}

data class ScoringConsentState(val decisions: Map<ScoringContextPurpose, ScoringContextDecision> = emptyMap(),
                               val loaded: Boolean = false, val error: String? = null,
                               val relay: List<ScoringConsentDelivery> = emptyList())

/** New server-compute choices only. No local cycle/journal preferences or history are imported. */
class ScoringContextConsent(private val account: AccountStorageContext,
    private val capture: () -> ScoringConsentCapture? = { null },
    private val didSave: () -> Unit = {
        if (SelfHostedPushSettings.from(account).snapshot().ready) ScoringInputWorker.enqueue(account)
    },
) {
    private val lifecycle = Any()
    private val operations = Mutex()
    @Volatile private var retired = false
    private var database: ScoringConsentDatabase? = null
    private var retirement: Job? = null
    private val unsaved = mutableSetOf<ScoringContextPurpose>()
    private val transitions = mutableMapOf<ScoringContextPurpose, Long>()
    private var priorChange = CompletableDeferred(Unit)
    private val _state = MutableStateFlow(ScoringConsentState())
    val state: StateFlow<ScoringConsentState> = _state.asStateFlow()

    private fun active() {
        if (retired || !account.isCurrent()) throw AccountAuthException(AuthFailure.STALE)
        if (account.identity.scope == null) throw AccountAuthException(AuthFailure.SIGNED_OUT)
    }

    private fun ready(): ScoringConsentDatabase {
        active()
        database?.let { return it }
        val opened = ScoringConsentDatabase.open(account)
        try {
            CloudAuthClient.withIdentity(account, account.identity) {
                synchronized(lifecycle) {
                    if (retired) throw AccountAuthException(AuthFailure.STALE)
                    database = opened
                }
            }
            return opened
        } catch (failure: Throwable) { opened.close(); throw failure }
    }

    private fun values(db: ScoringConsentDatabase): Map<ScoringContextPurpose, ScoringContextDecision> = db.dao().all().associate { row ->
        val purpose = ScoringContextPurpose.values().single { it.wire == row.purpose }
        require(SyncJson.uuid(row.decisionId) == row.decisionId && row.decidedAt >= 0)
        purpose to ScoringContextDecision(purpose, row.decisionId, row.enabled, row.decidedAt)
    }

    private fun publish(db: ScoringConsentDatabase) {
        val values = values(db)
        val held = (db.dao().barriers().map { it.purpose } + db.dao().pauses().map { it.purpose }).toSet()
        // Presentation does not materialize the lifetime capture/origin history.
        val relay = db.dao().recentDelivery().reversed()
        CloudAuthClient.withIdentity(account, account.identity) {
            synchronized(lifecycle) {
                if (retired) throw AccountAuthException(AuthFailure.STALE)
                _state.value = ScoringConsentState(values.filter { (purpose, decision) ->
                    purpose !in unsaved && (!decision.enabled || purpose.wire !in held)
                }, true, if (unsaved.isEmpty() && held.isEmpty()) null else
                    "Sharing change not saved; upload paused until explicit retry", relay)
            }
        }
    }

    suspend fun load() = withContext(Dispatchers.IO) {
        operations.withLock {
            try { publish(ready()) }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { synchronized(lifecycle) {
                if (!retired) _state.value = ScoringConsentState(error = "Sharing choices unavailable; upload paused")
            } }
        }
    }

    suspend fun setEnabled(purpose: ScoringContextPurpose, enabled: Boolean) = setEnabled(purpose, enabled, null)

    internal suspend fun setEnabled(purpose: ScoringContextPurpose, enabled: Boolean, beforeCommit: (() -> Unit)?) {
        val request = synchronized(lifecycle) {
            if (retired) throw AccountAuthException(AuthFailure.STALE)
            unsaved.add(purpose)
            _state.value = _state.value.copy(decisions = _state.value.decisions - purpose)
            val transition = (transitions.getOrDefault(purpose, 0) + 1).also { transitions[purpose] = it }
            val completion = CompletableDeferred<Unit>()
            Triple(transition, priorChange, completion).also { priorChange = completion }
        }
        val transition = request.first
        val at = System.currentTimeMillis()
        val captured = runCatching { capture() }.getOrNull()
        // Once a choice is accepted, caller cancellation must not drop a denial from the local queue.
        // Runtime retirement still revokes the SQLite commit fence.
        withContext(Dispatchers.IO + NonCancellable) {
            request.second.await()
            try { operations.withLock {
                try {
                    active()
                    val db = ready()
                    // This constant-size denial survives any subsequent capacity/validation failure.
                    db.runInTransaction { db.dao().pause(ScoringConsentPause(purpose.wire, UUID.randomUUID().toString(), at)) }
                    captured?.let { require(it.account == account.identity.context) }
                    // This commit must precede (and survive failure of) the decision transaction.
                    val intent = db.runInTransaction(java.util.concurrent.Callable {
                        val pending = db.dao().barrier(purpose.wire)?.let { requireNotNull(db.dao().intent(it.intentId)) }
                        if (pending != null && pending.enabled == enabled) return@Callable pending
                        if (pending != null) {
                            check(pending.enabled && !enabled) { "Retry pending denial before a new grant" }
                            // Never imported: an explicitly abandoned failed grant has no remote origin.
                            check(pending.mutationId == null)
                            check(db.dao().deleteIntent(pending.intentId) == 1)
                        }
                        val captureBytes = captured?.json?.toByteArray(Charsets.UTF_8)?.size ?: 0
                        require(captureBytes <= ScoringConsentLimits.CAPTURE_BYTES)
                        val ordinary = db.dao().ordinaryCount() < ScoringConsentLimits.ROWS &&
                            db.dao().ordinaryBytes() + captureBytes <= ScoringConsentLimits.BYTES
                        if (!ordinary && (enabled || db.dao().reservedCount(purpose.wire) != 0L)) throw ScoringConsentCapacity()
                        val created = ScoringConsentIntent(intentId = UUID.randomUUID().toString(), purpose = purpose.wire,
                            enabled = enabled, decidedAt = at, capture = captured?.json, state = "prepared", reserved = !ordinary)
                        captured?.let { created.payload(requireNotNull(account.identity.scope)) }
                        db.dao().intent(created)
                        db.dao().barrier(ScoringConsentBarrier(purpose.wire, created.intentId))
                        requireNotNull(db.dao().intent(created.intentId))
                    })
                    val row = intent.row()
                    db.runInTransaction {
                        check(db.dao().barrier(purpose.wire)?.intentId == intent.intentId)
                        if (db.dao().get(purpose.wire) == null) db.dao().insert(row) else check(db.dao().update(row) == 1)
                        check(db.dao().get(purpose.wire) == row)
                        check(db.dao().progress(intent.intentId, "local_saved", null, null) == 1)
                        check(db.dao().clearBarrier(purpose.wire, intent.intentId) == 1)
                        db.dao().clearPause(purpose.wire)
                        beforeCommit?.invoke()
                    }
                    val saved = values(db)
                    check(saved[purpose] == ScoringContextDecision(purpose, row.decisionId, enabled, row.decidedAt))
                    synchronized(lifecycle) { if (transitions[purpose] == transition) unsaved.remove(purpose) }
                    publish(db)
                    runCatching { didSave() }
                } catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) { synchronized(lifecycle) {
                    if (!retired) _state.value = _state.value.copy(decisions = _state.value.decisions - purpose,
                        error = "Sharing change not saved; upload paused until explicit retry")
                } }
            } } finally { request.third.complete(Unit) }
        }
    }

    fun decision(purpose: ScoringContextPurpose): ScoringContextDecision? = try {
        CloudAuthClient.withIdentity(account, account.identity) {
            synchronized(lifecycle) { if (retired) null else _state.value.decisions[purpose]?.takeIf { it.enabled } }
        }
    } catch (_: AccountAuthException) { null }

    fun allows(purpose: ScoringContextPurpose, payload: String): Boolean {
        val expected = decision(purpose) ?: return false
        return runCatching {
            require(payload.toByteArray().size <= 128 * 1024)
            val consent = JSONObject(payload).getJSONObject("consent")
            consent.length() == 3 && SyncJson.string(consent, "purpose") == purpose.wire &&
                SyncJson.long(consent, "policyVersion") == 1L && SyncJson.uuid(SyncJson.string(consent, "decisionId")) == expected.id &&
                decision(purpose) == expected
        }.getOrDefault(false)
    }

    fun retire() {
        synchronized(lifecycle) {
            if (retired) return
            retired = true; database?.retireWrites(); _state.value = ScoringConsentState()
            retirement = CoroutineScope(Dispatchers.IO).launch { operations.withLock { database?.close(); database = null } }
        }
    }
    internal suspend fun awaitRetirement() { synchronized(lifecycle) { retirement }?.join() }
}
