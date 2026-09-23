package com.noop.ble

import android.app.Application
import com.noop.analytics.PhoneComputeRuntime
import com.noop.data.*
import com.noop.oura.*
import java.io.IOException
import java.util.Base64
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.SQLiteMode
import org.robolectric.util.ReflectionHelpers

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class, instrumentedPackages = ["com.noop.analytics.PhoneComputeRuntime"])
@SQLiteMode(SQLiteMode.Mode.NATIVE)
@OptIn(ExperimentalCoroutinesApi::class)
class GenericNotificationCaptureNativeTest {
    private val device = "generic-observed-fixture"
    private val epoch = 1_750_000_000L
    private fun identity(f: CaptureIndexNativeFixture) = BleCaptureIdentity(f.initialAccount.namespace,
        f.initialAccount.identity.generation.toString(), f.owner.sourceId.toString(), device, UUID.randomUUID().toString())
    private fun sink(f: CaptureIndexNativeFixture, scope: CoroutineScope, family: String,
                     committed: () -> Unit = {}, afterWrite: suspend () -> Unit = {}, recovered: () -> Unit = {}) =
        GenericNotificationCapture(scope, identity(f), family, f.initialAccount::isCurrent,
            write = { raw, rows -> WhoopRepository(f.room).insert(rows, device, rawCaptures = listOf(raw), markCloudPushDebt = true); afterWrite() },
            committed = committed, blocked = {}, recovered = recovered, nowMs = { epoch * 1000 }, monotonicNs = { 123456 })
    private fun count(f: CaptureIndexNativeFixture, table: String): Int =
        f.db.query("SELECT count(*) FROM $table").use { it.moveToFirst(); it.getInt(0) }
    private fun originals(f: CaptureIndexNativeFixture): List<JSONObject> = f.db.query("SELECT framesBlob FROM bleRawBatch ORDER BY id").use { rows ->
        buildList { while (rows.moveToNext()) addAll(BleRawCapture.decodeFrames(rows.getBlob(0)).map { JSONObject(it.toString(Charsets.UTF_8)) }) }
    }
    private fun ouraPacket() = byteArrayOf(0x60,0x12,0x02,0x00,0x01,0x00,0x80.toByte(),0x7b,0x77,0x75,0x7a,0x78,
        0xe4.toByte(),0xdd.toByte(),0xcc.toByte(),0xd4.toByte(),0xe8.toByte(),0xd7.toByte(),0x9d.toByte(),0x33)
    private fun oura(f: CaptureIndexNativeFixture, capture: GenericNotificationCapture, anchored: Boolean): OuraLiveSource {
        val source = OuraLiveSource(f.initialAccount, device, OuraRingGen.GEN3,
            liveSink = { _, _ -> }, authKey = { null }, durableCapture = capture)
        val driver = OuraDriver(OuraRingGen.GEN3, null)
        if (anchored) {
            val payload = IntArray(8) { ((epoch ushr (8 * it)) and 255).toInt() } + intArrayOf(0)
            driver.ingest(OuraRecord(OuraEventTag.TIME_SYNC.raw, 0x0001_0002, payload))
        }
        ReflectionHelpers.setField(source, "driver", driver)
        return source
    }

    @Test fun actualHuamiCustomCallbackCommitsOriginalObservedHRAndDebt() = runTest {
        CaptureIndexNativeFixture().use { f ->
            var wakes = 0
            val capture = sink(f, backgroundScope, "huami", { wakes++ })
            val source = HuamiHrSource(f.initialAccount, device, liveSink = {}, durableCapture = capture)
            val bytes = byteArrayOf(0,72)
            assertTrue(source.ingestNotification(HuamiHrSource.HUAMI_SERVICE.toString(), HuamiHrSource.HUAMI_HEART_RATE_CHAR, bytes))
            bytes[1] = 99
            assertTrue(capture.drain())
            assertEquals(1,count(f,"hrSample")); assertEquals(0,count(f,"rrInterval")); assertEquals(1,wakes)
            val original = originals(f).single()
            assertEquals("huami",original.getString("family"))
            assertEquals(HuamiHrSource.HUAMI_HEART_RATE_CHAR.toString(),original.getString("characteristicUUID"))
            assertEquals("host_receipt_unverified",original.getString("clockQuality"))
            assertArrayEquals(byteArrayOf(0,72),Base64.getDecoder().decode(original.getString("payload")))
            assertEquals(listOf("cloudPush"),WhoopRepository(f.room).owedSyncJobs().map { it.kind })
            source.stop()
            assertFalse(source.ingestNotification("service",HuamiHrSource.HUAMI_HEART_RATE_CHAR,byteArrayOf(0,73)))
        }
    }

