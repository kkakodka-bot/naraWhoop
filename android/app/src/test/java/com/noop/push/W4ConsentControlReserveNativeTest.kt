package com.noop.push

import android.app.Application
import com.noop.account.AccountStorageContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.time.Instant
import java.util.UUID

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class W4ConsentControlReserveNativeTest {
    private fun config() = ScoringConfigInput(null, "EDWARDS", false, true, false, null, 0, 0, "synthetic")
    private suspend fun deny(f: W4NativeFixture, purpose: ScoringContextPurpose = ScoringContextPurpose.JOURNAL): ScoringConsentIntent {
        val account = f.account()
        val frozen = ScoringConsentCapture.capture(ScoringInputSource.capture(account, f.device), config(), "UTC",
            Instant.parse("2026-09-18T12:00:00Z"))
        val choice = ScoringContextConsent(account, capture = { frozen }, didSave = {})
        try { choice.setEnabled(purpose, false); assertNull(choice.state.value.error) }
        finally { choice.retire(); choice.awaitRetirement() }
        return ScoringConsentDatabase.open(account).use { it.dao().intents().last() }
    }
    private fun seedHeld(store: ScoringSyncStore, count: Int, bodyBytes: Int? = null): List<ScoringInputMutation> {
        // Android has no active sensitive-input producer. Supported conflict-held profile rows
        // exercise the same no-eligible-work capacity boundary without enabling any producer.
        val held = mutableListOf<ScoringInputMutation>()
        store.database.runInTransaction {
            repeat(count) {
                val key = ScoringInputKey(UUID.randomUUID().toString(), "profile", "primary")
                var payload = "{\"schemaVersion\":1}"
                if (bodyBytes != null) {
                    val client = store.database.dao().client() ?: ScoringSyncClient(clientId = UUID.randomUUID().toString()).also(store.database.dao()::insert)
                    val p = JSONObject().put("schemaVersion", 1).put("padding", "")
                    val prototype = key.rpc().put("p_effective_day", "2026-09-18").put("p_payload", p)
                        .put("p_expected_revision", 0).put("p_deleted", false).put("p_client_id", client.clientId)
                        .put("p_client_mutation_id", UUID.randomUUID().toString()).put("p_client_revision", 1)
                    payload = p.put("padding", "x".repeat(bodyBytes - SyncJson.canonical(prototype).toByteArray().size)).toString()
                }
                val row = store.enqueue(key, ScoringInputHead(key, 0), "2026-09-18", payload)
                bodyBytes?.let { assertEquals(it, row.body.toByteArray().size) }
                store.retainFailure(row, "conflict")
                held += store.database.dao().mutation(row.mutationId)!!
            }
        }
        return held
    }
    private fun coordinator(f: W4NativeFixture, account: AccountStorageContext, store: ScoringSyncStore,
                            sent: MutableList<ScoringInputMutation>) = ScoringInputCoordinator(account, store,
        f.rpc(account, ScoringRpcTransport { url, _, _, body ->
            val o = JSONObject(body)
            if (url.endsWith("get_scoring_history_input_head_v3")) ScoringRpcReply(200, JSONObject()
                .put("schemaVersion", 1).put("userId", f.owner.userID).put("sourceDeviceId", o.getString("p_device"))
                .put("kind", o.getString("p_kind")).put("entity", o.getString("p_entity"))
                .put("headRevision", store.database.dao().entity(ScoringInputKey(o.getString("p_device"), o.getString("p_kind"), o.getString("p_entity")).storageKey)!!.headRevision).toString())
            else {
                val request = store.database.dao().mutation(o.getString("p_client_mutation_id"))!!
                sent += request
                ScoringRpcReply(200, f.receipt(request, o.getLong("p_expected_revision") + 1))
            }
        }), scheduled = {})

    private suspend fun boundary(count: Int) {
        W4NativeFixture().use { f ->
            val account = f.account(); val held = ScoringSyncDatabase.open(account).use { seedHeld(ScoringSyncStore(account, it), count) }
            val denial = deny(f); val sent = mutableListOf<ScoringInputMutation>()
            repeat(3) {
                ScoringSyncDatabase.open(account).use { db ->
                    val store = ScoringSyncStore(account, db)
                    coordinator(f, account, store, sent).drain()
                    held.forEach { assertEquals("Held debt must never change", it, db.dao().mutation(it.mutationId)) }
                    assertEquals(count.toLong(), db.dao().pendingCount())
                }
            }
            println("ANDROID_HELD_CAPACITY queue=$count rounds=3 sends=${sent.size}")
            assertEquals("The captured denial must settle even when no ordinary row can drain", 1, sent.size)
            assertEquals(f.device, sent.single().device); assertEquals("config", sent.single().kind)
            assertEquals(JSONObject(denial.capture!!).getJSONObject("config").toString(), JSONObject(sent.single().body).getJSONObject("p_payload").toString())
        }
    }
    @Test fun fullHeldQueueStillSettlesCapturedDenialAcrossReopen(): Unit = runBlocking(Dispatchers.IO) { boundary(4096) }
    @Test fun oneFreeSlotRemainsPositiveControl(): Unit = runBlocking(Dispatchers.IO) { boundary(4095) }

    @Test fun fullHeldByteBudgetAdmitsAllFourDenialsAndKeepsEveryHeldByteAcrossPartialReopen(): Unit = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account()
            val held = ScoringSyncDatabase.open(account).use { db ->
                seedHeld(ScoringSyncStore(account, db), 256, 65536).also { assertEquals(16L * 1024 * 1024, db.dao().pendingBytes()) }
            }
            val denials = ScoringContextPurpose.values().map { deny(f, it) }
            val positions = ScoringConsentDatabase.open(account).use { db -> denials.associate { it.intentId to db.position(it) } }
            val sent = mutableListOf<ScoringInputMutation>()
            lateinit var captured: List<ScoringInputMutation>
            ScoringSyncDatabase.open(account).use { db ->
                val store = ScoringSyncStore(account, db)
                val inputs = coordinator(f, account, store, sent)
                inputs.recoverConsent()
                captured = denials.map { db.dao().mutation(db.dao().consentImport(it.intentId)!!.mutationId)!! }
                assertEquals(4L, db.dao().controlCount()); assertEquals(256L, db.dao().ordinaryPendingCount())
                assertEquals(16L * 1024 * 1024, db.dao().ordinaryPendingBytes())
                assertTrue(db.dao().controlBytes() in 1..ScoringConsentControlLimits.TOTAL_BYTES)
                val extra = ScoringInputKey(UUID.randomUUID().toString(), "config", "primary")
                assertTrue(runCatching { store.enqueue(extra, null, "2026-09-18", config().payload()) }.exceptionOrNull() is ScoringConsentCapacity)
                inputs.drain(); assertEquals(1, sent.size)
                assertEquals(3L, db.dao().controlCount()) // Recent-receipt retention cannot hold a control slot.
                held.forEach { assertEquals(it, db.dao().mutation(it.mutationId)) }
            }
            repeat(4) {
                ScoringSyncDatabase.open(account).use { db ->
                    val store = ScoringSyncStore(account, db)
                    coordinator(f, account, store, sent).drain()
                    held.forEach { assertEquals(it, db.dao().mutation(it.mutationId)) }
                }
            }
            assertEquals(captured.map { it.mutationId }, sent.map { it.mutationId })
            assertEquals(captured.map { it.clientRevision }, sent.map { it.clientRevision })
            assertEquals(captured.map { JSONObject(it.body).getJSONObject("p_payload").toString() }, sent.map { JSONObject(it.body).getJSONObject("p_payload").toString() })
            ScoringSyncDatabase.open(account).use { db ->
                assertEquals(0L, db.dao().controlCount()); assertEquals(256L, db.dao().pendingCount())
                val store = ScoringSyncStore(account, db)
                denials.forEach { assertTrue(runCatching { store.importConsent(it, positions.getValue(it.intentId)) }.exceptionOrNull() is ScoringConsentOriginRetired) }
            }
            ScoringConsentDatabase.open(account).use { db -> denials.forEach { assertNull(db.dao().intent(it.intentId)) } }
        }
    }

    @Test fun reserveRemainsBoundedThroughSettlementAndFailedRetirementCommit(): Unit = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account()
            ScoringSyncDatabase.open(account).use { seedHeld(ScoringSyncStore(account, it), 4096) }
            val denials = ScoringContextPurpose.values().map { deny(f, it) }
            val positions = ScoringConsentDatabase.open(account).use { db -> denials.associate { it.intentId to db.position(it) } }
            lateinit var first: ScoringConsentIntent
            lateinit var extra: ScoringConsentIntent
            lateinit var extraPosition: ScoringConsentPosition
            lateinit var originalSlots: List<ScoringConsentControl>
            ScoringSyncDatabase.open(account).use { db ->
                val store = ScoringSyncStore(account, db)
                val mutations = denials.map { store.importConsent(it, positions.getValue(it.intentId)) }
                originalSlots = db.dao().controls()
                assertEquals(4, originalSlots.size); assertTrue(db.dao().controlBytes() <= ScoringConsentControlLimits.TOTAL_BYTES)
                extra = deny(f); extraPosition = ScoringConsentDatabase.open(account).use { it.position(extra) }
                repeat(2) { assertTrue(runCatching { store.importConsent(extra, extraPosition) }.exceptionOrNull() is ScoringConsentCapacity) }
                val grant = extra.copy(intentId = UUID.randomUUID().toString(), enabled = true, sequence = extra.sequence + 1)
                assertTrue(runCatching { store.importConsent(grant, extraPosition.copy(sequence = grant.sequence)) }.exceptionOrNull() is ScoringConsentCapacity)
                assertEquals(mutations[0], store.importConsent(denials[0], positions.getValue(denials[0].intentId)))
                assertEquals(originalSlots, db.dao().controls())
                val request = store.admitDraft(mutations[0], ScoringInputHead(mutations[0].key(), 0))
                store.recordReceipt(request, f.receipt(request, 1))
                assertEquals(originalSlots, db.dao().controls())
                ScoringConsentDatabase.open(account).use { consent ->
                    consent.runInTransaction { consent.dao().progress(denials[0].intentId, "remote_accepted", request.mutationId, db.dao().mutation(request.mutationId)!!.receipt) }
                    first = consent.dao().intent(denials[0].intentId)!!
                }
                assertTrue(runCatching { store.importConsent(extra, extraPosition) }.exceptionOrNull() is ScoringConsentCapacity)
                assertTrue(runCatching { db.runInTransaction {
                    store.retireConsent(first, positions.getValue(first.intentId)); db.retireWrites()
                } }.isFailure)
            }
            ScoringSyncDatabase.open(account).use { db ->
                assertEquals(originalSlots, db.dao().controls()) // Actual precommit retirement rolled back deletion.
                val store = ScoringSyncStore(account, db)
                repeat(2) { store.retireConsent(first, positions.getValue(first.intentId)) }
                assertEquals(3L, db.dao().controlCount())
                val admitted = store.importConsent(extra, extraPosition)
                assertEquals("waiting_previous", admitted.state)
                assertEquals(4L, db.dao().controlCount())
                assertTrue(runCatching { store.importConsent(denials[0], positions.getValue(first.intentId)) }.exceptionOrNull() is ScoringConsentOriginRetired)
                assertEquals(4096L, db.dao().ordinaryPendingCount())
            }
        }
    }

    @Test fun sameEntityConflictIsNotRebasedOrBypassedByControlAdmission(): Unit = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account(); lateinit var prior: ScoringInputMutation
            ScoringSyncDatabase.open(account).use { db ->
                val store = ScoringSyncStore(account, db); seedHeld(store, 4095)
                val key = ScoringInputKey(f.device, "config", "primary")
                val request = store.enqueue(key, ScoringInputHead(key, 0), "2026-09-17", config().payload())
                store.retainFailure(request, "conflict"); prior = db.dao().mutation(request.mutationId)!!
            }
            val denial = deny(f); val sent = mutableListOf<ScoringInputMutation>()
            var first: ScoringInputMutation? = null
            repeat(3) {
                ScoringSyncDatabase.open(account).use { db ->
                    val store = ScoringSyncStore(account, db)
                    coordinator(f, account, store, sent).drain()
                    assertEquals(prior, db.dao().mutation(prior.mutationId))
                    val pending = db.dao().mutation(db.dao().consentImport(denial.intentId)!!.mutationId)!!
                    assertEquals("waiting_previous", pending.state)
                    if (first == null) first = pending else assertEquals(first, pending)
                    assertEquals(1L, db.dao().controlCount()); assertEquals(4096L, db.dao().ordinaryPendingCount())
                }
            }
            assertTrue(sent.isEmpty())
        }
    }

    @Test fun controlPayloadAndEnvelopeHaveIndependentByteBounds(): Unit = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account()
            ScoringSyncDatabase.open(account).use { db ->
                val store = ScoringSyncStore(account, db); seedHeld(store, 4096)
                val base = deny(f)
                ScoringConsentDatabase.open(account).use { consent ->
                    for ((payloadPadding, envelopePadding) in listOf(70000 to 0, 30000 to 80000)) {
                        val captured = JSONObject(base.capture!!)
                        captured.getJSONObject("config").put("padding", "x".repeat(payloadPadding))
                        captured.put("outerPadding", "x".repeat(envelopePadding))
                        val intent = base.copy(sequence = 0, intentId = UUID.randomUUID().toString(), capture = captured.toString())
                        val row = intent.copy(sequence = consent.dao().intent(intent))
                        assertTrue(runCatching { store.importConsent(row, consent.position(row)) }.exceptionOrNull() is ScoringConsentCapacity)
                        assertEquals(0L, db.dao().controlCount()); assertNull(db.dao().consentImport(row.intentId))
                    }
                }
            }
        }
    }

    @Test fun receiptCopyAndDeletionCrashesKeepSlotUntilProofThenRecoverWithoutResend(): Unit = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account()
            val held = ScoringSyncDatabase.open(account).use { seedHeld(ScoringSyncStore(account, it), 4096) }
            val denial = deny(f); val sent = mutableListOf<ScoringInputMutation>()
            lateinit var queued: ScoringInputMutation
            ScoringConsentDatabase.open(account).use { consent ->
                consent.openHelper.writableDatabase.execSQL("CREATE TRIGGER reject_queue BEFORE UPDATE ON consentIntent WHEN NEW.state='queued' BEGIN SELECT RAISE(ABORT,'synthetic progress loss'); END")
                ScoringSyncDatabase.open(account).use { db ->
                    val store = ScoringSyncStore(account, db)
                    assertTrue(runCatching { coordinator(f, account, store, sent).recoverConsent() }.isFailure)
                    queued = db.dao().mutation(db.dao().consentImport(denial.intentId)!!.mutationId)!!
                    assertEquals(denial.intentId, db.dao().controls().single().intentId)
                }
                consent.openHelper.writableDatabase.execSQL("DROP TRIGGER reject_queue")
                consent.openHelper.writableDatabase.execSQL("CREATE TRIGGER reject_receipt_copy BEFORE UPDATE ON consentIntent WHEN NEW.state='remote_accepted' BEGIN SELECT RAISE(ABORT,'synthetic receipt loss'); END")
                ScoringSyncDatabase.open(account).use { db ->
                    val store = ScoringSyncStore(account, db)
                    assertTrue(coordinator(f, account, store, sent).drain())
                    assertEquals(listOf(queued.mutationId), sent.map { it.mutationId })
                    assertEquals(1L, db.dao().controlCount()); assertEquals("queued", consent.dao().intent(denial.intentId)!!.state)
                }
                consent.openHelper.writableDatabase.execSQL("DROP TRIGGER reject_receipt_copy")
                consent.openHelper.writableDatabase.execSQL("CREATE TRIGGER reject_delete BEFORE DELETE ON consentIntent BEGIN SELECT RAISE(ABORT,'synthetic consent deletion loss'); END")
                ScoringSyncDatabase.open(account).use { db ->
                    val store = ScoringSyncStore(account, db)
                    assertTrue(runCatching { coordinator(f, account, store, sent).recoverConsent() }.isFailure)
                    assertEquals(0L, db.dao().controlCount()); assertNull(db.dao().consentImport(denial.intentId))
                    assertEquals("remote_accepted", consent.dao().intent(denial.intentId)!!.state)
                }
                consent.openHelper.writableDatabase.execSQL("DROP TRIGGER reject_delete")
                ScoringSyncDatabase.open(account).use { db ->
                    val store = ScoringSyncStore(account, db)
                    repeat(2) { assertFalse(coordinator(f, account, store, sent).drain()) }
                    assertNull(consent.dao().intent(denial.intentId)); assertEquals(1, sent.size)
                    held.forEach { assertEquals(it, db.dao().mutation(it.mutationId)) }
                }
            }
        }
    }

    @Test fun reservedAdmissionRollsBackOriginFailureAndRetiredPrecommitAndCannotFundConflictReplacement(): Unit = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account()
            val held = ScoringSyncDatabase.open(account).use { seedHeld(ScoringSyncStore(account, it), 4096) }
            val denial = deny(f)
            val position = ScoringConsentDatabase.open(account).use { it.position(denial) }
            val key = ScoringInputKey(f.device, "config", "primary")
            ScoringSyncDatabase.open(account).use { db ->
                val store = ScoringSyncStore(account, db)
                db.openHelper.writableDatabase.execSQL("CREATE TRIGGER reject_origin BEFORE INSERT ON consentImport BEGIN SELECT RAISE(ABORT,'synthetic reserved origin failure'); END")
                assertTrue(runCatching { store.importConsent(denial, position) }.isFailure)
                assertEquals(0L, db.dao().controlCount()); assertNull(db.dao().consentImport(denial.intentId))
                assertNull(db.dao().relayPosition()); assertNull(db.dao().entity(key.storageKey))
                db.openHelper.writableDatabase.execSQL("DROP TRIGGER reject_origin")
                assertTrue(runCatching { db.runInTransaction {
                    store.importConsent(denial, position)
                    assertEquals(1L, db.dao().controlCount())
                    db.retireWrites()
                } }.isFailure)
            }
            ScoringSyncDatabase.open(account).use { db ->
                val store = ScoringSyncStore(account, db)
                assertEquals(0L, db.dao().controlCount()); assertNull(db.dao().consentImport(denial.intentId))
                assertNull(db.dao().relayPosition()); assertNull(db.dao().entity(key.storageKey))
                val draft = store.importConsent(denial, position)
                assertEquals(1L, draft.clientRevision)
                val pending = store.admitDraft(draft, ScoringInputHead(key, 0))
                store.retainFailure(pending, "conflict")
                val conflict = db.dao().mutation(pending.mutationId)!!
                assertTrue(runCatching { store.enqueue(key, ScoringInputHead(key, 1), "2026-09-18", config().payload(),
                    resolving = conflict.mutationId) }.exceptionOrNull() is ScoringConsentCapacity)
                assertEquals(conflict, db.dao().mutation(conflict.mutationId))
                assertEquals(1L, db.dao().entity(key.storageKey)!!.clientRevision)
                assertEquals(1L, db.dao().controlCount())
                held.forEach { assertEquals(it, db.dao().mutation(it.mutationId)) }
            }
        }
    }

    @Test fun legacyOriginCapacityCannotConsumeControlReserveOrOrdinaryPendingCapacity(): Unit = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account()
            val originals = mutableListOf<Pair<ScoringConsentImport, ScoringInputMutation>>()
            ScoringSyncDatabase.open(account).use { db ->
                val store = ScoringSyncStore(account, db)
                db.runInTransaction {
                    repeat(4096) {
                        val key = ScoringInputKey(UUID.randomUUID().toString(), "config", "primary")
                        val mutation = store.enqueue(key, ScoringInputHead(key, 0), "2026-09-17", config().payload())
                        store.recordReceipt(mutation, f.receipt(mutation, 1))
                        // Synthetic pre-position accepted origins, not server-backed history claims.
                        val origin = ScoringConsentImport(UUID.randomUUID().toString(), "{}", mutation.mutationId)
                        db.dao().insert(origin)
                        originals += origin to db.dao().mutation(mutation.mutationId)!!
                    }
                }
            }
            val denials = ScoringContextPurpose.values().map { deny(f, it) }
            val sent = mutableListOf<ScoringInputMutation>()
            ScoringSyncDatabase.open(account).use { db ->
                val store = ScoringSyncStore(account, db)
                val inputs = coordinator(f, account, store, sent)
                inputs.recoverConsent()
                assertEquals(4L, db.dao().controlCount())
                assertEquals(4096L, db.dao().ordinaryConsentCount()); assertEquals(0L, db.dao().ordinaryPendingCount())
                val grant = denials.last().copy(intentId = UUID.randomUUID().toString(), enabled = true, sequence = denials.last().sequence + 1)
                val position = ScoringConsentDatabase.open(account).use { it.position(denials.last()) }.copy(sequence = grant.sequence)
                assertTrue(runCatching { store.importConsent(grant, position) }.exceptionOrNull() is ScoringConsentCapacity)
                val profile = store.enqueue(ScoringInputKey(UUID.randomUUID().toString(), "profile", "primary"),
                    null, "2026-09-18", f.profile().payload())
                repeat(5) { inputs.drain() }
                assertEquals(5, sent.size); assertEquals(1, sent.count { it.mutationId == profile.mutationId })
                assertEquals(0L, db.dao().controlCount()); assertEquals(4096L, db.dao().ordinaryConsentCount())
                originals.forEach { (origin, mutation) ->
                    assertEquals(origin, db.dao().consentImport(origin.intentId))
                    assertEquals(mutation, db.dao().mutation(mutation.mutationId))
                }
            }
        }
    }
}
