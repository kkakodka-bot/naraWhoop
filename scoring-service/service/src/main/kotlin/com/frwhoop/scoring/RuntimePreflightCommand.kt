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
    enum class Stage { WORKER_IDENTITY, PROJECT_BINDING, DATABASE_CONNECTION, DATABASE_SCHEMA, INGEST_AUTH, REST_AUTH }
    class Failure(val stage: Stage) : IllegalStateException("runtime_preflight_failed:${stage.name.lowercase()}")

    internal val requiredMigrationHashes get() = MigrationSourceCatalog.hashes
    internal val requiredTables = listOf("public.physiology_service_heartbeats", "public.physiology_work_items",
        "public.server_physiology_results", "public.noop_rr_packet_provenance", "public.noop_standard_hr_receipts",
        "public.physiology_feature_manifests", "public.physiology_promotion_approvals", "public.physiology_model_acquisition_contracts",
        "public.physiology_worker_heartbeats", "public.noop_skin_temp_samples")
    internal val requiredFunctions = listOf("internal.assert_ingest_secret(text)",
        "public.scoring_claim_one(integer,integer,uuid,uuid,date)",
        "public.scoring_acquire_input_gate(uuid,uuid)", "public.engine_publish_physiology(text,jsonb)",
        "public.scoring_renew_lease(uuid,uuid,date,bigint,uuid,uuid,integer)",
        "public.scoring_finish_work(uuid,uuid,date,bigint,uuid,uuid,text,integer,text)",
        "public.physiology_feature_is_canonical(text,text)",
        "public.scoring_legacy_claim_one(integer,integer,uuid,uuid,date)",
        "public.scoring_legacy_renew_lease(uuid,uuid,date,bigint,uuid,uuid,integer)",
        "public.scoring_legacy_finish_work(uuid,uuid,date,bigint,uuid,uuid,text,integer,text)",
        "public.engine_publish_legacy_fenced(text,jsonb)",
        "internal.engine_publish_legacy_fenced(text,jsonb)", "internal.engine_publish_physiology(text,jsonb)",
        "public.server_scoring_read_contract(uuid,date,uuid)",
        "public.server_pipeline_diagnostics(uuid,uuid,uuid,date)", "public.scoring_local_day_v2(text,text)")

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
        checked(Stage.WORKER_IDENTITY) { config.workerIdentity() }
        val endpoint = heartbeatUrl(config)
        val connection = checked(Stage.DATABASE_CONNECTION) {
            val (url, properties) = databaseConnectionParameters(config)
            DriverManager.getConnection(url, properties)
        }
        try { checkDatabase(connection, config.ingestSecret, config.algorithmVersion) }
        finally { runCatching { connection.close() } }
        checkRest(endpoint, config.serviceRoleKey)
        return "runtime_preflight_ok"
    }

    internal fun databaseConnectionParameters(config: ScoringConfig): Pair<String, Properties> {
        val credentials = PostgresClient.parseUserInfo(config.databaseUrl)
        val properties = Properties().apply {
            credentials.user?.let { setProperty("user", it) }
            credentials.password?.let { setProperty("password", it) }
            setProperty("connectTimeout", "10")
            setProperty("socketTimeout", "15")
            setProperty("cancelSignalTimeout", "5")
            setProperty("ApplicationName", "physiology-runtime-preflight")
        }
        return PostgresClient.boundedJdbcUrl(config.databaseUrl) to properties
    }

    internal fun checkDatabase(connection: Connection, ingestSecret: String, algorithmVersion: String = "frwhoop-physiology-2") {
        checked(Stage.DATABASE_CONNECTION) {
            require(connection.autoCommit)
            connection.isReadOnly = true
            connection.autoCommit = false
        }
        try {
            checked(Stage.DATABASE_SCHEMA) {
                MigrationSourceCatalog.verify(connection)
                connection.prepareStatement("select to_regclass(?) is not null").use { statement ->
                    statement.queryTimeout = 10
                    val historyTables = if (algorithmVersion == "frwhoop-server-2-history") listOf(
                        "public.scoring_jobs_v2", "public.scoring_snapshots_v2", "public.scoring_history_inputs_v3",
                        "public.scoring_history_checkpoints_v3", "public.scoring_history_heads_v3", "public.scoring_archive_jobs_v2") else emptyList()
                    for (table in requiredTables + historyTables) {
                        statement.setString(1, table)
                        statement.executeQuery().use { rows -> require(rows.next() && rows.getBoolean(1)) }
                    }
                }
                connection.prepareStatement("select to_regprocedure(?) is not null").use { statement ->
                    statement.queryTimeout = 10
                    val historyFunctions = if (algorithmVersion == "frwhoop-server-2-history") listOf(
                        "public.register_scoring_history_v3(text)", "public.claim_scoring_history_v3(text,integer)",
                        "public.publish_scoring_history_v3(uuid,bigint,bigint,bigint,jsonb,jsonb,bigint,bigint,bigint)",
                        "public.renew_scoring_v2(uuid,integer)", "public.fail_scoring_v2(uuid,bigint,text)",
                        "public.expand_scoring_history_v3(integer)") else emptyList()
                    for (function in requiredFunctions + historyFunctions) {
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
