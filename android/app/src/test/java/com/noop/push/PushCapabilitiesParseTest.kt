package com.noop.push

import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneId

class PushCapabilitiesParseTest {
    @Test fun scalarCapabilitiesRequireAtLeast11And14IsAccepted() {
        val names = listOf("stepSample", "sleepStateSample", "ppgHrSample")
        assertTrue(PushCapabilities.parse(document("1.0", names)).appendTables.isEmpty())
        for (version in listOf("1.1", "1.2", "1.3", "1.4")) {
            assertEquals(setOf(PushAppendTable.STEP_SAMPLE, PushAppendTable.SLEEP_STATE_SAMPLE, PushAppendTable.PPG_HR_SAMPLE),
                PushCapabilities.parse(document(version, names)).appendTables)
        }
        assertTrue(runCatching { PushCapabilities.parse(document("1.5", names)) }.exceptionOrNull() is PushProtocolException)
    }
    /**
     * Verbatim stdout of `Tools/push_capabilities_oracle.swift` — the Swift twin of this parser.
     * Format: `label|OK|protocolVersion|appendCsv|mutableCsv|isEmpty` or `label|ERR|message`.
     */
    private val oracle = """
        allKnownV10|OK|1.0|hrSample|dailyMetric,journal|0
        allKnownV11|OK|1.1|hrSample|dailyMetric,journal|0
        someUnknown|OK|1.0|hrSample||0
        allUnknown|OK|1.1|||1
        emptyStreams|OK|1.0|||1
        duplicate|ERR|duplicate capability stream
        nonString|ERR|capability stream names must be strings
        missingReceiver|ERR|capabilities are missing required protocol 1.0 members
        forbiddenCommand|ERR|capabilities contain forbidden remote-control metadata
        unsupportedVersion|ERR|unsupported capability document
    """.trimIndent()

    @Test
    fun capabilitiesParseMatchesTheSwiftOracleExactly() {
        for (row in oracle.lines().map { it.trim() }.filter { it.isNotEmpty() }) {
            val parts = row.split("|")
            val label = parts[0]
            when (parts[1]) {
                "OK" -> {
                    val parsed = PushCapabilities.parse(fixtureBytes(label))
                    assertEquals("$label: protocolVersion", parts[2], parsed.protocolVersion)
                    assertEquals("$label: receiverStateId", RECEIVER_ID, parsed.receiverStateId)
                    assertEquals(
                        "$label: append",
                        if (parts[3].isEmpty()) emptyList() else parts[3].split(","),
                        PushAppendTable.entries.filter { it in parsed.appendTables }.map { it.wireName },
                    )
                    assertEquals(
                        "$label: mutable",
                        if (parts[4].isEmpty()) emptyList() else parts[4].split(","),
                        PushMutableTable.entries.filter { it in parsed.mutableTables }.map { it.wireName },
                    )
                    assertEquals("$label: isEmpty", parts[5] == "1", parsed.isEmpty)
                }
                "ERR" -> {
                    val error = runCatching { PushCapabilities.parse(fixtureBytes(label)) }.exceptionOrNull()
                    assertTrue("$label: expected PushProtocolException", error is PushProtocolException)
                    assertEquals("$label: message", parts[2], (error as PushProtocolException).message)
                }
                else -> error("unknown oracle row kind: $row")
            }
        }
    }

    @Test
    fun objectLaneV12Parse() {
        val parsed = PushCapabilities.parse(
            JSONObject()
                .put("type", "capabilities")
                .put("protocolVersion", PushProtocol.OBJECT_VERSION)
                .put("receiverStateId", RECEIVER_ID)
                .put("streams", JSONArray(listOf("rawImuSession", "ppgWaveformSample")))
                .put(
                    "objectLane",
                    JSONObject()
                        .put("endpoint", "/api/push/objects")
                        .put("maxObjectBytes", PushProtocol.MAX_OBJECT_WIRE_BYTES)
                        .put("urlTtlSec", 3600)
                        .put("streams", JSONArray(listOf("rawImuSession"))),
                )
                .toString()
                .toByteArray(),
        )
        assertEquals(PushProtocol.OBJECT_VERSION, parsed.protocolVersion)
        assertEquals("/api/push/objects", parsed.objectLane?.endpoint)
        assertEquals(setOf(PushBinaryTable.RAW_IMU_SESSION), parsed.objectLane?.streams)
    }

