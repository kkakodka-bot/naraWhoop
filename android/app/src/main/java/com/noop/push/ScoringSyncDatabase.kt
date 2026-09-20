package com.noop.push

import androidx.room.*
import com.noop.account.AccountStorageContext
import com.noop.data.WhoopDatabase
import java.util.UUID
import org.json.JSONObject

@Entity(tableName = "snapshotV2")
data class ScoringSnapshotRow(@PrimaryKey val cacheKey: String, val day: String, val timezone: String,
    val sourceDeviceId: String, val algorithmVersion: String, val inputRevision: Long, val resultRevision: Long,
    val body: String, val fetchedAt: Long)
@Entity(tableName = "snapshotSelection")
data class ScoringSnapshotSelection(@PrimaryKey val selectionKey: String, val cacheKey: String)
@Entity(tableName = "historyEntity")
data class ScoringInputEntity(@PrimaryKey val entityKey: String, val clientRevision: Long, val headRevision: Long,
    val earliestDay: String, val originalStart: Long?, val originalEnd: Long?)
@Entity(tableName = "historyMutation", indices = [Index("entityKey")])
data class ScoringInputMutation(@PrimaryKey val mutationId: String, val entityKey: String,
    val device: String, val kind: String, val entity: String, val clientRevision: Long,
    val body: String, val state: String, val receipt: String?, val createdAt: Long) {
    fun key() = ScoringInputKey(device, kind, entity)
}
@Entity(tableName = "syncClient")
data class ScoringSyncClient(@PrimaryKey val singleton: Int = 1, val clientId: String)
@Entity(tableName = "consentImport", indices = [Index(value = ["mutationId"], unique = true)])
data class ScoringConsentImport(@PrimaryKey val intentId: String, val origin: String, val mutationId: String,
    val sourceSequence: Long? = null)
@Entity(tableName = "consentRelayPosition")
data class ScoringConsentRelayPosition(@PrimaryKey val singleton: Int = 1, val sourceId: String, val lastSequence: Long)
@Entity(tableName = "consentControl", indices = [Index(value = ["intentId"], unique = true), Index(value = ["mutationId"], unique = true)])
data class ScoringConsentControl(@PrimaryKey val purpose: String, val intentId: String, val mutationId: String, val allocatedBytes: Long)

internal object ScoringConsentControlLimits {
    const val COUNT = 4L
    const val PAYLOAD_BYTES = 64 * 1024
    const val ENVELOPE_BYTES = 128 * 1024L
    const val TOTAL_BYTES = COUNT * ENVELOPE_BYTES
}