    @Test fun actualSigHRRetainsTransmittedRROnlyInRawUntilBeatAdapterExists() = runTest {
        CaptureIndexNativeFixture().use { f ->
            val capture = sink(f,backgroundScope,"huami")
            val source = HuamiHrSource(f.initialAccount,device,liveSink={},durableCapture=capture)
            assertTrue(source.ingestNotification(HuamiHrSource.STD_HEART_RATE_SERVICE.toString(),HuamiHrSource.STD_HEART_RATE_CHAR,byteArrayOf(0x10,70,0,4)))
            assertTrue(capture.drain())
            assertEquals(0,count(f,"rrInterval"))
            val raw = originals(f).single()
            val packet = Base64.getDecoder().decode(raw.getString("payload"))
            assertEquals(listOf(1000),StandardHeartRate.parse(packet)!!.rr)
            assertEquals("unqualified",raw.getString("rrProjectionStatus"))
            assertEquals("producer_not_implemented",raw.getString("rrProjectionReason"))
            source.stop()
        }
    }

    @Test fun equalRRNotificationsInOneHostSecondKeepEveryOriginalWithoutClaimingQualifiedBeats() = runTest {
        CaptureIndexNativeFixture().use { f ->
            val capture = sink(f,backgroundScope,"huami")
            val source = HuamiHrSource(f.initialAccount,device,liveSink={},durableCapture=capture)
            val bytes = byteArrayOf(0x10,70,0,4)
            repeat(2) {
                assertTrue(source.ingestNotification(HuamiHrSource.STD_HEART_RATE_SERVICE.toString(),HuamiHrSource.STD_HEART_RATE_CHAR,bytes))
                assertTrue(capture.drain())
            }
            val raw = originals(f)
            assertEquals(2,raw.size)
            assertEquals(listOf(0L,1L),raw.map { it.getLong("sequence") })
            raw.forEach { assertArrayEquals(bytes,Base64.getDecoder().decode(it.getString("payload"))) }
            // Both originals remain recoverable, but no unqualified interval reaches the
            // legacy scalar table that frozen-v1 consumes without a beat-clock filter.
            raw.forEach { assertEquals(listOf(1000),StandardHeartRate.parse(Base64.getDecoder().decode(it.getString("payload")))!!.rr) }
            assertEquals(0,count(f,"rrInterval"))
            assertEquals(0,count(f,"standardHrReceipt"))
            assertEquals(0,count(f,"rrPacketProvenance"))
            source.stop()
        }
    }

    @Test fun actualStandardHRCallbackKeepsExactWordsAndHRThroughFailedTransactionWithoutLegacyRR() = runTest {
        CaptureIndexNativeFixture().use { f ->
            PhoneComputeRuntime.installFinalHosted()
            val capture=sink(f,backgroundScope,"standard_hr")
            val source=StandardHrSource(f.initialAccount,device,liveSink={_,_->},
                persist={_,_,_->fail("prepared source must use captured transaction")},durableCapture=capture)
            val bytes=byteArrayOf(0x10,70,0,4,10,4)
            f.db.execSQL("CREATE TRIGGER refuse_generic BEFORE INSERT ON bleRawBatch BEGIN SELECT RAISE(ABORT,'fixture'); END")
            assertTrue(source.ingestHeartRateNotification(bytes))
            assertFalse(capture.drain()); assertEquals(0,count(f,"hrSample")); assertEquals(0,count(f,"rrInterval"))
            f.db.execSQL("DROP TRIGGER refuse_generic")
            source.stop(); assertTrue(capture.drain())
            assertEquals(1,count(f,"hrSample")); assertEquals(0,count(f,"rrInterval"))
            assertArrayEquals(bytes,Base64.getDecoder().decode(originals(f).single().getString("payload")))
            assertEquals(listOf(1000,1010),StandardHeartRate.parse(bytes)!!.rr)
            assertTrue(PhoneComputeRuntime.evidence().isEmpty())
        }
    }

