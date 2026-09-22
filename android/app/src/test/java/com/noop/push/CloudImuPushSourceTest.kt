package com.noop.push

import android.app.Application
import android.content.Context
import com.noop.account.AccountStorageContext
import com.noop.data.StreamPersistence
import com.noop.data.WhoopDatabase
import com.noop.protocol.Whoop5RawImu
import com.noop.testcentre.ImuSessionFileStore
import com.noop.testcentre.ImuContinuousRecorder
import com.noop.testcentre.GroundTruthCollector
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.time.LocalDate
import java.time.ZoneId
import java.util.UUID
import java.util.zip.Inflater
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class, shadows = [SyntheticSecurePrefsShadow::class])
class CloudImuPushSourceTest {
    private val sourceId = "10000000-0000-4000-8000-000000000099"
    private val ts = 1_800_000_100L
    private val device = "whoop-fixture"
    private lateinit var storage: AccountStorageContext
    private lateinit var controller: AccountSessionController
    private lateinit var installation: AutoCloseable
    private lateinit var sessions: ImuSessionFileStore
    private lateinit var continuous: ImuSessionFileStore

    @Before fun setup() {
        val app = RuntimeEnvironment.getApplication() as Context
        val scope = AccountScope.create("https://imu.example.test", UUID.randomUUID().toString())
        val credentials = object : AccountCredentialStore {
            var session: AccountSession? = AccountSession(scope, "synthetic-access", "synthetic-refresh", Long.MAX_VALUE)
            override fun load(projectURL: String) = session
            override fun save(session: AccountSession) { this.session = session }
            override fun clear(projectURL: String) { session = null }
        }
        controller = AccountSessionController(credentials, AccountAuthTransport { _, _ -> error("no network") })
        controller.configure(AccountConfiguration(scope.projectURL, "synthetic-anon"))
        installation = CloudAuthClient.installTestController(controller)
        storage = AccountStorageContext(app, controller.identitySnapshot())
        sessions = ImuSessionFileStore(storage)
        continuous = ImuSessionFileStore(storage, ImuSessionFileStore.NAMESPACE_CONTINUOUS)
    }

    @After fun teardown() { WhoopDatabase.close(); installation.close() }

    private fun source(budget: Int = 16, destination: String = "receiver-v1") =
        CloudImuPushSource(storage, sourceId, destination, budget)

    private fun capture(store: ImuSessionFileStore, window: String, time: Long = ts, seed: Int = 1) {
        store.start(window, device, (ts - 3600) * 1000)
        assertTrue(store.append(device, frame(time, seed), 1_900_000_000_000L) > 0)
        store.flushAll()
    }

    @Test fun realDaoKeepsSameSecondAcrossWindowsAndContinuousOrigin() = runBlocking {
        capture(sessions, "s-one", seed = 1)
        capture(sessions, "s-two", seed = 1)
        capture(continuous, "c-one", seed = 2)
        val mux = source()
        val dao = WhoopDatabase.get(storage).pushDao(mux)
        val rows = dao.binaryRows(PushBinaryTable.RAW_IMU_SESSION, device, 0, 10)
            .map { (it as PushBinaryRow.RawImuSession).record }
        assertEquals(3, rows.size)
        assertEquals(3, rows.map { it.rowId }.toSet().size)
        assertTrue(rows.all { it.ts == ts && it.rowId != it.ts })
        assertTrue(dao.knownDeviceIds(PushCapabilities.ALL).contains(device))
        assertArrayEquals(StreamPersistence.packImuColumns(Whoop5RawImu.rawColumns(frame(ts, 2))!!), rows.first().columns)
        val reopened = source().indexedPushRows(device, 0, 10)
        assertEquals(rows.map { it.rowId }, reopened.map { it.rowId })
        assertArrayEquals(rows.first().columns, reopened.first().columns)
        assertEquals(rows.last(), (dao.binaryRecordAt(PushBinaryTable.RAW_IMU_SESSION, device, rows.last().rowId) as PushBinaryRow.RawImuSession).record)
        val origins = mutableSetOf<String>()
        repeat(3) {
            val archive = mux.archiveRows(device, 1).single()
            val (descriptor, file) = unpack(archive)
            origins += descriptor.getString("origin")
            assertEquals(storage.namespace, descriptor.getString("ownerNamespace"))
            assertEquals(sourceId, descriptor.getString("sourceId"))
            assertEquals("android", descriptor.getString("platform"))
            assertEquals(1, descriptor.getInt("recordCount"))
            assertEquals(PushBinaryCodec.sha256Hex(file), descriptor.getString("fileSHA256"))
            assertTrue(rows.any { it.rowId == descriptor.getJSONArray("members").getJSONObject(0).getLong("rowID") })
            mux.acknowledgeArchive(device, archive)
        }
        assertEquals(setOf("session", "continuous"), origins)
    }

