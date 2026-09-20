package com.noop.push

import android.app.Application
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
class W4ConsentCompactionNativeTest {
    private fun capture(f: W4NativeFixture) = ScoringConsentCapture.capture(
        ScoringInputSource.capture(f.account(), f.device),
        ScoringConfigInput(null, "EDWARDS", false, true, false, null, 0, 0, "synthetic"), "UTC",
        Instant.parse("2026-09-18T12:00:00Z"))

    private suspend fun accept(f: W4NativeFixture, consentDb: ScoringConsentDatabase,
                               store: ScoringSyncStore): Pair<ScoringConsentIntent, ScoringConsentPosition> {
        val choice = ScoringContextConsent(f.account(), capture = { capture(f) }, didSave = {})
        try { choice.setEnabled(ScoringContextPurpose.JOURNAL, false); assertNull(choice.state.value.error) }
        finally { choice.retire(); choice.awaitRetirement() }
        val intent = consentDb.dao().intents().last()
        val position = consentDb.position(intent)
        val draft = store.importConsent(intent, position)
        val head = store.database.dao().entity(draft.entityKey)!!.headRevision
        val request = store.admitDraft(draft, ScoringInputHead(draft.key(), head))
        val receipt = f.receipt(request, head + 1)
        store.recordReceipt(request, receipt)
        consentDb.runInTransaction { consentDb.dao().progress(intent.intentId, "remote_accepted", request.mutationId,
            store.database.dao().mutation(request.mutationId)!!.receipt) }
        return consentDb.dao().intent(intent.intentId)!! to position
    }

