package com.frwhoop.scoring

import com.frwhoop.scoring.db.PostgresClient
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class PostgresClientTest {
    // URL handling is pure and testable WITHOUT opening a real Hikari pool / database
    // (Phase 3 gate: "URL normalization must be testable without requiring a real database").

    @Test fun boundedWorkersCannotDisableDriverTimeoutsThroughUrlOptions() {
        assertEquals("jdbc:postgresql://db/postgres?sslmode=require&options=-c%20default_transaction_read_only%3Don",
            PostgresClient.boundedJdbcUrl("postgresql://user:secret@db/postgres?socketTimeout=0&connectTimeout=0&" +
                "cancelSignalTimeout=0&socket%54imeout=999&sslmode=require&options=-c%20default_transaction_read_only%3Don"))
        assertEquals("jdbc:postgresql://db/postgres",PostgresClient.boundedJdbcUrl("postgres://db/postgres?socketTimeout=0"))
        assertEquals("jdbc:postgresql://db/postgres?socketTimeout=0",
            PostgresClient.normalizeJdbcUrl("postgres://db/postgres?socketTimeout=0"))
    }

    @Test fun hostedTlsUsesTheJvmSystemTrustFactoryWithoutChangingTheLibpqCompatibleUrl() {
        val url = "postgresql://postgres.project:secret@aws-0-us-west-1.pooler.supabase.com:6543/postgres?" +
            "sslmode=verify-full&sslrootcert=system"
        assertEquals(mapOf("sslfactory" to "org.postgresql.ssl.DefaultJavaSSLFactory"),
            PostgresClient.verifiedHostedJdbcProperties(url))
        assertEquals("jdbc:postgresql://aws-0-us-west-1.pooler.supabase.com:6543/postgres?" +
            "sslmode=verify-full&sslrootcert=system", PostgresClient.normalizeJdbcUrl(url))
        val parsed = org.postgresql.Driver.parseURL(PostgresClient.normalizeJdbcUrl(url),
            java.util.Properties().apply { putAll(PostgresClient.verifiedHostedJdbcProperties(url)) })!!
        assertEquals("org.postgresql.ssl.DefaultJavaSSLFactory",
            org.postgresql.core.SocketFactoryFactory.getSslSocketFactory(parsed).javaClass.name)
        for (override in listOf(
            "sslfactory=org.postgresql.ssl.NonValidatingFactory",
            "sslhostnameverifier=example.UnreviewedVerifier",
            "user=postgres.other-project",
        )) assertThrows(IllegalArgumentException::class.java) {
            PostgresClient.verifiedHostedJdbcProperties("$url&$override")
        }
        assertEquals(emptyMap<String, String>(),
            PostgresClient.verifiedHostedJdbcProperties("postgresql://postgres:secret@localhost:5432/postgres"))
    }

    @Test
    fun normalizesPostgresqlUrlToJdbc() {
        // Userinfo is stripped for the JDBC URL; credentials travel via Hikari data-source properties.
        assertEquals(
            "jdbc:postgresql://localhost:5432/postgres",
            PostgresClient.normalizeJdbcUrl("postgresql://user:pass@localhost:5432/postgres"),
        )
        val (user, password) = PostgresClient.parseUserInfo("postgresql://user:pass@localhost:5432/postgres")
        assertEquals("user", user)
        assertEquals("pass", password)
    }

    @Test fun explicitReviewedCaUsesActualValidatingDriverFactoryAndRejectsChangedTrust() {
        val directory = java.nio.file.Files.createTempDirectory("hosted-ca-test").toRealPath()
        try {
            val original = java.nio.file.Path.of("../../Tools/release/certificates/supabase-prod-ca-2021.crt").toRealPath()
            val ca = java.nio.file.Files.copy(original, directory.resolve("ca.crt"))
            val encodedPath = java.net.URLEncoder.encode(ca.toString(), java.nio.charset.StandardCharsets.UTF_8)
            val url = "postgresql://postgres:private-test@db.sgoyxzcagqyxexmsidtk.supabase.co:5432/postgres?" +
                "sslmode=verify-full&sslrootcert=$encodedPath"
            val properties = PostgresClient.verifiedHostedJdbcProperties(url)
            assertEquals(emptyMap<String, String>(), properties)
            val parsed = org.postgresql.Driver.parseURL(PostgresClient.normalizeJdbcUrl(url),
                java.util.Properties().apply { putAll(properties) })!!
            assertEquals("verify-full", parsed.getProperty("sslmode"))
            assertEquals(ca.toString(), parsed.getProperty("sslrootcert"))
            assertEquals("org.postgresql.ssl.LibPQFactory",
                org.postgresql.core.SocketFactoryFactory.getSslSocketFactory(parsed).javaClass.name)
            assertThrows(IllegalArgumentException::class.java) {
                PostgresClient.verifiedHostedJdbcProperties(url.replace("verify-full", "require"))
            }
            val link = java.nio.file.Files.createSymbolicLink(directory.resolve("link.crt"), ca)
            assertThrows(IllegalArgumentException::class.java) {
                PostgresClient.verifiedHostedJdbcProperties(url.substringBefore("sslrootcert=") + "sslrootcert=" + link)
            }
            java.nio.file.Files.writeString(ca, "changed trust")
            val error = assertThrows(IllegalArgumentException::class.java) {
                PostgresClient.verifiedHostedJdbcProperties(url)
            }
            assertEquals("Hosted DATABASE_URL root certificate differs from reviewed trust", error.message)
            assertNull(error.cause)
        } finally { directory.toFile().deleteRecursively() }
    }

    @Test
    fun normalizesPostgresUrlToJdbcPostgresql() {
        assertEquals(
            "jdbc:postgresql://localhost:5432/postgres",
            PostgresClient.normalizeJdbcUrl("postgres://user:pass@localhost:5432/postgres"),
        )
        val (user, password) = PostgresClient.parseUserInfo("postgres://user:pass@localhost:5432/postgres")
        assertEquals("user", user)
        assertEquals("pass", password)
    }

    @Test
    fun jdbcPrefixedUrlIsNormalizedToUserinfoFree() {
        assertEquals(
            "jdbc:postgresql://localhost:5432/postgres",
            PostgresClient.normalizeJdbcUrl("jdbc:postgresql://user:pass@localhost:5432/postgres"),
        )
    }

    // pgJDBC rejects userinfo in the URL (parses `user:pass@host` as the host). The client therefore
    // strips userinfo for the JDBC URL and passes credentials via Hikari data-source properties.
    @Test
    fun stripsUserInfoForJdbcUrl() {
        assertEquals(
            "jdbc:postgresql://localhost:5432/postgres",
            PostgresClient.normalizeJdbcUrl("jdbc:postgresql://postgres:s3cr3t@localhost:5432/postgres"),
        )
    }

    @Test
    fun extractsUserAndPassword() {
        val (user, password) = PostgresClient.parseUserInfo("jdbc:postgresql://postgres:s3cr3t@db:5432/postgres")
        assertEquals("postgres", user)
        assertEquals("s3cr3t", password)
    }

    @Test
    fun noUserInfoMeansNullCredentials() {
        val (user, password) = PostgresClient.parseUserInfo("jdbc:postgresql://db:5432/postgres")
        assertNull(user)
        assertNull(password)
    }

    @Test
    fun passwordMayContainAtSign() {
        val (user, password) = PostgresClient.parseUserInfo("jdbc:postgresql://postgres:p@ss@db:5432/postgres")
        assertEquals("postgres", user)
        assertEquals("p@ss", password)
    }

    @Test
    fun percentEncodedCredentialsAreDecodedAfterSplitting() {
        val url = "postgresql://postgres%2Eproject:p%40ss%2Fword%3Fend%25@pooler.example:5432/postgres?sslmode=require"
        assertEquals(
            PostgresClient.Companion.UserInfo("postgres.project", "p@ss/word?end%"),
            PostgresClient.parseUserInfo(url),
        )
        assertEquals("jdbc:postgresql://pooler.example:5432/postgres?sslmode=require", PostgresClient.normalizeJdbcUrl(url))
    }

    @Test
    fun percentEscapesAreDecodedOnceAndLiteralPlusIsPreserved() {
        val result = PostgresClient.parseUserInfo("jdbc:postgresql://user%3Aname:p+%2B%252F%20end@db:5432/postgres")
        assertEquals("user:name", result.user)
        assertEquals("p++%2F end", result.password)
    }

    @Test
    fun encodedUtf8AndPasswordlessUsernameAreSupported() {
        assertEquals("caf\u00e9", PostgresClient.parseUserInfo("postgres://caf%C3%A9@db/postgres").user)
        assertNull(PostgresClient.parseUserInfo("postgres://caf%C3%A9@db/postgres").password)
    }

    @Test
    fun malformedEscapesFailWithoutExposingTheCredential() {
        for (password in listOf("secret%", "secret%2", "secret%zz")) {
            val error = assertThrows(IllegalArgumentException::class.java) {
                PostgresClient.parseUserInfo("postgres://user:$password@db/postgres")
            }
            assertEquals("DATABASE_URL has malformed percent encoding in userinfo", error.message)
            assertNull(error.cause)
        }
    }
}