    @Test fun lateBackfillGetsNewCursorAndArchiveRetriesKeepTheirExactPrefix() {
        capture(continuous, "c-one")
        val mux = source()
        val first = mux.indexedPushRows(device, 0, 10).single()
        val archive = mux.archiveRows(device, 1).single()
        continuous.append(device, frame(ts - 20, 2)); continuous.flushAll()
        val retry = source().archiveRows(device, 1).single()
        assertEquals(archive, retry)
        val late = source().indexedPushRows(device, first.rowId, 10).single()
        assertTrue(late.rowId > first.rowId)
        assertEquals(ts - 20, late.ts)
        assertEquals(0, continuous.append(device, frame(ts - 20, 2)))
        val rawBytes = continuous.totalBytes()
        mux.acknowledgeArchive(device, archive)
        assertEquals(rawBytes, continuous.totalBytes())
        val revised = source().archiveRows(device, 1).single()
        val descriptor = unpack(revised).first
        assertEquals(archive.batchId, descriptor.getString("previousArchive"))
        assertEquals(1, descriptor.getInt("prefixRecords"))
        assertEquals(2, descriptor.getInt("recordCount"))
        assertEquals(late.rowId, descriptor.getJSONArray("members").getJSONObject(0).getLong("rowID"))
        assertEquals(archive, source(destination = "new-receiver").archiveRows(device, 1).single())
    }

    @Test fun missingDurableIndexCannotReassignPreviouslyIssuedMembershipIds() {
        capture(continuous, "c-one")
        source().indexedPushRows(device, 0, 10).single()
        val index = File(storage.filesDir, "cloud-imu-v1/$sourceId/membership.sqlite")
        assertTrue(index.delete()) // only this test's closed synthetic membership index
        assertThrows(IllegalStateException::class.java) { source().archiveRows(device, 1) }
        assertThrows(IllegalStateException::class.java) { source().indexedPushRows(device, 0, 10) }
        assertFalse(index.exists())
        assertEquals(1, continuous.stats("c-one", ts, ts).coveredSeconds)
    }

    @Test fun boundedScanResumesAfterReopenWithoutReportingEmptyAndDoesNotStarveEarlierLateData() {
        capture(continuous, "c-one", ts)
        continuous.append(device, frame(ts + 1800)); continuous.flushAll()
        val first = source(budget = 1).indexedPushRows(device, 0, 10).single()
        val second = source(budget = 1).indexedPushRows(device, first.rowId, 10).single()
        assertTrue(second.rowId > first.rowId)
        continuous.append(device, frame(ts - 10)); continuous.flushAll()
        assertEquals(ts - 10, source(budget = 1).indexedPushRows(device, second.rowId, 10).single().ts)
    }

