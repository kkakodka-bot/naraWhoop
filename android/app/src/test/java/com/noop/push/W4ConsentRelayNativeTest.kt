package com.noop.push

import android.app.Application
import com.noop.account.AccountStorageContext
import kotlinx.coroutines.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.time.Instant
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class W4ConsentRelayNativeTest {
    private suspend fun close(consent: ScoringContextConsent) { consent.retire(); consent.awaitRetirement() }
    private fun config(era: String) = ScoringConfigInput(null, "EDWARDS", false, true, false, null, 0, 0, era)
    private fun capture(account: AccountStorageContext, device: String, zone: String = "America/Los_Angeles",
                        at: String = "2026-09-19T06:59:59Z") = ScoringConsentCapture.capture(
        ScoringInputSource.capture(account, device), config(device), zone, Instant.parse(at))
    private suspend fun denial(account: AccountStorageContext, frozen: ScoringConsentCapture): ScoringConsentIntent {
        val consent = ScoringContextConsent(account, capture = { frozen }, didSave = {})
        try { consent.setEnabled(ScoringContextPurpose.JOURNAL, false); assertNull(consent.state.value.error) }
        finally { close(consent) }
        return ScoringConsentDatabase.open(account).use { it.dao().intents().last() }
    }
    private fun head(f: W4NativeFixture, body: String, revision: Long = 0): ScoringRpcReply {
        val input = JSONObject(body)
        return ScoringRpcReply(200, JSONObject().put("schemaVersion", 1).put("userId", f.owner.userID)
            .put("sourceDeviceId", input.getString("p_device")).put("kind", input.getString("p_kind"))
            .put("entity", input.getString("p_entity")).put("headRevision", revision).toString())
    }

    @Test fun failedRevocationNewRuntimeBeforeRetryCannotRecoverOldGrant() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account()
            val first = ScoringContextConsent(account)
            first.setEnabled(ScoringContextPurpose.JOURNAL, true)
            val old = first.decision(ScoringContextPurpose.JOURNAL)!!
            val payload = JSONObject().put("consent", old.payload()).toString()
            ScoringConsentDatabase.open(account).use { db ->
                db.openHelper.writableDatabase.execSQL("""CREATE TRIGGER reject_revoke BEFORE UPDATE ON consentDecision
                    WHEN NEW.purpose='journal_context' AND NEW.enabled=0
                    BEGIN SELECT RAISE(ABORT,'synthetic update failure'); END""")
                first.setEnabled(ScoringContextPurpose.JOURNAL, false)
                first.load()
                first.setEnabled(ScoringContextPurpose.CYCLE, true)
                assertFalse(first.allows(ScoringContextPurpose.JOURNAL, payload))
                close(first)
                val next = ScoringContextConsent(account)
                try {
                    next.load()
                    assertTrue("Trigger preserved the prior disk grant", db.dao().get("journal_context")!!.enabled)
                    assertFalse("Fresh runtime must hold the old grant BEFORE retry", next.allows(ScoringContextPurpose.JOURNAL, payload))
                    assertNotNull(next.state.value.error)
                    db.openHelper.writableDatabase.execSQL("DROP TRIGGER reject_revoke")
                    next.setEnabled(ScoringContextPurpose.JOURNAL, false)
                } finally { close(next) }
                val last = ScoringContextConsent(account)
                try { last.load(); assertFalse(last.allows(ScoringContextPurpose.JOURNAL, payload)) }
                finally { close(last) }
            }
        }
    }

    @Test fun failedDenialRetryRetainsOriginalDecisionDateAndSource() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account(); val frozen = capture(account, f.device)
            val first = ScoringContextConsent(account, capture = { frozen }, didSave = {})
            first.setEnabled(ScoringContextPurpose.JOURNAL, true)
            ScoringConsentDatabase.open(account).use { db ->
                db.openHelper.writableDatabase.execSQL("""CREATE TRIGGER reject_revoke BEFORE UPDATE ON consentDecision
                    WHEN NEW.enabled=0 BEGIN SELECT RAISE(ABORT,'synthetic failure'); END""")
                first.setEnabled(ScoringContextPurpose.JOURNAL, false)
                val pending = db.dao().intents().last()
                assertEquals("prepared", pending.state); assertFalse(pending.enabled)
                close(first)
                val second = ScoringContextConsent(account, capture = { capture(account, UUID.randomUUID().toString(), "Asia/Tokyo", "2026-09-20T12:00:00Z") }, didSave = {})
                try {
                    second.load(); assertNull(second.decision(ScoringContextPurpose.JOURNAL))
                    second.setEnabled(ScoringContextPurpose.JOURNAL, true)
                    assertNull(second.decision(ScoringContextPurpose.JOURNAL))
                    assertEquals(2, db.dao().intents().size)
                    db.openHelper.writableDatabase.execSQL("DROP TRIGGER reject_revoke")
                    second.setEnabled(ScoringContextPurpose.JOURNAL, false)
                    assertEquals(pending.copy(state = "local_saved"), db.dao().intents().last())
                    assertNull(db.dao().barrier("journal_context"))
                } finally { close(second) }
            }
        }
    }

    @Test fun consentCommitRecoveryPrecedesNewSnapshotAndImportsOnlyOnceAfterReauthentication() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val first = f.account(); val frozen = capture(first, f.device)
            val intent = denial(first, frozen)
            assertFalse(first.getDatabasePath("server_sync.sqlite").exists())
            f.controller.clearSession(); f.controller.signIn("a", "synthetic")
            val account = f.account()
            val runtime = ScoringInputRuntime(account, scheduled = {})
            try {
                val newConfig = runtime.captureConfig(config(f.device).copy(effortMethod = "BANISTER"), "Asia/Tokyo", runtime.captureSource(f.device))
                ScoringSyncDatabase.open(account).use { db ->
                    val imported = db.dao().consentImport(intent.intentId)!!
                    val mutation = db.dao().mutation(imported.mutationId)!!
                    assertEquals(1L, mutation.clientRevision); assertEquals(2L, newConfig.clientRevision)
                    assertEquals("waiting_previous", newConfig.state)
                    val body = JSONObject(mutation.body)
                    assertEquals("2026-09-18", body.getString("p_effective_day"))
                    assertEquals(f.device, body.getString("p_device"))
                    assertEquals(JSONObject(frozen.json).getJSONObject("config").toString(), body.getJSONObject("p_payload").toString())
                    repeat(2) { runtime.recoverConsent() }
                    assertEquals(mutation, db.dao().mutation(mutation.mutationId))
                    assertEquals(2L, db.dao().entity(mutation.entityKey)!!.clientRevision)
                }
            } finally { runtime.retire(); runtime.awaitRetirement() }
        }
    }

    @Test fun importCommittedBeforeRelayProgressCrashReusesExactMutation() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account(); val intent = denial(account, capture(account, f.device))
            ScoringConsentDatabase.open(account).use { consent ->
                consent.openHelper.writableDatabase.execSQL("""CREATE TRIGGER reject_progress BEFORE UPDATE ON consentIntent
                    WHEN NEW.state='queued' BEGIN SELECT RAISE(ABORT,'synthetic relay crash'); END""")
                val first = ScoringSyncDatabase.open(account).use { db ->
                    val store = ScoringSyncStore(account, db)
                    assertTrue(runCatching { ScoringConsentRelay.recoverBefore(account, store) {} }.isFailure)
                    assertEquals("local_saved", consent.dao().intent(intent.intentId)!!.state)
                    val link = db.dao().consentImport(intent.intentId)!!
                    db.dao().mutation(link.mutationId)!!
                }
                consent.openHelper.writableDatabase.execSQL("DROP TRIGGER reject_progress")
                ScoringSyncDatabase.open(account).use { db ->
                    val store = ScoringSyncStore(account, db)
                    repeat(2) { ScoringConsentRelay.recoverBefore(account, store) {} }
                    assertEquals(first, db.dao().mutation(first.mutationId))
                    assertEquals(1L, db.dao().entity(first.entityKey)!!.clientRevision)
                    assertEquals(first.mutationId, consent.dao().intent(intent.intentId)!!.mutationId)
                    assertEquals("queued", consent.dao().intent(intent.intentId)!!.state)
                }
            }
        }
    }

    @Test fun failedOriginInsertRollsBackMutationAndRevisionTogether() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account(); val intent = denial(account, capture(account, f.device))
            ScoringSyncDatabase.open(account).use { db ->
                val store = ScoringSyncStore(account, db)
                db.openHelper.writableDatabase.execSQL("""CREATE TRIGGER reject_origin BEFORE INSERT ON consentImport
                    BEGIN SELECT RAISE(ABORT,'synthetic origin failure'); END""")
                assertTrue(runCatching { store.importConsent(intent) }.isFailure)
                assertNull(db.dao().consentImport(intent.intentId)); assertTrue(store.pending().isEmpty())
                assertNull(db.dao().entity(ScoringInputKey(f.device, "config", "primary").storageKey))
                db.openHelper.writableDatabase.execSQL("DROP TRIGGER reject_origin")
                assertEquals(1L, store.importConsent(intent).clientRevision)
            }
        }
    }

    @Test fun httpAcceptedBeforeReceiptSaveReplaysIdenticalBytesAndRecordsVerifiedProgress() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account(); val intent = denial(account, capture(account, f.device))
            val sent = mutableListOf<String>()
            ScoringSyncDatabase.open(account).use { db ->
                val store = ScoringSyncStore(account, db)
                val rpc = f.rpc(account, ScoringRpcTransport { url, _, _, body ->
                    if (url.endsWith("get_scoring_history_input_head_v3")) head(f, body)
                    else {
                        sent.add(body)
                        val mutation = db.dao().mutation(JSONObject(body).getString("p_client_mutation_id"))!!
                        ScoringRpcReply(200, f.receipt(mutation))
                    }
                })
                db.openHelper.writableDatabase.execSQL("""CREATE TRIGGER reject_receipt BEFORE UPDATE ON historyMutation
                    WHEN NEW.state='settled' BEGIN SELECT RAISE(ABORT,'synthetic receipt crash'); END""")
                assertTrue(ScoringInputCoordinator(account, store, rpc, scheduled = {}).drain())
                val link = db.dao().consentImport(intent.intentId)!!
                assertEquals("pending", db.dao().mutation(link.mutationId)!!.state)
                db.openHelper.writableDatabase.execSQL("DROP TRIGGER reject_receipt")
            }
            ScoringSyncDatabase.open(account).use { db ->
                val store = ScoringSyncStore(account, db)
                val rpc = f.rpc(account, ScoringRpcTransport { url, _, _, body ->
                    assertTrue(url.endsWith("put_scoring_history_input_v3"))
                    sent.add(body)
                    ScoringRpcReply(200, f.receipt(db.dao().mutation(JSONObject(body).getString("p_client_mutation_id"))!!))
                })
                assertFalse(ScoringInputCoordinator(account, store, rpc, scheduled = {}).drain())
                assertEquals(2, sent.size); assertEquals(sent[0], sent[1])
                ScoringConsentDatabase.open(account).use { consent ->
                    val saved = consent.dao().intent(intent.intentId)!!
                    assertEquals("remote_accepted", saved.state); assertNotNull(saved.receipt)
                    val mutation = db.dao().mutation(saved.mutationId!!)!!
                    assertEquals(mutation.receipt, saved.receipt); assertEquals(1L, mutation.clientRevision)
                }
            }
        }
    }

    @Test fun verifiedReceiptRecoversAfterConsentProgressWriteFailsWithoutResending() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account(); val intent = denial(account, capture(account, f.device))
            ScoringConsentDatabase.open(account).use { consent ->
                consent.openHelper.writableDatabase.execSQL("""CREATE TRIGGER reject_remote_progress BEFORE UPDATE ON consentIntent
                    WHEN NEW.state='remote_accepted' BEGIN SELECT RAISE(ABORT,'synthetic crash'); END""")
                ScoringSyncDatabase.open(account).use { db ->
                    val store = ScoringSyncStore(account, db)
                    val draft = store.importConsent(intent)
                    val request = store.admitDraft(draft, ScoringInputHead(draft.key(), 0))
                    store.recordReceipt(request, f.receipt(request))
                    assertTrue(runCatching { ScoringConsentRelay.recoverBefore(account, store) {} }.isFailure)
                }
                consent.openHelper.writableDatabase.execSQL("DROP TRIGGER reject_remote_progress")
                ScoringSyncDatabase.open(account).use { db ->
                    val calls = AtomicInteger()
                    val rpc = f.rpc(account, ScoringRpcTransport { _, _, _, _ -> calls.incrementAndGet(); error("No resend expected") })
                    assertFalse(ScoringInputCoordinator(account, ScoringSyncStore(account, db), rpc, scheduled = {}).drain())
                    assertEquals(0, calls.get()); assertEquals("remote_accepted", consent.dao().intent(intent.intentId)!!.state)
                }
            }
        }
    }

    @Test fun disabledCloudTermsAndPresentationStillCaptureAndImportDenialWithoutAuthorization() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account(); val settings = SelfHostedPushSettings.from(account)
            settings.setEnabled(false); ServerScoringSettings.setEnabled(account, false)
            assertFalse(settings.snapshot().ready)
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            val runtime = ScoringInputRuntime(account, scheduled = {})
            val hook = ScoringSettingsSync(account, runtime, scope, source = { runtime.captureSource(f.device) }, ready = { false })
            val frozen = hook.captureConsent()!!
            val intent = denial(account, frozen)
            try {
                ScoringSyncDatabase.open(account).use { db ->
                    val calls = AtomicInteger()
                    val rpc = AccountScoringRpc(account, { "synthetic" }, {
                        calls.incrementAndGet(); f.controller.authorizedSession()
                    }, ScoringRpcTransport { _, _, _, _ -> error("Disabled transport") })
                    val coordinator = ScoringInputCoordinator(account, ScoringSyncStore(account, db), rpc,
                        scheduled = {}, canDeliver = { settings.snapshot().ready })
                    assertFalse(coordinator.drain()); assertEquals(0, calls.get())
                    val imported = db.dao().consentImport(intent.intentId)!!
                    val body = JSONObject(db.dao().mutation(imported.mutationId)!!.body)
                    assertEquals(JSONObject(frozen.json).getString("effectiveDay"), body.getString("p_effective_day"))
                    assertFalse(body.getJSONObject("p_payload").getBoolean("cycleAwarenessEnabled"))
                    assertFalse(body.getJSONObject("p_payload").getBoolean("journalContextEnabled"))
                }
            } finally { hook.retire(); runtime.retire(); runtime.awaitRetirement(); scope.cancel() }
        }
    }

    @Test fun rapidTogglesAndOtherPurposeKeepOrderAndDoNotReenableOldPayload() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account(); val consent = ScoringContextConsent(account, capture = { capture(account, f.device) }, didSave = {})
            try {
                consent.setEnabled(ScoringContextPurpose.JOURNAL, true)
                val old = JSONObject().put("consent", consent.decision(ScoringContextPurpose.JOURNAL)!!.payload()).toString()
                consent.setEnabled(ScoringContextPurpose.JOURNAL, false)
                consent.setEnabled(ScoringContextPurpose.JOURNAL, true)
                consent.setEnabled(ScoringContextPurpose.CYCLE, false)
                assertFalse(consent.allows(ScoringContextPurpose.JOURNAL, old))
                ScoringSyncDatabase.open(account).use { db ->
                    val store = ScoringSyncStore(account, db)
                    ScoringConsentRelay.recoverBefore(account, store) {}
                    ScoringConsentDatabase.open(account).use { journal ->
                        assertEquals(listOf(true, false, true, false), journal.dao().intents().map { it.enabled })
                        journal.dao().intents().forEachIndexed { index, row ->
                            val mutation = db.dao().mutation(row.mutationId!!)!!
                            assertEquals(index + 1L, mutation.clientRevision)
                            assertEquals(if (index == 0) "awaiting_head" else "waiting_previous", mutation.state)
                        }
                    }
                }
            } finally { close(consent) }
        }
    }

    @Test fun missingCaptureIsHeldAndNeverAcquiresNextDevice() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account(); val consent = ScoringContextConsent(account, didSave = {})
            consent.setEnabled(ScoringContextPurpose.JOURNAL, false)
            assertEquals("held_capture", consent.state.value.relay.single().state)
            close(consent)
            val runtime = ScoringInputRuntime(account, scheduled = {})
            try {
                assertTrue(runCatching { runtime.captureConfig(config(f.device), "UTC", runtime.captureSource(f.device)) }.exceptionOrNull() is ScoringConsentRelayHeld)
                ScoringSyncDatabase.open(account).use { assertTrue(it.dao().pending(20).isEmpty()) }
                ScoringConsentDatabase.open(account).use { assertNull(it.dao().intents().single().capture) }
            } finally { runtime.retire(); runtime.awaitRetirement() }
        }
    }

    @Test fun changedOriginOrOwnerCannotBeImportedUnderAnExistingIntentId() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account(); val intent = denial(account, capture(account, f.device))
            ScoringSyncDatabase.open(account).use { db ->
                val store = ScoringSyncStore(account, db); val first = store.importConsent(intent)
                val changed = intent.copy(capture = JSONObject(intent.capture!!).put("effectiveDay", "2026-09-19").toString())
                assertTrue(runCatching { store.importConsent(changed) }.isFailure)
                val wrongOwner = intent.copy(intentId = UUID.randomUUID().toString(),
                    capture = JSONObject(intent.capture).put("userID", UUID.randomUUID().toString()).toString())
                assertTrue(runCatching { store.importConsent(wrongOwner) }.isFailure)
                assertEquals(1L, db.dao().entity(first.entityKey)!!.clientRevision)
            }
        }
    }

    @Test fun policyRevokedDuringAuthorizationMakesNoTransportCall() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account(); denial(account, capture(account, f.device))
            var enabled = true; val calls = AtomicInteger(); val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
            val rpc = AccountScoringRpc(account, { "synthetic" }, {
                entered.complete(Unit); release.await(); f.controller.authorizedSession()
            }, ScoringRpcTransport { _, _, _, _ -> calls.incrementAndGet(); error("Revoked transport") })
            ScoringSyncDatabase.open(account).use { db ->
                val coordinator = ScoringInputCoordinator(account, ScoringSyncStore(account, db), rpc, scheduled = {}, canDeliver = { enabled })
                val work = async { coordinator.drain() }
                try {
                    withTimeout(5000) { entered.await() }; enabled = false; release.complete(Unit)
                    withTimeout(5000) { work.await() }
                    assertEquals(0, calls.get()); assertEquals("awaiting_head", db.dao().pending(1).single().state)
                } finally { release.complete(Unit); work.cancelAndJoin() }
            }
        }
    }

    @Test fun cancellationAndRapidEnableCannotCoalesceAwayAnAcceptedDenial() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account(); val frozen = capture(account, f.device)
            val hold = AtomicBoolean(false); val entered = CountDownLatch(1); val release = CountDownLatch(1)
            val consent = ScoringContextConsent(account, capture = {
                if (hold.compareAndSet(true, false)) { entered.countDown(); check(release.await(10, TimeUnit.SECONDS)) }
                frozen
            }, didSave = {})
            consent.setEnabled(ScoringContextPurpose.JOURNAL, true)
            val old = JSONObject().put("consent", consent.decision(ScoringContextPurpose.JOURNAL)!!.payload()).toString()
            hold.set(true)
            val disable = launch { consent.setEnabled(ScoringContextPurpose.JOURNAL, false) }
            assertTrue(entered.await(10, TimeUnit.SECONDS)); disable.cancel()
            val enable = launch { consent.setEnabled(ScoringContextPurpose.JOURNAL, true) }
            try {
                release.countDown()
                withTimeout(10_000) { disable.join(); enable.join() }
                ScoringConsentDatabase.open(account).use { db ->
                    assertEquals(listOf(true, false, true), db.dao().intents().map { it.enabled })
                    assertTrue(db.dao().intents().all { it.state == "local_saved" })
                }
                assertNotNull(consent.decision(ScoringContextPurpose.JOURNAL))
                assertFalse(consent.allows(ScoringContextPurpose.JOURNAL, old))
            } finally { release.countDown(); disable.cancelAndJoin(); enable.cancelAndJoin(); close(consent) }
        }
    }

    @Test fun conflictIsHeldSeparatelyFromLocalDenialAndDoesNotReleaseFollowers() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account(); val intent = denial(account, capture(account, f.device))
            val runtime = ScoringInputRuntime(account, scheduled = {})
            try {
                val later = runtime.captureConfig(config(f.device), "UTC", runtime.captureSource(f.device))
                ScoringSyncDatabase.open(account).use { db ->
                    val store = ScoringSyncStore(account, db)
                    val rpc = f.rpc(account, ScoringRpcTransport { _, _, _, body -> head(f, body, 99) })
                    assertFalse(ScoringInputCoordinator(account, store, rpc, scheduled = {}).drain())
                    assertEquals("waiting_previous", db.dao().mutation(later.mutationId)!!.state)
                    ScoringConsentDatabase.open(account).use { consent ->
                        assertEquals(false, consent.dao().get("journal_context")!!.enabled)
                        val state = consent.dao().intent(intent.intentId)!!
                        assertEquals("conflict_held", state.state); assertNull(state.receipt)
                    }
                }
            } finally { runtime.retire(); runtime.awaitRetirement() }
        }
    }

    @Test fun anotherDeviceAfterMidnightDoesNotRetargetOriginalDenial() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account(); val intent = denial(account, capture(account, f.device))
            val other = UUID.randomUUID().toString()
            val runtime = ScoringInputRuntime(account, scheduled = {})
            try {
                val fresh = runtime.captureConfig(config(other), "Pacific/Kiritimati", runtime.captureSource(other))
                ScoringSyncDatabase.open(account).use { db ->
                    val original = db.dao().mutation(db.dao().consentImport(intent.intentId)!!.mutationId)!!
                    assertEquals(f.device, original.device); assertEquals(other, fresh.device)
                    assertEquals("2026-09-18", JSONObject(original.body).getString("p_effective_day"))
                    assertEquals(f.device, JSONObject(original.body).getJSONObject("p_payload").getString("sourceEra"))
                }
            } finally { runtime.retire(); runtime.awaitRetirement() }
        }
    }
}
