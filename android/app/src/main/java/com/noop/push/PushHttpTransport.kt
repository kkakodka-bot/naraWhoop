package com.noop.push

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.RequestBody
import okio.Buffer
import okio.BufferedSink
import okio.GzipSink
import okio.buffer
import java.io.IOException
import java.util.Base64
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** Minimal HTTP adapter: no redirects, no logging, and bounded acknowledgement/error reads. */
class PushHttpTransport(
    private val endpoint: PushEndpointPolicy.ValidEndpoint,
    private val uploadToken: String,
    private val fleetToken: String,
    private val client: OkHttpClient = defaultClient(),
    private val uploadClient: OkHttpClient = defaultUploadClient(),
    private val onBatchStart: (PushBatch) -> Unit = {},
    private val now: () -> java.time.Instant = { java.time.Instant.now() },
) : PushTransport {
    init {
        require(PushEnrollmentCredential.isValidUploadToken(uploadToken)) { "invalid upload authorization" }
        require(PushEnrollmentCredential.isValidFleetToken(fleetToken)) { "invalid fleet authorization" }
    }

    override suspend fun capabilities(): PushCapabilitiesResult {
        val request = Request.Builder()
            .url(endpoint.url)
            .pushAuthorization()
            .header("Accept", "application/json")
            .header(ACCEPT_VERSION_HEADER, PushProtocol.CAPABILITIES_ACCEPT_VERSIONS)
            .get()
            .build()
        val response = try {
            executeRequest(request)
        } catch (cancelled: kotlinx.coroutines.CancellationException) {
            throw cancelled
        } catch (failure: PushTransportException) {
            return PushCapabilitiesResult.Rejected(
                failure.failure.safeCode,
                failure.failure.retryable,
                failure.failure,
            )
        } catch (_: Throwable) {
            val failure = PushFailure(PushFailureCode.NETWORK_IO)
            return PushCapabilitiesResult.Rejected(failure.safeCode, failure.retryable, failure)
        }
        if (response.statusCode !in 200..299) {
            val failure = PushError.httpFailure(response.statusCode, response.body)
            return PushCapabilitiesResult.Rejected(failure.safeCode, failure.retryable, failure)
        }
        return try {
            PushCapabilitiesResult.Available(PushCapabilities.parse(response.body))
        } catch (invalid: PushProtocolException) {
            val failure = PushFailure(PushFailureCode.CAPABILITIES_INVALID)
            PushCapabilitiesResult.Rejected(failure.safeCode, failure.retryable, failure)
        }
    }

    override suspend fun post(batch: PushBatch): PushTransportResponse {
        runCatching { onBatchStart(batch) }
        val compressedBody = gzip(batch.body)
        val compressed = execute(compressedBody, contentEncoding = "gzip")
        if (compressed.statusCode != 415) return compressed
        // Protocol 1.0 allowed identity requests. A definitive media-type rejection is the only
        // signal that permits one compatibility attempt with the exact same decoded entity.
        return execute(batch.body, contentEncoding = null)
    }

    override suspend fun postBinary(batch: PushBinaryBatch): PushTransportResponse {
        val manifestHeader = Base64.getEncoder().encodeToString(batch.manifestJSON)
        return execute(
            body = batch.payload,
            contentEncoding = batch.contentEncoding,
            contentType = OCTET_STREAM,
            binaryObject = true,
            manifestHeader = manifestHeader,
        )
    }

    override suspend fun createObjectIntent(manifest: PushObjectManifest, lane: PushObjectLane): PushObjectIntent {
        val body = manifest.encode()
        if (body.size > 8 * 1024) throw PushTransportException(PushFailure(PushFailureCode.LOCAL_DATA))
        val request = Request.Builder()
            .url(laneUrl(lane.endpoint))
            .pushAuthorization()
            .header("Accept", "application/json")
            .header("Content-Type", "application/json")
            .post(FixedRequestBody(body, "application/json"))
            .build()
        val response = executeRequest(request)
        if (response.statusCode !in 200..299) {
            throw PushTransportException(
                PushError.httpFailure(
                    response.statusCode,
                    response.body, PushProtocol.OBJECT_VERSION,
                    PushBinaryTable.entries.firstOrNull { it.wireName == manifest.stream },
                ),
            )
        }
        return try {
            PushObjectIntentParser.parse(response.body, manifest.objectId)
        } catch (_: PushProtocolException) {
            throw PushTransportException(PushFailure(PushFailureCode.ACK_INVALID))
        }
    }

    override suspend fun uploadObject(intent: PushObjectIntent, body: ByteArray) {
        fun expired() = intent.expiresAt?.let { runCatching { java.time.Instant.parse(it) }.getOrNull() }
            ?.let { !it.isAfter(now()) } == true
        if (expired()) throw PushTransportException(PushFailure(PushFailureCode.OBJECT_INTENT_EXPIRED))
        val uploadUrl = intent.uploadUrl
            ?: throw PushTransportException(PushFailure(PushFailureCode.ACK_INVALID))
        val request = Request.Builder()
            .url(uploadUrl)
            .put(FixedRequestBody(body, OCTET_STREAM))
            .apply {
                intent.requiredHeaders.forEach { (name, value) -> header(name, value) }
            }
            .removeHeader("Authorization")
            .removeHeader(FLEET_TOKEN_HEADER)
            .build()
        val response = try {
            // PUT status is not a durable receipt. Its response body is unused; closing it avoids
            // materializing an arbitrary bucket error page while retaining the immutable payload.
            uploadClient.newCall(request).await().use { it.code }
        } catch (cancelled: kotlinx.coroutines.CancellationException) {
            throw cancelled
        } catch (io: IOException) {
            throw PushTransportException(classifyPushTransportFailure(io), io)
        }
        if (response !in 200..299) {
            if (response in setOf(401, 403) && expired())
                throw PushTransportException(PushFailure(PushFailureCode.OBJECT_INTENT_EXPIRED, response))
            throw PushTransportException(PushFailure.http(response))
        }
    }

    override suspend fun completeObject(objectId: String, lane: PushObjectLane): PushObjectAck {
        val request = Request.Builder()
            .url(laneUrl("${lane.endpoint}/$objectId/complete"))
            .pushAuthorization()
            .header("Accept", "application/json")
            .post(FixedRequestBody(ByteArray(0), "application/json"))
            .build()
        val response = executeRequest(request)
        if (response.statusCode !in 200..299) {
            throw PushTransportException(
                PushError.httpFailure(
                    response.statusCode,
                    response.body, PushProtocol.OBJECT_VERSION,
                ),
            )
        }
        return try {
            PushObjectAckParser.parse(response.body, objectId)
        } catch (_: PushProtocolException) {
            throw PushTransportException(PushFailure(PushFailureCode.ACK_INVALID))
        }
    }

    private fun laneUrl(path: String): String {
        val base = java.net.URI(endpoint.url)
        return java.net.URI(base.scheme, base.authority, path, null, null).toString()
    }

    private suspend fun execute(body: ByteArray, contentEncoding: String?): PushTransportResponse =
        execute(body, contentEncoding, NDJSON.toString(), binaryObject = false, manifestHeader = null)

    private suspend fun execute(
        body: ByteArray,
        contentEncoding: String?,
        contentType: String,
        binaryObject: Boolean,
        manifestHeader: String?,
    ): PushTransportResponse {
        val request = Request.Builder()
            .url(endpoint.url)
            .pushAuthorization()
            .header("Accept", "application/json")
            .header("Content-Type", contentType)
            .apply {
                if (binaryObject) header("NOOP-Push-Binary-Object", "1")
                if (manifestHeader != null) header("NOOP-Push-Manifest", manifestHeader)
                if (contentEncoding != null) header("Content-Encoding", contentEncoding)
            }
            .post(FixedRequestBody(body, contentType))
            .build()
        return executeRequest(request)
    }

    private fun Request.Builder.pushAuthorization(): Request.Builder =
        header("Authorization", "Bearer $uploadToken")
            .header(FLEET_TOKEN_HEADER, fleetToken)

    private suspend fun executeRequest(request: Request): PushTransportResponse {
        try {
            return client.newCall(request).await().use { response ->
                val bytes = response.body?.byteStream()?.use { input ->
                    val bounded = ByteArray(PushProtocol.MAX_ACK_BYTES + 1)
                    var total = 0
                    while (total < bounded.size) {
                        val read = input.read(bounded, total, bounded.size - total)
                        if (read < 0) break
                        total += read
                    }
                    bounded.copyOf(total)
                } ?: ByteArray(0)
                PushTransportResponse(response.code, bytes)
            }
        } catch (cancelled: kotlinx.coroutines.CancellationException) {
            throw cancelled
        } catch (failure: PushTransportException) {
            throw failure
        } catch (io: IOException) {
            throw PushTransportException(classifyPushTransportFailure(io), io)
        }
    }

    /** Cancelling WorkManager cancels the active socket instead of waiting for the blocking timeout. */
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

    companion object {
        const val ACCEPT_VERSION_HEADER = "NOOP-Push-Accept-Version"
        const val FLEET_TOKEN_HEADER = "X-NOOP-Fleet-Token"
        private val NDJSON = "application/x-ndjson; charset=utf-8".toMediaType()
        private const val OCTET_STREAM = "application/octet-stream"
        internal fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
            .followRedirects(false)
            .followSslRedirects(false)
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(15, TimeUnit.SECONDS)
            .writeTimeout(15, TimeUnit.SECONDS)
            .callTimeout(15, TimeUnit.SECONDS)
            .build()

        internal fun defaultUploadClient(): OkHttpClient = OkHttpClient.Builder()
            .followRedirects(false)
            .followSslRedirects(false)
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.MINUTES)
            .writeTimeout(30, TimeUnit.MINUTES)
            .callTimeout(30, TimeUnit.MINUTES)
            .build()

        /** Compresses only the already bounded decoded entity and rejects unexpected wire expansion. */
        internal fun gzip(decoded: ByteArray): ByteArray {
            require(decoded.size <= PushProtocol.MAX_BODY_BYTES) { "decoded push body exceeds limit" }
            val buffer = Buffer()
            GzipSink(buffer).buffer().use { it.write(decoded) }
            check(buffer.size <= PushProtocol.MAX_WIRE_BODY_BYTES) { "gzip push body exceeds wire limit" }
            return buffer.readByteArray()
        }

        private class FixedRequestBody(
            private val bytes: ByteArray,
            private val mediaType: String,
        ) : RequestBody() {
            private val type = mediaType.toMediaType()
            override fun contentType() = type
            override fun contentLength(): Long = bytes.size.toLong()
            override fun writeTo(sink: BufferedSink) {
                sink.write(bytes)
            }
        }
    }
}