    @Test fun completedContinuousDeletePreservesAcceptedCursorAndAllowsNewCapture() = runBlocking {
        capture(continuous, "c-deleted")
        val http = FixtureTransport()
        val progress = testProgress()
        assertTrue(coordinator(http, progress).pushObjects(PushBinaryTable.RAW_IMU_SESSION, device, imuLane) is PushResult.Accepted)
        val accepted = progress.binaryCursor(PushBinaryTable.RAW_IMU_SESSION, progressDevice)!!
        val oldArchive = source().archiveRows(device, 1).single()
        val recorder = ImuContinuousRecorder(continuous, storage.getSharedPreferences("recorder-fixture", 0),
            nowMs = { (ts + 60) * 1000 }, tickIntervalMs = null)
        assertTrue(recorder.deleteAll())
        assertTrue(source().rowsWereUserWithdrawn(device, 0, accepted.rowId))
        assertNull(source().indexedPushRecord(device, accepted.rowId))
        assertTrue(source().archiveRows(device, 1).isEmpty())
        assertEquals(accepted, progress.binaryCursor(PushBinaryTable.RAW_IMU_SESSION, progressDevice))
        assertThrows(IllegalStateException::class.java) { continuous.start("c-deleted", device, ts * 1000) }
        capture(continuous, "c-next", ts + 10, 2)
        val next = source().indexedPushRows(device, accepted.rowId, 10).single()
        assertTrue(next.rowId > accepted.rowId)
        assertTrue(coordinator(http, progress).pushObjects(PushBinaryTable.RAW_IMU_SESSION, device, imuLane) is PushResult.Accepted)
        assertEquals(next.rowId, progress.binaryCursor(PushBinaryTable.RAW_IMU_SESSION, progressDevice)!!.rowId)
        val newArchive = source().archiveRows(device, 1).single()
        assertNotEquals(oldArchive.batchId, newArchive.batchId)
        assertEquals("c-next", unpack(newArchive).first.getString("window"))
        assertNoFabricatedArchiveDelivery()
    }

    @Test fun supportedSessionDeleteWithdrawsPendingArchiveAndFrozenUploadWithoutAck() = runBlocking {
        val collector = GroundTruthCollector.from(storage)
        val deleted = collector.start(device, (ts - 1) * 1000).sessionId!!
        sessions.append(device, frame(ts)); collector.stop((ts + 1) * 1000)
        val http = FixtureTransport().apply { offline = true }
        val progress = testProgress()
        assertTrue(coordinator(http, progress).pushObjects(PushBinaryTable.RAW_IMU_SESSION, device, imuLane) is PushResult.Rejected)
        val boundary = progress.preparedBoundary(PushBinaryTable.RAW_IMU_SESSION, progressDevice)!!
        source().archiveRows(device, 1).single()
        assertTrue(collector.deleteSession(deleted))
        assertEquals(PushResult.NoData, coordinator(http, progress).pushObjects(PushBinaryTable.RAW_IMU_SESSION, device, imuLane))
        assertNull(progress.binaryCursor(PushBinaryTable.RAW_IMU_SESSION, progressDevice))
        assertNull(progress.preparedBoundary(PushBinaryTable.RAW_IMU_SESSION, progressDevice))
        assertNull(progress.inFlightObject(PushBinaryTable.RAW_IMU_SESSION, progressDevice))
        val nextId = collector.start(device, (ts + 10) * 1000).sessionId!!
        sessions.append(device, frame(ts + 11, 2)); collector.stop((ts + 12) * 1000)
        http.offline = false
        assertTrue(coordinator(http, progress).pushObjects(PushBinaryTable.RAW_IMU_SESSION, device, imuLane) is PushResult.Accepted)
        assertTrue(progress.binaryCursor(PushBinaryTable.RAW_IMU_SESSION, progressDevice)!!.rowId > boundary.endCursor.rowId)
        assertEquals(nextId, unpack(source().archiveRows(device, 1).single()).first.getString("window"))
        assertNoFabricatedArchiveDelivery()
    }

