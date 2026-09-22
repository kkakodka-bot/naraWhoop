package com.noop.push

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneId

class PushObjectLaneTest {
    // Same pinned-today discipline as PushCoordinatorTest: the coordinator requires an explicit
    // clock so the suite asserts behaviour rather than the calendar.
    private val pinnedToday = { LocalDate.of(2026, 8, 18) }

    private fun imuColumns(seed: Short): ByteArray {
        val data = ByteArray(PushBinaryCodec.IMU_RECORD_PAYLOAD_BYTES)
        for (index in 0 until PushBinaryCodec.IMU_COLUMNS_PER_RECORD) {
            val value = (seed + index.toShort()).toInt()
            data[index * 2] = (value and 0xff).toByte()
            data[index * 2 + 1] = ((value shr 8) and 0xff).toByte()
        }
        return data
    }

    @Test
    fun credentialChangeAfterPresignedPutFencesObjectCompletion() = runBlocking {
        val row = PushRawImuRecord(100, 100, imuColumns(1))
        val lane = PushObjectLane(
            endpoint = "/api/push/objects",
            maxObjectBytes = PushProtocol.MAX_OBJECT_WIRE_BYTES.toLong(),
            urlTtlSec = 3600,
            streams = setOf(PushBinaryTable.RAW_IMU_SESSION),
        )
        var current = true
        var completeCalls = 0
        val transport = object : PushTransport {
            override suspend fun post(batch: PushBatch) = error("inline push must not run")
            override suspend fun createObjectIntent(manifest: PushObjectManifest, lane: PushObjectLane) =
                PushObjectIntent(
                    manifest.objectId,
                    "objects/key",
                    "https://b2.example/upload",
                    emptyMap(),
                    null,
                    duplicate = false,
                )
            override suspend fun uploadObject(intent: PushObjectIntent, body: ByteArray) {
                current = false
            }
            override suspend fun completeObject(objectId: String, lane: PushObjectLane): PushObjectAck {
                completeCalls++
                error("stale credential must not complete an object")
            }
        }

        var cancelled = false
        try {
            PushCoordinator(
                FakeImuSource(listOf(row)),
                transport,
                MemoryObjectProgress(),
                SOURCE_A,
                pinnedToday,
                ZoneId.of("UTC"),
                destinationStillCurrent = { current },
            ).pushObjects(PushBinaryTable.RAW_IMU_SESSION, "dev", lane)
        } catch (_: kotlinx.coroutines.CancellationException) {
            cancelled = true
        }

        assertTrue(cancelled)
        assertEquals(0, completeCalls)
    }

    @Test
    fun resumeAfterKillSkipsPutWhenUploaded() = runBlocking {
        val row = PushRawImuRecord(100, 100, imuColumns(1))
        val batch = PushProtocol.binaryObjectBatch(
            PushBinaryTable.RAW_IMU_SESSION, SOURCE_A, "dev", null,
            listOf(PushBinaryRow.RawImuSession(row)),
            protocolVersion = PushProtocol.OBJECT_VERSION,
            decodedLimit = PushProtocol.MAX_OBJECT_DECODED_BYTES,
        )
        val lane = PushObjectLane(
            endpoint = "/api/push/objects",
            maxObjectBytes = PushProtocol.MAX_OBJECT_WIRE_BYTES.toLong(),
            urlTtlSec = 3600,
            streams = setOf(PushBinaryTable.RAW_IMU_SESSION),
        )
        val progress = MemoryObjectProgress()
        progress.saveInFlightObject(
            PushBinaryTable.RAW_IMU_SESSION,
            "dev:imu-membership-v1",
            PushInFlightObject(batch.objectId, "k/resume", batch.contentSha256, uploaded = true),
        )
        var intentCalls = 0
        var uploadCalls = 0
        var completeCalls = 0
        val transport = object : PushTransport {
            override suspend fun post(batch: PushBatch) =
                throw PushTransportException(PushFailure(PushFailureCode.LOCAL_DATA))
            override suspend fun createObjectIntent(manifest: PushObjectManifest, lane: PushObjectLane): PushObjectIntent {
                intentCalls += 1
                throw PushTransportException(PushFailure(PushFailureCode.LOCAL_DATA))
            }
            override suspend fun uploadObject(intent: PushObjectIntent, body: ByteArray) {
                uploadCalls += 1
            }
            override suspend fun completeObject(objectId: String, lane: PushObjectLane): PushObjectAck {
                completeCalls += 1
                return PushObjectAck(batch.objectId, "ready", "k/resume", duplicate = false)
            }
        }
        val result = PushCoordinator(
            FakeImuSource(listOf(row)), transport, progress,             SOURCE_A, pinnedToday, ZoneId.of("UTC"),
        ).pushObjects(PushBinaryTable.RAW_IMU_SESSION, "dev", lane)
        assertTrue(result is PushResult.Accepted)
        assertEquals(0, intentCalls)
        assertEquals(0, uploadCalls)
        assertEquals(1, completeCalls)
    }

