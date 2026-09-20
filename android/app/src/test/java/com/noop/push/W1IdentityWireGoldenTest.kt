package com.noop.push

import com.noop.data.ScalarProvenance
import com.noop.data.V18AuxIdentity
import com.noop.data.V18AuxRow
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class W1IdentityWireGoldenTest {
    private val source = "00000000-0000-4000-8000-000000000001"
    private fun aux(id: Long, index: Long?, ts: Long = 1700000000) = PushBinaryRow.V18Aux(PushV18AuxRecord(
        id, ts, V18AuxIdentity.pack(if (index == null) V18AuxRow(ts, rrCount = 127) else V18AuxRow(ts, recordIndex = index)), index))

    @Test fun exactAuxiliaryFormatTwoAndFingerprintsMatchIndependentLittleEndianVectors() {
        val rows = listOf(aux(7, 0), aux(8, 4294967295L), aux(9, null))
        val bytes = PushBinaryCodec.pack(PushBinaryTable.V18_AUX_SAMPLE, rows, auxIdentityV2 = true)
        assertEquals("4e504231020203000000070000000000000000f153650000000001000000000000000009000000020100000000000000080000000000000000f153650000000001ffffffff00000000090000000201000000ffffffff090000000000000000f1536500000000000600000002020000007f",
            bytes.joinToString("") { "%02x".format(it) })
        assertEquals("98ca021a76743a278cbe5958104d358a2d556afac46f7bec0fa752e4e77307a2", PushBinaryCodec.sha256Hex(bytes))
        assertEquals(listOf("88a5a135f161d15a69120c0a7392398bd4d7bf7a893dca9cebf9f31ff786caec",
            "ca81e4df3474f44cee9d051515036c2f4051f6c4555c57552a158b3a23afa6c1",
            "270435985192b6490f8a6c0470665af96d2eec7ef9408a5170bd4d3b88bc0e43"),
            rows.map { PushProtocol.binaryKeyFingerprint(PushBinaryTable.V18_AUX_SAMPLE, "strap", it, true) })
        assertEquals(bytes.size, 10 + rows.sumOf { PushBinaryCodec.packedRowSize(it, auxIdentityV2 = true) })
    }

    @Test fun legacyPrefixStopsAtKnownIndexAndV14UnknownFingerprintIsNotLegacy() {
        val rows = listOf(aux(1, null), aux(2, 0), aux(3, null))
        val old = PushProtocol.binaryObjectBatch(PushBinaryTable.V18_AUX_SAMPLE, source, "strap", null, rows, "1.3")
        assertEquals(1, old.sampleCount); assertEquals(1, old.endCursor!!.rowId)
        assertTrue(runCatching { PushProtocol.binaryObjectBatch(PushBinaryTable.V18_AUX_SAMPLE, source, "strap", old.endCursor, rows.drop(1), "1.3") }.exceptionOrNull() is PushProtocolException)
        val modern = PushProtocol.binaryObjectBatch(PushBinaryTable.V18_AUX_SAMPLE, source, "strap", null, rows.take(1), "1.4")
        assertNotEquals(old.endCursor!!.naturalKeyFingerprint, modern.endCursor!!.naturalKeyFingerprint)
    }

    @Test fun boundedContiguousPrefixRejectsMalformedOrMismatchedFieldsAndKeepsStableBytes() {
        val rows = listOf(aux(1, 0, 100), aux(2, 1, 100 + 48 * 3600), aux(3, 2, 101))
        val a = PushProtocol.binaryObjectBatch(PushBinaryTable.V18_AUX_SAMPLE, source, "strap", null, rows, "1.4")
        val b = PushProtocol.binaryObjectBatch(PushBinaryTable.V18_AUX_SAMPLE, source, "strap", null, rows, "1.4")
        assertEquals(1, a.sampleCount); assertEquals(100, a.startTs); assertEquals(101, a.endTs)
        assertArrayEquals(a.payload, b.payload); assertEquals(a.batchId, b.batchId)
        for (invalid in listOf(aux(1, 0).record.copy(recordIndex = 1), aux(1, 0).record.copy(fields = byteArrayOf(2, 1)))) {
            assertTrue(runCatching { PushBinaryCodec.pack(PushBinaryTable.V18_AUX_SAMPLE, listOf(PushBinaryRow.V18Aux(invalid)), auxIdentityV2 = true) }.exceptionOrNull() is PushProtocolException)
        }
    }

    @Test fun scalarSchemaAndProtocolPreserveUnknownNullAndNeverStripKnownProvenance() {
        val first = PushAppendRecord(1, linkedMapOf("ts" to 100L), linkedMapOf("counter" to 65535, "activityClass" to null, "provenance" to null))
        val provenance = ScalarProvenance.validated(ScalarProvenance.v18(byteArrayOf(1), 0))
        val second = first.copy(rowId = 2, key = linkedMapOf("ts" to 101L), data = first.data + ("provenance" to provenance))
        val old = PushProtocol.appendBatch(PushAppendTable.STEP_SAMPLE, source, "strap", null, listOf(first, second), "1.3")
        assertEquals("1.3", old.protocolVersion); assertEquals(1, old.recordCount)
        assertFalse(old.body.toString(Charsets.UTF_8).contains("provenance"))
        val modern = PushProtocol.appendBatch(PushAppendTable.STEP_SAMPLE, source, "strap", null, listOf(second), "1.4")
        assertEquals(0L, JSONObject(modern.body.toString(Charsets.UTF_8).lines()[1]).getJSONObject("data").getJSONObject("provenance").getLong("recordIndex"))
        assertTrue(runCatching { PushProtocol.appendBatch(PushAppendTable.STEP_SAMPLE, source, "strap", null, listOf(first), "1.0") }.exceptionOrNull() is PushProtocolException)
        for (version in listOf("1.1", "1.2", "1.3", "1.4")) {
            assertEquals(if (version in setOf("1.3", "1.4")) 2 else 1, PushProtocol.schemaVersion("ppgWaveformSample", version))
            for (stream in listOf("v18AuxSample", "stepSample", "sleepStateSample", "ppgHrSample"))
                assertEquals(if (version == "1.4") 2 else 1, PushProtocol.schemaVersion(stream, version))
            assertEquals(1, PushProtocol.schemaVersion("hrSample", version))
        }
    }

    @Test fun scalarNumericTypesAndProvenanceAreStrictWithoutClipping() {
        val invalid = listOf(
            PushAppendTable.STEP_SAMPLE to mapOf("counter" to true, "activityClass" to null),
            PushAppendTable.STEP_SAMPLE to mapOf("counter" to 65536, "activityClass" to null),
            PushAppendTable.SLEEP_STATE_SAMPLE to mapOf("state" to 2, "rawByte" to 0),
            PushAppendTable.PPG_HR_SAMPLE to mapOf("bpm" to "90", "conf" to 0.8),
            PushAppendTable.PPG_HR_SAMPLE to mapOf("bpm" to 90, "conf" to Double.NaN))
        for ((table, data) in invalid) assertTrue(runCatching {
            PushProtocol.appendBatch(table, source, "strap", null, listOf(PushAppendRecord(1, mapOf("ts" to 100), data)), "1.4")
        }.exceptionOrNull() is PushProtocolException)
        for (json in listOf("{\"v\":true,\"origin\":\"whoop-v18\"}", "{\"v\":1,\"origin\":\"whoop-v18\",\"recordIndex\":-1}",
            "{\"v\":1,\"origin\":\"whoop-v18\",\"future\":1}", "{\"v\":1,\"origin\":\"whoop-v18\",\"algorithm\":null}"))
            assertTrue(runCatching { ScalarProvenance.validated(json) }.isFailure)
    }

    @Test fun exactPpgInputDigestBanksOriginalSignedSamplesAndDuplicateOrder() {
        val records = listOf(ScalarProvenance.PpgInput(100, 0, listOf(-32768, -1, 0, 32767)),
            ScalarProvenance.PpgInput(100, 4294967295L, listOf(1, 2)), ScalarProvenance.PpgInput(101, null, listOf(-2, 3)))
        assertEquals("05d7e42624ac139eeca917cdcdc2c3e183de3db0adebfbc384960df41e77002e", ScalarProvenance.ppgInputDigest(records))
        assertNotEquals(ScalarProvenance.ppgInputDigest(records), ScalarProvenance.ppgInputDigest(listOf(records[1], records[0], records[2])))
        assertTrue(runCatching { ScalarProvenance.ppgInputDigest(listOf(records[0].copy(samples = listOf(32768)))) }.isFailure)
    }
}