    @Test fun missingFilesWithoutExplicitDeletionRemainAnError() {
        capture(continuous, "c-one")
        val row = source().indexedPushRows(device, 0, 10).single()
        val path = File(storage.filesDir, EnrollmentDataScope.storageName(storage, "raw-imu-continuous"))
        val file = File(path, "c-one").listFiles()!!.single { it.extension == "imus" }
        assertTrue(file.delete()) // simulate loss of this test's synthetic source, not a user delete
        assertFalse(source().rowsWereUserWithdrawn(device, 0, row.rowId))
        assertThrows(IllegalStateException::class.java) { source().indexedPushRecord(device, row.rowId) }
    }

    @Test fun deletingOneOriginCancelsMixedFrozenBoundaryButKeepsOtherMembership() = runBlocking {
        capture(continuous, "c-deleted")
        capture(sessions, "s-kept", seed = 2)
        val original = source().indexedPushRows(device, 0, 10)
        val http = FixtureTransport().apply { offline = true }
        val progress = testProgress()
        assertTrue(coordinator(http, progress).pushObjects(PushBinaryTable.RAW_IMU_SESSION, device, imuLane) is PushResult.Rejected)
        assertEquals(2, progress.preparedBoundary(PushBinaryTable.RAW_IMU_SESSION, progressDevice)!!.sampleCount)
        val recorder = ImuContinuousRecorder(continuous, storage.getSharedPreferences("recorder-fixture", 0),
            nowMs = { (ts + 60) * 1000 }, tickIntervalMs = null)
        assertTrue(recorder.deleteAll())
        val remaining = source().indexedPushRows(device, 0, 10).single()
        assertEquals(original.last(), remaining)
        http.offline = false
        val uploaded = coordinator(http, progress).pushObjects(PushBinaryTable.RAW_IMU_SESSION, device, imuLane) as PushResult.Accepted
        assertEquals(1, uploaded.recordCount)
        assertEquals(remaining.rowId, progress.binaryCursor(PushBinaryTable.RAW_IMU_SESSION, progressDevice)!!.rowId)
    }

    @Test fun versionOneIndexUpgradesWithoutReassigningExistingMembership() {
        capture(continuous, "c-one")
        val original = source().indexedPushRows(device, 0, 10).single()
        val index = File(storage.filesDir, "cloud-imu-v1/$sourceId/membership.sqlite")
        android.database.sqlite.SQLiteDatabase.openOrCreateDatabase(index, null).use {
            it.execSQL("DROP TABLE withdrawn") // this isolated synthetic index is the old v1 schema
            it.version = 1
        }
        assertEquals(original, source().indexedPushRows(device, 0, 10).single())
        assertTrue(continuous.deleteFiles("c-one"))
        continuous.remove("c-one")
        assertTrue(source().rowsWereUserWithdrawn(device, 0, original.rowId))
    }

    @Test fun indexedPrefixUploadsBeforeInventoryCompletesAndDiscoveryUsesNormalWorkerContinuation() = runBlocking {
        capture(continuous, "c-large")
        repeat(33) { continuous.append(device, frame(ts + (it + 1) * 1800L)) }
        continuous.flushAll()
        val progress = testProgress()
        val http = FixtureTransport()
        val capabilities = PushCapabilities(emptySet(), emptySet(), setOf(PushBinaryTable.RAW_IMU_SESSION),
            "1.4", objectLane = imuLane)
        val first = coordinator(http, progress, 1).pushKnownDevices(capabilities = capabilities, binaryEnabled = true)
        assertEquals(1, first.acceptedRecords)
        assertEquals(0, first.rejectedBatches)
        assertTrue(shouldContinuePushRun(first, false))
        // Drain more slices than the worker's failure-attempt budget. Each real coordinator slice
        // receives a synthetic transport ACK and schedules normal continuation, never failure retry.
        repeat(33) {
            val slice = coordinator(http, progress, 1).pushKnownDevices(capabilities = capabilities, binaryEnabled = true)
            assertEquals(1, slice.acceptedRecords)
            assertEquals(0, slice.rejectedBatches)
            assertTrue(shouldContinuePushRun(slice, false))
        }
        val scan = coordinator(http, progress, 1).pushKnownDevices(capabilities = capabilities, binaryEnabled = true)
        assertEquals(0, scan.acceptedBatches)
        assertEquals(0, scan.acceptedRecords)
        assertEquals(0, scan.rejectedBatches)
        assertFalse(scan.hasRetryableFailure)
        assertTrue(scan.hasMoreBinaryRows)
        assertTrue(shouldContinuePushRun(scan, false))
        assertNull(scan.failure)
    }