    @Test
    fun invalidObjectManifestIsNonRetryable() = runBlocking {
        val row = PushRawImuRecord(100, 100, imuColumns(1))
        val lane = PushObjectLane(
            endpoint = "/api/push/objects",
            maxObjectBytes = PushProtocol.MAX_OBJECT_WIRE_BYTES.toLong(),
            urlTtlSec = 3600,
            streams = setOf(PushBinaryTable.RAW_IMU_SESSION),
        )
        var intentCalls = 0
        val transport = object : PushTransport {
            override suspend fun post(batch: PushBatch) =
                throw PushTransportException(PushFailure(PushFailureCode.LOCAL_DATA))
            override suspend fun createObjectIntent(manifest: PushObjectManifest, lane: PushObjectLane): PushObjectIntent {
                intentCalls += 1
                throw PushTransportException(PushFailure.http(400, "invalid_object_manifest"))
            }
            override suspend fun uploadObject(intent: PushObjectIntent, body: ByteArray) {
                error("upload must not run")
            }
            override suspend fun completeObject(objectId: String, lane: PushObjectLane): PushObjectAck {
                error("complete must not run")
            }
        }
        val result = PushCoordinator(
            FakeImuSource(listOf(row)), transport, MemoryObjectProgress(),             SOURCE_A, pinnedToday, ZoneId.of("UTC"),
        ).pushObjects(PushBinaryTable.RAW_IMU_SESSION, "dev", lane)
        assertTrue(result is PushResult.Rejected)
        assertFalse((result as PushResult.Rejected).retryable)
        assertEquals(1, intentCalls)
    }

    @Test
    fun resumeBeforePutReusesObjectKey() = runBlocking {
        val row = PushRawImuRecord(100, 100, imuColumns(1))
        val batch = PushProtocol.binaryObjectBatch(
            PushBinaryTable.RAW_IMU_SESSION, SOURCE_A, "dev", null,
            listOf(PushBinaryRow.RawImuSession(row)),
            protocolVersion = PushProtocol.OBJECT_VERSION,
            decodedLimit = PushProtocol.MAX_OBJECT_DECODED_BYTES,
        )
        val lane = PushObjectLane(
            endpoint = "/api/push/objects",
            maxObjectBytes = PushProtocol.MAX_OBJECT_WIRE_BYTES.toLong(),
            urlTtlSec = 3600,
            streams = setOf(PushBinaryTable.RAW_IMU_SESSION),
        )
        val progress = MemoryObjectProgress()
        progress.saveInFlightObject(
            PushBinaryTable.RAW_IMU_SESSION,
            "dev:imu-membership-v1",
            PushInFlightObject(batch.objectId, "k/resume", batch.contentSha256, uploaded = false),
        )
        var intentCalls = 0
        var uploadCalls = 0
        var completeCalls = 0
        val transport = object : PushTransport {
            override suspend fun post(batch: PushBatch) =
                throw PushTransportException(PushFailure(PushFailureCode.LOCAL_DATA))
            override suspend fun createObjectIntent(manifest: PushObjectManifest, lane: PushObjectLane): PushObjectIntent {
                intentCalls += 1
                return PushObjectIntent(
                    batch.objectId, "k/resume", "https://b2.example/put", emptyMap(), null, duplicate = false,
                )
            }
            override suspend fun uploadObject(intent: PushObjectIntent, body: ByteArray) {
                uploadCalls += 1
                assertEquals("k/resume", intent.objectKey)
            }
            override suspend fun completeObject(objectId: String, lane: PushObjectLane): PushObjectAck {
                completeCalls += 1
                return PushObjectAck(batch.objectId, "ready", "k/resume", duplicate = false)
            }
        }
        val result = PushCoordinator(
            FakeImuSource(listOf(row)), transport, progress,             SOURCE_A, pinnedToday, ZoneId.of("UTC"),
        ).pushObjects(PushBinaryTable.RAW_IMU_SESSION, "dev", lane)
        assertTrue(result is PushResult.Accepted)
        assertEquals(1, intentCalls)
        assertEquals(1, uploadCalls)
        assertEquals(1, completeCalls)
    }

