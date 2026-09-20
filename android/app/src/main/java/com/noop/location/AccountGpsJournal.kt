package com.noop.location

import android.database.DatabaseErrorHandler
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteException
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.sqlite.db.SupportSQLiteOpenHelper
import androidx.sqlite.db.framework.FrameworkSQLiteOpenHelperFactory
import com.noop.account.AccountFencedOpenHelperFactory
import com.noop.account.AccountStorageContext
import com.noop.account.AccountWriteFence
import com.noop.analytics.RouteMath
import com.noop.analytics.RouteMath.LatLng
import java.io.File
import java.util.UUID

/** Local workout debt. A saved-workout commit or explicit discard is the only deletion authority. */
internal class AccountGpsJournal(
    private val account: AccountStorageContext,
    private val fence: AccountWriteFence,
    private val maxPoints: Int = 262_144,
    private val beforeCommit: () -> Unit = {},
) : AutoCloseable {
    init { require(maxPoints in 1..262_144) }
    data class Snapshot(
        val id: String, val deviceId: String, val startMs: Long, val sport: String,
        val pausedAtMs: Long?, val pausedDurationMs: Long, val lastMs: Long,
        val endMs: Long?, val pointCount: Int, val distanceM: Double, val track: List<LatLng>,
    )

    private var helper: SupportSQLiteOpenHelper? = null

    private fun database(): SupportSQLiteDatabase {
        fence.check()
        helper?.let { return it.writableDatabase }
        val path = account.getDatabasePath(FILE_NAME)
        verifyExisting(path)
        val callback = object : SupportSQLiteOpenHelper.Callback(2) {
            override fun onConfigure(db: SupportSQLiteDatabase) {
                db.execSQL("PRAGMA synchronous=FULL")
                db.execSQL("PRAGMA foreign_keys=ON")
            }
            override fun onCreate(db: SupportSQLiteDatabase) {
                db.execSQL("CREATE TABLE gpsOwner(singleton INTEGER PRIMARY KEY CHECK(singleton=1), namespace TEXT NOT NULL, project TEXT NOT NULL, user TEXT NOT NULL)")
                db.execSQL("INSERT INTO gpsOwner VALUES(1,?,?,?)", ownerValues())
                db.execSQL("CREATE TABLE gpsSession(singleton INTEGER PRIMARY KEY CHECK(singleton=1), id TEXT NOT NULL UNIQUE, device TEXT NOT NULL, startMs INTEGER NOT NULL, sport TEXT NOT NULL, pausedAtMs INTEGER, pausedDurationMs INTEGER NOT NULL, lastMs INTEGER NOT NULL, endMs INTEGER, pointCount INTEGER NOT NULL, distanceM REAL NOT NULL)")
                db.execSQL("CREATE TABLE gpsPoint(ordinal INTEGER PRIMARY KEY, latitudeBits INTEGER NOT NULL, longitudeBits INTEGER NOT NULL)")
                createFinalization(db)
            }
            override fun onUpgrade(db: SupportSQLiteDatabase, oldVersion: Int, newVersion: Int) {
                check(oldVersion == 1 && newVersion == 2) { "GPS journal version requires recovery" }
                createFinalization(db)
            }
            override fun onCorruption(db: SupportSQLiteDatabase) =
                throw SQLiteException("GPS journal requires recovery; files retained")
            override fun onOpen(db: SupportSQLiteDatabase) {
                db.query("SELECT namespace,project,user FROM gpsOwner WHERE singleton=1").use {
                    check(it.moveToFirst() && (0..2).all { column -> it.getString(column) == ownerValues()[column] })
                }
                db.query("PRAGMA synchronous").use { check(it.moveToFirst() && it.getInt(0) == 2) }
            }
        }
        val created = AccountFencedOpenHelperFactory(fence, FrameworkSQLiteOpenHelperFactory()).create(
            SupportSQLiteOpenHelper.Configuration.builder(account).name(path.absolutePath)
                .callback(callback).allowDataLossOnRecovery(false).build(),
        )
        try {
            created.setWriteAheadLoggingEnabled(true)
            val db = created.writableDatabase
            fence.check()
            helper = created
            return db
        } catch (failure: Throwable) { created.close(); throw failure }
    }

    private fun ownerValues(): Array<Any> = arrayOf(account.namespace, account.identity.projectURL.orEmpty(), account.identity.scope?.userID.orEmpty())

    private fun verifyExisting(file: File) {
        if (!file.exists()) {
            check(!File(file.path + "-wal").exists() && !File(file.path + "-shm").exists())
            return
        }
        SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READONLY or SQLiteDatabase.NO_LOCALIZED_COLLATORS,
            DatabaseErrorHandler { /* Unrecognized or corrupt debt is never replaced. */ }).use { db ->
            check(db.version in 1..2)
            db.rawQuery("SELECT namespace,project,user FROM gpsOwner WHERE singleton=1", null).use {
                check(it.moveToFirst() && (0..2).all { column -> it.getString(column) == ownerValues()[column] })
            }
        }
    }

    private fun <T> transaction(body: (SupportSQLiteDatabase) -> T): T {
        val db = database()
        db.beginTransaction()
        try {
            val result = body(db)
            beforeCommit()
            db.setTransactionSuccessful()
            return result
        } finally { db.endTransaction() }
    }

    fun read(fullTrack: Boolean = false): Snapshot? = read(database(), fullTrack)

    private fun read(db: SupportSQLiteDatabase, fullTrack: Boolean = false): Snapshot? {
        val header = db.query("SELECT id,device,startMs,sport,pausedAtMs,pausedDurationMs,lastMs,endMs,pointCount,distanceM FROM gpsSession WHERE singleton=1").use {
            if (!it.moveToFirst()) return null
            Snapshot(it.getString(0), it.getString(1), it.getLong(2), it.getString(3),
                if (it.isNull(4)) null else it.getLong(4), it.getLong(5), it.getLong(6),
                if (it.isNull(7)) null else it.getLong(7), it.getInt(8), it.getDouble(9), emptyList())
        }
        check(header.pointCount in 0..262_144 && header.distanceM.isFinite() && header.distanceM >= 0)
        val track = ArrayList<LatLng>()
        val first = if (fullTrack) 0 else (header.pointCount - DISPLAY_POINTS).coerceAtLeast(0)
        db.query("SELECT latitudeBits,longitudeBits,ordinal FROM gpsPoint WHERE ordinal>=? ORDER BY ordinal LIMIT ?",
            arrayOf(first, if (fullTrack) 262_145 else DISPLAY_POINTS + 1)).use {
            while (it.moveToNext()) {
                check(it.getInt(2) == first + track.size)
                val point = LatLng(Double.fromBits(it.getLong(0)), Double.fromBits(it.getLong(1)))
                check(point.lat.isFinite() && point.lat in -90.0..90.0 && point.lon.isFinite() && point.lon in -180.0..180.0)
                track += point
            }
        }
        check(track.size == header.pointCount - first)
        return header.copy(track = track)
    }

    fun start(startMs: Long, sport: String, deviceId: String): Snapshot = transaction { db ->
        require(startMs > 0 && sport.isNotBlank() && sport.length <= 256 && deviceId.isNotBlank() && deviceId.length <= 256)
        check(read(db) == null) { "An interrupted GPS workout must be settled first" }
        db.query("SELECT COUNT(*) FROM gpsPoint").use { check(it.moveToFirst() && it.getInt(0) == 0) }
        db.query("SELECT COUNT(*) FROM gpsFinalization").use { check(it.moveToFirst() && it.getInt(0) == 0) }
        val id = UUID.randomUUID().toString()
        db.execSQL("INSERT INTO gpsSession VALUES(1,?,?,?,?,NULL,0,?,NULL,0,0)", arrayOf(id, deviceId, startMs, sport, startMs))
        checkNotNull(read(db))
    }

    fun append(id: String, point: LatLng, nowMs: Long): Snapshot = transaction { db ->
        require(point.lat.isFinite() && point.lat in -90.0..90.0 && point.lon.isFinite() && point.lon in -180.0..180.0)
        val s = current(db, id)
        check(s.endMs == null && s.pausedAtMs == null)
        check(s.pointCount < maxPoints) { "GPS journal capacity reached; saved points retained" }
        val distance = s.distanceM + (s.track.lastOrNull()?.let { RouteMath.haversineMeters(it, point) } ?: 0.0)
        db.execSQL("INSERT INTO gpsPoint VALUES(?,?,?)", arrayOf(s.pointCount, point.lat.toRawBits(), point.lon.toRawBits()))
        db.execSQL("UPDATE gpsSession SET pointCount=pointCount+1,distanceM=?,lastMs=? WHERE singleton=1", arrayOf(distance, maxOf(nowMs, s.lastMs)))
        checkNotNull(read(db))
    }

    fun pause(id: String, nowMs: Long, recovering: Boolean = false): Snapshot = transaction { db ->
        val s = current(db, id)
        if (s.endMs == null && s.pausedAtMs == null) {
            val at = if (recovering) s.lastMs else maxOf(nowMs, s.lastMs)
            db.execSQL("UPDATE gpsSession SET pausedAtMs=? WHERE singleton=1", arrayOf(at))
        }
        checkNotNull(read(db))
    }

    fun resume(id: String, nowMs: Long): Snapshot = transaction { db ->
        val s = current(db, id)
        check(s.endMs == null)
        val pause = s.pausedAtMs
        if (pause != null) db.execSQL("UPDATE gpsSession SET pausedAtMs=NULL,pausedDurationMs=?,lastMs=? WHERE singleton=1",
            arrayOf(s.pausedDurationMs + (nowMs - pause).coerceAtLeast(0), maxOf(s.lastMs, nowMs)))
        checkNotNull(read(db))
    }

    fun finish(id: String, nowMs: Long): Snapshot = transaction { db ->
        val s = current(db, id)
        if (s.endMs == null) {
            val end = maxOf(nowMs, s.lastMs)
            val paused = s.pausedDurationMs + (s.pausedAtMs?.let { (end - it).coerceAtLeast(0) } ?: 0)
            db.execSQL("UPDATE gpsSession SET endMs=?,pausedDurationMs=?,pausedAtMs=? WHERE singleton=1", arrayOf(end, paused, end))
        }
        checkNotNull(read(db, fullTrack = true))
    }

    fun finalization(id: String): GpsWorkoutPayload? = finalization(database(), id)

    private fun finalization(db: SupportSQLiteDatabase, id: String): GpsWorkoutPayload? {
        val session = current(db, id)
        val size = db.query("SELECT sessionId,length(payload) FROM gpsFinalization WHERE singleton=1").use {
            if (!it.moveToFirst()) return null
            check(it.getString(0) == id && it.getLong(1) in 1..GpsWorkoutPayload.MAX_BYTES.toLong())
            it.getInt(1)
        }
        // A bounded payload can still exceed Android's CursorWindow; never fetch the whole BLOB as
        // one cursor row. Each read remains below the window limit without truncating the intent.
        val bytes = ByteArray(size)
        var offset = 0
        while (offset < size) {
            val count = minOf(64 * 1024, size - offset)
            db.query("SELECT substr(payload,?,?) FROM gpsFinalization WHERE singleton=1 AND sessionId=?",
                arrayOf(offset + 1, count, id)).use {
                check(it.moveToFirst())
                val part = it.getBlob(0); check(part.size == count)
                part.copyInto(bytes, offset)
            }
            offset += count
        }
        return GpsWorkoutPayload.decode(bytes).also { it.validate(account, session) }
    }

    fun freezeFinalization(payload: GpsWorkoutPayload): GpsWorkoutPayload = transaction { db ->
        val session = current(db, payload.sessionId)
        payload.validate(account, session)
        val bytes = payload.encode()
        val prior = finalization(db, payload.sessionId)
        if (prior != null) {
            check(prior.encode().contentEquals(bytes)) { "GPS finalization is immutable" }
            prior
        } else {
            check(payload.row.routePolyline == if (session.pointCount >= 2)
                RouteMath.encode(checkNotNull(read(db, fullTrack = true)).track) else null)
            db.execSQL("INSERT INTO gpsFinalization(singleton,sessionId,payload) VALUES(1,?,?)", arrayOf(payload.sessionId, bytes))
            payload
        }
    }

    fun settle(id: String, explicitDiscard: Boolean = false, expectedPayload: ByteArray? = null) = transaction { db ->
        val s = current(db, id)
        if (!explicitDiscard) {
            check(s.endMs != null && expectedPayload != null)
            check(checkNotNull(finalization(db, id)).encode().contentEquals(expectedPayload))
        }
        db.execSQL("DELETE FROM gpsFinalization WHERE singleton=1")
        db.execSQL("DELETE FROM gpsPoint")
        db.execSQL("DELETE FROM gpsSession WHERE singleton=1")
    }

    private fun current(db: SupportSQLiteDatabase, id: String): Snapshot = checkNotNull(read(db)).also { check(it.id == id) }
    override fun close() { helper?.close(); helper = null }

    companion object {
        const val FILE_NAME = "gps_workout_v1.sqlite"
        const val DISPLAY_POINTS = 2048
        private fun createFinalization(db: SupportSQLiteDatabase) = db.execSQL(
            "CREATE TABLE gpsFinalization(singleton INTEGER PRIMARY KEY CHECK(singleton=1), sessionId TEXT NOT NULL UNIQUE, " +
                "payload BLOB NOT NULL CHECK(length(payload)>0 AND length(payload)<=16777216), " +
                "FOREIGN KEY(sessionId) REFERENCES gpsSession(id))",
        )
    }
}
