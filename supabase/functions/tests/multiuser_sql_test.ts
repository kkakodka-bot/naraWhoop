import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { createSupabaseRest } from "../_shared/rest.ts";
import { createInstallationLifecycle } from "../_shared/installationLifecycle.ts";
import {
  createNoopDeviceResolver,
  findNoopDevice,
} from "../_shared/devices.ts";
import { resolveUploadIdentity } from "../_shared/tokens.ts";
import { createPushObjects } from "../_shared/objects.ts";
import { createDeletionService } from "../_shared/workers.ts";
import { pushConfig } from "../_shared/config.ts";

const container = Deno.env.get("PIPELINE_TEST_DATABASE_CONTAINER");
const restUrl = Deno.env.get("PIPELINE_TEST_REST_URL");
const output = Deno.env.get("PIPELINE_TEST_OUTPUT");
function capacityCohorts(): number[] {
  const configured = Deno.env.get("PIPELINE_TEST_CAPACITY_COHORTS");
  if (!configured) return [10, 100, 1000];
  const values = configured.split(",").map((value) => {
    assert.match(value, /^[1-9][0-9]*$/);
    const cohort = Number(value);
    assert.ok(Number.isSafeInteger(cohort) && cohort <= 1000);
    return cohort;
  });
  assert.equal(new Set(values).size, values.length);
  return values;
}
function jwt(role: string, sub?: string) {
  const header = btoa(JSON.stringify({ alg: "HS256", typ: "JWT" })).replaceAll(
    "=",
    "",
  );
  const body = btoa(
    JSON.stringify({ role, sub, exp: Math.floor(Date.now() / 1000) + 3600 }),
  ).replaceAll("=", "");
  return `${header}.${body}.${
    createHmac(
      "sha256",
      "isolated-pipeline-jwt-secret-never-used-outside-tests",
    )
      .update(`${header}.${body}`).digest("base64url")
  }`;
}
function restFor(role = "service_role", sub?: string) {
  return createSupabaseRest({
    cfg: { supabaseUrl: restUrl!, supabaseServiceRoleKey: jwt(role, sub) },
    fetchImpl: (input, init) =>
      fetch(String(input).replace("/rest/v1/", "/"), {
        ...init,
        signal: AbortSignal.timeout(15000),
      }),
  });
}
async function command(args: string[], input?: string) {
  const child = new Deno.Command("docker", {
    args,
    stdin: "piped",
    stdout: "piped",
    stderr: "piped",
  }).spawn();
  const writer = child.stdin.getWriter();
  if (input) await writer.write(new TextEncoder().encode(input));
  await writer.close();
  const result = await child.output();
  assert.equal(result.code, 0, new TextDecoder().decode(result.stderr));
  return new TextDecoder().decode(result.stdout).trim();
}
function sql(text: string, database = "postgres") {
  return command([
    "exec",
    "-i",
    container!,
    "psql",
    "-U",
    "postgres",
    "-d",
    database,
    "-X",
    "-qAt",
    "-v",
    "ON_ERROR_STOP=1",
  ], text);
}
const uuid = () => crypto.randomUUID();
const rest = restFor();
const headers = (token: string) =>
  new Headers({
    authorization: `Bearer ${token}`,
    "x-noop-fleet-token": "noop_multiuser_fleet",
  });