    @Test fun legacyStandardCallbackFlushRetainsExactReceiptButCannotPublishArrivalRR() = runTest {
        CaptureIndexNativeFixture().use { f ->
            PhoneComputeRuntime.installFinalHosted()
            val saved=CompletableDeferred<Unit>()
            val source=StandardHrSource(f.initialAccount,device,liveSink={_,_->},persist={batch,id,done->
                backgroundScope.launch {
                    try { val counts=WhoopRepository(f.room).insert(batch,id); done(Result.success(counts)); saved.complete(Unit) }
                    catch (error:Exception) { saved.completeExceptionally(error) }
                }
            })
            val bytes=byteArrayOf(0x10,70,0,4,10,4)
            assertTrue(source.ingestHeartRateNotification(bytes)); source.stop(); saved.await()
            assertEquals(1,count(f,"hrSample")); assertEquals(0,count(f,"rrInterval"))
            f.db.query("SELECT rawHex,clockVersion FROM standardHRReceipt").use {
                assertTrue(it.moveToFirst()); assertEquals("104600040a04",it.getString(0))
                assertEquals("host-arrival-unmapped",it.getString(1)); assertFalse(it.moveToNext())
            }
            assertTrue(PhoneComputeRuntime.evidence().isEmpty())
        }
    }

    @Test fun actualWHOOPStandardCallbackKeepsReceiptAndHRWithoutLegacyRR() = runTest {
        CaptureIndexNativeFixture().use { f ->
            PhoneComputeRuntime.installFinalHosted()
            val client=WhoopBleClient(f.initialAccount,WhoopRepository(f.room),device)
            try {
                val bytes=byteArrayOf(0x10,70,0,4,10,4)
                ReflectionHelpers.callInstanceMethod<Unit>(client,"parseStandardHr",
                    ReflectionHelpers.ClassParameter.from(ByteArray::class.java,bytes))
                val queue=ReflectionHelpers.callInstanceMethod<LiveCaptureQueue<Any>>(client,"getStandardCapture")
                assertTrue(queue.drain())
                assertEquals(1,count(f,"hrSample")); assertEquals(0,count(f,"rrInterval"))
                f.db.query("SELECT rawHex,clockVersion FROM standardHRReceipt").use {
                    assertTrue(it.moveToFirst()); assertEquals("104600040a04",it.getString(0))
                    assertEquals("host-arrival-unmapped",it.getString(1)); assertFalse(it.moveToNext())
                }
                assertTrue(PhoneComputeRuntime.evidence().isEmpty())
            } finally { client.shutdown() }
        }
    }

    @Test fun actualFTMSCallbackPersistsObservedFieldsMalformedOriginalAndBattery() = runTest {
        CaptureIndexNativeFixture().use { f ->
            val capture = sink(f,backgroundScope,"ftms")
            val source = FtmsSource(f.initialAccount,liveSink={},durableCapture=capture)
            val machine = UUID.fromString("00002acd-0000-1000-8000-00805f9b34fb")
            assertTrue(source.ingestNotification(FtmsSource.FITNESS_MACHINE_SERVICE.toString(),machine,byteArrayOf(1,1,99)))
            assertTrue(source.ingestNotification(FtmsSource.FITNESS_MACHINE_SERVICE.toString(),machine,byteArrayOf(-1)))
            assertTrue(source.ingestNotification("0000180f-0000-1000-8000-00805f9b34fb",UUID.fromString("00002a19-0000-1000-8000-00805f9b34fb"),byteArrayOf(88)))
            source.stop(); assertTrue(capture.drain())
            assertEquals(3,originals(f).size); assertEquals(1,count(f,"hrSample")); assertEquals(1,count(f,"battery"))
            f.db.query("SELECT payloadJSON FROM event WHERE kind='FTMS_READING'").use {
                assertTrue(it.moveToFirst()); val fields=JSONObject(it.getString(0))
                assertEquals(99,fields.getInt("heart_rate_bpm")); assertTrue(fields.isNull("power_watts"))
            }
        }
    }

