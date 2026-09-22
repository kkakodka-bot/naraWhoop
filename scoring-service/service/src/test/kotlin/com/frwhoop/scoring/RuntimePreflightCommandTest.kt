package com.frwhoop.scoring

import com.sun.net.httpserver.HttpServer
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.*
import org.junit.Test
import java.net.InetSocketAddress
import java.util.concurrent.atomic.AtomicInteger

class RuntimePreflightCommandTest {
    private val project = "abcdefghijklmnopqrst"
    private val config = ScoringConfig("postgresql://postgres.$project:private-password@aws-0-us-west-1.pooler.supabase.com:6543/postgres?sslmode=verify-full&sslrootcert=system",
        "private-ingest", "https://$project.supabase.co/rest/v1", "private-service")

    @Test fun directAndPoolerConnectionsRequireTheSameCanonicalHostedProject() {
        for (database in listOf(config.databaseUrl,
            "postgresql://postgres:secret@db.$project.supabase.co:5432/postgres?sslmode=verify-full&sslrootcert=system")) {
            val endpoint = RuntimePreflightCommand.heartbeatUrl(config.copy(databaseUrl = database))
            assertEquals("https://$project.supabase.co/rest/v1/physiology_service_heartbeats?select=version&id=eq.1&limit=1", endpoint.toString())
        }
    }

    @Test fun urlOptionsCannotDisableThePreflightDriverDeadlines() {
        val candidate = config.copy(databaseUrl = config.databaseUrl + "&connectTimeout=0&socketTimeout=0")
        RuntimePreflightCommand.heartbeatUrl(candidate)
        val (url, properties) = RuntimePreflightCommand.databaseConnectionParameters(candidate)
        val actual = org.postgresql.Driver.parseURL(url, properties)!!
        assertEquals("10", actual.getProperty("connectTimeout"))
        assertEquals("15", actual.getProperty("socketTimeout"))
        assertEquals("5", actual.getProperty("cancelSignalTimeout"))
        assertEquals("verify-full", actual.getProperty("sslmode"))
        assertEquals("system", actual.getProperty("sslrootcert"))
        assertEquals("org.postgresql.ssl.DefaultJavaSSLFactory", actual.getProperty("sslfactory"))
        assertFalse(url.contains("private-password"))
    }

    @Test fun mismatchedUnknownOrInsecureEndpointsFailBeforeCredentialsCanLeave() {
        val invalid = listOf(
            config.copy(databaseUrl = config.databaseUrl.replace("postgres.$project", "postgres.zyxwvutsrqponmlkjihg")),
            config.copy(databaseUrl = "postgresql://postgres.$project:secret@untrusted.example/postgres"),
            config.copy(databaseUrl = config.databaseUrl + "&user=postgres.zyxwvutsrqponmlkjihg"),
            config.copy(databaseUrl = config.databaseUrl + "&%75ser=postgres.zyxwvutsrqponmlkjihg"),
            config.copy(databaseUrl = config.databaseUrl.substringBefore('?')),
            config.copy(databaseUrl = config.databaseUrl.replace("sslmode=verify-full", "sslmode=require")),
            config.copy(databaseUrl = config.databaseUrl.replace("sslrootcert=system", "sslrootcert=/tmp/unreviewed.pem")),
            config.copy(databaseUrl = config.databaseUrl + "&sslmode=verify-full"),
            config.copy(databaseUrl = config.databaseUrl + "&sslrootcert=system"),
            config.copy(databaseUrl = config.databaseUrl + "&ssl=true"),
            config.copy(supabaseUrl = "http://$project.supabase.co/rest/v1"),
            config.copy(supabaseUrl = "https://custom.example/rest/v1"),
            config.copy(supabaseUrl = "https://$project.supabase.co/functions/v1"),
            config.copy(supabaseUrl = "https://$project.supabase.co/rest/v1?secret=hidden"),
            config.copy(supabaseUrl = "https://user:secret@$project.supabase.co/rest/v1"),
            config.copy(supabaseUrl = "https://$project.supabase.co"),
        )
        for (candidate in invalid) {
            val error = assertThrows(RuntimePreflightCommand.Failure::class.java) { RuntimePreflightCommand.heartbeatUrl(candidate) }
            assertEquals("runtime_preflight_failed:project_binding", error.message)
            assertNull(error.cause)
        }
    }

    @Test fun restProbeOnlyReadsTheHeartbeatWithBothAuthenticationHeaders() {
        serve(200, "[{\"version\":\"frwhoop-physiology-2\"}]") { server, path ->
            RuntimePreflightCommand.checkRest(path.toHttpUrl(), "synthetic-token")
            assertEquals(1, server.requests.get())
            assertEquals("GET", server.method)
            assertEquals("Bearer synthetic-token", server.authorization)
            assertEquals("synthetic-token", server.apiKey)
            assertEquals(0, server.bodyBytes)
        }
    }

    @Test fun rejectedMalformedEmptyAndOversizedResponsesAreSanitized() {
        for ((status, body) in listOf(401 to "secret-from-server", 500 to "postgresql://secret", 200 to "[]",
            200 to "{}", 200 to "[{\"version\":\"\"}]", 200 to "x".repeat(4097))) {
            serve(status, body) { _, path ->
                val error = assertThrows(RuntimePreflightCommand.Failure::class.java) {
                    RuntimePreflightCommand.checkRest(path.toHttpUrl(), "private-token")
                }
                assertEquals("runtime_preflight_failed:rest_auth", error.message)
                assertNull(error.cause)
            }
        }
    }

    @Test fun redirectsNeverForwardTheServiceCredential() {
        val target = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        val hits = AtomicInteger()
        target.createContext("/") { response -> hits.incrementAndGet(); response.sendResponseHeaders(200, -1); response.close() }
        target.start()
        try {
            serve(302, "", "http://127.0.0.1:${target.address.port}/") { _, path ->
                assertThrows(RuntimePreflightCommand.Failure::class.java) {
                    RuntimePreflightCommand.checkRest(path.toHttpUrl(), "private-token")
                }
                assertEquals(0, hits.get())
            }
        } finally { target.stop(0) }
    }

    private class Seen {
        val requests = AtomicInteger()
        var method: String? = null
        var authorization: String? = null
        var apiKey: String? = null
        var bodyBytes = -1
    }
    private fun serve(status: Int, body: String, redirect: String? = null, block: (Seen, String) -> Unit) {
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        val seen = Seen()
        server.createContext("/rest/v1/physiology_service_heartbeats") { exchange ->
            seen.requests.incrementAndGet(); seen.method = exchange.requestMethod
            seen.authorization = exchange.requestHeaders.getFirst("Authorization")
            seen.apiKey = exchange.requestHeaders.getFirst("apikey")
            seen.bodyBytes = exchange.requestBody.readBytes().size
            redirect?.let { exchange.responseHeaders.add("Location", it) }
            val bytes = body.toByteArray()
            exchange.sendResponseHeaders(status, if (bytes.isEmpty()) -1 else bytes.size.toLong())
            exchange.responseBody.use { it.write(bytes) }
            exchange.close()
        }
        server.start()
        try { block(seen, "http://127.0.0.1:${server.address.port}/rest/v1/physiology_service_heartbeats?select=version&id=eq.1&limit=1") }
        finally { server.stop(0) }
    }
}
