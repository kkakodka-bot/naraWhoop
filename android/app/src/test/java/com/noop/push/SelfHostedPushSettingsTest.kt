package com.noop.push

import android.content.SharedPreferences
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SelfHostedPushSettingsTest {
    @Test fun wifiOnlyDefaultsOnAndPersistsOptOut() {
        val plain = FakePushPrefs()
        val settings = SelfHostedPushSettings.forTest(plain)

        assertTrue(settings.snapshot().wifiOnly)
        settings.setWifiOnly(false)

        assertFalse(SelfHostedPushSettings.forTest(plain).snapshot().wifiOnly)
    }

    @Test fun binaryObjectsDefaultOnAndPersist() {
        val plain = FakePushPrefs()
        val settings = SelfHostedPushSettings.forTest(plain)

        assertTrue(settings.snapshot().binaryObjectsEnabled)
        settings.setBinaryObjectsEnabled(false)

        assertFalse(SelfHostedPushSettings.forTest(plain).snapshot().binaryObjectsEnabled)
    }

    @Test fun defaultsOnButCannotEnableWithoutBundleEndpointAndToken() {
        val settings = SelfHostedPushSettings.forTest(FakePushPrefs())
        assertTrue(settings.snapshot().enabled)
        assertFalse(settings.snapshot().ready)
        assertFalse(settings.setEnabled(true))
    }

    @Test fun blankBundleTokenTurnsReadinessOff() {
        val settings = SelfHostedPushSettings.forTest(
            FakePushPrefs(),
            bundleEndpoint = "https://example.com/push",
            bundleToken = "   ",
        )

        assertNull(settings.fleetToken())
        assertFalse(settings.snapshot().ready)
        assertFalse(settings.setEnabled(true))
    }

    @Test fun fleetConfigurationAloneIsNotReadyWithoutEnrollment() {
        val settings = SelfHostedPushSettings.forTest(
            FakePushPrefs(),
            bundleEndpoint = "https://example.com/push",
            bundleToken = "fleet-secret",
        )

        assertFalse(settings.snapshot().hasEnrollment)
        assertFalse(settings.snapshot().ready)
        assertFalse(settings.setEnabled(true))
    }

    @Test fun progressNamespaceDiffersPerEndpointAndIsStable() {
        val settings = SelfHostedPushSettings.forTest(FakePushPrefs())
        val first = (PushEndpointPolicy.validate("https://one.example/push") as PushEndpointPolicy.Result.Valid).endpoint
        val second = (PushEndpointPolicy.validate("https://two.example/push") as PushEndpointPolicy.Result.Valid).endpoint

        val firstNamespace = settings.progressNamespace(USER_A, SOURCE_A, first)

        assertNotEquals(firstNamespace, settings.progressNamespace(USER_A, SOURCE_A, second))
        assertNotEquals(firstNamespace, settings.progressNamespace(USER_B, SOURCE_A, first))
        assertTrue(firstNamespace == settings.progressNamespace(USER_A, SOURCE_A, first))
    }

    @Test fun receiverStateAndNegotiatedVersionFenceProgressAtTheSameEndpoint() {
        val settings = SelfHostedPushSettings.forTest(FakePushPrefs())
        val endpoint = (PushEndpointPolicy.validate("https://one.example/push") as PushEndpointPolicy.Result.Valid).endpoint

        val first = settings.progressNamespace(USER_A, SOURCE_A, endpoint, "1.0", "00000000-0000-4000-8000-000000000001")
        val resetReceiver = settings.progressNamespace(USER_A, SOURCE_A, endpoint, "1.0", "00000000-0000-4000-8000-000000000002")
        val upgradedProtocol = settings.progressNamespace(USER_A, SOURCE_A, endpoint, "1.1", "00000000-0000-4000-8000-000000000001")

        assertNotEquals(first, resetReceiver)
        assertNotEquals(first, upgradedProtocol)
    }

    @Test fun progressIsPersistedAndSuccessOnlyAppearsAfterCatchUpCompletes() {
        val settings = SelfHostedPushSettings.forTest(
            FakePushPrefs(),
            bundleEndpoint = "https://example.com/push",
            bundleToken = "secret",
        )
        enroll(settings)
        assertTrue(settings.setEnabled(true))

        settings.recordPushStarted()
        settings.recordAcceptedBatches(4, records = 12_000)
        settings.recordContinuation()

        val continuing = settings.snapshot()
        assertEquals(SelfHostedPushSettings.RunState.CONTINUING, continuing.runState)
        assertEquals(4, continuing.acceptedBatches)
        assertEquals(12_000L, continuing.acceptedRecords)
        assertNull(continuing.lastSuccessAt)
        assertNull(continuing.lastError)

        settings.recordAcceptedBatches(3, records = 8_000)
        settings.recordSuccess(atMillis = 1234L)
        val complete = settings.snapshot()
        assertEquals(SelfHostedPushSettings.RunState.COMPLETE, complete.runState)
        assertEquals(7, complete.acceptedBatches)
        assertEquals(20_000L, complete.acceptedRecords)
        assertEquals(1234L, complete.lastSuccessAt)
    }

    @Test fun disableIsImmediatelyIdleAndRejectsLateWorkerStatusWrites() {
        val settings = SelfHostedPushSettings.forTest(
            FakePushPrefs(),
            bundleEndpoint = "https://example.com/push",
            bundleToken = "secret",
        )
        enroll(settings)
        assertTrue(settings.setEnabled(true))
        settings.recordPushStarted()
        settings.recordRunning()

        assertTrue(settings.setEnabled(false))
        assertEquals(SelfHostedPushSettings.RunState.IDLE, settings.snapshot().runState)

        settings.recordContinuation()
        settings.recordRetrying("late retry")
        settings.recordSuccess(999L)
        val stopped = settings.snapshot()
        assertEquals(SelfHostedPushSettings.RunState.IDLE, stopped.runState)
        assertNull(stopped.lastError)
        assertNull(stopped.lastSuccessAt)
    }

    @Test fun capabilitiesAreVisibleOnlyWhenRecordedForTheBundleEndpoint() {
        val settings = SelfHostedPushSettings.forTest(
            FakePushPrefs(),
            bundleEndpoint = "https://one.example/push",
            bundleToken = "secret",
        )
        val first = (PushEndpointPolicy.validate("https://one.example/push") as PushEndpointPolicy.Result.Valid).endpoint
        val second = (PushEndpointPolicy.validate("https://two.example/push") as PushEndpointPolicy.Result.Valid).endpoint

        settings.recordCapabilities(
            first,
            PushCapabilities(
                appendTables = setOf(PushAppendTable.HR_SAMPLE),
                mutableTables = setOf(PushMutableTable.JOURNAL),
            ),
            atMillis = 1234L,
        )

        assertEquals(listOf("hrSample", "journal"), settings.snapshot().supportedStreams)
        assertEquals(1234L, settings.snapshot().capabilitiesCheckedAt)

        // Capabilities recorded against any other destination must not surface for this build's endpoint.
        settings.recordCapabilities(second, PushCapabilities.ALL, atMillis = 2345L)
        assertNull(settings.snapshot().supportedStreams)
        assertNull(settings.snapshot().capabilitiesCheckedAt)
    }

    @Test fun liveStreamIsVisibleDuringWorkAndClearedAfterCompleteCatchUp() {
        val settings = SelfHostedPushSettings.forTest(
            FakePushPrefs(),
            bundleEndpoint = "https://example.com/push",
            bundleToken = "secret",
        )
        enroll(settings)
        assertTrue(settings.setEnabled(true))
        settings.recordRunning()

        settings.recordCurrentStream("rrInterval")
        assertEquals("rrInterval", settings.snapshot().currentStream)

        settings.recordSuccess(atMillis = 999L)
        assertNull(settings.snapshot().currentStream)
    }

    @Test fun cycleFailurePersistsOnlyStructuredCategoryAndStatus() {
        val plain = FakePushPrefs()
        val settings = SelfHostedPushSettings.forTest(plain)
        val failure = PushFailure(PushFailureCode.HTTP_AUTH, 401)

        settings.saveCycleFailure("receiver-a", failure)

        assertEquals(failure, settings.cycleFailure("receiver-a"))
        assertFalse(plain.all.values.any { it.toString().contains("secret.example") })
        settings.saveCycleFailure("receiver-a", null)
        assertNull(settings.cycleFailure("receiver-a"))
    }

    @Test fun boundedReceiverErrorCodeSurvivesContinuationWithoutArbitraryText() {
        val plain = FakePushPrefs()
        val settings = SelfHostedPushSettings.forTest(plain)
        val failure = PushFailure(PushFailureCode.HTTP_PROTOCOL_REJECTED, 422, "registry_mismatch")

        settings.saveCycleFailure("receiver-a", failure)

        assertEquals(failure, settings.cycleFailure("receiver-a"))
        assertFalse(plain.all.values.any { it.toString().contains("response body") })
    }

    private fun enroll(settings: SelfHostedPushSettings) {
        val sourceId = settings.sourceId()
        settings.recordEnrollmentBinding(
            PushEnrollmentCredential(USER_A, sourceId, TOKEN_ID, UPLOAD_TOKEN),
        )
    }

    private companion object {
        const val USER_A = "00000000-0000-4000-8000-000000000010"
        const val USER_B = "00000000-0000-4000-8000-000000000011"
        const val SOURCE_A = "00000000-0000-4000-8000-000000000012"
        const val TOKEN_ID = "00000000-0000-4000-8000-000000000013"
        const val UPLOAD_TOKEN = "noop_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }

    internal class FakePushPrefs : SharedPreferences {
        private val map = HashMap<String, Any?>()
        override fun getBoolean(key: String, defValue: Boolean) = map[key] as? Boolean ?: defValue
        override fun getLong(key: String, defValue: Long) = map[key] as? Long ?: defValue
        override fun getString(key: String, defValue: String?) = map[key] as? String ?: defValue
        override fun getInt(key: String, defValue: Int) = map[key] as? Int ?: defValue
        override fun getFloat(key: String, defValue: Float) = map[key] as? Float ?: defValue
        @Suppress("UNCHECKED_CAST")
        override fun getStringSet(key: String, defValues: MutableSet<String>?) =
            map[key] as? MutableSet<String> ?: defValues
        override fun getAll(): MutableMap<String, *> = HashMap(map)
        override fun contains(key: String) = map.containsKey(key)
        override fun registerOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit
        override fun unregisterOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit
        override fun edit(): SharedPreferences.Editor = Editor()

        private inner class Editor : SharedPreferences.Editor {
            private val pending = HashMap<String, Any?>()
            private val removals = HashSet<String>()
            override fun putString(key: String, value: String?) = apply { pending[key] = value }
            override fun putStringSet(key: String, values: MutableSet<String>?) = apply { pending[key] = values }
            override fun putInt(key: String, value: Int) = apply { pending[key] = value }
            override fun putLong(key: String, value: Long) = apply { pending[key] = value }
            override fun putFloat(key: String, value: Float) = apply { pending[key] = value }
            override fun putBoolean(key: String, value: Boolean) = apply { pending[key] = value }
            override fun remove(key: String) = apply { removals += key }
            override fun clear() = apply { map.clear() }
            override fun commit(): Boolean { flush(); return true }
            override fun apply() = flush()
            private fun flush() {
                removals.forEach(map::remove)
                map.putAll(pending)
            }
        }
    }
}