@Dao
interface ScoringSyncDao {
    @Query("SELECT * FROM snapshotV2 WHERE cacheKey=:key") fun snapshot(key: String): ScoringSnapshotRow?
    @Query("SELECT s.* FROM snapshotV2 s JOIN snapshotSelection p ON p.cacheKey=s.cacheKey WHERE p.selectionKey=:key")
    fun selected(key: String): ScoringSnapshotRow?
    @Insert(onConflict = OnConflictStrategy.REPLACE) fun put(row: ScoringSnapshotRow)
    @Insert(onConflict = OnConflictStrategy.REPLACE) fun select(row: ScoringSnapshotSelection)
    @Query("DELETE FROM snapshotSelection WHERE cacheKey NOT IN (SELECT cacheKey FROM snapshotV2 ORDER BY fetchedAt DESC LIMIT 56)") fun trimSelections()
    @Query("DELETE FROM snapshotV2 WHERE cacheKey NOT IN (SELECT cacheKey FROM snapshotV2 ORDER BY fetchedAt DESC LIMIT 56)") fun trimSnapshots()
    @Query("SELECT * FROM historyEntity WHERE entityKey=:key") fun entity(key: String): ScoringInputEntity?
    @Insert(onConflict = OnConflictStrategy.REPLACE) fun put(row: ScoringInputEntity)
    @Query("SELECT * FROM historyMutation WHERE mutationId=:id") fun mutation(id: String): ScoringInputMutation?
    @Query("SELECT * FROM historyMutation WHERE entityKey=:key AND state NOT IN ('settled','resolved') ORDER BY clientRevision LIMIT 1")
    fun unresolved(key: String): ScoringInputMutation?
    @Query("SELECT COUNT(*) FROM historyMutation WHERE entityKey=:key AND clientRevision>:revision AND state NOT IN ('settled','resolved')")
    fun followingCount(key: String, revision: Long): Int
    @Query("SELECT * FROM historyMutation WHERE state IN ('awaiting_head','pending') ORDER BY createdAt,clientRevision LIMIT :limit")
    fun pending(limit: Int): List<ScoringInputMutation>
    @Query("UPDATE historyMutation SET body=:body,state='pending' WHERE mutationId=:id AND state='awaiting_head'")
    fun admit(id: String, body: String): Int
    @Query("UPDATE historyMutation SET state='awaiting_head' WHERE mutationId=:id AND state='waiting_previous'")
    fun releaseFollowing(id: String): Int
    @Insert fun insert(row: ScoringInputMutation)
    @Query("UPDATE historyMutation SET state=:state,receipt=:receipt WHERE mutationId=:id")
    fun settle(id: String, state: String, receipt: String?)
    @Query("SELECT * FROM syncClient WHERE singleton=1") fun client(): ScoringSyncClient?
    @Insert fun insert(row: ScoringSyncClient)
    @Query("SELECT * FROM consentImport WHERE intentId=:id") fun consentImport(id: String): ScoringConsentImport?
    @Insert fun insert(row: ScoringConsentImport)
    @Query("UPDATE consentImport SET sourceSequence=:sequence WHERE intentId=:id") fun bindConsentPosition(id: String, sequence: Long)
    @Query("SELECT COUNT(*) FROM consentImport") fun consentCount(): Long
    @Query("SELECT COALESCE(SUM(length(CAST(origin AS BLOB))),0) FROM consentImport") fun consentBytes(): Long
    @Query("SELECT * FROM consentRelayPosition WHERE singleton=1") fun relayPosition(): ScoringConsentRelayPosition?
    @Insert(onConflict = OnConflictStrategy.REPLACE) fun relayPosition(row: ScoringConsentRelayPosition)
    @Query("DELETE FROM consentImport WHERE intentId=:id") fun deleteConsentOrigin(id: String): Int
    @Query("DELETE FROM historyMutation WHERE mutationId=:id AND state='settled'") fun deleteSettledMutation(id: String): Int
    @Query("SELECT COUNT(*) FROM historyMutation WHERE state NOT IN ('settled','resolved')") fun pendingCount(): Long
    @Query("SELECT COALESCE(SUM(length(CAST(body AS BLOB))),0) FROM historyMutation WHERE state NOT IN ('settled','resolved')") fun pendingBytes(): Long
    @Query("SELECT COUNT(*) FROM historyMutation m WHERE state NOT IN ('settled','resolved') AND NOT EXISTS(SELECT 1 FROM consentControl c WHERE c.mutationId=m.mutationId)")
    fun ordinaryPendingCount(): Long
    @Query("SELECT COALESCE(SUM(length(CAST(body AS BLOB))),0) FROM historyMutation m WHERE state NOT IN ('settled','resolved') AND NOT EXISTS(SELECT 1 FROM consentControl c WHERE c.mutationId=m.mutationId)")
    fun ordinaryPendingBytes(): Long
    @Query("SELECT COUNT(*) FROM consentImport i WHERE NOT EXISTS(SELECT 1 FROM consentControl c WHERE c.intentId=i.intentId)") fun ordinaryConsentCount(): Long
    @Query("SELECT COALESCE(SUM(length(CAST(origin AS BLOB))),0) FROM consentImport i WHERE NOT EXISTS(SELECT 1 FROM consentControl c WHERE c.intentId=i.intentId)") fun ordinaryConsentBytes(): Long
    @Query("SELECT * FROM consentControl ORDER BY purpose") fun controls(): List<ScoringConsentControl>
    @Query("SELECT * FROM consentControl WHERE purpose=:purpose") fun control(purpose: String): ScoringConsentControl?
    @Query("SELECT c.intentId FROM consentControl c JOIN historyMutation m ON m.mutationId=c.mutationId WHERE m.state='settled'") fun acceptedControlIds(): List<String>
    @Query("SELECT COUNT(*) FROM consentControl") fun controlCount(): Long
    @Query("SELECT COALESCE(SUM(allocatedBytes),0) FROM consentControl") fun controlBytes(): Long
    @Insert fun insert(row: ScoringConsentControl)
    @Query("DELETE FROM consentControl WHERE intentId=:id") fun deleteControl(id: String): Int
}

