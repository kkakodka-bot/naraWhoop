package com.frwhoop.scoring

import com.frwhoop.scoring.db.PostgresClient
import com.frwhoop.scoring.db.ScoringWorkQueue
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Before
import java.net.ServerSocket
import java.nio.file.Files
import java.nio.file.Path
import java.sql.DriverManager
import java.util.UUID
import java.util.concurrent.TimeUnit

/** Starts its own loopback-only PG cluster. Never accepts a DATABASE_URL or existing data directory. */
object DisposablePostgres {
    private val pg = Path.of(System.getenv("W3_TEST_PG_BIN") ?: "/opt/homebrew/opt/postgresql@18/bin")
    private val artifacts = Path.of(System.getenv("W3_TEST_ARTIFACTS") ?: System.getProperty("java.io.tmpdir"))
    val directory: Path = Files.createTempDirectory(Files.createDirectories(artifacts), "w3-pg-")
    private val data = directory.resolve("data")
    private val port = ServerSocket(0).use { it.localPort }
    val url = "jdbc:postgresql://127.0.0.1:$port/postgres?user=w3test"
    val db: PostgresClient
    val root: Path = Path.of("../..").toAbsolutePath().normalize()

    init {
        check(Files.isExecutable(pg.resolve("initdb"))) { "PostgreSQL native integration requires W3_TEST_PG_BIN" }
        run("initdb", "-D",data.toString(),"--auth=trust","--username=w3test","--no-locale","--encoding=UTF8")
        run("pg_ctl","-D",data.toString(),"-l",directory.resolve("postgres.log").toString(),
            "-o","-F -h 127.0.0.1 -p $port -c unix_socket_directories=''","-w","-t","30","start")
        Runtime.getRuntime().addShutdownHook(Thread {
            runCatching { run("pg_ctl","-D",data.toString(),"-m","fast","-w","-t","30","stop") }
        })
        db = PostgresClient(url)
        sql("""
            create role anon; create role authenticated; create role service_role bypassrls;
            create schema auth; create schema extensions; create schema internal;
            create table auth.users(id uuid primary key);
            create function auth.uid() returns uuid language sql stable as
              'select nullif(current_setting(''request.jwt.claim.sub'',true),'''')::uuid';
            create function auth.role() returns text language sql stable as 'select current_user::text';
            grant usage on schema auth,public to authenticated,anon,service_role;
        """.trimIndent())
        migration("20260819190000_frwhoop_base_schema.sql")
        sql("alter table profiles add reported_age_years integer")
        // The historical storage migration contains unrelated legacy dependencies. Use its exact
        // canonical object table definition, not a mock of the queue/result tables under test.
        val storage = Files.readString(root.resolve("supabase/migrations/20260824180000_production_persistence.sql"))
        val objectDDL = storage.substring(storage.indexOf("create table if not exists public.object_manifests ("))
        sql(objectDDL.substring(0,objectDDL.indexOf("\n);")+3))
        sql("""create function internal.assert_ingest_secret(text) returns void language plpgsql as
            'begin if $1 <> ''test-only'' then raise exception ''unauthorized''; end if; end';""")
        migration("20260907133000_noop_hr_samples.sql")
        migration("20260907133100_noop_append_stream_projections.sql")
        migration("20260907170000_noop_raw_object_lane.sql")
        migration("20260911120000_noop_remaining_append_projections.sql")
        migration("20260916160000_scoring_service_state.sql")
        migration("20260916170000_scoring_work_items_device_id.sql")
        migration("20260917190000_scoring_derived_artifact.sql")
        migration("20260918010000_production_scoring_durability.sql")
        migration("20260918020000_production_intake_durability.sql")
        migration("20260918030000_production_scoring_review_repairs.sql")
        migration("20260918050000_production_scoring_history.sql")
        println("W3 disposable PostgreSQL artifacts: $directory")
    }

    private fun run(vararg arguments: String) {
        val p = ProcessBuilder(listOf(pg.resolve(arguments[0]).toString())+arguments.drop(1))
            .redirectErrorStream(true).redirectOutput(ProcessBuilder.Redirect.appendTo(directory.resolve("lifecycle.log").toFile())).start()
        check(p.waitFor(45,TimeUnit.SECONDS)) { "PG process timed out: ${arguments[0]}" }
        check(p.exitValue()==0) { "PG ${arguments[0]} failed; inspect $directory/lifecycle.log" }
    }
    private fun migration(name: String) = sql(Files.readString(root.resolve("supabase/migrations/$name")))
    fun sql(text: String) { db.withConnection { c -> c.createStatement().use { it.execute(text) } } }
    fun scalar(text: String): String? = db.withConnection { c ->
        c.createStatement().use { s -> s.executeQuery(text).use { r -> if (r.next()) r.getString(1) else null } }
    }
    fun connection() = DriverManager.getConnection(url)
}

abstract class PgIntegrationBase {
    protected val u: UUID = UUID.fromString("10000000-0000-4000-8000-000000000001")
    protected val other: UUID = UUID.fromString("10000000-0000-4000-8000-000000000002")
    protected val device: UUID = UUID.fromString("20000000-0000-4000-8000-000000000001")
    protected val device2: UUID = UUID.fromString("20000000-0000-4000-8000-000000000002")
    protected val day = "2026-09-15"
    protected val pg get() = DisposablePostgres
    protected val queue get() = ScoringWorkQueue(pg.db)
    protected fun sql(text: String) = pg.sql(text)
    protected fun scalar(text: String) = pg.scalar(text)

    @Before fun resetFixture() {
        sql("truncate auth.users cascade; delete from scoring_algorithms_v2 where algorithm_version<>'frwhoop-server-1'")
        sql("insert into auth.users values('$u'),('$other')")
        sql("insert into devices(id,user_id,source_kind,device_family) values('$device','$u','noop_push','whoop5'),('$device2','$u','noop_push','whoop5')")
    }

    protected fun payload(hrv: Double = 42.0, sleep: JSONArray = JSONArray()): JSONObject = JSONObject()
        .put("timezone","UTC").put("dataThrough","2026-09-15T10:00:00Z").put("status","partial")
        .put("coverage",JSONObject().put("gaps",JSONArray().put("historical_state_unavailable")))
        .put("daily",JSONObject().put("hrv_rmssd_ms",hrv)).put("sleep",sleep)

    protected fun night(start: String = "2026-09-15T00:00:00Z", id: UUID = UUID.randomUUID()): JSONObject = JSONObject()
        .put("id",id.toString()).put("start_at",start).put("end_at","2026-09-15T08:00:00Z")
        .put("is_nap",false).put("in_bed_min",480).put("asleep_min",420).put("awake_min",60)
        .put("light_min",200).put("deep_min",100).put("rem_min",120).put("efficiency",0.875)
        .put("stages",JSONArray().put(JSONObject().put("start",1789430400).put("end",1789459200).put("stage","light")))
}
