package com.noop.push

import android.app.Application
import com.noop.account.AccountStorageContext
import kotlinx.coroutines.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.util.UUID

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class W4ContextConsentNativeTest {
    private fun body(decision: ScoringContextDecision) = JSONObject().put("consent", decision.payload()).toString()
    private suspend fun close(consent: ScoringContextConsent) { consent.retire(); consent.awaitRetirement() }

    @Test fun defaultsOffPersistsSeparateDecisionsAndDoesNotReadLegacyPreferences() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account()
            account.getSharedPreferences("noop_prefs", 0).edit().putBoolean("noop.cycleTracking", true).commit()
            val consent = ScoringContextConsent(account)
            consent.load(); assertTrue(consent.state.value.loaded)
            ScoringContextPurpose.values().forEach { assertNull(consent.decision(it)) }
            consent.setEnabled(ScoringContextPurpose.JOURNAL, true)
            val decision = consent.decision(ScoringContextPurpose.JOURNAL)!!
            assertNull(consent.decision(ScoringContextPurpose.CYCLE))
            close(consent); assertFalse(consent.allows(ScoringContextPurpose.JOURNAL, body(decision)))
            val reopened = ScoringContextConsent(account)
            try {
                reopened.load(); assertEquals(decision, reopened.decision(ScoringContextPurpose.JOURNAL))
                ScoringConsentDatabase.open(account).use { db ->
                    db.openHelper.readableDatabase.query("PRAGMA synchronous").use { assertTrue(it.moveToFirst()); assertEquals(2, it.getInt(0)) }
                }
            } finally { close(reopened) }
        }
    }

    @Test fun revocationAndNewDecisionNeverReleaseOldPayload() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val consent = ScoringContextConsent(f.account())
            try {
                consent.setEnabled(ScoringContextPurpose.JOURNAL, true)
                val old = body(consent.decision(ScoringContextPurpose.JOURNAL)!!)
                assertTrue(consent.allows(ScoringContextPurpose.JOURNAL, old))
                consent.setEnabled(ScoringContextPurpose.JOURNAL, false)
                assertFalse(consent.allows(ScoringContextPurpose.JOURNAL, old))
                consent.setEnabled(ScoringContextPurpose.JOURNAL, true)
                assertFalse(consent.allows(ScoringContextPurpose.JOURNAL, old))
                assertTrue(consent.allows(ScoringContextPurpose.JOURNAL, body(consent.decision(ScoringContextPurpose.JOURNAL)!!)))
            } finally { close(consent) }
        }
    }

    @Test fun failedSQLiteUpdateStaysPausedAcrossReloadAndAnotherPurposeWrite() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account(); val consent = ScoringContextConsent(account)
            try {
                consent.setEnabled(ScoringContextPurpose.JOURNAL, true)
                val old = body(consent.decision(ScoringContextPurpose.JOURNAL)!!)
                ScoringConsentDatabase.open(account).use { db ->
                    db.openHelper.writableDatabase.execSQL("""CREATE TRIGGER reject_revocation BEFORE UPDATE ON consentDecision
                        WHEN NEW.purpose='journal_context' AND NEW.enabled=0
                        BEGIN SELECT RAISE(ABORT,'synthetic consent update failure'); END""")
                    consent.setEnabled(ScoringContextPurpose.JOURNAL, false)
                    assertNotNull(consent.state.value.error); assertFalse(consent.allows(ScoringContextPurpose.JOURNAL, old))
                    consent.load(); assertFalse(consent.allows(ScoringContextPurpose.JOURNAL, old))
                    consent.setEnabled(ScoringContextPurpose.CYCLE, true)
                    assertNotNull(consent.decision(ScoringContextPurpose.CYCLE))
                    assertNotNull(consent.state.value.error); assertFalse(consent.allows(ScoringContextPurpose.JOURNAL, old))
                    assertTrue(db.dao().get("journal_context")!!.enabled)
                    db.openHelper.writableDatabase.execSQL("DROP TRIGGER reject_revocation")
                    consent.setEnabled(ScoringContextPurpose.JOURNAL, false)
                    assertNull(consent.state.value.error); consent.load()
                    assertFalse(consent.allows(ScoringContextPurpose.JOURNAL, old))
                }
            } finally { close(consent) }
            val reopened = ScoringContextConsent(account)
            try { reopened.load(); assertNull(reopened.decision(ScoringContextPurpose.JOURNAL)); assertNotNull(reopened.decision(ScoringContextPurpose.CYCLE)) }
            finally { close(reopened) }
        }
    }

    @Test fun retirementAfterExecutedSqlRollsBackTheActualConsentUpdate() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account(); val consent = ScoringContextConsent(account)
            consent.setEnabled(ScoringContextPurpose.CYCLE, false)
            consent.setEnabled(ScoringContextPurpose.CYCLE, true) { consent.retire() }
            consent.awaitRetirement()
            val successor = ScoringContextConsent(account)
            try {
                successor.load(); assertEquals(false, successor.state.value.decisions[ScoringContextPurpose.CYCLE]?.enabled)
                successor.setEnabled(ScoringContextPurpose.CYCLE, true)
                assertNotNull(successor.decision(ScoringContextPurpose.CYCLE))
                assertTrue(runCatching { consent.setEnabled(ScoringContextPurpose.CYCLE, false) }.exceptionOrNull() is AccountAuthException)
            } finally { close(successor) }
        }
    }

    @Test fun sameAccountNewGenerationCannotUseOldConsentGateOrWriter() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val old = ScoringContextConsent(f.account())
            old.setEnabled(ScoringContextPurpose.JOURNAL, true)
            val prior = old.decision(ScoringContextPurpose.JOURNAL)!!
            f.controller.clearSession(); f.controller.signIn("a", "synthetic")
            assertFalse(old.allows(ScoringContextPurpose.JOURNAL, body(prior)))
            old.setEnabled(ScoringContextPurpose.JOURNAL, false)
            close(old)
            val current = ScoringContextConsent(f.account())
            try { current.load(); assertEquals(prior, current.decision(ScoringContextPurpose.JOURNAL)) }
            finally { close(current) }
        }
    }

    @Test fun malformedConsentCannotMatchAnAffirmativeDecision() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val consent = ScoringContextConsent(f.account())
            try {
                consent.setEnabled(ScoringContextPurpose.JOURNAL, true)
                val decision = consent.decision(ScoringContextPurpose.JOURNAL)!!
                for (replacement in listOf(decision.payload().put("policyVersion", true), decision.payload().put("policyVersion", 1.5),
                    decision.payload().put("decisionId", UUID.randomUUID().toString()), decision.payload().put("purpose", "cycle_context"),
                    decision.payload().put("unexpected", 1))) {
                    assertFalse(consent.allows(ScoringContextPurpose.JOURNAL, JSONObject().put("consent", replacement).toString()))
                }
            } finally { close(consent) }
        }
    }

    @Test fun wrongOwnerDatabaseIsRejectedWithoutRebinding() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account()
            ScoringConsentDatabase.open(account).use { db ->
                db.openHelper.writableDatabase.execSQL("UPDATE localAccountOwner SET userID=? WHERE singleton=1", arrayOf(f.device))
            }
            val consent = ScoringContextConsent(account)
            try {
                consent.load(); assertFalse(consent.state.value.loaded); assertNotNull(consent.state.value.error)
                assertNull(consent.decision(ScoringContextPurpose.JOURNAL))
                android.database.sqlite.SQLiteDatabase.openDatabase(account.getDatabasePath("scoring_context_consent.sqlite").absolutePath,
                    null, android.database.sqlite.SQLiteDatabase.OPEN_READONLY).use { db ->
                    db.rawQuery("SELECT userID FROM localAccountOwner", null).use { assertTrue(it.moveToFirst()); assertEquals(f.device, it.getString(0)) }
                }
            } finally { close(consent) }
        }
    }
}
