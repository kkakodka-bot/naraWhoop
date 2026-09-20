package com.noop.push

import com.noop.data.ScalarProvenance
import com.noop.data.V18AuxIdentity
import com.noop.data.V18AuxRow
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.zip.GZIPInputStream

class W1StrictProvenanceGoldenTest {
    private val source = "3a3486dd-5030-4e17-a00d-a781399890f9"
    private val hash = "a".repeat(64)
    private val derived = mapOf("v" to 1, "origin" to "whoop-v26-ppg-derived", "algorithm" to "ppg-acf-v1",
        "sampleRateHz" to 25, "windowSettingSeconds" to 8, "inputStartTs" to 92L, "inputEndTs" to 101L, "inputSHA256" to hash)
    private fun encode(provenance: Any?) = PushProtocol.appendBatch(PushAppendTable.PPG_HR_SAMPLE, source,
        "fixture-device", null, listOf(PushAppendRecord(1, mapOf("ts" to 100L),
            mapOf("bpm" to 65, "conf" to null, "provenance" to provenance))), "1.4")

    @Test fun provenanceMatchesSwiftStrictTypeAndOriginMatrixBeforeAnyCoercion() {
        encode(derived); encode(mapOf("v" to 1, "origin" to "legacy-unknown"))
        encode(mapOf("v" to 1, "origin" to "whoop-v18", "recordIndex" to 4294967295L, "frameSHA256" to hash))
        encode(null)
        val invalid = listOf("v" to true, "v" to 1.0, "v" to 2, "origin" to 1, "origin" to "future",
            "future" to 1, "algorithm" to "guessed", "sampleRateHz" to 25.0, "sampleRateHz" to 0,
            "sampleRateHz" to 9007199254740992L, "windowSettingSeconds" to true,
            "windowSettingSeconds" to 9007199254740992L, "inputStartTs" to 101,
            "inputEndTs" to 9007199254740992L, "inputStartTs" to -9007199254740992L,
            "inputSHA256" to hash.uppercase(), "inputSHA256" to "a", "inputSHA256" to emptyMap<String, Any>(),
            "recordIndex" to 0, "frameSHA256" to hash, "inputStartTs" to null, "origin" to "a".repeat(1025))
        for ((key, value) in invalid) assertTrue("accepted $key=$value", runCatching { encode(derived + (key to value)) }.isFailure)
        for (key in derived.keys) assertTrue("accepted missing $key", runCatching { encode(derived - key) }.isFailure)
        for (index in listOf(-1L, 4294967296L)) assertTrue(runCatching {
            encode(mapOf("v" to 1, "origin" to "whoop-v18", "recordIndex" to index)) }.isFailure)
        assertTrue(runCatching { encode(mapOf("v" to 1, "origin" to "legacy-unknown", "recordIndex" to 0)) }.isFailure)
        assertTrue(runCatching { encode(mapOf("v" to 1, "origin" to "whoop-v18", "algorithm" to "ppg-acf-v1")) }.isFailure)
        assertTrue(runCatching { encode(emptyList<Any>()) }.isFailure)
        assertTrue(runCatching { encode("{}") }.isFailure)
        encode(derived + mapOf("inputStartTs" to -9007199254740991L, "inputEndTs" to 9007199254740991L))
    }

    @Test fun storedJsonCannotCoerceIntegerBooleanOrNullProvenance() {
        for (bad in listOf("true", "\"1\"", "1.0", "1.5", "null", "{}", "[]")) {
            assertTrue(bad, runCatching { ScalarProvenance.validated("""{"v":1,"origin":"whoop-v18","recordIndex":$bad}""") }.isFailure)
        }
        assertTrue(runCatching { ScalarProvenance.validated("""{"v":1.0,"origin":"whoop-v18"}""") }.isFailure)
    }

    @Test fun optionalSelectionIsDerivedOnlyAndNeverCoercedOrInferred() {
        assertFalse(ScalarProvenance.validated(derived).containsKey("inputSelection"))
        for (selection in listOf("concat-records-per-second-v1", "last-record-per-second-v1")) encode(derived + ("inputSelection" to selection))
        for (invalid in listOf(null, org.json.JSONObject.NULL, "future", 1, true, "", emptyList<String>())) {
            assertTrue("accepted selection $invalid", runCatching { encode(derived + ("inputSelection" to invalid)) }.isFailure)
        }
        for (origin in listOf("whoop-v18", "legacy-unknown")) assertTrue(runCatching {
            encode(mapOf("v" to 1, "origin" to origin, "inputSelection" to "concat-records-per-second-v1"))
        }.isFailure)
        assertTrue(runCatching { ScalarProvenance.validated(org.json.JSONObject(derived).put("inputSelection", org.json.JSONObject.NULL).toString()) }.isFailure)
    }

