package com.frwhoop.scoring.db

import com.zaxxer.hikari.HikariConfig
import com.zaxxer.hikari.HikariDataSource
import java.net.URI
import java.net.URLDecoder
import java.nio.charset.StandardCharsets
import java.sql.Connection

/**
 * Durable Postgres access for the scoring service.
 *
 * URL handling is PURE and testable WITHOUT a live database (Phase 3 gate: "URL normalization
 * must be testable without requiring a real database").
 *
 * The receiver-style DATABASE_URL follows the libpq/Node `pg` convention
 * `postgresql://user:password@host:port/database` (with optional `jdbc:` prefix). pgJDBC does NOT
 * accept userinfo in a JDBC URL — `jdbc:postgresql://user:pass@host/db` parses `user:pass@host` as
 * the host (verified against pgJDBC 42.7.4). We therefore split the userinfo out and pass user /
 * password to Hikari as data-source properties, keeping the URL userinfo-free.
 */
class PostgresClient private constructor(
    internal val dataSource: HikariDataSource,
) : AutoCloseable {

    constructor(databaseUrl: String, queryTimeoutSeconds: Int? = null,
                connectionBudget: ConnectionBudget = ConnectionBudget.fromEnvironment()) : this(
        HikariDataSource(
            HikariConfig().apply {
                for ((name, value) in verifiedHostedJdbcProperties(databaseUrl)) {
                    addDataSourceProperty(name, value)
                }
                driverClassName = "org.postgresql.Driver"
                jdbcUrl = if (queryTimeoutSeconds == null) normalizeJdbcUrl(databaseUrl) else boundedJdbcUrl(databaseUrl)
                maximumPoolSize = connectionBudget.poolSize
                minimumIdle = 1
                connectionTimeout = 30_000
                idleTimeout = 600_000
                maxLifetime = 1_800_000
                // Legacy/archive clients retain operator URL overrides of finite driver defaults.
                // Dedicated scoring/model clients below enforce their stricter limits instead.
                addDataSourceProperty("connectTimeout", "10")
                addDataSourceProperty("socketTimeout", "60")
                addDataSourceProperty("cancelSignalTimeout", "5")
                queryTimeoutSeconds?.let { seconds ->
                    require(seconds in 1..60)
                    connectionTimeout = 5_000
                    addDataSourceProperty("connectTimeout", 5)
                    addDataSourceProperty("socketTimeout", seconds + 5)
                    addDataSourceProperty("cancelSignalTimeout", 5)
                    addDataSourceProperty("options", "-c statement_timeout=${seconds * 1000}")
                    connectionInitSql = "set statement_timeout = ${seconds * 1000}"
                }

                val creds = parseUserInfo(databaseUrl)
                if (creds.user != null) {
                    addDataSourceProperty("user", creds.user)
                    addDataSourceProperty("password", creds.password.orEmpty())
                }
            },
        ),
    )

    companion object {
        data class UserInfo(val user: String?, val password: String?)

        private const val JAVA_SYSTEM_TRUST_FACTORY = "org.postgresql.ssl.DefaultJavaSSLFactory"
        private val HOSTED_DATABASE_OPTIONS = setOf("sslmode", "sslrootcert", "connectTimeout", "socketTimeout",
            "cancelSignalTimeout", "ApplicationName", "applicationName", "targetServerType", "channelBinding",
            "prepareThreshold")

        /** Hosted credentials may leave the process only with hostname and CA verification enabled.
         * Local disposable/self-hosted databases retain their existing test/development behavior. */
        fun requireVerifiedHostedTls(databaseUrl: String): Boolean = verifiedHostedRoot(databaseUrl) != null

        private fun verifiedHostedRoot(databaseUrl: String): String? {
            val uri = try { URI(normalizeJdbcUrl(databaseUrl).removePrefix("jdbc:")) }
            catch (_: Exception) { throw IllegalArgumentException("DATABASE_URL is invalid") }
            val host = uri.host?.lowercase() ?: return null
            if (!(host.endsWith(".supabase.co") || host.endsWith(".pooler.supabase.com"))) return null
            val options = linkedMapOf<String, String>()
            for (raw in uri.rawQuery.orEmpty().split('&').filter(String::isNotEmpty)) {
                val name = decodeOption(raw.substringBefore('='))
                val value = decodeOption(raw.substringAfter('=', ""))
                require(name !in options) { "DATABASE_URL contains duplicate options" }
                options[name] = value
            }
            require(options.keys.all(HOSTED_DATABASE_OPTIONS::contains)) {
                "Hosted DATABASE_URL contains unsupported options"
            }
            require(options["sslmode"] == "verify-full") { "Hosted DATABASE_URL requires sslmode=verify-full" }
            val root = options["sslrootcert"] ?: throw IllegalArgumentException("Hosted DATABASE_URL requires a reviewed sslrootcert")
            if (root != "system") verifyPinnedHostedCa(root)
            require("ssl" !in options) { "Hosted DATABASE_URL must use one explicit TLS mode" }
            return root
        }

        private fun verifyPinnedHostedCa(filename: String) {
            // Public Supabase CA, pinned to the reviewed source asset. Never fetch trust at runtime.
            // A path is configurable for isolated local preflight, but trust bytes are not.
            try {
                val file = java.nio.file.Path.of(filename)
                require(file.isAbsolute && !java.nio.file.Files.isSymbolicLink(file) && file.toRealPath() == file)
                require(java.nio.file.Files.isRegularFile(file) && java.nio.file.Files.size(file) in 1..131072)
                val bytes = java.nio.file.Files.readAllBytes(file)
                val digest = java.security.MessageDigest.getInstance("SHA-256").digest(bytes)
                    .joinToString("") { "%02x".format(it) }
                require(digest == "700723581420dd1ac98fd7e9ac529f0ef210eadcaf87fc868a3ad7d114c2f3b7")
                val certificate = java.security.cert.CertificateFactory.getInstance("X.509")
                    .generateCertificate(bytes.inputStream()) as java.security.cert.X509Certificate
                require(certificate.basicConstraints >= 0)
                certificate.checkValidity()
            } catch (_: Exception) {
                throw IllegalArgumentException("Hosted DATABASE_URL root certificate differs from reviewed trust")
            }
        }

        /** libpq accepts sslrootcert=system directly. pgJDBC 42.7.4 treats that value as a file
         * name unless its Java-system-trust factory is selected separately. Keep the shared URL
         * libpq-compatible and add the JVM-only factory as a connection property. */
        internal fun verifiedHostedJdbcProperties(databaseUrl: String): Map<String, String> =
            if (verifiedHostedRoot(databaseUrl) == "system") mapOf("sslfactory" to JAVA_SYSTEM_TRUST_FACTORY)
            else emptyMap() // pgJDBC's validating LibPQFactory reads the pinned explicit CA file.

        private fun decodeOption(value: String): String = try {
            URLDecoder.decode(value, StandardCharsets.UTF_8)
        } catch (_: IllegalArgumentException) {
            throw IllegalArgumentException("DATABASE_URL has malformed option encoding")
        }

        /** Map a receiver-style database URL to a userinfo-free JDBC URL. Pure: no I/O, no pool. */
        fun normalizeJdbcUrl(databaseUrl: String): String {
            val base = when {
                databaseUrl.startsWith("jdbc:") -> databaseUrl
                databaseUrl.startsWith("postgresql://") -> "jdbc:$databaseUrl"
                databaseUrl.startsWith("postgres://") ->
                    "jdbc:${databaseUrl.replaceFirst("postgres://", "postgresql://")}"
                else -> databaseUrl
            }
            // Strip userinfo from the authority: jdbc:postgresql://user:pass@host:port/db -> jdbc:postgresql://host:port/db
            return stripUserInfo(base)
        }

        /** pgJDBC URL parameters otherwise override the worker's bounded connection properties. */
        internal fun boundedJdbcUrl(databaseUrl: String): String {
            val normalized = normalizeJdbcUrl(databaseUrl)
            if ('?' !in normalized) return normalized
            val retained = normalized.substringAfter('?').split('&').filter { parameter ->
                val name = try { URLDecoder.decode(parameter.substringBefore('='), StandardCharsets.UTF_8) }
                catch (_: IllegalArgumentException) { throw IllegalArgumentException("Invalid database URL option encoding") }
                name !in setOf("connectTimeout", "socketTimeout", "cancelSignalTimeout")
            }.joinToString("&")
            return normalized.substringBefore('?') + if (retained.isEmpty()) "" else "?$retained"
        }

        /** Extract user/password from `user:pass@` userinfo. Splits at the LAST `@` before the first
         *  `/` (path), so an `@` inside the password survives; the password is everything after the
         *  FIRST `:` within userinfo. URI escapes are decoded exactly once, after splitting.
         *  Handles `postgresql://`, `postgres://`, and `jdbc:`-prefixed forms. */
        fun parseUserInfo(databaseUrl: String): UserInfo {
            val authority = authorityOf(databaseUrl) ?: return UserInfo(null, null)
            val at = authority.lastIndexOf('@')
            if (at <= 0) return UserInfo(null, null)
            val userinfo = authority.substring(0, at)
            val colon = userinfo.indexOf(':')
            return if (colon < 0) {
                UserInfo(decodeUserInfo(userinfo), null)
            } else {
                UserInfo(decodeUserInfo(userinfo.substring(0, colon)), decodeUserInfo(userinfo.substring(colon + 1)))
            }
        }

        private fun decodeUserInfo(value: String): String = try {
            // URLDecoder handles form data, where '+' means space; URI userinfo keeps literal '+'.
            URLDecoder.decode(value.replace("+", "%2B"), StandardCharsets.UTF_8)
        } catch (_: IllegalArgumentException) {
            // Decoder errors can include the credential. Keep both the message and cause sanitized.
            throw IllegalArgumentException("DATABASE_URL has malformed percent encoding in userinfo")
        }

        private fun authorityOf(databaseUrl: String): String? {
            // Strip any jdbc: prefix, then any scheme:// marker; authority ends at first / or ? or end.
            var s = databaseUrl
            if (s.startsWith("jdbc:")) s = s.removePrefix("jdbc:")
            for (scheme in listOf("postgresql://", "postgres://")) {
                if (s.startsWith(scheme)) {
                    s = s.removePrefix(scheme)
                    break
                }
            }
            val end = s.indexOfFirst { it == '/' || it == '?' }
            return if (end < 0) s else s.substring(0, end)
        }

        private fun stripUserInfo(jdbcUrl: String): String {
            val marker = "://"
            val schemeEnd = jdbcUrl.indexOf(marker)
            if (schemeEnd < 0) return jdbcUrl
            val authorityStart = schemeEnd + marker.length
            val pathStart = jdbcUrl.indexOf('/', authorityStart)
            val authority = jdbcUrl.substring(authorityStart, if (pathStart < 0) jdbcUrl.length else pathStart)
            val at = authority.lastIndexOf('@')
            if (at < 0) return jdbcUrl
            val hostPort = authority.substring(at + 1)
            return jdbcUrl.substring(0, authorityStart) + hostPort + jdbcUrl.substring(if (pathStart < 0) jdbcUrl.length else pathStart)
        }
    }

    private val activeConnections = java.util.concurrent.ConcurrentHashMap<Connection, Thread>()

    fun <T> withConnection(block: (Connection) -> T): T {
        val owner = Thread.currentThread()
        if (owner.isInterrupted) throw InterruptedException("database_operation_cancelled")
        return dataSource.connection.use { connection ->
            activeConnections[connection] = owner
            try {
                if (owner.isInterrupted) throw InterruptedException("database_operation_cancelled")
                block(connection)
            } finally { activeConnections.remove(connection) }
        }
    }

    /** Used only by a dedicated model process's hard attempt deadline. */
    fun abortActiveConnections() {
        abortConnections(activeConnections.keys.toList())
    }

    /** Cancel an attempt without touching the input gate, archive lane or another owner. */
    fun abortConnectionsOwnedBy(owner: Thread) {
        abortConnections(activeConnections.entries.filter { it.value === owner }.map { it.key })
    }

    private fun abortConnections(connections: List<Connection>) {
        connections.forEach { connection -> runCatching {
            connection.abort { task -> Thread(task, "physiology-jdbc-abort").apply { isDaemon = true }.start() }
        } }
    }

    override fun close() {
        dataSource.close()
    }
}
