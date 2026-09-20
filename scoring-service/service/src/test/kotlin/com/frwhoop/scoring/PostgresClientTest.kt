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
