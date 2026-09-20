package com.noop.push

import android.app.Application
import android.content.Context
import com.noop.account.AccountStorageContext
import com.noop.account.AccountWriteFence
import com.noop.analytics.RouteMath.LatLng
import com.noop.data.WhoopDatabase
import com.noop.data.WorkoutRow
import com.noop.location.AccountGpsJournal
import com.noop.location.AccountGpsSession
import com.noop.location.GpsWorkoutFinalizer
import com.noop.location.GpsWorkoutPayload
import java.io.File
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
class W2GpsDurabilityNativeTest {
    private val a = AccountScope.create("https://gps.example.test", "10000000-0000-4000-8000-000000000001")
    private val b = AccountScope.create("https://gps.example.test", "10000000-0000-4000-8000-000000000002")
    private lateinit var app: Context
    private lateinit var controller: AccountSessionController
    private lateinit var installation: AutoCloseable
    private val journals = mutableListOf<AccountGpsJournal>()
    private val sessions = mutableListOf<AccountGpsSession>()
    private val points = listOf(LatLng(-0.0, 20.1234567890123), LatLng(-0.0, 20.1234567890123), LatLng(0.1234567890123, 20.2345678901234))

    @Before fun setup() {
        app = RuntimeEnvironment.getApplication()
        val credentials = object : AccountCredentialStore {
            var session: AccountSession? = AccountSession(a, "synthetic-access", "synthetic-refresh", Long.MAX_VALUE)
            override fun load(projectURL: String) = session?.takeIf { it.scope.projectURL == projectURL }
            override fun save(session: AccountSession) { this.session = session }
            override fun clear(projectURL: String) { session = null }
        }
        controller = AccountSessionController(credentials, AccountAuthTransport { _, grant ->
            val owner = if ((grant as? AccountGrant.Password)?.email == "b") b else a
            AccountReply(200, """{"access_token":"synthetic-access","refresh_token":"synthetic-refresh","expires_in":3600,"user":{"id":"${owner.userID}"}}""")
        })
        controller.configure(AccountConfiguration(a.projectURL, "synthetic-anon"))
        installation = CloudAuthClient.installTestController(controller)
    }

    @After fun teardown() {
        runBlocking { sessions.forEach { it.retireAndJoin() } }
        journals.forEach { it.close() }
        WhoopDatabase.close()
        installation.close()
    }

    private fun account() = AccountStorageContext(app, controller.identitySnapshot())
    private fun journal(context: AccountStorageContext = account(), max: Int = 262_144, beforeCommit: () -> Unit = {}) =
        AccountGpsJournal(context, AccountWriteFence(context), max, beforeCommit).also { journals += it }
    private fun session(context: AccountStorageContext = account()) = AccountGpsSession(context).also { sessions += it }
    private fun rejects(body: () -> Unit) {
        try { body(); fail("operation should have failed") } catch (expected: Exception) { }
    }

    private fun freeze(raw: AccountGpsJournal, finished: AccountGpsJournal.Snapshot): ByteArray {
        val endMs = checkNotNull(finished.endMs)
        val row = WorkoutRow(deviceId = finished.deviceId, startTs = finished.startMs / 1000,
            endTs = endMs / 1000, sport = finished.sport, source = "manual",
            durationS = (endMs - finished.startMs - finished.pausedDurationMs).coerceAtLeast(0) / 1000.0,
            distanceM = finished.distanceM.takeIf { it > 0 },
            routePolyline = if (finished.track.size >= 2) com.noop.analytics.RouteMath.encode(finished.track) else null)
        return raw.freezeFinalization(GpsWorkoutPayload.capture(account(), finished.id, row, emptyList())).encode()
    }

    @Test fun exactOrderedDuplicatePointsSurviveActualCloseAndReopen() {
        val original = journal()
        val begun = original.start(1000, "Walk", "original-device")
        points.forEachIndexed { index, point -> original.append(begun.id, point, 2000L + index) }
        original.close()
        val reopened = journal().read(fullTrack = true)!!
        assertEquals(begun.id, reopened.id)
        assertEquals("original-device", reopened.deviceId)
        assertEquals(points.map { it.lat.toRawBits() to it.lon.toRawBits() }, reopened.track.map { it.lat.toRawBits() to it.lon.toRawBits() })
        assertEquals(3, reopened.pointCount)
    }

