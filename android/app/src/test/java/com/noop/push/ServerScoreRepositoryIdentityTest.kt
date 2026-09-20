package com.noop.push

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Uses the real v2 parser/session/cache without adding an Android runtime test dependency. */
class ServerScoreRepositoryIdentityTest {
    private val owner = "11111111-1111-1111-1111-111111111111"
    private val source = "44444444-4444-4444-4444-444444444444"
    private val device = "22222222-2222-2222-2222-222222222222"
    private val local = "whoop-SERIAL123"
    private val credential = PushEnrollmentCredential(owner, source, "55555555-5555-5555-5555-555555555555", "noop_" + "a".repeat(43))
    private fun body(): JSONObject = JSONObject(javaClass.getResource("/server_physiology_snapshot.json")!!.readText())
        .put("identity", JSONObject().put("userId", owner).put("sourceId", source).put("deviceId", device).put("externalDeviceId", local))

    @Test fun enrolledReceiptBindsOwnerInstallationAndStrap() {
        ServerScoreClient.validateEnrollmentReceipt(body().toString(), credential, local)
        for (key in listOf("userId", "sourceId", "externalDeviceId", "deviceId")) {
            val root = body()
            root.getJSONObject("identity").put(key, "wrong")
            assertTrue(key, runCatching { ServerScoreClient.validateEnrollmentReceipt(root.toString(), credential, local) }.isFailure)
        }
    }

    @Test fun registrationRequiresCanonicalDeviceAndExactEcho() {
        assertEquals(device, ServerScoreClient.validateIdentityReceipt(body(), credential, local, true))
        val root = body(); root.getJSONObject("identity").put("deviceId", JSONObject.NULL)
        assertTrue(runCatching { ServerScoreClient.validateIdentityReceipt(root, credential, local, true) }.isFailure)
    }

    @Test fun delayedErrorFallbackCannotRestoreAnOldAccountOrStrap() {
        val cache = ServerScoreClient.parseSnapshot(body().toString(), "2026-09-16", owner)
        val state = ServerScoreSessionState(); state.activate(owner)
        val epoch = state.generation(); val request = state.beginRequest(cache.day)
        // Re-selecting the same owner after a source/device change still rotates the generation.
        state.activate(owner)
        assertFalse(state.isCurrentRequest(cache.day, epoch, owner, request))
        assertFalse(state.accept(cache, epoch, owner, request))
        assertNull(state.overlay(cache.day, owner))
    }
}