    @Test fun exactScalar14NativeGoldensMatchIndependentCanonicalJsonAndUuidVectors() {
        val tables = listOf(PushAppendTable.STEP_SAMPLE, PushAppendTable.SLEEP_STATE_SAMPLE, PushAppendTable.PPG_HR_SAMPLE)
        val data = listOf(mapOf("counter" to 65535, "activityClass" to null, "provenance" to
            mapOf("v" to 1, "origin" to "whoop-v18", "recordIndex" to 4294967295L, "frameSHA256" to hash)),
            mapOf("state" to 2, "rawByte" to 32, "provenance" to mapOf("v" to 1, "origin" to "legacy-unknown")),
            mapOf("bpm" to 65, "conf" to null, "provenance" to derived))
        val ids = listOf("0dfb4099-7fe3-584d-af1c-964d998bef3a", "6c4d130b-29a9-522a-97dd-bbbdf8fd65d4", "11c243e8-3013-54d0-91e4-121c01a95252")
        val hashes = listOf("2632c3f890c5fd77f16bc8d1b7295dcdb39d5c05407a361be0165b25d9db8555",
            "085e920304afca1a5e664a2966f047a9874562900e9a769c937c02b986c6a3cd", "6bd50a151956e59b014aab9a2b0ea315b95973d183fb8804011bc07a4e918337")
        val sizes = listOf(577, 468, 652)
        for (i in tables.indices) {
            val batch = PushProtocol.appendBatch(tables[i], source, "fixture-device", null,
                listOf(PushAppendRecord(1, mapOf("ts" to 100L), data[i])), "1.4")
            assertEquals(ids[i], batch.batchId); assertEquals(hashes[i], PushBinaryCodec.sha256Hex(batch.body))
            assertEquals(sizes[i], batch.body.size)
            export("scalar14-android/${tables[i].wireName}.ndjson", batch.body)
        }
    }

    @Test fun exactAux14NativeBytesAndFingerprintsMatchActualSwiftGolden() {
        val rows = listOf(0L, 4294967295L, null).mapIndexed { i, index -> PushBinaryRow.V18Aux(PushV18AuxRecord(
            i + 1L, 100, V18AuxIdentity.pack(if (index == null) V18AuxRow(100, rrCount = 1) else V18AuxRow(100, recordIndex = index)), index)) }
        val decoded = PushBinaryCodec.pack(PushBinaryTable.V18_AUX_SAMPLE, rows, auxIdentityV2 = true)
        assertEquals("4e50423102020300000001000000000000006400000000000000010000000000000000090000000201000000000000000200000000000000640000000000000001ffffffff00000000090000000201000000ffffffff030000000000000064000000000000000006000000020200000001",
            decoded.joinToString("") { "%02x".format(it) })
        assertEquals(listOf("af4a73756a88246ff46f49a667eb32d4917de6468ac189d4b8ccb4b308f1ecaa",
            "7ad1d842f0a57254542785cb45fb33dd4162c7b45a12db7af8a5469ce5c85d82", "39ad74746342bc4d30c7086d6a66db64d7f2ed52d55c95bf1e83bb8ac405bb59"),
            rows.map { PushProtocol.binaryKeyFingerprint(PushBinaryTable.V18_AUX_SAMPLE, "fixture-device", it, true) })
        val batch = PushProtocol.binaryObjectBatch(PushBinaryTable.V18_AUX_SAMPLE, source, "fixture-device", null, rows, "1.4")
        assertEquals("bc0f818227ef1c3ed66b6596dbeb4e533d4f632994ac5728c4ac4701a3ee523a", batch.contentSha256)
        assertEquals("acd9cf97-7ebd-5286-a4eb-96c347224ea0", batch.batchId)
        assertEquals("3ae2c9e6-b7f9-5c44-8292-73920eb88b74", batch.objectId)
        assertArrayEquals(decoded, GZIPInputStream(batch.payload.inputStream()).use { it.readBytes() })
        assertEquals(113, batch.uncompressedBytes); assertEquals(64, batch.payload.size)
        export("aux14-android/payload.npb1", decoded); export("aux14-android/payload.gz", batch.payload)
        export("aux14-android/manifest.json", PushObjectManifest(batch).encode())
    }

    private fun export(name: String, bytes: ByteArray) {
        System.getenv("NARA_ANDROID_GOLDEN_DIR")?.let { parent ->
            val file = File(parent, name); check(file.parentFile!!.isDirectory || file.parentFile!!.mkdirs())
            file.writeBytes(bytes)
        }
    }
}
