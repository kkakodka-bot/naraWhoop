package com.noop.data

import android.app.Application
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.sqlite.db.SupportSQLiteOpenHelper
import androidx.sqlite.db.framework.FrameworkSQLiteOpenHelperFactory
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.SQLiteMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
@SQLiteMode(SQLiteMode.Mode.NATIVE)
class PpgRecordIdentityMigrationTest {
    @Test fun migrationPreservesRowIdsBytesAndMultipleRecordsPerSecond() {
        val configuration = SupportSQLiteOpenHelper.Configuration.builder(RuntimeEnvironment.getApplication())
            .name(null).callback(object : SupportSQLiteOpenHelper.Callback(1) {
                override fun onCreate(db: SupportSQLiteDatabase) {
                    db.execSQL("CREATE TABLE ppgWaveformSample(deviceId TEXT NOT NULL, ts INTEGER NOT NULL, " +
                        "samples BLOB NOT NULL, burstIndex INTEGER, PRIMARY KEY(deviceId,ts))")
                    db.execSQL("INSERT INTO ppgWaveformSample(rowid,deviceId,ts,samples,burstIndex) VALUES(88,'d',123,X'0100ff7f',14)")
                }
                override fun onUpgrade(db: SupportSQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit
            }).build()
        FrameworkSQLiteOpenHelperFactory().create(configuration).use { helper ->
            val db = helper.writableDatabase
            db.beginTransaction()
            try {
                WhoopDatabase.MIGRATION_39_40.migrate(db)
                db.setTransactionSuccessful()
            } finally { db.endTransaction() }
            db.query("SELECT rowid,samples,recordIndex FROM ppgWaveformSample").use {
                assertTrue(it.moveToFirst())
                assertEquals(88L, it.getLong(0))
                assertArrayEquals(byteArrayOf(1, 0, -1, 127), it.getBlob(1))
                assertEquals(-1L, it.getLong(2))
            }
            repeat(2) {
                db.execSQL("INSERT OR IGNORE INTO ppgWaveformSample VALUES('d',123,X'0200',14,4294967295)")
                db.execSQL("INSERT OR IGNORE INTO ppgWaveformSample VALUES('d',123,X'0300',14,0)")
            }
            db.query("SELECT count(*) FROM ppgWaveformSample").use {
                assertTrue(it.moveToFirst()); assertEquals(3, it.getInt(0))
            }
        }
    }
}
