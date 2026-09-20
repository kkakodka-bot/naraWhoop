package com.noop.push

import android.content.SharedPreferences
import org.junit.Assert.*
import org.junit.Test

class CloudAuthSessionStoreTest {
    @Test fun migratesOnlyAfterVerifiedEncryptedPersistenceAndClearsBothOnSignOut() {
        val secure=SelfHostedPushSettingsTest.FakePushPrefs()
        val legacy=SelfHostedPushSettingsTest.FakePushPrefs()
        legacy.edit().putString(CloudAuthSessionStore.KEY,"opaque-test-session").commit()
        val store=CloudAuthSessionStore(secure,legacy)
        assertEquals("opaque-test-session",store.read())
        assertEquals("opaque-test-session",secure.getString(CloudAuthSessionStore.KEY,null))
        assertFalse(legacy.contains(CloudAuthSessionStore.KEY))
        store.clear()
        assertNull(store.read())
        assertFalse(secure.contains(CloudAuthSessionStore.KEY))
        assertFalse(legacy.contains(CloudAuthSessionStore.KEY))
    }

    @Test fun failedEncryptedCommitDoesNotRemoveRecoverableLegacyCopy() {
        val storage=SelfHostedPushSettingsTest.FakePushPrefs()
        val secure=object : SharedPreferences by storage {
            override fun edit(): SharedPreferences.Editor = object : SharedPreferences.Editor by storage.edit() {
                override fun putString(key: String,value: String?): SharedPreferences.Editor = this
                override fun commit()=false
            }
        }
        val legacy=SelfHostedPushSettingsTest.FakePushPrefs()
        legacy.edit().putString(CloudAuthSessionStore.KEY,"opaque-test-session").commit()
        try { CloudAuthSessionStore(secure,legacy).read(); fail("expected durable-write failure") }
        catch(_: IllegalStateException) { }
        assertEquals("opaque-test-session",legacy.getString(CloudAuthSessionStore.KEY,null))
    }

    @Test fun successfulCommitWithoutMatchingReadbackDoesNotRemoveLegacyCopy() {
        val storage=SelfHostedPushSettingsTest.FakePushPrefs()
        val secure=object : SharedPreferences by storage {
            override fun getString(key: String,defValue: String?) = null
        }
        val legacy=SelfHostedPushSettingsTest.FakePushPrefs()
        legacy.edit().putString(CloudAuthSessionStore.KEY,"opaque-test-session").commit()
        try { CloudAuthSessionStore(secure,legacy).read(); fail("expected readback failure") }
        catch(_: IllegalStateException) { }
        assertEquals("opaque-test-session",legacy.getString(CloudAuthSessionStore.KEY,null))
    }

    @Test fun existingEncryptedSessionWinsOverOlderPlaintextSession() {
        val secure=SelfHostedPushSettingsTest.FakePushPrefs()
        val legacy=SelfHostedPushSettingsTest.FakePushPrefs()
        secure.edit().putString(CloudAuthSessionStore.KEY,"current").commit()
        legacy.edit().putString(CloudAuthSessionStore.KEY,"old").commit()
        assertEquals("current",CloudAuthSessionStore(secure,legacy).read())
        assertFalse(legacy.contains(CloudAuthSessionStore.KEY))
    }

    @Test fun processLocalValueAfterFailedCommitDoesNotFalselyVerifyMigrationOnNextRead() {
        val storage=SelfHostedPushSettingsTest.FakePushPrefs()
        val secure=object : SharedPreferences by storage {
            override fun edit(): SharedPreferences.Editor {
                val underlying=storage.edit()
                return object : SharedPreferences.Editor by underlying {
                    override fun putString(key: String,value: String?): SharedPreferences.Editor {
                        underlying.putString(key,value); return this
                    }
                    override fun commit(): Boolean { underlying.apply(); return false }
                }
            }
        }
        val legacy=SelfHostedPushSettingsTest.FakePushPrefs()
        legacy.edit().putString(CloudAuthSessionStore.KEY,"opaque-test-session").commit()
        val store=CloudAuthSessionStore(secure,legacy)
        repeat(2) {
            try { store.read(); fail("expected durable-write failure") } catch(_: IllegalStateException) { }
            assertEquals("opaque-test-session",legacy.getString(CloudAuthSessionStore.KEY,null))
        }
    }
}