/** Separate additive store, independently versioned from the raw Whoop database. */
@Database(entities = [ScoringSnapshotRow::class, ScoringSnapshotSelection::class, ScoringInputEntity::class,
    ScoringInputMutation::class, ScoringSyncClient::class, ScoringConsentImport::class,
    ScoringConsentRelayPosition::class, ScoringConsentControl::class], version = 4, exportSchema = true)
abstract class ScoringSyncDatabase : RoomDatabase(), java.io.Closeable {
    internal lateinit var writeFence: com.noop.account.AccountWriteFence
    internal lateinit var accountIdentity: AccountIdentitySnapshot
    fun retireWrites() = writeFence.retire()
    override fun close() { retireWrites(); super.close() }
    abstract fun dao(): ScoringSyncDao
    companion object {
        internal val MIGRATION_1_2 = object : androidx.room.migration.Migration(1, 2) {
            override fun migrate(db: androidx.sqlite.db.SupportSQLiteDatabase) {
                db.execSQL("CREATE TABLE consentImport(intentId TEXT NOT NULL PRIMARY KEY,origin TEXT NOT NULL,mutationId TEXT NOT NULL)")
                db.execSQL("CREATE UNIQUE INDEX index_consentImport_mutationId ON consentImport(mutationId)")
            }
        }
        internal val MIGRATION_2_3 = object : androidx.room.migration.Migration(2, 3) {
            override fun migrate(db: androidx.sqlite.db.SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE consentImport ADD COLUMN sourceSequence INTEGER")
                db.execSQL("CREATE TABLE consentRelayPosition(singleton INTEGER NOT NULL PRIMARY KEY,sourceId TEXT NOT NULL,lastSequence INTEGER NOT NULL)")
            }
        }
        internal val MIGRATION_3_4 = object : androidx.room.migration.Migration(3, 4) {
            override fun migrate(db: androidx.sqlite.db.SupportSQLiteDatabase) {
                db.execSQL("CREATE TABLE consentControl(purpose TEXT NOT NULL PRIMARY KEY,intentId TEXT NOT NULL,mutationId TEXT NOT NULL,allocatedBytes INTEGER NOT NULL)")
                db.execSQL("CREATE UNIQUE INDEX index_consentControl_intentId ON consentControl(intentId)")
                db.execSQL("CREATE UNIQUE INDEX index_consentControl_mutationId ON consentControl(mutationId)")
            }
        }
        fun open(account: AccountStorageContext): ScoringSyncDatabase {
            val owner = requireNotNull(account.identity.scope)
            check(account.isCurrent())
            val path = account.getDatabasePath("server_sync.sqlite").absolutePath
            WhoopDatabase.verifyExistingOwner(account, path)
            val fence = com.noop.account.AccountWriteFence(account)
            return Room.databaseBuilder(account, ScoringSyncDatabase::class.java, path)
                .openHelperFactory(com.noop.account.AccountFencedOpenHelperFactory(fence))
                .addMigrations(MIGRATION_1_2, MIGRATION_2_3, MIGRATION_3_4)
                .addCallback(object : Callback() {
                    override fun onCreate(db: androidx.sqlite.db.SupportSQLiteDatabase) {
                        db.execSQL("CREATE TABLE localAccountOwner (singleton INTEGER PRIMARY KEY CHECK(singleton=1), projectURL TEXT NOT NULL, userID TEXT NOT NULL)")
                        db.execSQL("INSERT INTO localAccountOwner VALUES(1,?,?)", arrayOf(owner.projectURL, owner.userID))
                    }
                    override fun onOpen(db: androidx.sqlite.db.SupportSQLiteDatabase) {
                        db.execSQL("PRAGMA synchronous=FULL")
                        db.query("PRAGMA synchronous").use { check(it.moveToFirst() && it.getInt(0) == 2) }
                        db.query("SELECT projectURL,userID FROM localAccountOwner WHERE singleton=1").use {
                            check(it.moveToFirst()); AccountPushAdmission.verifyOwner(owner, it.getString(0), it.getString(1))
                        }
                    }
                }).build().also { it.writeFence = fence; it.accountIdentity = account.identity }
        }
    }
}

