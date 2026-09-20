package com.noop.push

import android.app.Application
import android.database.sqlite.SQLiteDatabase
import androidx.room.withTransaction
import androidx.sqlite.db.SimpleSQLiteQuery
import com.noop.account.AccountStorageContext
import com.noop.account.AccountWriteFence
import com.noop.analytics.RouteMath
import com.noop.analytics.UserProfile
import com.noop.analytics.WorkoutSport
import com.noop.data.DataBackup
import com.noop.data.GpsWorkoutCommit
import com.noop.data.GpsWorkoutDeliveryStore
import com.noop.data.GpsDestinationDurabilityBarrier
import com.noop.data.HrSample
import com.noop.data.HrRow
import com.noop.data.StreamBatch
import com.noop.data.WhoopDatabase
import com.noop.data.WhoopRepository
import com.noop.data.requireDurableAccountCommit
import com.noop.location.AccountGpsJournal
import com.noop.location.AccountGpsSession
import com.noop.location.GpsWorkoutFinalizer
import com.noop.location.GpsWorkoutPayload
import com.noop.location.GpsWorkoutProjectionWitness
import com.noop.ui.AppViewModel
import com.noop.ui.ProfileStore
import java.io.IOException
import java.nio.ByteBuffer
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.SQLiteMode

internal class GpsDeliveryTestCrash : IOException("synthetic postcommit interruption")

internal class GpsDeliveryFixture : AutoCloseable {
    val storage = StorageMutationFixture()
    var account = storage.account()
        private set
    val gps = AccountGpsSession(account)
    val startMs = System.currentTimeMillis() - 3_600_000
    val device = "gps-projection-source"
    val samples = List(21) { HrSample(device, startMs / 1000 + it * 40, 140 + it % 7) }
    val inputs = GpsWorkoutFinalizer.Inputs(samples, UserProfile(weightKg = 75.0, age = 32.0, sex = "male"), 190.0, 55.0)
    val changed = GpsWorkoutFinalizer.Inputs(emptyList(), UserProfile(weightKg = 110.0, age = 60.0, sex = "female"), 160.0, 80.0)
    val db get() = WhoopDatabase.get(account)
    suspend fun start(): String {
        val id = gps.startDurable(startMs, "Walk", device).sessionId!!
        gps.appendDurable(RouteMath.LatLng(37.0, -122.0), id)
        gps.appendDurable(RouteMath.LatLng(37.001, -122.0), id)
        return id
    }
    fun payload(id: String, owner: AccountStorageContext = account) =
        AccountGpsJournal(owner, AccountWriteFence(owner)).use { checkNotNull(it.finalization(id)) }
    fun route() = AccountGpsJournal(account, AccountWriteFence(account)).use { it.read(true) }
    suspend fun committed(id: String, values: GpsWorkoutFinalizer.Inputs = inputs,
        notify: (GpsWorkoutCommit) -> Unit = {}): GpsWorkoutPayload {
        assertTrue(gpsRejects {
            GpsWorkoutFinalizer(account, gps, afterDestinationWrite = { throw GpsDeliveryTestCrash() }, onCommitted = notify)
                .finish(id, values)
        } is GpsDeliveryTestCrash)
        return payload(id)
    }
    fun blob(payload: GpsWorkoutPayload, column: String): ByteArray {
        require(column == "payload" || column == "witness")
        val key = arrayOf<Any>(payload.row.deviceId, payload.row.startTs, payload.row.sport)
        val where = "deviceId=? AND startTs=? AND sport=?"
        val sql = db.openHelper.readableDatabase
        val size = sql.query(SimpleSQLiteQuery("SELECT length($column) FROM gpsWorkoutDelivery WHERE $where", key)).use {
            check(it.moveToFirst()); it.getInt(0)
        }
        return ByteArray(size).also { bytes ->
            var offset = 0
            while (offset < size) {
                val count = minOf(65_536, size - offset)
                sql.query(SimpleSQLiteQuery("SELECT substr($column,?,?) FROM gpsWorkoutDelivery WHERE $where",
                    arrayOf<Any>(offset + 1, count, *key))).use {
                    check(it.moveToFirst()); val part = it.getBlob(0); check(part.size == count)
                    part.copyInto(bytes, offset)
                }
                offset += count
            }
        }
    }
    fun witness(payload: GpsWorkoutPayload) = GpsWorkoutProjectionWitness.decode(blob(payload, "witness"), payload)
    fun count(table: String): Long {
        require(table in listOf("workout", "hrSample", "gpsWorkoutDelivery"))
        return db.openHelper.readableDatabase.query("SELECT count(*) FROM $table").use { check(it.moveToFirst()); it.getLong(0) }
    }
    suspend fun canonical(payload: GpsWorkoutPayload): List<HrSample> = withContext(Dispatchers.IO) {
        payload.samples.map { it.ts }.distinct().chunked(512).flatMap { db.whoopDao().gpsWorkoutHrExact(device, it) }.sortedBy { it.ts }
    }
    suspend fun deliver(payload: GpsWorkoutPayload, limits: GpsWorkoutDeliveryStore.Limits = GpsWorkoutDeliveryStore.Limits()) =
        withContext(Dispatchers.IO) {
            db.withTransaction {
                requireDurableAccountCommit(db.openHelper.writableDatabase)
                GpsWorkoutDeliveryStore(account, db, limits).deliver(payload)
            }
        }
    suspend fun reopenRoom() {
        gps.retireAndJoin()
        WhoopDatabase.close()
        storage.controller.signIn("a", "synthetic")
        account = storage.account()
    }
    fun stagedWal(): java.io.File = storage.staged(account).also { backup ->
        SQLiteDatabase.openDatabase(backup.path, null, SQLiteDatabase.OPEN_READWRITE).use { sql ->
            check(sql.enableWriteAheadLogging())
            sql.rawQuery("PRAGMA journal_mode", null).use {
                check(it.moveToFirst() && it.getString(0).equals("wal", true))
            }
            sql.rawQuery("PRAGMA wal_checkpoint(TRUNCATE)", null).use {
                check(it.moveToFirst() && it.getInt(0) == 0)
            }
        }
    }
    override fun close() { runBlocking { gps.retireAndJoin() }; storage.close() }
}