    @Test fun crashAfterOriginRetirementBeforeConsentDeletionReopensWithoutReplayOrNewRevision() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account()
            lateinit var original: ScoringConsentIntent
            lateinit var position: ScoringConsentPosition
            ScoringConsentDatabase.open(account).use { consent ->
                ScoringSyncDatabase.open(account).use { db ->
                    val store = ScoringSyncStore(account, db)
                    val saved = accept(f, consent, store); original = saved.first; position = saved.second
                    consent.openHelper.writableDatabase.execSQL("CREATE TRIGGER fail_compaction BEFORE DELETE ON consentIntent BEGIN SELECT RAISE(ABORT,'synthetic power loss'); END")
                    assertTrue(runCatching { ScoringConsentRelay.compactAccepted(consent, store, 0) }.isFailure)
                    assertNull(db.dao().consentImport(original.intentId))
                    assertNull(db.dao().mutation(original.mutationId!!))
                    assertEquals(original, consent.dao().intent(original.intentId)) // Exact durable receipt survives.
                    assertEquals(position.sequence, db.dao().relayPosition()!!.lastSequence)
                }
            }
            ScoringConsentDatabase.open(account).use { consent ->
                ScoringSyncDatabase.open(account).use { db ->
                    val store = ScoringSyncStore(account, db)
                    consent.openHelper.writableDatabase.execSQL("DROP TRIGGER fail_compaction")
                    repeat(2) { ScoringConsentRelay.compactAccepted(consent, store, 0) }
                    assertNull(consent.dao().intent(original.intentId))
                    assertTrue(runCatching { store.importConsent(original, position) }.exceptionOrNull() is ScoringConsentOriginRetired)
                    assertEquals(1L, db.dao().entity(ScoringInputKey(f.device, "config", "primary").storageKey)!!.clientRevision)
                    val next = accept(f, consent, store)
                    assertEquals(position.sourceId, next.second.sourceId)
                    assertTrue(next.second.sequence > position.sequence) // AUTOINCREMENT never resets on compaction.
                    assertEquals(2L, db.dao().mutation(next.first.mutationId!!)!!.clientRevision)
                }
            }
        }
    }

    @Test fun failedOriginDeleteRetainsBothProofsAndForeignSourceCannotRetireOrReplay() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            ScoringConsentDatabase.open(f.account()).use { consent ->
                ScoringSyncDatabase.open(f.account()).use { db ->
                    val store = ScoringSyncStore(f.account(), db)
                    val (intent, position) = accept(f, consent, store)
                    db.openHelper.writableDatabase.execSQL("CREATE TRIGGER fail_origin BEFORE DELETE ON consentImport BEGIN SELECT RAISE(ABORT,'synthetic failure'); END")
                    assertTrue(runCatching { ScoringConsentRelay.compactAccepted(consent, store, 0) }.isFailure)
                    assertNotNull(db.dao().consentImport(intent.intentId)); assertNotNull(db.dao().mutation(intent.mutationId!!))
                    assertEquals(intent, consent.dao().intent(intent.intentId))
                    val foreign = position.copy(sourceId = UUID.randomUUID().toString())
                    assertTrue(runCatching { store.retireConsent(intent, foreign) }.isFailure)
                    assertTrue(runCatching { store.importConsent(intent, foreign) }.isFailure)
                    assertTrue(runCatching { store.retireConsent(intent.copy(receipt = "{}"), position) }.isFailure)
                    db.openHelper.writableDatabase.execSQL("DROP TRIGGER fail_origin")
                    ScoringConsentRelay.compactAccepted(consent, store, 0)
                    assertTrue(consent.dao().intents().isEmpty()); assertEquals(0L, db.dao().consentCount())
                }
            }
        }
    }

    @Test fun fullHistoryAndReservedDebtNeverReopenOldGrantOnFreshRuntime() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account(); val frozen = capture(f)
            ScoringConsentDatabase.open(account).use { db ->
                val old = ScoringContextPurpose.values().associateWith { purpose ->
                    val id = UUID.randomUUID().toString()
                    db.dao().insert(ScoringConsentRow(purpose.wire, id, true, 1))
                    JSONObject().put("consent", ScoringContextDecision(purpose, id, true, 1).payload()).toString()
                }
                db.runInTransaction {
                    repeat(4096) { db.dao().intent(ScoringConsentIntent(intentId = UUID.randomUUID().toString(),
                        purpose = ScoringContextPurpose.JOURNAL.wire, enabled = false, decidedAt = 1,
                        capture = frozen.json, state = "local_saved")) }
                }
                val first = ScoringContextConsent(account, capture = { frozen }, didSave = {})
                try {
                    first.load()
                    // Refused grants still pause each purpose BEFORE the history-cap check.
                    for (purpose in ScoringContextPurpose.values()) {
                        first.setEnabled(purpose, true); assertNotNull(first.state.value.error)
                    }
                } finally { first.retire(); first.awaitRetirement() }
                assertEquals(4096, db.dao().intents().size); assertEquals(4, db.dao().pauses().size)
                val reopened = ScoringContextConsent(account, capture = { frozen }, didSave = {})
                try {
                    reopened.load(); old.forEach { (p, payload) -> assertFalse(reopened.allows(p, payload)) }
                    for (purpose in ScoringContextPurpose.values()) {
                        reopened.setEnabled(purpose, false)
                        assertEquals(1L, db.dao().reservedCount(purpose.wire))
                    }
                    val retained = db.dao().intents().filter { it.reserved }
                    // Another transition cannot replace any immutable overflow denial.
                    for (purpose in ScoringContextPurpose.values()) reopened.setEnabled(purpose, false)
                    assertEquals(retained, db.dao().intents().filter { it.reserved })
                    assertEquals(4100, db.dao().intents().size); assertEquals(4, db.dao().pauses().size)
                } finally { reopened.retire(); reopened.awaitRetirement() }
                val last = ScoringContextConsent(account, didSave = {})
                try { last.load(); old.forEach { (p, payload) -> assertFalse(last.allows(p, payload)) } }
                finally { last.retire(); last.awaitRetirement() }
            }
        }
    }

    @Test fun failedDecisionRemainsPausedAfterAcceptedIntentCompacts() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            ScoringConsentDatabase.open(f.account()).use { consent ->
                ScoringSyncDatabase.open(f.account()).use { db ->
                    val store = ScoringSyncStore(f.account(), db)
                    val (intent, _) = accept(f, consent, store)
                    val old = ScoringConsentRow(ScoringContextPurpose.JOURNAL.wire, UUID.randomUUID().toString(), true, 0)
                    consent.dao().update(old)
                    consent.dao().pause(ScoringConsentPause(old.purpose, intent.intentId, intent.decidedAt))
                    ScoringConsentRelay.compactAccepted(consent, store, 0)
                    assertTrue(consent.dao().intents().isEmpty())
                    val fresh = ScoringContextConsent(f.account(), didSave = {})
                    try { fresh.load(); assertNull(fresh.decision(ScoringContextPurpose.JOURNAL)); assertNotNull(fresh.state.value.error) }
                    finally { fresh.retire(); fresh.awaitRetirement() }
                }
            }
        }
    }

    @Test fun byteCapacityPausesBeforeRefusalAndRetainsBoundedTypedReceiptProofOnly(): Unit = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val frozen = capture(f)
            ScoringConsentDatabase.open(f.account()).use { consent ->
                // A pre-upgrade, oversized lifetime capture store must still permit a denial.
                val larger = JSONObject(frozen.json).put("syntheticExtension", "x".repeat(64 * 1024)).toString()
                consent.runInTransaction {
                    repeat(257) { consent.dao().intent(ScoringConsentIntent(intentId = UUID.randomUUID().toString(),
                        purpose = ScoringContextPurpose.JOURNAL.wire, enabled = false, decidedAt = 1,
                        capture = larger, state = "local_saved")) }
                    consent.dao().insert(ScoringConsentRow(ScoringContextPurpose.CYCLE.wire, UUID.randomUUID().toString(), true, 1))
                }
                assertTrue(consent.dao().ordinaryCount() < ScoringConsentLimits.ROWS)
                assertTrue(consent.dao().ordinaryBytes() > ScoringConsentLimits.BYTES)
                val choice = ScoringContextConsent(f.account(), capture = { frozen }, didSave = {})
                try {
                    choice.setEnabled(ScoringContextPurpose.CYCLE, true)
                    assertNotNull(choice.state.value.error); assertEquals(1, consent.dao().pauses().size)
                    choice.setEnabled(ScoringContextPurpose.CYCLE, false)
                    assertEquals(1L, consent.dao().reservedCount(ScoringContextPurpose.CYCLE.wire))
                } finally { choice.retire(); choice.awaitRetirement() }
                ScoringSyncDatabase.open(f.account()).use { db ->
                    val store = ScoringSyncStore(f.account(), db)
                    val key = ScoringInputKey(f.device, "config", "primary")
                    val payload = JSONObject(frozen.json).getJSONObject("config").toString()
                    val request = store.enqueue(key, ScoringInputHead(key, 0), "2026-09-18", payload)
                    val largeAck = JSONObject(f.receipt(request)).put("unrecognizedExtension", "x".repeat(2 * 1024 * 1024)).toString()
                    store.recordReceipt(request, largeAck)
                    val proof = db.dao().mutation(request.mutationId)!!.receipt!!
                    assertFalse(JSONObject(proof).has("unrecognizedExtension")); assertTrue(proof.toByteArray().size < 1024)
                    store.recordReceipt(request, f.receipt(request)) // Same typed proof remains idempotent.
                }
            }
        }
    }
}