Deno.test({
  name:
    "fully migrated multi-user lifecycle, authorization, canonical series and restore",
  ignore: !container,
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async (t) => {
    assert.match(container!, /^nara-db-server-pipeline\.[a-z0-9]+$/);
    assert.match(restUrl!, /^http:\/\/127\.0\.0\.1:\d+$/);
    assert.equal(
      await command([
        "inspect",
        container!,
        "--format",
        '{{index .Config.Labels "nara.test"}}',
      ]),
      "server-pipeline",
    );
    for (let i = 0; i < 60; i++) {
      try {
        await rest.select("devices", "select=id&limit=1");
        break;
      } catch (e) {
        if (i === 59) throw e;
        await new Promise((r) => setTimeout(r, 250));
      }
    }
    const a = uuid(),
      b = uuid(),
      a1 = uuid(),
      a2 = uuid(),
      b1 = uuid(),
      codeA = uuid(),
      codeB = uuid();
    await sql(`insert into auth.users(id) values('${a}'),('${b}');
    insert into profiles(id,timezone) values('${a}','UTC'),('${b}','UTC') on conflict(id) do update set timezone='UTC';
    insert into noop_enrollment_codes(id,user_id,code_hash,expires_at) values
      ('${codeA}','${a}',repeat('a',64),now()+interval '1 day'),('${codeB}','${b}',repeat('b',64),now()+interval '1 day');
    insert into noop_app_installations(source_id,user_id,enrollment_code_id,platform,app_version) values
      ('${a1}','${a}','${codeA}','ios','multiuser-fixture'),('${a2}','${a}','${codeA}','android','multiuser-fixture'),
      ('${b1}','${b}','${codeB}','ios','multiuser-fixture');
    insert into noop_ingest_tokens(user_id,source_id,enrollment_code_id,token_kind,token_hash) values
      ('${a}','${a1}','${codeA}','installation',encode(sha256(convert_to('noop_multiuser_a1','UTF8')),'hex')),
      ('${a}','${a2}','${codeA}','installation',encode(sha256(convert_to('noop_multiuser_a2','UTF8')),'hex')),
      ('${b}','${b1}','${codeB}','installation',encode(sha256(convert_to('noop_multiuser_b1','UTF8')),'hex')),
      (null,null,null,'fleet',encode(sha256(convert_to('noop_multiuser_fleet','UTF8')),'hex'));`);
    const resolve = createNoopDeviceResolver({ rest });
    const band = await resolve({
      userId: a,
      sourceId: a1,
      externalDeviceId: "whoop-SYNTH001",
    });
    const replacement = await resolve({
      userId: a,
      sourceId: a1,
      externalDeviceId: "whoop-SYNTH002",
    });
    const otherBand = await resolve({
      userId: b,
      sourceId: b1,
      externalDeviceId: "whoop-SYNTH001",
    });
    await resolve({
      userId: b,
      sourceId: b1,
      externalDeviceId: "whoop-SYNTH002",
    });
    const time = Math.floor(Date.now() / 1000) - 60;
    const project = (
      user: string,
      device: string,
      source: string,
      stream: string,
      measurements: any[],
      batch = uuid(),
    ) =>
      rest.rpc("noop_project_append_batch", {
        p_user: user,
        p_device: device,
        p_source: source,
        p_batch: batch,
        p_stream: stream,
        p_rows: measurements.map((r) => ({
          ...r,
          user_id: user,
          device_id: device,
          source_id: source,
          batch_id: batch,
        })),
      });
    const lifecycle = createInstallationLifecycle(rest);
    const call = (
      token: string,
      action: "retire" | "confirm" | "handoff",
      body?: unknown,
    ) =>
      lifecycle(
        new Request("http://localhost/fixture", {
          method: "POST",
          headers: headers(token),
          body: body ? JSON.stringify(body) : undefined,
        }),
        action,
      );

    await t.step(
      "two phones, one band: equal scalar/RR replay retains both source receipts",
      async () => {
        assert.equal(
          await resolve({
            userId: a,
            sourceId: a2,
            externalDeviceId: "whoop-SYNTH001",
          }),
          band,
        );
        assert.notEqual(otherBand, band);
        assert.notEqual(replacement, band);
        for (const source of [a1, a2]) {
          assert.equal(
            await project(a, band, source, "hrSample", [{ ts: time, bpm: 60 }]),
            1,
          );
          assert.equal(
            await project(a, band, source, "rrInterval", [{
              ts: time,
              rrMs: 800,
              seq: 0,
            }, { ts: time, rrMs: 800, seq: 1 }]),
            2,
          );
        }
        assert.equal(
          await sql(
            `select count(*) from noop_hr_samples where user_id='${a}' and device_id='${band}'`,
          ),
          "1",
        );
        assert.equal(
          await sql(
            `select count(*) from noop_rr_intervals where user_id='${a}' and device_id='${band}'`,
          ),
          "2",
        );
        assert.equal(
          await sql(
            `select count(*) from noop_projection_observations where user_id='${a}'`,
          ),
          "6",
        );
        assert.equal(
          await sql(
            `select count(*) from noop_hr_samples where device_id='${replacement}'`,
          ),
          "0",
        );
      },
    );
    await t.step(
      "late supported serial evidence reconciles provisional projections and preserves raw provenance",
      async () => {
        const provisional = await resolve({
          userId: a,
          sourceId: a1,
          externalDeviceId: "local-band",
        });
        const batch = uuid();
        await project(a, provisional, a1, "hrSample", [{
          ts: time - 1,
          bpm: 61,
        }], batch);
        const request = {
          provisionalExternalDeviceId: "local-band",
          evidence: {
            method: "device_information_serial_v1",
            serial: "SYNTH001",
            receiptSha256: "c".repeat(64),
          },
        };
        const response = await call("noop_multiuser_a1", "confirm", request);
        assert.equal(response.status, 200, await response.clone().text());
        assert.equal((await response.json()).deviceId, band);
        assert.equal(
          await findNoopDevice({
            rest,
            userId: a,
            sourceId: a1,
            externalDeviceId: "local-band",
          }),
          band,
        );
        assert.equal(
          await sql(
            `select count(*) from noop_hr_samples where device_id='${provisional}'`,
          ),
          "0",
        );
        assert.equal(
          await sql(
            `select count(*) from noop_projection_observations where device_id='${provisional}'`,
          ),
          "1",
        );
        assert.equal(
          await project(
            a,
            band,
            a1,
            "hrSample",
            [{ ts: time - 1, bpm: 61 }],
            batch,
          ),
          1,
        );
        assert.equal(
          (await call("noop_multiuser_a1", "confirm", request)).status,
          200,
        );
        assert.equal(
          (await call("noop_multiuser_b1", "confirm", request)).status,
          200,
        );
        assert.equal(
          await findNoopDevice({
            rest,
            userId: a,
            sourceId: a1,
            externalDeviceId: "local-band",
          }),
          band,
        );
      },
    );
    await t.step(
      "conflicting copies are quarantined and retries cannot resurrect physiology",
      async () => {
        await project(a, band, a1, "hrSample", [{ ts: time + 1, bpm: 62 }]);
        await project(a, band, a2, "hrSample", [{ ts: time + 1, bpm: 63 }]);
        await project(a, band, a1, "hrSample", [{ ts: time + 1, bpm: 62 }]);
        assert.equal(
          await sql(
            `select count(*) from noop_hr_samples where device_id='${band}' and ts=${
              time + 1
            }`,
          ),
          "0",
        );
        assert.equal(
          await sql(
            `select count(*) from noop_projection_conflicts where device_id='${band}'`,
          ),
          "1",
        );
        const provisional = await resolve({
          userId: a,
          sourceId: a2,
          externalDeviceId: "conflicted-band",
        });
        await project(a, band, a1, "hrSample", [{ ts: time + 2, bpm: 64 }]);
        await project(a, provisional, a2, "hrSample", [{
          ts: time + 2,
          bpm: 64,
        }]);
        await project(a, provisional, a2, "hrSample", [{
          ts: time + 2,
          bpm: 65,
        }]);
        assert.equal(
          (await call("noop_multiuser_a2", "confirm", {
            provisionalExternalDeviceId: "conflicted-band",
            evidence: {
              method: "device_information_serial_v1",
              serial: "SYNTH001",
              receiptSha256: "d".repeat(64),
            },
          })).status,
          200,
        );
        await project(a, band, a1, "hrSample", [{ ts: time + 2, bpm: 64 }]);
        assert.equal(
          await sql(
            `select count(*) from noop_hr_samples where device_id='${band}' and ts=${
              time + 2
            }`,
          ),
          "0",
        );
      },
    );
    await t.step(
      "collection handoff requires the current generation",
      async () => {
        const first = await call("noop_multiuser_a1", "handoff", {
          externalDeviceId: "whoop-SYNTH001",
        });
        assert.equal(first.status, 200);
        const lease = await first.json();
        assert.equal(
          (await call("noop_multiuser_a2", "handoff", {
            externalDeviceId: "whoop-SYNTH001",
          })).status,
          409,
        );
        assert.equal(
          (await call("noop_multiuser_a2", "handoff", {
            externalDeviceId: "whoop-SYNTH001",
            expectedGeneration: lease.generation,
          })).status,
          200,
        );
        assert.equal(
          (await call("noop_multiuser_a1", "handoff", {
            externalDeviceId: "whoop-SYNTH001",
            expectedGeneration: lease.generation,
          })).status,
          409,
        );
      },
    );
    await t.step(
      "clock disagreement quarantines both scalar copies without relabeling packet provenance",
      async () => {
        const original = time - 20, corrected = original + 300;
        await project(a, band, a1, "rrInterval", [{
          ts: original,
          rrMs: 800,
          seq: 0,
        }]);
        await project(a, band, a2, "rrInterval", [{
          ts: corrected,
          rrMs: 800,
          seq: 0,
        }]);
        const packet = {
          packetId: "d".repeat(64),
          ts: original,
          sensorTs: original,
          recordIndex: 7,
          rawHex: "aa".repeat(28),
          srcChannel: 5,
          schemaVersion: 1,
          decoderVersion: "whoop5-v18-original-words-v1",
          clockVersion: "sensor-second-unmapped",
          timestampPrecisionSeconds: 1,
          clockOffsetSeconds: 0,
          declaredCount: 0,
        };
        await project(a, band, a1, "rrPacketProvenance", [packet]);
        await project(a, band, a2, "rrPacketProvenance", [{
          ...packet,
          ts: corrected,
          clockVersion: "legacy-stale-clock-snap300-v1",
          timestampPrecisionSeconds: 300,
          clockOffsetSeconds: 300,
        }]);
        await project(a, band, a2, "rrInterval", [{
          ts: corrected,
          rrMs: 800,
          seq: 0,
        }]);
        assert.equal(
          await sql(
            `select count(*) from noop_rr_intervals where device_id='${band}' and ts in(${original},${corrected})`,
          ),
          "0",
        );
        assert.equal(
          await sql(
            `select count(*) from noop_projection_observations where device_id='${band}' and stream='rrPacketProvenance'`,
          ),
          "2",
        );
      },
    );
    await t.step(
      "RR transport headers retain two receipts and one sensor packet",
      async () => {
        const oracle = JSON.parse(
          await Deno.readTextFile(
            new URL(
              "../../../android/app/src/test/resources/rr_packet_provenance_oracle.json",
              import.meta.url,
            ),
          ),
        ).cases[1];
        const frame = Uint8Array.from(
          oracle.hex.match(/../g).map((x: string) => parseInt(x, 16)),
        );
        frame[5] ^= 1;
        let crc = 0xffff;
        for (const byte of frame.slice(0, 6)) {
          crc ^= byte;
          for (let i = 0; i < 8; i++) {
            crc = (crc & 1) ? (crc >>> 1) ^ 0xa001 : crc >>> 1;
          }
        }
        frame[6] = crc & 255;
        frame[7] = crc >>> 8;
        const hex = (b: Uint8Array) =>
          Array.from(b).map((x) => x.toString(16).padStart(2, "0")).join("");
        const row = {
          packetId: oracle.packetId,
          ts: oracle.sensorTs,
          sensorTs: oracle.sensorTs,
          recordIndex: oracle.recordIndex,
          rawHex: oracle.hex,
          srcChannel: 5,
          schemaVersion: 1,
          decoderVersion: "whoop5-v18-original-words-v1",
          clockVersion: "sensor-second-unmapped",
          timestampPrecisionSeconds: 1,
          clockOffsetSeconds: 0,
          declaredCount: 3,
        };
        await project(a, band, a1, "rrPacketProvenance", [row]);
        await project(a, band, a2, "rrPacketProvenance", [{
          ...row,
          rawHex: hex(frame),
        }]);
        assert.equal(
          await sql(
            `select count(*) from noop_rr_packet_provenance where device_id='${band}' and "packetId"='${oracle.packetId}'`,
          ),
          "1",
        );
        assert.equal(
          await sql(
            `select count(distinct row_data->>'rawHex') from noop_projection_observations
        where device_id='${band}' and stream='rrPacketProvenance' and row_data->>'packetId'='${oracle.packetId}'`,
          ),
          "2",
        );
        frame[24] ^= 1;
        await project(a, band, a2, "rrPacketProvenance", [{
          ...row,
          rawHex: hex(frame),
        }]);
        assert.equal(
          await sql(
            `select count(*) from noop_rr_packet_provenance where device_id='${band}' and "packetId"='${oracle.packetId}'`,
          ),
          "0",
        );
      },
    );
    await t.step(
      "atomic admission enforces source and owner budgets and prunes only expired operational rows",
      async () => {
        await sql(
          `delete from noop_fleet_intake_usage where user_id in('${a}','${b}');
      update noop_fleet_intake_policy set source_requests_per_minute=2,user_requests_per_minute=3;`,
        );
        try {
          const admitted = await Promise.all(
            [a1, a1, a2, a2].map((s) =>
              rest.rpc("admit_noop_request", { p_user: a, p_source: s })
            ),
          );
          assert.equal(admitted.filter(Boolean).length, 3);
          assert.equal(
            await rest.rpc("admit_noop_request", { p_user: b, p_source: b1 }),
            true,
          );
          await assert.rejects(() =>
            rest.rpc("admit_noop_request", { p_user: b, p_source: a1 })
          );
          await sql(
            `insert into noop_fleet_intake_usage values('${b}','${b1}',now()-interval '3 days',1);`,
          );
          const pruned = await rest.rpc(
            "prune_multiuser_operational_records",
            {},
          );
          assert.equal(pruned.intakeRows, 1);
          assert.equal(
            await sql(
              `select sum(requests) from noop_fleet_intake_usage where user_id='${a}'`,
            ),
            "3",
          );
        } finally {
          await sql(
            "update noop_fleet_intake_policy set source_requests_per_minute=200,user_requests_per_minute=600;",
          );
        }
      },
    );
    await t.step(
      "real authenticated principals cannot read, mutate, complete or delete another owner",
      async () => {
        await project(b, otherBand, b1, "hrSample", [{ ts: time, bpm: 75 }]);
        for (const [owner, other] of [[a, b], [b, a]]) {
          const account = restFor("authenticated", owner);
          assert.ok(
            (await account.select(
              "noop_hr_samples",
              `user_id=eq.${owner}&select=bpm`,
            )).length > 0,
          );
          assert.deepEqual(
            await account.select(
              "noop_hr_samples",
              `user_id=eq.${other}&select=bpm`,
            ),
            [],
          );
          assert.deepEqual(
            await account.select(
              "noop_projection_observations",
              `user_id=eq.${other}`,
            ),
            [],
          );
          await assert.rejects(() =>
            account.rpc("noop_project_append_batch", {
              p_user: other,
              p_device: otherBand,
              p_source: b1,
              p_batch: uuid(),
              p_stream: "hrSample",
              p_rows: [],
            })
          );
          await assert.rejects(() =>
            account.delete(
              "noop_projection_observations",
              `user_id=eq.${other}`,
            )
          );
          await assert.rejects(() =>
            account.rpc("server_scoring_for_device_day", {
              p_user: other,
              p_device: otherBand,
              p_day: "2026-09-21",
            })
          );
        }
        await assert.rejects(() =>
          project(a, otherBand, a1, "hrSample", [{ ts: time, bpm: 80 }])
        );
        await sql(
          await Deno.readTextFile(
            new URL("./server_scores_rls_proof.sql", import.meta.url),
          ),
        );
        const objectId = uuid();
        const tokenId = await sql(
          `select id from noop_ingest_tokens where user_id='${a}' and source_id='${a1}'`,
        );
        const intentObjects = createPushObjects({
          rest,
          cfg: pushConfig({}),
          resolveDeviceId: async () => band,
          raw: {
            presignPut: async (_key: string, seconds: number, stamp: Date) => ({
              url: "http://127.0.0.1/synthetic-put",
              expiresAt: new Date(stamp.getTime() + seconds * 1000)
                .toISOString(),
            }),
          } as any,
        });
        const intent = await intentObjects.createIntent({
          userId: a,
          sourceId: a1,
          tokenId,
          authMode: "installation",
          manifest: {
            type: "binaryObject",
            protocolVersion: "1.2",
            stream: "ppgWaveformSample",
            deviceId: "whoop-SYNTH001",
            sourceId: a1,
            objectId,
            batchId: uuid(),
            startTs: time,
            endTs: time + 1,
            sampleCount: 1,
            compressedBytes: 28,
            uncompressedBytes: 28,
            contentSha256: "a".repeat(64),
            contentEncoding: "gzip",
          },
        });
        assert.equal(intent.status, "pending");
        assert.equal(
          await sql(
            `select auth_mode||':'||ingest_token_id from object_manifests where id='${objectId}'`,
          ),
          `installation:${tokenId}`,
        );
        assert.ok(
          Number.isFinite(
            Date.parse(
              await rest.rpc("authorize_noop_object_put", {
                p_user: a,
                p_source: a1,
                p_object: objectId,
              }),
            ),
          ),
        );
        await assert.rejects(() =>
          rest.rpc("authorize_noop_object_put", {
            p_user: b,
            p_source: b1,
            p_object: objectId,
          })
        );
        await assert.rejects(() =>
          restFor("authenticated", a).rpc("authorize_noop_object_put", {
            p_user: a,
            p_source: a1,
            p_object: objectId,
          })
        );
        let storageCalls = 0;
        const raw = new Proxy({}, {
          get: () => () => {
            storageCalls++;
            throw new Error("unauthorized object side effect");
          },
        });
        const objects = createPushObjects({
          rest,
          cfg: pushConfig({}),
          raw: raw as any,
        });
        await assert.rejects(() =>
          objects.completeObject({
            userId: b,
            sourceId: b1,
            authMode: "installation",
            objectId,
          }), /forbidden/);
        await assert.rejects(() =>
          objects.completeObject({
            userId: a,
            sourceId: a2,
            authMode: "installation",
            objectId,
          }), /forbidden/);
        assert.equal(storageCalls, 0);
        assert.equal(
          await sql(
            `select status from object_manifests where id='${objectId}'`,
          ),
          "pending",
        );
      },
    );
    await t.step(
      "A retirement is idempotent, never changes owner, and leaves A2 working",
      async () => {
        const retired = await call("noop_multiuser_a1", "retire");
        assert.equal(retired.status, 200, await retired.clone().text());
        const receipt = await retired.json();
        assert.equal(receipt.userId, a);
        assert.equal(receipt.sourceId, a1);
        const object = await sql(
          `select id from object_manifests where user_id='${a}' and source_id='${a1}' and status='pending' limit 1`,
        );
        await assert.rejects(() =>
          rest.rpc("authorize_noop_object_put", {
            p_user: a,
            p_source: a1,
            p_object: object,
          })
        );
        assert.deepEqual(
          await (await call("noop_multiuser_a1", "retire")).json(),
          receipt,
        );
        await assert.rejects(() =>
          resolveUploadIdentity({ rest, headers: headers("noop_multiuser_a1") })
        );
        assert.equal(
          (await resolveUploadIdentity({
            rest,
            headers: headers("noop_multiuser_a2"),
          })).id,
          a,
        );
        await assert.rejects(() =>
          project(a, band, a1, "hrSample", [{ ts: time + 3, bpm: 65 }])
        );
        await assert.rejects(() =>
          rest.patch(
            "noop_app_installations",
            { user_id: b },
            `source_id=eq.${a1}`,
          )
        );
        await assert.rejects(() =>
          rest.patch("noop_app_installations", {
            retired_at: null,
            retirement_id: null,
            revoked_at: null,
          }, `source_id=eq.${a1}`)
        );
        const fresh = uuid();
        await sql(
          `insert into noop_app_installations(source_id,user_id,enrollment_code_id,platform,app_version)
      values('${fresh}','${b}','${codeB}','ios','fresh-epoch');`,
        );
        await project(b, otherBand, fresh, "hrSample", [{
          ts: time + 3,
          bpm: 76,
        }]);
        assert.equal(
          await sql(
            `select user_id from noop_app_installations where source_id='${a1}'`,
          ),
          a,
        );
        assert.equal(
          await sql(
            `select count(*) from noop_hr_samples where user_id='${b}' and bpm=65`,
          ),
          "0",
        );
      },
    );
    await t.step(
      "isolated backup/restore retains retirement and provenance, tenant cascade preserves other owner",
      async () => {
        await command([
          "exec",
          container!,
          "pg_dump",
          "-U",
          "postgres",
          "-d",
          "postgres",
          "--schema=public",
          "--schema=auth",
          "--schema=internal",
          "--format=custom",
          "--file=/tmp/multiuser.dump",
        ]);
        await sql("create database multiuser_restore template template0;");
        await sql(
          'drop schema public; create schema extensions; create extension pgcrypto with schema extensions; create extension "uuid-ossp" with schema extensions;',
          "multiuser_restore",
        );
        await command([
          "exec",
          container!,
          "pg_restore",
          "-U",
          "supabase_admin",
          "--dbname=multiuser_restore",
          "--no-owner",
          "--exit-on-error",
          "/tmp/multiuser.dump",
        ]);
        await sql(
          await Deno.readTextFile(
            new URL("./server_scores_rls_proof.sql", import.meta.url),
          ),
          "multiuser_restore",
        );
        const original = await sql(
          `select count(*) from noop_projection_observations where user_id='${a}'`,
        );
        assert.equal(
          await sql(
            `select count(*) from noop_projection_observations where user_id='${a}'`,
            "multiuser_restore",
          ),
          original,
        );
        assert.equal(
          await sql(
            `select count(*) from noop_app_installations where source_id='${a1}' and retired_at is not null`,
            "multiuser_restore",
          ),
          "1",
        );
        await sql(
          `delete from auth.users where id='${a}';`,
          "multiuser_restore",
        );
        assert.equal(
          await sql(
            `select count(*) from noop_projection_observations where user_id='${a}'`,
            "multiuser_restore",
          ),
          "0",
        );
        assert.equal(
          await sql(
            `select count(*) from noop_hr_samples where user_id='${b}'`,
            "multiuser_restore",
          ),
          "2",
        );
      },
    );
    await t.step(
      "account deletion freezes admission, retries storage failures and preserves the other owner",
      async () => {
        let fail = true;
        let authDeleted = false;
        const erased: string[] = [];
        const deletion = createDeletionService({
          rest: {
            ...rest,
            adminDeleteAuthUser: async (owner) => {
              assert.equal(owner, a);
              await sql(`delete from auth.users where id='${owner}'`);
              authDeleted = true;
              return { deleted: true, missing: false };
            },
          },
          objectStore: {
            deleteObject: async (key) => {
              assert.ok(key.includes(`/users/${a}/`));
              return { deleted: true, missing: false };
            },
            listPrefix: async (prefix) => {
              assert.ok(prefix.includes(`/users/${a}/`));
              return [];
            },
            purgePrefixVersions: async (prefix) => {
              assert.ok(prefix.includes(`/users/${a}/`));
              if (fail) throw new Error("synthetic storage outage");
              erased.push(prefix);
              return { deleted: 0 };
            },
          },
        });
        assert.equal((await deletion.run(a)).status, "retry");
        assert.equal(authDeleted, false);
        await assert.rejects(() =>
          resolveUploadIdentity({ rest, headers: headers("noop_multiuser_a2") })
        );
        await sql(
          `update noop_account_retirements set requested_at=clock_timestamp()-interval '1 hour' where user_id='${a}'`,
        );
        assert.equal((await deletion.run(a)).status, "retry");
        assert.equal(authDeleted, false);
        fail = false;
        const result = await deletion.run(a);
        assert.equal(result.status, "deleted", JSON.stringify(result));
        assert.equal(authDeleted, true);
        assert.ok(erased.length >= 3);
        assert.equal(
          await sql(
            `select count(*) from noop_projection_observations where user_id='${a}'`,
          ),
          "0",
        );
        assert.equal(
          await sql(
            `select count(*) from noop_hr_samples where user_id='${b}'`,
          ),
          "2",
        );
        assert.equal(
          await sql(
            `select count(*) from noop_account_retirements where user_id='${a}'`,
          ),
          "1",
        );
      },
    );
    await Deno.mkdir(output!, { recursive: true });
    await Deno.writeTextFile(
      `${output}/multiuser-lifecycle.json`,
      JSON.stringify(
        {
          environment: "disposable Supabase Postgres/PostgREST",
          owners: 2,
          devicesPerOwner: 2,
          phonesForFirstOwner: 2,
          physicalEvidence: "NOT_MEASURED",
          objectProvider: "fixture",
          authDelete: "SQL cascade fixture",
          steps: 11,
        },
        null,
        2,
      ),
    );
    await sql(`delete from auth.users where id in('${a}','${b}');`);
  },
});

