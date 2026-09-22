import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import {
  CAPACITY_LIVE_P95_SLO_SECONDS,
  capacitySourceIdentity,
  outcomeCounts,
  ownerFairness,
  quantiles,
  sampleProcesses,
  specialOwnerProgress,
  summarizeResourceSamples,
} from "./capacity_evidence.ts";

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
async function databaseStats() {
  try {
    const result = await new Deno.Command("docker", {
      args: [
        "stats",
        "--no-stream",
        "--format",
        "{{json .}}",
        container!,
      ],
      stdout: "piped",
      stderr: "piped",
    }).output();
    if (result.code !== 0) throw new Error("docker_stats_failed");
    return {
      status: "MEASURED",
      value: JSON.parse(new TextDecoder().decode(result.stdout).trim()),
    };
  } catch {
    return {
      status: "NOT_MEASURED",
      reason: "docker_stats_failed",
      value: null,
    };
  }
}
async function backlog(owners: string) {
  return JSON.parse(
    await sql(`select jsonb_build_object(
    'pendingTotal',count(*),
    'pendingLive',count(*) filter(where public.scoring_work_class(day,timezone_id)='live'),
    'pendingBackfill',count(*) filter(where public.scoring_work_class(day,timezone_id)='backfill'),
    'oldestSeconds',coalesce(max(extract(epoch from clock_timestamp()-dirty_at)),0)
  ) from physiology_work_items where user_id in(${owners}) and done_at is null;`),
  );
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
    const sourceIdentity = capacitySourceIdentity();
    const revision = sourceIdentity.commitSha!;
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
    const initialBacklog = await backlog(owners);
    const logs: Array<Promise<void>> = [], children: Deno.ChildProcess[] = [];
    let injected = false;
    const samples: any[] = [];
    const databaseResourceSamples: any[] = [];
    let databaseSampling = false;
    let databaseSampler: Promise<void> | null = null;
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
      databaseSampling = true;
      databaseSampler = (async () => {
        while (databaseSampling) {
          const database = await databaseStats();
          databaseResourceSamples.push({
            at: new Date().toISOString(),
            database: database.value,
            databaseStatus: database.status,
            databaseMissingReason: "reason" in database
              ? database.reason
              : null,
          });
          if (databaseSampling) {
            await new Promise((resolve) => setTimeout(resolve, 250));
          }
        }
      })();
      const deadline = Date.now() + 180000;
      let finished = false;
      while (Date.now() < deadline) {
        const state = JSON.parse(
          await sql(`select jsonb_build_object(
        'running',(select count(*) from scoring_fleet_reservations where expires_at>clock_timestamp()),
        'maxPerUser',(select coalesce(max(n),0) from(select count(*) n from scoring_fleet_reservations
          where expires_at>clock_timestamp() group by user_id) q),
        'connections',(select count(*) from pg_stat_activity where backend_type='client backend'),
        'activeConnections',(select count(*) from pg_stat_activity where backend_type='client backend' and state='active'),
        'liveOwners',(select count(distinct user_id) from physiology_work_items where user_id in(${owners})
          and day=current_date-1 and done_at is not null),
        'targetDaysDone',(select count(*) from physiology_work_items where user_id in(${owners})
          and day in(current_date-1,current_date-8) and done_at is not null),
        'pending',(select count(*) from physiology_work_items where user_id in(${owners}) and done_at is null),
        'pendingLive',(select count(*) from physiology_work_items where user_id in(${owners}) and done_at is null
          and public.scoring_work_class(day,timezone_id)='live'),
        'pendingBackfill',(select count(*) from physiology_work_items where user_id in(${owners}) and done_at is null
          and public.scoring_work_class(day,timezone_id)='backfill'),
        'oldestSeconds',(select coalesce(max(extract(epoch from clock_timestamp()-dirty_at)),0)
          from physiology_work_items where user_id in(${owners}) and done_at is null));`),
        );
        const workers = await sampleProcesses(
          children.map((child) => child.pid),
        );
        samples.push({ at: new Date().toISOString(), ...state, workers });
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
      databaseSampling = false;
      await databaseSampler;
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
          `select coalesce(json_agg(json_build_object(
      'userId',user_id,'workClass',work_class,'outcome',outcome,
      'completedAtEpoch',extract(epoch from completed_at),
      'seconds',extract(epoch from completed_at)-${
            committedAt / 1000
          }) order by completed_at,run_id),'[]'::json) from scoring_fleet_completions
      where user_id in(${owners})`,
        ),
      );
      const latency = (kind: string) => {
        const v = completions.filter((r: any) =>
          r.workClass === kind && r.outcome === "done"
        ).map((r: any) => r.seconds);
        return quantiles(v);
      };
      const finalBacklog = await backlog(owners);
      const seconds = (Date.now() - committedAt) / 1000;
      const liveLatency = latency("live");
      const fairness = {
        ...ownerFairness(completions, 10, committedAt),
        configuredLiveToBackfillWeight: "3:1",
        maxConcurrentReservations: Math.max(
          ...samples.map((sample) => sample.running),
        ),
        maxReservationsPerOwner: Math.max(
          ...samples.map((sample) => sample.maxPerUser),
        ),
        noisyOwner: specialOwnerProgress(completions, noisy.u),
      };
      const normalizedStateSamples = samples.map((sample) => ({
        ...sample,
        connections: {
          total: sample.connections,
          active: sample.activeConnections,
        },
      }));
      const resourceSamples = [
        ...normalizedStateSamples,
        ...databaseResourceSamples,
      ];
      const outcomes = outcomeCounts(completions);
      const report = {
        schemaVersion: 2,
        sourceIdentity,
        sourceRevision: revision,
        runtime: {
          deno: Deno.version.deno,
          v8: Deno.version.v8,
          typescript: Deno.version.typescript,
          os: Deno.build.os,
          arch: Deno.build.arch,
          workerJavaMaxHeapBytes: 384 * 1024 * 1024,
        },
        owners: 10,
        devices: 20,
        workers: 4,
        inputHrRows: 27001,
        seconds,
        liveSeconds: liveLatency,
        backfillSeconds: latency("backfill"),
        backlogRecovery: {
          initial: initialBacklog,
          final: finalBacklog,
          drainSeconds: seconds,
          drained: finalBacklog.pendingTotal === 0,
          samples: samples.map((sample) => ({
            at: sample.at,
            pendingTotal: sample.pending,
            pendingLive: sample.pendingLive,
            pendingBackfill: sample.pendingBackfill,
            oldestSeconds: sample.oldestSeconds,
          })),
        },
        retries: {
          outcomeCounts: outcomes,
          durableAttempts: completions.length,
          attemptsPerCompleted: completions.length /
            (outcomes.done ?? 1),
          lateInputRevisionInjected: injected,
          workerRestart: {
            status: "NOT_MEASURED",
            reason: "not_exercised_by_actual_worker_capacity_fixture",
          },
          leaseExpiry: {
            status: "NOT_MEASURED",
            reason: "covered_by_scheduler_capacity_fixture",
          },
        },
        fairness,
        samples,
        databaseResourceSamples,
        resourceSummary: summarizeResourceSamples(resourceSamples, "workers"),
        liveArrivalDuringWork: injected,
        publicationP95SloSeconds: CAPACITY_LIVE_P95_SLO_SECONDS,
        localScalarLiveP95Under60Seconds:
          liveLatency.p95 <= CAPACITY_LIVE_P95_SLO_SECONDS,
        scope:
          "actual JVM load, scoring, publication and completion; synthetic scalar-only data; no B2/model or target-VPS capacity claim",
      };
      await Deno.writeTextFile(
        `${output}/fleet-worker-capacity.json`,
        JSON.stringify(report, null, 2),
      );
      console.log(JSON.stringify({ ...report, samples: undefined }));
    } finally {
      databaseSampling = false;
      if (databaseSampler) await databaseSampler;
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
