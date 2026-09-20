package com.frwhoop.scoring.db

import com.zaxxer.hikari.HikariConfig
import com.zaxxer.hikari.HikariDataSource
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

    constructor(databaseUrl: String) : this(
        HikariDataSource(
            HikariConfig().apply {
                driverClassName = "org.postgresql.Driver"
                jdbcUrl = normalizeJdbcUrl(databaseUrl)
                maximumPoolSize = 6
                minimumIdle = 1
                connectionTimeout = 30_000
                idleTimeout = 600_000
                maxLifetime = 1_800_000

                // Hikari's connectionTimeout only bounds borrowing a pool connection. A
                // separate input-gate watchdog cannot interrupt this connection's reads.
                // pgJDBC deadlines are seconds; URL options intentionally override these
                // defaults (https://jdbc.postgresql.org/documentation/use/). socketTimeout
                // bounds a stalled read, not total job time or a stream making progress.
                addDataSourceProperty("connectTimeout", "10")
                addDataSourceProperty("socketTimeout", "60")
                addDataSourceProperty("cancelSignalTimeout", "5")

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

    fun <T> withConnection(block: (Connection) -> T): T =
        dataSource.connection.use(block)

    override fun close() {
        dataSource.close()
    }
}
