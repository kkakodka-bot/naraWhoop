package com.noop.push

import android.app.Application
import android.content.Context
import androidx.work.testing.TestListenableWorkerBuilder
import com.noop.account.AccountStorageContext
import com.noop.data.WhoopDatabase
import java.io.File
import java.util.UUID
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
class W2AndroidAccountRuntimeTest {
    private val a = AccountScope.create("https://a.example.test", "10000000-0000-4000-8000-000000000001")
    private val b = AccountScope.create("https://a.example.test", "10000000-0000-4000-8000-000000000002")
    private lateinit var app: Context
    private lateinit var controller: AccountSessionController
    private lateinit var installation: AutoCloseable
    private val config = AccountConfiguration(a.projectURL, "synthetic-anon")
    @Before fun setup() {
        app = RuntimeEnvironment.getApplication()
        val credentials = object : AccountCredentialStore {
            var saved: AccountSession? = AccountSession(a, "synthetic-access", "synthetic-refresh", Long.MAX_VALUE)
            override fun load(projectURL: String) = saved?.takeIf { it.scope.projectURL == projectURL }
            override fun save(session: AccountSession) { saved = session }
            override fun clear(projectURL: String) { saved = null }
        }
        controller = AccountSessionController(credentials, AccountAuthTransport { _, grant ->
            val owner = if ((grant as? AccountGrant.Password)?.email == "b") b else a
            AccountReply(200, """{"access_token":"synthetic-access","refresh_token":"synthetic-refresh","expires_in":3600,"user":{"id":"${owner.userID}"}}""")
        })
        controller.configure(config)
        installation = CloudAuthClient.installTestController(controller)
    }
    @After fun teardown() { WhoopDatabase.close(); installation.close() }
    private fun context(scope: AccountScope, generation: UUID = controller.identitySnapshot().generation) =
        AccountStorageContext(app, AccountIdentitySnapshot(scope.projectURL, scope, generation))

