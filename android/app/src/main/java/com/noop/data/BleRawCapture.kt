package com.noop.data

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import androidx.sqlite.db.SimpleSQLiteQuery
import androidx.sqlite.db.SupportSQLiteDatabase
import com.noop.ble.BleCaptureIdentity
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.UUID
import java.util.zip.Deflater
import java.util.zip.DeflaterOutputStream
import java.util.zip.Inflater

@Entity(tableName = "bleRawBatch", indices = [Index(value = ["batchId"], unique = true), Index(value = ["deviceId", "syncedAt"])])
data class BleRawBatchEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val batchId: String,
    val deviceId: String,
    val namespace: String,
    val generation: String,
    val sourceId: String,
    val sessionId: String,
    val family: String,
    val receivedAtMs: Long,
    val receivedMonotonicNs: Long,
    val deviceClockRef: Long,
    val wallClockRef: Long,
    val clockBasis: String,
    val frameCount: Int,
    val byteSize: Int,
    val framesBlob: ByteArray,
    val contentHash: String,
    val committedAtMs: Long,
    val sealed: Boolean = false,
    val lastReceivedAtMs: Long = receivedAtMs,
    val syncedAt: Long? = null,
)

@Entity(tableName = "bleRawMember", indices = [Index(value = ["rawBatchId"])])
data class BleRawMemberEntity(@PrimaryKey val captureId: String, val rawBatchId: String,
    val captureHash: String, val receivedAtMs: Long, val receivedMonotonicNs: Long,
    val deviceClockRef: Long, val wallClockRef: Long)

/** Required evidence, separate from the rotating diagnostic archive. No pending row is evicted. */
class BleRawCapture private constructor(val row: BleRawBatchEntity) {
    fun insert(db: SupportSQLiteDatabase, capacityBytes: Long = CAPACITY_BYTES) {
        check(db.inTransaction())
        var r = row
        db.query(SimpleSQLiteQuery("SELECT captureHash FROM bleRawMember WHERE captureId=?", arrayOf(r.batchId))).use {
            if (it.moveToFirst()) {
                check(it.getString(0) == r.contentHash) { "Raw capture identity conflict" }
                return
            }
        }
        // Receipt-accepted rows can be reclaimed. SQLite pages/WAL require additional disk headroom.
        db.execSQL("DELETE FROM bleRawMember WHERE rawBatchId IN (SELECT batchId FROM bleRawBatch WHERE syncedAt IS NOT NULL)")
        db.execSQL("DELETE FROM bleRawBatch WHERE syncedAt IS NOT NULL")
        val used = db.query("SELECT COALESCE(SUM(length(framesBlob)+512),0) + (SELECT count(*)*128 FROM bleRawMember) FROM bleRawBatch")
            .use { it.moveToFirst(); it.getLong(0) }
        var previousBytes = 0
        // Local commit and transport sealing are different frontiers. Merge only still-unselected
        // durable rows with identical owner/session/clock offset, bounded to a ten-second window.
        db.query(SimpleSQLiteQuery("""SELECT id,batchId,framesBlob,receivedAtMs,receivedMonotonicNs,
            deviceClockRef,wallClockRef,frameCount FROM bleRawBatch WHERE sealed=0 AND syncedAt IS NULL
            AND namespace=? AND generation=? AND sourceId=? AND deviceId=? AND sessionId=? AND family=?
            AND clockBasis=? AND deviceClockRef-wallClockRef=? AND receivedAtMs BETWEEN ? AND ?
            ORDER BY id DESC LIMIT 1""".trimIndent(), arrayOf(r.namespace,r.generation,r.sourceId,r.deviceId,
                r.sessionId,r.family,r.clockBasis,r.deviceClockRef-r.wallClockRef,r.receivedAtMs-10_000,r.receivedAtMs))).use { cursor ->
            if (cursor.moveToFirst() && cursor.getInt(7) + r.frameCount <= 4096) {
                val existingBlob = cursor.getBlob(2)
                val frames = decodeFrames(existingBlob) + decodeFrames(r.framesBlob)
                if (frames.sumOf { it.size.toLong() + 4 } + 4 <= MAX_BATCH_BYTES) {
                    val combined = create(BleCaptureIdentity(r.namespace,r.generation,r.sourceId,r.deviceId,r.sessionId),
                        frames,r.family,cursor.getLong(3),cursor.getLong(4),cursor.getLong(5),cursor.getLong(6),r.clockBasis,"sealed").row
                    r = combined.copy(id=cursor.getLong(0), batchId=cursor.getString(1), lastReceivedAtMs=row.receivedAtMs)
                    previousBytes = existingBlob.size + 512
                }
            }
        }
        if (r.framesBlob.size.toLong() + 512 + 128 - previousBytes > capacityBytes - used)
            throw IOException("capture_storage_capacity")
        if (previousBytes > 0) {
            db.execSQL("UPDATE bleRawBatch SET framesBlob=?,contentHash=?,frameCount=?,byteSize=?,lastReceivedAtMs=?,committedAtMs=? WHERE id=? AND sealed=0",
                arrayOf(r.framesBlob,r.contentHash,r.frameCount,r.byteSize,r.lastReceivedAtMs,System.currentTimeMillis(),r.id))
        } else {
            db.execSQL("""INSERT INTO bleRawBatch (batchId,deviceId,namespace,generation,sourceId,sessionId,family,
                receivedAtMs,receivedMonotonicNs,deviceClockRef,wallClockRef,clockBasis,frameCount,byteSize,
                framesBlob,contentHash,committedAtMs,sealed,lastReceivedAtMs,syncedAt) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,0,?,NULL)""".trimIndent(),
                arrayOf(r.batchId,r.deviceId,r.namespace,r.generation,r.sourceId,r.sessionId,r.family,
                    r.receivedAtMs,r.receivedMonotonicNs,r.deviceClockRef,r.wallClockRef,r.clockBasis,
                    r.frameCount,r.byteSize,r.framesBlob,r.contentHash,System.currentTimeMillis(),r.lastReceivedAtMs))
        }
        db.execSQL("INSERT INTO bleRawMember VALUES(?,?,?,?,?,?,?)", arrayOf(row.batchId,r.batchId,row.contentHash,
            row.receivedAtMs,row.receivedMonotonicNs,row.deviceClockRef,row.wallClockRef))
    }

