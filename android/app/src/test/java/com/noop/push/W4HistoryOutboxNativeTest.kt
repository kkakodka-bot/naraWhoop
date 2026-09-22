package com.noop.push

import android.app.Application
import org.json.JSONObject
import org.junit.Test
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import kotlinx.coroutines.runBlocking

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class W4HistoryOutboxNativeTest {
    @Test fun offlineProfileDraftIsDurableBeforeAnyHeadRequestAndUsesCapturedUploadSource() = runBlocking(kotlinx.coroutines.Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account(); val source = ScoringInputSource.capture(account, "my-whoop")
            val draft = ScoringSyncDatabase.open(account).use { db ->
                val store = ScoringSyncStore(account, db)
                val rpc = f.rpc(account, ScoringRpcTransport { _, _, _, _ -> error("Offline save must not access network") })
                ScoringInputCoordinator(account, store, rpc, java.time.Clock.fixed(java.time.Instant.parse("2026-09-18T01:00:00Z"), java.time.ZoneOffset.UTC), {})
                    .saveProfile(f.profile().copy(timezone = "America/Los_Angeles"), source)
            }
            assertEquals(source.serverDeviceId, draft.device); assertNotEquals(source.uploadSourceId, draft.device)
            assertEquals("awaiting_head", draft.state)
            val body = JSONObject(draft.body); assertEquals("2026-09-17", body.getString("p_effective_day")); assertTrue(body.isNull("p_expected_revision"))
            ScoringSyncDatabase.open(account).use { db -> assertEquals(draft.body, ScoringSyncStore(account, db).pending().single().body) }
        }
    }
    @Test fun draftHeadIsFrozenBeforeFirstSendAndHeadDoesNotNeedToBeZero() = runBlocking(kotlinx.coroutines.Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account()
            ScoringSyncDatabase.open(account).use { db ->
                val store = ScoringSyncStore(account, db)
                val previous = store.enqueue(f.key(), ScoringInputHead(f.key(), 0), "2026-09-18", f.profile().payload())
                store.recordReceipt(previous, f.receipt(previous, 88))
                val draft = store.enqueue(f.key(), null, "2026-09-18", f.profile().payload())
                var heads = 0; var writes = 0
                val rpc = f.rpc(account, ScoringRpcTransport { url, _, _, body ->
                    if (url.endsWith("get_scoring_history_input_head_v3")) {
                        heads++
                        ScoringRpcReply(200, JSONObject().put("schemaVersion", 1).put("userId", f.owner.userID)
                            .put("sourceDeviceId", f.device).put("kind", "profile").put("entity", "primary").put("headRevision", 88).toString())
                    } else {
                        writes++; assertEquals(88, JSONObject(body).getLong("p_expected_revision"))
                        val frozen = db.dao().mutation(draft.mutationId)!!; assertEquals(body, frozen.body); assertEquals("pending", frozen.state)
                        if (writes == 1) throw java.io.IOException("lost reply")
                        ScoringRpcReply(200, f.receipt(frozen, 123))
                    }
                })
                val coordinator = ScoringInputCoordinator(account, store, rpc, scheduled = {})
                assertTrue(coordinator.drain()); assertFalse(coordinator.drain()); assertEquals(1, heads); assertEquals(2, writes)
            }
        }
    }
    @Test fun unknownOrChangedRemoteHeadDoesNotAuthorizeDraftOverwrite() = runBlocking(kotlinx.coroutines.Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account()
            ScoringSyncDatabase.open(account).use { db ->
                val store = ScoringSyncStore(account, db)
                val draft = store.enqueue(f.key(), null, "2026-09-18", f.profile().payload())
                val conflict = store.admitDraft(draft, ScoringInputHead(f.key(), 88))
                assertEquals("conflict", conflict.state); assertEquals(draft.body, conflict.body)
                assertTrue(store.pending().isEmpty())
                val rebased = store.enqueue(f.key(), ScoringInputHead(f.key(), 88), "2026-09-18", f.profile().payload(), resolving = draft.mutationId)
                assertNotEquals(draft.mutationId, rebased.mutationId); assertEquals(88, JSONObject(rebased.body).getLong("p_expected_revision"))
            }
        }
    }
    @Test fun sleepPinsSnapshotSourceAndAnchorsAndTombstonePreservesEarliestAffectedDay() = runBlocking(kotlinx.coroutines.Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account()
            ScoringSyncDatabase.open(account).use { db ->
                val store = ScoringSyncStore(account, db)
                val snapshot = ServerSnapshotDecoder.decode(f.snapshot(sleep = f.sleep()), f.owner, "2026-09-18").snapshot!!
                assertNotEquals(snapshot.sourceDeviceId, SelfHostedPushSettings.from(account).sourceId())
                val session = snapshot.sleep.single()
                val coordinator = ScoringInputCoordinator(account, store, f.rpc(account, ScoringRpcTransport { _, _, _, _ -> error("offline") }), scheduled = {})
                val draft = coordinator.queueSleepEdit(snapshot, ScoringSleepEdit(session, session.start - 86400, session.end - 86400, false, false))
                assertEquals(f.device, draft.device); assertEquals(session.originalStart, JSONObject(draft.body).getJSONObject("p_payload").getLong("originalStart"))
                assertEquals("2026-09-17", JSONObject(draft.body).getString("p_effective_day"))
                val request = store.admitDraft(draft, ScoringInputHead(draft.key(), 0)); store.recordReceipt(request, f.receipt(request))
                val tombstone = coordinator.queueSleepTombstone(snapshot, session)
                assertEquals(draft.entity, tombstone.entity); assertEquals("2026-09-17", JSONObject(tombstone.body).getString("p_effective_day"))
                assertTrue(JSONObject(tombstone.body).getBoolean("p_deleted")); assertEquals(0, JSONObject(tombstone.body).getJSONObject("p_payload").length())
            }
        }
    }
    @Test fun receiptAndHeadRollbackTogetherWhenGenerationChangesAtActualOuterCommit() = runBlocking(kotlinx.coroutines.Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account()
            ScoringSyncDatabase.open(account).use { db ->
                val store = ScoringSyncStore(account, db); val request = store.enqueue(f.key(), ScoringInputHead(f.key(), 0), "2026-09-18", f.profile().payload())
                try {
                    db.runInTransaction {
                        store.recordReceipt(request, f.receipt(request)); f.controller.clearSession()
                    }
                    fail("retired receipt committed")
                } catch (e: com.noop.account.AccountWriteRevokedException) { assertEquals(AuthFailure.STALE, e.failure) }
                db.openHelper.readableDatabase.query("SELECT state,receipt FROM historyMutation").use {
                    assertTrue(it.moveToFirst()); assertEquals("pending", it.getString(0)); assertTrue(it.isNull(1))
                }
                db.openHelper.readableDatabase.query("SELECT headRevision FROM historyEntity").use { assertTrue(it.moveToFirst()); assertEquals(0, it.getLong(0)) }
            }
        }
    }
    @Test fun tenFieldsPersistExactAcrossReopenAndOpaqueAckAdvancesAtomically() = runBlocking(kotlinx.coroutines.Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account()
            val first = ScoringSyncDatabase.open(account).use { db ->
                db.openHelper.writableDatabase.query("PRAGMA synchronous").use { assertTrue(it.moveToFirst()); assertEquals(2, it.getInt(0)) }
                ScoringSyncStore(account, db).enqueue(f.key(), ScoringInputHead(f.key(), 0), "2026-09-18", f.profile().payload())
            }
            assertEquals(10, JSONObject(first.body).length())
            ScoringSyncDatabase.open(account).use { db ->
                val store = ScoringSyncStore(account, db); assertEquals(first.body, store.pending().single().body)
                store.recordReceipt(first, f.receipt(first, 123))
                assertTrue(store.pending().isEmpty()); assertEquals(123, db.dao().entity(first.entityKey)!!.headRevision)
                store.recordReceipt(first, f.receipt(first, 123)); assertEquals(123, db.dao().entity(first.entityKey)!!.headRevision)
                assertNotNull(db.dao().mutation(first.mutationId)!!.receipt)
            }
        }
    }
    @Test fun everyReceiptIdentityMustMatchAndInvalidAckRetainsPending() = runBlocking(kotlinx.coroutines.Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account()
            ScoringSyncDatabase.open(account).use { db ->
                val store = ScoringSyncStore(account, db)
                val request = store.enqueue(f.key(), ScoringInputHead(f.key(), 5), "2026-09-18", f.profile().payload())
                val changes = mapOf<String, Any>("schemaVersion" to 2, "userId" to f.device, "sourceDeviceId" to f.owner.userID,
                    "kind" to "config", "entity" to "other", "clientId" to f.device, "clientMutationId" to f.device,
                    "clientRevision" to 10, "effectiveDay" to "2026-09-17", "deleted" to true, "revision" to 5,
                    "invalidatedFrom" to "2026-09-19")
                for ((key, value) in changes) {
                    try { store.recordReceipt(request, JSONObject(f.receipt(request)).put(key, value).toString()); fail("accepted $key") }
                    catch (_: IllegalArgumentException) { }
                    assertEquals(request.body, store.pending().single().body)
                }
            }
        }
    }
    @Test fun lostReplyRetriesIdenticalRequestNotNextRevision() = runBlocking(kotlinx.coroutines.Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account()
            ScoringSyncDatabase.open(account).use { db ->
                val store = ScoringSyncStore(account, db); val request = store.enqueue(f.key(), ScoringInputHead(f.key(), 0), "2026-09-18", f.profile().payload())
                val bodies = mutableListOf<String>()
                val rpc = f.rpc(account, ScoringRpcTransport { _, _, _, body ->
                    bodies += body
                    if (bodies.size == 1) throw java.io.IOException("synthetic lost reply")
                    ScoringRpcReply(200, f.receipt(request))
                })
                val coordinator = ScoringInputCoordinator(account, store, rpc, scheduled = {})
                assertTrue(coordinator.drain()); assertFalse(coordinator.drain())
                assertEquals(listOf(request.body, request.body), bodies)
            }
        }
    }
    @Test fun sqlstate40001RetainsIntentRegardlessOfHttpStatusUntilExplicitRebase() = runBlocking(kotlinx.coroutines.Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account()
            ScoringSyncDatabase.open(account).use { db ->
                val store = ScoringSyncStore(account, db); val original = store.enqueue(f.key(), ScoringInputHead(f.key(), 0), "2026-09-18", f.profile().payload())
                val rpc = f.rpc(account, ScoringRpcTransport { _, _, _, _ -> ScoringRpcReply(500, """{"code":"40001"}""") })
                assertFalse(ScoringInputCoordinator(account, store, rpc, scheduled = {}).drain())
                assertEquals("conflict", db.dao().mutation(original.mutationId)!!.state)
                try { store.enqueue(f.key(), ScoringInputHead(f.key(), 20), "2026-09-18", f.profile().payload()); fail("silent rebase") }
                catch (_: IllegalStateException) { }
                val next = store.enqueue(f.key(), ScoringInputHead(f.key(), 20), "2026-09-18", f.profile().payload(), resolving = original.mutationId)
                assertNotEquals(original.mutationId, next.mutationId); assertEquals(2, next.clientRevision)
                assertEquals(original.body, db.dao().mutation(original.mutationId)!!.body)
            }
        }
    }
    @Test fun laterDuplicateReceiptCannotRewindKnownHead() = runBlocking(kotlinx.coroutines.Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account()
            ScoringSyncDatabase.open(account).use { db ->
                val store = ScoringSyncStore(account, db)
                val a = store.enqueue(f.key(), ScoringInputHead(f.key(), 0), "2026-09-18", f.profile().payload()); store.recordReceipt(a, f.receipt(a, 100))
                val b = store.enqueue(f.key(), ScoringInputHead(f.key(), 100), "2026-09-18", f.profile().payload()); store.recordReceipt(b, f.receipt(b, 200))
                store.recordReceipt(a, f.receipt(a, 100)); assertEquals(200, db.dao().entity(a.entityKey)!!.headRevision)
            }
        }
    }
    @Test fun sameAccountNewGenerationCannotSettleThroughOldStore() = runBlocking(kotlinx.coroutines.Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account()
            ScoringSyncDatabase.open(account).use { db ->
                val store = ScoringSyncStore(account, db); val a = store.enqueue(f.key(), ScoringInputHead(f.key(), 0), "2026-09-18", f.profile().payload())
                f.controller.clearSession(); f.controller.signIn("a", "synthetic")
                try { store.recordReceipt(a, f.receipt(a)); fail("old generation settled") } catch (e: com.noop.account.AccountWriteRevokedException) { assertEquals(AuthFailure.STALE, e.failure) }
                ScoringSyncDatabase.open(f.account()).use { fresh -> assertEquals(a.body, ScoringSyncStore(f.account(), fresh).pending().single().body) }
            }
        }
    }
}
