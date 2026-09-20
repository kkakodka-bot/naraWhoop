package com.noop.push

import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PushEnrollmentManagerTest {
    @Test fun successfulExchangePersistsCredentialAndMarksPushReady() = runBlocking {
        val plain = SelfHostedPushSettingsTest.FakePushPrefs()
        val secure = SelfHostedPushSettingsTest.FakePushPrefs()
        val settings = SelfHostedPushSettings.forTest(plain, ENDPOINT, FLEET_TOKEN)
        var changes = 0
        settings.setEnabled(false)
        val manager = manager(settings, secure) { changes++ }

        val result = manager.enroll("ONE-TIME-CODE")

        assertTrue(result is PushEnrollmentResult.Success)
        assertEquals(1, changes)
        assertTrue(settings.snapshot().enabled)
        assertTrue(settings.snapshot().hasEnrollment)
        assertTrue(settings.snapshot().ready)
        assertEquals((result as PushEnrollmentResult.Success).credential, manager.currentCredential())
        assertFalse(plain.all.values.any { it == "ONE-TIME-CODE" })
        assertFalse(secure.all.values.any { it == "ONE-TIME-CODE" })
        assertFalse(plain.all.values.any { it == USER_ID || it == TOKEN_ID || it == UPLOAD_TOKEN })
    }

    @Test fun existingSourceCannotBeSilentlyReassignedToAnotherUser() = runBlocking {
        val plain = SelfHostedPushSettingsTest.FakePushPrefs()
        val secure = SelfHostedPushSettingsTest.FakePushPrefs()
        val settings = SelfHostedPushSettings.forTest(plain, ENDPOINT, FLEET_TOKEN)
        val store = PushEnrollmentStore.forTest(secure)
        val first = manager(settings, secure, userId = USER_ID)
        assertTrue(first.enroll("FIRST") is PushEnrollmentResult.Success)
        val original = store.load(settings.sourceId())

        val second = manager(settings, secure, userId = OTHER_USER_ID).enroll("SECOND")

        assertEquals(PushEnrollmentFailureCode.IDENTITY_CONFLICT, (second as PushEnrollmentResult.Failure).code)
        assertEquals(original, store.load(settings.sourceId()))
    }

    private fun manager(
        settings: SelfHostedPushSettings,
        secure: SelfHostedPushSettingsTest.FakePushPrefs,
        userId: String = USER_ID,
        onChanged: () -> Unit = {},
    ): PushEnrollmentManager = PushEnrollmentManager(
        settings = settings,
        store = PushEnrollmentStore.forTest(secure),
        clientFactory = { endpoint, fleetToken, appVersion ->
            val client = OkHttpClient.Builder().addInterceptor { chain ->
                if (chain.request().method == "GET") return@addInterceptor enrollmentCapabilitiesResponse(chain.request(), userId, settings.sourceId())
                val requestBody = JSONObject(Buffer().also { chain.request().body!!.writeTo(it) }.readUtf8())
                val response = JSONObject()
                    .put("type", PushEnrollmentClient.RESPONSE_TYPE)
                    .put("protocolVersion", PushEnrollmentClient.PROTOCOL_VERSION)
                    .put("userId", userId)
                    .put("sourceId", requestBody.getString("sourceId"))
                    .put("tokenId", TOKEN_ID)
                    .put("uploadToken", UPLOAD_TOKEN)
                Response.Builder()
                    .request(chain.request())
                    .protocol(Protocol.HTTP_1_1)
                    .code(200)
                    .message("ok")
                    .body(response.toString().toResponseBody())
                    .build()
            }.build()
            PushEnrollmentClient(endpoint, fleetToken, appVersion, client)
        },
        appVersion = "11.1.1-test",
        onCredentialChanged = onChanged,
    )

    private companion object {
        const val ENDPOINT = "https://receiver.example/functions/v1/push"
        const val FLEET_TOKEN = "noop_fleet_secret"
        const val USER_ID = "00000000-0000-4000-8000-000000000010"
        const val OTHER_USER_ID = "00000000-0000-4000-8000-000000000011"
        const val TOKEN_ID = "00000000-0000-4000-8000-000000000012"
        const val UPLOAD_TOKEN = "noop_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
}
