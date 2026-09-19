package com.frwhoop.scoring

import com.frwhoop.scoring.db.PostgresClient
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import java.net.URI
import java.sql.Connection
import java.sql.DriverManager
import java.util.Properties
import java.util.concurrent.TimeUnit

/** Read-only deployment check. Never initializes a worker, claims work, or tests a publication RPC. */
object RuntimePreflightCommand {
    enum class Stage { PROJECT_BINDING, DATABASE_CONNECTION, DATABASE_SCHEMA, INGEST_AUTH, REST_AUTH }
    class Failure(val stage: Stage) : IllegalStateException("runtime_preflight_failed:${stage.name.lowercase()}")

    // Every physiology migration this binary depends on, including the restored revision fence and gate.
    internal val requiredMigrations = setOf(
        "20260918010000", "20260918020000", "20260918030000", "20260918040000",
        "20260918050000", "20260918060000", "20260918070000", "20260918100000",
        "20260918110000", "20260918120000", "20260918130000", "20260918140000",
        "20260918150000", "20260918180000", "20260918190000", "20260918200000",
        "20260918210000", "20260918220000",
    )
    internal val requiredTables = listOf("public.physiology_service_heartbeats", "public.physiology_work_items",
        "public.server_physiology_results", "public.noop_rr_packet_provenance", "public.noop_standard_hr_receipts")
    internal val requiredFunctions = listOf("internal.assert_ingest_secret(text)",
        "public.scoring_claim_one(integer,integer,uuid,uuid,date)",
        "public.scoring_acquire_input_gate(uuid,uuid)", "public.engine_publish_physiology(text,jsonb)",
        "public.scoring_renew_lease(uuid,uuid,date,bigint,uuid,uuid,integer)",
        "public.scoring_finish_work(uuid,uuid,date,bigint,uuid,uuid,text,integer,text)")

    private fun <T> checked(stage: Stage, block: () -> T): T = try { block() }
        catch (_: Exception) { throw Failure(stage) } // A JDBC/HTTP exception may contain credentials or server data.

    internal fun heartbeatUrl(config: ScoringConfig): HttpUrl = checked(Stage.PROJECT_BINDING) {
        val url = requireNotNull(config.supabaseUrl.toHttpUrlOrNull())
        require(url.isHttps && url.username.isEmpty() && url.password.isEmpty() &&
            url.port == 443 && url.encodedPath.trimEnd('/') == "/rest/v1" && url.query == null && url.fragment == null)
        val project = Regex("^([a-z0-9]{20})\\.supabase\\.co$").matchEntire(url.host)?.groupValues?.get(1)
        requireNotNull(project) // Custom domains require independent binding evidence; token claims alone are not proof.
        val db = URI(PostgresClient.normalizeJdbcUrl(config.databaseUrl).removePrefix("jdbc:"))
        require(db.scheme == "postgresql" && db.host != null && db.fragment == null)
        // JDBC query options can override properties passed to DriverManager. In particular, a
        // second user/host must not silently change the project selected by a pooler connection.
        val allowedOptions = setOf("sslmode", "ssl", "sslrootcert", "connectTimeout", "socketTimeout",
            "ApplicationName", "applicationName", "targetServerType", "channelBinding", "prepareThreshold")
        require(db.rawQuery.orEmpty().split('&').filter(String::isNotEmpty).all {
            it.substringBefore('=') in allowedOptions
        })
        val direct = Regex("^db\\.([a-z0-9]{20})\\.supabase\\.co$").matchEntire(db.host)?.groupValues?.get(1)
        val user = PostgresClient.parseUserInfo(config.databaseUrl).user
        val pooler = if (db.host.endsWith(".pooler.supabase.com"))
            Regex("^postgres\\.([a-z0-9]{20})$").matchEntire(user.orEmpty())?.groupValues?.get(1) else null
        require(project == (direct ?: pooler))
        require(!config.serviceRoleKey.isBlank() && !config.ingestSecret.isBlank())
        url.newBuilder().encodedPath("/rest/v1/physiology_service_heartbeats")
            .addQueryParameter("select", "version").addQueryParameter("id", "eq.1")
            .addQueryParameter("limit", "1").build()
    }