    private val progressDevice get() = "$device:imu-membership-v1"
    private val imuLane get() = PushObjectLane("/objects", PushProtocol.MAX_OBJECT_WIRE_BYTES.toLong(), 3600,
        setOf(PushBinaryTable.RAW_IMU_SESSION))
    private fun testProgress() = SharedPrefsPushProgressStore(storage.getSharedPreferences("delete-progress", 0))
    private fun coordinator(http: PushTransport, progress: PushProgressStore, budget: Int = 16) =
        PushCoordinator(WhoopDatabase.get(storage).pushDao(source(budget)), http, progress, sourceId,
            { LocalDate.of(2026, 9, 21) }, ZoneId.of("UTC"))
    private fun assertNoFabricatedArchiveDelivery() {
        android.database.sqlite.SQLiteDatabase.openDatabase(
            File(storage.filesDir, "cloud-imu-v1/$sourceId/membership.sqlite").path, null,
            android.database.sqlite.SQLiteDatabase.OPEN_READONLY).use { db ->
            db.rawQuery("SELECT count(*) FROM delivered", null).use { assertTrue(it.moveToFirst()); assertEquals(0, it.getInt(0)) }
            db.rawQuery("SELECT count(*) FROM withdrawn", null).use { assertTrue(it.moveToFirst()); assertEquals(1, it.getInt(0)) }
        }
    }
    private class FixtureTransport : PushTransport {
        var offline = false
        override suspend fun post(batch: PushBatch): PushTransportResponse = error("inline not used")
        override suspend fun createObjectIntent(manifest: PushObjectManifest, lane: PushObjectLane) =
            PushObjectIntent(manifest.objectId, "fixture/${manifest.objectId}", "https://object.invalid/put", emptyMap(), null, false)
        override suspend fun uploadObject(intent: PushObjectIntent, body: ByteArray) {
            if (offline) throw PushTransportException(PushFailure(PushFailureCode.NETWORK_IO))
        }
        override suspend fun completeObject(objectId: String, lane: PushObjectLane) =
            PushObjectAck(objectId, "ready", "fixture/$objectId", false)
    }

