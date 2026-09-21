package com.frwhoop.scoring

import com.frwhoop.scoring.db.PostgresClient
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import java.sql.Connection
import java.sql.DriverManager

/** Real PostgreSQL transaction checks in an explicitly named disposable database; never uses DATABASE_URL. */
class RuntimePreflightIntegrationTest {
    private lateinit var connection: Connection

    @Before fun setup() {
        val url = System.getenv("RUNTIME_PREFLIGHT_TEST_DATABASE_URL")
        assumeTrue("Requires disposable runtime_preflight_test PostgreSQL", url != null)
        require(url!!.startsWith("postgresql://postgres@127.0.0.1:") && url.endsWith("/runtime_preflight_test"))
        connection = DriverManager.getConnection(PostgresClient.normalizeJdbcUrl(url), "postgres", "")
        execute("create schema if not exists supabase_migrations; create schema if not exists internal; create schema if not exists auth")
        execute("create table if not exists supabase_migrations.schema_migrations(version text primary key)")
        execute("truncate supabase_migrations.schema_migrations")
        connection.prepareStatement("insert into supabase_migrations.schema_migrations values(?)").use { statement ->
            for (version in RuntimePreflightCommand.requiredMigrations) { statement.setString(1, version); statement.executeUpdate() }
        }
        for (table in RuntimePreflightCommand.requiredTables) execute("create table if not exists $table(marker integer)")
        for (function in RuntimePreflightCommand.requiredFunctions.filterNot { it.startsWith("internal.") }) {
            execute("create or replace function $function returns void language plpgsql as 'begin end'")
        }
        execute("create table if not exists internal.preflight_sentinel(value integer); truncate internal.preflight_sentinel; insert into internal.preflight_sentinel values(7)")
        execute("create or replace function auth.role() returns text language sql stable as 'select current_setting(''request.jwt.claim.role'',true)'")
        execute("""create or replace function internal.assert_ingest_secret(secret text) returns void language plpgsql as
            'begin if secret is distinct from ''fixture-secret'' then raise exception ''secret rejected: %'',secret; end if; end'""")
    }

    @After fun close() { if (::connection.isInitialized) connection.close() }

    @Test fun validConfigurationPerformsAReadOnlyTransactionAndLeavesRowsUntouched() {
        RuntimePreflightCommand.checkDatabase(connection, "fixture-secret")
        assertTrue(connection.isReadOnly)
        assertEquals(7, sentinel())
    }

    @Test fun missingMigrationFailsBeforeCheckingSecret() {
        execute("delete from supabase_migrations.schema_migrations where version='20260919010000'")
        val error = assertThrows(RuntimePreflightCommand.Failure::class.java) {
            RuntimePreflightCommand.checkDatabase(connection, "secret-must-not-be-printed")
        }
        assertEquals(RuntimePreflightCommand.Stage.DATABASE_SCHEMA, error.stage)
        assertNull(error.cause)
    }

    @Test fun migrationLedgerCannotHideMissingWorkerFunctions() {
        execute("drop function public.scoring_acquire_input_gate(uuid,uuid)")
        val error = assertThrows(RuntimePreflightCommand.Failure::class.java) {
            RuntimePreflightCommand.checkDatabase(connection, "fixture-secret")
        }
        assertEquals(RuntimePreflightCommand.Stage.DATABASE_SCHEMA, error.stage)
    }

    @Test fun migrationLedgerCannotHideMissingPerProcessHeartbeatTable() {
        execute("drop table public.physiology_worker_heartbeats")
        val error = assertThrows(RuntimePreflightCommand.Failure::class.java) {
            RuntimePreflightCommand.checkDatabase(connection, "fixture-secret")
        }
        assertEquals(RuntimePreflightCommand.Stage.DATABASE_SCHEMA, error.stage)
    }

    @Test fun physiologyDependenciesCannotSatisfyTheHistoricalWorkerContract() {
        val error = assertThrows(RuntimePreflightCommand.Failure::class.java) {
            RuntimePreflightCommand.checkDatabase(connection, "fixture-secret", "frwhoop-server-2-history")
        }
        assertEquals(RuntimePreflightCommand.Stage.DATABASE_SCHEMA, error.stage)
        assertEquals(7, sentinel())
    }

    @Test fun ingestSecretIsBoundAndDatabaseErrorCannotDiscloseIt() {
        val secret = "'); update internal.preflight_sentinel set value=99; --"
        val error = assertThrows(RuntimePreflightCommand.Failure::class.java) {
            RuntimePreflightCommand.checkDatabase(connection, secret)
        }
        assertEquals("runtime_preflight_failed:ingest_auth", error.message)
        assertNull(error.cause)
        assertFalse(error.stackTraceToString().contains(secret))
        assertEquals(7, sentinel())
    }

    @Test fun aFunctionAttemptingMutationIsRejectedByTheDatabaseReadOnlyTransaction() {
        execute("""create or replace function internal.assert_ingest_secret(secret text) returns void language plpgsql as
            'begin update internal.preflight_sentinel set value=99; end'""")
        val error = assertThrows(RuntimePreflightCommand.Failure::class.java) {
            RuntimePreflightCommand.checkDatabase(connection, "fixture-secret")
        }
        assertEquals(RuntimePreflightCommand.Stage.INGEST_AUTH, error.stage)
        assertEquals(7, sentinel())
    }

    @Test fun serviceRoleBypassCannotPassAsIngestSecretValidation() {
        execute("select set_config('request.jwt.claim.role','service_role',false)")
        val error = assertThrows(RuntimePreflightCommand.Failure::class.java) {
            RuntimePreflightCommand.checkDatabase(connection, "fixture-secret")
        }
        assertEquals(RuntimePreflightCommand.Stage.INGEST_AUTH, error.stage)
        assertEquals(7, sentinel())
    }

    private fun execute(sql: String) { connection.createStatement().use { it.execute(sql) } }
    private fun sentinel(): Int = connection.createStatement().use { statement ->
        statement.executeQuery("select value from internal.preflight_sentinel").use { rows -> rows.next(); rows.getInt(1) }
    }
}
