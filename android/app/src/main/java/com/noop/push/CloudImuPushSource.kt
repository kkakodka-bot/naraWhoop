package com.noop.push

import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import com.noop.account.AccountStorageContext
import com.noop.testcentre.ImuSessionFileStore
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import java.util.zip.Deflater
import java.util.zip.DeflaterOutputStream
import org.json.JSONArray
import org.json.JSONObject

/** Account-captured membership for session and continuous IMU. No upload ACK authorizes deletion. */
class CloudImuPushSource internal constructor(
    private val storage: AccountStorageContext,
    private val sourceId: String,
    private val destination: String = "",
    private val segmentBudget: Int = 16,
) : ImuExactArchiveSource {
    constructor(context: Context, sourceId: String) : this(AccountStorageContext.capture(context), sourceId)

    private val stores = linkedMapOf(
        "continuous" to ImuSessionFileStore(storage, ImuSessionFileStore.NAMESPACE_CONTINUOUS),
        "session" to ImuSessionFileStore(storage, ImuSessionFileStore.NAMESPACE_SESSIONS),
    )
    private val indexFile: File
    private val lock: Any
    private val indexState = storage.getSharedPreferences("cloud_imu_index_v1_$sourceId", Context.MODE_PRIVATE)

    init {
        require(UUID.fromString(sourceId).toString() == sourceId)
        require(segmentBudget in 1..16)
        check(stores.values.all { it.pushOwnerMatches(storage.namespace) })
        indexFile = File(storage.filesDir, "cloud-imu-v1/$sourceId/membership.sqlite")
        check(indexFile.parentFile!!.isDirectory || indexFile.parentFile!!.mkdirs())
        lock = synchronized(locks) { locks.getOrPut(indexFile.canonicalPath) { Any() } }
    }

    override fun forDestination(namespace: String): CloudImuPushSource {
        require(namespace.isNotBlank())
        return CloudImuPushSource(storage, sourceId, namespace, segmentBudget)
    }

    override fun pushDeviceIds(): Set<String> = withIndex { db ->
        stores.values.flatMap { it.pushDeviceIds() }.toMutableSet().also { devices ->
            db.rawQuery("SELECT device FROM member UNION SELECT device FROM archive", null).use { cursor ->
                while (cursor.moveToNext()) devices += cursor.getString(0)
            }
        }
    }

    // The timestamp API cannot express this source's cursor. Production callers use indexed rows.
    override fun pushRecords(deviceId: String, afterTs: Long, limit: Int): List<ImuPushRecord> =
        throw IllegalStateException("IMU membership requires a row cursor")

    override fun indexedPushRecord(deviceId: String, rowId: Long): ImuPushRecord? = withIndex { db ->
        materialize(members(db, deviceId, rowId - 1, 1).filter { it.id == rowId }).firstOrNull()
    }

    override fun indexedPushRows(deviceId: String, afterRowId: Long, limit: Int): List<ImuPushRecord> = withIndex { db ->
        require(afterRowId >= 0 && limit in 1..PushProtocol.MAX_RECORDS + 1)
        val scan = scanPosition(db, "rows", deviceId)
        val pending = members(db, deviceId, afterRowId, limit)
        if (!scan.second && pending.isNotEmpty()) return@withIndex materialize(pending)
        if (scan(db, "rows", deviceId) { origin, segment, snapshot ->
                indexSegment(db, origin, segment, snapshot)
            }) throw ImuInventoryPendingException()
        materialize(members(db, deviceId, afterRowId, limit))
    }

    override fun archiveRows(deviceId: String, limit: Int): List<PushRawBatchRecord> = withIndex { db ->
        require(destination.isNotBlank() && limit in 1..2)
        val pending = pendingArchives(db, deviceId, limit)
        if (pending.isNotEmpty()) return@withIndex pending.map(::archiveRecord)
        val more = scan(db, "archives", deviceId) { origin, segment, snapshot ->
            prepareArchive(db, origin, segment, snapshot)
        }
        val prepared = pendingArchives(db, deviceId, limit)
        if (prepared.isEmpty() && more) throw ImuInventoryPendingException()
        prepared.map(::archiveRecord)
    }

    override fun acknowledgeArchive(deviceId: String, row: PushRawBatchRecord) = withIndex { db ->
        require(destination.isNotBlank())
        val saved = db.rawQuery("SELECT * FROM archive WHERE batchID = ? AND device = ?",
            arrayOf(row.batchId, deviceId)).use { cursor -> if (cursor.moveToFirst()) cursor.archive() else null }
        check(saved != null && archiveRecord(saved) == row) { "IMU archive acknowledgement mismatch" }
        // This is destination-scoped transport progress, not a durability receipt or a pruning gate.
        db.execSQL("INSERT OR IGNORE INTO delivered(destination, batchID) VALUES(?, ?)", arrayOf(destination, row.batchId))
    }

    private data class Member(val id: Long, val device: String, val origin: String, val window: String,
                              val bucket: Long, val ts: Long, val digest: String)
    private data class Archive(val id: Long, val batchId: String, val device: String, val origin: String,
                               val window: String, val bucket: Long, val descriptor: String)

    private fun members(db: SQLiteDatabase, deviceId: String, after: Long, limit: Int): List<Member> =
        db.rawQuery("SELECT * FROM member WHERE device = ? AND id > ? ORDER BY id LIMIT ?",
            arrayOf(deviceId, after.toString(), limit.toString())).use { cursor -> buildList {
                while (cursor.moveToNext()) add(Member(cursor.long("id"), cursor.string("device"),
                    cursor.string("origin"), cursor.string("window"), cursor.long("bucket"),
                    cursor.long("ts"), cursor.string("digest")))
            } }

    private fun materialize(rows: List<Member>): List<ImuPushRecord> {
        var cachedKey: Triple<String, String, Long>? = null
        var cached = emptyMap<Long, ByteArray>()
        return rows.map { member ->
            val key = Triple(member.origin, member.window, member.bucket)
            if (key != cachedKey) {
                val store = stores.getValue(member.origin)
                val window = store.registeredWindows().singleOrNull { it.id == member.window && it.deviceId == member.device }
                    ?: error("IMU member source unavailable")
                cached = store.pushSnapshot(ImuSessionFileStore.PushSegment(window, member.bucket)).records
                    .associate { it.ts to it.columns }
                cachedKey = key
            }
            val columns = cached[member.ts] ?: error("IMU member unavailable")
            check(PushBinaryCodec.sha256Hex(columns) == member.digest) { "IMU member changed" }
            ImuPushRecord(member.ts, columns, member.id)
        }
    }

    private fun scanPosition(db: SQLiteDatabase, lane: String, deviceId: String): Pair<String, Boolean> =
        db.rawQuery("SELECT lastKey, inProgress FROM scan WHERE lane = ? AND device = ?", arrayOf(lane, deviceId))
            .use { if (it.moveToFirst()) it.getString(0) to (it.getInt(1) != 0) else "" to false }

    private fun scan(db: SQLiteDatabase, lane: String, deviceId: String,
                     consume: (String, ImuSessionFileStore.PushSegment, ImuSessionFileStore.PushSnapshot) -> Unit): Boolean {
        val (last, inProgress) = scanPosition(db, lane, deviceId)
        val all = stores.flatMap { (origin, store) -> store.pushSegments(deviceId).map { origin to it } }
            .sortedBy { (origin, segment) -> "$origin/${segment.window.id}/${segment.bucket}" }
        val remaining = all.filter { (origin, segment) ->
            !inProgress || "$origin/${segment.window.id}/${segment.bucket}" > last
        }
        val selected = remaining.take(segmentBudget)
        selected.forEach { (origin, segment) ->
            val snapshot = stores.getValue(origin).pushSnapshot(segment)
            db.beginTransaction()
            try {
                consume(origin, segment, snapshot)
                db.execSQL("INSERT OR REPLACE INTO scan(lane, device, lastKey, inProgress) VALUES(?, ?, ?, 1)",
                    arrayOf(lane, deviceId, "$origin/${segment.window.id}/${segment.bucket}"))
                db.setTransactionSuccessful()
            } finally { db.endTransaction() }
        }
        val more = remaining.size > selected.size
        if (!more) db.execSQL("UPDATE scan SET inProgress = 0 WHERE lane = ? AND device = ?", arrayOf(lane, deviceId))
        return more
    }

    private fun indexSegment(db: SQLiteDatabase, origin: String, segment: ImuSessionFileStore.PushSegment,
                             snapshot: ImuSessionFileStore.PushSnapshot) {
        snapshot.records.forEach { record ->
            db.execSQL("INSERT OR IGNORE INTO member(device, origin, window, bucket, ts, digest) VALUES(?, ?, ?, ?, ?, ?)",
                arrayOf(segment.window.deviceId, origin, segment.window.id, segment.bucket, record.ts,
                    PushBinaryCodec.sha256Hex(record.columns)))
        }
    }

    private fun pendingArchives(db: SQLiteDatabase, deviceId: String, limit: Int): List<Archive> =
        db.rawQuery("SELECT a.* FROM archive a WHERE device = ? AND NOT EXISTS " +
            "(SELECT 1 FROM delivered d WHERE d.batchID = a.batchID AND d.destination = ?) ORDER BY a.id LIMIT ?",
            arrayOf(deviceId, destination, limit.toString())).use { cursor -> buildList {
                while (cursor.moveToNext()) add(cursor.archive())
            } }

    private fun prepareArchive(db: SQLiteDatabase, origin: String, segment: ImuSessionFileStore.PushSegment,
                               snapshot: ImuSessionFileStore.PushSnapshot) {
        if (snapshot.records.isEmpty()) return
        indexSegment(db, origin, segment, snapshot)
        val window = segment.window
        val previous = db.rawQuery("SELECT * FROM archive WHERE device = ? AND origin = ? AND window = ? AND bucket = ? ORDER BY id DESC LIMIT 1",
            arrayOf(window.deviceId, origin, window.id, segment.bucket.toString())).use { if (it.moveToFirst()) it.archive() else null }
        val prefix = previous?.let { JSONObject(it.descriptor) }
        val fileDigest = PushBinaryCodec.sha256Hex(snapshot.bytes)
        if (prefix?.getString("fileSHA256") == fileDigest) return
        val prefixCount = prefix?.getInt("recordCount") ?: 0
        val prefixBytes = prefix?.getInt("fileBytes") ?: 0
        check(prefixCount <= snapshot.records.size && prefixBytes <= snapshot.bytes.size)
        if (prefix != null) check(PushBinaryCodec.sha256Hex(snapshot.bytes.copyOf(prefixBytes)) == prefix.getString("fileSHA256")) {
            "IMU archive prefix changed"
        }
        val entries = snapshot.records.drop(prefixCount).map { record ->
            val digest = PushBinaryCodec.sha256Hex(record.columns)
            val rowId = db.rawQuery("SELECT id FROM member WHERE device = ? AND origin = ? AND window = ? AND bucket = ? AND ts = ? AND digest = ?",
                arrayOf(window.deviceId, origin, window.id, segment.bucket.toString(), record.ts.toString(), digest))
                .use { check(it.moveToFirst()); it.getLong(0) }
            JSONObject(sortedMapOf<String, Any>("rowID" to rowId, "sha256" to digest, "ts" to record.ts))
        }
        val fields = sortedMapOf<String, Any>("version" to 1, "kind" to "noop.imus.archive",
            "ownerNamespace" to storage.namespace, "sourceId" to sourceId, "platform" to "android",
            "device" to window.deviceId, "origin" to origin, "window" to window.id, "bucket" to segment.bucket,
            "windowFrom" to window.from, "fileSHA256" to fileDigest, "fileBytes" to snapshot.bytes.size,
            "recordCount" to snapshot.records.size, "prefixBytes" to prefixBytes, "prefixRecords" to prefixCount,
            "members" to JSONArray(entries))
        window.to?.let { fields["windowTo"] = it }
        if (previous != null) {
            fields["previousArchive"] = previous.batchId
            fields["prefixSHA256"] = prefix!!.getString("fileSHA256")
        }
        val descriptor = JSONObject(fields).toString()
        val encoded = descriptor.toByteArray(Charsets.UTF_8)
        check(encoded.size <= 512 * 1024) { "IMU archive descriptor exceeds limit" }
        val batchId = "imf1.${PushBinaryCodec.sha256Hex(encoded)}.$fileDigest"
        db.execSQL("INSERT OR IGNORE INTO archive(batchID, device, origin, window, bucket, descriptor) VALUES(?, ?, ?, ?, ?, ?)",
            arrayOf(batchId, window.deviceId, origin, window.id, segment.bucket, descriptor))
    }

    private fun archiveRecord(archive: Archive): PushRawBatchRecord {
        val descriptor = JSONObject(archive.descriptor)
        check(descriptor.getString("ownerNamespace") == storage.namespace && descriptor.getString("sourceId") == sourceId)
        val file = stores.getValue(archive.origin).pushArchivePrefix(archive.window, archive.bucket,
            descriptor.getInt("fileBytes"), descriptor.getString("fileSHA256"))
        val encoded = archive.descriptor.toByteArray(Charsets.UTF_8)
        check(archive.batchId == "imf1.${PushBinaryCodec.sha256Hex(encoded)}.${PushBinaryCodec.sha256Hex(file)}")
        return PushRawBatchRecord(archive.id, archive.batchId, archive.bucket, archive.bucket, archive.bucket,
            archive.bucket, archive.bucket + ImuSessionFileStore.SEGMENT_SECONDS, 2, encoded.size + file.size,
            archiveBlob(encoded, file))
    }

    private fun <T> withIndex(block: (SQLiteDatabase) -> T): T = synchronized(lock) {
        // The row sequence is durable identity. Losing the index requires explicit recovery, not a
        // rebuild that can reassign a previous cursor's row ID to another same-second origin.
        val initialized = indexState.getBoolean("initialized", false)
        check(!initialized || indexFile.isFile) { "IMU membership index unavailable" }
        SQLiteDatabase.openOrCreateDatabase(indexFile, null).use { db ->
            db.execSQL("PRAGMA synchronous = FULL")
            val pageSize = db.rawQuery("PRAGMA page_size", null).use { check(it.moveToFirst()); it.getLong(0) }
            db.rawQuery("PRAGMA max_page_count = ${128 * 1024 * 1024L / pageSize}", null).use {
                check(it.moveToFirst() && it.getLong(0) <= 128 * 1024 * 1024L / pageSize)
            }
            check(db.version in 0..1) { "Unknown IMU index version" }
            check(!initialized || db.version == 1) { "IMU membership index reset" }
            if (db.version == 0) {
                db.beginTransaction()
                try {
                    db.execSQL("CREATE TABLE owner(namespace TEXT NOT NULL, sourceID TEXT NOT NULL)")
                    db.execSQL("INSERT INTO owner VALUES(?, ?)", arrayOf(storage.namespace, sourceId))
                    db.execSQL("CREATE TABLE member(id INTEGER PRIMARY KEY AUTOINCREMENT, device TEXT NOT NULL, origin TEXT NOT NULL, window TEXT NOT NULL, bucket INTEGER NOT NULL, ts INTEGER NOT NULL, digest TEXT NOT NULL, UNIQUE(device, origin, window, bucket, ts, digest))")
                    db.execSQL("CREATE INDEX member_device ON member(device, id)")
                    db.execSQL("CREATE TABLE scan(lane TEXT NOT NULL, device TEXT NOT NULL, lastKey TEXT NOT NULL, inProgress INTEGER NOT NULL, PRIMARY KEY(lane, device))")
                    db.execSQL("CREATE TABLE archive(id INTEGER PRIMARY KEY AUTOINCREMENT, batchID TEXT UNIQUE NOT NULL, device TEXT NOT NULL, origin TEXT NOT NULL, window TEXT NOT NULL, bucket INTEGER NOT NULL, descriptor TEXT NOT NULL)")
                    db.execSQL("CREATE INDEX archive_device ON archive(device, id)")
                    db.execSQL("CREATE INDEX archive_segment ON archive(device, origin, window, bucket, id)")
                    db.execSQL("CREATE TABLE delivered(destination TEXT NOT NULL, batchID TEXT NOT NULL, PRIMARY KEY(destination, batchID))")
                    db.version = 1
                    db.setTransactionSuccessful()
                } finally { db.endTransaction() }
            }
            db.rawQuery("SELECT namespace, sourceID FROM owner", null).use {
                check(it.count == 1 && it.moveToFirst() && it.getString(0) == storage.namespace && it.getString(1) == sourceId) {
                    "IMU index owner mismatch"
                }
            }
            if (!initialized) check(indexState.edit().putBoolean("initialized", true).commit()) {
                "IMU index identity could not be persisted"
            }
            block(db)
        }
    }

    private fun Cursor.string(column: String) = getString(getColumnIndexOrThrow(column))
    private fun Cursor.long(column: String) = getLong(getColumnIndexOrThrow(column))
    private fun Cursor.archive() = Archive(long("id"), string("batchID"), string("device"), string("origin"),
        string("window"), long("bucket"), string("descriptor"))

    companion object {
        private val locks = mutableMapOf<String, Any>()
        internal fun archiveBlob(descriptor: ByteArray, file: ByteArray): ByteArray {
            val size = 12 + descriptor.size + file.size
            check(size <= 9 * 1024 * 1024)
            val packed = ByteBuffer.allocate(size).order(ByteOrder.LITTLE_ENDIAN)
                .putInt(2).putInt(descriptor.size).put(descriptor).putInt(file.size).put(file).array()
            val output = ByteArrayOutputStream()
            output.write(ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(size).array())
            // Apple's Compression ZLIB envelope is raw DEFLATE. The .imus file stays byte exact.
            val deflater = Deflater(Deflater.DEFAULT_COMPRESSION, true)
            try { DeflaterOutputStream(output, deflater).use { it.write(packed) } }
            finally { deflater.end() }
            return output.toByteArray()
        }
    }
}

/** A saved bounded inventory still has work; it must not be reported as an empty source. */
class ImuInventoryPendingException : IllegalStateException("IMU inventory pending")