internal suspend fun gpsRejects(body: suspend () -> Unit): Exception {
    try { body() } catch (expected: Exception) { return expected }
    throw AssertionError("GPS operation must retain its debt")
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
@SQLiteMode(SQLiteMode.Mode.NATIVE)
class W2GpsDeliveryNativeTest {
    @Test fun actualAppMedianAndCaptureKeepRaw150AndOrderedSmoothed140() = runBlocking {
        GpsDeliveryFixture().use { f ->
            val id = f.start()
            // Run the unchanged production median AND capture methods without constructing the app's
            // BLE/service graph. Only the fields read by these methods are installed on this fixture.
            val type = Class.forName("sun.misc.Unsafe")
            val unsafe = type.getDeclaredField("theUnsafe").apply { isAccessible = true }.get(null)
            val model = type.getMethod("allocateInstance", Class::class.java).invoke(unsafe, AppViewModel::class.java) as AppViewModel
            fun field(name: String, value: Any) = AppViewModel::class.java.getDeclaredField(name).apply { isAccessible = true }.set(model, value)
            val active = MutableStateFlow<AppViewModel.ActiveWorkout?>(null)
            field("appContext", f.account); field("profileStore", ProfileStore.from(f.account))
            field("deviceId", f.device); field("hrWindow", ArrayDeque<Int>())
            field("hrWindowSize", 5); field("_bpm", MutableStateFlow<Int?>(null)); field("_activeWorkout", active)
            val ingest = AppViewModel::class.java.getDeclaredMethod("ingestHr", Int::class.javaPrimitiveType).apply { isAccessible = true }
            repeat(4) { ingest.invoke(model, 140) }
            active.value = AppViewModel.ActiveWorkout(f.startMs, WorkoutSport.default, true, sourceDeviceId = f.device, gpsSessionId = id)
            ingest.invoke(model, 150)
            val captured = checkNotNull(active.value).samples.single()
            assertEquals(140, captured.bpm)
            val repository = WhoopRepository(f.db)
            assertEquals(1, repository.insert(StreamBatch(hr = listOf(HrRow(captured.ts, 150))), f.device).hr)
            val payload = f.committed(id, f.inputs.copy(samples = listOf(captured))) {
                assertEquals(0, it.insertedHr); assertFalse(repository.publishGpsHrCommit(it) { true })
            }
            assertEquals(1L, repository.sleepSampleRevision.value)
            assertEquals(listOf(captured), GpsWorkoutPayload.decode(f.blob(payload, "payload")).samples)
            assertEquals(listOf(captured.copy(bpm = 150)), f.canonical(payload))
            assertEquals(listOf(-1), f.witness(payload).entries.map { it.originOrdinal })
            assertEquals(payload.row, GpsWorkoutFinalizer(f.account, f.gps).finish(id, f.changed))
            assertNull(f.route()); assertEquals(1L, f.count("gpsWorkoutDelivery"))
        }
    }

    @Test fun gpsFirstUnequalSameSecondKeepsAllCapturesAndOnlyFirstCanonical() = runBlocking {
        GpsDeliveryFixture().use { f ->
            val id = f.start(); val first = f.samples.first()
            val values = listOf(first, first.copy(bpm = 150), f.samples[1], first.copy(bpm = 160))
            val payload = f.committed(id, f.inputs.copy(samples = values)) { assertEquals(2, it.insertedHr) }
            assertEquals(values, GpsWorkoutPayload.decode(f.blob(payload, "payload")).samples)
            assertEquals(listOf(first, f.samples[1]), f.canonical(payload))
            assertEquals(listOf(0, 2), f.witness(payload).entries.map { it.originOrdinal })
            assertEquals(listOf(-1L), f.db.whoopDao().insertHr(listOf(first.copy(bpm = 175))))
            val witness = f.blob(payload, "witness")
            GpsWorkoutFinalizer(f.account, f.gps).finish(id, f.changed)
            assertArrayEquals(witness, f.blob(payload, "witness")); assertNull(f.route())
        }
    }

    @Test fun outOfOrderCapturesUseSortedWitnessWithFirstOriginalOrdinalsAndFullSyncedValues() = runBlocking {
        GpsDeliveryFixture().use { f ->
            val id = f.start()
            val a = f.samples[0].copy(synced = 7); val b = f.samples[1].copy(synced = 3)
            val payload = f.committed(id, f.inputs.copy(samples = listOf(b, a, b.copy(bpm = 180))))
            assertEquals(listOf(a, b), f.canonical(payload))
            assertEquals(listOf(1, 0), f.witness(payload).entries.map { it.originOrdinal })
            assertEquals(listOf(b, a, b.copy(bpm = 180)), GpsWorkoutPayload.decode(f.blob(payload, "payload")).samples)
        }
    }

    @Test fun workoutHrAndArtifactWriteFailuresRollbackEverythingAndPublishNothing() = runBlocking {
        GpsDeliveryFixture().use { f ->
            val id = f.start(); val repository = WhoopRepository(f.db)
            var notifications = 0
            for (table in listOf("workout", "hrSample", "gpsWorkoutDelivery")) {
                f.db.openHelper.writableDatabase.execSQL("CREATE TRIGGER gps_fault BEFORE INSERT ON $table BEGIN SELECT RAISE(ABORT,'synthetic'); END")
                gpsRejects { GpsWorkoutFinalizer(f.account, f.gps, onCommitted = {
                    notifications++; repository.publishGpsHrCommit(it) { true }
                }).finish(id, f.inputs) }
                assertEquals(0L, f.count("workout")); assertEquals(0L, f.count("hrSample")); assertEquals(0L, f.count("gpsWorkoutDelivery"))
                assertEquals(0, notifications); assertEquals(0L, repository.sleepSampleRevision.value)
                assertEquals(id, f.route()!!.id)
                f.db.openHelper.writableDatabase.execSQL("DROP TRIGGER gps_fault")
            }
            GpsWorkoutFinalizer(f.account, f.gps).finish(id, f.changed)
            assertNull(f.route()); assertEquals(1L, f.count("gpsWorkoutDelivery"))
        }
    }

    @Test fun postcommitFailurePublishesPositiveCountOnceButRetryNoopNeverBumps() = runBlocking {
        GpsDeliveryFixture().use { f ->
            val id = f.start(); val repository = WhoopRepository(f.db)
            val counts = mutableListOf<Int>()
            val notify: (GpsWorkoutCommit) -> Unit = {
                counts += it.insertedHr
                assertEquals(it.insertedHr > 0, repository.publishGpsHrCommit(it) { true })
                assertFalse(repository.publishGpsHrCommit(it) { true })
            }
            val payload = f.committed(id, notify = notify)
            assertEquals(listOf(f.samples.size), counts); assertEquals(1L, repository.sleepSampleRevision.value)
            assertEquals(payload.row, GpsWorkoutFinalizer(f.account, f.gps, onCommitted = notify).finish(id, f.changed))
            assertEquals(listOf(f.samples.size, 0), counts); assertEquals(1L, repository.sleepSampleRevision.value)
            assertEquals(0L, repository.batteryRevision.value)
        }
    }

    @Test fun cancellationFromCommitCallbackCannotSkipCapturedRepositoryPublication() = runBlocking {
        GpsDeliveryFixture().use { f ->
            val id = f.start(); val repository = WhoopRepository(f.db)
            val finishing = async(Dispatchers.IO) {
                val caller = checkNotNull(currentCoroutineContext()[Job])
                GpsWorkoutFinalizer(f.account, f.gps, onCommitted = {
                    caller.cancel(); assertTrue(repository.publishGpsHrCommit(it) { true })
                }).finish(id, f.inputs)
            }
            assertTrue(gpsRejects { finishing.await() } is kotlinx.coroutines.CancellationException)
            assertEquals(1L, repository.sleepSampleRevision.value)
            assertEquals(id, f.route()!!.id)
            GpsWorkoutFinalizer(f.account, f.gps, onCommitted = {
                assertEquals(0, it.insertedHr); assertFalse(repository.publishGpsHrCommit(it) { true })
            }).finish(id, f.changed)
            assertEquals(1L, repository.sleepSampleRevision.value)
        }
    }

    @Test fun capturedRepositoryRejectsRetiredRuntimeGenerationAndReplacementDatabase() = runBlocking {
        GpsDeliveryFixture().use { f ->
            val id = f.start(); val originalDb = f.db; val original = WhoopRepository(originalDb)
            var held: GpsWorkoutCommit? = null
            val payload = f.committed(id, notify = { held = it })
            val receipt = checkNotNull(held)
            assertFalse(original.publishGpsHrCommit(receipt) { false })
            withContext(Dispatchers.IO) {
                val backup = f.storage.staged(f.account)
                assertEquals(DataBackup.ImportResult.NeedsRestart,
                    DataBackup.installStagedBackup(f.account, backup, f.storage.emptySettings(f.account)))
            }
            val replacement = WhoopRepository(f.db)
            assertFalse(original.publishGpsHrCommit(receipt) { true })
            assertFalse(replacement.publishGpsHrCommit(receipt) { true })
            f.storage.controller.signIn("a", "synthetic")
            val next = f.storage.account(); val current = WhoopRepository(WhoopDatabase.get(next))
            assertFalse(current.publishGpsHrCommit(receipt) { true })
            assertEquals(0L, original.sleepSampleRevision.value); assertEquals(0L, replacement.sleepSampleRevision.value)
            assertEquals(0L, current.sleepSampleRevision.value)
            assertArrayEquals(payload.encode(), f.payload(id, next).encode())
        }
    }

    @Test fun sameArtifactMissingCanonicalRowsRetryUsesWitnessNotOriginalCaptures() = runBlocking {
        GpsDeliveryFixture().use { f ->
            val id = f.start(); val raw = f.samples.first().copy(bpm = 81, synced = 6)
            f.db.whoopDao().insertHr(listOf(raw))
            val payload = f.committed(id); val witness = f.blob(payload, "witness")
            f.db.openHelper.writableDatabase.execSQL("DELETE FROM hrSample WHERE deviceId=? AND ts=?", arrayOf(raw.deviceId, raw.ts))
            gpsRejects { withContext(Dispatchers.IO) { GpsWorkoutFinalizer.settleCurrent(f.account, payload) { fail("incomplete witness must not delete") } } }
            val repository = WhoopRepository(f.db)
            GpsWorkoutFinalizer(f.account, f.gps, onCommitted = {
                assertEquals(1, it.insertedHr); assertTrue(repository.publishGpsHrCommit(it) { true })
            }).finish(id, f.changed)
            assertEquals(raw, f.canonical(payload).first()); assertArrayEquals(witness, f.blob(payload, "witness"))
            assertEquals(1L, repository.sleepSampleRevision.value); assertNull(f.route())
        }
    }

    @Test fun changedCanonicalSyncedValueFailsProofAndRetryWithoutOverwrite() = runBlocking {
        GpsDeliveryFixture().use { f ->
            val id = f.start(); val payload = f.committed(id); val witness = f.blob(payload, "witness")
            f.db.openHelper.writableDatabase.execSQL("UPDATE hrSample SET synced=7 WHERE deviceId=?", arrayOf(f.device))
            gpsRejects { GpsWorkoutFinalizer(f.account, f.gps).finish(id, f.changed) }
            assertTrue(f.canonical(payload).all { it.synced == 7 })
            assertArrayEquals(witness, f.blob(payload, "witness")); assertEquals(id, f.route()!!.id)
        }
    }

    @Test fun actualRestoreWithoutArtifactRequiresExplicitRetryAndNewProjectionWitness() = runBlocking {
        GpsDeliveryFixture().use { f ->
            val id = f.start(); var oldWitness: ByteArray? = null
            gpsRejects { GpsWorkoutFinalizer(f.account, f.gps, afterDestinationWrite = { payload ->
                oldWitness = f.blob(payload, "witness")
                withContext(Dispatchers.IO) {
                    val backup = f.storage.staged(f.account)
                    SQLiteDatabase.openDatabase(backup.path, null, SQLiteDatabase.OPEN_READWRITE).use {
                        it.execSQL("DELETE FROM gpsWorkoutDelivery")
                        it.execSQL("UPDATE hrSample SET bpm=81 WHERE deviceId=?", arrayOf(f.device))
                    }
                    assertEquals(DataBackup.ImportResult.NeedsRestart, DataBackup.installStagedBackup(f.account, backup, f.storage.emptySettings(f.account)))
                }
            }).finish(id, f.inputs) }
            val payload = f.payload(id); assertEquals(0L, f.count("gpsWorkoutDelivery")); assertEquals(id, f.route()!!.id)
            GpsWorkoutFinalizer(f.account, f.gps).finish(id, f.changed)
            assertArrayEquals(payload.encode(), f.blob(payload, "payload"))
            assertFalse(checkNotNull(oldWitness).contentEquals(f.blob(payload, "witness")))
            assertTrue(f.witness(payload).entries.all { it.originOrdinal == -1 && it.row.bpm == 81 })
            assertEquals(payload.row.avgHr, GpsWorkoutPayload.decode(f.blob(payload, "payload")).row.avgHr)
            assertNull(f.route())
        }
    }

    @Test fun actualRestoreWithIntactArtifactAndRowsPreservesOriginalWitness() = runBlocking {
        GpsDeliveryFixture().use { f ->
            val id = f.start(); var retained: GpsWorkoutPayload? = null; var witness: ByteArray? = null
            val stages = mutableListOf<GpsDestinationDurabilityBarrier.Step>()
            GpsWorkoutFinalizer(f.account, f.gps, afterDestinationWrite = { payload ->
                retained = payload; witness = f.blob(payload, "witness")
                withContext(Dispatchers.IO) {
                    val backup = f.stagedWal()
                    assertEquals(DataBackup.ImportResult.NeedsRestart, DataBackup.installStagedBackup(f.account, backup, f.storage.emptySettings(f.account)))
                }
            }, destinationBarrier = GpsDestinationDurabilityBarrier(afterStep = { stages += it }),
                beforeGpsDelete = {
                    assertEquals(GpsDestinationDurabilityBarrier.Step.values().toList(), stages)
                    assertTrue(f.db.openHelper.writableDatabase.inTransaction())
                    assertEquals(id, f.route()!!.id)
                }).finish(id, f.inputs)
            assertArrayEquals(checkNotNull(witness), f.blob(checkNotNull(retained), "witness")); assertNull(f.route())
        }
    }

    @Test fun retainedArtifactSurvivesManualWorkoutDeletionAndPreventsAnotherSessionTakingItsKey() = runBlocking {
        GpsDeliveryFixture().use { f ->
            val id = f.start(); val payload = f.committed(id); val bytes = f.blob(payload, "payload")
            GpsWorkoutFinalizer(f.account, f.gps).finish(id, f.changed)
            f.db.openHelper.writableDatabase.execSQL("DELETE FROM workout")
            assertArrayEquals(bytes, f.blob(payload, "payload")); assertEquals(1L, f.count("gpsWorkoutDelivery"))
            val different = GpsWorkoutPayload.capture(f.account, java.util.UUID.randomUUID().toString(), payload.row, payload.samples)
            gpsRejects { f.deliver(different) }
            assertEquals(0L, f.count("workout")); assertArrayEquals(bytes, f.blob(payload, "payload"))
        }
    }

    @Test fun countAndByteCapsAdmitExactBoundaryRejectNewWorkAndPermitMatchingRetry() = runBlocking {
        GpsDeliveryFixture().use { f ->
            val id = f.start()
            val tiny = GpsWorkoutDeliveryStore.Limits(artifacts = 1, bytes = 1)
            gpsRejects { GpsWorkoutFinalizer(f.account, f.gps, deliveryLimits = tiny).finish(id, f.inputs) }
            val payload = f.payload(id)
            assertEquals(0L, f.count("workout")); assertEquals(0L, f.count("hrSample")); assertEquals(id, f.route()!!.id)
            val exact = payload.encode().size + 12L + 20L * payload.samples.map { it.ts }.distinct().size + GpsWorkoutDeliveryStore.METADATA_BYTES
            val limits = GpsWorkoutDeliveryStore.Limits(1, exact)
            assertEquals(payload.samples.size, f.deliver(payload, limits))
            assertEquals(0, f.deliver(payload, limits))
            val second = GpsWorkoutPayload.capture(f.account, "another-session", payload.row.copy(startTs = payload.row.startTs - 1), payload.samples)
            gpsRejects { f.deliver(second, GpsWorkoutDeliveryStore.Limits(1)) }
            gpsRejects { f.deliver(second, GpsWorkoutDeliveryStore.Limits(2, exact)) }
            assertEquals(1L, f.count("workout")); assertEquals(1L, f.count("gpsWorkoutDelivery"))
            GpsWorkoutFinalizer(f.account, f.gps, deliveryLimits = limits).finish(id, f.changed)
            assertNull(f.route())
        }
    }

    @Test fun malformedWitnessWithRecomputedHashStillCannotSettleOrRewriteIntent() = runBlocking {
        GpsDeliveryFixture().use { f ->
            val id = f.start(); val payload = f.committed(id)
            val original = f.blob(payload, "witness")
            for (mutate in listOf<(ByteBuffer) -> Unit>(
                { it.putInt(4, 2) }, // unknown version
                { it.putInt(28, -2) }, // invalid origin
                { it.putInt(28, 1) }, // not the first capture at this key
                { it.putLong(32, payload.samples.first().ts) }, // duplicate timestamp
                { it.putInt(24, 9) }, // inserted origin full-HR mismatch
            )) {
                val altered = original.copyOf().also { mutate(ByteBuffer.wrap(it)) }
                f.db.openHelper.writableDatabase.execSQL("UPDATE gpsWorkoutDelivery SET witness=?,witnessSha256=?",
                    arrayOf(altered, GpsWorkoutDeliveryStore.sha256(altered)))
                gpsRejects { GpsWorkoutFinalizer(f.account, f.gps).finish(id, f.changed) }
                assertArrayEquals(altered, f.blob(payload, "witness")); assertEquals(id, f.route()!!.id)
                assertArrayEquals(payload.encode(), f.blob(payload, "payload"))
            }
        }
    }

    @Test fun revokedGenerationAtNativeDestinationCommitRollsBackArtifactWorkoutAndHr() = runBlocking {
        GpsDeliveryFixture().use { f ->
            val id = f.start()
            gpsRejects { GpsWorkoutFinalizer(f.account, f.gps,
                deliveryLimits = GpsWorkoutDeliveryStore.Limits(bytes = 1)).finish(id, f.inputs) }
            val payload = f.payload(id); val database = f.db
            gpsRejects {
                withContext(Dispatchers.IO) {
                    database.withTransaction {
                        requireDurableAccountCommit(database.openHelper.writableDatabase)
                        assertEquals(payload.samples.size, GpsWorkoutDeliveryStore(f.account, database).deliver(payload))
                        f.storage.controller.clearSession()
                    }
                }
            }
            database.openHelper.readableDatabase.query("SELECT (SELECT count(*) FROM workout),(SELECT count(*) FROM hrSample),(SELECT count(*) FROM gpsWorkoutDelivery)").use {
                assertTrue(it.moveToFirst()); repeat(3) { index -> assertEquals(0, it.getInt(index)) }
            }
            f.storage.controller.signIn("a", "synthetic")
            assertArrayEquals(payload.encode(), f.payload(id, f.storage.account()).encode())
        }
    }

    @Test fun changedArtifactOwnerGenerationSessionAndCountsNeverAuthorizeCleanup() = runBlocking {
        GpsDeliveryFixture().use { f ->
            val id = f.start(); val payload = f.committed(id)
            val alterations = listOf(
                Triple("namespace", "unrelated", payload.namespace),
                Triple("capturedGeneration", java.util.UUID.randomUUID().toString(), payload.capturedGeneration),
                Triple("sessionId", "unrelated-session", payload.sessionId),
                Triple("captureCount", -1, payload.samples.size),
                Triple("formatVersion", 2, 1),
                Triple("payloadSha256", "0".repeat(64), GpsWorkoutDeliveryStore.sha256(payload.encode())),
            )
            for ((column, bad, original) in alterations) {
                f.db.openHelper.writableDatabase.execSQL("UPDATE gpsWorkoutDelivery SET $column=?", arrayOf(bad))
                gpsRejects { GpsWorkoutFinalizer(f.account, f.gps).finish(id, f.changed) }
                assertEquals(id, f.route()!!.id)
                f.db.openHelper.writableDatabase.execSQL("UPDATE gpsWorkoutDelivery SET $column=?", arrayOf(original))
            }
            GpsWorkoutFinalizer(f.account, f.gps).finish(id, f.changed)
            assertNull(f.route())
        }
    }

    @Test fun nativeBlobChunkingPreservesLargeArtifactAcrossCloseAndReopen() = runBlocking {
        GpsDeliveryFixture().use { f ->
            val id = f.start(); val initial = f.committed(id)
            // A separate workout key permits a bounded large artifact without replacing the first.
            val samples = List(1_030) { HrSample(f.device, f.startMs / 1000 + it, 140 + it % 20) }
            val large = GpsWorkoutPayload.capture(f.account, "large-artifact", initial.row.copy(startTs = initial.row.startTs - 1,
                notes = "x".repeat(2 * 1024 * 1024 + 17)), samples)
            f.deliver(large)
            val bytes = large.encode(); val witness = f.blob(large, "witness")
            assertTrue(bytes.size > 2 * 1024 * 1024)
            f.reopenRoom()
            assertEquals(0, f.deliver(large))
            assertArrayEquals(bytes, f.blob(large, "payload")); assertArrayEquals(witness, f.blob(large, "witness"))
            assertEquals(1_030, f.witness(large).entries.size)
        }
    }
}