    @Test fun rawFailureRollsBackDecodedRowsDebtAndCursorUntilRetry() = runTest {
        CaptureIndexNativeFixture().use { f ->
            var wakes=0; var cursor=-1
            val capture=sink(f,backgroundScope,"huami",{wakes++})
            f.db.execSQL("CREATE TRIGGER refuse_generic BEFORE INSERT ON bleRawBatch BEGIN SELECT RAISE(ABORT,'fixture'); END")
            assertTrue(capture.capture(byteArrayOf(72),"custom","custom") { assertTrue(capture.persist(StreamBatch(hr=listOf(HrRow(epoch,72))))) })
            repeat(10_000) { i -> capture.setCursorAfterDurablePrefix { cursor=i } }
            capture.setCursorAfterDurablePrefix { cursor=0 }
            assertFalse(capture.drain()); assertEquals(-1,cursor); assertEquals(0,wakes)
            assertEquals(0,count(f,"hrSample")); assertEquals(0,count(f,"bleRawBatch"))
            assertTrue(WhoopRepository(f.room).owedSyncJobs().isEmpty())
            f.db.execSQL("DROP TRIGGER refuse_generic")
            capture.seal(); assertTrue(capture.drain())
            assertEquals(0,cursor); assertEquals(1,wakes); assertEquals(1,count(f,"hrSample")); assertEquals(1,count(f,"bleRawMember"))
        }
    }

    @Test fun lostCommitResponseReplaysSameRawAndDecodedIdentity() = runTest {
        CaptureIndexNativeFixture().use { f ->
            var failed=false
            val capture=sink(f,backgroundScope,"huami",afterWrite={ if(!failed){failed=true;throw IOException("lost response")} })
            capture.capture(byteArrayOf(72),"custom","custom") { capture.persist(StreamBatch(hr=listOf(HrRow(epoch,72)))) }
            assertFalse(capture.drain()); assertEquals(1,count(f,"hrSample")); assertEquals(1,count(f,"bleRawMember"))
            capture.seal(); assertTrue(capture.drain())
            assertEquals(1,count(f,"hrSample")); assertEquals(1,count(f,"bleRawMember")); assertEquals(1,originals(f).size)
        }
    }

    @Test fun overBudgetProjectionRetainsOriginalWithoutInvokingNumericalCode() = runTest {
        CaptureIndexNativeFixture().use { f ->
            PhoneComputeRuntime.installFinalHosted()
            val capture=sink(f,backgroundScope,"oura")
            capture.capture(byteArrayOf(1),"oura","notify") { assertFalse(capture.persist(StreamBatch(hr=List(500){HrRow(epoch+it,72)}))) }
            capture.seal(); assertTrue(capture.drain())
            assertEquals(1,originals(f).size); assertEquals(0,count(f,"hrSample")); assertTrue(PhoneComputeRuntime.evidence().isEmpty())
        }
    }

    @Test fun rawCapacityIncludesInflightAndFinalAcceptedPrefixSurvivesSeal() = runTest {
        CaptureIndexNativeFixture().use { f ->
            val capture=sink(f,backgroundScope,"ftms")
            repeat(16) { assertTrue(capture.capture(byteArrayOf(it.toByte()),"ftms","machine") {}) }
            assertFalse(capture.capture(byteArrayOf(99),"ftms","machine") {})
            assertEquals(16,capture.pendingCount)
            capture.seal(); repeat(2){ capture.drain() }
            assertEquals(16,originals(f).size); assertEquals(0,capture.pendingCount)
        }
    }

