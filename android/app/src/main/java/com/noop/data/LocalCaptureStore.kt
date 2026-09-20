package com.noop.data

import android.database.Cursor
import androidx.sqlite.db.SimpleSQLiteQuery
import androidx.sqlite.db.SupportSQLiteDatabase
import com.noop.account.CaptureAdmission
import com.noop.account.CaptureFormat
import com.noop.account.CaptureNamespace
import com.noop.account.CaptureOwner
import com.noop.account.DurableCapture
import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

enum class CaptureIndexFailure {
    NOT_READY, OWNER_MISMATCH, CONFLICT, INVALID_CAPTURE, MISSING_MEMBER, DESTINATION_MISMATCH, NESTED_TRANSACTION,
}

class CaptureIndexException(val failure: CaptureIndexFailure) : IllegalStateException("capture_index_${failure.name.lowercase()}")

data class CaptureMemberKey(val captureId: String, val recordOrdinal: Int, val routeOrdinal: Int) {
    init {
        require(UUID.fromString(captureId).toString() == captureId)
        require(recordOrdinal in 0..4_095 && routeOrdinal in 0..15)
    }
}

data class IndexedCaptureMember(val resource: LocalCaptureResource, val member: LocalCaptureMember) {
    val key: CaptureMemberKey get() = CaptureMemberKey(member.captureId, member.recordOrdinal, member.routeOrdinal)
}

class CaptureProjectionInput internal constructor(val indexed: IndexedCaptureMember, private val payload: ByteArray) {
    fun payload(): ByteArray = payload.copyOf()
}

enum class CaptureProjectionDecision { RECORDED, DEFERRED, CONFLICT }
enum class CaptureApplyResult { APPLIED, ALREADY_APPLIED, DEFERRED, CONFLICT }
data class CaptureRegistration(val resourceInserted: Boolean, val membersInserted: Int)

interface CaptureMemberProjection {
    /** Runs synchronously in the store's transaction. Do not begin/end transactions or suspend. */
    fun write(database: SupportSQLiteDatabase, input: CaptureProjectionInput): CaptureProjectionDecision

    /** Must query the exact owner/device/source destination and its frozen values, not just a row ID. */
    fun destinationMatches(database: SupportSQLiteDatabase, input: CaptureProjectionInput): Boolean
}

