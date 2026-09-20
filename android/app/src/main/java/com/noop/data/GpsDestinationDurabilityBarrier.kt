package com.noop.data

import android.database.Cursor
import androidx.room.Entity
import androidx.sqlite.db.SupportSQLiteDatabase
import com.noop.account.AccountStorageContext
import java.io.File
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.StandardOpenOption.READ
import java.nio.file.attribute.BasicFileAttributes

/** Bounded account-local control state, never a reusable durability receipt. */
@Entity(tableName = "gpsDestinationBarrier", primaryKeys = ["singleton"])
data class GpsDestinationBarrier(val singleton: Int, val phase: Int)

object GpsDestinationBarrierSchema {
    const val CREATE_SQL = """CREATE TABLE IF NOT EXISTS `gpsDestinationBarrier` (
        `singleton` INTEGER NOT NULL, `phase` INTEGER NOT NULL,
        PRIMARY KEY (`singleton`))"""

    fun create(db: SupportSQLiteDatabase) = db.execSQL(CREATE_SQL)
}

/** All hooks are instance-local. Production uses the actual SQLite and directory operations. */
internal class GpsDestinationDurabilityBarrier(
    private val checkpointView: (SupportSQLiteDatabase) -> SupportSQLiteDatabase = { it },
    private val directories: GpsDestinationDirectorySync = NativeGpsDestinationDirectorySync,
    private val afterStep: (Step) -> Unit = {},
) {
    internal enum class Step { CONTROL_MUTATED, CONTROL_COMMITTED, CHECKPOINT_COMPLETED, DIRECTORIES_SYNCED }

    /** The caller holds the namespace lease until its subsequent exact writer proof and GPS delete. */
    fun synchronize(
        account: AccountStorageContext,
        database: WhoopDatabase,
        durabilityView: (SupportSQLiteDatabase) -> SupportSQLiteDatabase,
        verify: () -> Unit,
    ) {
        check(database.accountIdentity == account.identity) { "GPS barrier owner changed; debt retained" }
        val sql = database.openHelper.writableDatabase
        check(!sql.inTransaction()) { "GPS barrier requires an independent committed transaction" }
        val paths = directoryPlan(account, sql)
        database.runInTransaction {
            requireDurableAccountCommit(durabilityView(sql))
            verify()
            advanceControl(sql)
            afterStep(Step.CONTROL_MUTATED)
        }
        afterStep(Step.CONTROL_COMMITTED)
        check(!sql.inTransaction()) { "GPS checkpoint cannot run inside a transaction" }
        checkedFullCheckpoint(checkpointView(sql))
        afterStep(Step.CHECKPOINT_COMPLETED)
        paths.forEach { directories.sync(it) }
        afterStep(Step.DIRECTORIES_SYNCED)
    }

    private fun advanceControl(sql: SupportSQLiteDatabase) {
        val old = readPhase(sql)
        val next = old?.let { 1 - it } ?: 0
        if (old == null) {
            sql.compileStatement("INSERT INTO gpsDestinationBarrier(singleton,phase) VALUES(1,0)").use {
                check(it.executeInsert() == 1L) { "GPS barrier control insertion failed; debt retained" }
            }
        } else {
            sql.compileStatement("UPDATE gpsDestinationBarrier SET phase=? WHERE singleton=1 AND phase=?").use {
                it.bindLong(1, next.toLong()); it.bindLong(2, old.toLong())
                check(it.executeUpdateDelete() == 1) { "GPS barrier control change failed; debt retained" }
            }
        }
        check(readPhase(sql) == next) { "GPS barrier control readback failed; debt retained" }
    }

    private fun readPhase(sql: SupportSQLiteDatabase): Int? =
        sql.query("SELECT singleton,phase FROM gpsDestinationBarrier LIMIT 2").use { rows ->
            if (!rows.moveToFirst()) return@use null
            check(rows.columnCount == 2 && rows.getType(0) == Cursor.FIELD_TYPE_INTEGER &&
                rows.getType(1) == Cursor.FIELD_TYPE_INTEGER && rows.getLong(0) == 1L && rows.getLong(1) in 0L..1L) {
                "GPS barrier control state is malformed; debt retained"
            }
            val value = rows.getInt(1)
            check(!rows.moveToNext()) { "GPS barrier control capacity exceeded; debt retained" }
            value
        }

    private fun checkedFullCheckpoint(sql: SupportSQLiteDatabase) {
        sql.query("PRAGMA main.wal_checkpoint(FULL)").use { rows ->
            check(rows.columnCount == 3 && rows.moveToFirst() &&
                (0..2).all { rows.getType(it) == Cursor.FIELD_TYPE_INTEGER }) {
                "GPS destination checkpoint result is malformed; debt retained"
            }
            val busy = rows.getLong(0); val frames = rows.getLong(1); val completed = rows.getLong(2)
            check(busy == 0L && frames > 0 && completed == frames && !rows.moveToNext()) {
                "GPS destination checkpoint is incomplete; debt retained"
            }
        }
    }

    private fun directoryPlan(account: AccountStorageContext, sql: SupportSQLiteDatabase): List<File> {
        val files = AccountStorageContext.platform(account).filesDir.canonicalFile
        val accounts = File(files, "accounts-v1")
        val root = File(accounts, account.namespace)
        val databases = File(root, "databases")
        val paths = listOf(databases, root, accounts, files, checkNotNull(files.parentFile))
        paths.forEach { path ->
            val attributes = Files.readAttributes(path.toPath(), BasicFileAttributes::class.java, NOFOLLOW_LINKS)
            check(attributes.isDirectory && !attributes.isSymbolicLink) { "GPS destination directory is unsafe; debt retained" }
        }
        check(account.root.canonicalFile == root && File(checkNotNull(sql.path)).canonicalFile == File(databases, WhoopDatabase.DB_NAME)) {
            "GPS destination path changed; debt retained"
        }
        val attributes = Files.readAttributes(File(databases, WhoopDatabase.DB_NAME).toPath(),
            BasicFileAttributes::class.java, NOFOLLOW_LINKS)
        check(attributes.isRegularFile && !attributes.isSymbolicLink) { "GPS destination file is unsafe; debt retained" }
        return paths
    }
}

internal fun interface GpsDestinationDirectorySync {
    fun sync(directory: File)
}

/** Never opens the active SQLite main/WAL/SHM inode independently of SQLite. */
internal object NativeGpsDestinationDirectorySync : GpsDestinationDirectorySync {
    override fun sync(directory: File) {
        val path = directory.toPath()
        val before = Files.readAttributes(path, BasicFileAttributes::class.java, NOFOLLOW_LINKS)
        check(before.isDirectory && !before.isSymbolicLink && before.fileKey() != null) {
            "GPS destination directory identity unavailable; debt retained"
        }
        fun checkIdentity() {
            val current = Files.readAttributes(path, BasicFileAttributes::class.java, NOFOLLOW_LINKS)
            check(current.isDirectory && !current.isSymbolicLink && current.fileKey() == before.fileKey()) {
                "GPS destination directory moved; debt retained"
            }
        }
        // The namespace lease excludes supported restore/open mutations of these directory paths.
        // Android's NIO force(true) reaches FileDispatcherImpl.force0 -> checked fsync(fd).
        FileChannel.open(path, READ, NOFOLLOW_LINKS).use { channel ->
            checkIdentity()
            channel.force(true)
            checkIdentity()
        }
    }
}