    @Test fun recoveredSessionIsPausedWithoutStartingLocationAndResumeIsExplicit() = runBlocking {
        val raw = journal()
        val begun = raw.start(1000, "Walk", "original-device")
        raw.append(begun.id, points.first(), 4000)
        raw.close()
        val current = session()
        val recovered = current.recoverDurable()
        assertFalse(recovered.active)
        assertTrue(recovered.paused)
        assertEquals(4000L, recovered.pausedAtMs)
        assertFalse(current.appendDurable(points.last()))
        assertEquals(1, current.state.value.pointCount)
        assertTrue(current.resumeDurable().active)
        assertTrue(current.appendDurable(points.last()))
        assertEquals(2, current.state.value.pointCount)
    }

    @Test fun aToBToARestoresOnlyTheOriginalOwnersDebtAndRejectsLateCallback() = runBlocking {
        val old = session()
        val begun = old.startDurable(1000, "Walk", "device-A")
        old.appendDurable(points.first())
        controller.signIn("b", "synthetic")
        old.retire()
        val next = session()
        assertNull(next.recoverDurable().sessionId)
        assertFalse(old.appendDurable(points.last()))
        controller.signIn("a", "synthetic")
        next.retire()
        val restored = session().recoverDurable()
        assertEquals(begun.sessionId, restored.sessionId)
        assertEquals("device-A", restored.deviceId)
        assertEquals(1, restored.pointCount)
        assertFalse(restored.active)
    }

    @Test fun revocationAtActualCommitRollsBackTheNewPoint() = runBlocking {
        var revoke = false
        val original = journal(beforeCommit = { if (revoke) controller.clearSession() })
        val begun = original.start(1000, "Walk", "device-A")
        original.append(begun.id, points.first(), 2000)
        revoke = true
        rejects { original.append(begun.id, points.last(), 3000) }
        original.close()
        controller.signIn("a", "synthetic")
        val restored = journal().read(true)!!
        assertEquals(1, restored.pointCount)
        assertEquals(points.first(), restored.track.single())
    }

    @Test fun storageFailurePreservesCommittedPointsAndAllowsExactRetry() {
        var fail = false
        val raw = journal(beforeCommit = { if (fail) throw java.io.IOException("synthetic disk failure") })
        val begun = raw.start(1000, "Walk", "device-A")
        raw.append(begun.id, points.first(), 2000)
        fail = true
        rejects { raw.append(begun.id, points.last(), 3000) }
        assertEquals(1, raw.read()!!.pointCount)
        fail = false
        assertEquals(2, raw.append(begun.id, points.last(), 3000).pointCount)
        raw.close()
        assertEquals(listOf(points.first(), points.last()), journal().read(true)!!.track)
    }

    @Test fun fullDataCapacityStillPermitsFinishAndSettlementWithoutEviction() {
        val raw = journal(max = 2)
        val begun = raw.start(1000, "Walk", "device-A")
        raw.append(begun.id, points.first(), 2000)
        raw.append(begun.id, points.last(), 3000)
        rejects { raw.append(begun.id, points.last(), 4000) }
        assertEquals(2, raw.read()!!.pointCount)
        val finished = raw.finish(begun.id, 5000)
        assertEquals(2, finished.track.size)
        rejects { raw.settle(begun.id) }
        raw.settle(begun.id, expectedPayload = freeze(raw, finished))
        assertNull(raw.read())
    }

    @Test fun finishIsRetryStableAndCannotDeleteAnotherSession() {
        val raw = journal()
        val begun = raw.start(1000, "Walk", "device-A")
        raw.append(begun.id, points.first(), 2000)
        val finish = raw.finish(begun.id, 3000)
        raw.close()
        val next = journal()
        assertEquals(finish, next.finish(begun.id, 9999))
        rejects { next.resume(begun.id, 9999) }
        rejects { next.settle("not-the-same-session") }
        assertEquals(begun.id, next.read()!!.id)
        next.settle(begun.id, expectedPayload = freeze(next, finish))
        val another = next.start(10000, "Walk", "device-B")
        rejects { next.settle(begun.id, explicitDiscard = true) }
        assertEquals(another.id, next.read()!!.id)
    }

