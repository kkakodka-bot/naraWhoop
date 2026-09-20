package com.noop.push

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class DeviceLinkStoreTest {
    private val identity = DeviceLinkStore.Identity("https://example.test/functions/v1/push", "11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222", "whoop-SERIAL")
    private val canonical = "33333333-3333-3333-3333-333333333333"
    private fun receipt() = JSONObject().put("identity", JSONObject().put("userId", identity.owner)
        .put("sourceId", identity.source).put("externalDeviceId", identity.device).put("deviceId", canonical))

    @Test fun firstInstallRequiresAckAndConfirmedBindingSurvivesOfflineReopen() {
        val prefs = SelfHostedPushSettingsTest.FakePushPrefs()
        assertNull(DeviceLinkStore(prefs).confirmed(identity))
        DeviceLinkStore(prefs).record(identity, receipt().toString())
        assertEquals(canonical, DeviceLinkStore(prefs).confirmed(identity))
    }

    @Test fun acknowledgementNeverCrossesOwnerSourceDeviceOrEndpoint() {
        val store = DeviceLinkStore(SelfHostedPushSettingsTest.FakePushPrefs())
        store.record(identity, receipt().toString())
        for (other in listOf(identity.copy(owner = "other"), identity.copy(source = "other"),
            identity.copy(device = "whoop-OTHER"), identity.copy(endpoint = "https://elsewhere.test/functions/v1/push"))) {
            assertNull(store.confirmed(other))
        }
    }

    @Test fun wrongOrIncompleteServerReceiptNeverMarksReady() {
        val store = DeviceLinkStore(SelfHostedPushSettingsTest.FakePushPrefs())
        for (key in listOf("userId", "sourceId", "externalDeviceId", "deviceId")) {
            val response = receipt(); response.getJSONObject("identity").put(key, "wrong")
            assertTrue(runCatching { store.record(identity, response.toString()) }.isFailure)
            assertNull(store.confirmed(identity))
        }
    }
}
