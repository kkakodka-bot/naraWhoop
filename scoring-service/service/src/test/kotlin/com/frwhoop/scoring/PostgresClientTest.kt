package com.frwhoop.scoring

import com.frwhoop.scoring.db.PostgresClient
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PostgresClientTest {
    // URL handling is pure and testable WITHOUT opening a real Hikari pool / database
    // (Phase 3 gate: "URL normalization must be testable without requiring a real database").

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
}
