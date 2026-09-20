package com.noop.data

import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.sqlite.db.SupportSQLiteOpenHelper

/** Configures the native connection before Room's schema transaction or any data handoff. */
internal class DurableAccountOpenHelperFactory(
    private val delegate: SupportSQLiteOpenHelper.Factory = CorruptionPreservingOpenHelperFactory(),
) : SupportSQLiteOpenHelper.Factory {
    override fun create(configuration: SupportSQLiteOpenHelper.Configuration): SupportSQLiteOpenHelper {
        val callback = configuration.callback
        val durable = SupportSQLiteOpenHelper.Configuration.builder(configuration.context)
            .name(configuration.name)
            .noBackupDirectory(configuration.useNoBackupDirectory)
            .allowDataLossOnRecovery(false)
            .callback(object : SupportSQLiteOpenHelper.Callback(callback.version) {
                override fun onConfigure(db: SupportSQLiteDatabase) {
                    callback.onConfigure(db)
                    // This is the native configure callback, outside the account fence's implicit
                    // write transaction. SQLite cannot change synchronous inside a transaction.
                    db.execSQL("PRAGMA synchronous=FULL")
                }
                override fun onCreate(db: SupportSQLiteDatabase) = callback.onCreate(db)
                override fun onUpgrade(db: SupportSQLiteDatabase, oldVersion: Int, newVersion: Int) =
                    callback.onUpgrade(db, oldVersion, newVersion)
                override fun onDowngrade(db: SupportSQLiteDatabase, oldVersion: Int, newVersion: Int) =
                    callback.onDowngrade(db, oldVersion, newVersion)
                override fun onOpen(db: SupportSQLiteDatabase) {
                    // WAL readers can use another pooled connection. Verify the writer, not a
                    // connection arbitrarily selected for an out-of-transaction PRAGMA query.
                    db.beginTransaction()
                    try { requireDurableAccountCommit(db) } finally { db.endTransaction() }
                    callback.onOpen(db)
                }
                override fun onCorruption(db: SupportSQLiteDatabase) = callback.onCorruption(db)
            }).build()
        return delegate.create(durable)
    }
}

/** Check again on the active writer transaction before surrendering a separate durable copy.
 * These are configuration guarantees; they do not certify the device filesystem or power supply.
 */
internal fun requireDurableAccountCommit(db: SupportSQLiteDatabase) {
    check(!db.isReadOnly) { "Account destination is read-only; durable handoff retained" }
    check(db.inTransaction()) { "Durable handoff must verify its active writer transaction" }
    db.query("PRAGMA journal_mode").use { cursor ->
        check(cursor.moveToFirst() && cursor.getString(0).equals("wal", ignoreCase = true)) {
            "Account destination requires WAL; durable handoff retained"
        }
    }
    db.query("PRAGMA synchronous").use { cursor ->
        check(cursor.moveToFirst() && cursor.getInt(0) in 2..3) {
            "Account destination requires FULL synchronization; durable handoff retained"
        }
    }
}