    @Test fun preparedOuraAnchoredRecordRetainsOriginalWithoutPromotingItToQualifiedBeats() = runTest {
        CaptureIndexNativeFixture().use { f ->
            PhoneComputeRuntime.installFinalHosted()
            val capture=sink(f,backgroundScope,"oura"); val source=oura(f,capture,true)
            assertTrue(source.ingestNotification(ouraPacket())); source.stop(); assertTrue(capture.drain())
            assertEquals(0,count(f,"rrInterval")); assertEquals(0,count(f,"hrSample")); assertEquals(1,originals(f).size)
            assertArrayEquals(ouraPacket(),Base64.getDecoder().decode(originals(f).single().getString("payload")))
            assertEquals("producer_not_implemented",originals(f).single().getString("rrProjectionReason"))
            assertTrue(PhoneComputeRuntime.evidence().isEmpty())
        }
    }

    @Test fun preparedOuraUnknownClockAndPhasesNeverAcquireInventedTimeline() = runTest {
        CaptureIndexNativeFixture().use { f ->
            PhoneComputeRuntime.installFinalHosted()
            val capture=sink(f,backgroundScope,"oura"); val source=oura(f,capture,false)
            val phases=byteArrayOf(0x4e,6,2,0,1,0,0,0x6c)
            repeat(20){ assertTrue(source.ingestNotification(ouraPacket()));assertTrue(source.ingestNotification(phases)); assertTrue(capture.drain()) }
            assertEquals(0,source.retainedUnknownClockCount)
            source.stop(); assertTrue(capture.drain())
            assertEquals(40,originals(f).size);assertEquals(0,count(f,"rrInterval"));assertEquals(0,count(f,"event"));assertEquals(0,count(f,"hrSample"))
            assertTrue(PhoneComputeRuntime.evidence().isEmpty())
        }
    }

    @Test fun ouraActualCursorWaitsForTransactionAndUsesCapturedAccountPreferences() = runTest {
        CaptureIndexNativeFixture().use { f ->
            val capture=sink(f,backgroundScope,"oura"); val source=oura(f,capture,false)
            f.db.execSQL("CREATE TRIGGER refuse_generic BEFORE INSERT ON bleRawBatch BEGIN SELECT RAISE(ABORT,'fixture'); END")
            source.ingestNotification(byteArrayOf(0x7f,1,0));source.saveResumeCursorAfterDurability(123)
            assertFalse(capture.drain());assertEquals(0L,OuraHistoryCursorStore.read(f.initialAccount,device))
            f.db.execSQL("DROP TRIGGER refuse_generic")
            source.stop();assertTrue(capture.drain());assertEquals(123L,OuraHistoryCursorStore.read(f.initialAccount,device))
            assertEquals(0L,OuraHistoryCursorStore.read(f.initialAccount,"other-device"))
        }
    }

    @Test fun retiredCaptureFailureCannotStopReplacementWithSameDeviceId() = runTest {
        CaptureIndexNativeFixture().use { f ->
            val previous=sink(f,backgroundScope,"huami")
            val replacement=sink(f,backgroundScope,"huami")
            var stops=0
            val source=object: LiveHrSource {
                override fun scan() {}
                override fun connect(address:String) {}
                override fun stop() { stops++ }
            }
            val coordinator=SourceCoordinator(f.initialAccount,DeviceRegistry(f.room),WhoopRepository(f.room),
                liveSink={_,_->},startWhoop={},stopWhoop={},scope=backgroundScope)
            ReflectionHelpers.setField(coordinator,"activeSource",source)
            ReflectionHelpers.setField(coordinator,"activeStrapId",device)
            ReflectionHelpers.setField(coordinator,"activeGenericCapture",replacement)
            coordinator.onGenericCaptureBlocked(previous); runCurrent()
            assertEquals(0,stops)
            coordinator.onGenericCaptureBlocked(replacement); runCurrent()
            assertEquals(1,stops)
            f.controller.clearSession()
            coordinator.onGenericCaptureBlocked(replacement); runCurrent()
            assertEquals(1,stops)
        }
    }

