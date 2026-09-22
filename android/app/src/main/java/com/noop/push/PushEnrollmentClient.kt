package com.noop.push

import java.io.IOException
import java.net.URI
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import org.json.JSONObject

enum class PushEnrollmentFailureCode {
    INVALID_REQUEST,
    NOT_CONFIGURED,
    UNAUTHORIZED,
    CODE_REJECTED,
    RATE_LIMITED,
    SERVER,
    HTTP,
    NETWORK,
    INVALID_RESPONSE,
    IDENTITY_CONFLICT,
    STORAGE,
}

sealed interface PushEnrollmentResult {
    data class Success(val credential: PushEnrollmentCredential) : PushEnrollmentResult

    data class Failure(
        val code: PushEnrollmentFailureCode,
        val retryable: Boolean = false,
        val httpStatus: Int? = null,
    ) : PushEnrollmentResult
}

/** One-time enrollment exchange. It never logs or retains the submitted code. */
class PushEnrollmentClient(
    private val endpoint: PushEndpointPolicy.ValidEndpoint,
    private val fleetToken: String,
    private val appVersion: String,
    private val client: OkHttpClient = defaultClient(),
) {
    suspend fun confirmWearable(item: WearableAssociationStore.Association, credential: PushEnrollmentCredential) {
        val witness = "device_information_serial_v1:${credential.sourceId}:${item.provisional}:${item.serial}"
        val digest = java.security.MessageDigest.getInstance("SHA-256").digest(witness.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it.toInt() and 255) }
        val body = JSONObject().put("provisionalExternalDeviceId",item.provisional).put("evidence",JSONObject()
            .put("method","device_information_serial_v1").put("serial",item.serial).put("receiptSha256",digest))
        val response = execute(Request.Builder().url(endpoint.url.trimEnd('/') + "/wearables/confirm")
            .header("Authorization","Bearer ${credential.uploadToken}").header("x-noop-fleet-token",fleetToken)
            .post(body.toString().toRequestBody(JSON_MEDIA_TYPE)).build())
        check(response.statusCode == 200 && response.body.size <= MAX_RESPONSE_BYTES) { "Wearable confirmation unavailable" }
        val receipt = JSONObject(response.body.toString(Charsets.UTF_8))
        check(receipt.optString("userId") == credential.userId && receipt.optString("sourceId") == credential.sourceId &&
            receipt.optString("state") == "confirmed" && PushEnrollmentCredential.isCanonicalUuid(receipt.optString("deviceId")))
    }

    suspend fun retire(credential: PushEnrollmentCredential) {
        val request = Request.Builder().url(endpoint.url.trimEnd('/') + "/installation/retire")
            .header("Authorization", "Bearer ${credential.uploadToken}")
            .header("x-noop-fleet-token", fleetToken).header("Cache-Control", "no-store")
            .post(ByteArray(0).toRequestBody(JSON_MEDIA_TYPE)).build()
        val response = execute(request)
        check(response.statusCode == 200 && response.body.size <= MAX_RESPONSE_BYTES) { "Retirement unavailable" }
        val receipt = JSONObject(response.body.toString(Charsets.UTF_8))
        check(receipt.optString("userId") == credential.userId && receipt.optString("sourceId") == credential.sourceId &&
            PushEnrollmentCredential.isCanonicalUuid(receipt.optString("retirementId")) &&
            receipt.optString("policy") == "retain_original_owner") { "Invalid retirement receipt" }
    }

    suspend fun enroll(code: String, sourceId: String): PushEnrollmentResult {
        val normalizedCode = code.trim()
        if (!validCode(normalizedCode) ||
            !PushEnrollmentCredential.isCanonicalUuid(sourceId) ||
            appVersion.isBlank() || appVersion.length > MAX_APP_VERSION_CHARS || appVersion.any { it.isISOControl() } ||
            !PushEnrollmentCredential.isValidFleetToken(fleetToken)
        ) {
            return PushEnrollmentResult.Failure(PushEnrollmentFailureCode.INVALID_REQUEST)
        }
        val body = JSONObject()
            .put("code", normalizedCode)
            .put("sourceId", sourceId)
            .put("platform", PLATFORM)
            .put("appVersion", appVersion)
            .toString()
            .toByteArray(Charsets.UTF_8)
        val request = Request.Builder()
            .url(enrollmentUrl(endpoint))
            .header("Authorization", "Bearer $fleetToken")
            .header("Accept", "application/json")
            .post(body.toRequestBody(JSON_MEDIA_TYPE))
            .build()
        val response = try {
            execute(request)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            return PushEnrollmentResult.Failure(PushEnrollmentFailureCode.NETWORK, retryable = true)
        }
        if (response.statusCode !in 200..299) return failureForStatus(response.statusCode)
        if (response.body.size > MAX_RESPONSE_BYTES) {
            return PushEnrollmentResult.Failure(PushEnrollmentFailureCode.INVALID_RESPONSE)
        }
        val parsed = parseResponse(response.body, sourceId)
        if (parsed !is PushEnrollmentResult.Success) return parsed
        return when (val capabilities = PushHttpTransport(endpoint, parsed.credential.uploadToken, fleetToken, client).capabilities()) {
            is PushCapabilitiesResult.Available -> if (capabilities.capabilities.userId == parsed.credential.userId &&
                capabilities.capabilities.sourceId == parsed.credential.sourceId) parsed
                else PushEnrollmentResult.Failure(PushEnrollmentFailureCode.INVALID_RESPONSE)
            is PushCapabilitiesResult.Rejected -> PushEnrollmentResult.Failure(
                PushEnrollmentFailureCode.INVALID_RESPONSE, retryable = capabilities.retryable)
        }
    }

    private suspend fun execute(request: Request): EnrollmentHttpResponse {
        try {
            return client.newCall(request).await().use { response ->
                val input = response.body?.byteStream()
                val bytes = input?.use {
                    val bounded = ByteArray(MAX_RESPONSE_BYTES + 1)
                    var total = 0
                    while (total < bounded.size) {
                        val read = it.read(bounded, total, bounded.size - total)
                        if (read < 0) break
                        total += read
                    }
                    bounded.copyOf(total)
                } ?: ByteArray(0)
                EnrollmentHttpResponse(response.code, bytes)
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (io: IOException) {
            throw io
        }
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    private suspend fun Call.await(): Response = suspendCancellableCoroutine { continuation ->
        continuation.invokeOnCancellation { cancel() }
        enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                if (continuation.isActive) continuation.resumeWithException(e)
            }

            override fun onResponse(call: Call, response: Response) {
                if (continuation.isActive) {
                    continuation.resume(response) { response.close() }
                } else {
                    response.close()
                }
            }
        })
    }

    private data class EnrollmentHttpResponse(val statusCode: Int, val body: ByteArray)

    companion object {
        const val PLATFORM = "android"
        const val MAX_CODE_CHARS = 128
        const val MAX_APP_VERSION_CHARS = 64
        const val MAX_RESPONSE_BYTES = 16 * 1024
        const val RESPONSE_TYPE = "enrollment"
        const val PROTOCOL_VERSION = "1.1"
        private val JSON_MEDIA_TYPE = "application/json; charset=utf-8".toMediaType()
        private val RESPONSE_FIELDS =
            setOf("type", "protocolVersion", "userId", "sourceId", "tokenId", "uploadToken")

        internal fun enrollmentUrl(endpoint: PushEndpointPolicy.ValidEndpoint): String {
            val base = URI(endpoint.url)
            val path = (base.path.takeUnless { it.isNullOrEmpty() } ?: "/").removeSuffix("/") + "/enroll"
            return URI(base.scheme, base.authority, path, null, null).toASCIIString()
        }

        internal fun parseResponse(body: ByteArray, expectedSourceId: String): PushEnrollmentResult {
            if (body.isEmpty() || body.size > MAX_RESPONSE_BYTES) {
                return PushEnrollmentResult.Failure(PushEnrollmentFailureCode.INVALID_RESPONSE)
            }
            val objectValue = runCatching { JSONObject(body.toString(Charsets.UTF_8)) }.getOrNull()
                ?: return PushEnrollmentResult.Failure(PushEnrollmentFailureCode.INVALID_RESPONSE)
            if (objectValue.keys().asSequence().toSet() != RESPONSE_FIELDS) {
                return PushEnrollmentResult.Failure(PushEnrollmentFailureCode.INVALID_RESPONSE)
            }
            if (objectValue.opt("type") != RESPONSE_TYPE || objectValue.opt("protocolVersion") != PROTOCOL_VERSION) {
                return PushEnrollmentResult.Failure(PushEnrollmentFailureCode.INVALID_RESPONSE)
            }
            val userId = objectValue.opt("userId") as? String
                ?: return PushEnrollmentResult.Failure(PushEnrollmentFailureCode.INVALID_RESPONSE)
            val sourceId = objectValue.opt("sourceId") as? String
                ?: return PushEnrollmentResult.Failure(PushEnrollmentFailureCode.INVALID_RESPONSE)
            val tokenId = objectValue.opt("tokenId") as? String
                ?: return PushEnrollmentResult.Failure(PushEnrollmentFailureCode.INVALID_RESPONSE)
            val uploadToken = objectValue.opt("uploadToken") as? String
                ?: return PushEnrollmentResult.Failure(PushEnrollmentFailureCode.INVALID_RESPONSE)
            if (sourceId != expectedSourceId) {
                return PushEnrollmentResult.Failure(PushEnrollmentFailureCode.INVALID_RESPONSE)
            }
            val credential = runCatching {
                PushEnrollmentCredential(userId, sourceId, tokenId, uploadToken)
            }.getOrNull() ?: return PushEnrollmentResult.Failure(PushEnrollmentFailureCode.INVALID_RESPONSE)
            return PushEnrollmentResult.Success(credential)
        }

        internal fun failureForStatus(status: Int): PushEnrollmentResult.Failure = when (status) {
            401, 403 -> PushEnrollmentResult.Failure(PushEnrollmentFailureCode.UNAUTHORIZED, httpStatus = status)
            400, 404, 409, 410, 422 ->
                PushEnrollmentResult.Failure(PushEnrollmentFailureCode.CODE_REJECTED, httpStatus = status)
            408 -> PushEnrollmentResult.Failure(PushEnrollmentFailureCode.NETWORK, retryable = true, httpStatus = status)
            429 -> PushEnrollmentResult.Failure(PushEnrollmentFailureCode.RATE_LIMITED, retryable = true, httpStatus = status)
            in 500..599 -> PushEnrollmentResult.Failure(PushEnrollmentFailureCode.SERVER, retryable = true, httpStatus = status)
            else -> PushEnrollmentResult.Failure(PushEnrollmentFailureCode.HTTP, httpStatus = status)
        }

        private fun validCode(value: String): Boolean =
            value.length in 4..MAX_CODE_CHARS && value.all { !it.isISOControl() }

        private fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
            .followRedirects(false)
            .followSslRedirects(false)
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(15, TimeUnit.SECONDS)
            .writeTimeout(15, TimeUnit.SECONDS)
            .callTimeout(15, TimeUnit.SECONDS)
            .build()
    }
}