    /** Returns a fixed marker only. Caller may print it; no configured identifiers/secrets are returned. */
    fun run(config: ScoringConfig): String {
        val endpoint = heartbeatUrl(config)
        val connection = checked(Stage.DATABASE_CONNECTION) {
            val credentials = PostgresClient.parseUserInfo(config.databaseUrl)
            val properties = Properties().apply {
                credentials.user?.let { setProperty("user", it) }
                credentials.password?.let { setProperty("password", it) }
                setProperty("connectTimeout", "10")
                setProperty("socketTimeout", "15")
                setProperty("ApplicationName", "physiology-runtime-preflight")
            }
            DriverManager.getConnection(PostgresClient.normalizeJdbcUrl(config.databaseUrl), properties)
        }
        try { checkDatabase(connection, config.ingestSecret) }
        finally { runCatching { connection.close() } }
        checkRest(endpoint, config.serviceRoleKey)
        return "runtime_preflight_ok"
    }

    internal fun checkDatabase(connection: Connection, ingestSecret: String) {
        checked(Stage.DATABASE_CONNECTION) {
            require(connection.autoCommit)
            connection.isReadOnly = true
            connection.autoCommit = false
        }
        try {
            checked(Stage.DATABASE_SCHEMA) {
                connection.createStatement().use { statement ->
                    statement.queryTimeout = 10
                    statement.executeQuery("select version from supabase_migrations.schema_migrations").use { rows ->
                        val versions = buildSet { while (rows.next()) add(rows.getString(1)) }
                        require(versions.containsAll(requiredMigrations))
                    }
                }
                connection.prepareStatement("select to_regclass(?) is not null").use { statement ->
                    statement.queryTimeout = 10
                    for (table in requiredTables) {
                        statement.setString(1, table)
                        statement.executeQuery().use { rows -> require(rows.next() && rows.getBoolean(1)) }
                    }
                }
                connection.prepareStatement("select to_regprocedure(?) is not null").use { statement ->
                    statement.queryTimeout = 10
                    for (function in requiredFunctions) {
                        statement.setString(1, function)
                        statement.executeQuery().use { rows -> require(rows.next() && rows.getBoolean(1)) }
                    }
                }
            }
            checked(Stage.INGEST_AUTH) {
                // assert_ingest_secret bypasses its comparison for service-role JWT sessions.
                // Refuse that context so this check actually validates the supplied secret.
                connection.createStatement().use { statement ->
                    statement.queryTimeout = 10
                    statement.executeQuery("select auth.role() is distinct from 'service_role'").use { rows ->
                        require(rows.next() && rows.getBoolean(1))
                    }
                }
                connection.prepareStatement("select internal.assert_ingest_secret(?)").use { statement ->
                    statement.queryTimeout = 10
                    statement.setString(1, ingestSecret)
                    statement.executeQuery().use { rows -> require(rows.next()) }
                }
            }
        } finally {
            runCatching { connection.rollback() }
        }
    }

    internal fun checkRest(endpoint: HttpUrl, serviceRoleKey: String) = checked(Stage.REST_AUTH) {
        // Never follow a redirect carrying the service key. Response bodies/errors are never logged.
        val http = OkHttpClient.Builder().connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(10, TimeUnit.SECONDS).callTimeout(15, TimeUnit.SECONDS)
            .followRedirects(false).followSslRedirects(false).build()
        val request = Request.Builder().url(endpoint).get()
            .header("apikey", serviceRoleKey).header("Authorization", "Bearer $serviceRoleKey").build()
        http.newCall(request).execute().use { response ->
            require(response.code == 200)
            val body = response.body ?: error("missing response")
            require(body.contentLength() <= 4096)
            val source = body.source()
            source.request(4097)
            require(source.buffer.size <= 4096)
            val rows = JSONArray(source.readUtf8())
            require(rows.length() == 1 && (rows.getJSONObject(0).opt("version") as? String)?.isNotBlank() == true)
        }
    }
}
