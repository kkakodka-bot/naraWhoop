package com.noop.push

import com.noop.account.AccountStorageContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

data class ScoringRpcReply(val status: Int, val body: String)
fun interface ScoringRpcTransport {
    suspend fun post(url: String, anonKey: String, bearer: String, body: String): ScoringRpcReply
}
class ScoringRpcException(val code: String?, val status: Int) : Exception("Scoring RPC rejected") {
    val conflict get() = code == "40001"
    val permanent get() = code in setOf("23505", "22023")
    val authentication get() = code == "42501" || status == 401 || status == 403
}

/** Captured account authorization is checked on both sides of every suspension. */
class AccountScoringRpc(
    private val account: AccountStorageContext,
    private val anonKey: () -> String? = ServerScoringSettings::anonKey,
    private val authorize: suspend () -> AuthorizedCloudSession = { CloudAuthClient.authorizedSession(account) },
    private val transport: ScoringRpcTransport = HttpScoringRpcTransport,
) {
    suspend fun call(name: String, body: String, admission: () -> Boolean = { true }): String {
        require(name in setOf("get_server_score_snapshot_v2", "put_scoring_history_input_v3",
            "get_scoring_history_input_head_v3", "get_scoring_history_input_v3"))
        val captured = account.identity.context ?: throw AccountAuthException(AuthFailure.SIGNED_OUT)
        check(account.isCurrent())
        check(admission()) { "Scoring delivery paused" }
        val key = anonKey() ?: throw AccountAuthException(AuthFailure.NOT_CONFIGURED)
        val auth = authorize()
        if (auth.context != captured || !account.isCurrent()) throw AccountAuthException(AuthFailure.STALE)
        check(admission()) { "Scoring delivery paused" }
        val reply = transport.post("${captured.scope.projectURL}/rest/v1/rpc/$name", key, auth.accessToken, body)
        if (!account.isCurrent()) throw AccountAuthException(AuthFailure.STALE)
        require(reply.body.toByteArray().size <= ServerSnapshotDecoder.MAX_BYTES)
        if (reply.status !in 200..299) {
            val code = runCatching { JSONObject(reply.body).optString("code").takeIf { it.length <= 16 } }.getOrNull()
            throw ScoringRpcException(code, reply.status)
        }
        return reply.body
    }
    suspend fun snapshot(day: String, timezone: String? = null): ServerSnapshotResponse {
        SyncJson.day(day)
        val body = call("get_server_score_snapshot_v2", JSONObject().put("p_day", day).toString())
        return ServerSnapshotDecoder.decode(body, requireNotNull(account.identity.scope), day, timezone)
    }
}

private object HttpScoringRpcTransport : ScoringRpcTransport {
    override suspend fun post(url: String, anonKey: String, bearer: String, body: String): ScoringRpcReply = withContext(Dispatchers.IO) {
        val connection = URL(url).openConnection() as HttpURLConnection
        try {
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 20_000; connection.readTimeout = 30_000
            connection.requestMethod = "POST"; connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            connection.setRequestProperty("apikey", anonKey)
            connection.setRequestProperty("Authorization", "Bearer $bearer")
            connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            val status = connection.responseCode
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            val buffer = java.io.ByteArrayOutputStream()
            stream?.use { input ->
                val chunk = ByteArray(4096)
                while (true) {
                    val count = input.read(chunk); if (count < 0) break
                    require(buffer.size() + count <= ServerSnapshotDecoder.MAX_BYTES)
                    buffer.write(chunk, 0, count)
                }
            }
            ScoringRpcReply(status, buffer.toString("UTF-8"))
        } finally { connection.disconnect() }
    }
}
