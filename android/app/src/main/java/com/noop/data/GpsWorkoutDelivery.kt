package com.noop.data

import android.database.Cursor
import androidx.room.Entity
import androidx.sqlite.db.SimpleSQLiteQuery
import androidx.sqlite.db.SupportSQLiteDatabase
import com.noop.account.AccountStorageContext
import com.noop.location.GpsWorkoutPayload
import com.noop.location.GpsWorkoutProjectionWitness
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicBoolean

/** Retained independently of workout edits/deletion; no cascade or eviction authority. */
@Entity(tableName = "gpsWorkoutDelivery", primaryKeys = ["deviceId", "startTs", "sport"])
data class GpsWorkoutDelivery(
    val deviceId: String,
    val startTs: Long,
    val sport: String,
    val namespace: String,
    val projectURL: String,
    val userID: String,
    val capturedGeneration: String,
    val sessionId: String,
    val formatVersion: Int,
    val payload: ByteArray,
    val payloadSha256: String,
    val witness: ByteArray,
    val witnessSha256: String,
    val captureCount: Int,
    val witnessCount: Int,
    val retainedBytes: Long,
)

object GpsWorkoutDeliverySchema {
    const val CREATE_SQL = """CREATE TABLE IF NOT EXISTS `gpsWorkoutDelivery` (
        `deviceId` TEXT NOT NULL, `startTs` INTEGER NOT NULL, `sport` TEXT NOT NULL,
        `namespace` TEXT NOT NULL, `projectURL` TEXT NOT NULL, `userID` TEXT NOT NULL,
        `capturedGeneration` TEXT NOT NULL, `sessionId` TEXT NOT NULL, `formatVersion` INTEGER NOT NULL,
        `payload` BLOB NOT NULL, `payloadSha256` TEXT NOT NULL, `witness` BLOB NOT NULL,
        `witnessSha256` TEXT NOT NULL, `captureCount` INTEGER NOT NULL, `witnessCount` INTEGER NOT NULL,
        `retainedBytes` INTEGER NOT NULL, PRIMARY KEY (`deviceId`, `startTs`, `sport`))"""
    fun create(db: SupportSQLiteDatabase) = db.execSQL(CREATE_SQL)
}

/** Issued after the Room transaction returns; the same captured repository may publish it once. */
internal class GpsWorkoutCommit internal constructor(
    val account: AccountStorageContext,
    val database: WhoopDatabase,
    val insertedHr: Int,
) {
    private val published = AtomicBoolean(false)
    internal fun publishOnce(body: () -> Unit): Boolean {
        if (!published.compareAndSet(false, true)) return false
        body()
        return true
    }
}

