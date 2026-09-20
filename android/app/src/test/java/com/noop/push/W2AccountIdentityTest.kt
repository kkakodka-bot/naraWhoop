package com.noop.push

import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.supervisorScope
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

private const val W2_A = "11111111-1111-4111-8111-111111111111"
private const val W2_B = "22222222-2222-4222-8222-222222222222"
private const val W2_SOURCE = "33333333-3333-4333-8333-333333333333"
private const val W2_NOW = 1_800_000_000_000L

/** No Android context, keystore, real accounts or network are used in this suite. */
class W2AccountIdentityTest {
    @Test fun canonicalNamespaceSeparatesProjectsAndOwners() {
        val a = AccountScope.create("https://EXAMPLE.test:443/", W2_A.uppercase())
        assertEquals(AccountScope.create("https://example.test", W2_A), a)
        assertEquals(64, a.namespace.length)
        assertNotEquals(a.namespace, AccountScope.create(a.projectURL, W2_B).namespace)
        assertNotEquals(a.namespace, AccountScope.create("https://other.test", W2_A).namespace)
        assertTrue(runCatching { AccountScope.create("https://user:pass@example.test", W2_A) }.isFailure)
        assertTrue(runCatching { AccountScope.create(a.projectURL, "1-1-1-1-1") }.isFailure)
    }

    @Test fun concurrentRefreshIsSingleFlightAndDoesNotRebuildIdentity() = runCase {
        val f = Fixture()
        val before = f.auth.identitySnapshot().context!!
        val requests = (1..24).map { async { f.auth.authorizedSession() } }
        f.transport.next().complete(reply())
        requests.awaitAll().forEach { assertEquals(before, it.context) }
        assertEquals(1, f.transport.count.get())
        assertEquals(1, f.store.saves)
        assertEquals(1, f.transitions.get())
    }

    @Test fun logoutRejectsLateRefreshAndDoesNotRestoreOnReopen() = runCase {
        val f = Fixture()
        val old = f.auth.identitySnapshot().context!!
        val pending = async { f.auth.authorizedSession() }
        val response = f.transport.next()
        f.auth.clearSession()
        assertFalse(f.auth.isCurrent(old))
        response.complete(reply())
        fails(AuthFailure.STALE) { pending.await() }
        assertNull(f.auth.identitySnapshot().scope)
        assertEquals(0, f.store.saves)
        val reopened = AccountSessionController(f.store, f.transport, now = { W2_NOW })
        reopened.configure(f.configuration)
        assertNull(reopened.storedSession())
    }

    @Test fun lateOldRevocationCannotClearNewUser() = runCase {
        val f = Fixture()
        val old = async { f.auth.authorizedSession() }
        val oldResponse = f.transport.next()
        val login = async { f.auth.signIn("synthetic@example.test", "synthetic") }
        f.transport.next().complete(reply(W2_B))
        assertEquals(W2_B, login.await().userId)
        oldResponse.complete(AccountReply(400, """{"error":"invalid_grant"}"""))
        fails(AuthFailure.STALE) { old.await() }
        assertEquals(W2_B, f.auth.storedSession()!!.userId)
        assertEquals(W2_B, f.store.value!!.userId)
    }

    @Test fun projectSwitchRejectsLateSignIn() = runCase {
        val f = Fixture()
        val login = async { f.auth.signIn("synthetic@example.test", "synthetic") }
        val response = f.transport.next()
        f.auth.configure(AccountConfiguration("https://other.test", "synthetic"))
        response.complete(reply())
        fails(AuthFailure.STALE) { login.await() }
        assertNull(f.auth.identitySnapshot().scope)
        assertEquals(0, f.store.saves)
    }

    @Test fun transientStatusesAndMalformedResponsesRetainLogin() = runCase {
        for (status in listOf(408, 429, 500, 503, 200)) {
            val f = Fixture()
            val before = f.auth.identitySnapshot().context!!
            val pending = async { f.auth.authorizedSession() }
            f.transport.next().complete(AccountReply(status, "{}"))
            fails(if (status == 200) AuthFailure.INVALID_RESPONSE else AuthFailure.RETRYABLE) { pending.await() }
            assertTrue(f.auth.isCurrent(before))
            assertEquals(0, f.store.clears)
            val retry = async { f.auth.authorizedSession() }
            f.transport.next().complete(reply())
            assertEquals(before, retry.await().context)
        }
    }