/** All entry points run on IO. Snapshot publication and journal settlement are single transactions. */
class ScoringSyncStore(val account: AccountStorageContext, val database: ScoringSyncDatabase) {
    init { require(database.accountIdentity == account.identity) }
    private val owner = requireNotNull(account.identity.scope)
    private val dao get() = database.dao()
    private fun active() { if (!account.isCurrent()) throw AccountAuthException(AuthFailure.STALE) }
    private fun <T> transaction(block: () -> T): T = database.runInTransaction(java.util.concurrent.Callable {
        active(); val result = block(); active(); result
    })
    private fun selection(day: String, timezone: String) = "$day/$timezone"
    fun load(day: String, timezone: String): Pair<ServerSnapshotV2, Long>? {
        active()
        val row = dao.selected(selection(day, timezone)) ?: return null
        val snapshot = requireNotNull(ServerSnapshotDecoder.decode(row.body, owner, day, timezone).snapshot)
        require(snapshot.sourceDeviceId == row.sourceDeviceId && snapshot.algorithmVersion == row.algorithmVersion &&
            snapshot.inputRevision == row.inputRevision && snapshot.resultRevision == row.resultRevision)
        active(); return snapshot to row.fetchedAt
    }
    fun accept(snapshot: ServerSnapshotV2, fetchedAt: Long): ServerSnapshotV2 = transaction {
        val validated = requireNotNull(ServerSnapshotDecoder.decode(snapshot.json, owner, snapshot.day, snapshot.timezone).snapshot)
        val key = "${snapshot.sourceDeviceId}/${snapshot.day}/${snapshot.timezone}/2/${snapshot.algorithmVersion}"
        val previous = dao.snapshot(key)
        if (previous != null) {
            if (snapshot.resultRevision < previous.resultRevision || snapshot.inputRevision < previous.inputRevision)
                return@transaction requireNotNull(ServerSnapshotDecoder.decode(previous.body, owner, snapshot.day, snapshot.timezone).snapshot)
            if (snapshot.resultRevision == previous.resultRevision) {
                // Envelope freshness can change while the immutable result cannot.
                require(immutableResult(previous.body) == immutableResult(snapshot.json)) { "Conflicting immutable result" }
            }
        }
        dao.put(ScoringSnapshotRow(key, snapshot.day, snapshot.timezone, snapshot.sourceDeviceId, snapshot.algorithmVersion,
            snapshot.inputRevision, snapshot.resultRevision, snapshot.json, fetchedAt))
        dao.select(ScoringSnapshotSelection(selection(snapshot.day, snapshot.timezone), key))
        dao.trimSelections(); dao.trimSnapshots()
        validated
    }
    private fun immutableResult(body: String): String = JSONObject(body).let {
        listOf("pending", "requestedInputRevision", "archiveStatus").forEach(it::remove); SyncJson.canonical(it)
    }
    /** Import and origin receipt commit together. Replaying after a relay crash cannot allocate another revision. */
    internal fun importConsent(intent: ScoringConsentIntent): ScoringInputMutation =
        ScoringConsentDatabase.open(account).use { consent -> importConsent(intent, consent.position(intent)) }