    companion object {
        const val CAPACITY_BYTES = 128L * 1024 * 1024
        const val MAX_BATCH_BYTES = 1024 * 1024
        val schema = listOf(
            """CREATE TABLE IF NOT EXISTS bleRawBatch (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                batchId TEXT NOT NULL, deviceId TEXT NOT NULL, namespace TEXT NOT NULL, generation TEXT NOT NULL,
                sourceId TEXT NOT NULL, sessionId TEXT NOT NULL, family TEXT NOT NULL, receivedAtMs INTEGER NOT NULL,
                receivedMonotonicNs INTEGER NOT NULL, deviceClockRef INTEGER NOT NULL, wallClockRef INTEGER NOT NULL,
                clockBasis TEXT NOT NULL, frameCount INTEGER NOT NULL, byteSize INTEGER NOT NULL, framesBlob BLOB NOT NULL,
                contentHash TEXT NOT NULL, committedAtMs INTEGER NOT NULL, sealed INTEGER NOT NULL,
                lastReceivedAtMs INTEGER NOT NULL, syncedAt INTEGER)""".trimIndent(),
            "CREATE UNIQUE INDEX IF NOT EXISTS index_bleRawBatch_batchId ON bleRawBatch(batchId)",
            "CREATE INDEX IF NOT EXISTS index_bleRawBatch_deviceId_syncedAt ON bleRawBatch(deviceId,syncedAt)",
            "CREATE TABLE IF NOT EXISTS bleRawMember (captureId TEXT PRIMARY KEY NOT NULL,rawBatchId TEXT NOT NULL,captureHash TEXT NOT NULL,receivedAtMs INTEGER NOT NULL,receivedMonotonicNs INTEGER NOT NULL,deviceClockRef INTEGER NOT NULL,wallClockRef INTEGER NOT NULL)",
            "CREATE INDEX IF NOT EXISTS index_bleRawMember_rawBatchId ON bleRawMember(rawBatchId)",
        )

        internal fun decodeFrames(blob: ByteArray): List<ByteArray> {
            require(blob.size >= 4)
            val size = ByteBuffer.wrap(blob).order(ByteOrder.LITTLE_ENDIAN).int
            require(size in 4..MAX_BATCH_BYTES)
            val raw = ByteArray(size)
            val inflater = Inflater(true)
            try {
                inflater.setInput(blob,4,blob.size-4)
                var written = 0
                while (written < size) {
                    val count = inflater.inflate(raw,written,size-written)
                    require(count > 0); written += count
                }
                require(inflater.finished() && inflater.remaining == 0)
            } finally { inflater.end() }
            val input = ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN)
            val count = input.int; require(count in 1..4096)
            val result = List(count) {
                val bytes = input.int; require(bytes in 0..input.remaining())
                ByteArray(bytes).also(input::get)
            }
            require(!input.hasRemaining())
            return result
        }

        fun create(identity: BleCaptureIdentity, frames: List<ByteArray>, family: String,
                   receivedAtMs: Long, receivedMonotonicNs: Long, deviceClockRef: Long,
                   wallClockRef: Long, clockBasis: String, occurrence: String): BleRawCapture {
            require(frames.isNotEmpty() && frames.size <= 4096)
            val size = frames.sumOf { it.size.toLong() }
            require(size + 4L * (frames.size + 1) <= MAX_BATCH_BYTES)
            val packed = ByteBuffer.allocate(size.toInt() + 4 * (frames.size + 1)).order(ByteOrder.LITTLE_ENDIAN)
            packed.putInt(frames.size)
            frames.forEach { packed.putInt(it.size); packed.put(it) }
            val raw = packed.array()
            val digest = MessageDigest.getInstance("SHA-256").digest(raw).joinToString("") { "%02x".format(it) }
            val batchId = UUID.nameUUIDFromBytes(
                "${identity.namespace}|${identity.sourceId}|${identity.deviceId}|${identity.sessionId}|$receivedMonotonicNs|$occurrence|$digest".toByteArray()).toString()
            val output = ByteArrayOutputStream()
            output.write(ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(raw.size).array())
            val deflater = Deflater(Deflater.DEFAULT_COMPRESSION, true)
            try { DeflaterOutputStream(output, deflater).use { it.write(raw) } } finally { deflater.end() }
            return BleRawCapture(BleRawBatchEntity(batchId = batchId, deviceId = identity.deviceId,
                namespace = identity.namespace, generation = identity.generation, sourceId = identity.sourceId,
                sessionId = identity.sessionId, family = family, receivedAtMs = receivedAtMs,
                receivedMonotonicNs = receivedMonotonicNs, deviceClockRef = deviceClockRef,
                wallClockRef = wallClockRef, clockBasis = clockBasis, frameCount = frames.size,
                byteSize = size.toInt(), framesBlob = output.toByteArray(), contentHash = digest, committedAtMs = 0))
        }
    }
}
