package com.noop.push

import android.app.Application
import android.content.Context
import com.noop.data.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.time.LocalDate
import java.time.ZoneId
import java.util.UUID

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class W1PreparedAuxiliaryNativeTest {
    private val sourceId = "30000000-0000-4000-8000-000000000001"
    private val table = PushBinaryTable.V18_AUX_SAMPLE
    private val lane = PushObjectLane("/fixture", 4 * 1024 * 1024, 3600, setOf(table))
    private fun progressKey(f: W4NativeFixture) = "${f.device}:v18AuxSample.identity-v2"
    private fun progress(f: W4NativeFixture) = EndpointScopedProgressStore(
        SharedPrefsPushProgressStore(f.account().getSharedPreferences("synthetic-prepared", Context.MODE_PRIVATE)), "receiver-fixture")
    private fun coordinator(f: W4NativeFixture, transport: PushTransport, progress: PushProgressStore = progress(f)) =
        PushCoordinator(PushDao(WhoopDatabase.get(f.account())), transport, progress, sourceId,
            { LocalDate.of(2026, 9, 18) }, ZoneId.of("UTC"))
    private suspend fun insert(f: W4NativeFixture, index: Long, value: Int = 1) = WhoopRepository(WhoopDatabase.get(f.account()))
        .insert(StreamBatch(v18Aux = listOf(V18AuxRow(100, recordIndex = index, rrCount = value.toLong()))), f.device)

    private class Transport : PushTransport {
        val manifests = mutableListOf<PushObjectManifest>()
        val payloads = mutableListOf<ByteArray>()
        var failIntent: PushFailure? = null
        var failUpload = false
        var completed = 0
        override suspend fun post(batch: PushBatch): PushTransportResponse = error("Object lane only")
        override suspend fun createObjectIntent(manifest: PushObjectManifest, lane: PushObjectLane): PushObjectIntent {
            manifests += manifest
            failIntent?.let { throw PushTransportException(it) }
            return PushObjectIntent(manifest.objectId, "fixture/${manifest.objectId}", "https://fixture.test/synthetic", emptyMap(), null, false)
        }
        override suspend fun uploadObject(intent: PushObjectIntent, body: ByteArray) {
            payloads += body.copyOf()
            if (failUpload) throw PushTransportException(PushFailure(PushFailureCode.NETWORK_IO))
        }
        override suspend fun completeObject(objectId: String, lane: PushObjectLane): PushObjectAck {
            completed++
            return PushObjectAck(objectId, "ready", "fixture/$objectId", false)
        }
    }

    @Test fun newRowsAfterFailedUploadCannotGrowPreparedPrefixAcrossProgressReopen() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            insert(f, 0); val http = Transport().apply { failUpload = true }
            assertTrue(coordinator(f, http).pushObjects(table, f.device, lane, "1.4") is PushResult.Rejected)
            val prepared = progress(f).preparedBoundary(table, progressKey(f))!!
            assertEquals(1, prepared.sampleCount); insert(f, 1)
            http.failUpload = false
            val retry = coordinator(f, http).pushObjects(table, f.device, lane, "1.4") as PushResult.Accepted
            assertTrue(retry.hasMore); assertEquals(1, retry.recordCount)
            assertEquals(http.manifests[0], http.manifests[1]); assertArrayEquals(http.payloads[0], http.payloads[1])
            assertNull(progress(f).preparedBoundary(table, progressKey(f)))
            assertEquals(prepared.endCursor, progress(f).binaryCursor(table, progressKey(f)))
            assertTrue(coordinator(f, http).pushObjects(table, f.device, lane, "1.4") is PushResult.Accepted)
            assertEquals(1L, http.manifests[2].sampleCount); assertNotEquals(http.manifests[0].objectId, http.manifests[2].objectId)
            assertNull(progress(f).binaryCursor(table, f.device)) // No cursor reset or adoption in legacy namespace.
        }
    }

    @Test fun intentFailureStillFreezesBytesAndObjectConflictDoesNotRegenerateIdentity() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            insert(f, 0); val http = Transport().apply { failIntent = PushFailure.http(409, "object_id_conflict") }
            assertTrue(coordinator(f, http).pushObjects(table, f.device, lane, "1.4") is PushResult.Rejected)
            assertEquals(1, http.manifests.size); assertNotNull(progress(f).preparedBoundary(table, progressKey(f)))
            insert(f, 1); http.failIntent = null
            assertTrue(coordinator(f, http).pushObjects(table, f.device, lane, "1.4") is PushResult.Accepted)
            assertEquals(http.manifests[0], http.manifests[1])
        }
    }

    @Test fun failedOrNoopPreparedPersistenceCannotStartTransport() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            insert(f, 0); val http = Transport(); val base = progress(f)
            for (throwFailure in listOf(true, false)) {
                val broken = object : PushProgressStore by base {
                    override suspend fun savePreparedBoundary(table: PushBinaryTable, deviceId: String, prepared: PushPreparedBoundary?) {
                        if (throwFailure) error("synthetic persistence failure")
                    }
                }
                assertTrue(coordinator(f, http, broken).pushObjects(table, f.device, lane, "1.4") is PushResult.Rejected)
                assertTrue(http.manifests.isEmpty())
            }
        }
    }

    @Test fun changedOrDeletedPreparedRowsFailClosedWithoutReplacingPendingIdentity() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            insert(f, 0); val http = Transport().apply { failUpload = true }
            coordinator(f, http).pushObjects(table, f.device, lane, "1.4")
            val expected = progress(f).preparedBoundary(table, progressKey(f))!!
            val sql = WhoopDatabase.get(f.account()).openHelper.writableDatabase
            sql.execSQL("UPDATE v18AuxSample SET fields=?", arrayOf(V18AuxIdentity.pack(V18AuxRow(100, recordIndex = 0, rrCount = 99))))
            http.failUpload = false
            assertTrue(coordinator(f, http).pushObjects(table, f.device, lane, "1.4") is PushResult.Rejected)
            sql.execSQL("DELETE FROM v18AuxSample")
            assertTrue(coordinator(f, http).pushObjects(table, f.device, lane, "1.4") is PushResult.Rejected)
            assertEquals(expected, progress(f).preparedBoundary(table, progressKey(f))); assertEquals(1, http.manifests.size)
        }
    }

    @Test fun acceptedCursorSurvivesPendingCleanupFailureWithoutResendingOldRows() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            insert(f, 0); val http = Transport(); val base = progress(f)
            val failCleanup = object : PushProgressStore by base {
                override suspend fun savePreparedBoundary(table: PushBinaryTable, deviceId: String, prepared: PushPreparedBoundary?) {
                    if (prepared == null) error("synthetic crash after cursor commit")
                    base.savePreparedBoundary(table, deviceId, prepared)
                }
            }
            assertTrue(coordinator(f, http, failCleanup).pushObjects(table, f.device, lane, "1.4") is PushResult.Rejected)
            assertEquals(1, http.completed); assertNotNull(base.binaryCursor(table, progressKey(f)))
            insert(f, 1)
            assertTrue(coordinator(f, http).pushObjects(table, f.device, lane, "1.4") is PushResult.Accepted)
            assertEquals(2, http.completed); assertNotEquals(http.manifests[0].objectId, http.manifests[1].objectId)
            assertNull(base.preparedBoundary(table, progressKey(f)))
        }
    }

    @Test fun preparedProgressIsAccountEndpointAndGenerationFenced() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            insert(f, 0); val http = Transport().apply { failUpload = true }; val context = f.account().identity.context!!
            val base = progress(f)
            val fenced = AccountFencedProgress(base, AccountPushAdmission(context, context.scope, sourceId, f.controller::isCurrent))
            coordinator(f, http, fenced).pushObjects(table, f.device, lane, "1.4")
            val pending = base.preparedBoundary(table, progressKey(f))!!
            val otherEndpoint = EndpointScopedProgressStore(SharedPrefsPushProgressStore(
                f.account().getSharedPreferences("synthetic-prepared", Context.MODE_PRIVATE)), "other-receiver")
            assertNull(otherEndpoint.preparedBoundary(table, progressKey(f)))
            f.controller.clearSession()
            assertTrue(runCatching { fenced.savePreparedBoundary(table, progressKey(f), null) }.exceptionOrNull() is AccountAuthException)
            assertEquals(pending, base.preparedBoundary(table, progressKey(f)))
            val otherScope = AccountScope.create(f.owner.projectURL, UUID.randomUUID().toString())
            val otherAccount = com.noop.account.AccountStorageContext(f.account().baseContext,
                AccountIdentitySnapshot(otherScope.projectURL, otherScope, UUID.randomUUID()))
            assertNull(SharedPrefsPushProgressStore(otherAccount.getSharedPreferences("synthetic-prepared", Context.MODE_PRIVATE))
                .preparedBoundary(table, "receiver-fixture:${progressKey(f)}"))
        }
    }
}
