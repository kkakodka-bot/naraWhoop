import assert from "node:assert/strict";
import { createHmac } from "node:crypto";

const container = Deno.env.get("PIPELINE_TEST_DATABASE_CONTAINER");
const binary = Deno.env.get("PIPELINE_TEST_V2_BINARY");
const output = Deno.env.get("PIPELINE_TEST_OUTPUT");
async function sql(statement: string) {
  const child = new Deno.Command("docker", {
    args: [
      "exec",
      "-i",
      container!,
      "psql",
      "-U",
      "postgres",
      "-d",
      "postgres",
      "-X",
      "-qAt",
      "-v",
      "ON_ERROR_STOP=1",
    ],
    stdin: "piped",
    stdout: "piped",
    stderr: "piped",
  }).spawn();
  const writer = child.stdin.getWriter();
  await writer.write(new TextEncoder().encode(statement));
  await writer.close();
  const result = await child.output();
  assert.equal(result.code, 0, new TextDecoder().decode(result.stderr));
  return new TextDecoder().decode(result.stdout).trim();
}
function token() {
  const h = btoa(JSON.stringify({ alg: "HS256", typ: "JWT" })).replaceAll(
    "=",
    "",
  );
  const b = btoa(
    JSON.stringify({
      role: "service_role",
      exp: Math.floor(Date.now() / 1000) + 3600,
    }),
  ).replaceAll("=", "");
  return `${h}.${b}.${
    createHmac(
      "sha256",
      "isolated-pipeline-jwt-secret-never-used-outside-tests",
    ).update(`${h}.${b}`).digest("base64url")
  }`;
}