    @Test
    fun malformedObjectLaneDisablesLane() {
        val parsed = PushCapabilities.parse(
            JSONObject()
                .put("type", "capabilities")
                .put("protocolVersion", PushProtocol.OBJECT_VERSION)
                .put("receiverStateId", RECEIVER_ID)
                .put("streams", JSONArray(listOf("rawImuSession")))
                .put(
                    "objectLane",
                    JSONObject()
                        .put("endpoint", "https://bad.example/objects")
                        .put("maxObjectBytes", true)
                        .put("streams", JSONArray(listOf("rawImuSession"))),
                )
                .toString()
                .toByteArray(),
        )
        assertEquals(null, parsed.objectLane)
    }

    @Test
    fun allUnknownStreamsParseEmptyAndCoordinatorNoOps() = runBlocking {
        val capabilities = PushCapabilities.parse(fixtureBytes("allUnknown"))
        assertTrue(capabilities.isEmpty)

        val source = object : PushSnapshotSource {
            override suspend fun knownDeviceIds(capabilities: PushCapabilities): List<String> {
                error("Room must stay unopened when capabilities are empty")
            }

            override suspend fun appendRecordAt(table: PushAppendTable, deviceId: String, rowId: Long): PushAppendRecord? = null
            override suspend fun appendRows(table: PushAppendTable, deviceId: String, afterRowId: Long, limit: Int): List<PushAppendRecord> = emptyList()
            override suspend fun mutableRows(table: PushMutableTable, deviceId: String, window: PushWindow, limit: Int): List<PushMutableRecord> = emptyList()
            override suspend fun binaryRecordAt(table: PushBinaryTable, deviceId: String, rowId: Long): PushBinaryRow? = null
            override suspend fun binaryRows(table: PushBinaryTable, deviceId: String, afterRowId: Long, limit: Int): List<PushBinaryRow> = emptyList()
            override suspend fun acknowledgeBinary(table: PushBinaryTable, deviceId: String, rows: List<PushBinaryRow>) = Unit
        }
        var postCount = 0
        val transport = object : PushTransport {
            override suspend fun capabilities(): PushCapabilitiesResult = PushCapabilitiesResult.Available(PushCapabilities.ALL)
            override suspend fun post(batch: PushBatch): PushTransportResponse {
                postCount++
                error("must not POST")
            }
        }

        val result = PushCoordinator(
            source,
            transport,
            MemoryProgress(),
            SOURCE_A,
            { LocalDate.of(2026, 8, 18) },
            ZoneId.of("UTC"),
        ).pushKnownDevices(capabilities = capabilities)

        assertEquals(0, result.acceptedBatches)
        assertEquals(0, result.rejectedBatches)
        assertFalse(result.hasMoreAppendRows)
        assertEquals(0, postCount)
    }

    private fun fixtureBytes(label: String): ByteArray = when (label) {
        "allKnownV10" -> document("1.0", listOf("hrSample", "journal", "dailyMetric"))
        "allKnownV11" -> document("1.1", listOf("hrSample", "journal", "dailyMetric"))
        "someUnknown" -> document("1.0", listOf("hrSample", "stepSample", "futureStream"))
        "allUnknown" -> document("1.1", listOf("futureScalarStream", "futureStream"))
        "emptyStreams" -> document("1.0", emptyList())
        "duplicate" -> document("1.0", listOf("hrSample", "hrSample"))
        "nonString" -> JSONObject()
            .put("type", "capabilities")
            .put("protocolVersion", "1.0")
            .put("receiverStateId", RECEIVER_ID)
            .put("streams", JSONArray().put("hrSample").put(1))
            .toString()
            .toByteArray()
        "missingReceiver" -> JSONObject()
            .put("type", "capabilities")
            .put("protocolVersion", "1.0")
            .put("streams", JSONArray().put("hrSample"))
            .toString()
            .toByteArray()
        "forbiddenCommand" -> JSONObject()
            .put("type", "capabilities")
            .put("protocolVersion", "1.0")
            .put("receiverStateId", RECEIVER_ID)
            .put("streams", JSONArray().put("hrSample"))
            .put("command", "sync-now")
            .toString()
            .toByteArray()
        "unsupportedVersion" -> document("2.0", listOf("hrSample"))
        else -> error("unknown fixture $label")
    }

    private fun document(version: String, streams: List<String>): ByteArray = JSONObject()
        .put("type", "capabilities")
        .put("protocolVersion", version)
        .put("receiverStateId", RECEIVER_ID)
        .put("streams", JSONArray(streams))
        .toString()
        .toByteArray()

    private companion object {
        const val RECEIVER_ID = "00000000-0000-4000-8000-000000000099"
    }
}