    @Test
    fun objectIdConflictKeepsFrozenImuIdentity() = runBlocking {
        val row = PushRawImuRecord(100, 100, imuColumns(1))
        val lane = PushObjectLane(
            endpoint = "/api/push/objects",
            maxObjectBytes = PushProtocol.MAX_OBJECT_WIRE_BYTES.toLong(),
            urlTtlSec = 3600,
            streams = setOf(PushBinaryTable.RAW_IMU_SESSION),
        )
        var intentCalls = 0
        val transport = object : PushTransport {
            override suspend fun post(batch: PushBatch) =
                throw PushTransportException(PushFailure(PushFailureCode.LOCAL_DATA))
            override suspend fun createObjectIntent(manifest: PushObjectManifest, lane: PushObjectLane): PushObjectIntent {
                intentCalls += 1
                throw PushTransportException(PushFailure.http(409, "object_id_conflict"))
            }
            override suspend fun uploadObject(intent: PushObjectIntent, body: ByteArray) {
                error("upload must not run")
            }
            override suspend fun completeObject(objectId: String, lane: PushObjectLane): PushObjectAck {
                error("complete must not run")
            }
        }
        val result = PushCoordinator(
            FakeImuSource(listOf(row)), transport, MemoryObjectProgress(),             SOURCE_A, pinnedToday, ZoneId.of("UTC"),
        ).pushObjects(PushBinaryTable.RAW_IMU_SESSION, "dev", lane)
        assertTrue(result is PushResult.Rejected)
        assertFalse((result as PushResult.Rejected).retryable)
        assertEquals(1, intentCalls)
    }

    @Test
    fun objectLaneUnavailableIsRetryable() = runBlocking {
        val row = PushRawImuRecord(100, 100, imuColumns(1))
        val lane = PushObjectLane(
            endpoint = "/api/push/objects",
            maxObjectBytes = PushProtocol.MAX_OBJECT_WIRE_BYTES.toLong(),
            urlTtlSec = 3600,
            streams = setOf(PushBinaryTable.RAW_IMU_SESSION),
        )
        val transport = object : PushTransport {
            override suspend fun post(batch: PushBatch) =
                throw PushTransportException(PushFailure(PushFailureCode.LOCAL_DATA))
            override suspend fun createObjectIntent(manifest: PushObjectManifest, lane: PushObjectLane): PushObjectIntent {
                throw PushTransportException(PushFailure.http(503, "object_lane_unavailable"))
            }
            override suspend fun uploadObject(intent: PushObjectIntent, body: ByteArray) {
                error("upload must not run")
            }
            override suspend fun completeObject(objectId: String, lane: PushObjectLane): PushObjectAck {
                error("complete must not run")
            }
        }
        val result = PushCoordinator(
            FakeImuSource(listOf(row)), transport, MemoryObjectProgress(),             SOURCE_A, pinnedToday, ZoneId.of("UTC"),
        ).pushObjects(PushBinaryTable.RAW_IMU_SESSION, "dev", lane)
        assertTrue(result is PushResult.Rejected)
        assertTrue((result as PushResult.Rejected).retryable)
    }