    @Test fun rotatedRefreshCredentialIsRetainedUntilCheckedSaveSucceeds() = runCase {
        val f = Fixture()
        f.store.failSave = true
        val pending = async { f.auth.authorizedSession() }
        f.transport.next().complete(reply())
        fails(AuthFailure.CREDENTIAL_UNAVAILABLE) { pending.await() }
        f.store.failSave = false
        assertEquals("new-access", f.auth.authorizedSession().accessToken)
        assertEquals(1, f.transport.count.get())
        assertEquals("new-refresh", f.store.value!!.refreshToken)
    }

    @Test fun failedSignInPersistenceNeverPublishesAccount() = runCase {
        val f = Fixture()
        val login = async { f.auth.signIn("synthetic@example.test", "synthetic") }
        val response = f.transport.next()
        f.store.failSave = true
        response.complete(reply(W2_B))
        fails(AuthFailure.CREDENTIAL_UNAVAILABLE) { login.await() }
        assertNull(f.auth.identitySnapshot().scope)
        assertNull(f.store.value)
    }

    @Test fun failedSecureClearStillFencesAndNotifies() = runCase {
        val f = Fixture()
        val before = f.auth.identitySnapshot().context!!
        f.store.failClear = true
        fails(AuthFailure.CREDENTIAL_UNAVAILABLE) { f.auth.clearSession() }
        assertNull(f.auth.identitySnapshot().scope)
        assertFalse(f.auth.isCurrent(before))
        assertEquals(2, f.transitions.get())
        assertEquals(AuthFailure.CREDENTIAL_UNAVAILABLE, f.auth.lastError())
    }

    @Test fun inaccessibleStorageIsNotAbsenceAndCanRetry() {
        val f = Fixture()
        f.store.failLoad = true
        assertNull(f.auth.storedSession())
        assertEquals(AuthFailure.CREDENTIAL_UNAVAILABLE, f.auth.lastError())
        f.store.failLoad = false
        assertEquals(W2_A, f.auth.storedSession()!!.userId)
    }

    @Test fun mismatchedRefreshSubjectCannotReplaceOwner() = runCase {
        val f = Fixture()
        val pending = async { f.auth.authorizedSession() }
        f.transport.next().complete(reply(W2_B))
        fails(AuthFailure.INVALID_IDENTITY) { pending.await() }
        assertEquals(W2_A, f.auth.storedSession()!!.userId)
        assertEquals(0, f.store.saves)
    }

    @Test fun revokedRefreshInvalidatesOwner() = runCase {
        val f = Fixture()
        val pending = async { f.auth.authorizedSession() }
        f.transport.next().complete(AccountReply(400, """{"error_code":"refresh_token_not_found"}"""))
        fails(AuthFailure.REVOKED) { pending.await() }
        assertNull(f.auth.identitySnapshot().scope)
        assertNull(f.store.value)
    }

    @Test fun ownerAdmissionRejectsUnboundWrongAccountAndProject() = runCase {
        val scope = AccountScope.create("https://example.test", W2_A)
        AccountPushAdmission.verifyOwner(scope, scope.projectURL, scope.userID)
        fails(AuthFailure.UNBOUND_CAPTURE) { AccountPushAdmission.verifyOwner(scope, null, null) }
        fails(AuthFailure.UNBOUND_CAPTURE) { AccountPushAdmission.verifyOwner(scope, scope.projectURL, W2_B) }
        fails(AuthFailure.UNBOUND_CAPTURE) { AccountPushAdmission.verifyOwner(scope, "https://other.test", W2_A) }
        fails(AuthFailure.UNBOUND_CAPTURE) {
            AccountPushAdmission(AccountSessionContext(scope, UUID.randomUUID()),
                AccountScope.create(scope.projectURL, W2_B), W2_SOURCE) { true }
        }
    }

    @Test fun capabilitiesRequireAuthenticatedOwner() = runCase {
        val scope = AccountScope.create("https://example.test", W2_A)
        fun capability(owner: String?) = JSONObject().put("type", "capabilities")
            .put("protocolVersion", "1.0").put("receiverStateId", W2_SOURCE)
            .put("streams", org.json.JSONArray()).apply { owner?.let { put("userId", it) } }
            .toString().toByteArray()
        assertTrue(AccountPushAdmission.capabilities(capability(W2_A), scope).isEmpty)
        fails(AuthFailure.INVALID_IDENTITY) { AccountPushAdmission.capabilities(capability(null), scope) }
        fails(AuthFailure.INVALID_IDENTITY) { AccountPushAdmission.capabilities(capability(W2_B), scope) }
    }

