package com.noop.push

import android.app.Application
import android.database.sqlite.SQLiteDatabase
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
class W4ConsentRelayMigrationNativeTest {
    private fun legacy(account: AccountStorageContext, name: String, version: Int = 1, create: (SQLiteDatabase) -> Unit) {
        val path = account.getDatabasePath(name); path.parentFile!!.mkdirs()
        SQLiteDatabase.openOrCreateDatabase(path, null).use { db ->
            db.execSQL("CREATE TABLE localAccountOwner(singleton INTEGER PRIMARY KEY CHECK(singleton=1),projectURL TEXT NOT NULL,userID TEXT NOT NULL)")
            val owner = account.identity.scope!!
            db.execSQL("INSERT INTO localAccountOwner VALUES(1,?,?)", arrayOf(owner.projectURL, owner.userID))
            create(db)
            db.version = version
        }
    }

    @Test fun consentVersionOneMigratesWithoutInventingIntentOrChangingPriorChoice() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account(); val id = UUID.randomUUID().toString()
            legacy(account, "scoring_context_consent.sqlite") { db ->
                db.execSQL("CREATE TABLE consentDecision(purpose TEXT NOT NULL PRIMARY KEY,decisionId TEXT NOT NULL,enabled INTEGER NOT NULL,decidedAt INTEGER NOT NULL)")
                db.execSQL("INSERT INTO consentDecision VALUES('journal_context',?,1,123)", arrayOf(id))
            }
            ScoringConsentDatabase.open(account).use { db ->
                assertEquals(ScoringConsentRow("journal_context", id, true, 123), db.dao().get("journal_context"))
                assertTrue(db.dao().intents().isEmpty()); assertTrue(db.dao().barriers().isEmpty())
                assertEquals(3, db.openHelper.readableDatabase.version)
            }
        }
    }

    @Test fun inputVersionOneMigratesWithoutChangingExistingMutationOrClientRevision() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account(); val mutation = UUID.randomUUID().toString(); val client = UUID.randomUUID().toString()
            val key = f.key().storageKey
            legacy(account, "server_sync.sqlite") { db ->
                db.execSQL("CREATE TABLE snapshotV2(cacheKey TEXT NOT NULL PRIMARY KEY,day TEXT NOT NULL,timezone TEXT NOT NULL,sourceDeviceId TEXT NOT NULL,algorithmVersion TEXT NOT NULL,inputRevision INTEGER NOT NULL,resultRevision INTEGER NOT NULL,body TEXT NOT NULL,fetchedAt INTEGER NOT NULL)")
                db.execSQL("CREATE TABLE snapshotSelection(selectionKey TEXT NOT NULL PRIMARY KEY,cacheKey TEXT NOT NULL)")
                db.execSQL("CREATE TABLE historyEntity(entityKey TEXT NOT NULL PRIMARY KEY,clientRevision INTEGER NOT NULL,headRevision INTEGER NOT NULL,earliestDay TEXT NOT NULL,originalStart INTEGER,originalEnd INTEGER)")
                db.execSQL("CREATE TABLE historyMutation(mutationId TEXT NOT NULL PRIMARY KEY,entityKey TEXT NOT NULL,device TEXT NOT NULL,kind TEXT NOT NULL,entity TEXT NOT NULL,clientRevision INTEGER NOT NULL,body TEXT NOT NULL,state TEXT NOT NULL,receipt TEXT,createdAt INTEGER NOT NULL)")
                db.execSQL("CREATE INDEX index_historyMutation_entityKey ON historyMutation(entityKey)")
                db.execSQL("CREATE TABLE syncClient(singleton INTEGER NOT NULL PRIMARY KEY,clientId TEXT NOT NULL)")
                db.execSQL("INSERT INTO syncClient VALUES(1,?)", arrayOf(client))
                db.execSQL("INSERT INTO historyEntity VALUES(?,7,2,'2026-09-18',NULL,NULL)", arrayOf(key))
                db.execSQL("INSERT INTO historyMutation VALUES(?,?,?,'profile','primary',7,'{\"synthetic\":true}','pending',NULL,123)", arrayOf(mutation, key, f.device))
            }
            ScoringSyncDatabase.open(account).use { db ->
                assertEquals(4, db.openHelper.readableDatabase.version)
                assertEquals(7L, db.dao().entity(key)!!.clientRevision)
                assertEquals("{\"synthetic\":true}", db.dao().mutation(mutation)!!.body)
                assertEquals(client, db.dao().client()!!.clientId)
                assertNull(db.dao().consentImport(UUID.randomUUID().toString()))
            }
        }
    }

    @Test fun versionTwoFailedRevokeMigratesPauseAndKeepsAutoincrementAndSourceAcrossReopen() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account(); val old = UUID.randomUUID().toString(); val denial = UUID.randomUUID().toString()
            legacy(account, "scoring_context_consent.sqlite", 2) { db ->
                db.execSQL("CREATE TABLE consentDecision(purpose TEXT NOT NULL PRIMARY KEY,decisionId TEXT NOT NULL,enabled INTEGER NOT NULL,decidedAt INTEGER NOT NULL)")
                db.execSQL("CREATE TABLE consentIntent(sequence INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,intentId TEXT NOT NULL,purpose TEXT NOT NULL,enabled INTEGER NOT NULL,decidedAt INTEGER NOT NULL,capture TEXT,state TEXT NOT NULL,mutationId TEXT,receipt TEXT)")
                db.execSQL("CREATE UNIQUE INDEX index_consentIntent_intentId ON consentIntent(intentId)")
                db.execSQL("CREATE TABLE consentBarrier(purpose TEXT NOT NULL PRIMARY KEY,intentId TEXT NOT NULL)")
                db.execSQL("INSERT INTO consentDecision VALUES('journal_context',?,1,10)", arrayOf(old))
                db.execSQL("INSERT INTO consentIntent VALUES(91,?,'journal_context',0,20,NULL,'prepared',NULL,NULL)", arrayOf(denial))
                db.execSQL("INSERT INTO consentBarrier VALUES('journal_context',?)", arrayOf(denial))
            }
            val source = ScoringConsentDatabase.open(account).use { db ->
                assertEquals(ScoringConsentPause("journal_context", denial, 20), db.dao().pauses().single())
                assertEquals(91L, db.dao().intent(denial)!!.sequence)
                assertFalse(db.dao().intent(denial)!!.reserved)
                db.ensureSource()
            }
            val runtime = ScoringContextConsent(account, didSave = {})
            try { runtime.load(); assertNull(runtime.decision(ScoringContextPurpose.JOURNAL)); assertNotNull(runtime.state.value.error) }
            finally { runtime.retire(); runtime.awaitRetirement() }
            ScoringConsentDatabase.open(account).use { db ->
                assertEquals(source, db.ensureSource())
                assertEquals(92L, db.dao().intent(ScoringConsentIntent(intentId = UUID.randomUUID().toString(),
                    purpose = "cycle_context", enabled = false, decidedAt = 30, capture = null, state = "local_saved")))
            }
        }
    }

    @Test fun versionTwoInputOriginSurvivesUpgradeWithoutInventingPositionOrNewMutation() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account(); val id = UUID.randomUUID().toString(); val mutation = UUID.randomUUID().toString()
            val schema = org.json.JSONObject(java.io.File(System.getProperty("room.schemaLocation"),
                "com.noop.push.ScoringSyncDatabase/4.json").readText()).getJSONObject("database")
            legacy(account, "server_sync.sqlite", 2) { db ->
                val entities = schema.getJSONArray("entities")
                for (i in 0 until entities.length()) {
                    val entity = entities.getJSONObject(i); val name = entity.getString("tableName")
                    if (name in setOf("consentRelayPosition", "consentControl")) continue
                    var create = entity.getString("createSql").replace("\${TABLE_NAME}", name)
                    if (name == "consentImport") create = create.replace(", `sourceSequence` INTEGER", "")
                    db.execSQL(create)
                    val indices = entity.getJSONArray("indices")
                    for (j in 0 until indices.length()) db.execSQL(indices.getJSONObject(j).getString("createSql").replace("\${TABLE_NAME}", name))
                }
                db.execSQL("INSERT INTO consentImport VALUES(?, '{}', ?)", arrayOf(id, mutation))
            }
            ScoringSyncDatabase.open(account).use { db ->
                assertEquals(ScoringConsentImport(id, "{}", mutation, null), db.dao().consentImport(id))
                assertNull(db.dao().relayPosition()); assertTrue(db.dao().pending(20).isEmpty())
                assertEquals(4, db.openHelper.readableDatabase.version)
            }
        }
    }

    @Test fun versionThreeInputUpgradePreservesHeldDebtAndWatermarkWithoutPromotingOldOrigins(): Unit = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account(); val id = UUID.randomUUID().toString(); val mutation = UUID.randomUUID().toString()
            val source = UUID.randomUUID().toString(); val key = f.key().storageKey
            val schema = org.json.JSONObject(java.io.File(System.getProperty("room.schemaLocation"),
                "com.noop.push.ScoringSyncDatabase/4.json").readText()).getJSONObject("database")
            legacy(account, "server_sync.sqlite", 3) { db ->
                val entities = schema.getJSONArray("entities")
                for (i in 0 until entities.length()) {
                    val entity = entities.getJSONObject(i); val name = entity.getString("tableName")
                    if (name == "consentControl") continue
                    db.execSQL(entity.getString("createSql").replace("\${TABLE_NAME}", name))
                    val indices = entity.getJSONArray("indices")
                    for (j in 0 until indices.length()) db.execSQL(indices.getJSONObject(j).getString("createSql").replace("\${TABLE_NAME}", name))
                }
                db.execSQL("INSERT INTO historyEntity VALUES(?,7,2,'2026-09-18',NULL,NULL)", arrayOf(key))
                db.execSQL("INSERT INTO historyMutation VALUES(?,?,?,'profile','primary',7,'{\"held\":true}','conflict',NULL,123)", arrayOf(mutation, key, f.device))
                db.execSQL("INSERT INTO consentImport VALUES(?, '{\"immutable\":true}', ?, 91)", arrayOf(id, mutation))
                db.execSQL("INSERT INTO consentRelayPosition VALUES(1,?,91)", arrayOf(source))
            }
            repeat(2) {
                ScoringSyncDatabase.open(account).use { db ->
                    assertEquals(4, db.openHelper.readableDatabase.version)
                    assertEquals(7L, db.dao().entity(key)!!.clientRevision)
                    assertEquals("{\"held\":true}", db.dao().mutation(mutation)!!.body)
                    assertEquals("conflict", db.dao().mutation(mutation)!!.state)
                    assertEquals(ScoringConsentImport(id, "{\"immutable\":true}", mutation, 91), db.dao().consentImport(id))
                    assertEquals(ScoringConsentRelayPosition(sourceId = source, lastSequence = 91), db.dao().relayPosition())
                    assertTrue(db.dao().controls().isEmpty())
                    assertEquals(1L, db.dao().ordinaryPendingCount()); assertEquals(1L, db.dao().ordinaryConsentCount())
                }
            }
        }
    }

    @Test fun pairedVersionTwoPendingAndCopiedAcceptedReceiptSurviveUpgradeRetryAndRetirementCrash(): Unit =
        runBlocking(Dispatchers.IO) { pairedVersionTwoUpgrade(acceptedReceiptCopied = true) }

    @Test fun pairedVersionTwoPendingAndUncopiedAcceptedReceiptSurviveUpgradeRetryAndRetirementCrash(): Unit =
        runBlocking(Dispatchers.IO) { pairedVersionTwoUpgrade(acceptedReceiptCopied = false) }

    private data class LegacyPair(val intent: ScoringConsentIntent, val request: ScoringInputMutation, val proof: String)

    private fun legacyPair(f: W4NativeFixture, client: String, accepted: Boolean, receiptCopied: Boolean): LegacyPair {
        val sequence = if (accepted) 41L else 42L
        val revision = if (accepted) 7L else 8L
        val head = if (accepted) 2L else 3L
        val at = Instant.parse(if (accepted) "2026-09-19T06:59:59Z" else "2026-09-19T07:00:01Z")
        val config = ScoringConfigInput(null, "EDWARDS", false, true, false, null, 0, 0,
            if (accepted) "v2-accepted" else "v2-pending")
        val captured = ScoringConsentCapture.capture(ScoringInputSource.capture(f.account(), f.device), config,
            "America/Los_Angeles", at)
        val day = JSONObject(captured.json).getString("effectiveDay")
        val key = ScoringInputKey(f.device, "config", "primary")
        val mutation = UUID.randomUUID().toString()
        val body = SyncJson.canonical(key.rpc().put("p_effective_day", day).put("p_payload", JSONObject(config.payload()))
            .put("p_expected_revision", head).put("p_deleted", false).put("p_client_id", client)
            .put("p_client_mutation_id", mutation).put("p_client_revision", revision))
        val request = ScoringInputMutation(mutation, key.storageKey, key.device, key.kind, key.entity, revision,
            body, if (accepted) "settled" else "pending", null, at.toEpochMilli())
        val proof = ScoringInputReceipt.decode(f.receipt(request, head + 1), f.owner, request).json
        val intent = ScoringConsentIntent(sequence = sequence, intentId = UUID.randomUUID().toString(),
            purpose = ScoringContextPurpose.JOURNAL.wire, enabled = false, decidedAt = at.toEpochMilli(),
            capture = captured.json, state = if (receiptCopied) "remote_accepted" else "queued",
            mutationId = mutation, receipt = if (receiptCopied) proof else null)
        intent.payload(f.owner)
        return LegacyPair(intent, request.copy(receipt = if (accepted) proof else null), proof)
    }

    private fun seedPairedVersionTwo(account: AccountStorageContext, client: String, pairs: List<LegacyPair>) {
        // Explicit v2 DDL: neither source/position nor reserve columns exist before Room opens.
        legacy(account, "scoring_context_consent.sqlite", 2) { db ->
            db.execSQL("CREATE TABLE consentDecision(purpose TEXT NOT NULL PRIMARY KEY,decisionId TEXT NOT NULL,enabled INTEGER NOT NULL,decidedAt INTEGER NOT NULL)")
            db.execSQL("CREATE TABLE consentIntent(sequence INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,intentId TEXT NOT NULL,purpose TEXT NOT NULL,enabled INTEGER NOT NULL,decidedAt INTEGER NOT NULL,capture TEXT,state TEXT NOT NULL,mutationId TEXT,receipt TEXT)")
            db.execSQL("CREATE UNIQUE INDEX index_consentIntent_intentId ON consentIntent(intentId)")
            db.execSQL("CREATE TABLE consentBarrier(purpose TEXT NOT NULL PRIMARY KEY,intentId TEXT NOT NULL)")
            pairs.forEach { (intent) ->
                db.execSQL("INSERT INTO consentIntent VALUES(?,?,?,?,?,?,?,?,?)", arrayOf(intent.sequence, intent.intentId,
                    intent.purpose, 0, intent.decidedAt, intent.capture, intent.state, intent.mutationId, intent.receipt))
            }
            val current = pairs.last().intent
            db.execSQL("INSERT INTO consentDecision VALUES(?,?,0,?)", arrayOf(current.purpose, current.intentId, current.decidedAt))
        }
        legacy(account, "server_sync.sqlite", 2) { db ->
            db.execSQL("CREATE TABLE snapshotV2(cacheKey TEXT NOT NULL PRIMARY KEY,day TEXT NOT NULL,timezone TEXT NOT NULL,sourceDeviceId TEXT NOT NULL,algorithmVersion TEXT NOT NULL,inputRevision INTEGER NOT NULL,resultRevision INTEGER NOT NULL,body TEXT NOT NULL,fetchedAt INTEGER NOT NULL)")
            db.execSQL("CREATE TABLE snapshotSelection(selectionKey TEXT NOT NULL PRIMARY KEY,cacheKey TEXT NOT NULL)")
            db.execSQL("CREATE TABLE historyEntity(entityKey TEXT NOT NULL PRIMARY KEY,clientRevision INTEGER NOT NULL,headRevision INTEGER NOT NULL,earliestDay TEXT NOT NULL,originalStart INTEGER,originalEnd INTEGER)")
            db.execSQL("CREATE TABLE historyMutation(mutationId TEXT NOT NULL PRIMARY KEY,entityKey TEXT NOT NULL,device TEXT NOT NULL,kind TEXT NOT NULL,entity TEXT NOT NULL,clientRevision INTEGER NOT NULL,body TEXT NOT NULL,state TEXT NOT NULL,receipt TEXT,createdAt INTEGER NOT NULL)")
            db.execSQL("CREATE INDEX index_historyMutation_entityKey ON historyMutation(entityKey)")
            db.execSQL("CREATE TABLE syncClient(singleton INTEGER NOT NULL PRIMARY KEY,clientId TEXT NOT NULL)")
            db.execSQL("CREATE TABLE consentImport(intentId TEXT NOT NULL PRIMARY KEY,origin TEXT NOT NULL,mutationId TEXT NOT NULL)")
            db.execSQL("CREATE UNIQUE INDEX index_consentImport_mutationId ON consentImport(mutationId)")
            db.execSQL("INSERT INTO syncClient VALUES(1,?)", arrayOf(client))
            val pending = pairs.last().request
            db.execSQL("INSERT INTO historyEntity VALUES(?,?,?,?,NULL,NULL)", arrayOf(pending.entityKey,
                pending.clientRevision, JSONObject(pending.body).getLong("p_expected_revision"),
                JSONObject(pending.body).getString("p_effective_day")))
            pairs.forEach { (intent, request) ->
                db.execSQL("INSERT INTO historyMutation VALUES(?,?,?,?,?,?,?,?,?,?)", arrayOf(request.mutationId,
                    request.entityKey, request.device, request.kind, request.entity, request.clientRevision,
                    request.body, request.state, request.receipt, request.createdAt))
                db.execSQL("INSERT INTO consentImport VALUES(?,?,?)", arrayOf(intent.intentId, intent.origin(), request.mutationId))
            }
        }
    }

    private suspend fun pairedVersionTwoUpgrade(acceptedReceiptCopied: Boolean) {
        W4NativeFixture().use { f ->
            val account = f.account(); val client = UUID.randomUUID().toString()
            val accepted = legacyPair(f, client, accepted = true, receiptCopied = acceptedReceiptCopied)
            val pending = legacyPair(f, client, accepted = false, receiptCopied = false)
            val pairs = listOf(accepted, pending)
            seedPairedVersionTwo(account, client, pairs)
            val sent = mutableListOf<String>()
            val positions = mutableMapOf<String, ScoringConsentPosition>()
            val acceptedIntents = mutableListOf<ScoringConsentIntent>()
            lateinit var source: ScoringConsentSource
            fun coordinator(store: ScoringSyncStore) = ScoringInputCoordinator(account, store,
                f.rpc(account, ScoringRpcTransport { url, _, _, body ->
                    assertTrue("A frozen v2 pending request must not fetch a new head", url.endsWith("put_scoring_history_input_v3"))
                    assertEquals(pending.request.body, body)
                    sent += body
                    ScoringRpcReply(200, JSONObject(pending.proof).put("unrecognizedExtension", "not retained").toString())
                }), scheduled = {})

            ScoringConsentDatabase.open(account).use { consent ->
                ScoringSyncDatabase.open(account).use { db ->
                    val store = ScoringSyncStore(account, db)
                    assertEquals(3, consent.openHelper.readableDatabase.version)
                    assertEquals(4, db.openHelper.readableDatabase.version)
                    assertNull(consent.dao().source()); assertNull(db.dao().relayPosition())
                    pairs.forEach { (intent, request) ->
                        assertEquals(intent, consent.dao().intent(intent.intentId))
                        assertEquals(request, db.dao().mutation(request.mutationId))
                        assertEquals(ScoringConsentImport(intent.intentId, intent.origin(), request.mutationId), db.dao().consentImport(intent.intentId))
                    }
                    assertEquals(listOf(pending.request), store.pending()); assertTrue(db.dao().controls().isEmpty())
                    coordinator(store).recoverConsent()
                    source = consent.ensureSource()
                    pairs.forEach { (intent, request) ->
                        val position = consent.position(intent); positions[intent.intentId] = position
                        assertEquals(source.sourceId, position.sourceId); assertEquals(intent.sequence, position.sequence)
                        // The older accepted origin binds in place even after the pending row moved high water.
                        assertEquals(request, store.importConsent(intent, position))
                        assertEquals(ScoringConsentImport(intent.intentId, intent.origin(), request.mutationId, intent.sequence),
                            db.dao().consentImport(intent.intentId))
                    }
                    assertEquals(ScoringConsentRelayPosition(sourceId = source.sourceId, lastSequence = 42), db.dao().relayPosition())
                    assertEquals(accepted.intent.copy(state = "remote_accepted", receipt = accepted.proof), consent.dao().intent(accepted.intent.intentId))
                    assertEquals(accepted.proof, ScoringInputReceipt.decode(consent.dao().intent(accepted.intent.intentId)!!.receipt!!,
                        f.owner, accepted.request).json)
                    db.openHelper.writableDatabase.execSQL("CREATE TRIGGER fail_v2_receipt BEFORE UPDATE ON historyMutation WHEN NEW.state='settled' BEGIN SELECT RAISE(ABORT,'synthetic accepted HTTP before receipt commit'); END")
                    assertTrue(coordinator(store).drain())
                    assertEquals(listOf(pending.request.body), sent)
                    assertEquals(pending.request, db.dao().mutation(pending.request.mutationId))
                    assertEquals(pending.intent, consent.dao().intent(pending.intent.intentId))
                    assertEquals(8L, db.dao().entity(pending.request.entityKey)!!.clientRevision)
                }
            }

            ScoringConsentDatabase.open(account).use { consent ->
                ScoringSyncDatabase.open(account).use { db ->
                    val store = ScoringSyncStore(account, db)
                    assertEquals(source, consent.ensureSource())
                    assertEquals(pending.request, db.dao().mutation(pending.request.mutationId))
                    assertEquals(client, db.dao().client()!!.clientId)
                    db.openHelper.writableDatabase.execSQL("DROP TRIGGER fail_v2_receipt")
                    assertFalse(coordinator(store).drain())
                    assertEquals(listOf(pending.request.body, pending.request.body), sent)
                    pairs.forEach { (intent, request, proof) ->
                        assertEquals(request.copy(state = "settled", receipt = proof), db.dao().mutation(request.mutationId))
                        val copied = intent.copy(state = "remote_accepted", receipt = proof)
                        assertEquals(copied, consent.dao().intent(intent.intentId)); acceptedIntents += copied
                        assertEquals(proof, ScoringInputReceipt.decode(copied.receipt!!, f.owner, request).json)
                        assertFalse(JSONObject(copied.receipt).has("unrecognizedExtension"))
                    }
                    assertEquals(8L, db.dao().entity(pending.request.entityKey)!!.clientRevision)
                    assertEquals(4L, db.dao().entity(pending.request.entityKey)!!.headRevision)
                    consent.openHelper.writableDatabase.execSQL("CREATE TRIGGER fail_v2_retirement BEFORE DELETE ON consentIntent BEGIN SELECT RAISE(ABORT,'synthetic input retired before consent delete'); END")
                    assertTrue(runCatching { ScoringConsentRelay.compactAccepted(consent, store, 0) }.isFailure)
                    assertNull(db.dao().consentImport(accepted.intent.intentId)); assertNull(db.dao().mutation(accepted.request.mutationId))
                    assertNotNull(db.dao().consentImport(pending.intent.intentId))
                    assertEquals(acceptedIntents, consent.dao().intents())
                    assertEquals(42L, db.dao().relayPosition()!!.lastSequence)
                }
            }

            ScoringConsentDatabase.open(account).use { consent ->
                ScoringSyncDatabase.open(account).use { db ->
                    val store = ScoringSyncStore(account, db)
                    assertEquals(source, consent.ensureSource()); assertEquals(acceptedIntents, consent.dao().intents())
                    assertNull(db.dao().consentImport(accepted.intent.intentId))
                    consent.openHelper.writableDatabase.execSQL("DROP TRIGGER fail_v2_retirement")
                    coordinator(store).recoverConsent() // Finish the cross-store deletion gap without resending.
                    assertNull(consent.dao().intent(accepted.intent.intentId))
                    repeat(2) { ScoringConsentRelay.compactAccepted(consent, store, 0) }
                }
            }
            ScoringConsentDatabase.open(account).use { consent ->
                ScoringSyncDatabase.open(account).use { db ->
                    val store = ScoringSyncStore(account, db)
                    assertEquals(source, consent.ensureSource()); assertTrue(consent.dao().intents().isEmpty())
                    repeat(2) {
                        acceptedIntents.forEach { intent ->
                            assertTrue(runCatching { store.importConsent(intent, positions.getValue(intent.intentId)) }.exceptionOrNull() is ScoringConsentOriginRetired)
                            assertNull(db.dao().consentImport(intent.intentId)); assertNull(db.dao().mutation(intent.mutationId!!))
                        }
                        assertFalse(coordinator(store).drain())
                    }
                    assertEquals(ScoringConsentRelayPosition(sourceId = source.sourceId, lastSequence = 42), db.dao().relayPosition())
                    assertEquals(8L, db.dao().entity(pending.request.entityKey)!!.clientRevision)
                    assertEquals(4L, db.dao().entity(pending.request.entityKey)!!.headRevision)
                    assertEquals(client, db.dao().client()!!.clientId)
                    assertEquals(pending.intent.row(), consent.dao().get(pending.intent.purpose))
                    assertEquals(0L, db.dao().pendingCount()); assertEquals(0L, db.dao().consentCount())
                    assertTrue(db.dao().controls().isEmpty())
                    assertEquals(listOf(pending.request.body, pending.request.body), sent)
                }
            }
        }
    }
}
