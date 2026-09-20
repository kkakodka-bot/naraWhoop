package com.noop.push

import android.app.Application
import android.database.sqlite.SQLiteDatabase
import com.noop.account.AccountStorageContext
import com.noop.account.AccountWriteFence
import com.noop.analytics.RouteMath
import com.noop.analytics.UserProfile
import com.noop.data.DataBackup
import com.noop.data.HrSample
import com.noop.data.WhoopDatabase
import com.noop.data.WorkoutRow
import com.noop.location.AccountGpsJournal
import com.noop.location.AccountGpsSession
import com.noop.location.GpsWorkoutFinalizer
import com.noop.location.GpsWorkoutPayload
import com.noop.location.GpsWorkoutProjectionWitness
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class W2GpsFinalizationNativeTest {
    private class Crash : IOException("synthetic interruption after destination commit")
    private class Fixture : AutoCloseable {
        val storage = StorageMutationFixture()
        val account = storage.account()
        private val sessions = mutableListOf<AccountGpsSession>()
        val gps = session()
        val startMs = System.currentTimeMillis() - 3_600_000
        val samples = List(21) { HrSample("gps-original-device", startMs / 1000 + it * 40, 150 + it % 7) }
        val inputs = GpsWorkoutFinalizer.Inputs(samples, UserProfile(weightKg = 75.0, age = 32.0, sex = "male"), 190.0, 55.0)
        val changed = GpsWorkoutFinalizer.Inputs(emptyList(), UserProfile(weightKg = 110.0, age = 60.0, sex = "female"), 160.0, 80.0)
        fun session(owner: AccountStorageContext = account) = AccountGpsSession(owner).also { sessions += it }
        suspend fun start(points: Int = 2): String {
            val id = gps.startDurable(startMs, "Walk", "gps-original-device").sessionId!!
            repeat(points) { gps.appendDurable(RouteMath.LatLng(37.0 + it * 0.001, -122.0), id) }
            return id
        }
        fun payload(id: String, owner: AccountStorageContext = account): GpsWorkoutPayload =
            AccountGpsJournal(owner, AccountWriteFence(owner)).use { checkNotNull(it.finalization(id)) }
        fun route(owner: AccountStorageContext = account) = AccountGpsJournal(owner, AccountWriteFence(owner)).use { it.read(true) }
        suspend fun row(expected: WorkoutRow, owner: AccountStorageContext = account): WorkoutRow? = withContext(Dispatchers.IO) {
            WhoopDatabase.get(owner).whoopDao().gpsWorkoutExact(expected.deviceId, expected.startTs, expected.sport)
        }
        suspend fun assertDestination(payload: GpsWorkoutPayload, owner: AccountStorageContext = account) = withContext(Dispatchers.IO) {
            val dao = WhoopDatabase.get(owner).whoopDao()
            assertEquals(payload.row, dao.gpsWorkoutExact(payload.row.deviceId, payload.row.startTs, payload.row.sport))
            assertEquals(payload.samples.sortedBy { it.ts }, dao.gpsWorkoutHrExact(payload.row.deviceId, payload.samples.map { it.ts }).sortedBy { it.ts })
        }
        suspend fun reopen(): Pair<AccountStorageContext, AccountGpsSession> {
            gps.retireAndJoin()
            WhoopDatabase.close()
            storage.controller.signIn("a", "synthetic")
            val owner = storage.account()
            return owner to session(owner).also { it.recoverDurable() }
        }
        override fun close() {
            runBlocking { sessions.forEach { it.retireAndJoin() } }
            storage.close()
        }
    }

    private suspend fun rejects(body: suspend () -> Unit): Exception {
        try { body() } catch (expected: Exception) { return expected }
        throw AssertionError("operation should retain GPS debt")
    }

    @Test fun crashAfterCommitReopenReusesExactNonNullHrScoresAndCapturedProfile() = runBlocking {
        Fixture().use { f ->
            val id = f.start()
            assertTrue(rejects { GpsWorkoutFinalizer(f.account, f.gps, afterDestinationWrite = { throw Crash() }).finish(id, f.inputs) } is Crash)
            val frozen = f.payload(id)
            assertNotNull(frozen.row.avgHr); assertNotNull(frozen.row.maxHr)
            assertNotNull(frozen.row.strain); assertTrue(frozen.row.energyKcal!! > 0)
            f.assertDestination(frozen)
            val bytes = frozen.encode()
            val (owner, recovered) = f.reopen()
            assertEquals(id, recovered.state.value.sessionId)
            assertArrayEquals(bytes, f.payload(id, owner).encode())
            assertEquals(frozen.row, GpsWorkoutFinalizer(owner, recovered).finish(id, f.changed))
            f.assertDestination(frozen, owner)
            assertNull(f.route(owner))
        }
    }

    @Test fun freezeSucceedsDestinationFailsThenReopenRetriesTheOriginalPayload() = runBlocking {
        Fixture().use { f ->
            val id = f.start()
            val db = WhoopDatabase.get(f.account)
            db.openHelper.writableDatabase.execSQL("CREATE TRIGGER gps_test_failure BEFORE INSERT ON workout BEGIN SELECT RAISE(ABORT,'synthetic'); END")
            rejects { GpsWorkoutFinalizer(f.account, f.gps).finish(id, f.inputs) }
            val frozen = f.payload(id)
            assertNull(f.row(frozen.row)); assertEquals(2, f.route()!!.pointCount)
            val (owner, recovered) = f.reopen()
            WhoopDatabase.get(owner).openHelper.writableDatabase.execSQL("DROP TRIGGER gps_test_failure")
            assertArrayEquals(frozen.encode(), f.payload(id, owner).encode())
            assertEquals(frozen.row, GpsWorkoutFinalizer(owner, recovered).finish(id, f.changed))
            f.assertDestination(frozen, owner); assertNull(f.route(owner))
        }
    }

    @Test fun actualRestoreAfterSaveBeforeSettlementKeepsDebtAndExplicitRetryUsesCurrentDatabase() = runBlocking {
        Fixture().use { f ->
            val backup = f.storage.staged(f.account)
            val id = f.start()
            rejects { GpsWorkoutFinalizer(f.account, f.gps, afterDestinationWrite = {
                withContext(Dispatchers.IO) {
                    assertEquals(DataBackup.ImportResult.NeedsRestart,
                        DataBackup.installStagedBackup(f.account, backup, f.storage.emptySettings(f.account)))
                }
            }).finish(id, f.inputs) }
            val frozen = f.payload(id)
            assertNull(f.row(frozen.row)); assertEquals(2, f.route()!!.pointCount)
            assertEquals(frozen.row, GpsWorkoutFinalizer(f.account, f.gps).finish(id, f.changed))
            f.assertDestination(frozen); assertNull(f.route())
        }
    }

    @Test fun restoredExactWorkoutWithMissingHrCannotSettleGps() = restoreWithChangedHr(drop = true)
    @Test fun restoredExactWorkoutWithConflictingHrCannotSettleGps() = restoreWithChangedHr(drop = false)

    private fun restoreWithChangedHr(drop: Boolean) = runBlocking {
        Fixture().use { f ->
            val id = f.start()
            var saved: GpsWorkoutPayload? = null
            rejects { GpsWorkoutFinalizer(f.account, f.gps, afterDestinationWrite = { payload ->
                saved = payload
                withContext(Dispatchers.IO) {
                    val backup = f.storage.staged(f.account)
                    SQLiteDatabase.openDatabase(backup.path, null, SQLiteDatabase.OPEN_READWRITE).use { db ->
                        if (drop) db.execSQL("DELETE FROM hrSample WHERE deviceId=?", arrayOf(payload.row.deviceId))
                        else db.execSQL("UPDATE hrSample SET bpm=bpm+1 WHERE deviceId=?", arrayOf(payload.row.deviceId))
                    }
                    assertEquals(DataBackup.ImportResult.NeedsRestart,
                        DataBackup.installStagedBackup(f.account, backup, f.storage.emptySettings(f.account)))
                }
            }).finish(id, f.inputs) }
            val frozen = checkNotNull(saved)
            assertEquals(frozen.row, f.row(frozen.row))
            assertArrayEquals(frozen.encode(), f.payload(id).encode())
            assertEquals(id, f.route()!!.id)
            if (!drop) {
                rejects { GpsWorkoutFinalizer(f.account, f.gps).finish(id, f.changed) }
                assertArrayEquals(frozen.encode(), f.payload(id).encode())
            } else {
                val witness = WhoopDatabase.get(f.account).openHelper.readableDatabase.query("SELECT witness FROM gpsWorkoutDelivery").use {
                    check(it.moveToFirst()); it.getBlob(0)
                }
                GpsWorkoutFinalizer(f.account, f.gps).finish(id, f.changed)
                f.assertDestination(frozen); assertNull(f.route())
                WhoopDatabase.get(f.account).openHelper.readableDatabase.query("SELECT witness FROM gpsWorkoutDelivery").use {
                    assertTrue(it.moveToFirst()); assertArrayEquals(witness, it.getBlob(0))
                }
            }
        }
    }

    @Test fun failedActualRestorePreservesDestinationAndPermitsSettlement() = runBlocking {
        Fixture().use { f ->
            val backup = f.storage.staged(f.account)
            val id = f.start()
            var frozen: GpsWorkoutPayload? = null
            val row = GpsWorkoutFinalizer(f.account, f.gps, afterDestinationWrite = { payload ->
                frozen = payload
                withContext(Dispatchers.IO) {
                    assertTrue(DataBackup.installStagedBackup(f.account, backup, f.storage.emptySettings(f.account)) {
                        check(backup.delete()) // Force the real copy/rollback path after quiescence.
                    } is DataBackup.ImportResult.Failed)
                }
            }).finish(id, f.inputs)
            assertEquals(checkNotNull(frozen).row, row); f.assertDestination(checkNotNull(frozen))
            assertNull(f.route())
        }
    }

    @Test fun ownerReplacementAfterSaveCannotDeleteOriginalOwnersGps() = replacementAfterSave("b")
    @Test fun sameOwnerNewGenerationAfterSaveCannotDeleteOldSessionsGps() = replacementAfterSave("a")

    @Test fun explicitGpsRetirementAfterSaveRetainsPayloadUntilNewSession() = runBlocking {
        Fixture().use { f ->
            val id = f.start()
            rejects { GpsWorkoutFinalizer(f.account, f.gps, afterDestinationWrite = {
                f.gps.retireAndJoin()
            }).finish(id, f.inputs) }
            val frozen = f.payload(id)
            val next = f.session()
            assertEquals(id, next.recoverDurable().sessionId)
            assertEquals(frozen.row, GpsWorkoutFinalizer(f.account, next).finish(id, f.changed))
            f.assertDestination(frozen); assertNull(f.route())
        }
    }

    private fun replacementAfterSave(next: String) = runBlocking {
        Fixture().use { f ->
            val id = f.start()
            var frozen: GpsWorkoutPayload? = null
            rejects { GpsWorkoutFinalizer(f.account, f.gps, afterDestinationWrite = { payload ->
                frozen = payload; f.storage.controller.signIn(next, "synthetic")
            }).finish(id, f.inputs) }
            f.gps.retireAndJoin()
            if (next == "b") {
                val b = f.storage.account()
                assertNull(f.session(b).recoverDurable().sessionId)
                f.storage.controller.signIn("a", "synthetic")
            }
            val owner = f.storage.account()
            val recovered = f.session(owner)
            assertEquals(id, recovered.recoverDurable().sessionId)
            assertArrayEquals(checkNotNull(frozen).encode(), f.payload(id, owner).encode())
            assertEquals(checkNotNull(frozen).row, GpsWorkoutFinalizer(owner, recovered).finish(id, f.changed))
            f.assertDestination(checkNotNull(frozen), owner); assertNull(f.route(owner))
        }
    }

    @Test fun editedDestinationIsNeverOverwrittenByFrozenRetry() = runBlocking {
        Fixture().use { f ->
            val id = f.start()
            var edited: WorkoutRow? = null
            rejects { GpsWorkoutFinalizer(f.account, f.gps, afterDestinationWrite = { payload ->
                edited = payload.row.copy(notes = "intentional later edit", energyKcal = 901.25)
                WhoopDatabase.get(f.account).whoopDao().upsertWorkouts(listOf(checkNotNull(edited)))
            }).finish(id, f.inputs) }
            val frozen = f.payload(id)
            rejects { GpsWorkoutFinalizer(f.account, f.gps).finish(id, f.changed) }
            assertEquals(edited, f.row(frozen.row)); assertArrayEquals(frozen.encode(), f.payload(id).encode())
        }
    }

    @Test fun legacyFinishedWithoutPayloadRefusesToOverwriteExistingNonNullMetrics() = runBlocking {
        Fixture().use { f ->
            val id = f.start()
            val ended = f.gps.finishDurable()
            val original = WorkoutRow(ended.deviceId, ended.startMs / 1000, ended.endMs!! / 1000, ended.sport, "manual",
                durationS = 3600.0, energyKcal = 254.75, avgHr = 145, maxHr = 172, strain = 38.0,
                routePolyline = RouteMath.encode(ended.track), distanceM = ended.distanceM)
            WhoopDatabase.get(f.account).whoopDao().upsertWorkouts(listOf(original))
            rejects { GpsWorkoutFinalizer(f.account, f.gps).finish(id, f.changed) }
            assertEquals(original, f.row(original)); assertEquals(id, f.route()!!.id)
        }
    }

    @Test fun conflictingHrInsertIgnoreRetainsCaptureAndProvesItsDistinctCanonicalProjection() = runBlocking {
        Fixture().use { f ->
            val id = f.start()
            val other = f.samples.first().copy(bpm = 81)
            WhoopDatabase.get(f.account).whoopDao().insertHr(listOf(other))
            var frozen: GpsWorkoutPayload? = null
            val row = GpsWorkoutFinalizer(f.account, f.gps, afterDestinationWrite = { frozen = it }).finish(id, f.inputs)
            assertEquals(checkNotNull(frozen).row, row)
            withContext(Dispatchers.IO) {
                val db = WhoopDatabase.get(f.account)
                assertEquals(listOf(other), db.whoopDao().gpsWorkoutHrExact(other.deviceId, listOf(other.ts)))
                db.openHelper.readableDatabase.query("SELECT payload,witness FROM gpsWorkoutDelivery").use {
                    assertTrue(it.moveToFirst())
                    val retained = GpsWorkoutPayload.decode(it.getBlob(0))
                    assertEquals(f.samples, retained.samples)
                    assertArrayEquals(checkNotNull(frozen).encode(), retained.encode())
                    val witness = GpsWorkoutProjectionWitness.decode(it.getBlob(1), retained)
                    assertEquals(other, witness.entries.first().row)
                    assertEquals(-1, witness.entries.first().originOrdinal)
                }
            }
            assertNull(f.route())
        }
    }

    @Test fun proofThroughGpsDeleteExcludesConcurrentOrdinaryWorkoutEdit() = runBlocking {
        Fixture().use { f ->
            val id = f.start()
            val database = WhoopDatabase.get(f.account).also { it.openHelper.writableDatabase }
            val proof = CountDownLatch(1); val release = CountDownLatch(1)
            val editStarted = CountDownLatch(1); val editDone = CountDownLatch(1)
            val executor = Executors.newSingleThreadExecutor()
            val finishing = async(Dispatchers.IO) {
                GpsWorkoutFinalizer(f.account, f.gps, beforeGpsDelete = {
                    proof.countDown(); check(release.await(10, TimeUnit.SECONDS))
                }).finish(id, f.inputs)
            }
            try {
                assertTrue(proof.await(10, TimeUnit.SECONDS))
                val frozen = f.payload(id)
                val edited = frozen.row.copy(notes = "edit after settlement")
                val writer = executor.submit {
                    editStarted.countDown()
                    // Already-open handle: this writer does not acquire the namespace/opening lock.
                    runBlocking { database.whoopDao().upsertWorkouts(listOf(edited)) }
                    editDone.countDown()
                }
                assertTrue(editStarted.await(10, TimeUnit.SECONDS))
                assertFalse("ordinary edit must wait for proof and deletion", editDone.await(150, TimeUnit.MILLISECONDS))
                release.countDown(); assertEquals(frozen.row, finishing.await())
                writer.get(10, TimeUnit.SECONDS)
                assertNull(f.route()); assertEquals(edited, f.row(edited))
            } finally {
                release.countDown(); finishing.join()
                executor.shutdownNow(); assertTrue(executor.awaitTermination(10, TimeUnit.SECONDS))
            }
        }
    }

    @Test fun finalizationWinningNamespaceLeaseSettlesBeforeActualRestore() = runBlocking {
        Fixture().use { f ->
            val backup = f.storage.staged(f.account)
            val settings = f.storage.emptySettings(f.account)
            val id = f.start()
            val proof = CountDownLatch(1); val release = CountDownLatch(1)
            val restoring = CountDownLatch(1); val restored = CountDownLatch(1)
            val executor = Executors.newSingleThreadExecutor()
            val finishing = async(Dispatchers.IO) {
                GpsWorkoutFinalizer(f.account, f.gps, beforeGpsDelete = {
                    proof.countDown(); check(release.await(10, TimeUnit.SECONDS))
                }).finish(id, f.inputs)
            }
            try {
                assertTrue(proof.await(10, TimeUnit.SECONDS))
                val restore = executor.submit<DataBackup.ImportResult> {
                    restoring.countDown()
                    DataBackup.installStagedBackup(f.account, backup, settings).also { restored.countDown() }
                }
                assertTrue(restoring.await(10, TimeUnit.SECONDS))
                assertFalse(restored.await(150, TimeUnit.MILLISECONDS))
                release.countDown(); finishing.await()
                assertEquals(DataBackup.ImportResult.NeedsRestart, restore.get(10, TimeUnit.SECONDS))
                assertNull(f.route())
            } finally {
                release.countDown(); finishing.join()
                executor.shutdownNow(); assertTrue(executor.awaitTermination(10, TimeUnit.SECONDS))
            }
        }
    }

    @Test fun noDataAndOverCapacityHrRetainAnUnfinishedRoute() = runBlocking {
        Fixture().use { f ->
            val id = f.start(points = 1)
            rejects { GpsWorkoutFinalizer(f.account, f.gps).finish(id, f.changed) }
            assertNull(f.route()!!.endMs)
            val tooMany = f.inputs.copy(samples = List(GpsWorkoutPayload.MAX_HR_SAMPLES + 1) { f.samples.first() })
            rejects { GpsWorkoutFinalizer(f.account, f.gps).finish(id, tooMany) }
            assertNull(f.route()!!.endMs); assertEquals(1, f.route()!!.pointCount)
        }
    }

    @Test fun payloadByteCapDoesNotEvictRouteOrPriorIntent() = runBlocking {
        Fixture().use { f ->
            val id = f.start()
            rejects { GpsWorkoutFinalizer(f.account, f.gps, afterDestinationWrite = { throw Crash() }).finish(id, f.inputs) }
            val frozen = f.payload(id)
            val tooLarge = GpsWorkoutPayload.capture(f.account, id,
                frozen.row.copy(notes = "x".repeat(GpsWorkoutPayload.MAX_BYTES)), frozen.samples)
            AccountGpsJournal(f.account, AccountWriteFence(f.account)).use { journal ->
                rejects { journal.freezeFinalization(tooLarge) }
            }
            assertArrayEquals(frozen.encode(), f.payload(id).encode()); assertEquals(2, f.route()!!.pointCount)
        }
    }

    @Test fun allWorkoutColumnsAndOrderedHrRoundTripWithoutRecalculation() = runBlocking {
        Fixture().use { f ->
            val id = f.start()
            val session = f.gps.finishDurable()
            val endMs = checkNotNull(session.endMs)
            val row = WorkoutRow(session.deviceId, session.startMs / 1000, endMs / 1000, session.sport, "manual",
                durationS = (endMs - session.startMs - session.pausedDurationMs) / 1000.0,
                energyKcal = 222.125, avgHr = 151, maxHr = 189, strain = 51.375, distanceM = session.distanceM,
                zonesJSON = "{\"z\":2}", notes = "synthetic \u03b1", routePolyline = RouteMath.encode(session.track), steps = 987)
            val payload = GpsWorkoutPayload.capture(f.account, id, row, f.samples.reversed() + f.samples.first())
            AccountGpsJournal(f.account, AccountWriteFence(f.account)).use { it.freezeFinalization(payload) }
            f.gps.retireAndJoin()
            val decoded = f.payload(id)
            assertEquals(row, decoded.row); assertEquals(payload.samples, decoded.samples)
            assertArrayEquals(payload.encode(), decoded.encode())
        }
    }

    @Test fun maximumHrPayloadLargerThanCursorWindowReopensWithoutTruncation() = runBlocking {
        Fixture().use { f ->
            val id = f.start()
            rejects { GpsWorkoutFinalizer(f.account, f.gps, afterDestinationWrite = { throw Crash() }).finish(id, f.inputs) }
            val original = f.payload(id)
            // Keep the route in this fixture; use a new session to exercise an unoccupied payload slot.
            f.gps.discardDurable(id)
            val next = f.start()
            val ended = f.gps.finishDurable()
            val endMs = checkNotNull(ended.endMs)
            val row = original.row.copy(startTs = ended.startMs / 1000, endTs = endMs / 1000,
                durationS = (endMs - ended.startMs - ended.pausedDurationMs).coerceAtLeast(0) / 1000.0,
                distanceM = ended.distanceM.takeIf { it > 0 }, routePolyline = RouteMath.encode(ended.track))
            val samples = List(GpsWorkoutPayload.MAX_HR_SAMPLES) { f.samples[it % f.samples.size] }
            val payload = GpsWorkoutPayload.capture(f.account, next, row, samples)
            assertTrue(payload.encode().size > 2 * 1024 * 1024)
            AccountGpsJournal(f.account, AccountWriteFence(f.account)).use { it.freezeFinalization(payload) }
            f.gps.retireAndJoin()
            val restored = f.payload(next)
            assertEquals(samples, restored.samples)
            assertArrayEquals(payload.encode(), restored.encode())
        }
    }

    @Test fun unknownPayloadVersionIsRetainedAndCannotBeRebuiltOnRetry() = runBlocking {
        Fixture().use { f ->
            val id = f.start()
            rejects { GpsWorkoutFinalizer(f.account, f.gps, afterDestinationWrite = { throw Crash() }).finish(id, f.inputs) }
            val bytes = f.payload(id).encode().also { it[7] = 2 }
            f.gps.retireAndJoin()
            val path = f.account.getDatabasePath(AccountGpsJournal.FILE_NAME)
            SQLiteDatabase.openDatabase(path.path, null, SQLiteDatabase.OPEN_READWRITE).use {
                it.execSQL("UPDATE gpsFinalization SET payload=? WHERE singleton=1", arrayOf(bytes))
            }
            val recovered = f.session().also { it.recoverDurable() }
            rejects { GpsWorkoutFinalizer(f.account, recovered).finish(id, f.changed) }
            assertEquals(id, f.route()!!.id)
            SQLiteDatabase.openDatabase(path.path, null, SQLiteDatabase.OPEN_READONLY).use { db ->
                db.rawQuery("SELECT payload FROM gpsFinalization", null).use {
                    assertTrue(it.moveToFirst()); assertArrayEquals(bytes, it.getBlob(0))
                }
            }
        }
    }

    @Test fun schemaOneUpgradePreservesExactRouteAndFinishedMetadata() = runBlocking {
        Fixture().use { f ->
            val path = f.account.getDatabasePath(AccountGpsJournal.FILE_NAME)
            val id = java.util.UUID.randomUUID().toString()
            val points = listOf(RouteMath.LatLng(-0.0, 20.123456789), RouteMath.LatLng(-0.0, 20.123456789))
            SQLiteDatabase.openOrCreateDatabase(path, null).use { db ->
                db.execSQL("CREATE TABLE gpsOwner(singleton INTEGER PRIMARY KEY CHECK(singleton=1), namespace TEXT NOT NULL, project TEXT NOT NULL, user TEXT NOT NULL)")
                db.execSQL("INSERT INTO gpsOwner VALUES(1,?,?,?)", arrayOf(f.account.namespace, f.account.identity.projectURL, f.account.identity.scope!!.userID))
                db.execSQL("CREATE TABLE gpsSession(singleton INTEGER PRIMARY KEY CHECK(singleton=1), id TEXT NOT NULL UNIQUE, device TEXT NOT NULL, startMs INTEGER NOT NULL, sport TEXT NOT NULL, pausedAtMs INTEGER, pausedDurationMs INTEGER NOT NULL, lastMs INTEGER NOT NULL, endMs INTEGER, pointCount INTEGER NOT NULL, distanceM REAL NOT NULL)")
                db.execSQL("CREATE TABLE gpsPoint(ordinal INTEGER PRIMARY KEY, latitudeBits INTEGER NOT NULL, longitudeBits INTEGER NOT NULL)")
                db.execSQL("INSERT INTO gpsSession VALUES(1,?,'gps-original-device',1000,'Walk',4000,500,3000,4000,2,0)", arrayOf(id))
                points.forEachIndexed { i, point -> db.execSQL("INSERT INTO gpsPoint VALUES(?,?,?)", arrayOf(i, point.lat.toRawBits(), point.lon.toRawBits())) }
                db.version = 1
            }
            repeat(2) {
                AccountGpsJournal(f.account, AccountWriteFence(f.account)).use { journal ->
                    val recovered = journal.read(true)!!
                    assertEquals(id, recovered.id); assertEquals(4000L, recovered.endMs); assertEquals(500L, recovered.pausedDurationMs)
                    assertEquals(points.map { it.lat.toRawBits() to it.lon.toRawBits() }, recovered.track.map { it.lat.toRawBits() to it.lon.toRawBits() })
                    assertNull(journal.finalization(id))
                    rejects { journal.settle(id) }
                }
            }
            SQLiteDatabase.openDatabase(path.path, null, SQLiteDatabase.OPEN_READONLY).use { assertEquals(2, it.version) }
        }
    }
}