    @Test fun jobsCannotAdoptTheNextLoginOrProjectAndUnassignedJobsDefer() {
        val scope = AccountScope.create("https://example.test", W2_A)
        val context = AccountSessionContext(scope, UUID.randomUUID())
        assertTrue(AccountPushJobAdmission.matches(context, scope.namespace, context.generation.toString()))
        assertFalse(AccountPushJobAdmission.matches(context, null, null))
        assertFalse(AccountPushJobAdmission.matches(context, scope.namespace, UUID.randomUUID().toString()))
        assertFalse(AccountPushJobAdmission.matches(context,
            AccountScope.create(scope.projectURL, W2_B).namespace, context.generation.toString()))
        assertFalse(AccountPushJobAdmission.matches(context,
            AccountScope.create("https://other.test", W2_A).namespace, context.generation.toString()))
    }

    @Test fun pendingReceiptAndFurtherTransportAreFencedByGeneration() = runCase {
        val f = Fixture()
        val context = f.auth.identitySnapshot().context!!
        val admission = AccountPushAdmission(context, context.scope, W2_SOURCE, f.auth::isCurrent)
        val started = CompletableDeferred<Unit>()
        val response = CompletableDeferred<PushTransportResponse>()
        val calls = AtomicInteger()
        val base = object : PushTransport {
            override suspend fun post(batch: PushBatch): PushTransportResponse {
                calls.incrementAndGet(); started.complete(Unit); return response.await()
            }
        }
        val transport = AccountFencedTransport(base, admission) { PushCapabilitiesResult.Available(PushCapabilities.ALL) }
        val batch = PushProtocol.appendBatch(PushAppendTable.HR_SAMPLE, W2_SOURCE, "device", null,
            listOf(PushAppendRecord(1, mapOf("ts" to 100L), mapOf("bpm" to 60L))))
        val pending = async { transport.post(batch) }
        started.await()
        f.auth.clearSession()
        response.complete(PushTransportResponse(200, byteArrayOf()))
        fails(AuthFailure.STALE) { pending.await() }
        fails(AuthFailure.STALE) { transport.post(batch) }
        assertEquals(1, calls.get())
    }
}

private fun runCase(block: suspend CoroutineScope.() -> Unit) =
    runBlocking { withTimeout(5_000) { supervisorScope(block) } }

private suspend fun fails(expected: AuthFailure, body: suspend () -> Any?) {
    try { body(); fail("Expected " + expected) }
    catch (failure: AccountAuthException) { assertEquals(expected, failure.failure) }
}
private fun reply(user: String = W2_A) = AccountReply(200,
    JSONObject().put("access_token", "new-access").put("refresh_token", "new-refresh")
        .put("expires_in", 3600).put("user", JSONObject().put("id", user)).toString())

private class Fixture {
    val configuration = AccountConfiguration("https://example.test", "synthetic-anon")
    val store = MemoryCredentials(AccountSession(AccountScope.create(configuration.projectURL, W2_A),
        "old-access", "old-refresh", W2_NOW - 1))
    val transport = ControlledAuth()
    val transitions = AtomicInteger()
    val auth = AccountSessionController(store, transport, now = { W2_NOW }, changed = { transitions.incrementAndGet() })
        .apply { configure(configuration) }
}
private class ControlledAuth : AccountAuthTransport {
    val count = AtomicInteger()
    private val requests = Channel<CompletableDeferred<AccountReply>>(Channel.UNLIMITED)
    override suspend fun exchange(configuration: AccountConfiguration, grant: AccountGrant): AccountReply {
        count.incrementAndGet()
        val response = CompletableDeferred<AccountReply>()
        requests.send(response)
        return response.await()
    }
    suspend fun next() = requests.receive()
}
private class MemoryCredentials(var value: AccountSession?) : AccountCredentialStore {
    var saves = 0
    var clears = 0
    @Volatile var failSave = false
    @Volatile var failLoad = false
    @Volatile var failClear = false
    @Synchronized override fun load(projectURL: String): AccountSession? {
        if (failLoad) throw IllegalStateException("synthetic locked")
        return value?.takeIf { it.scope.projectURL == projectURL }
    }
    @Synchronized override fun save(session: AccountSession) {
        if (failSave) throw IllegalStateException("synthetic write failure")
        value = session; saves++
    }
    @Synchronized override fun clear(projectURL: String) {
        if (failClear) throw IllegalStateException("synthetic clear failure")
        value = null; clears++
    }
}
