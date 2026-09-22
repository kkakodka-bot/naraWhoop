package com.frwhoop.scoring.b2

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.net.URLEncoder
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import java.util.concurrent.TimeUnit

/** Minimal SigV4 PUT for B2's S3-compatible API (path-style, same as Edge `s3.ts`). */
class B2ObjectStore(
    private val config: B2Config,
    private val http: OkHttpClient = OkHttpClient.Builder().build(),
) {
    interface PutClient {
        fun putObject(key: String, body: ByteArray, contentType: String): PutResult
    }
    fun interface ReadClient {
        fun readObject(bucket: String, key: String, maxBytes: Int): ByteArray
    }

    data class PutResult(val etag: String?, val bytes: Int)

    private val readHttp = http.newBuilder().followRedirects(false).followSslRedirects(false)
        .callTimeout(30, TimeUnit.SECONDS).readTimeout(20, TimeUnit.SECONDS).build()

    /** Only our configured bucket/endpoint; object metadata can never choose a download URL. */
    fun readObject(bucket: String, key: String, maxBytes: Int): ByteArray {
        require(bucket == config.bucket && maxBytes in 1..64 * 1024 * 1024)
        require(key.isNotBlank() && !key.startsWith('/') && key.split('/').none { it == "." || it == ".." })
        val signed = sign("GET", key, ByteArray(0), null)
        val request = Request.Builder().url(signed.url).get().apply {
            signed.headers.forEach { (name, value) -> header(name, value) }
            header("Accept-Encoding", "identity")
        }.build()
        readHttp.newCall(request).execute().use { response ->
            check(response.code == 200) { "candidate_object_http_${response.code}" }
            val body = checkNotNull(response.body) { "candidate_object_body_missing" }
            check(body.contentLength() <= maxBytes) { "candidate_object_size_limit" }
            val bytes = body.byteStream().readNBytes(maxBytes + 1)
            check(bytes.size <= maxBytes) { "candidate_object_size_limit" }
            return bytes
        }
    }

    fun putObject(key: String, body: ByteArray, contentType: String): PutResult {
        val signed = signPut(key, body, contentType)
        val req = Request.Builder()
            .url(signed.url)
            .put(body.toRequestBody(contentType.toMediaType()))
            .apply {
                signed.headers.forEach { (name, value) -> header(name, value) }
            }
            .build()
        http.newCall(req).execute().use { resp ->
            if (!resp.isSuccessful) {
                error("B2 PUT failed (${resp.code}): ${resp.body?.string()?.take(180)}")
            }
            return PutResult(etag = resp.header("ETag"), bytes = body.size)
        }
    }

    internal fun signPut(key: String, body: ByteArray, contentType: String): SignedRequest {
        return sign("PUT",key,body,contentType)
    }

    private fun sign(method: String, key: String, body: ByteArray, contentType: String?): SignedRequest {
        val now = Instant.now()
        val amzDate = AMZ_DATE.format(now.atOffset(ZoneOffset.UTC))
        val dateStamp = amzDate.substring(0, 8)
        val host = config.endpoint
        val uri = "/${urlEncode(config.bucket)}/${encodeKey(key)}"
        val payloadHash = sha256Hex(body)
        val headers = linkedMapOf(
            "host" to host,
            "x-amz-content-sha256" to payloadHash,
            "x-amz-date" to amzDate,
        )
        if(contentType != null) {
            headers["content-type"] = contentType
            headers["content-length"] = body.size.toString()
        }
        val signedHeaderNames = headers.keys.sorted()
        val canonicalHeaders = signedHeaderNames.map { "$it:${headers[it]}\n" }.joinToString("")
        val signedHeaders = signedHeaderNames.joinToString(";")
        val canonicalRequest = listOf(
            method,
            uri,
            "",
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ).joinToString("\n")
        val credentialScope = "$dateStamp/${config.region}/s3/aws4_request"
        val stringToSign = listOf(
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            sha256Hex(canonicalRequest.toByteArray(StandardCharsets.UTF_8)),
        ).joinToString("\n")
        val signingKey = signingKey(config.applicationKey, dateStamp, config.region, "s3")
        val signature = hmacHex(signingKey, stringToSign)
        val authorization = "AWS4-HMAC-SHA256 Credential=${config.keyId}/$credentialScope, " +
            "SignedHeaders=$signedHeaders, Signature=$signature"
        val outHeaders = headers.toMutableMap()
        outHeaders["authorization"] = authorization
        return SignedRequest(url = "https://$host$uri", headers = outHeaders)
    }

    data class SignedRequest(val url: String, val headers: Map<String, String>)

    companion object {
        private val AMZ_DATE = DateTimeFormatter.ofPattern("yyyyMMdd'T'HHmmss'Z'")

        fun sha256Hex(data: ByteArray): String =
            MessageDigest.getInstance("SHA-256").digest(data)
                .joinToString("") { "%02x".format(it) }

        private fun sha256Hex(text: String): String = sha256Hex(text.toByteArray(StandardCharsets.UTF_8))

        private fun hmac(data: ByteArray, message: String): ByteArray {
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(SecretKeySpec(data, "HmacSHA256"))
            return mac.doFinal(message.toByteArray(StandardCharsets.UTF_8))
        }

        private fun hmacHex(key: ByteArray, message: String): String =
            hmac(key, message).joinToString("") { "%02x".format(it) }

        private fun signingKey(secret: String, dateStamp: String, region: String, service: String): ByteArray {
            val kDate = hmac("AWS4$secret".toByteArray(StandardCharsets.UTF_8), dateStamp)
            val kRegion = hmac(kDate, region)
            val kService = hmac(kRegion, service)
            return hmac(kService, "aws4_request")
        }

        private fun urlEncode(value: String): String =
            URLEncoder.encode(value, StandardCharsets.UTF_8)
                .replace("+", "%20")
                .replace("%21", "!")
                .replace("%27", "'")
                .replace("%28", "(")
                .replace("%29", ")")
                .replace("%7E", "~")

        private fun encodeKey(key: String): String =
            key.split("/").joinToString("/") { urlEncode(it) }
    }
}