/** Current-owner SQL only. Retired file-finalization authority never enters this store. */
class LocalCaptureStore(
    private val owner: CaptureOwner,
    private val admission: CaptureAdmission,
    private val database: () -> SupportSQLiteDatabase,
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val beforeCommit: () -> Unit = {},
) {
    suspend fun register(capture: DurableCapture): CaptureRegistration = withContext(dispatcher) {
        validateCapture(capture)
        transaction { db ->
            val expected = capture.resource
            val existing = resource(db, expected.captureId)
            if (existing != null && existing != expected) fail(CaptureIndexFailure.CONFLICT)
            if (existing == null) db.execSQL(INSERT_RESOURCE, resourceValues(expected))

            val expectedMembers = capture.members.associateBy { it.key() }
            val existingMembers = mutableSetOf<CaptureMemberKey>()
            db.query(SimpleSQLiteQuery("SELECT $MEMBER_COLUMNS FROM localCaptureMember WHERE captureId=?", arrayOf(expected.captureId))).use { rows ->
                while (rows.moveToNext()) {
                    val current = rows.member()
                    validateMember(current, expected)
                    val wanted = expectedMembers[current.key()] ?: fail(CaptureIndexFailure.CONFLICT)
                    if (current.copy(projectionState = 0) != wanted) fail(CaptureIndexFailure.CONFLICT)
                    if (!existingMembers.add(current.key())) fail(CaptureIndexFailure.CONFLICT)
                }
            }
            var inserted = 0
            for (member in capture.members) if (member.key() !in existingMembers) {
                db.execSQL(INSERT_MEMBER, memberValues(member))
                inserted++
            }
            CaptureRegistration(existing == null, inserted)
        }
    }

    suspend fun pendingMembers(after: CaptureMemberKey? = null, limit: Int = 128): List<IndexedCaptureMember> = withContext(dispatcher) {
        require(limit in 1..256)
        transaction { db ->
            val args = mutableListOf<Any?>(owner.scope.projectURL, owner.scope.userID, owner.sourceId.toString())
            val page = if (after == null) "" else {
                args.addAll(listOf(after.captureId, after.captureId, after.recordOrdinal,
                    after.recordOrdinal, after.routeOrdinal))
                " AND (m.captureId>? OR (m.captureId=? AND (m.recordOrdinal>? OR (m.recordOrdinal=? AND m.routeOrdinal>?))))"
            }
            args += limit
            val selected = resourceNames.joinToString(",") { "r.`$it`" } + "," + memberNames.joinToString(",") { "m.`$it`" }
            db.query(SimpleSQLiteQuery("SELECT $selected FROM localCaptureResource r JOIN localCaptureMember m ON m.captureId=r.captureId " +
                "WHERE r.projectURL=? AND r.userID=? AND r.sourceID=? AND m.projectionState<>1$page " +
                "ORDER BY m.captureId,m.recordOrdinal,m.routeOrdinal LIMIT ?", args.toTypedArray())).use { rows ->
                buildList {
                    while (rows.moveToNext()) {
                        val resource = rows.resource()
                        val member = rows.member(resourceNames.size)
                        validateResource(resource)
                        validateMember(member, resource)
                        add(IndexedCaptureMember(resource, member))
                    }
                }
            }
        }
    }

    suspend fun applyMember(
        capture: DurableCapture,
        key: CaptureMemberKey,
        projection: CaptureMemberProjection,
    ): CaptureApplyResult = withContext(dispatcher) {
        validateCapture(capture)
        if (key.captureId != capture.resource.captureId) fail(CaptureIndexFailure.CONFLICT)
        val expectedMember = capture.members.firstOrNull { it.key() == key } ?: fail(CaptureIndexFailure.MISSING_MEMBER)
        val payload = capture.payload(key.recordOrdinal)
        if (payload.size != expectedMember.payloadBytes || sha256(payload) != expectedMember.payloadSha256) fail(CaptureIndexFailure.INVALID_CAPTURE)
        try {
            transaction { db ->
                val resource = resource(db, key.captureId) ?: fail(CaptureIndexFailure.MISSING_MEMBER)
                if (resource != capture.resource) fail(CaptureIndexFailure.CONFLICT)
                val current = member(db, key) ?: fail(CaptureIndexFailure.MISSING_MEMBER)
                validateMember(current, resource)
                if (current.copy(projectionState = 0) != expectedMember) fail(CaptureIndexFailure.CONFLICT)
                val input = CaptureProjectionInput(IndexedCaptureMember(resource, current), payload)
                if (current.projectionState == 1) {
                    if (!projection.destinationMatches(db, input)) fail(CaptureIndexFailure.DESTINATION_MISMATCH)
                    return@transaction CaptureApplyResult.ALREADY_APPLIED
                }
                when (projection.write(db, input)) {
                    CaptureProjectionDecision.DEFERRED -> throw HeldProjection(CaptureApplyResult.DEFERRED)
                    CaptureProjectionDecision.CONFLICT -> throw HeldProjection(CaptureApplyResult.CONFLICT)
                    CaptureProjectionDecision.RECORDED -> Unit
                }
                if (!projection.destinationMatches(db, input)) fail(CaptureIndexFailure.DESTINATION_MISMATCH)
                db.compileStatement("UPDATE localCaptureMember SET projectionState=1 WHERE captureId=? AND recordOrdinal=? AND routeOrdinal=? AND projectionState=0").use { statement ->
                    statement.bindString(1, key.captureId); statement.bindLong(2, key.recordOrdinal.toLong()); statement.bindLong(3, key.routeOrdinal.toLong())
                    if (statement.executeUpdateDelete() != 1) fail(CaptureIndexFailure.CONFLICT)
                }
                CaptureApplyResult.APPLIED
            }
        } catch (held: HeldProjection) { held.result }
    }

    private fun <T> transaction(block: (SupportSQLiteDatabase) -> T): T {
        admission.withCurrent { Unit }
        // Opening may wait for the namespace/SQLite lock; never hold identity while doing so.
        val db = database()
        if (db.inTransaction()) fail(CaptureIndexFailure.NESTED_TRANSACTION)
        db.beginTransactionNonExclusive()
        var ended = false
        try {
            requireReady(db)
            verifyOwner(db)
            val result = block(db)
            beforeCommit()
            admission.withCurrent {
                verifyOwner(db)
                db.setTransactionSuccessful()
                ended = true
                db.endTransaction()
            }
            return result
        } finally {
            if (!ended) db.endTransaction()
        }
    }

    private fun requireReady(db: SupportSQLiteDatabase) {
        val names = mutableSetOf<String>()
        db.query("SELECT name FROM sqlite_master WHERE type='table' AND name IN ('localAccountOwner','localCaptureResource','localCaptureMember')").use { rows ->
            while (rows.moveToNext()) names += rows.text(0)
        }
        if ("localAccountOwner" !in names) fail(CaptureIndexFailure.OWNER_MISMATCH)
        if ("localCaptureResource" !in names || "localCaptureMember" !in names) fail(CaptureIndexFailure.NOT_READY)
    }

    private fun verifyOwner(db: SupportSQLiteDatabase) {
        db.query("SELECT projectURL,userID FROM localAccountOwner WHERE singleton=1").use { row ->
            if (!row.moveToFirst() || row.text(0) != owner.scope.projectURL || row.text(1) != owner.scope.userID || row.moveToNext()) {
                fail(CaptureIndexFailure.OWNER_MISMATCH)
            }
        }
    }

    private fun resource(db: SupportSQLiteDatabase, id: String): LocalCaptureResource? =
        db.query(SimpleSQLiteQuery("SELECT $RESOURCE_COLUMNS FROM localCaptureResource WHERE captureId=?", arrayOf(id))).use { rows ->
            if (!rows.moveToFirst()) null else rows.resource().also { validateResource(it) }
        }

    private fun member(db: SupportSQLiteDatabase, key: CaptureMemberKey): LocalCaptureMember? =
        db.query(SimpleSQLiteQuery("SELECT $MEMBER_COLUMNS FROM localCaptureMember WHERE captureId=? AND recordOrdinal=? AND routeOrdinal=?",
            arrayOf(key.captureId, key.recordOrdinal, key.routeOrdinal))).use { rows -> if (rows.moveToFirst()) rows.member() else null }

    private fun validateCapture(capture: DurableCapture) {
        if (capture.owner != owner) fail(CaptureIndexFailure.OWNER_MISMATCH)
        val resource = capture.resource
        validateResource(resource)
        if (capture.members.size != resource.memberCount) fail(CaptureIndexFailure.INVALID_CAPTURE)
        val groups = capture.members.groupBy { it.recordOrdinal }
        if (groups.keys != (0 until resource.recordCount).toSet()) fail(CaptureIndexFailure.INVALID_CAPTURE)
        var lastEncounter = -1L
        var payloadBytes = 0L
        for (recordOrdinal in 0 until resource.recordCount) {
            val members = checkNotNull(groups[recordOrdinal])
            members.forEach { validateMember(it, resource) }
            val first = members.first()
            if (first.encounterOrdinal <= lastEncounter || members.map { it.routeOrdinal }.toSet() != members.indices.toSet() ||
                members.any { it.projectionState != 0 || it.encounterOrdinal != first.encounterOrdinal ||
                    it.receivedAtMs != first.receivedAtMs || it.payloadOffset != first.payloadOffset ||
                    it.payloadBytes != first.payloadBytes || it.payloadSha256 != first.payloadSha256 }) {
                fail(CaptureIndexFailure.INVALID_CAPTURE)
            }
            if (members.map { Triple(it.namespace, it.sessionID, it.bucket) }.distinct().size != members.size) fail(CaptureIndexFailure.INVALID_CAPTURE)
            lastEncounter = first.encounterOrdinal
            payloadBytes += first.payloadBytes
        }
        if (payloadBytes != resource.payloadBytes) fail(CaptureIndexFailure.INVALID_CAPTURE)
    }

    private fun validateResource(value: LocalCaptureResource) {
        if (value.projectURL != owner.scope.projectURL || value.userID != owner.scope.userID || value.sourceID != owner.sourceId.toString()) {
            fail(CaptureIndexFailure.OWNER_MISMATCH)
        }
        if (!listOf(value.captureId, value.generation, value.serverDeviceID, value.producerID).all(::uuid) ||
            !text(value.deviceID, 256) || value.format !in CaptureFormat.values().map { it.name } || value.formatVersion != 1 ||
            value.relativePath != "capture-v1/${value.captureId}.ncap" || !hash(value.fileSha256) ||
            value.fileBytes !in 1..(4L shl 20) || value.payloadBytes !in 1..value.fileBytes ||
            value.recordCount !in 1..4_096 || value.memberCount !in value.recordCount..8_192) {
            fail(CaptureIndexFailure.INVALID_CAPTURE)
        }
    }

    private fun validateMember(value: LocalCaptureMember, resource: LocalCaptureResource) {
        if (value.captureId != resource.captureId || value.recordOrdinal !in 0 until resource.recordCount ||
            value.routeOrdinal !in 0..15 || value.encounterOrdinal < 0 || value.receivedAtMs < 0 ||
            value.namespace !in CaptureNamespace.values().map { it.name } || !text(value.sessionID, 128) ||
            value.payloadBytes !in 1..(1 shl 20) || value.payloadOffset !in 0..(resource.fileBytes - 32 - value.payloadBytes) ||
            !hash(value.payloadSha256) || value.projectionState !in 0..1) fail(CaptureIndexFailure.INVALID_CAPTURE)
    }

    private class HeldProjection(val result: CaptureApplyResult) : RuntimeException()

    companion object {
        private val resourceNames = listOf("captureId", "projectURL", "userID", "sourceID", "generation", "deviceID", "serverDeviceID",
            "producerID", "format", "formatVersion", "relativePath", "fileSha256", "fileBytes", "payloadBytes", "recordCount", "memberCount")
        private val memberNames = listOf("captureId", "recordOrdinal", "routeOrdinal", "encounterOrdinal", "receivedAtMs", "namespace",
            "sessionID", "bucket", "payloadOffset", "payloadBytes", "payloadSha256", "projectionState")
        private val RESOURCE_COLUMNS = resourceNames.joinToString(",") { "`$it`" }
        private val MEMBER_COLUMNS = memberNames.joinToString(",") { "`$it`" }
        private val INSERT_RESOURCE = "INSERT INTO localCaptureResource ($RESOURCE_COLUMNS) VALUES (${resourceNames.joinToString(",") { "?" }})"
        private val INSERT_MEMBER = "INSERT INTO localCaptureMember ($MEMBER_COLUMNS) VALUES (${memberNames.joinToString(",") { "?" }})"

        private fun resourceValues(v: LocalCaptureResource): Array<Any?> = arrayOf(v.captureId, v.projectURL, v.userID, v.sourceID,
            v.generation, v.deviceID, v.serverDeviceID, v.producerID, v.format, v.formatVersion, v.relativePath,
            v.fileSha256, v.fileBytes, v.payloadBytes, v.recordCount, v.memberCount)
        private fun memberValues(v: LocalCaptureMember): Array<Any?> = arrayOf(v.captureId, v.recordOrdinal, v.routeOrdinal,
            v.encounterOrdinal, v.receivedAtMs, v.namespace, v.sessionID, v.bucket, v.payloadOffset,
            v.payloadBytes, v.payloadSha256, v.projectionState)
        private fun LocalCaptureMember.key() = CaptureMemberKey(captureId, recordOrdinal, routeOrdinal)
        private fun Cursor.resource(o: Int = 0) = LocalCaptureResource(text(o), text(o + 1), text(o + 2), text(o + 3), text(o + 4),
            text(o + 5), text(o + 6), text(o + 7), text(o + 8), integer(o + 9), text(o + 10), text(o + 11),
            long(o + 12), long(o + 13), integer(o + 14), integer(o + 15))
        private fun Cursor.member(o: Int = 0) = LocalCaptureMember(text(o), integer(o + 1), integer(o + 2), long(o + 3), long(o + 4),
            text(o + 5), text(o + 6), if (isNull(o + 7)) null else long(o + 7), long(o + 8), integer(o + 9), text(o + 10), integer(o + 11))
        private fun Cursor.text(index: Int): String {
            if (getType(index) != Cursor.FIELD_TYPE_STRING) fail(CaptureIndexFailure.INVALID_CAPTURE)
            return getString(index)
        }
        private fun Cursor.long(index: Int): Long {
            if (getType(index) != Cursor.FIELD_TYPE_INTEGER) fail(CaptureIndexFailure.INVALID_CAPTURE)
            return getLong(index)
        }
        private fun Cursor.integer(index: Int): Int {
            val value = long(index)
            if (value !in Int.MIN_VALUE..Int.MAX_VALUE) fail(CaptureIndexFailure.INVALID_CAPTURE)
            return value.toInt()
        }
        private fun text(value: String, max: Int) = value.isNotBlank() && value.toByteArray(Charsets.UTF_8).size <= max &&
            value.none { it.isISOControl() || it in '\uD800'..'\uDFFF' }
        private fun hash(value: String) = value.matches(Regex("[0-9a-f]{64}"))
        private fun uuid(value: String) = runCatching { UUID.fromString(value).toString() == value }.getOrDefault(false)
        private fun sha256(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        private fun fail(failure: CaptureIndexFailure): Nothing = throw CaptureIndexException(failure)
    }
}