    @Test fun offlineObjectReplayFreezesMembershipAndIgnoresLegacyTimestampCursor() = runBlocking {
        capture(continuous, "c-one")
        val prefs = storage.getSharedPreferences("imu-progress-fixture", 0)
        fun progress() = SharedPrefsPushProgressStore(prefs)
        progress().saveBinaryCursor(PushBinaryTable.RAW_IMU_SESSION, device, PushCursor(ts + 9999, "0".repeat(64)))
        val manifests = mutableListOf<PushObjectManifest>()
        val uploads = mutableListOf<ByteArray>()
        var offline = true
        val transport = object : PushTransport {
            override suspend fun post(batch: PushBatch): PushTransportResponse = error("inline not used")
            override suspend fun createObjectIntent(manifest: PushObjectManifest, lane: PushObjectLane): PushObjectIntent {
                manifests += manifest
                return PushObjectIntent(manifest.objectId, "fixture/${manifest.objectId}", "https://object.invalid/put", emptyMap(), null, false)
            }
            override suspend fun uploadObject(intent: PushObjectIntent, body: ByteArray) {
                uploads += body
                if (offline) throw PushTransportException(PushFailure(PushFailureCode.NETWORK_IO))
            }
            override suspend fun completeObject(objectId: String, lane: PushObjectLane) =
                PushObjectAck(objectId, "ready", "fixture/$objectId", false)
        }
        val lane = PushObjectLane("/objects", PushProtocol.MAX_OBJECT_WIRE_BYTES.toLong(), 3600,
            setOf(PushBinaryTable.RAW_IMU_SESSION))
        fun coordinator() = PushCoordinator(WhoopDatabase.get(storage).pushDao(source()), transport, progress(), sourceId,
            { LocalDate.of(2026, 9, 21) }, ZoneId.of("UTC"))
        assertTrue(coordinator().pushObjects(PushBinaryTable.RAW_IMU_SESSION, device, lane) is PushResult.Rejected)
        val key = "$device:imu-membership-v1"
        val frozen = progress().preparedBoundary(PushBinaryTable.RAW_IMU_SESSION, key)!!
        continuous.append(device, frame(ts - 15, 2)); continuous.flushAll()
        offline = false
        val recovered = coordinator().pushObjects(PushBinaryTable.RAW_IMU_SESSION, device, lane) as PushResult.Accepted
        assertEquals(1, recovered.recordCount)
        assertArrayEquals(uploads[0], uploads[1])
        assertEquals(manifests[0].objectId, manifests[1].objectId)
        assertEquals(frozen.endCursor, progress().binaryCursor(PushBinaryTable.RAW_IMU_SESSION, key))
        assertNull(progress().preparedBoundary(PushBinaryTable.RAW_IMU_SESSION, key))
        assertTrue(coordinator().pushObjects(PushBinaryTable.RAW_IMU_SESSION, device, lane) is PushResult.Accepted)
        assertEquals(PushResult.NoData, coordinator().pushObjects(PushBinaryTable.RAW_IMU_SESSION, device, lane))
        assertEquals(2, continuous.stats("c-one", ts - 15, ts).coveredSeconds)
    }

    @Test fun capturedStoresAndProgressCannotMoveToAnotherAccountOrInstallation() {
        capture(continuous, "c-one")
        val original = source().indexedPushRows(device, 0, 10).single()
        val otherScope = AccountScope.create(storage.identity.scope!!.projectURL, UUID.randomUUID().toString())
        val other = AccountStorageContext(storage.baseContext,
            AccountIdentitySnapshot(otherScope.projectURL, otherScope, UUID.randomUUID()))
        assertTrue(CloudImuPushSource(other, sourceId).indexedPushRows(device, 0, 10).isEmpty())
        controller.clearSession()
        assertEquals(original, source().indexedPushRows(device, 0, 10).single())
        val newSource = "10000000-0000-4000-8000-000000000098"
        val archive = CloudImuPushSource(storage, newSource, "receiver-v1").archiveRows(device, 1).single()
        assertEquals(newSource, unpack(archive).first.getString("sourceId"))
        assertTrue(other.root.listFiles().orEmpty().none { it.name.startsWith("raw-imu-") && it.walk().any { file -> file.extension == "imus" } })
    }

    @Test fun accountFenceRejectsRetiredCaptureBeforeAnyRowsCanLeave() = runBlocking {
        capture(continuous, "c-one")
        val captured = storage.identity.context!!
        val admission = AccountPushAdmission(captured, captured.scope, sourceId) { CloudAuthClient.isCurrent(storage, it) }
        val fenced = AccountFencedSnapshot(WhoopDatabase.get(storage).pushDao(source()), admission)
        assertEquals(1, fenced.binaryRows(PushBinaryTable.RAW_IMU_SESSION, device, 0, 10).size)
        controller.clearSession()
        assertThrows(AccountAuthException::class.java) { runBlocking {
            fenced.binaryRows(PushBinaryTable.RAW_IMU_SESSION, device, 0, 10)
        } }
        Unit
    }