internal class GpsWorkoutDeliveryStore(
    private val account: AccountStorageContext,
    private val database: WhoopDatabase,
    private val limits: Limits = Limits(),
) {
    internal data class Limits(val artifacts: Int = 1_024, val bytes: Long = 256L * 1024 * 1024) {
        init { require(artifacts in 1..1_024 && bytes in 1..(256L * 1024 * 1024)) }
    }

    /** Caller owns the writer transaction, including the native FULL/WAL guard. */
    suspend fun deliver(payload: GpsWorkoutPayload): Int {
        val db = writer(payload)
        val bytes = payload.encode()
        val retained = read(db, payload)
        val witness = retained?.let { validate(it, payload, bytes) }
        if (retained == null) admit(db, bytes.size, 12 + 20 * GpsWorkoutProjectionWitness.firstOrdinals(payload).size)

        val dao = database.whoopDao()
        val row = payload.row
        val existing = workoutMatches(db, row)
        check(existing == null || existing) { "GPS destination workout differs; debt retained" }
        if (existing == null) dao.upsertWorkouts(listOf(row))

        val inserted: Int
        if (witness == null) {
            val ids = ArrayList<Long>(payload.samples.size)
            payload.samples.chunked(512).forEach { chunk ->
                val results = dao.insertHr(chunk)
                check(results.size == chunk.size); ids.addAll(results)
            }
            inserted = ids.count { it > 0 }
            val projected = GpsWorkoutProjectionWitness.capture(payload, canonical(db, payload), ids)
            val witnessBytes = projected.encode()
            val artifact = artifact(payload, bytes, witnessBytes, projected.entries.size)
            db.execSQL(INSERT_SQL, values(artifact))
        } else {
            val actual = canonical(db, payload)
            val missing = witness.entries.mapNotNull { entry ->
                val present = actual[entry.row.ts]
                check(present == null || present == entry.row) { "GPS canonical heart rate differs; debt retained" }
                entry.row.takeIf { present == null }
            }
            inserted = missing.chunked(512).sumOf { chunk -> dao.insertHr(chunk).count { it > 0 } }
        }
        verify(payload)
        return inserted
    }

    /** Exact current destination proof; it never creates an absent artifact or changes its witness. */
    fun verify(payload: GpsWorkoutPayload) {
        val db = writer(payload)
        val row = payload.row
        check(workoutMatches(db, row) == true) {
            "GPS destination changed or restored; debt retained"
        }
        val retained = checkNotNull(read(db, payload)) { "GPS retained delivery missing; debt retained" }
        val witness = validate(retained, payload, payload.encode())
        val actual = canonical(db, payload)
        check(actual.size == witness.entries.size && witness.entries.all { actual[it.row.ts] == it.row }) {
            "GPS canonical witness differs; debt retained"
        }
    }

    private fun writer(payload: GpsWorkoutPayload): SupportSQLiteDatabase {
        check(database.accountIdentity == account.identity) { "GPS database generation differs" }
        check(payload.namespace == account.namespace && payload.project == account.identity.projectURL &&
            payload.user == account.identity.scope?.userID) { "GPS artifact owner differs" }
        val db = database.openHelper.writableDatabase
        check(db.inTransaction()) { "GPS delivery requires a writer transaction" }
        db.query("SELECT projectURL,userID FROM localAccountOwner WHERE singleton=1").use {
            check(it.moveToFirst() && it.text(0) == payload.project && it.text(1) == payload.user && !it.moveToNext())
        }
        return db
    }

    private fun canonical(db: SupportSQLiteDatabase, payload: GpsWorkoutPayload): Map<Long, HrSample> {
        val keys = GpsWorkoutProjectionWitness.firstOrdinals(payload).keys.toList()
        val result = linkedMapOf<Long, HrSample>()
        keys.chunked(512).forEach { chunk ->
            db.query(SimpleSQLiteQuery("SELECT deviceId,ts,bpm,synced FROM hrSample WHERE deviceId=? AND ts IN (${chunk.joinToString(",") { "?" }})",
                (listOf<Any>(payload.row.deviceId) + chunk).toTypedArray())).use { rows ->
                while (rows.moveToNext()) {
                    val hr = HrSample(rows.text(0), rows.long(1), rows.integer(2), rows.integer(3))
                    check(hr.deviceId == payload.row.deviceId && hr.ts in chunk && result.put(hr.ts, hr) == null)
                }
            }
        }
        return result
    }

    // Compare all twelve non-key fields in SQLite; large route/notes text must not have to fit
    // inside one Android CursorWindow merely to prove an already frozen workout.
    private fun workoutMatches(db: SupportSQLiteDatabase, row: WorkoutRow): Boolean? = db.query(SimpleSQLiteQuery(
        """SELECT endTs IS ? AND source IS ? AND durationS IS ? AND energyKcal IS ? AND avgHr IS ? AND
            maxHr IS ? AND strain IS ? AND distanceM IS ? AND zonesJSON IS ? AND notes IS ? AND
            routePolyline IS ? AND steps IS ? FROM workout WHERE deviceId=? AND startTs=? AND sport=?""",
        arrayOf<Any?>(row.endTs, row.source, row.durationS, row.energyKcal, row.avgHr, row.maxHr, row.strain,
            row.distanceM, row.zonesJSON, row.notes, row.routePolyline, row.steps, row.deviceId, row.startTs, row.sport),
    )).use { if (it.moveToFirst()) it.integer(0) == 1 else null }

    private fun artifact(payload: GpsWorkoutPayload, bytes: ByteArray, witness: ByteArray, count: Int) = GpsWorkoutDelivery(
        payload.row.deviceId, payload.row.startTs, payload.row.sport, payload.namespace, payload.project, payload.user,
        payload.capturedGeneration, payload.sessionId, 1, bytes, sha256(bytes), witness, sha256(witness),
        payload.samples.size, count, bytes.size.toLong() + witness.size + METADATA_BYTES,
    ).also { checkMetadata(it) }

    private fun validate(saved: GpsWorkoutDelivery, payload: GpsWorkoutPayload, bytes: ByteArray): GpsWorkoutProjectionWitness {
        checkMetadata(saved)
        check(saved.deviceId == payload.row.deviceId && saved.startTs == payload.row.startTs && saved.sport == payload.row.sport &&
            saved.namespace == payload.namespace && saved.projectURL == payload.project && saved.userID == payload.user &&
            saved.capturedGeneration == payload.capturedGeneration && saved.sessionId == payload.sessionId && saved.formatVersion == 1 &&
            saved.captureCount == payload.samples.size && saved.payload.contentEquals(bytes) && saved.payloadSha256 == sha256(bytes) &&
            saved.witnessSha256 == sha256(saved.witness) && saved.retainedBytes == bytes.size.toLong() + saved.witness.size + METADATA_BYTES) {
            "GPS immutable delivery differs; debt retained"
        }
        return GpsWorkoutProjectionWitness.decode(saved.witness, payload).also { check(it.entries.size == saved.witnessCount) }
    }

    private fun checkMetadata(value: GpsWorkoutDelivery) {
        check(value.payload.size in 1..GpsWorkoutPayload.MAX_BYTES && value.witness.size in 12..GpsWorkoutProjectionWitness.MAX_BYTES)
        val text = listOf(value.deviceId, value.sport, value.namespace, value.projectURL, value.userID,
            value.capturedGeneration, value.sessionId, value.payloadSha256, value.witnessSha256)
        check(text.sumOf { it.toByteArray(Charsets.UTF_8).size.toLong() } <= METADATA_BYTES) { "GPS artifact metadata capacity reached" }
    }

    private fun admit(db: SupportSQLiteDatabase, payloadBytes: Int, witnessBytes: Int) {
        val needed = payloadBytes.toLong() + witnessBytes + METADATA_BYTES
        db.query("""SELECT count(*),coalesce(sum(retainedBytes),0),count(CASE WHEN
            typeof(payload)<>'blob' OR typeof(witness)<>'blob' OR typeof(retainedBytes)<>'integer' OR
            length(payload) NOT BETWEEN 1 AND ${GpsWorkoutPayload.MAX_BYTES} OR
            length(witness) NOT BETWEEN 12 AND ${GpsWorkoutProjectionWitness.MAX_BYTES} OR
            retainedBytes<>length(payload)+length(witness)+$METADATA_BYTES THEN 1 END)
            FROM gpsWorkoutDelivery""").use {
            check(it.moveToFirst() && it.long(2) == 0L) { "GPS retained quota requires recovery" }
            val count = it.long(0); val bytes = it.long(1)
            check(count >= 0 && count < limits.artifacts && bytes >= 0 && needed <= limits.bytes - bytes) {
                "GPS retained delivery capacity reached; debt retained"
            }
        }
    }

    private fun read(db: SupportSQLiteDatabase, payload: GpsWorkoutPayload): GpsWorkoutDelivery? {
        val key = arrayOf<Any>(payload.row.deviceId, payload.row.startTs, payload.row.sport)
        val header = db.query(SimpleSQLiteQuery("""SELECT namespace,projectURL,userID,capturedGeneration,sessionId,formatVersion,
            payloadSha256,witnessSha256,captureCount,witnessCount,retainedBytes,length(payload),length(witness),typeof(payload),typeof(witness)
            FROM gpsWorkoutDelivery WHERE $KEY""", key)).use {
            if (!it.moveToFirst()) return null
            check(it.text(13) == "blob" && it.text(14) == "blob")
            val payloadLength = it.integer(11); val witnessLength = it.integer(12)
            check(payloadLength in 1..GpsWorkoutPayload.MAX_BYTES && witnessLength in 12..GpsWorkoutProjectionWitness.MAX_BYTES)
            GpsWorkoutDelivery(payload.row.deviceId, payload.row.startTs, payload.row.sport,
                it.text(0), it.text(1), it.text(2), it.text(3), it.text(4), it.integer(5),
                ByteArray(payloadLength), it.text(6), ByteArray(witnessLength), it.text(7), it.integer(8), it.integer(9), it.long(10))
        }
        readBlob(db, key, "payload", header.payload)
        readBlob(db, key, "witness", header.witness)
        return header
    }

    private fun readBlob(db: SupportSQLiteDatabase, key: Array<Any>, column: String, target: ByteArray) {
        var offset = 0
        while (offset < target.size) {
            val count = minOf(65_536, target.size - offset)
            db.query(SimpleSQLiteQuery("SELECT substr($column,?,?) FROM gpsWorkoutDelivery WHERE $KEY",
                arrayOf<Any>(offset + 1, count, *key))).use {
                check(it.moveToFirst() && it.getType(0) == Cursor.FIELD_TYPE_BLOB)
                val chunk = it.getBlob(0); check(chunk.size == count); chunk.copyInto(target, offset)
            }
            offset += count
        }
    }

    companion object {
        const val METADATA_BYTES = 8_192L
        private const val KEY = "deviceId=? AND startTs=? AND sport=?"
        private const val INSERT_SQL = "INSERT INTO gpsWorkoutDelivery (deviceId,startTs,sport,namespace,projectURL,userID,capturedGeneration,sessionId,formatVersion,payload,payloadSha256,witness,witnessSha256,captureCount,witnessCount,retainedBytes) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
        private fun values(v: GpsWorkoutDelivery): Array<Any> = arrayOf(v.deviceId, v.startTs, v.sport, v.namespace, v.projectURL,
            v.userID, v.capturedGeneration, v.sessionId, v.formatVersion, v.payload, v.payloadSha256, v.witness, v.witnessSha256,
            v.captureCount, v.witnessCount, v.retainedBytes)
        private fun Cursor.text(i: Int): String { check(getType(i) == Cursor.FIELD_TYPE_STRING); return getString(i) }
        private fun Cursor.long(i: Int): Long { check(getType(i) == Cursor.FIELD_TYPE_INTEGER); return getLong(i) }
        private fun Cursor.integer(i: Int): Int = long(i).also { check(it in Int.MIN_VALUE..Int.MAX_VALUE) }.toInt()
        internal fun sha256(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    }
}
