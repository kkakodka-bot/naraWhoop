package com.noop.push

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PushEnrollmentStoreTest {
    @Test fun credentialRoundTripsWithoutPersistingEnrollmentCode() {
        val prefs = SelfHostedPushSettingsTest.FakePushPrefs()
        val store = PushEnrollmentStore.forTest(prefs)
        val credential = credential()

        store.save(SOURCE_ID, credential)

        assertEquals(credential, store.load(SOURCE_ID))
        assertFalse(prefs.all.values.any { it == "ONE-TIME-CODE" })
        assertFalse(credential.toString().contains(UPLOAD_TOKEN))
        assertTrue(credential.toString().contains("[REDACTED]"))
    }

    @Test fun sourceMismatchClearsCredentialAndFailsClosed() {
        val prefs = SelfHostedPushSettingsTest.FakePushPrefs()
        val store = PushEnrollmentStore.forTest(prefs)
        store.save(SOURCE_ID, credential())

        assertNull(store.load(OTHER_SOURCE_ID))
        assertEquals(USER_ID, store.boundUserId())
        assertFalse(prefs.all.values.contains(UPLOAD_TOKEN))
        assertNull(store.load(SOURCE_ID))
    }

    @Test fun incompleteOrUnknownVersionCredentialIsCleared() {
        val prefs = SelfHostedPushSettingsTest.FakePushPrefs()
        prefs.edit()
            .putInt("version", PushEnrollmentCredential.STORAGE_VERSION + 1)
            .putString("upload_token", UPLOAD_TOKEN)
            .commit()

        assertNull(PushEnrollmentStore.forTest(prefs).load(SOURCE_ID))
        assertTrue(prefs.all.isEmpty())
    }

    @Test(expected = IllegalArgumentException::class)
    fun saveRejectsCredentialForAnotherSource() {
        PushEnrollmentStore.forTest(SelfHostedPushSettingsTest.FakePushPrefs())
            .save(OTHER_SOURCE_ID, credential())
    }

    @Test(expected = IllegalArgumentException::class)
    fun credentialRejectsMalformedUploadToken() {
        PushEnrollmentCredential(USER_ID, SOURCE_ID, TOKEN_ID, "noop_too-short")
    }

    @Test fun clearingCredentialRetainsOwnerAndRejectsReattribution() {
        val store = PushEnrollmentStore.forTest(SelfHostedPushSettingsTest.FakePushPrefs())
        store.save(SOURCE_ID, credential()); store.clear()
        assertEquals(USER_ID, store.boundUserId())
        assertNull(store.load(SOURCE_ID))
        assertTrue(runCatching { store.save(SOURCE_ID, credential().copy(userId = OTHER_SOURCE_ID)) }.isFailure)
        store.save(SOURCE_ID, credential())
        assertEquals(credential(), store.load(SOURCE_ID))
    }

    @Test fun delayedRevocationCannotClearRenewedCredential() {
        val store = PushEnrollmentStore.forTest(SelfHostedPushSettingsTest.FakePushPrefs())
        val old = credential(); store.save(SOURCE_ID, old)
        val renewed = old.copy(uploadToken = "noop_" + "b".repeat(43))
        store.save(SOURCE_ID, renewed)
        assertFalse(store.clearIfCurrent(old))
        assertEquals(renewed, store.load(SOURCE_ID))
    }

    @Test fun enrollmentReplyCannotUndoExplicitClear() {
        val store = PushEnrollmentStore.forTest(SelfHostedPushSettingsTest.FakePushPrefs())
        val pending = store.generation(); store.clear()
        assertFalse(store.saveIfCurrent(pending, SOURCE_ID, credential()))
        assertNull(store.load(SOURCE_ID))
    }

    @Test fun transientEncryptedReadFailureDoesNotClearCredentialOrOwnerWitness() {
        val prefs = SelfHostedPushSettingsTest.FakePushPrefs()
        val writer = PushEnrollmentStore.forTest(prefs); writer.save(SOURCE_ID, credential())
        var fail = true
        val flaky = object : android.content.SharedPreferences by prefs {
            override fun getString(key: String, defValue: String?): String? {
                if (fail) { fail = false; throw SecurityException("temporarily unavailable") }
                return prefs.getString(key, defValue)
            }
        }
        val reader = PushEnrollmentStore.forTest(flaky)
        assertTrue(runCatching { reader.load(SOURCE_ID) }.exceptionOrNull() is SecurityException)
        assertEquals(credential(), reader.load(SOURCE_ID))
        assertEquals(USER_ID, reader.boundUserId())
    }

    private fun credential() = PushEnrollmentCredential(USER_ID, SOURCE_ID, TOKEN_ID, UPLOAD_TOKEN)

    @Test fun retirementSurvivesInterruptionAndCreatesAnIndependentOwnerEpoch() {
        val prefs = SelfHostedPushSettingsTest.FakePushPrefs()
        val store = PushEnrollmentStore.forTest(prefs)
        store.save(SOURCE_ID,credential())
        val generation = store.generation()
        val pending = store.beginRetirement(credential())
        assertNull(store.load(SOURCE_ID))
        assertEquals(USER_ID,store.boundUserId())
        assertEquals(pending,PushEnrollmentStore.forTest(prefs).pendingRetirement())
        assertFalse(store.saveIfCurrent(generation,SOURCE_ID,credential()))
        assertTrue(runCatching {store.save(SOURCE_ID,credential().copy(userId=OTHER_SOURCE_ID))}.isFailure)
        store.completeRetirement(pending)
        val b = credential().copy(userId=OTHER_SOURCE_ID,sourceId=pending.nextSourceId)
        store.save(pending.nextSourceId,b)
        assertEquals(b,store.load(pending.nextSourceId))
        assertEquals(USER_ID,prefs.getString("retired_owner.$SOURCE_ID",null))
    }

    @Test fun serialEvidenceCannotBeRepointedOrReadByAnotherEpoch() {
        val prefs = SelfHostedPushSettingsTest.FakePushPrefs()
        val store = WearableAssociationStore(prefs)
        val a = credential()
        store.record("local-band","SYNTH001",a)
        val item = WearableAssociationStore(prefs).pending(a).single()
        store.acknowledge(item,a)
        assertTrue(store.pending(a).isEmpty())
        assertTrue(runCatching {store.record("local-band","SYNTH002",a)}.isFailure)
        assertTrue(runCatching {store.pending(a)}.isFailure)
        val b = a.copy(userId=OTHER_SOURCE_ID,sourceId=java.util.UUID.randomUUID().toString())
        assertTrue(store.pending(b).isEmpty())
        store.record("local-band","SYNTH002",b)
        assertEquals("SYNTH002",store.pending(b).single().serial)
    }

    private companion object {
        const val USER_ID = "00000000-0000-4000-8000-000000000010"
        const val SOURCE_ID = "00000000-0000-4000-8000-000000000011"
        const val OTHER_SOURCE_ID = "00000000-0000-4000-8000-000000000012"
        const val TOKEN_ID = "00000000-0000-4000-8000-000000000013"
        const val UPLOAD_TOKEN = "noop_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
}