    @Test fun translatedRecorderUsesCorrectedUploadAndRetentionPolicyFallback() {
        for (language in listOf("en", "de", "es", "fr", "pl", "pt-PT", "ru", "zh")) {
            val config = android.content.res.Configuration(storage.resources.configuration)
            config.setLocale(java.util.Locale.forLanguageTag(language))
            val localized = storage.createConfigurationContext(config)
            val privacy = localized.getString(com.noop.R.string.imu_recorder_privacy)
            val retention = localized.getString(com.noop.R.string.imu_recorder_retention_policy)
            if (language == "de") {
                assertTrue(privacy.contains("Cloud-Uploads deines Kontos"))
                assertTrue(retention.contains("nicht automatisch gelöscht"))
            } else {
                assertTrue(privacy.contains("account's cloud uploads"))
                assertTrue(retention.contains("A successful upload does not automatically delete them."))
            }
        }
    }

    @Test fun corruptedSourceDoesNotAdvanceMembershipOrProducePartialArchive() {
        capture(continuous, "c-one")
        val mux = source()
        val row = mux.indexedPushRows(device, 0, 10).single()
        val file = storage.filesDir.walk().single { it.extension == "imus" }
        file.appendBytes(byteArrayOf(1, 2, 3))
        assertThrows(Exception::class.java) { source().indexedPushRecord(device, row.rowId) }
        assertThrows(Exception::class.java) { source().archiveRows(device, 1) }
    }

    @Test fun reverseTimeMembershipObjectsStayWithinTheDeclaredObjectWindow() {
        val rows = listOf(ts, ts - PushProtocol.MAX_IMU_OBJECT_WINDOW_SECONDS - 1,
            ts - PushProtocol.MAX_IMU_OBJECT_WINDOW_SECONDS).mapIndexed { index, timestamp ->
            PushBinaryRow.RawImuSession(PushRawImuRecord(index + 1L, timestamp, ByteArray(1200)))
        }
        val batch = PushProtocol.binaryObjectBatch(PushBinaryTable.RAW_IMU_SESSION, sourceId, device, null, rows)
        assertEquals(1, batch.sampleCount)
        assertEquals(ts, batch.startTs)
        assertEquals(ts + 1, batch.endTs)
    }

