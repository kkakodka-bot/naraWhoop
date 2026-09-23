package com.noop.push

import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test

class PushObjectExpiryTest {
    @Test fun expiredUploadUrlProducesRecoverableDebtInsteadOfAccountRevocation() = runBlocking {
        val client = OkHttpClient.Builder().addInterceptor { chain ->
            assertNull(chain.request().header("Authorization"))
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1)
                .code(403).message("expired").body(ByteArray(0).toResponseBody()).build()
        }.build()
        val endpoint = (PushEndpointPolicy.validate("https://receiver.example/push") as PushEndpointPolicy.Result.Valid).endpoint
        val transport = PushHttpTransport(endpoint, "noop_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "fleet-fixture", uploadClient = client)
        try {
            transport.uploadObject(PushObjectIntent("00000000-0000-4000-8000-000000000010", "exact/key",
                "https://storage.example/put", emptyMap(), "2020-01-01T00:00:00Z", false), byteArrayOf(1, 2, 3))
            fail("Expected expired upload failure")
        } catch (failure: PushTransportException) {
            assertTrue("URL expiry must renew on the next bounded retry without reopening", failure.failure.retryable)
            assertFalse("Storage URL expiry is not evidence of account revocation", failure.failure.code == PushFailureCode.HTTP_AUTH)
        }
    }
}
