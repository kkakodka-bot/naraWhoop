package com.noop.push

import android.app.Application
import com.noop.account.AccountStorageContext
import org.robolectric.RuntimeEnvironment
import java.util.UUID

internal class W4NativeFixture : java.io.Closeable {
    val owner = AccountScope.create("https://fixture.example.test", "10000000-0000-4000-8000-000000000001")
    val device = "20000000-0000-4000-8000-000000000001"
    val controller = AccountSessionController(object : AccountCredentialStore {
        var value: AccountSession? = AccountSession(owner, "synthetic-access", "synthetic-refresh", Long.MAX_VALUE)
        override fun load(projectURL: String) = value
        override fun save(session: AccountSession) { value = session }
        override fun clear(projectURL: String) { value = null }
    }, AccountAuthTransport { _, _ ->
        AccountReply(200, """{"access_token":"synthetic-next","refresh_token":"synthetic-refresh","expires_in":3600,"user":{"id":"${owner.userID}"}}""")
    }).apply { configure(AccountConfiguration(owner.projectURL, "synthetic-anon")) }
    private val installation = CloudAuthClient.installTestController(controller)
    fun account() = AccountStorageContext(RuntimeEnvironment.getApplication(), controller.identitySnapshot())
    fun snapshot(revision: Long = 7, input: Long = 2, sleep: String = "[]", status: String = "available"): String = """
        {"schemaVersion":2,"userId":"${owner.userID}","sourceDeviceId":"$device","day":"2026-09-18","timezone":"UTC",
         "algorithmVersion":"frwhoop-server-2","inputRevision":$input,"resultRevision":$revision,"computedAt":"2026-09-18T10:00:00Z",
         "dataThrough":null,"status":"$status","daily":${if (status == "no_data") "null" else "{\"hrv_rmssd_ms\":42}"},
         "coverage":{},"sleep":$sleep,"pending":false}
    """.trimIndent()
    fun sleep() = """[{"id":"30000000-0000-4000-8000-000000000001","start_at":"2026-09-17T23:00:00Z","end_at":"2026-09-18T07:00:00Z",
        "is_nap":false,"stages":[{"start":${java.time.Instant.parse("2026-09-17T23:00:00Z").epochSecond},"end":${java.time.Instant.parse("2026-09-18T07:00:00Z").epochSecond},"stage":"light"}]}]"""
    fun key() = ScoringInputKey(device, "profile", "primary")
    fun profile() = ScoringProfileInput(30.0, "nonbinary", 70.0, 170.0, null, 1.0, "UTC")
    fun receipt(request: ScoringInputMutation, revision: Long = 123): String {
        val body = org.json.JSONObject(request.body)
        return org.json.JSONObject().put("schemaVersion", 1).put("userId", owner.userID).put("sourceDeviceId", request.device)
            .put("kind", request.kind).put("entity", request.entity).put("revision", revision).put("clientId", body.getString("p_client_id"))
            .put("clientMutationId", request.mutationId).put("clientRevision", request.clientRevision)
            .put("effectiveDay", body.getString("p_effective_day")).put("deleted", body.getBoolean("p_deleted"))
            .put("invalidatedFrom", "2026-09-16").toString()
    }
    fun rpc(account: AccountStorageContext, transport: ScoringRpcTransport) = AccountScoringRpc(account, { "synthetic-anon" },
        { controller.authorizedSession() }, transport)
    override fun close() { com.noop.data.WhoopDatabase.close(); installation.close() }
}