    @Test fun nativeArchiveArtifactsPreserveBothSourcesThroughPackedWireEncoding() = runBlocking {
        capture(sessions, "session-fixture", seed = 1)
        capture(continuous, "continuous-fixture", seed = 2)
        val mux = source()
        val root = System.getenv("ANDROID_IMU_FIXTURE_DIR")?.let { File(it).apply { mkdirs() } }
        val rawRows = WhoopDatabase.get(storage).pushDao(mux)
            .binaryRows(PushBinaryTable.RAW_IMU_SESSION, device, 0, 10)
        val rawBatch = PushProtocol.binaryObjectBatch(PushBinaryTable.RAW_IMU_SESSION, sourceId, device,
            null, rawRows, "1.4", PushProtocol.MAX_OBJECT_DECODED_BYTES)
        val rawPacked = PushBinaryCodec.pack(PushBinaryTable.RAW_IMU_SESSION, rawRows)
        assertEquals(2, rawRows.size)
        assertEquals(4, rawPacked[5].toInt())
        assertEquals(PushBinaryCodec.sha256Hex(rawPacked), rawBatch.contentSha256)
        val rawHashes = JSONObject()
        linkedMapOf("manifest.json" to rawBatch.manifestJSON, "payload.zst" to rawBatch.payload,
            "payload.npb1" to rawPacked).forEach { (name, bytes) ->
            rawHashes.put(name, PushBinaryCodec.sha256Hex(bytes))
            root?.let { File(it, "rawImuSession").apply { mkdirs() } }?.let { File(it, name).writeBytes(bytes) }
        }
        val cases = org.json.JSONArray()
        repeat(2) {
            val row = mux.archiveRows(device, 1).single()
            val (descriptor, file, encodedDescriptor) = unpack(row)
            val batch = PushProtocol.binaryObjectBatch(PushBinaryTable.RAW_BATCH, sourceId, device, null,
                listOf(PushBinaryRow.RawBatch(row)), "1.4", PushProtocol.MAX_OBJECT_DECODED_BYTES)
            val packed = PushBinaryCodec.pack(PushBinaryTable.RAW_BATCH, listOf(PushBinaryRow.RawBatch(row)))
            assertEquals(PushBinaryCodec.sha256Hex(packed), batch.contentSha256)
            val origin = descriptor.getString("origin")
            val outputs = linkedMapOf("manifest.json" to batch.manifestJSON, "payload.zst" to batch.payload,
                "descriptor.json" to encodedDescriptor, "source.imus" to file,
                "payload.npb1" to packed)
            val hashes = JSONObject()
            outputs.forEach { (name, bytes) ->
                hashes.put(name, PushBinaryCodec.sha256Hex(bytes))
                root?.let { File(it, origin).apply { mkdirs() } }?.let { File(it, name).writeBytes(bytes) }
            }
            cases.put(JSONObject().put("origin", origin).put("archiveBatchId", row.batchId)
                .put("objectId", batch.objectId).put("batchId", batch.batchId).put("recordCount", 1).put("files", hashes))
            mux.acknowledgeArchive(device, row)
        }
        root?.let { File(it, "fixture.json").writeText(JSONObject().put("synthetic", true)
            .put("producer", "android.CloudImuPushSource").put("ownerUserId", storage.identity.scope!!.userID)
            .put("ownerNamespace", storage.namespace).put("sourceId", sourceId).put("deviceId", device)
            .put("rawImuSession", JSONObject().put("objectId", rawBatch.objectId).put("batchId", rawBatch.batchId)
                .put("recordCount", rawRows.size).put("files", rawHashes))
            .put("cases", cases).toString(2)) }
        assertEquals(2, cases.length())
    }

    private fun frame(timestamp: Long, seed: Int = 1) = ByteArray(1244).also { frame ->
        ByteBuffer.wrap(frame).order(ByteOrder.LITTLE_ENDIAN).putInt(15, timestamp.toInt())
        frame[24] = 100; frame[630] = 100; frame[28] = seed.toByte()
    }

    private fun unpack(record: PushRawBatchRecord): Triple<JSONObject, ByteArray, ByteArray> {
        val size = ByteBuffer.wrap(record.framesBlob).order(ByteOrder.LITTLE_ENDIAN).int
        val packed = ByteArray(size)
        val inflater = Inflater(true)
        try {
            inflater.setInput(record.framesBlob, 4, record.framesBlob.size - 4)
            assertEquals(size, inflater.inflate(packed)); assertTrue(inflater.finished()); assertEquals(0, inflater.remaining)
        } finally { inflater.end() }
        val buffer = ByteBuffer.wrap(packed).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(2, buffer.int)
        val descriptorBytes = ByteArray(buffer.int); buffer.get(descriptorBytes)
        val file = ByteArray(buffer.int); buffer.get(file); assertFalse(buffer.hasRemaining())
        val descriptor = JSONObject(descriptorBytes.toString(Charsets.UTF_8))
        assertEquals("imf1.${PushBinaryCodec.sha256Hex(descriptorBytes)}.${PushBinaryCodec.sha256Hex(file)}", record.batchId)
        assertEquals(descriptorBytes.size + file.size, record.byteSize)
        assertEquals("NOOPIMU2", file.copyOf(8).toString(Charsets.US_ASCII))
        return Triple(descriptor, file, descriptorBytes)
    }
}