    @Test fun newStartCannotOverwriteUnsettledDebtButExplicitDiscardCanRemoveIt() {
        val raw = journal()
        val begun = raw.start(1000, "Walk", "device-A")
        rejects { raw.start(2000, "Run", "device-B") }
        rejects { raw.settle(begun.id) }
        assertEquals(begun.id, raw.read()!!.id)
        raw.settle(begun.id, explicitDiscard = true)
        assertNull(raw.read())
        assertNotEquals(begun.id, raw.start(3000, "Run", "device-B").id)
    }

    @Test fun wrongOwnerAndCorruptFilesAreRejectedWithoutRewritingThem() = runBlocking {
        val ca = account()
        val raw = journal(ca)
        raw.start(1000, "Walk", "device-A")
        raw.close()
        val bytes = ca.getDatabasePath(AccountGpsJournal.FILE_NAME).readBytes()
        controller.signIn("b", "synthetic")
        val cb = account()
        val target = cb.getDatabasePath(AccountGpsJournal.FILE_NAME)
        target.writeBytes(bytes)
        rejects { journal(cb).read() }
        assertArrayEquals(bytes, target.readBytes())
    }

    @Test fun unrecognizedBytesAndWalArePreserved() {
        val ca = account()
        val file = ca.getDatabasePath(AccountGpsJournal.FILE_NAME)
        val wal = File(file.path + "-wal")
        val bytes = "unrecognized synthetic journal".toByteArray()
        val walBytes = byteArrayOf(3, 4, 5, 6)
        file.writeBytes(bytes); wal.writeBytes(walBytes)
        rejects { journal(ca).read() }
        assertArrayEquals(bytes, file.readBytes())
        assertArrayEquals(walBytes, wal.readBytes())
    }

    @Test fun actualWorkoutSaveFailureKeepsRouteUntilSuccessfulRepositoryCommit() = runBlocking {
        val ca = account()
        val gps = session(ca)
        gps.startDurable(1000, "Walk", "device-A")
        gps.appendDurable(points.first()); gps.appendDurable(points.last())
        val id = gps.state.value.sessionId!!
        val finalizer = GpsWorkoutFinalizer(ca, gps)
        val inputs = GpsWorkoutFinalizer.Inputs(emptyList(), com.noop.analytics.UserProfile(), 190.0)
        val db = WhoopDatabase.get(ca)
        db.openHelper.writableDatabase.execSQL("CREATE TRIGGER synthetic_gps_save_failure BEFORE INSERT ON workout BEGIN SELECT RAISE(ABORT,'synthetic failure'); END")
        try { finalizer.finish(id, inputs); fail("save should fail") } catch (_: Exception) { }
        assertEquals(2, journal(ca).read(true)!!.track.size)
        db.openHelper.writableDatabase.execSQL("DROP TRIGGER synthetic_gps_save_failure")
        val row = finalizer.finish(id, inputs)
        assertNull(journal(ca).read())
        db.openHelper.readableDatabase.query("SELECT COUNT(*),deviceId,routePolyline FROM workout").use {
            assertTrue(it.moveToFirst()); assertEquals(1, it.getInt(0))
            assertEquals("device-A", it.getString(1)); assertEquals(row.routePolyline, it.getString(2))
        }
    }

    @Test fun invalidCoordinatesDoNotEnterDurableOrPresentedRoute() {
        val raw = journal()
        val begun = raw.start(1000, "Walk", "device-A")
        listOf(LatLng(Double.NaN, 0.0), LatLng(91.0, 0.0), LatLng(0.0, Double.POSITIVE_INFINITY), LatLng(0.0, -181.0)).forEach {
            rejects { raw.append(begun.id, it, 2000) }
        }
        assertEquals(0, raw.read()!!.pointCount)
    }

    @Test fun priorSessionCollectorCannotRelabelItsLatePointIntoANewWorkout() = runBlocking {
        val gps = session()
        val old = gps.startDurable(1000, "Walk", "device-A")
        gps.discardDurable(old.sessionId!!)
        val next = gps.startDurable(2000, "Run", "device-B")
        assertFalse(gps.appendDurable(points.first(), old.sessionId))
        assertEquals(0, gps.state.value.pointCount)
        assertTrue(gps.appendDurable(points.last(), next.sessionId))
        assertEquals("device-B", gps.state.value.deviceId)
        assertEquals(1, gps.state.value.pointCount)
    }
}
