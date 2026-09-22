package com.noop.push

import kotlinx.coroutines.CancellationException
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/** Coordinates bounded Room snapshots and transport without holding a database read across network I/O. */
class PushCoordinator(
    private val source: PushSnapshotSource,
    private val transport: PushTransport,
    private val progress: PushProgressStore,
    private val sourceId: String,
    private val today: () -> LocalDate,
    private val zoneId: ZoneId,
    private val destinationStillCurrent: () -> Boolean = { true },
) {
    suspend fun pushAppend(table: PushAppendTable, deviceId: String, protocolVersion: String = PushProtocol.VERSION): PushResult {
        val stored = try {
            progress.cursor(table, deviceId)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            return rejected(PushFailure(PushFailureCode.LOCAL_DATABASE))
        }
        val effective = if (stored == null || stored.rowId <= 0) {
            null
        } else {
            val atCursor = try {
                source.appendRecordAt(table, deviceId, stored.rowId)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (invalid: PushProtocolException) {
                return rejected(PushFailure(PushFailureCode.LOCAL_DATA))
            } catch (_: Throwable) {
                return rejected(PushFailure(PushFailureCode.LOCAL_DATABASE))
            }
            val fingerprint = atCursor?.let { PushProtocol.keyFingerprint(table, deviceId, it.key) }
            if (fingerprint == stored.naturalKeyFingerprint) stored else null
        }
        val rows = try {
            source.appendRows(table, deviceId, effective?.rowId ?: 0L, PushProtocol.MAX_RECORDS + 1)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (invalid: PushProtocolException) {
            return rejected(PushFailure(PushFailureCode.LOCAL_DATA))
        } catch (_: Throwable) {
            return rejected(PushFailure(PushFailureCode.LOCAL_DATABASE))
        }
        if (rows.isEmpty()) return PushResult.NoData
        val batch = try {
            PushProtocol.appendBatch(table, sourceId, deviceId, effective, rows, protocolVersion)
        } catch (t: PushProtocolException) {
            return rejected(PushFailure(PushFailureCode.LOCAL_DATA))
        }
        val accepted = deliver(batch)
        if (accepted !is PushResult.Accepted) return accepted
        val end = batch.endCursor ?: return rejected(PushFailure(PushFailureCode.LOCAL_DATA))
        return try {
            progress.saveCursor(table, deviceId, end)
            accepted.copy(hasMore = rows.size > batch.recordCount)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (invalid: PushProtocolException) {
            return rejected(PushFailure(PushFailureCode.LOCAL_DATA))
        } catch (_: Throwable) {
            // The endpoint may have applied the bytes. Keeping the old cursor safely repeats the same upserts.
            rejected(PushFailure(PushFailureCode.LOCAL_DATABASE))
        }
    }

    suspend fun pushMutable(table: PushMutableTable, deviceId: String): PushResult {
        val fullWindow = PushWindow.ending(today(), zoneId)
        val rows = try {
            source.mutableRows(
                table, deviceId, fullWindow, PushProtocol.MAX_MUTABLE_SNAPSHOT_RECORDS + 1,
            )
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (invalid: PushProtocolException) {
            return rejected(PushFailure(PushFailureCode.LOCAL_DATA))
        } catch (_: Throwable) {
            return rejected(PushFailure(PushFailureCode.LOCAL_DATABASE))
        }
        if (rows.size > PushProtocol.MAX_MUTABLE_SNAPSHOT_RECORDS) {
            return rejected(PushFailure(PushFailureCode.LOCAL_DATA))
        }
        var encodedBytes = 0L
        val days = generateSequence(LocalDate.parse(fullWindow.fromDay)) { previous ->
            previous.plusDays(1).takeUnless { it.isAfter(LocalDate.parse(fullWindow.toDay)) }
        }.toList()
        val recordsByDay = days.associateWith { mutableListOf<PushMutableRecord>() }
        for (record in rows) {
            val size = try {
                PushProtocol.mutableRecordEncodedSize(table, record)
            } catch (t: PushProtocolException) {
                return rejected(PushFailure(PushFailureCode.LOCAL_DATA))
            }
            encodedBytes += size
            if (encodedBytes > PushProtocol.MAX_MUTABLE_SNAPSHOT_ENCODED_BYTES) {
                return rejected(PushFailure(PushFailureCode.LOCAL_DATA))
            }
            val day = try {
                mutableRecordDay(table, record)
            } catch (_: PushProtocolException) {
                return rejected(PushFailure(PushFailureCode.LOCAL_DATA))
            }
            val bucket = recordsByDay[day]
                ?: return rejected(PushFailure(PushFailureCode.LOCAL_DATA))
            bucket += record
        }
        val currentHashes = try {
            recordsByDay.mapKeys { (day, _) -> day.toString() }
                .mapValues { (_, dayRows) -> PushProtocol.mutableSnapshotHash(table, dayRows) }
        } catch (_: PushProtocolException) {
            return rejected(PushFailure(PushFailureCode.LOCAL_DATA))
        }
        val previousHashes = try {
            progress.window(table, deviceId)?.dayHashes.orEmpty()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            return rejected(PushFailure(PushFailureCode.LOCAL_DATABASE))
        }
        val changedDays = days.filter { day -> previousHashes[day.toString()] != currentHashes[day.toString()] }
        if (changedDays.isEmpty()) return PushResult.NoData
        val window = PushWindow.days(changedDays.first(), changedDays.last(), zoneId)
        val changedRows = days.asSequence()
            .filter { it >= changedDays.first() && it <= changedDays.last() }
            .flatMap { recordsByDay.getValue(it).asSequence() }
            .toList()
        val batches = try {
            PushProtocol.mutableBatches(table, sourceId, deviceId, window, changedRows)
        } catch (t: PushProtocolException) {
            return rejected(PushFailure(PushFailureCode.LOCAL_DATA))
        }
        for (batch in batches) {
            val accepted = deliver(batch)
            if (accepted !is PushResult.Accepted) return accepted
        }
        val replacementId = batches.first().replacementId ?: batches.first().batchId
        return try {
            progress.saveWindow(
                table,
                deviceId,
                PushWindowProgress(fullWindow, replacementId, currentHashes),
            )
            PushResult.Accepted(
                batchId = replacementId,
                recordCount = changedRows.size,
                hasMore = false,
                batchCount = batches.size,
            )
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            rejected(PushFailure(PushFailureCode.LOCAL_DATABASE))
        }
    }

    suspend fun pushBinary(table: PushBinaryTable, deviceId: String): PushResult {
        val stored = try {
            progress.binaryCursor(table, deviceId)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            return rejected(PushFailure(PushFailureCode.LOCAL_DATABASE))
        }
        val effective = if (table == PushBinaryTable.RAW_BATCH) {
            null
        } else if (stored == null || stored.rowId <= 0) {
            null
        } else {
            val atCursor = try {
                source.binaryRecordAt(table, deviceId, stored.rowId)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (invalid: PushProtocolException) {
                return rejected(PushFailure(PushFailureCode.LOCAL_DATA))
            } catch (_: Throwable) {
                return rejected(PushFailure(PushFailureCode.LOCAL_DATABASE))
            }
            val fingerprint = atCursor?.let { PushProtocol.binaryKeyFingerprint(table, deviceId, it) }
            if (fingerprint == stored.naturalKeyFingerprint) stored else null
        }
        val limit = if (table == PushBinaryTable.RAW_BATCH) 1 else PushProtocol.MAX_RECORDS + 1
        val rows = try {
            source.binaryRows(table, deviceId, effective?.rowId ?: 0L, limit)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (invalid: PushProtocolException) {
            return rejected(PushFailure(PushFailureCode.LOCAL_DATA))
        } catch (_: Throwable) {
            return rejected(PushFailure(PushFailureCode.LOCAL_DATABASE))
        }
        if (rows.isEmpty()) return PushResult.NoData
        val batch = try {
            PushProtocol.binaryObjectBatch(table, sourceId, deviceId, effective, rows)
        } catch (_: PushProtocolException) {
            return rejected(PushFailure(PushFailureCode.LOCAL_DATA))
        }
        val accepted = deliverBinary(batch)
        if (accepted !is PushResult.Accepted) return accepted
        return try {
            batch.endCursor?.let { progress.saveBinaryCursor(table, deviceId, it) }
            source.acknowledgeBinary(table, deviceId, rows)
            val hasMore = table != PushBinaryTable.RAW_BATCH && rows.size > batch.sampleCount
            accepted.copy(hasMore = hasMore)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (invalid: PushProtocolException) {
            rejected(PushFailure(PushFailureCode.LOCAL_DATA))
        } catch (_: Throwable) {
            rejected(PushFailure(PushFailureCode.LOCAL_DATABASE))
        }
    }

    suspend fun pushObjects(table: PushBinaryTable, deviceId: String, lane: PushObjectLane,
                            protocolVersion: String = PushProtocol.OBJECT_VERSION): PushResult {
        val freezePrefix = table == PushBinaryTable.V18_AUX_SAMPLE && protocolVersion == "1.4"
        val progressDevice = if (freezePrefix)
            "$deviceId:v18AuxSample.identity-v2" else deviceId
        var prepared: PushPreparedBoundary? = null
        val stored = try {
            val cursor = progress.binaryCursor(table, progressDevice)
            if (freezePrefix) {
                prepared = progress.preparedBoundary(table, progressDevice)
                if (prepared != null && cursor == prepared!!.endCursor) {
                    // Crash after accepted cursor commit, before pending cleanup. Never replay old rows.
                    progress.saveInFlightObject(table, progressDevice, null)
                    progress.savePreparedBoundary(table, progressDevice, null)
                    check(progress.preparedBoundary(table, progressDevice) == null)
                    prepared = null
                }
            }
            cursor
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            return rejected(PushFailure(PushFailureCode.LOCAL_DATABASE))
        }
        if (prepared != null && stored != prepared!!.startCursor)
            return rejected(PushFailure(PushFailureCode.LOCAL_DATA))
        val effective = if (table == PushBinaryTable.RAW_BATCH) {
            null
        } else if (stored == null || stored.rowId <= 0) {
            null
        } else {
            val atCursor = try {
                source.binaryRecordAt(table, deviceId, stored.rowId)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (invalid: PushProtocolException) {
                return rejected(PushFailure(PushFailureCode.LOCAL_DATA))
            } catch (_: Throwable) {
                return rejected(PushFailure(PushFailureCode.LOCAL_DATABASE))
            }
            val fingerprint = atCursor?.let { PushProtocol.binaryKeyFingerprint(table, deviceId, it, protocolVersion == "1.4") }
            if (fingerprint == stored.naturalKeyFingerprint) stored else null
        }
        if (prepared != null && effective != prepared!!.startCursor)
            return rejected(PushFailure(PushFailureCode.LOCAL_DATA))
        val limit = if (table == PushBinaryTable.RAW_BATCH) 1 else (prepared?.sampleCount ?: PushProtocol.MAX_RECORDS) + 1
        val rows = try {
            source.binaryRows(table, deviceId, effective?.rowId ?: 0L, limit)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (invalid: PushProtocolException) {
            return rejected(PushFailure(PushFailureCode.LOCAL_DATA))
        } catch (_: Throwable) {
            return rejected(PushFailure(PushFailureCode.LOCAL_DATABASE))
        }
        if (rows.isEmpty()) return if (prepared == null) PushResult.NoData else rejected(PushFailure(PushFailureCode.LOCAL_DATA))
        val batch = try {
            PushProtocol.binaryObjectBatch(
                table, sourceId, deviceId, effective, prepared?.let { rows.take(it.sampleCount) } ?: rows,
                protocolVersion = protocolVersion,
                decodedLimit = PushProtocol.MAX_OBJECT_DECODED_BYTES,
            )
        } catch (_: PushProtocolException) {
            return rejected(PushFailure(PushFailureCode.LOCAL_DATA))
        }
        if (batch.payload.size.toLong() > lane.maxObjectBytes) {
            return rejected(PushFailure(PushFailureCode.LOCAL_DATA))
        }
        if (freezePrefix) {
            val captured = PushPreparedBoundary.capture(effective, batch)
            if (prepared != null && prepared != captured) return rejected(PushFailure(PushFailureCode.LOCAL_DATA))
            try {
                if (prepared == null) progress.savePreparedBoundary(table, progressDevice, captured)
                check(progress.preparedBoundary(table, progressDevice) == captured)
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Throwable) { return rejected(PushFailure(PushFailureCode.LOCAL_DATABASE)) }
        }
        val accepted = deliverObject(batch, lane, progressDevice, freezePrefix)
        if (accepted !is PushResult.Accepted) return accepted
        return try {
            batch.endCursor?.let { progress.saveBinaryCursor(table, progressDevice, it) }
            source.acknowledgeBinary(table, deviceId, rows.take(batch.sampleCount))
            if (freezePrefix) {
                check(progress.binaryCursor(table, progressDevice) == batch.endCursor)
                progress.saveInFlightObject(table, progressDevice, null)
                progress.savePreparedBoundary(table, progressDevice, null)
                check(progress.preparedBoundary(table, progressDevice) == null)
            }
            val hasMore = table != PushBinaryTable.RAW_BATCH && rows.size > batch.sampleCount
            accepted.copy(hasMore = hasMore)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (invalid: PushProtocolException) {
            rejected(PushFailure(PushFailureCode.LOCAL_DATA))
        } catch (_: Throwable) {
            rejected(PushFailure(PushFailureCode.LOCAL_DATABASE))
        }
    }

    private fun mutableRecordDay(table: PushMutableTable, record: PushMutableRecord): LocalDate = when (table) {
        PushMutableTable.DAILY_METRIC, PushMutableTable.JOURNAL -> {
            val value = record.key["day"] as? String
                ?: throw PushProtocolException("mutable day key is not a string")
            runCatching { LocalDate.parse(value) }
                .getOrElse { throw PushProtocolException("mutable day key is invalid") }
        }
        PushMutableTable.SLEEP_SESSION, PushMutableTable.WORKOUT -> {
            val value = record.key["startTs"]
            val timestamp = when (value) {
                is Byte, is Short, is Int, is Long -> (value as Number).toLong()
                else -> throw PushProtocolException("mutable startTs key is not an integer")
            }
            runCatching { Instant.ofEpochSecond(timestamp).atZone(zoneId).toLocalDate() }
                .getOrElse { throw PushProtocolException("mutable startTs key is invalid") }
        }
    }

    /** One append page and one checksum-minimized mutable replacement per actual source device. */
    suspend fun pushKnownDevices(
        startDeviceIndex: Int = 0,
        maxDevices: Int = Int.MAX_VALUE,
        capabilities: PushCapabilities = PushCapabilities.ALL,
        binaryEnabled: Boolean = false,
    ): PushRunResult {
        require(startDeviceIndex >= 0)
        require(maxDevices > 0)
        val ndjsonEnabled = capabilities.appendTables.isNotEmpty() || capabilities.mutableTables.isNotEmpty()
        val binaryAllowed = binaryEnabled && capabilities.binaryTables.isNotEmpty()
        if (capabilities.isEmpty || (!ndjsonEnabled && !binaryAllowed)) {
            return PushRunResult(
                acceptedBatches = 0,
                acceptedRecords = 0,
                rejectedBatches = 0,
                hasMoreAppendRows = false,
            )
        }
        val devices = try {
            val live = source.knownDeviceIds(capabilities).filter(String::isNotBlank).distinct()
            live.forEach { progress.rememberDeviceId(it) }
            (live + progress.knownDeviceIds()).filter(String::isNotBlank).distinct().sorted()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            val failure = PushFailure(PushFailureCode.LOCAL_DATABASE)
            return PushRunResult(acceptedBatches = 0, acceptedRecords = 0, rejectedBatches = 1, hasMoreAppendRows = false, hasRetryableFailure = true, failure = failure)
        }
        if (devices.isEmpty()) return PushRunResult(acceptedBatches = 0, acceptedRecords = 0, rejectedBatches = 0, hasMoreAppendRows = false)
        val start = startDeviceIndex % devices.size
        val selectedCount = minOf(maxDevices, devices.size)
        val selectedDevices = (0 until selectedCount).map { devices[(start + it) % devices.size] }
        val nextDeviceIndex = (start + selectedCount) % devices.size
        var accepted = 0
        var acceptedRecords = 0
        var rejected = 0
        var more = false
        var binaryMore = false
        var retryableFailure = false
        var selectedFailure: PushFailure? = null
        for (deviceId in selectedDevices) {
            if (ndjsonEnabled) {
                for (table in PushAppendTable.entries.filter { it in capabilities.appendTables }) {
                    if (table.isScalarExtension && capabilities.protocolVersion == PushProtocol.VERSION) continue
                    when (val result = pushAppend(table, deviceId, capabilities.protocolVersion)) {
                        is PushResult.Accepted -> {
                            accepted += result.batchCount
                            acceptedRecords += result.recordCount
                            more = more || result.hasMore
                        }
                        is PushResult.Rejected -> {
                            rejected += 1
                            if (selectedFailure == null || result.retryable && !retryableFailure) {
                                selectedFailure = result.failure
                            }
                            retryableFailure = retryableFailure || result.retryable
                        }
                        PushResult.NoData -> Unit
                    }
                }
                for (table in PushMutableTable.entries.filter { it in capabilities.mutableTables }) {
                    when (val result = pushMutable(table, deviceId)) {
                        is PushResult.Accepted -> {
                            accepted += result.batchCount
                            acceptedRecords += result.recordCount
                        }
                        is PushResult.Rejected -> {
                            rejected += 1
                            if (selectedFailure == null || result.retryable && !retryableFailure) {
                                selectedFailure = result.failure
                            }
                            retryableFailure = retryableFailure || result.retryable
                        }
                        PushResult.NoData -> Unit
                    }
                }
            }
            if (binaryAllowed) {
                for (table in PushBinaryTable.entries.filter { it in capabilities.binaryTables }) {
                    val lane = capabilities.objectLane
                    if (lane == null || table !in lane.streams) continue
                    when (val result = pushObjects(table, deviceId, lane, capabilities.protocolVersion)) {
                        is PushResult.Accepted -> {
                            accepted += result.batchCount
                            acceptedRecords += result.recordCount
                            binaryMore = binaryMore || result.hasMore
                        }
                        is PushResult.Rejected -> {
                            rejected += 1
                            if (selectedFailure == null || result.retryable && !retryableFailure) {
                                selectedFailure = result.failure
                            }
                            retryableFailure = retryableFailure || result.retryable
                        }
                        PushResult.NoData -> Unit
                    }
                }
            }
        }
        return PushRunResult(
            acceptedBatches = accepted,
            acceptedRecords = acceptedRecords,
            rejectedBatches = rejected,
            hasMoreAppendRows = more,
            hasMoreBinaryRows = binaryMore,
            hasRetryableFailure = retryableFailure,
            nextDeviceIndex = nextDeviceIndex,
            hasMoreDevices = devices.size > selectedCount,
            failure = selectedFailure,
        )
    }

    private suspend fun deliverBinary(batch: PushBinaryBatch): PushResult {
        if (!destinationStillCurrent()) {
            throw CancellationException("push destination changed")
        }
        val response = try {
            transport.postBinary(batch)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (transport: PushTransportException) {
            return rejected(transport.failure)
        } catch (_: Throwable) {
            return rejected(PushFailure(PushFailureCode.NETWORK_IO))
        }
        if (response.body.size > PushProtocol.MAX_ACK_BYTES) {
            return rejected(PushFailure(PushFailureCode.ACK_INVALID))
        }
        if (response.statusCode !in 200..299) {
            return rejected(
                PushFailure.http(response.statusCode, PushError.parseCode(response.body, batch.protocolVersion)),
            )
        }
        val ack = try {
            PushAck.parse(response.body)
        } catch (_: PushProtocolException) {
            return rejected(PushFailure(PushFailureCode.ACK_INVALID))
        }
        if (!ack.exactlyMatches(batch)) {
            return rejected(PushFailure(PushFailureCode.ACK_INVALID))
        }
        return PushResult.Accepted(batch.batchId, batch.sampleCount, hasMore = false)
    }

    private suspend fun deliverObject(batch: PushBinaryBatch, lane: PushObjectLane, progressDevice: String = batch.deviceId,
                                      frozenIdentity: Boolean = false): PushResult {
        if (!destinationStillCurrent()) {
            throw CancellationException("push destination changed")
        }
        var manifest = PushObjectManifest(batch)
        var uploaded = false
        var expectedKey: String? = null
        try {
            progress.inFlightObject(batch.table, progressDevice)?.let { inFlight ->
                if (inFlight.objectId == manifest.objectId && inFlight.contentSha256 == manifest.contentSha256) {
                    uploaded = inFlight.uploaded
                    expectedKey = inFlight.objectKey
                } else {
                    return rejected(PushFailure(PushFailureCode.LOCAL_DATA))
                }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            return rejected(PushFailure(PushFailureCode.LOCAL_DATABASE))
        }
        if (!uploaded) {
            val intent = try {
                transport.createObjectIntent(manifest, lane)
            } catch (intentFailure: PushTransportException) {
                if (frozenIdentity || intentFailure.failure.receiverCode != "object_id_conflict") {
                    return objectLaneFailure(intentFailure)
                }
                manifest = manifest.replacingObjectId(PushProtocol.freshObjectId())
                try {
                    transport.createObjectIntent(manifest, lane)
                } catch (retry: PushTransportException) {
                    return objectLaneFailure(retry)
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                return objectLaneFailure(PushTransportException(PushFailure(PushFailureCode.NETWORK_IO)))
            }
            if (intent.objectId != manifest.objectId) {
                return rejected(PushFailure(PushFailureCode.ACK_INVALID))
            }
            if (intent.duplicate) {
                if (!frozenIdentity) runCatching { progress.saveInFlightObject(batch.table, progressDevice, null) }
                return PushResult.Accepted(batch.batchId, batch.sampleCount, hasMore = false)
            }
            if (expectedKey != null && intent.objectKey != expectedKey) {
                return rejected(PushFailure(PushFailureCode.ACK_INVALID))
            }
            expectedKey = intent.objectKey
            try {
                progress.saveInFlightObject(
                    batch.table,
                    progressDevice,
                    PushInFlightObject(manifest.objectId, intent.objectKey, manifest.contentSha256, uploaded = false),
                )
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                return rejected(PushFailure(PushFailureCode.LOCAL_DATABASE))
            }
            if (!destinationStillCurrent()) {
                throw CancellationException("push destination changed")
            }
            try {
                transport.uploadObject(intent, batch.payload)
            } catch (failure: PushTransportException) {
                return objectLaneFailure(failure)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                return objectLaneFailure(PushTransportException(PushFailure(PushFailureCode.NETWORK_IO)))
            }
            try {
                progress.saveInFlightObject(
                    batch.table,
                    progressDevice,
                    PushInFlightObject(manifest.objectId, intent.objectKey, manifest.contentSha256, uploaded = true),
                )
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                return rejected(PushFailure(PushFailureCode.LOCAL_DATABASE))
            }
        }
        var reuploaded = false
        while (true) {
            val ack = try {
                transport.completeObject(manifest.objectId, lane)
            } catch (completeFailure: PushTransportException) {
                val code = completeFailure.failure.receiverCode
                if (!reuploaded && (code == "size_mismatch" || code == "object_missing")) {
                    reuploaded = true
                    try {
                        val refreshed = transport.createObjectIntent(manifest, lane)
                        if (refreshed.duplicate) continue
                        if (refreshed.objectId != manifest.objectId) {
                            return rejected(PushFailure(PushFailureCode.ACK_INVALID))
                        }
                        transport.uploadObject(refreshed, batch.payload)
                        expectedKey = refreshed.objectKey
                    } catch (failure: PushTransportException) {
                        return objectLaneFailure(failure)
                    } catch (cancelled: CancellationException) {
                        throw cancelled
                    } catch (_: Throwable) {
                        return objectLaneFailure(PushTransportException(PushFailure(PushFailureCode.NETWORK_IO)))
                    }
                    continue
                }
                return objectLaneFailure(completeFailure)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                return objectLaneFailure(PushTransportException(PushFailure(PushFailureCode.NETWORK_IO)))
            }
            if (ack.objectId != manifest.objectId || !ack.releasesLocalRows) {
                return rejected(PushFailure(PushFailureCode.ACK_INVALID))
            }
            if (expectedKey != null && ack.objectKey != expectedKey) {
                return rejected(PushFailure(PushFailureCode.ACK_INVALID))
            }
            if (!frozenIdentity) runCatching { progress.saveInFlightObject(batch.table, progressDevice, null) }
            return PushResult.Accepted(batch.batchId, batch.sampleCount, hasMore = false)
        }
    }

    private fun objectLaneFailure(error: PushTransportException): PushResult =
        rejected(error.failure)

    private suspend fun deliver(batch: PushBatch): PushResult {
        if (!destinationStillCurrent()) {
            throw CancellationException("push destination changed")
        }
        val response = try {
            transport.post(batch)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (transport: PushTransportException) {
            return rejected(transport.failure)
        } catch (_: Throwable) {
            return rejected(PushFailure(PushFailureCode.NETWORK_IO))
        }
        if (response.body.size > PushProtocol.MAX_ACK_BYTES) {
            return rejected(PushFailure(PushFailureCode.ACK_INVALID))
        }
        if (response.statusCode !in 200..299) {
            return rejected(
                PushFailure.http(response.statusCode, PushError.parseCode(response.body, batch.protocolVersion)),
            )
        }
        val ack = try {
            PushAck.parse(response.body)
        } catch (t: PushProtocolException) {
            return rejected(PushFailure(PushFailureCode.ACK_INVALID))
        }
        if (!ack.exactlyMatches(batch)) {
            return rejected(PushFailure(PushFailureCode.ACK_INVALID))
        }
        return PushResult.Accepted(batch.batchId, batch.recordCount, hasMore = false)
    }

    private fun rejected(failure: PushFailure) =
        PushResult.Rejected(failure.safeCode, failure.retryable, failure)
}
