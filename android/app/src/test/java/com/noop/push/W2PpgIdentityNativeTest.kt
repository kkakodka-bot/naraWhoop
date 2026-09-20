package com.noop.push

import android.app.Application
import androidx.sqlite.db.SupportSQLiteOpenHelper
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.sqlite.db.framework.FrameworkSQLiteOpenHelperFactory
import com.noop.data.WhoopDatabase
import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class W2PpgIdentityNativeTest {
    @Test fun migrationPreservesUnknownAndSameSecondDistinctIdentity() {
        val helper = FrameworkSQLiteOpenHelperFactory().create(SupportSQLiteOpenHelper.Configuration.builder(RuntimeEnvironment.getApplication())
            .name(null).callback(object : SupportSQLiteOpenHelper.Callback(1) {
                override fun onCreate(db: SupportSQLiteDatabase) {
                    db.execSQL("CREATE TABLE ppgWaveformSample(deviceId TEXT NOT NULL,ts INTEGER NOT NULL,samples BLOB NOT NULL,burstIndex INTEGER,PRIMARY KEY(deviceId,ts))")
                    db.execSQL("INSERT INTO ppgWaveformSample(rowid,deviceId,ts,samples,burstIndex) VALUES(77,'fixture',1,X'01000200',NULL)")
                }
                override fun onUpgrade(db: SupportSQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit
            }).build())
        try {
            val db = helper.writableDatabase
            db.beginTransaction()
            try { WhoopDatabase.MIGRATION_39_40.migrate(db); db.setTransactionSuccessful() } finally { db.endTransaction() }
            db.query("SELECT rowid FROM ppgWaveformSample WHERE recordIndex=-1").use {
                assertTrue(it.moveToFirst()); assertEquals(77L, it.getLong(0))
            }
            repeat(2) { db.execSQL("INSERT OR IGNORE INTO ppgWaveformSample VALUES('fixture',1,X'0300',NULL,4294967295)") }
            db.execSQL("INSERT INTO ppgWaveformSample VALUES('fixture',1,X'0400',NULL,12)")
            db.query("SELECT recordIndex,hex(samples) FROM ppgWaveformSample ORDER BY recordIndex").use {
                assertTrue(it.moveToFirst()); assertEquals(-1, it.getLong(0)); assertEquals("01000200", it.getString(1))
                assertTrue(it.moveToNext()); assertEquals(12, it.getLong(0))
                assertTrue(it.moveToNext()); assertEquals(4294967295L, it.getLong(0)); assertFalse(it.moveToNext())
            }
        } finally { helper.close() }
    }
    @Test fun binaryV2PreservesUnsignedRecordIndexAndUnknown() {
        val records = listOf(
            PushBinaryRow.PpgWaveform(PushPpgWaveformRecord(1, 100, null, byteArrayOf(1, 0), 4294967295L)),
            PushBinaryRow.PpgWaveform(PushPpgWaveformRecord(2, 100, null, byteArrayOf(2, 0), null)),
        )
        val bytes = PushBinaryCodec.pack(PushBinaryTable.PPG_WAVEFORM_SAMPLE, records, true)
        val b = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        b.position(4); assertEquals(2, b.get().toInt()); assertEquals(1, b.get().toInt()); assertEquals(2, b.int)
        assertEquals(1, b.long); assertEquals(100, b.long); assertEquals(1, b.get().toInt()); assertEquals(4294967295L, b.long)
        assertEquals(0, b.get().toInt()); assertEquals(2, b.int); assertEquals(1, b.short.toInt())
        assertEquals(2, b.long); assertEquals(100, b.long); assertEquals(0, b.get().toInt())
        assertEquals(0, b.get().toInt()); assertEquals(2, b.int); assertEquals(2, b.short.toInt()); assertFalse(b.hasRemaining())
        assertEquals(10 + records.sumOf { PushBinaryCodec.packedRowSize(it, true) }, bytes.size)
        assertNotEquals(PushProtocol.binaryKeyFingerprint(PushBinaryTable.PPG_WAVEFORM_SAMPLE, "fixture", records[0]),
            PushProtocol.binaryKeyFingerprint(PushBinaryTable.PPG_WAVEFORM_SAMPLE, "fixture", records[1]))
        try { PushBinaryCodec.pack(PushBinaryTable.PPG_WAVEFORM_SAMPLE, records); fail("identity downgrade") }
        catch (expected: PushProtocolException) { assertTrue(expected.message!!.contains("1.3")) }
    }
}
