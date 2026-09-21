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
        execute("drop table if exists supabase_migrations.scoring_source_identities")
        execute("create table if not exists supabase_migrations.schema_migrations(version text primary key,name text,source_sha256 text)")
        execute("truncate supabase_migrations.schema_migrations")
        connection.prepareStatement("insert into supabase_migrations.schema_migrations(version,source_sha256) values(?,?)").use { statement ->
            for ((version, hash) in RuntimePreflightCommand.requiredMigrationHashes) {
                statement.setString(1, version); statement.setString(2, hash); statement.executeUpdate()
            }
        }
        for (table in RuntimePreflightCommand.requiredTables) execute("create table if not exists $table(marker integer)")
        for (function in RuntimePreflightCommand.requiredFunctions.filterNot { it == "internal.assert_ingest_secret(text)" }) {
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
        execute("delete from supabase_migrations.schema_migrations where version='20260921104000_server_unrepresentable_clock.sql'")
        val error = assertThrows(RuntimePreflightCommand.Failure::class.java) {
            RuntimePreflightCommand.checkDatabase(connection, "secret-must-not-be-printed")
        }
        assertEquals(RuntimePreflightCommand.Stage.DATABASE_SCHEMA, error.stage)
        assertNull(error.cause)
    }

    @Test fun timestampAndNameKeepCollidingMigrationsDistinct() {
        val colliding = RuntimePreflightCommand.requiredMigrationHashes.keys.groupBy { it.take(14) }.values.first { it.size > 1 }
        val version = colliding.first()
        assertTrue(colliding.size > 1)
        connection.prepareStatement("update supabase_migrations.schema_migrations set version=?,name=? where version=?").use {
            it.setString(1, version.take(14)); it.setString(2, version.drop(15).removeSuffix(".sql")); it.setString(3, version)
            assertEquals(1, it.executeUpdate())
        }
        RuntimePreflightCommand.checkDatabase(connection, "fixture-secret")
    }

    @Test fun bareAmbiguousTimestampCannotClaimEitherCollisionPeer() {
        val version = RuntimePreflightCommand.requiredMigrationHashes.keys.groupBy { it.take(14) }.values.first { it.size > 1 }.first()
        execute("update supabase_migrations.schema_migrations set version='${version.take(14)}' where version='$version'")
        failsSchema()
    }

    @Test fun uniqueTimestampStillRequiresItsActualSourceHash() {
        val version = RuntimePreflightCommand.requiredMigrationHashes.keys.groupBy { it.take(14) }.values.first { it.size == 1 }.single()
        execute("update supabase_migrations.schema_migrations set version='${version.take(14)}' where version='$version'")
        RuntimePreflightCommand.checkDatabase(connection, "fixture-secret")
    }

    @Test fun currentSourceCatalogCannotStandInForAbsentHistoricalHashEvidence() {
        execute("update supabase_migrations.schema_migrations set source_sha256=null")
        failsSchema()
    }

    @Test fun changedAppliedHashFailsClosed() {
        execute("update supabase_migrations.schema_migrations set source_sha256=repeat('0',64)")
        failsSchema()
    }

    @Test fun unknownLedgerIdentityFailsClosedEvenWhenAllRequiredRowsExist() {
        execute("insert into supabase_migrations.schema_migrations(version,source_sha256) values('20260921999999_unknown.sql',repeat('0',64))")
        failsSchema()
    }

    @Test fun duplicateAliasesCannotCountAsSeparateAppliedMigrations() {
        val version = RuntimePreflightCommand.requiredMigrationHashes.keys.groupBy { it.take(14) }.values.first { it.size == 1 }.single()
        execute("insert into supabase_migrations.schema_migrations(version,source_sha256) select '${version.take(14)}',source_sha256 from supabase_migrations.schema_migrations where version='$version'")
        failsSchema()
    }

    @Test fun reviewedFullIdentityLedgerCanValidateBothMigrationStreams() {
        sourceAttestations()
        execute("truncate supabase_migrations.schema_migrations")
        RuntimePreflightCommand.checkDatabase(connection, "fixture-secret")
        assertEquals(7, sentinel())
    }

    @Test fun explicitAttestationsCanSupplyLegacyLedgerHashesWithoutInventingThem() {
        sourceAttestations()
        execute("update supabase_migrations.schema_migrations set source_sha256=null")
        RuntimePreflightCommand.checkDatabase(connection, "fixture-secret")
    }

    @Test fun validAttestationCannotHideContradictoryLedgerHash() {
        sourceAttestations()
        execute("update supabase_migrations.schema_migrations set source_sha256=repeat('0',64)")
        failsSchema()
    }

    @Test fun alteredAttestationCannotHideBehindACompleteValidStandardLedger() {
        sourceAttestations()
        execute("update supabase_migrations.scoring_source_identities set sha256=repeat('0',64)")
        failsSchema()
    }

    @Test fun ledgerCannotHideMissingConflictTransportImplementation() {
        execute("drop function internal.engine_publish_physiology(text,jsonb)")
        failsSchema()
    }

    @Test fun ledgerCannotHideMissingAuthorizedReadContract() {
        execute("drop function public.server_scoring_read_contract(uuid,date,uuid)")
        failsSchema()
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
    private fun sourceAttestations() = execute("""create table supabase_migrations.scoring_source_identities as
        select version as basename,source_sha256 as sha256 from supabase_migrations.schema_migrations""")
    private fun failsSchema() {
        val error = assertThrows(RuntimePreflightCommand.Failure::class.java) {
            RuntimePreflightCommand.checkDatabase(connection, "fixture-secret")
        }
        assertEquals(RuntimePreflightCommand.Stage.DATABASE_SCHEMA, error.stage)
        assertNull(error.cause)
        assertEquals(7, sentinel())
    }
    private fun sentinel(): Int = connection.createStatement().use { statement ->
        statement.executeQuery("select value from internal.preflight_sentinel").use { rows -> rows.next(); rows.getInt(1) }
    }
}
