package com.noop.push

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import com.noop.BuildConfig
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.security.KeyStore
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.withContext
import org.json.JSONObject

// W2_CORE_BEGIN
class AccountScope private constructor(val projectURL: String, val userID: String) {
    override fun equals(other: Any?) = other is AccountScope && other.projectURL == projectURL && other.userID == userID
    override fun hashCode() = 31 * projectURL.hashCode() + userID.hashCode()
    val namespace: String get() = digest("account-v1\u0000$projectURL\u0000$userID")
    companion object {
        fun create(projectURL: String, userID: String): AccountScope {
            val uuid = UUID.fromString(userID)
            require(uuid.toString().equals(userID, ignoreCase = true)) { "invalid identity" }
            return AccountScope(canonicalProjectURL(projectURL), uuid.toString())
        }
        fun canonicalProjectURL(value: String): String {
            val uri = URI(value)
            val scheme = uri.scheme?.lowercase()
            val host = uri.host?.lowercase() ?: throw AccountAuthException(AuthFailure.NOT_CONFIGURED)
            require(uri.userInfo == null && uri.query == null && uri.fragment == null &&
                !value.contains('\u0000') && !uri.path.orEmpty().contains(".."))
            require(scheme == "https" || (scheme == "http" && host in setOf("localhost", "127.0.0.1", "[::1]")))
            val port = if ((scheme == "https" && uri.port == 443) || (scheme == "http" && uri.port == 80)) -1 else uri.port
            return URI(scheme, null, host, port, uri.path.orEmpty().trimEnd('/'), null, null).toString()
        }
        fun digest(value: String): String = MessageDigest.getInstance("SHA-256")
            .digest(value.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
    }
}
data class AccountSessionContext(val scope: AccountScope, val generation: UUID)
data class AccountIdentitySnapshot(val projectURL: String?, val scope: AccountScope?, val generation: UUID) {
    val context: AccountSessionContext? get() = scope?.let { AccountSessionContext(it, generation) }
}
data class AccountConfiguration(val projectURL: String, val anonKey: String) {
    init { require(AccountScope.canonicalProjectURL(projectURL) == projectURL && anonKey.isNotBlank()) }
}
data class AccountSession(val scope: AccountScope, val accessToken: String, val refreshToken: String, val expiresAtMs: Long) {
    val userId: String get() = scope.userID
    fun isExpired(nowMs: Long = System.currentTimeMillis()) = nowMs + 60_000 >= expiresAtMs
}
data class AuthorizedCloudSession(val context: AccountSessionContext, val accessToken: String, val expiresAtMs: Long)
enum class AuthFailure { NOT_CONFIGURED, SIGNED_OUT, INVALID_CREDENTIALS, INVALID_IDENTITY, REVOKED,
    STALE, RETRYABLE, INVALID_RESPONSE, CREDENTIAL_UNAVAILABLE, UNBOUND_CAPTURE, REJECTED }
class AccountAuthException(val failure: AuthFailure) : Exception(failure.name.lowercase())
sealed interface AccountGrant {
    data class Password(val email: String, val password: String) : AccountGrant
    data class Refresh(val token: String) : AccountGrant
}
data class AccountReply(val status: Int, val body: String)
fun interface AccountAuthTransport {
    suspend fun exchange(configuration: AccountConfiguration, grant: AccountGrant): AccountReply
}
interface AccountCredentialStore {
    fun load(projectURL: String): AccountSession?
    fun save(session: AccountSession)
    fun clear(projectURL: String)
}
class AccountSessionController(
    private val store: AccountCredentialStore,
    private val transport: AccountAuthTransport,
    private val now: () -> Long = System::currentTimeMillis,
    private val changed: () -> Unit = {},
    private val tasks: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
) {
    private val lock = Any()
    private var configuration: AccountConfiguration? = null
    private var session: AccountSession? = null
    private var generation = UUID.randomUUID()
    private var loaded = false
    private var dirty = false
    private var refresh: Pair<UUID, Deferred<AuthorizedCloudSession>>? = null
    private var error: AuthFailure? = null
    fun lastError(): AuthFailure? = synchronized(lock) { error }
    fun configure(value: AccountConfiguration?) {
        val notify = synchronized(lock) {
            if (configuration == value) false else {
                invalidate(); configuration = value; loaded = false; error = null; true
            }
        }
        if (notify) changed()
    }
    fun storedSession(): AccountSession? {
        var recovered = false
        val result = synchronized(lock) {
            try {
                val unavailable = !loaded && error == AuthFailure.CREDENTIAL_UNAVAILABLE
                load(); recovered = unavailable && session != null
                if (recovered) generation = UUID.randomUUID()
                session
            } catch (_: Exception) { error = AuthFailure.CREDENTIAL_UNAVAILABLE; null }
        }
        if (recovered) changed()
        return result
    }
    fun identitySnapshot(): AccountIdentitySnapshot {
        storedSession()
        return synchronized(lock) { AccountIdentitySnapshot(configuration?.projectURL, session?.scope, generation) }
    }
    fun isCurrent(context: AccountSessionContext): Boolean = synchronized(lock) {
        generation == context.generation && session?.scope == context.scope && configuration?.projectURL == context.scope.projectURL
    }
    /** Linearizes the final SQLite commit against identity invalidation. Never await inside body. */
    internal fun <T> withIdentity(expected: AccountIdentitySnapshot, body: () -> T): T = synchronized(lock) {
        if (expected != AccountIdentitySnapshot(configuration?.projectURL, session?.scope, generation))
            throw AccountAuthException(AuthFailure.STALE)
        body()
    }
    fun clearSession() {
        try {
            synchronized(lock) {
                invalidate(); loaded = true
                configuration?.let { store.clear(it.projectURL) }
                error = null
            }
        } catch (_: Exception) {
            synchronized(lock) { error = AuthFailure.CREDENTIAL_UNAVAILABLE }
            throw AccountAuthException(AuthFailure.CREDENTIAL_UNAVAILABLE)
        } finally { changed() }
    }
    suspend fun signIn(email: String, password: String): AccountSession {
        val start = try {
            synchronized(lock) {
                val config = configuration ?: throw AccountAuthException(AuthFailure.NOT_CONFIGURED)
                invalidate(); loaded = true
                try { store.clear(config.projectURL) } catch (_: Exception) {
                    error = AuthFailure.CREDENTIAL_UNAVAILABLE
                    throw AccountAuthException(AuthFailure.CREDENTIAL_UNAVAILABLE)
                }
                config to generation
            }
        } finally { changed() }
        val parsed = parse(exchange(start.first, AccountGrant.Password(email, password)), start.first, false)
        synchronized(lock) {
            if (generation != start.second || configuration != start.first) throw AccountAuthException(AuthFailure.STALE)
            try { store.save(parsed) } catch (_: Exception) {
                error = AuthFailure.CREDENTIAL_UNAVAILABLE
                throw AccountAuthException(AuthFailure.CREDENTIAL_UNAVAILABLE)
            }
            session = parsed; error = null
        }
        changed()
        return parsed
    }
    suspend fun authorizedSession(): AuthorizedCloudSession {
        storedSession()
        val selected: Pair<AuthorizedCloudSession?, Deferred<AuthorizedCloudSession>?> = synchronized(lock) {
            load()
            val config = configuration ?: throw AccountAuthException(AuthFailure.NOT_CONFIGURED)
            val current = session ?: throw AccountAuthException(AuthFailure.SIGNED_OUT)
            if (dirty) {
                try { store.save(current); dirty = false; error = null } catch (_: Exception) {
                    throw AccountAuthException(AuthFailure.CREDENTIAL_UNAVAILABLE)
                }
            }
            val context = AccountSessionContext(current.scope, generation)
            if (!current.isExpired(now())) AuthorizedCloudSession(context, current.accessToken, current.expiresAtMs) to null
            else {
                val pending = refresh?.second ?: run {
                    val id = UUID.randomUUID()
                    val task = tasks.async(start = CoroutineStart.LAZY) { refresh(config, current, context, id) }
                    refresh = id to task
                    task
                }
                null to pending
            }
        }
        val result = selected.first ?: selected.second!!.await()
        if (!isCurrent(result.context)) throw AccountAuthException(AuthFailure.STALE)
        return result
    }
    private suspend fun refresh(config: AccountConfiguration, old: AccountSession,
                                context: AccountSessionContext, id: UUID): AuthorizedCloudSession {
        try {
            val parsed = parse(exchange(config, AccountGrant.Refresh(old.refreshToken)), config, true)
            return synchronized(lock) {
                if (!isCurrent(context) || configuration != config) throw AccountAuthException(AuthFailure.STALE)
                if (parsed.scope != context.scope) throw AccountAuthException(AuthFailure.INVALID_IDENTITY)
                session = parsed; dirty = true
                try { store.save(parsed); dirty = false; error = null } catch (_: Exception) {
                    error = AuthFailure.CREDENTIAL_UNAVAILABLE
                    throw AccountAuthException(AuthFailure.CREDENTIAL_UNAVAILABLE)
                }
                AuthorizedCloudSession(context, parsed.accessToken, parsed.expiresAtMs)
            }
        } catch (failure: Exception) {
            if (!isCurrent(context)) throw AccountAuthException(AuthFailure.STALE)
            if ((failure as? AccountAuthException)?.failure == AuthFailure.REVOKED) {
                val notify = synchronized(lock) {
                    if (!isCurrent(context)) false else {
                        invalidate(); loaded = true
                        try { store.clear(config.projectURL); error = AuthFailure.REVOKED }
                        catch (_: Exception) { error = AuthFailure.CREDENTIAL_UNAVAILABLE }
                        true
                    }
                }
                if (notify) changed()
            }
            throw failure
        } finally {
            synchronized(lock) { if (refresh?.first == id) refresh = null }
        }
    }
    private fun load() {
        if (loaded) return
        val config = configuration ?: return
        try {
            val value = store.load(config.projectURL)
            if (value != null && value.scope.projectURL != config.projectURL) throw AccountAuthException(AuthFailure.INVALID_IDENTITY)
            if (value != null && (value.accessToken.isBlank() || value.refreshToken.isBlank())) {
                throw AccountAuthException(AuthFailure.CREDENTIAL_UNAVAILABLE)
            }
            session = value; loaded = true; error = null
        } catch (_: Exception) {
            error = AuthFailure.CREDENTIAL_UNAVAILABLE
            throw AccountAuthException(AuthFailure.CREDENTIAL_UNAVAILABLE)
        }
    }
    private fun invalidate() {
        generation = UUID.randomUUID(); session = null; dirty = false
        // HTTP may finish; its captured generation can no longer commit.
        refresh = null
    }
    private suspend fun exchange(config: AccountConfiguration, grant: AccountGrant): AccountReply {
        try { return transport.exchange(config, grant) }
        catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
        catch (failure: AccountAuthException) { throw failure }
        catch (_: Exception) { throw AccountAuthException(AuthFailure.RETRYABLE) }
    }
    private fun parse(reply: AccountReply, config: AccountConfiguration, refreshing: Boolean): AccountSession {
        if (reply.body.toByteArray().size > 128 * 1024) throw AccountAuthException(AuthFailure.INVALID_RESPONSE)
        if (reply.status == 408 || reply.status == 429 || reply.status >= 500) throw AccountAuthException(AuthFailure.RETRYABLE)
        val body = runCatching { JSONObject(reply.body) }.getOrNull()
        if (reply.status != 200) {
            val code = body?.optString("error_code")?.takeIf { it.isNotEmpty() } ?: body?.optString("error")
            if (refreshing && reply.status in listOf(400, 401) &&
                code in setOf("invalid_grant", "refresh_token_not_found", "refresh_token_already_used", "session_not_found")) {
                throw AccountAuthException(AuthFailure.REVOKED)
            }
            if (!refreshing && reply.status in listOf(400, 401)) throw AccountAuthException(AuthFailure.INVALID_CREDENTIALS)
            throw AccountAuthException(AuthFailure.REJECTED)
        }
        try {
            require(body != null)
            val access = body.getString("access_token"); val refresh = body.getString("refresh_token")
            val seconds = body.getLong("expires_in")
            require(access.isNotBlank() && refresh.isNotBlank() && seconds > 0 && seconds < Long.MAX_VALUE / 1000)
            return AccountSession(AccountScope.create(config.projectURL, body.getJSONObject("user").getString("id")),
                access, refresh, Math.addExact(now(), seconds * 1000))
        } catch (_: Exception) { throw AccountAuthException(AuthFailure.INVALID_RESPONSE) }
    }
}
// W2_CORE_END

/** Compatibility facade. Preferences contain ciphertext, never bearer or refresh plaintext. */
object CloudAuthClient {
    private val lock = Any()
    private var controller: AccountSessionController? = null
    private val listeners = CopyOnWriteArrayList<() -> Unit>()
    internal fun installTestController(value: AccountSessionController?): AutoCloseable = synchronized(lock) {
        val previous = controller
        controller = value
        AutoCloseable { synchronized(lock) { controller = previous } }
    }
    fun observeIdentity(listener: () -> Unit): AutoCloseable {
        listeners.add(listener)
        return AutoCloseable { listeners.remove(listener) }
    }
    private fun controller(context: Context): AccountSessionController = synchronized(lock) {
        controller ?: AccountSessionController(AndroidAccountCredentialStore(com.noop.account.AccountStorageContext.platform(context)),
            AndroidAccountHTTPTransport(), changed = { listeners.forEach { it() } }).also {
            controller = it
            val endpoint = BuildConfig.NOOP_PUSH_ENDPOINT.trim().trimEnd('/')
            if (endpoint.endsWith("/functions/v1/push") && BuildConfig.NOOP_SUPABASE_ANON_KEY.isNotBlank()) {
                it.configure(AccountConfiguration(AccountScope.canonicalProjectURL(endpoint.removeSuffix("/functions/v1/push")),
                    BuildConfig.NOOP_SUPABASE_ANON_KEY.trim()))
            }
        }
    }
    fun configure(context: Context, projectURL: String, anonKey: String) {
        controller(context).configure(AccountConfiguration(AccountScope.canonicalProjectURL(projectURL), anonKey))
    }
    fun storedSession(context: Context): AccountSession? = controller(context).storedSession()
    fun identitySnapshot(context: Context): AccountIdentitySnapshot = controller(context).identitySnapshot()
    fun isCurrent(context: Context, expected: AccountSessionContext): Boolean = controller(context).isCurrent(expected)
    internal fun <T> withIdentity(context: Context, expected: AccountIdentitySnapshot, body: () -> T): T =
        controller(context).withIdentity(expected, body)
    fun lastPersistenceError(context: Context): AuthFailure? = controller(context).lastError()
    fun clearSession(context: Context) { runCatching { clearSessionChecked(context) } }
    fun clearSessionChecked(context: Context) = controller(context).clearSession()
    suspend fun signIn(context: Context, email: String, password: String): AccountSession =
        controller(context).signIn(email, password)
    suspend fun authorizedSession(context: Context): AuthorizedCloudSession = controller(context).authorizedSession()
    suspend fun validAccessToken(context: Context): String = authorizedSession(context).accessToken
}

private class AndroidAccountCredentialStore(context: Context) : AccountCredentialStore {
    private val prefs = context.getSharedPreferences("noop_cloud_auth_account_v1", Context.MODE_PRIVATE)
    private fun active(projectURL: String) = "active." + AccountScope.digest(projectURL)
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val alias = "noop.cloudAuth.account.v1"
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    override fun load(projectURL: String): AccountSession? {
        val namespace = prefs.getString(active(projectURL), null)?.takeIf { it.isNotEmpty() } ?: return null
        val packed = prefs.getString("session.$namespace", null) ?: throw AccountAuthException(AuthFailure.CREDENTIAL_UNAVAILABLE)
        val parts = packed.split('.')
        require(parts.size == 2)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(parts[0], Base64.NO_WRAP)))
        cipher.updateAAD(namespace.toByteArray(Charsets.UTF_8))
        val body = JSONObject(String(cipher.doFinal(Base64.decode(parts[1], Base64.NO_WRAP)), Charsets.UTF_8))
        val scope = AccountScope.create(body.getString("projectURL"), body.getString("userID"))
        require(scope.namespace == namespace && scope.projectURL == projectURL)
        return AccountSession(scope, body.getString("accessToken"), body.getString("refreshToken"), body.getLong("expiresAtMs"))
    }
    override fun save(session: AccountSession) {
        val namespace = session.scope.namespace
        val body = JSONObject().put("projectURL", session.scope.projectURL).put("userID", session.scope.userID)
            .put("accessToken", session.accessToken).put("refreshToken", session.refreshToken)
            .put("expiresAtMs", session.expiresAtMs).toString()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key()); cipher.updateAAD(namespace.toByteArray(Charsets.UTF_8))
        val ciphertext = cipher.doFinal(body.toByteArray(Charsets.UTF_8))
        val packed = Base64.encodeToString(cipher.iv, Base64.NO_WRAP) + "." + Base64.encodeToString(ciphertext, Base64.NO_WRAP)
        check(prefs.edit().putString("session.$namespace", packed)
            .putString(active(session.scope.projectURL), namespace).commit())
    }
    override fun clear(projectURL: String) {
        val namespace = prefs.getString(active(projectURL), null)
        val edit = prefs.edit().putString(active(projectURL), "")
        if (!namespace.isNullOrBlank()) edit.remove("session.$namespace")
        check(edit.commit())
    }
}
private class AndroidAccountHTTPTransport : AccountAuthTransport {
    override suspend fun exchange(configuration: AccountConfiguration, grant: AccountGrant): AccountReply =
        withContext(Dispatchers.IO) {
            val kind: String
            val payload = JSONObject()
            when (grant) {
                is AccountGrant.Password -> { kind = "password"; payload.put("email", grant.email).put("password", grant.password) }
                is AccountGrant.Refresh -> { kind = "refresh_token"; payload.put("refresh_token", grant.token) }
            }
            val conn = URL(configuration.projectURL + "/auth/v1/token?grant_type=" + kind).openConnection() as HttpURLConnection
            try {
                conn.instanceFollowRedirects = false
                conn.connectTimeout = 20_000; conn.readTimeout = 30_000
                conn.requestMethod = "POST"; conn.doOutput = true
                conn.setRequestProperty("Content-Type", "application/json")
                conn.setRequestProperty("apikey", configuration.anonKey)
                conn.outputStream.use { it.write(payload.toString().toByteArray(Charsets.UTF_8)) }
                val status = conn.responseCode
                val stream = if (status in 200..299) conn.inputStream else conn.errorStream
                val bytes = stream?.use { it.readBytesBounded(128 * 1024) } ?: byteArrayOf()
                AccountReply(status, String(bytes, Charsets.UTF_8))
            } finally { conn.disconnect() }
        }
}
private fun java.io.InputStream.readBytesBounded(limit: Int): ByteArray {
    val buffer = java.io.ByteArrayOutputStream()
    val chunk = ByteArray(4096)
    while (true) {
        val count = read(chunk)
        if (count < 0) break
        if (buffer.size() + count > limit) throw AccountAuthException(AuthFailure.INVALID_RESPONSE)
        buffer.write(chunk, 0, count)
    }
    return buffer.toByteArray()
}