    internal fun importConsent(intent: ScoringConsentIntent, position: ScoringConsentPosition): ScoringInputMutation = transaction {
        val captured = intent.payload(owner)
        require(position.sequence == intent.sequence)
        val previous = relayPosition(position)
        require(intent.state in setOf("local_saved", "queued", "remote_accepted", "conflict_held"))
        val origin = intent.origin()
        dao.consentImport(intent.intentId)?.let {
            require(it.origin == origin && (it.sourceSequence == null || it.sourceSequence == position.sequence)) { "Immutable consent origin changed" }
            dao.bindConsentPosition(intent.intentId, position.sequence)
            dao.relayPosition(previous.copy(lastSequence = maxOf(previous.lastSequence, position.sequence)))
            return@transaction requireNotNull(dao.mutation(it.mutationId))
        }
        if (position.sequence <= previous.lastSequence) throw ScoringConsentOriginRetired()
        val originBytes = origin.toByteArray(Charsets.UTF_8).size
        val ordinaryOriginFits = dao.ordinaryConsentCount() < ScoringConsentLimits.ROWS &&
            dao.ordinaryConsentBytes() + originBytes <= ScoringConsentLimits.BYTES
        val control = if (intent.enabled) null else ControlCandidate(
            ScoringContextPurpose.values().single { it.wire == intent.purpose }, intent.intentId, originBytes)
        val key = ScoringInputKey(SyncJson.string(captured, "device"), "config", "primary")
        val mutation = enqueueInput(key, null, SyncJson.string(captured, "effectiveDay"),
            SyncJson.canonical(captured.getJSONObject("config")), queueFollowing = true,
            control = control, requireControl = !ordinaryOriginFits)
        dao.insert(ScoringConsentImport(intent.intentId, origin, mutation.mutationId, position.sequence))
        dao.relayPosition(previous.copy(lastSequence = position.sequence))
        mutation
    }
    private fun relayPosition(position: ScoringConsentPosition): ScoringConsentRelayPosition {
        val saved = dao.relayPosition() ?: ScoringConsentRelayPosition(sourceId = position.sourceId, lastSequence = 0)
        require(saved.sourceId == position.sourceId) { "Consent journal source changed" }
        return saved
    }
    /** Call only after consent durably copied the exact verified receipt. Both DB halves are retryable. */
    internal fun retireConsent(intent: ScoringConsentIntent, position: ScoringConsentPosition) = transaction {
        require(intent.state == "remote_accepted" && intent.receipt != null && position.sequence == intent.sequence)
        intent.payload(owner)
        val previous = relayPosition(position)
        val origin = dao.consentImport(intent.intentId)
        if (origin == null) {
            require(position.sequence <= previous.lastSequence) { "No accepted origin to retire" }
        } else {
            require(origin.origin == intent.origin() && (origin.sourceSequence == null || origin.sourceSequence == position.sequence))
            val mutation = requireNotNull(dao.mutation(origin.mutationId))
            require(mutation.state == "settled" && mutation.mutationId == intent.mutationId && mutation.receipt == intent.receipt)
            ScoringInputReceipt.decode(intent.receipt, owner, mutation)
            dao.relayPosition(previous.copy(lastSequence = maxOf(previous.lastSequence, position.sequence)))
            check(dao.deleteConsentOrigin(intent.intentId) == 1)
            check(dao.deleteSettledMutation(mutation.mutationId) == 1)
            dao.deleteControl(intent.intentId)
        }
    }
    internal fun acceptedControlIds(): List<String> { active(); return dao.acceptedControlIds() }
    internal fun hasConsentOrigin(id: String): Boolean { active(); return dao.consentImport(id) != null }

    private data class ControlCandidate(val purpose: ScoringContextPurpose, val intentId: String, val originBytes: Int)
    fun enqueue(key: ScoringInputKey, head: ScoringInputHead?, effectiveDay: String, payload: String,
        deleted: Boolean = false, resolving: String? = null, queueFollowing: Boolean = false): ScoringInputMutation =
        enqueueInput(key, head, effectiveDay, payload, deleted, resolving, queueFollowing)