    @Test
    fun capabilityAbsenceRetainsBinaryRows() = runBlocking {
        val caps = PushCapabilities(
            appendTables = emptySet(),
            mutableTables = emptySet(),
            binaryTables = setOf(PushBinaryTable.RAW_IMU_SESSION),
            protocolVersion = PushProtocol.OBJECT_VERSION,
            objectLane = null,
        )
        val result = PushCoordinator(
            FakeImuSource(emptyList()), object : PushTransport {
                override suspend fun post(batch: PushBatch) =
                    throw PushTransportException(PushFailure(PushFailureCode.LOCAL_DATA))
            },
            MemoryObjectProgress(),
            SOURCE_A, pinnedToday, ZoneId.of("UTC"),
        ).pushKnownDevices(capabilities = caps, binaryEnabled = true)
        assertEquals(0, result.acceptedBatches)
        assertFalse(result.hasMoreBinaryRows)
    }
}

private class FakeImuSource(private val rows: List<PushRawImuRecord>) : PushSnapshotSource {
    override suspend fun knownDeviceIds(capabilities: PushCapabilities) = listOf("dev")
    override suspend fun appendRecordAt(table: PushAppendTable, deviceId: String, rowId: Long) = null
    override suspend fun appendRows(table: PushAppendTable, deviceId: String, afterRowId: Long, limit: Int) =
        emptyList<PushAppendRecord>()
    override suspend fun mutableRows(table: PushMutableTable, deviceId: String, window: PushWindow, limit: Int) =
        emptyList<PushMutableRecord>()
    override suspend fun binaryRecordAt(table: PushBinaryTable, deviceId: String, rowId: Long) = null
    override suspend fun binaryRows(table: PushBinaryTable, deviceId: String, afterRowId: Long, limit: Int) =
        rows.filter { it.ts > afterRowId }.take(limit).map { PushBinaryRow.RawImuSession(it) }
    override suspend fun acknowledgeBinary(table: PushBinaryTable, deviceId: String, rows: List<PushBinaryRow>) {}
}

private class MemoryObjectProgress : PushProgressStore {
    private val inflight = mutableMapOf<String, PushInFlightObject>()
    private val cursors = mutableMapOf<String, PushCursor>()
    private val prepared = mutableMapOf<String, PushPreparedBoundary>()
    override suspend fun knownDeviceIds(): Set<String> = emptySet()
    override suspend fun rememberDeviceId(deviceId: String) {}
    override suspend fun cursor(table: PushAppendTable, deviceId: String) = null
    override suspend fun saveCursor(table: PushAppendTable, deviceId: String, cursor: PushCursor) {}
    override suspend fun binaryCursor(table: PushBinaryTable, deviceId: String) = cursors["${table.wireName}.$deviceId"]
    override suspend fun saveBinaryCursor(table: PushBinaryTable, deviceId: String, cursor: PushCursor) {
        cursors["${table.wireName}.$deviceId"] = cursor
    }
    override suspend fun preparedBoundary(table: PushBinaryTable, deviceId: String) = prepared["${table.wireName}.$deviceId"]
    override suspend fun savePreparedBoundary(table: PushBinaryTable, deviceId: String, prepared: PushPreparedBoundary?) {
        val key = "${table.wireName}.$deviceId"
        if (prepared == null) this.prepared.remove(key) else this.prepared[key] = prepared
    }
    override suspend fun window(table: PushMutableTable, deviceId: String) = null
    override suspend fun saveWindow(table: PushMutableTable, deviceId: String, progress: PushWindowProgress) {}
    override suspend fun inFlightObject(table: PushBinaryTable, deviceId: String): PushInFlightObject? =
        inflight["${table.wireName}.$deviceId"]
    override suspend fun saveInFlightObject(table: PushBinaryTable, deviceId: String, inFlight: PushInFlightObject?) {
        val key = "${table.wireName}.$deviceId"
        if (inFlight == null) inflight.remove(key) else inflight[key] = inFlight
    }
}
