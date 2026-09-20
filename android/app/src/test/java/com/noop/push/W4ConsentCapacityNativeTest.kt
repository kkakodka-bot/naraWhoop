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

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class W4ConsentCapacityNativeTest {
    private fun config(era: String = "synthetic") = ScoringConfigInput(null, "EDWARDS", false, true, false, null, 0, 0, era)
    private fun capture(account: AccountStorageContext, device: String, era: String = "synthetic") = ScoringConsentCapture.capture(
        ScoringInputSource.capture(account, device), config(era), "UTC", Instant.parse("2026-09-18T12:00:00Z"))
    private suspend fun close(consent: ScoringContextConsent) { consent.retire(); consent.awaitRetirement() }
    private fun count(db: androidx.sqlite.db.SupportSQLiteDatabase, sql: String): Long = db.query(sql).use { check(it.moveToFirst()); it.getLong(0) }

    @Test fun countAndByteHistoryDoNotBlockDurableDenialAndAcceptedOriginsNeverBecomeNewChoices() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account()
            // Valid bounded sourceEra with JSON escaping gives >16MiB of immutable captures.
            val frozen = capture(account, f.device, "x" + "\u0001".repeat(511))
            val origins = mutableListOf<Pair<ScoringConsentIntent, ScoringConsentPosition>>()
            ScoringConsentDatabase.open(account).use { consentDb ->
                ScoringSyncDatabase.open(account).use { inputDb ->
                    val store = ScoringSyncStore(account, inputDb)
                    consentDb.runInTransaction {
                        inputDb.runInTransaction {
                            repeat(5000) { i ->
                                val intent = ScoringConsentIntent(intentId = UUID.randomUUID().toString(),
                                    purpose = ScoringContextPurpose.values()[i % 4].wire, enabled = false, decidedAt = i.toLong(),
                                    capture = frozen.json, state = "local_saved")
                                // Seed a valid pre-v3 lifetime history that exceeds today's limits.
                                // Each mutation settled before the next; old origins had no positions.
                                val draft = store.enqueue(ScoringInputKey(f.device, "config", "primary"), null,
                                    "2026-09-18", config("x" + "\u0001".repeat(511)).payload())
                                val ready = store.admitDraft(draft, ScoringInputHead(draft.key(), i.toLong()))
                                val receipt = f.receipt(ready, i + 1L)
                                store.recordReceipt(ready, receipt)
                                val saved = intent.copy(state = "remote_accepted", mutationId = ready.mutationId,
                                    receipt = inputDb.dao().mutation(ready.mutationId)!!.receipt)
                                val sequence = consentDb.dao().intent(saved)
                                val row = saved.copy(sequence = sequence)
                                inputDb.dao().insert(ScoringConsentImport(row.intentId, row.origin(), ready.mutationId))
                                if (i == 0 || i == 4999) origins += row to consentDb.position(row)
                            }
                        }
                    }
                    assertEquals(5000, count(inputDb.openHelper.readableDatabase, "SELECT COUNT(*) FROM consentImport"))
                    assertTrue(count(consentDb.openHelper.readableDatabase, "SELECT SUM(length(CAST(capture AS BLOB))) FROM consentIntent") > 16 * 1024 * 1024)
                    assertTrue(consentDb.dao().relayPage(0).isEmpty())
                }
                // Existing disk grants predate the now-full history. A new grant must not be
                // admitted while full, but revocation still gets the reserved privacy lane.
                val old = ScoringContextPurpose.values().associateWith { purpose ->
                    val id = UUID.randomUUID().toString()
                    consentDb.dao().insert(ScoringConsentRow(purpose.wire, id, true, 1))
                    JSONObject().put("consent", ScoringContextDecision(purpose, id, true, 1).payload()).toString()
                }
                val first = ScoringContextConsent(account, capture = { frozen }, didSave = {})
                consentDb.openHelper.writableDatabase.execSQL("""CREATE TRIGGER fail_denial BEFORE UPDATE ON consentDecision
                    WHEN NEW.enabled=0 BEGIN SELECT RAISE(ABORT,'synthetic decision update failure'); END""")
                ScoringContextPurpose.values().forEach { first.setEnabled(it, false) }
                val barriers = consentDb.dao().barriers().associate { it.purpose to it.intentId }
                assertEquals(4, barriers.size); close(first)
                val fresh = ScoringContextConsent(account, capture = { frozen }, didSave = {})
                try {
                    fresh.load(); assertNotNull(fresh.state.value.error); assertEquals(64, fresh.state.value.relay.size)
                    old.forEach { (purpose, payload) -> assertFalse(fresh.allows(purpose, payload)) }
                    assertTrue(consentDb.dao().all().all { it.enabled })
                    consentDb.openHelper.writableDatabase.execSQL("DROP TRIGGER fail_denial")
                    ScoringContextPurpose.values().forEach { purpose ->
                        fresh.setEnabled(purpose, false)
                        assertEquals(barriers[purpose.wire], consentDb.dao().get(purpose.wire)!!.decisionId)
                        assertFalse(fresh.allows(purpose, old.getValue(purpose)))
                    }
                } finally { close(fresh) }
                repeat(2) {
                    ScoringSyncDatabase.open(account).use { inputDb ->
                        val store = ScoringSyncStore(account, inputDb)
                        ScoringConsentRelay.recoverBefore(account, store) {}
                        val before = inputDb.dao().entity(ScoringInputKey(f.device, "config", "primary").storageKey)!!.clientRevision
                        assertTrue(runCatching { store.importConsent(origins.first().first, origins.first().second) }.exceptionOrNull() is ScoringConsentOriginRetired)
                        assertEquals("settled", store.importConsent(origins.last().first, origins.last().second).state)
                        assertEquals(before, inputDb.dao().entity(ScoringInputKey(f.device, "config", "primary").storageKey)!!.clientRevision)
                        assertEquals(68, count(inputDb.openHelper.readableDatabase, "SELECT COUNT(*) FROM consentImport"))
                        assertEquals(68, consentDb.dao().intents().size)
                    }
                }
            }
        }
    }

    @Test fun saturatedInputAdmissionStillDrainsOlderWorkThenSendsSameDenialBeforeNewConfigAcrossReopen() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account(); val frozen = capture(account, f.device)
            ScoringSyncDatabase.open(account).use { db ->
                val store = ScoringSyncStore(account, db)
                db.runInTransaction {
                    repeat(4096) { i -> store.enqueue(ScoringInputKey(if (i == 0) f.device else UUID.randomUUID().toString(), "config", "primary"),
                        null, "2026-09-17", config().payload()) }
                }
                // Actual production ordinary capacity is full. Denial-control capacity is independent.
            }
            val consent = ScoringContextConsent(account, capture = { frozen }, didSave = {})
            consent.setEnabled(ScoringContextPurpose.JOURNAL, false); assertNull(consent.state.value.error); close(consent)
            val (intent, position) = ScoringConsentDatabase.open(account).use {
                val row = it.dao().intents().single(); row to it.position(row)
            }
            val sent = mutableListOf<String>()
            val requests = mutableListOf<ScoringInputMutation>()
            var deniedMutation: String? = null; var laterMutation: String? = null
            repeat(2) { reopening ->
                ScoringSyncDatabase.open(account).use { db ->
                    val store = ScoringSyncStore(account, db)
                    val coordinator = ScoringInputCoordinator(account, store, rpc(f, account, db, sent, captured = requests), scheduled = {})
                    if (reopening == 0) {
                        assertTrue(runCatching { coordinator.captureConfig(config("newer"), "UTC", ScoringInputSource.capture(account, f.device)) }.isFailure)
                        assertTrue(coordinator.drain()); assertEquals(20, sent.size)
                        deniedMutation = db.dao().consentImport(intent.intentId)!!.mutationId
                        ScoringConsentDatabase.open(account).use {
                            val queued = it.dao().intent(intent.intentId)!!
                            assertEquals(intent.capture, queued.capture); assertEquals(intent.decidedAt, queued.decidedAt)
                            assertEquals("queued", queued.state); assertEquals(deniedMutation, queued.mutationId)
                        }
                        laterMutation = coordinator.captureConfig(config("newer"), "UTC", ScoringInputSource.capture(account, f.device)).mutationId
                        assertEquals("waiting_previous", db.dao().mutation(laterMutation!!)!!.state)
                    } else {
                        var drains = 0
                        while (coordinator.drain()) { check(++drains < 220) }
                        assertEquals(4098, sent.size)
                        assertEquals(1, sent.count { it == deniedMutation })
                        assertTrue(sent.indexOf(deniedMutation) < sent.indexOf(laterMutation))
                        val denialSent = requests.single { it.mutationId == deniedMutation }
                        assertEquals(JSONObject(intent.capture!!).getJSONObject("config").toString(),
                            JSONObject(denialSent.body).getJSONObject("p_payload").toString())
                        assertEquals("2026-09-18", JSONObject(denialSent.body).getString("p_effective_day"))
                        assertNull(db.dao().mutation(deniedMutation!!))
                        assertEquals(0L, db.dao().controlCount())
                        assertEquals("settled", db.dao().mutation(laterMutation!!)!!.state)
                        repeat(2) { coordinator.recoverConsent() }
                        assertNull(db.dao().consentImport(intent.intentId))
                        val revision = db.dao().entity(denialSent.entityKey)!!.clientRevision
                        assertTrue(runCatching { store.importConsent(intent, position) }.exceptionOrNull() is ScoringConsentOriginRetired)
                        assertEquals(revision, db.dao().entity(denialSent.entityKey)!!.clientRevision)
                    }
                }
            }
            ScoringConsentDatabase.open(account).use {
                // The exact receipt handshake frees reserved capacity, including recent controls.
                assertNull(it.dao().intent(intent.intentId))
            }
        }
    }

    @Test fun failedRelayDoesNotDeadlockExistingWorkAndConflictOnlyHoldsItsOwnDevice() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account(); val other = UUID.randomUUID().toString()
            ScoringSyncDatabase.open(account).use { db ->
                val store = ScoringSyncStore(account, db)
                val first = store.enqueue(ScoringInputKey(f.device, "config", "primary"), null, "2026-09-18", config().payload())
                val unrelated = store.enqueue(ScoringInputKey(other, "config", "primary"), null, "2026-09-18", config().payload())
                val consent = ScoringContextConsent(account, didSave = {}) // Missing captured source is a durable explicit hold.
                consent.setEnabled(ScoringContextPurpose.JOURNAL, false); close(consent)
                val sent = mutableListOf<String>()
                val coordinator = ScoringInputCoordinator(account, store, rpc(f, account, db, sent, conflictDevice = f.device), scheduled = {})
                assertFalse(coordinator.drain())
                assertEquals("conflict", db.dao().mutation(first.mutationId)!!.state)
                assertEquals(listOf(unrelated.mutationId), sent)
                assertEquals("settled", db.dao().mutation(unrelated.mutationId)!!.state)
                assertTrue(runCatching { coordinator.captureConfig(config(), "UTC", ScoringInputSource.capture(account, other)) }.exceptionOrNull() is ScoringConsentRelayHeld)
            }
        }
    }

    private fun rpc(f: W4NativeFixture, account: AccountStorageContext, db: ScoringSyncDatabase,
                    sent: MutableList<String>, conflictDevice: String? = null,
                    captured: MutableList<ScoringInputMutation>? = null) = f.rpc(account, ScoringRpcTransport { url, _, _, body ->
        val o = JSONObject(body)
        if (url.endsWith("get_scoring_history_input_head_v3")) {
            val key = ScoringInputKey(o.getString("p_device"), o.getString("p_kind"), o.getString("p_entity"))
            ScoringRpcReply(200, JSONObject().put("schemaVersion", 1).put("userId", f.owner.userID).put("sourceDeviceId", key.device)
                .put("kind", key.kind).put("entity", key.entity).put("headRevision", if (key.device == conflictDevice) 999 else db.dao().entity(key.storageKey)!!.headRevision).toString())
        } else {
            val mutation = db.dao().mutation(o.getString("p_client_mutation_id"))!!
            sent += mutation.mutationId
            captured?.add(mutation)
            ScoringRpcReply(200, f.receipt(mutation, o.getLong("p_expected_revision") + 1))
        }
    })
}