    @Test fun oldWriterNeverBecomesTheNextAccountsDatabase() = runBlocking {
        val ca = context(a)
        val legacy = app.getDatabasePath(WhoopDatabase.DB_NAME)
        legacy.parentFile!!.mkdirs(); legacy.writeText("unowned fixture preserved")
        val da = WhoopDatabase.get(ca)
        da.openHelper.writableDatabase.execSQL("INSERT INTO hrSample(deviceId,ts,bpm,synced) VALUES('fixture',1,61,0)")
        controller.signIn("b", "synthetic")
        val cb = context(b); val db = WhoopDatabase.get(cb)
        db.openHelper.writableDatabase.execSQL("INSERT INTO hrSample(deviceId,ts,bpm,synced) VALUES('fixture',1,72,0)")
        try { da.openHelper.writableDatabase.execSQL("INSERT INTO hrSample(deviceId,ts,bpm,synced) VALUES('fixture',2,63,0)"); fail("retired write") }
        catch (expected: com.noop.account.AccountWriteRevokedException) { assertEquals(AuthFailure.STALE, expected.failure) }
        da.openHelper.readableDatabase.query("SELECT count(*) FROM hrSample").use { assertTrue(it.moveToFirst()); assertEquals(1, it.getInt(0)) }
        db.openHelper.readableDatabase.query("SELECT count(*) FROM hrSample").use { assertTrue(it.moveToFirst()); assertEquals(1, it.getInt(0)) }
        assertEquals("unowned fixture preserved", legacy.readText())
        assertNotEquals(da.openHelper.databaseName, db.openHelper.databaseName)
        assertSame(db, WhoopDatabase.get(context(b)))
    }
    @Test fun prefsPendingFilesAndCacheAreCapturedAndAccountScoped() {
        val ca = context(a); val cb = context(b)
        val pa = ca.getSharedPreferences("profile", 0); val pb = cb.getSharedPreferences("profile", 0)
        assertTrue(pa.edit().putString("name", "synthetic-A").commit())
        assertNull(pb.getString("name", null))
        val pending = File(ca.filesDir, "uploads").apply { mkdirs() }
        File(pending, "pending.bin").writeBytes(byteArrayOf(1, 2, 3))
        assertFalse(File(cb.filesDir, "uploads/pending.bin").exists())
        controller.clearSession()
        assertTrue(File(pending, "pending.bin").exists())
        assertEquals(ca.root, context(a).root)
        val otherProject = context(AccountScope.create("https://b.example.test", a.userID))
        assertNotEquals(ca.root, otherProject.root)
    }
    @Test fun roomAbsolutePathRoundTripsButCannotEscapeAccountDirectory() {
        val ca = context(a); val cb = context(b)
        val owned = ca.getDatabasePath(WhoopDatabase.DB_NAME)
        assertEquals(owned, ca.getDatabasePath(owned.absolutePath))
        for (path in listOf("../other.sqlite", ".", "..", cb.getDatabasePath(WhoopDatabase.DB_NAME).absolutePath)) {
            try { ca.getDatabasePath(path); fail("foreign database path accepted") }
            catch (_: IllegalArgumentException) { }
        }
    }
    @Test fun ownerMismatchAndMissingOwnerAreRejected() = runBlocking {
        val db = WhoopDatabase.get(context(a))
        db.openHelper.writableDatabase
        val binding = AccountPushCaptureBindings.Binding(db, b, UUID.randomUUID().toString(), null)
        try { AccountPushCaptureBindings.validateOwner(binding); fail("wrong owner") } catch (expected: AccountAuthException) {
            assertEquals(AuthFailure.UNBOUND_CAPTURE, expected.failure)
        }
        db.openHelper.writableDatabase.execSQL("DELETE FROM localAccountOwner")
        try { AccountPushCaptureBindings.validateOwner(binding.copy(scope = a)); fail("missing owner") }
        catch (expected: AccountAuthException) { assertEquals(AuthFailure.UNBOUND_CAPTURE, expected.failure) }
    }
    @Test fun schedulingCapturesIdentityWithoutCredentials() {
        val captured = controller.identitySnapshot().context!!
        val request = SelfHostedPushScheduler.request(true, captured)
        assertTrue(AccountPushJobAdmission.matches(captured, request.workSpec.input.getString(AccountPushJobAdmission.NAMESPACE),
            request.workSpec.input.getString(AccountPushJobAdmission.GENERATION)))
        assertEquals(2, request.workSpec.input.keyValueMap.size)
        assertFalse(request.workSpec.input.toString().contains("synthetic-access"))
        assertNotEquals(SelfHostedPushScheduler.workName(captured),
            SelfHostedPushScheduler.workName(captured.copy(generation = UUID.randomUUID())))
    }
    @Test fun staleOrLegacyWorkerExitsBeforeOpeningAnyCapture() = runBlocking {
        val captured = controller.identitySnapshot().context!!
        val old = SelfHostedPushWorker.accountInput(captured.copy(generation = UUID.randomUUID()))
        val worker = TestListenableWorkerBuilder<SelfHostedPushWorker>(app).setInputData(old).build()
        assertEquals(androidx.work.ListenableWorker.Result.success(), worker.doWork())
        val legacy = TestListenableWorkerBuilder<SelfHostedPushWorker>(app).build()
        assertEquals(androidx.work.ListenableWorker.Result.success(), legacy.doWork())
        assertFalse(File(app.filesDir, "accounts-v1").exists())
    }
    @Test fun runSignalsCannotSettleAnotherAccountOrGeneration() {
        val ca = context(a); val cb = context(b); val next = context(a, UUID.randomUUID())
        assertTrue(PushRunSignal.reserve(ca, "a-job"))
        assertTrue(PushRunSignal.reserve(cb, "b-job"))
        assertTrue(PushRunSignal.reserve(next, "next-job"))
        assertFalse(PushRunSignal.settle(cb, "a-job", false) {}.owned)
        assertTrue(PushRunSignal.settle(ca, "a-job", false) {}.owned)
        assertTrue(PushRunSignal.settle(next, "next-job", false) {}.owned)
        assertTrue(PushRunSignal.settle(cb, "b-job", false) {}.owned)
    }
    @Test fun unrecognizedDatabaseAndWalArePreservedWithoutBinding() {
        val ca = context(a)
        val file = ca.getDatabasePath(WhoopDatabase.DB_NAME)
        val wal = File(file.path + "-wal")
        val bytes = "synthetic unrecognized capture".toByteArray()
        val walBytes = byteArrayOf(9, 8, 7, 6)
        file.writeBytes(bytes); wal.writeBytes(walBytes)
        try { WhoopDatabase.get(ca); fail("unrecognized store accepted") } catch (_: Exception) { }
        assertArrayEquals(bytes, file.readBytes())
        assertArrayEquals(walBytes, wal.readBytes())
    }
    @Test fun recognizedSqliteWithoutOwnerIsNotMigratedOrClaimed() {
        val ca = context(a)
        val file = ca.getDatabasePath(WhoopDatabase.DB_NAME)
        android.database.sqlite.SQLiteDatabase.openOrCreateDatabase(file, null).use {
            it.execSQL("CREATE TABLE synthetic_capture(value TEXT)")
            it.execSQL("INSERT INTO synthetic_capture VALUES('unowned')")
            it.execSQL("PRAGMA user_version=1")
        }
        val before = file.readBytes()
        try { WhoopDatabase.get(ca); fail("unbound store adopted") } catch (_: Exception) { }
        assertArrayEquals(before, file.readBytes())
    }
    @Test fun everyBackgroundWorkerRejectsLegacyAndOtherGenerationInput() = runBlocking {
        val ca = AccountStorageContext.capture(app)
        val input = com.noop.account.AccountWorkContext.input(ca)
        assertNotNull(com.noop.account.AccountWorkContext.resolve(app, input))
        assertNull(com.noop.account.AccountWorkContext.resolve(app, androidx.work.Data.EMPTY))
        controller.clearSession()
        assertNull(com.noop.account.AccountWorkContext.resolve(app, input))
        val backup = TestListenableWorkerBuilder<com.noop.ui.BackupSyncWorker>(app).setInputData(input).build()
        val export = TestListenableWorkerBuilder<com.noop.ui.DebugExportWorker>(app).setInputData(input).build()
        val coach = TestListenableWorkerBuilder<com.noop.ui.CoachBriefScheduler.CoachBriefWorker>(app).setInputData(input).build()
        assertEquals(androidx.work.ListenableWorker.Result.success(), backup.doWork())
        assertEquals(androidx.work.ListenableWorker.Result.success(), export.doWork())
        assertEquals(androidx.work.ListenableWorker.Result.success(), coach.doWork())
    }
    @Test fun runtimeRetirementAndGpsNeverRebindOldHandles() = runBlocking {
        val old = com.noop.account.AccountAppRuntime(context(a))
        old.gpsSession.startDurable(1L, "synthetic-walk", "synthetic-device")
        old.close()
        controller.signIn("b", "synthetic")
        val next = com.noop.account.AccountAppRuntime(context(b))
        old.gpsSession.start(2L, "late-callback")
        assertTrue(old.closed)
        assertFalse(old.gpsSession.state.value.active)
        assertFalse(next.gpsSession.state.value.active)
        assertNotSame(old.database, next.database)
        next.close()
    }
    @Test fun healthIdsAndConsentDoNotCrossAccountsOrInheritOsGrants() {
        val ca = context(a); val cb = context(b)
        assertNotEquals(com.noop.ingest.HealthConnectWriter.accountRecordId(ca, "noop-sleep-100"),
            com.noop.ingest.HealthConnectWriter.accountRecordId(cb, "noop-sleep-100"))
        com.noop.ui.NoopPrefs.setHcWriteback(ca, true)
        assertFalse(com.noop.ui.NoopPrefs.hcWriteback(cb))
        com.noop.ingest.HealthConnectImporter.migrateSelectionFromGrants(cb,
            com.noop.ingest.HealthConnectImporter.permissionsFor(com.noop.ingest.HealthConnectImporter.ImportCategory.entries.toSet()))
        assertFalse(com.noop.ui.NoopPrefs.of(cb).contains("noop.hc.importCategories"))
    }
    @Test fun consentAndSourceIdAreAccountScopedAndStableAcrossFacades() {
        val ca = AccountStorageContext.capture(app)
        assertNull(SelfHostedPushSettings.from(ca).enabledEndpoint())
        com.noop.ui.NoopPrefs.of(ca).edit().putString(com.noop.ui.NoopPrefs.KEY_ACCEPTED_TERMS_VERSION,
            com.noop.ui.Terms.CURRENT_VERSION).commit()
        assertNotNull(SelfHostedPushSettings.from(ca).enabledEndpoint())
        val id = SelfHostedPushSettings.from(ca).sourceId()
        assertEquals(id, SelfHostedPushSettings.from(ca).sourceId())
        assertNull(SelfHostedPushSettings.from(context(b)).enabledEndpoint())
        controller.clearSession()
        assertNull(SelfHostedPushSettings.from(ca).enabledEndpoint())
    }
    @Test fun diagnosticBuffersNeverCopyThePreviousAccountsLines() {
        com.noop.ui.StrapLogBuffer.replaceWith("synthetic-A", namespace = a.namespace)
        com.noop.ui.StrapLogBuffer.replaceWith("synthetic-B", namespace = b.namespace)
        assertEquals("synthetic-A", com.noop.ui.StrapLogBuffer.snapshot(namespace = a.namespace))
        assertEquals("synthetic-B", com.noop.ui.StrapLogBuffer.snapshot(namespace = b.namespace))
        com.noop.ui.StrapLogBuffer.clear()
    }
    @Test fun imuShortLivedFacadesSharePendingOnlyInsideTheirCapturedFolder() {
        val ca = context(a); val cb = context(b)
        val ts = 1_800_000_000L
        fun frame(seed: Int) = ByteArray(1244).also { bytes ->
            repeat(4) { bytes[15 + it] = (ts shr (8 * it)).toByte() }
            bytes[24] = 100; bytes[630] = 100; bytes[28] = seed.toByte()
        }
        fun store(c: Context) = com.noop.testcentre.ImuSessionFileStore(c)
        store(ca).start("same-session", "fixture", ts * 1000)
        store(cb).start("same-session", "fixture", ts * 1000)
        assertEquals(1, store(ca).append("fixture", frame(1)))
        assertEquals(1, store(ca).stats("same-session", ts, ts).coveredSeconds)
        assertEquals(0, store(cb).stats("same-session", ts, ts).coveredSeconds)
        assertEquals(1, store(cb).append("fixture", frame(2)))
        assertEquals(0, store(ca).append("fixture", frame(1)))
        val old = store(ca).pushRecords("fixture", 0, 10).single()
        val next = store(cb).pushRecords("fixture", 0, 10).single()
        assertFalse(old.columns.contentEquals(next.columns))
        assertEquals(1, store(ca).stats("same-session", ts, ts).coveredSeconds)
    }
    @Test fun imuFailedFlushKeepsRetryablePendingRecords() {
        val ca = context(a)
        val ts = 1_800_000_000L
        val store = com.noop.testcentre.ImuSessionFileStore(ca)
        val frame = ByteArray(1244).also { bytes ->
            repeat(4) { bytes[15 + it] = (ts shr (8 * it)).toByte() }
            bytes[24] = 100; bytes[630] = 100
        }
        store.start("fixture-session", "fixture", ts * 1000)
        store.append("fixture", frame)
        val filename = "imu-${com.noop.testcentre.ImuSessionFileStore.utcName(com.noop.testcentre.ImuSessionFileStore.bucketStart(ts))}.imus"
        val obstruction = File(ca.filesDir, "imu/raw-imu-bounded/fixture-session/$filename")
        assertTrue(obstruction.mkdir())
        try { store.prepareForRead("fixture-session"); fail("flush unexpectedly succeeded") }
        catch (_: java.io.IOException) { }
        assertEquals(1, store.stats("fixture-session", ts, ts).coveredSeconds)
        assertTrue(obstruction.delete()) // only the empty synthetic obstruction created above
        val reopened = com.noop.testcentre.ImuSessionFileStore(ca)
        reopened.prepareForRead("fixture-session")
        assertEquals(1, reopened.pushRecords("fixture", 0, 10).size)
    }
    @Test fun nativePpgPaginationRetainsDistinctSameSecondRecordIndices() = runBlocking {
        val db = WhoopDatabase.get(context(a))
        val sql = db.openHelper.writableDatabase
        sql.execSQL("INSERT INTO ppgWaveformSample(deviceId,ts,samples,burstIndex,recordIndex) VALUES('fixture',100,X'0100',NULL,4294967295)")
        sql.execSQL("INSERT INTO ppgWaveformSample(deviceId,ts,samples,burstIndex,recordIndex) VALUES('fixture',100,X'0200',NULL,12)")
        val source = PushDao(db)
        val first = source.binaryRows(PushBinaryTable.PPG_WAVEFORM_SAMPLE, "fixture", 0, 1).single() as PushBinaryRow.PpgWaveform
        val second = source.binaryRows(PushBinaryTable.PPG_WAVEFORM_SAMPLE, "fixture", first.record.rowId, 1).single() as PushBinaryRow.PpgWaveform
        assertEquals(4294967295L, first.record.recordIndex)
        assertEquals(12L, second.record.recordIndex)
        assertTrue(source.binaryRows(PushBinaryTable.PPG_WAVEFORM_SAMPLE, "fixture", second.record.rowId, 1).isEmpty())
    }
}