Deno.test({
  name:
    "measured concurrent fleet scheduler: live, backfill, failure, revisions and expired workers",
  ignore: !container,
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    assert.match(container!, /^nara-db-server-pipeline\.[a-z0-9]+$/);
    const report: any[] = [];
    const finish = (w: any, outcome = "done") =>
      rest.rpc("scoring_finish_work", {
        p_user: w.user_id,
        p_device: w.device_id,
        p_day: w.day,
        p_revision: w.input_revision,
        p_lease_token: w.lease_token,
        p_run_id: w.run_id,
        p_outcome: outcome,
        p_duration_ms: 3,
        p_error: outcome === "failed" ? "synthetic_retry" : null,
      });
    const claim = (seconds = 5) =>
      rest.rpc("scoring_claim_one", {
        p_lease_seconds: seconds,
        p_max_failures: 8,
      });
    for (const cohort of capacityCohorts()) {
      const seeded = JSON.parse(
        await sql(`
      create temporary table fleet_fixture as select gen_random_uuid() as u,gen_random_uuid() as d,
        gen_random_uuid() as s,gen_random_uuid() as c,n from generate_series(1,${cohort}) n;
      insert into auth.users(id) select u from fleet_fixture;
      insert into profiles(id,timezone) select u,'UTC' from fleet_fixture on conflict(id) do update set timezone='UTC';
      insert into devices(id,user_id,source_kind) select d,u,'noop_push' from fleet_fixture;
      insert into noop_enrollment_codes(id,user_id,code_hash,expires_at) select c,u,
        encode(sha256(convert_to(c::text,'UTF8')),'hex'),now()+interval '1 hour' from fleet_fixture;
      insert into noop_app_installations(source_id,user_id,enrollment_code_id,platform,app_version)
        select s,u,c,'ios','synthetic-capacity' from fleet_fixture;
      insert into noop_hr_samples(user_id,device_id,source_id,batch_id,ts,bpm)
        select u,d,s,gen_random_uuid(),extract(epoch from now())::bigint-60,60 from fleet_fixture;
      select json_agg(row_to_json(f)) from fleet_fixture f;`),
      );
      const owners = seeded.map((f: any) => `'${f.u}'`).join(",");
      const noisy = seeded[0];
      const broken = seeded[1];
      const now = Date.now();
      await sql(
        `select physiology_enqueue_day(user_id,device_id,current_date-7,'UTC',0)
      from physiology_work_items where user_id in(${owners}) and day=current_date;
      select physiology_enqueue_day('${noisy.u}','${noisy.d}',current_date-n,'UTC',0) from generate_series(8,107) n;
      update physiology_work_items set next_attempt_at=clock_timestamp() where user_id in(${owners});`,
      );
      const committedAt = Date.now();
      const [abandoned] = await claim(1);
      assert.ok(abandoned);
      await new Promise((r) => setTimeout(r, 1100));
      assert.equal(
        await finish(abandoned),
        false,
        "expired worker must fail original publication fence",
      );
      let completed = 0,
        failed = 0,
        superseded = 0,
        maxActive = 0,
        maxPerUser = 0,
        empty = 0;
      const seen = new Set<string>();
      const ownerProgress = new Set<string>();
      let liveDone = 0, backfillDone = 0;
      const latency: { live: number[]; backfill: number[] } = {
        live: [],
        backfill: [],
      };
      const dirtyLatency: { live: number[]; backfill: number[] } = {
        live: [],
        backfill: [],
      };
      const started = performance.now();
      let sampling = true;
      const resourceSamples: any[] = [];
      const sampler = (async () => {
        while (sampling) {
          const stats = await command([
            "stats",
            "--no-stream",
            "--format",
            "{{json .}}",
            container!,
          ]);
          const connections = JSON.parse(
            await sql(
              "select jsonb_build_object('total',count(*),'active',count(*) filter(where state='active')) from pg_stat_activity where backend_type='client backend'",
            ),
          );
          resourceSamples.push({
            at: new Date().toISOString(),
            database: JSON.parse(stats),
            connections,
          });
          if (sampling) await new Promise((r) => setTimeout(r, 500));
        }
      })();
      const worker = async (index: number) => {
        for (let attempt = 0; attempt < cohort * 5 + 500; attempt++) {
          const [w] = await claim();
          if (!w) {
            if (++empty > 32) return;
            await new Promise((r) => setTimeout(r, 5));
            continue;
          }
          empty = 0;
          assert.ok(!seen.has(w.lease_token));
          seen.add(w.lease_token);
          const live =
            w.day >= new Date(Date.now() - 86400000).toISOString().slice(0, 10);
          const kind = live ? "live" : "backfill";
          if (index === 0) {
            const reservations = await rest.select(
              "scoring_fleet_reservations",
              "select=user_id,device_id,day",
            );
            maxActive = Math.max(maxActive, reservations.length);
            assert.ok(reservations.length <= 4);
            const counts = new Map<string, number>(),
              devices = new Set<string>();
            for (const r of reservations) {
              counts.set(r.user_id, (counts.get(r.user_id) || 0) + 1);
              assert.ok(!devices.has(r.device_id + ":" + r.day));
              devices.add(r.device_id + ":" + r.day);
            }
            maxPerUser = Math.max(maxPerUser, ...counts.values());
            assert.ok(maxPerUser <= 2);
          }
          if (w.user_id === broken.u && failed < 8) {
            failed++;
            assert.equal(await finish(w, "failed"), true);
            await sql(
              `update physiology_work_items set next_attempt_at=clock_timestamp() where user_id='${broken.u}';`,
            );
            continue;
          }
          if (superseded === 0 && live && w.user_id !== noisy.u) {
            superseded++;
            await rest.rpc("physiology_enqueue_day", {
              p_user: w.user_id,
              p_device: w.device_id,
              p_day: w.day,
              p_timezone: "UTC",
              p_debounce_seconds: 0,
            });
            assert.equal(
              await finish(w),
              false,
              "late committed input must revoke completion",
            );
            continue;
          }
          await new Promise((r) =>
            setTimeout(r, w.user_id === noisy.u ? 20 : 3)
          );
          if (await finish(w)) {
            completed++;
            ownerProgress.add(w.user_id);
            if (live) liveDone++;
            else backfillDone++;
            latency[kind].push(
              (Date.now() - Math.max(committedAt, Date.parse(w.dirty_at))) /
                1000,
            );
            dirtyLatency[kind].push(
              (Date.now() - Date.parse(w.dirty_at)) / 1000,
            );
          }
        }
        throw new Error("bounded capacity run did not settle");
      };
      try {
        await Promise.all([0, 1, 2, 3].map(worker));
      } finally {
        sampling = false;
        await sampler;
      }
      assert.ok(liveDone >= cohort - 1 && backfillDone >= cohort - 1);
      assert.ok(
        ownerProgress.size >= cohort - 1,
        "normal users must progress despite a noisy and failed owner",
      );
      assert.equal(failed, 8);
      assert.equal(superseded, 1);
      const metrics = await rest.select("scoring_fleet_metrics", "select=*");
      const quantiles = (values: number[]) => {
        const sorted = values.sort((a, b) => a - b);
        const p = (q: number) =>
          sorted[Math.min(sorted.length - 1, Math.ceil(q * sorted.length) - 1)];
        return { count: sorted.length, p50: p(.5), p95: p(.95), p99: p(.99) };
      };
      const row = {
        cohort,
        workers: 4,
        completed,
        liveDone,
        backfillDone,
        failed,
        superseded,
        ownerProgress: ownerProgress.size,
        seconds: (performance.now() - started) / 1000,
        maxActive,
        maxPerUser,
        liveSeconds: quantiles(latency.live),
        backfillSeconds: quantiles(latency.backfill),
        originalDirtyLiveSeconds: quantiles(dirtyLatency.live),
        originalDirtyBackfillSeconds: quantiles(dirtyLatency.backfill),
        metrics,
        resourceSamples,
        localQueueLiveP95Under60Seconds: quantiles(latency.live).p95 <= 60,
        latencyOrigin:
          "after fixture enqueue transaction committed or a later invalidation; dirty-time metrics also retained",
        measurementScope:
          "PostgreSQL scheduler plus scalar invalidation, synthetic 3ms/20ms work; no physiology/model/B2 capacity claim",
        injectedAt: new Date(now).toISOString(),
      };
      report.push(row);
      console.log(JSON.stringify(row));
      await Deno.mkdir(output!, { recursive: true });
      await Deno.writeTextFile(
        `${output}/fleet-capacity.json`,
        JSON.stringify(report, null, 2),
      );
      await sql(`delete from auth.users where id in(${owners});`);
    }
  },
});
