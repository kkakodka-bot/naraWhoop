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
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PushEnrollmentClientTest {
    @Test fun enrollmentUsesFleetAuthorizationAndExactRequestContract() = runBlocking {
        var method = ""
        var url = ""
        var authorization: String? = null
        var fleetHeader: String? = null
        var contentType: String? = null
        var requestJson: JSONObject? = null
        val client = OkHttpClient.Builder().addInterceptor { chain ->
            val request = chain.request()
            if (request.method == "GET") {
                assertEquals("Bearer $UPLOAD_TOKEN", request.header("Authorization"))
                assertEquals(FLEET_TOKEN, request.header(PushHttpTransport.FLEET_TOKEN_HEADER))
                return@addInterceptor enrollmentCapabilitiesResponse(request, USER_ID, SOURCE_ID)
            }
            method = request.method
            url = request.url.toString()
            authorization = request.header("Authorization")
            fleetHeader = request.header(PushHttpTransport.FLEET_TOKEN_HEADER)
            contentType = request.body?.contentType()?.toString()
            requestJson = JSONObject(Buffer().also { request.body!!.writeTo(it) }.readUtf8())
            enrollmentResponse(request, SOURCE_ID)
        }.build()

        val result = PushEnrollmentClient(endpoint(), FLEET_TOKEN, APP_VERSION, client)
            .enroll("  CODE-123  ", SOURCE_ID)

        assertTrue(result is PushEnrollmentResult.Success)
        assertEquals("POST", method)
        assertEquals("https://receiver.example/functions/v1/push/enroll", url)
        assertEquals("Bearer $FLEET_TOKEN", authorization)
        assertNull(fleetHeader)
        assertEquals("application/json; charset=utf-8", contentType)
        assertEquals(setOf("code", "sourceId", "platform", "appVersion"), requestJson!!.keys().asSequence().toSet())
        assertEquals("CODE-123", requestJson!!.getString("code"))
        assertEquals(SOURCE_ID, requestJson!!.getString("sourceId"))
        assertEquals("android", requestJson!!.getString("platform"))
        assertEquals(APP_VERSION, requestJson!!.getString("appVersion"))
    }

    @Test fun strictResponseRejectsWrongSourceProtocolTypeAndExtraMembers() {
        fun response(transform: JSONObject.() -> Unit): PushEnrollmentResult {
            val body = validResponse(SOURCE_ID).apply(transform).toString().toByteArray()
            return PushEnrollmentClient.parseResponse(body, SOURCE_ID)
        }

        assertEquals(
            PushEnrollmentFailureCode.INVALID_RESPONSE,
            (response { put("sourceId", OTHER_SOURCE_ID) } as PushEnrollmentResult.Failure).code,
        )
        assertEquals(
            PushEnrollmentFailureCode.INVALID_RESPONSE,
            (response { put("protocolVersion", "1.0") } as PushEnrollmentResult.Failure).code,
        )
        assertEquals(
            PushEnrollmentFailureCode.INVALID_RESPONSE,
            (response { put("type", "token") } as PushEnrollmentResult.Failure).code,
        )
        assertEquals(
            PushEnrollmentFailureCode.INVALID_RESPONSE,
            (response { put("unexpected", true) } as PushEnrollmentResult.Failure).code,
        )
        assertEquals(
            PushEnrollmentFailureCode.INVALID_RESPONSE,
            (response { put("uploadToken", "noop_too-short") } as PushEnrollmentResult.Failure).code,
        )
    }

    @Test fun redirectIsNotFollowedAndFailureContainsNoSecrets() = runBlocking {
        var calls = 0
        val client = OkHttpClient.Builder()
            .followRedirects(false)
            .followSslRedirects(false)
            .addInterceptor { chain ->
                calls++
                Response.Builder()
                    .request(chain.request())
                    .protocol(Protocol.HTTP_1_1)
                    .code(307)
                    .message("redirect")
                    .header("Location", "https://elsewhere.example/collect")
                    .body(ByteArray(0).toResponseBody())
                    .build()
            }
            .build()

        val result = PushEnrollmentClient(endpoint(), FLEET_TOKEN, APP_VERSION, client)
            .enroll("CODE-SECRET", SOURCE_ID)

        assertEquals(1, calls)
        assertTrue(result is PushEnrollmentResult.Failure)
        assertEquals(PushEnrollmentFailureCode.HTTP, (result as PushEnrollmentResult.Failure).code)
        assertFalse(result.toString().contains("CODE-SECRET"))
        assertFalse(result.toString().contains(FLEET_TOKEN))
    }

    @Test fun oversizedResponseFailsClosed() {
        val oversized = ByteArray(PushEnrollmentClient.MAX_RESPONSE_BYTES + 1) { 'x'.code.toByte() }
        val result = PushEnrollmentClient.parseResponse(oversized, SOURCE_ID)

        assertEquals(PushEnrollmentFailureCode.INVALID_RESPONSE, (result as PushEnrollmentResult.Failure).code)
    }

    @Test fun capabilityOwnerMismatchPreventsEnrollmentActivation() = runBlocking {
        val client = OkHttpClient.Builder().addInterceptor { chain ->
            if (chain.request().method == "GET") enrollmentCapabilitiesResponse(chain.request(), OTHER_SOURCE_ID, SOURCE_ID)
            else enrollmentResponse(chain.request(), SOURCE_ID)
        }.build()
        val result = PushEnrollmentClient(endpoint(), FLEET_TOKEN, APP_VERSION, client).enroll("CODE", SOURCE_ID)
        assertEquals(PushEnrollmentFailureCode.INVALID_RESPONSE, (result as PushEnrollmentResult.Failure).code)
    }

    private fun enrollmentResponse(request: okhttp3.Request, sourceId: String): Response = Response.Builder()
        .request(request)
        .protocol(Protocol.HTTP_1_1)
        .code(200)
        .message("ok")
        .body(validResponse(sourceId).toString().toResponseBody())
        .build()

    private fun validResponse(sourceId: String) = JSONObject()
        .put("type", PushEnrollmentClient.RESPONSE_TYPE)
        .put("protocolVersion", PushEnrollmentClient.PROTOCOL_VERSION)
        .put("userId", USER_ID)
        .put("sourceId", sourceId)
        .put("tokenId", TOKEN_ID)
        .put("uploadToken", UPLOAD_TOKEN)

    private fun endpoint() =
        (PushEndpointPolicy.validate("https://receiver.example/functions/v1/push") as PushEndpointPolicy.Result.Valid)
            .endpoint

    private companion object {
        const val USER_ID = "00000000-0000-4000-8000-000000000010"
        const val SOURCE_ID = "00000000-0000-4000-8000-000000000011"
        const val OTHER_SOURCE_ID = "00000000-0000-4000-8000-000000000012"
        const val TOKEN_ID = "00000000-0000-4000-8000-000000000013"
        const val UPLOAD_TOKEN = "noop_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        const val FLEET_TOKEN = "noop_fleet_secret"
        const val APP_VERSION = "11.1.1-test"
    }
}

internal fun enrollmentCapabilitiesResponse(request: okhttp3.Request, userId: String, sourceId: String): Response = Response.Builder()
    .request(request).protocol(Protocol.HTTP_1_1).code(200).message("ok")
    .body(JSONObject().put("type", "capabilities").put("protocolVersion", "1.1")
        .put("receiverStateId", "00000000-0000-4000-8000-000000000099")
        .put("userId", userId).put("sourceId", sourceId).put("streams", org.json.JSONArray())
        .toString().toResponseBody()).build()