Deno.test({
  name:
    "four actual physiology processes publish isolated live and backfill work under fleet budgets",
  ignore: !container || !binary,
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    assert.match(container!, /^nara-db-server-pipeline\.[a-z0-9]+$/);
    assert.match(
      Deno.env.get("PIPELINE_TEST_REST_URL")!,
      /^http:\/\/127\.0\.0\.1:\d+$/,
    );
    await Deno.mkdir(output!, { recursive: true });
    const revision = new TextDecoder().decode(
      (await new Deno.Command("git", { args: ["rev-parse", "HEAD"] }).output())
        .stdout,
    ).trim();
    const fixtures = JSON.parse(
      await sql(`
    create temporary table worker_users as select gen_random_uuid() u,n from generate_series(1,10) n;
    create temporary table worker_devices as select u,gen_random_uuid() d,gen_random_uuid() s,n
      from worker_users cross join generate_series(1,2);
    insert into auth.users(id) select u from worker_users;
    insert into profiles(id,timezone) select u,'UTC' from worker_users on conflict(id) do update set timezone='UTC';
    insert into devices(id,user_id,source_kind) select d,u,'noop_push' from worker_devices;
    insert into noop_hr_samples(user_id,device_id,source_id,batch_id,ts,bpm)
      select u,d,s,gen_random_uuid(),extract(epoch from day::timestamp at time zone 'UTC')::bigint+43200+i,60+n
      from worker_devices cross join (values(current_date-1),(current_date-8)) dates(day) cross join generate_series(0,599) i;
    select json_agg(row_to_json(f)) from worker_devices f;`),
    );
    const owners = [...new Set(fixtures.map((f: any) => f.u))].map((u) =>
      `'${u}'`
    ).join(",");
    const noisy = fixtures[0];
    await sql(
      `insert into noop_hr_samples(user_id,device_id,source_id,batch_id,ts,bpm)
      select '${noisy.u}','${noisy.d}','${noisy.s}',gen_random_uuid(),
        extract(epoch from (current_date-day)::timestamp at time zone 'UTC')::bigint+43200+i,60
      from generate_series(10,14) day cross join generate_series(0,599) i;
    update physiology_work_items set next_attempt_at=clock_timestamp() where user_id in(${owners});`,
    );
    const committedAt = Date.now();
    const logs: Array<Promise<void>> = [], children: Deno.ChildProcess[] = [];
    let injected = false;
    const samples: any[] = [];
    try {
      for (let i = 0; i < 4; i++) {
        const child = new Deno.Command(binary!, {
          clearEnv: true,
          env: {
            PATH: Deno.env.get("PATH")!,
            JAVA_HOME: Deno.env.get("JAVA_HOME")!,
            JAVA_OPTS: "-Xmx384m",
            DATABASE_URL: Deno.env.get("PIPELINE_TEST_DATABASE_URL")!,
            SUPABASE_URL: Deno.env.get("PIPELINE_TEST_REST_URL")!,
            SUPABASE_SERVICE_ROLE_KEY: token(),
            INGEST_SECRET: "isolated-pipeline-only",
            SCORING_ALGORITHM_VERSION: "frwhoop-physiology-2",
            SCORING_WORKER_INSTANCE_ID: "auto",
            SCORING_WORKER_SOURCE_REVISION: revision,
            SCORING_POLL_SECONDS: "1",
            SCORING_DB_POOL_SIZE: "4",
            SCORING_TOTAL_REPLICAS: "4",
            SCORING_DB_CONNECTION_BUDGET: "24",
            SCORING_DB_CONNECTION_RESERVE: "8",
          },
          stdout: "piped",
          stderr: "piped",
        }).spawn();
        children.push(child);
        logs.push(
          child.output().then(async (r) => {
            await Deno.writeTextFile(
              `${output}/fleet-worker-${i}.log`,
              new TextDecoder().decode(r.stdout) +
                new TextDecoder().decode(r.stderr),
            );
          }),
        );
      }
      const deadline = Date.now() + 180000;
      let finished = false;
      while (Date.now() < deadline) {
        const state = JSON.parse(
          await sql(`select jsonb_build_object(
        'running',(select count(*) from scoring_fleet_reservations where expires_at>clock_timestamp()),
        'maxPerUser',(select coalesce(max(n),0) from(select count(*) n from scoring_fleet_reservations
          where expires_at>clock_timestamp() group by user_id) q),
        'connections',(select count(*) from pg_stat_activity where backend_type='client backend'),
        'liveOwners',(select count(distinct user_id) from physiology_work_items where user_id in(${owners})
          and day=current_date-1 and done_at is not null),
        'targetDaysDone',(select count(*) from physiology_work_items where user_id in(${owners})
          and day in(current_date-1,current_date-8) and done_at is not null),
        'pending',(select count(*) from physiology_work_items where user_id in(${owners}) and done_at is null));`),
        );
        samples.push({ at: new Date().toISOString(), ...state });
        assert.ok(state.running <= 4 && state.maxPerUser <= 2);
        assert.ok(
          state.connections <= 24,
          "four bounded pools plus reserved test/admin connections",
        );
        if (state.running > 0 && !injected) {
          injected = true;
          await sql(
            `insert into noop_hr_samples(user_id,device_id,source_id,batch_id,ts,bpm)
          values('${noisy.u}','${noisy.d}','${noisy.s}',gen_random_uuid(),
            extract(epoch from (current_date-1)::timestamp at time zone 'UTC')::bigint+44000,65);
          update physiology_work_items set next_attempt_at=clock_timestamp() where user_id='${noisy.u}';`,
          );
        }
        if (
          state.targetDaysDone === 40 && state.liveOwners === 10 &&
          state.pending === 0
        ) {
          finished = true;
          break;
        }
        await new Promise((r) => setTimeout(r, 100));
      }
      assert.ok(
        finished,
        "actual workers must settle live, noisy backfill and late committed input within the bounded run",
      );
      assert.ok(injected);
      assert.equal(
        await sql(
          `select count(*) from physiology_work_items w where w.user_id in(${owners}) and not exists(
      select 1 from server_physiology_results r where r.user_id=w.user_id and r.device_id=w.device_id
        and r.period_day=w.day and r.input_revision=w.input_revision and r.algorithm_version='frwhoop-physiology-2')`,
        ),
        "0",
      );
      const completions = JSON.parse(
        await sql(
          `select json_agg(json_build_object('class',work_class,'outcome',outcome,
      'seconds',extract(epoch from completed_at)-${
            committedAt / 1000
          })) from scoring_fleet_completions
      where user_id in(${owners})`,
        ),
      );
      const latency = (kind: string) => {
        const v = completions.filter((r: any) =>
          r.class === kind && r.outcome === "done"
        ).map((r: any) => r.seconds).sort((a: number, b: number) => a - b);
        const q = (p: number) =>
          v[Math.min(v.length - 1, Math.ceil(v.length * p) - 1)];
        return { count: v.length, p50: q(.5), p95: q(.95), p99: q(.99) };
      };
      const report = {
        sourceRevision: revision,
        owners: 10,
        devices: 20,
        workers: 4,
        inputHrRows: 27001,
        seconds: (Date.now() - committedAt) / 1000,
        liveSeconds: latency("live"),
        backfillSeconds: latency("backfill"),
        samples,
        liveArrivalDuringWork: injected,
        localScalarLiveP95Under60Seconds: latency("live").p95 <= 60,
        scope:
          "actual JVM load, scoring, publication and completion; synthetic scalar-only data; no B2/model or target-VPS capacity claim",
      };
      await Deno.writeTextFile(
        `${output}/fleet-worker-capacity.json`,
        JSON.stringify(report, null, 2),
      );
      console.log(JSON.stringify({ ...report, samples: undefined }));
    } finally {
      for (const child of children) {
        try {
          child.kill("SIGTERM");
        } catch { /* Already exited. */ }
      }
      await Promise.all(logs);
      await sql(`delete from auth.users where id in(${owners});`);
    }
  },
});
