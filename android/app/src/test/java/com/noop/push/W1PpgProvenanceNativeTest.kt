package com.noop.push

import android.app.Application
import com.noop.data.*
import com.noop.protocol.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import kotlin.math.PI
import kotlin.math.sin

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class W1PpgProvenanceNativeTest {
    private val start = 1_780_917_232L
    private val template = ("aa015000010035412f1a80ad418401f0a3266aae470100c3c5050068faccfa8dfb46fc8bfd4c" +
        "febafedafe6dff56ffd5fffbff37ff6afce5f9d7f8dffa5efc98fddbfe5afe84fe15ff5cff40" +
        "5fb33c50080101006cb67c17").chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    private fun records(): List<PpgHr.Record> {
        val base = (0 until 12).map { s -> PpgHr.Record(start + s, s.toLong(), (0 until 24).map { i ->
            (1000 * sin(2 * PI * (70.0 / 60) * (s * 24 + i) / 24)).toInt()
        }) }
        return base.reversed() + base[6].copy(recordIndex = 4294967295L, samples = base[6].samples.map { -it })
    }
    private fun frame(record: PpgHr.Record) = template.copyOf().also { bytes ->
        fun u32(offset: Int, value: Long) { repeat(4) { bytes[offset + it] = (value ushr (8 * it)).toByte() } }
        u32(11, record.recordIndex!!); u32(15, record.ts)
        record.samples.forEachIndexed { i, value -> bytes[27 + 2 * i] = value.toByte(); bytes[28 + 2 * i] = (value shr 8).toByte() }
        u32(bytes.size - 4, Crc.crc32(bytes, 8, bytes.size - 4))
    }
    private fun extract(records: List<PpgHr.Record>, subLag: Boolean = false) = extractHistoricalStreams(
        records.map(::frame), start.toInt(), start.toInt(), DeviceFamily.WHOOP5, ppgHrSubLagInterp = subLag)

    // Independent encoding, not the production digest helper. Select exactly the current input window.
    private fun digest(records: List<PpgHr.Record>): String {
        val bytes = ByteArrayOutputStream()
        bytes.write("w1-ppg-input-v1\n".toByteArray())
        fun i32(value: Int) { bytes.write(ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(value).array()) }
        fun i64(value: Long) { bytes.write(ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putLong(value).array()) }
        i32(records.size)
        records.forEach { record ->
            i64(record.ts); bytes.write(if (record.recordIndex == null) 0 else 1)
            record.recordIndex?.let(::i64); i32(record.samples.size)
            record.samples.forEach { value -> bytes.write(ByteBuffer.allocate(2).order(ByteOrder.LITTLE_ENDIAN).putShort(value.toShort()).array()) }
        }
        return MessageDigest.getInstance("SHA-256").digest(bytes.toByteArray()).joinToString("") { "%02x".format(it) }
    }

    @Test fun actualCaptureRoomReopenAndWireKeepContributorsAndBothAlgorithmModes() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            for (subLag in listOf(false, true)) {
                val device = if (subLag) "synthetic-sublag" else f.device
                val input = records(); val streams = extract(input, subLag)
                val legacy = PpgHr.estimate(input.flatMap { r -> r.samples.map { PpgHr.Sample(r.ts, it) } }, subLag)
                assertTrue(streams.ppgHr.isNotEmpty())
                assertEquals(legacy, streams.ppgHr.map { PpgHr.Estimate(it.ts, it.bpm, it.conf) })
                val account = f.account()
                WhoopRepository(WhoopDatabase.get(account)).insert(streams, device, markPostBackfillDebt = true)
                WhoopDatabase.close()
                assertTrue(runCatching { WhoopDatabase.get(account) }.exceptionOrNull() is
                    com.noop.account.AccountWriteRevokedException)
                f.controller.signIn("synthetic-same-owner", "synthetic")
                val reopenedAccount = f.account()
                assertEquals(account.root, reopenedAccount.root)
                assertNotEquals(account.identity.generation, reopenedAccount.identity.generation)
                val db = WhoopDatabase.get(reopenedAccount)
                val stored = db.whoopDao().ppgHrSamples(device, start, start + 20, 100)
                assertEquals(streams.ppgHr.associate { it.ts to it.provenanceJSON }, stored.associate { it.ts to it.provenanceJSON })
                val rows = PushDao(db).appendRows(PushAppendTable.PPG_HR_SAMPLE, device, 0, 100)
                val batch = PushProtocol.appendBatch(PushAppendTable.PPG_HR_SAMPLE,
                    "00000000-0000-4000-8000-000000000001", device, null, rows, "1.4")
                System.getenv("NARA_ANDROID_GOLDEN_DIR")?.let { parent ->
                    val dir = java.io.File(parent, "ppg-derived-android")
                    check(dir.isDirectory || dir.mkdirs())
                    java.io.File(dir, if (subLag) "sublag.ndjson" else "integer-lag.ndjson").writeBytes(batch.body)
                    val originals = org.json.JSONArray(input.map { r -> JSONObject().put("ts", r.ts)
                        .put("recordIndex", r.recordIndex).put("samples", org.json.JSONArray(r.samples)) })
                    java.io.File(dir, "input-records.json").writeText(originals.toString())
                }
                val lines = batch.body.toString(Charsets.UTF_8).lineSequence().drop(1).filter { it.isNotBlank() }.map(::JSONObject).toList()
                assertEquals(stored.size, lines.size)
                lines.forEachIndexed { i, row ->
                    val ts = (rows[i].key.getValue("ts") as Number).toLong()
                    val contributors = input.filter { it.ts in ts - 4..ts + 4 }.sortedBy { it.ts }
                    val metadata = row.getJSONObject("data").getJSONObject("provenance")
                    assertEquals("concat-records-per-second-v1", metadata.getString("inputSelection"))
                    assertEquals(if (subLag) "ppg-acf-sublag-v1" else "ppg-acf-v1", metadata.getString("algorithm"))
                    assertEquals(24, metadata.getInt("sampleRateHz")); assertEquals(8, metadata.getInt("windowSettingSeconds"))
                    assertEquals(contributors.first().ts, metadata.getLong("inputStartTs"))
                    assertEquals(contributors.last().ts + 1, metadata.getLong("inputEndTs"))
                    assertEquals(digest(contributors), metadata.getString("inputSHA256"))
                    assertFalse(metadata.has("recordIndex")); assertFalse(metadata.has("frameSHA256"))
                }
                assertTrue(runCatching { PushProtocol.appendBatch(PushAppendTable.PPG_HR_SAMPLE,
                    "00000000-0000-4000-8000-000000000001", device, null, rows, "1.3") }.isFailure)
            }
        }
    }

    @Test fun roomScalarAndProvenanceRollbackTogetherWhenDurableDebtCommitFails() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val db = WhoopDatabase.get(f.account()); val repo = WhoopRepository(db); val streams = extract(records())
            db.openHelper.writableDatabase.execSQL("CREATE TRIGGER fail_debt BEFORE INSERT ON syncJob BEGIN SELECT RAISE(ABORT,'synthetic debt failure'); END")
            assertTrue(runCatching { repo.insert(streams, f.device, markPostBackfillDebt = true) }.isFailure)
            assertTrue(db.whoopDao().ppgHrSamples(f.device, start, start + 20, 100).isEmpty())
            db.openHelper.writableDatabase.execSQL("DROP TRIGGER fail_debt")
            repo.insert(streams, f.device, markPostBackfillDebt = true)
            assertEquals(streams.ppgHr.size, db.whoopDao().ppgHrSamples(f.device, start, start + 20, 100).size)
        }
    }
}