    @Test fun committedHeldPrefixResumesOnlyTheSameCurrentRegisteredSource() = runTest {
        CaptureIndexNativeFixture().use { f ->
            val capture=sink(f,backgroundScope,"huami")
            val registry=DeviceRegistry(f.room)
            registry.add(PairedDeviceRow(id=device,brand="Huami",model="fixture",nickname=null,
                sourceKind=SourceKind.huami.name,capabilities="hr",status=DeviceStatus.active.name,
                addedAt=epoch,lastSeenAt=epoch,peripheralId=null))
            registry.setActive(device)
            assertEquals(device,registry.activeDeviceId())
            var stops=0
            val prior=object:LiveHrSource { override fun scan() {}; override fun connect(address:String) {}; override fun stop(){stops++} }
            val coordinator=SourceCoordinator(f.initialAccount,registry,WhoopRepository(f.room),
                liveSink={_,_->},startWhoop={},stopWhoop={},scope=backgroundScope)
            ReflectionHelpers.setField(coordinator,"activeSource",prior)
            ReflectionHelpers.setField(coordinator,"activeStrapId",device)
            ReflectionHelpers.setField(coordinator,"activeGenericCapture",capture)
            f.db.execSQL("CREATE TRIGGER refuse_generic BEFORE INSERT ON bleRawBatch BEGIN SELECT RAISE(ABORT,'fixture'); END")
            capture.capture(byteArrayOf(70),"huami","notify") {}
            coordinator.onGenericCaptureBlocked(capture);runCurrent()
            assertSame(prior,ReflectionHelpers.getField<LiveHrSource>(coordinator,"activeSource"))
            assertEquals(1,stops)
            f.db.execSQL("DROP TRIGGER refuse_generic")
            assertTrue(capture.drain())
            coordinator.onGenericCaptureRecovered(capture).join()
            val replacement=ReflectionHelpers.getField<LiveHrSource>(coordinator,"activeSource")
            assertNotSame(prior,replacement)
            coordinator.onGenericCaptureRecovered(capture);runCurrent()
            assertSame(replacement,ReflectionHelpers.getField<LiveHrSource>(coordinator,"activeSource"))
            replacement.stop()
        }
    }

    @Test fun cloudWakeFailureCannotPreventDurableCaptureRecovery() = runTest {
        CaptureIndexNativeFixture().use { f ->
            var recovered=0
            val capture=sink(f,backgroundScope,"huami",committed={throw IOException("scheduler unavailable")},
                recovered={recovered++})
            assertTrue(capture.capture(byteArrayOf(70),"huami","notify") {})
            capture.seal();assertTrue(capture.drain())
            assertTrue(capture.isDrained);assertTrue(recovered>0)
            assertEquals(1,originals(f).size)
        }
    }

    @Test fun retiredOwnerRejectsFreshCallbackAndCannotCommitPendingIntoAnotherScope() = runTest {
        CaptureIndexNativeFixture().use { f ->
            val capture=sink(f,backgroundScope,"huami")
            capture.capture(byteArrayOf(72),"custom","custom") { capture.persist(StreamBatch(hr=listOf(HrRow(epoch,72)))) }
            f.controller.clearSession()
            assertFalse(capture.capture(byteArrayOf(73),"custom","custom") {})
            assertFalse(capture.drain());assertEquals(1,capture.pendingCount)
            assertEquals(0,count(f,"hrSample"));assertEquals(0,count(f,"bleRawBatch"))
        }
    }
    @Test fun sameAccountReplacementGenerationCannotDrainTheRetiredCapture() = runTest {
        CaptureIndexNativeFixture().use { f ->
            val capture=sink(f,backgroundScope,"huami")
            capture.capture(byteArrayOf(72),"custom","custom") { capture.persist(StreamBatch(hr=listOf(HrRow(epoch,72)))) }
            f.controller.clearSession(); f.controller.signIn("synthetic","synthetic")
            assertEquals(f.owner.scope,f.controller.identitySnapshot().scope)
            assertNotEquals(f.initialAccount.identity.generation,f.controller.identitySnapshot().generation)
            assertFalse(capture.drain());assertEquals(1,capture.pendingCount)
            assertFalse(capture.capture(byteArrayOf(73),"custom","custom") {})
            assertEquals(0,count(f,"hrSample"));assertEquals(0,count(f,"bleRawBatch"))
        }
    }

}