    private fun enqueueInput(key: ScoringInputKey, head: ScoringInputHead?, effectiveDay: String, payload: String,
        deleted: Boolean = false, resolving: String? = null, queueFollowing: Boolean = false,
        control: ControlCandidate? = null, requireControl: Boolean = false): ScoringInputMutation = transaction {
        require(!queueFollowing || (key.kind in setOf("profile", "config") && head == null && resolving == null))
        require(head == null || (head.key == key && head.revision >= 0)); SyncJson.day(effectiveDay)
        val parsed = JSONObject(payload); require(payload.toByteArray().size <= 128 * 1024)
        if (deleted) require(parsed.length() == 0 && key.kind == "sleep_edit")
        else require(SyncJson.long(parsed, "schemaVersion") == 1L)
        val pending = dao.unresolved(key.storageKey)
        if (resolving == null) check(pending == null || queueFollowing) { "Unresolved input intent" }
        else {
            require(head != null) { "Explicit rebase requires observed head" }
            check(pending != null && pending.mutationId == resolving && pending.state in setOf("conflict", "rejected"))
            check(dao.followingCount(key.storageKey, pending.clientRevision) == 0) { "Newer captured settings require explicit resolution" }
            dao.settle(resolving, "resolved", pending.receipt)
        }
        val previous = dao.entity(key.storageKey)
        require(head == null || head.revision >= (previous?.headRevision ?: 0))
        val clientRevision = Math.addExact(previous?.clientRevision ?: 0, 1)
        val client = dao.client() ?: ScoringSyncClient(clientId = UUID.randomUUID().toString()).also(dao::insert)
        val mutation = UUID.randomUUID().toString()
        val earliest = if (key.kind == "sleep_edit") minOf(previous?.earliestDay ?: effectiveDay, effectiveDay) else effectiveDay
        val originalStart = if (key.kind == "sleep_edit" && !deleted) SyncJson.long(parsed, "originalStart") else previous?.originalStart
        val originalEnd = if (key.kind == "sleep_edit" && !deleted) SyncJson.long(parsed, "originalEnd") else previous?.originalEnd
        if (previous?.originalStart != null) require(previous.originalStart == originalStart && previous.originalEnd == originalEnd)
        val body = SyncJson.canonical(key.rpc().put("p_effective_day", earliest).put("p_payload", parsed)
            .put("p_expected_revision", head?.revision ?: JSONObject.NULL).put("p_deleted", deleted).put("p_client_id", client.clientId)
            .put("p_client_mutation_id", mutation).put("p_client_revision", clientRevision))
        val ordinaryFits = !requireControl && dao.ordinaryPendingCount() < ScoringConsentLimits.ROWS &&
            dao.ordinaryPendingBytes() + body.toByteArray(Charsets.UTF_8).size <= ScoringConsentLimits.BYTES
        if (!ordinaryFits) {
            // Storage admission only: same-entity conflict/waiting state above remains binding.
            // Reserve enough for null expectedRevision to grow to any Int64 head before sending.
            val bytes = (control?.originBytes ?: 0).toLong() + body.toByteArray(Charsets.UTF_8).size + 20
            if (control == null || key.kind != "config" || key.entity != "primary" || deleted || resolving != null ||
                payload.toByteArray(Charsets.UTF_8).size > ScoringConsentControlLimits.PAYLOAD_BYTES ||
                bytes > ScoringConsentControlLimits.ENVELOPE_BYTES || dao.control(control.purpose.wire) != null ||
                dao.controlCount() >= ScoringConsentControlLimits.COUNT ||
                dao.controlBytes() + bytes > ScoringConsentControlLimits.TOTAL_BYTES) throw ScoringConsentCapacity()
            dao.insert(ScoringConsentControl(control.purpose.wire, control.intentId, mutation, bytes))
        }
        dao.put(ScoringInputEntity(key.storageKey, clientRevision, head?.revision ?: previous?.headRevision ?: 0, earliest, originalStart, originalEnd))
        ScoringInputMutation(mutation, key.storageKey, key.device, key.kind, key.entity, clientRevision, body,
            if (pending != null && queueFollowing) "waiting_previous" else if (head == null) "awaiting_head" else "pending", null,
            System.currentTimeMillis()).also(dao::insert)
    }
    /** Head resolution freezes the last field before the first send; a submitted body never changes. */
    fun admitDraft(request: ScoringInputMutation, head: ScoringInputHead): ScoringInputMutation = transaction {
        val current = requireNotNull(dao.mutation(request.mutationId))
        require(head.key == current.key())
        if (current.state != "awaiting_head") return@transaction current
        require(current.body == request.body && head.revision >= 0)
        val entity = requireNotNull(dao.entity(request.entityKey))
        if (head.revision != entity.headRevision) {
            // A metadata read is not permission to overwrite a remote edit made while offline.
            dao.settle(current.mutationId, "conflict", null)
            return@transaction current.copy(state = "conflict")
        }
        val body = SyncJson.canonical(JSONObject(current.body).put("p_expected_revision", head.revision))
        check(dao.admit(current.mutationId, body) == 1)
        dao.put(entity.copy(headRevision = head.revision))
        current.copy(body = body, state = "pending")
    }
    fun pending(limit: Int = 20): List<ScoringInputMutation> { active(); require(limit in 1..100); return dao.pending(limit) }
    fun recordReceipt(request: ScoringInputMutation, response: String) = transaction {
        val current = requireNotNull(dao.mutation(request.mutationId)); require(current.body == request.body)
        val receipt = ScoringInputReceipt.decode(response, owner, request)
        require(current.state in setOf("pending", "settled"))
        val entity = requireNotNull(dao.entity(request.entityKey))
        dao.put(entity.copy(headRevision = maxOf(entity.headRevision, receipt.revision)))
        if (current.state == "settled") require(ScoringInputReceipt.decode(requireNotNull(current.receipt), owner, current).json == receipt.json)
        dao.settle(request.mutationId, "settled", receipt.json)
        dao.unresolved(request.entityKey)?.takeIf { it.state == "waiting_previous" }?.let {
            check(dao.releaseFollowing(it.mutationId) == 1)
        }
    }
    fun retainFailure(request: ScoringInputMutation, state: String) = transaction {
        require(state in setOf("conflict", "rejected"))
        val current = requireNotNull(dao.mutation(request.mutationId)); require(current.body == request.body)
        if (current.state == "pending") dao.settle(request.mutationId, state, null)
    }
}
