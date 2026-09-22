package com.noop.data

import android.app.Application
import com.noop.account.AccountStorageContext
import com.noop.ble.BleCaptureIdentity
import com.noop.push.*
import androidx.room.withTransaction
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.zip.Inflater
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class BleRawDurabilityTest {
    private lateinit var installation: AutoCloseable
    private lateinit var account: AccountStorageContext
    private lateinit var db: WhoopDatabase
    private lateinit var owner: BleCaptureIdentity
    private lateinit var controller: AccountSessionController
    private val source = "20000000-0000-4000-8000-000000000002"
    @Before fun setup() {
        val scope = AccountScope.create("https://fixture.invalid", "10000000-0000-4000-8000-000000000001")
        controller = AccountSessionController(object : AccountCredentialStore {
            override fun load(projectURL: String) = AccountSession(scope, "fixture", "fixture", Long.MAX_VALUE)
            override fun save(session: AccountSession) {}
            override fun clear(projectURL: String) {}
        }, AccountAuthTransport { _, _ -> AccountReply(200,
            """{"access_token":"fixture","refresh_token":"fixture","expires_in":3600,"user":{"id":"${scope.userID}"}}""") })
        controller.configure(AccountConfiguration(scope.projectURL, "fixture"))
        installation = CloudAuthClient.installTestController(controller)
        account = AccountStorageContext(RuntimeEnvironment.getApplication(), controller.identitySnapshot())
        // Robolectric has no AndroidKeyStore. This synthetic account has no enrollment binding;
        // pin that absence without substituting any Room, transaction, receipt or write-fence code.
        org.robolectric.util.ReflectionHelpers.setStaticField(EnrollmentDataScope::class.java, "initialized", true)
        org.robolectric.util.ReflectionHelpers.setStaticField(EnrollmentDataScope::class.java, "pinned", null)
        db = WhoopDatabase.get(account)
        owner = BleCaptureIdentity(account.namespace, account.identity.generation.toString(), source, "original", "session")
    }
    @After fun teardown() {
        WhoopDatabase.close(); installation.close()
        org.robolectric.util.ReflectionHelpers.setStaticField(EnrollmentDataScope::class.java, "initialized", false)
    }
    private fun capture(ordinal: Int = 1, frames: List<ByteArray> = listOf(byteArrayOf(1, 2, 3))) =
        BleRawCapture.create(owner, frames, "WHOOP4", 1_790_000_000_123, 123, 100, 1_790_000_000,
            "receipt_anchor_unverified", ordinal.toString())

    @Test fun commitOutlivesReopenWithExactIdentityBytesAndUploadDebt() = runBlocking {
        val raw = capture()
        WhoopRepository(db).insert(StreamBatch(hr = listOf(HrRow(100, 70))), owner.deviceId,
            rawCaptures = listOf(raw), markCloudPushDebt = true)
        WhoopDatabase.close()
        // close retires the old writer generation. A new process reconstructs a fresh generation.
        controller.signIn("fixture", "fixture")
        account = AccountStorageContext(RuntimeEnvironment.getApplication(), controller.identitySnapshot())
        db = WhoopDatabase.get(account)
        val pending = db.pushDao(captureSourceId = source).binaryRows(PushBinaryTable.RAW_BATCH, owner.deviceId, 0, 10)
        val record = (pending.single() as PushBinaryRow.RawBatch).record
        assertEquals(raw.row.batchId, record.batchId)
        assertArrayEquals(raw.row.framesBlob, record.framesBlob)
        assertEquals(listOf("cloudPush"), WhoopRepository(db).owedSyncJobs().map { it.kind })
        assertTrue(db.pushDao(captureSourceId = source).binaryRows(PushBinaryTable.RAW_BATCH, "new-device", 0, 10).isEmpty())
        try {
            db.pushDao(captureSourceId = "foreign-source").binaryRows(PushBinaryTable.RAW_BATCH, owner.deviceId, 0, 10)
            fail("source changed")
        } catch (_: PushProtocolException) {}
    }

    @Test fun rawFailureRollsBackDecodedRowsAndDebt() = runBlocking {
        db.openHelper.writableDatabase.execSQL("CREATE TRIGGER refuse_raw BEFORE INSERT ON bleRawBatch BEGIN SELECT RAISE(ABORT,'fixture'); END")
        try {
            WhoopRepository(db).insert(StreamBatch(hr = listOf(HrRow(100, 70))), owner.deviceId,
                rawCaptures = listOf(capture()), markCloudPushDebt = true)
            fail("raw failure")
        } catch (_: android.database.sqlite.SQLiteException) {}
        db.openHelper.readableDatabase.query("SELECT count(*) FROM hrSample").use { it.moveToFirst(); assertEquals(0, it.getInt(0)) }
        assertTrue(WhoopRepository(db).owedSyncJobs().isEmpty())
    }

    @Test fun additive46to47MigrationPreservesExistingSamples() = runBlocking {
        val sql = db.openHelper.writableDatabase
        sql.execSQL("INSERT INTO hrSample(deviceId,ts,bpm,synced) VALUES('original',100,70,0)")
        sql.execSQL("DROP TABLE bleRawMember")
        sql.execSQL("DROP TABLE bleRawBatch")
        sql.execSQL("PRAGMA user_version=46")
        WhoopDatabase.close()
        controller.signIn("fixture", "fixture")
        account = AccountStorageContext(RuntimeEnvironment.getApplication(), controller.identitySnapshot())
        db = WhoopDatabase.get(account)
        db.openHelper.readableDatabase.query("SELECT bpm FROM hrSample WHERE deviceId='original'").use {
            assertTrue(it.moveToFirst()); assertEquals(70,it.getInt(0))
        }
        assertEquals(47,db.openHelper.readableDatabase.version)
        assertTrue(db.pushDao(captureSourceId=source).binaryRows(PushBinaryTable.RAW_BATCH,owner.deviceId,0,1).isEmpty())
    }

    @Test fun capacityHoldsExactPendingPrefixAndReplayIsIdempotent() = runBlocking {
        val raw = capture()
        val capacity = raw.row.framesBlob.size.toLong() + 640
        db.withTransaction { raw.insert(db.openHelper.writableDatabase, capacity) }
        db.withTransaction { raw.insert(db.openHelper.writableDatabase, 0) }
        try {
            db.withTransaction { capture(2).insert(db.openHelper.writableDatabase, capacity) }
            fail("capacity")
        } catch (_: java.io.IOException) {}
        val sourceDao = db.pushDao(captureSourceId = source)
        val pending = sourceDao.binaryRows(PushBinaryTable.RAW_BATCH, owner.deviceId, 0, 10)
        assertEquals(1, pending.size)
        sourceDao.acknowledgeBinary(PushBinaryTable.RAW_BATCH, owner.deviceId, pending)
        assertTrue(sourceDao.binaryRows(PushBinaryTable.RAW_BATCH, owner.deviceId, 0, 10).isEmpty())
        db.withTransaction { capture(2).insert(db.openHelper.writableDatabase, capacity) }
        assertEquals(1, sourceDao.binaryRows(PushBinaryTable.RAW_BATCH, owner.deviceId, 0, 10).size)
    }

    @Test fun packedRawFramesRoundTripWithoutDecodedTimestampAssumptions() {
        val frames = listOf(byteArrayOf(0, 1, -1), byteArrayOf(9, 0, 8, 0))
        val raw = capture(frames = frames)
        val buffer = ByteBuffer.wrap(raw.row.framesBlob).order(ByteOrder.LITTLE_ENDIAN)
        val unpacked = ByteArray(buffer.int)
        val inflater = Inflater(true)
        try {
            inflater.setInput(raw.row.framesBlob, 4, raw.row.framesBlob.size - 4)
            assertEquals(unpacked.size, inflater.inflate(unpacked)); assertTrue(inflater.finished())
        } finally { inflater.end() }
        val data = ByteBuffer.wrap(unpacked).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(frames.size, data.int)
        frames.forEach { expected -> val bytes = ByteArray(data.int); data.get(bytes); assertArrayEquals(expected, bytes) }
        assertFalse(data.hasRemaining())
        assertEquals(raw.row.batchId, capture(frames = frames).row.batchId)
    }

    @Test fun durableSparseCommitsCoalesceUntilSelectionThenRetryBytesAreSealed() = runBlocking {
        val repo = WhoopRepository(db)
        repeat(8) { repo.insert(StreamBatch(),owner.deviceId,rawCaptures=listOf(capture(it)),markCloudPushDebt=true) }
        val dao = db.pushDao(captureSourceId=source)
        val first = dao.binaryRows(PushBinaryTable.RAW_BATCH,owner.deviceId,0,10)
        assertEquals(1,first.size)
        assertEquals(8,(first.single() as PushBinaryRow.RawBatch).record.frameCount)
        repo.insert(StreamBatch(),owner.deviceId,rawCaptures=listOf(capture(99)),markCloudPushDebt=true)
        val later = dao.binaryRows(PushBinaryTable.RAW_BATCH,owner.deviceId,0,10)
        assertEquals(2,later.size)
        assertEquals(first.single(),later.first())
        // An exact committed prefix replay cannot add a second copy, even after sealing.
        repo.insert(StreamBatch(),owner.deviceId,rawCaptures=listOf(capture(0)),markCloudPushDebt=true)
        assertEquals(later,dao.binaryRows(PushBinaryTable.RAW_BATCH,owner.deviceId,0,10))
    }

    @Test fun paginationDoesNotSealFreshSingletonsBeforeTheirBoundedWindow() = runBlocking {
        val now = System.currentTimeMillis()
        val raw = BleRawCapture.create(owner,listOf(byteArrayOf(1)),"WHOOP4",now,123,100,now/1000,"unverified","young")
        WhoopRepository(db).insert(StreamBatch(),owner.deviceId,rawCaptures=listOf(raw),markCloudPushDebt=true)
        val dao = db.pushDao(captureSourceId=source)
        assertTrue(dao.binaryRows(PushBinaryTable.RAW_BATCH,owner.deviceId,0,1).isEmpty())
        assertTrue(WhoopRepository(db).owedSyncJobs().any { it.kind=="cloudPush" })
        db.openHelper.writableDatabase.execSQL("UPDATE bleRawBatch SET receivedAtMs=?",arrayOf(now-10_001))
        assertEquals(1,dao.binaryRows(PushBinaryTable.RAW_BATCH,owner.deviceId,0,1).size)
    }

    @Test fun networkFailureAndInvalidAckLeaveExactOutboxForRetryWithoutViewModel() = runBlocking {
        WhoopRepository(db).insert(StreamBatch(), owner.deviceId, rawCaptures = listOf(capture()), markCloudPushDebt = true)
        val attempts = mutableListOf<PushBinaryBatch>()
        var status = 503
        var valid = false
        val transport = object : PushTransport {
            override suspend fun post(batch: PushBatch) = error("raw-only fixture")
            override suspend fun postBinary(batch: PushBinaryBatch): PushTransportResponse {
                attempts += batch
                val ack = PushAck(batch.protocolVersion, if (valid) batch.batchId else "wrong",
                    batch.wireName, batch.deviceId, batch.endCursor, batch.sampleCount, "accepted")
                return PushTransportResponse(status, ack.encode())
            }
        }
        val dao = db.pushDao(captureSourceId = source)
        val stages = mutableListOf<com.noop.ble.BlePipelineTrace.Stage>()
        val coordinator = PushCoordinator(dao, transport, MemoryProgress(), source,
            { java.time.LocalDate.of(2026, 9, 21) }, java.time.ZoneOffset.UTC, trace = { stages += it })
        assertTrue(coordinator.pushBinary(PushBinaryTable.RAW_BATCH, owner.deviceId) is PushResult.Rejected)
        status = 200
        assertTrue(coordinator.pushBinary(PushBinaryTable.RAW_BATCH, owner.deviceId) is PushResult.Rejected)
        assertEquals(1, dao.binaryRows(PushBinaryTable.RAW_BATCH, owner.deviceId, 0, 1).size)
        assertFalse(stages.contains(com.noop.ble.BlePipelineTrace.Stage.CLOUD_ACK))
        valid = true
        assertTrue(coordinator.pushBinary(PushBinaryTable.RAW_BATCH, owner.deviceId) is PushResult.Accepted)
        assertTrue(dao.binaryRows(PushBinaryTable.RAW_BATCH, owner.deviceId, 0, 1).isEmpty())
        assertEquals(3, stages.count { it == com.noop.ble.BlePipelineTrace.Stage.UPLOAD_ATTEMPT })
        assertEquals(1, stages.count { it == com.noop.ble.BlePipelineTrace.Stage.CLOUD_ACK })
        attempts.drop(1).forEach { assertArrayEquals(attempts[0].payload, it.payload); assertEquals(attempts[0].batchId, it.batchId) }
    }

    @Test fun liveOnlyRuntimeCommitReachesControlledReceiverWithoutAnyViewModel() = runBlocking {
        val received = kotlinx.coroutines.CompletableDeferred<PushBinaryBatch>()
        val scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.Default)
        val raw = capture()
        val transport = object : PushTransport {
            override suspend fun post(batch: PushBatch) = error("raw-only fixture")
            override suspend fun postBinary(batch: PushBinaryBatch): PushTransportResponse {
                received.complete(batch)
                return PushTransportResponse(200, PushAck(batch.protocolVersion,batch.batchId,batch.wireName,
                    batch.deviceId,batch.endCursor,batch.sampleCount,"accepted").encode())
            }
        }
        val coordinator = PushCoordinator(db.pushDao(captureSourceId=source),transport,MemoryProgress(),source,
            { java.time.LocalDate.of(2026,9,21) },java.time.ZoneOffset.UTC)
        try {
            val queue = com.noop.ble.LiveCaptureQueue(scope, { _: BleRawCapture -> owner },
                persist = { rows -> WhoopRepository(db).insert(StreamBatch(),owner.deviceId,rawCaptures=rows,markCloudPushDebt=true) },
                committed = { kotlinx.coroutines.runBlocking { coordinator.pushBinary(PushBinaryTable.RAW_BATCH,owner.deviceId) } },
                blocked = { received.completeExceptionally(AssertionError("capture blocked")) })
            queue.offer(raw,raw.row.framesBlob.size)
            val batch = kotlinx.coroutines.withTimeout(5_000) { received.await() }
            assertEquals(1,batch.sampleCount)
            assertEquals(owner.deviceId,batch.deviceId)
            queue.drain() // joins the sole writer and its post-commit wake
        } finally { scope.coroutineContext[kotlinx.coroutines.Job]?.cancel() }
        Unit
    }

    @Test fun unknownHistoryCommitsRequiredBytesBeforeTrimAndDiskFailureHoldsLaterEnds() = runBlocking {
        val cursors = mutableMapOf<String,Long>()
        val cursor = object : com.noop.ble.TrimCursorStore {
            override suspend fun set(name: String,value: Long) { cursors[name]=value }
            override suspend fun get(name: String) = cursors[name]
        }
        val frame = com.noop.protocol.Framing.puffinCommandFrame(0,0,byteArrayOf(7,8,9),type=99)
        val payload = ByteBuffer.allocate(18).order(ByteOrder.LITTLE_ENDIAN)
            .putInt(1_790_000_000).putShort(0).putInt(0).putInt(42).putInt(0).array()
        val end = com.noop.protocol.Framing.puffinCommandFrame(2,0,payload,type=49)
        var acks = 0
        val backfill = com.noop.ble.Backfiller(WhoopRepository(db),owner.deviceId,cursor,
            ackTrim = { trim,_ ->
                db.openHelper.readableDatabase.query("SELECT framesBlob FROM bleRawBatch").use {
                    assertTrue(it.moveToFirst())
                    assertArrayEquals(frame,BleRawCapture.decodeFrames(it.getBlob(0)).single())
                }
                assertEquals(42L,trim); assertEquals(42L,cursors["strap_trim:${owner.deviceId}"])
                acks++
            }, captureIdentity={owner}, captureStillCurrent={it==owner}, rejectedSink={_,_->true})
        backfill.begin(com.noop.protocol.DeviceFamily.WHOOP5)
        backfill.ingest(frame); backfill.ingest(end)
        assertEquals(1,acks)
        db.openHelper.writableDatabase.execSQL("CREATE TRIGGER refuse_member BEFORE INSERT ON bleRawMember BEGIN SELECT RAISE(ABORT,'fixture'); END")
        backfill.begin(com.noop.protocol.DeviceFamily.WHOOP5)
        backfill.ingest(frame); backfill.ingest(end); backfill.ingest(end)
        assertTrue(backfill.persistStalled)
        assertEquals(1,acks)
    }

    @Test fun recoveryIntentSurvivesReconstructionButNotStopRevocationOrSourceReplacement() = runBlocking {
        var permitted = true
        var userStop: Long? = null
        com.noop.ui.NoopPrefs.setBackgroundConnection(account, true)
        fun runtime() = com.noop.ble.BleRuntimeIntent(account, { permitted }, { userStop })
        val target = com.noop.ble.BleRuntimeTarget(owner.deviceId, "AA:BB:CC:DD:EE:FF", com.noop.ble.WhoopModel.WHOOP4)
        assertNull(runtime().target())
        assertTrue(runtime().authorize()); assertTrue(runtime().remember(target))
        assertEquals(target, runtime().target())
        val oldAccount = account
        controller.signIn("fixture", "fixture")
        account = AccountStorageContext(RuntimeEnvironment.getApplication(), controller.identitySnapshot())
        assertNotEquals(oldAccount.identity.generation, account.identity.generation)
        assertEquals(target, runtime().target())
        permitted = false; assertNull(runtime().target())
        permitted = true; assertEquals(target, runtime().target())
        userStop = Long.MAX_VALUE; assertNull(runtime().target())
        userStop = null; assertTrue(runtime().stop()); assertNull(runtime().target())
        assertTrue(runtime().authorize()); assertEquals(target, runtime().target())
        account.getSharedPreferences("ble-runtime-v1", 0).edit().putString("source", "replacement").commit()
        assertNull(runtime().target())
    }

    @Test fun deviceSwitchDuringCursorIoCannotAckNewConnectionOrReattributeRaw() = runBlocking {
        var current = owner
        val cursors = mutableMapOf<String,Long>()
        val cursor = object : com.noop.ble.TrimCursorStore {
            override suspend fun set(name: String,value: Long) {
                cursors[name] = value
                // Model a device switch while the old connection's cursor IO is suspended.
                current = owner.copy(deviceId = "replacement", sessionId = "new-session")
            }
            override suspend fun get(name: String) = cursors[name]
        }
        var acks = 0
        val backfill = com.noop.ble.Backfiller(WhoopRepository(db),owner.deviceId,cursor,
            ackTrim = { _,_ -> acks++ }, captureIdentity = { current },
            captureStillCurrent = { it == current }, capturedAck = { _,_,_ -> acks++ })
        val frame = com.noop.protocol.Framing.puffinCommandFrame(0,0,byteArrayOf(7,8,9),type=99)
        val payload = ByteBuffer.allocate(18).order(ByteOrder.LITTLE_ENDIAN)
            .putInt(1_790_000_000).putShort(0).putInt(0).putInt(42).putInt(0).array()
        val end = com.noop.protocol.Framing.puffinCommandFrame(2,0,payload,type=49)
        backfill.begin(com.noop.protocol.DeviceFamily.WHOOP5)
        backfill.ingest(frame); backfill.ingest(end)
        assertEquals(0,acks)
        assertEquals(setOf("strap_trim:${owner.deviceId}"),cursors.keys)
        db.openHelper.readableDatabase.query("SELECT deviceId,sessionId,framesBlob FROM bleRawBatch").use {
            assertTrue(it.moveToFirst())
            assertEquals(owner.deviceId,it.getString(0)); assertEquals(owner.sessionId,it.getString(1))
            assertArrayEquals(frame,BleRawCapture.decodeFrames(it.getBlob(2)).single())
            assertFalse(it.moveToNext())
        }
    }
}
