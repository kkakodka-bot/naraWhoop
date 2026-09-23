import assert from 'node:assert/strict';
import { createHash, createHmac } from 'node:crypto';
import { basename, dirname, join } from 'node:path';
import { createSupabaseRest } from '../_shared/rest.ts';
import { handleScoresRequest } from '../_shared/serverScores.ts';
import { createPushArchive, createPushIngest } from '../_shared/ingest.ts';
import { createPushWalStore } from '../_shared/wal.ts';
import { commitArchivedBatch } from '../_shared/projections.ts';
import { createNoopDeviceResolver } from '../_shared/devices.ts';
import { createUploadReceiptStore } from '../_shared/receipts.ts';
import { resolveUploadIdentity } from '../_shared/tokens.ts';
import { pushConfig } from '../_shared/config.ts';
import { startObjectHttp } from './local_objects.ts';

// Explicit opt-in private replay. The input is a read-only exported scalar recording,
// not original mobile wire bytes. Never check recordings, patient values or envelopes in.
const recordingPath = Deno.env.get('PIPELINE_TEST_REAL_RECORDING');
const container = Deno.env.get('PIPELINE_TEST_DATABASE_CONTAINER');
const output = Deno.env.get('PIPELINE_TEST_OUTPUT');
const hash = (value: string | Uint8Array) => createHash('sha256').update(value).digest('hex');

async function regularBytes(filename: string, maximumBytes: number): Promise<Uint8Array> {
  const stat = await Deno.lstat(filename);
  assert.ok(stat.isFile && !stat.isSymlink && stat.size <= maximumBytes);
  return await Deno.readFile(filename);
}

async function baselineDistribution(binary: string) {
  const executable = await Deno.realPath(binary);
  assert.equal(executable, binary, 'baseline executable must use its canonical path');
  const root = dirname(dirname(executable));
  assert.equal(dirname(executable), join(root, 'bin'));
  const files: { path: string; sizeBytes: number; sha256: string }[] = [];
  for (const directory of ['bin', 'lib']) {
    for await (const entry of Deno.readDir(join(root, directory))) {
      assert.ok(entry.isFile && !entry.isSymlink, 'baseline distribution must contain regular files');
      const bytes = await regularBytes(join(root, directory, entry.name), 128 * 1024 * 1024);
      files.push({ path: `${directory}/${entry.name}`, sizeBytes: bytes.length, sha256: hash(bytes) });
    }
  }
  files.sort((a, b) => a.path < b.path ? -1 : a.path > b.path ? 1 : 0);
  assert.ok(files.some(file => file.path === `bin/${basename(binary)}`));
  assert.ok(files.some(file => file.path.startsWith('lib/') && file.path.endsWith('.jar')));
  return { files, sha256: hash(JSON.stringify(files)) };
}

async function sql(statement: string): Promise<string> {
  const child = new Deno.Command('docker', { args: ['exec', '-i', container!, 'psql', '-U', 'postgres',
    '-d', 'postgres', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1'], stdin: 'piped', stdout: 'piped', stderr: 'piped' }).spawn();
  const writer = child.stdin.getWriter(); await writer.write(new TextEncoder().encode(statement)); await writer.close();
  const result = await child.output();
  assert.equal(result.code, 0, 'private recording SQL failed; inspect private database log');
  return new TextDecoder().decode(result.stdout).trim();
}

Deno.test({ name: 'private real scalar recording -> durable local intake -> frozen baseline -> authenticated native contract',
  ignore: !recordingPath, sanitizeOps: false, sanitizeResources: false, fn: async () => {
  assert.match(container!, /^nara-db-server-pipeline\.[a-z0-9]+$/);
  const restUrl = Deno.env.get('PIPELINE_TEST_REST_URL')!;
  const authUrl = Deno.env.get('PIPELINE_TEST_AUTH_URL')!;
  const databaseUrl = Deno.env.get('PIPELINE_TEST_DATABASE_URL')!;
  for (const address of [restUrl, authUrl]) assert.match(address, /^http:\/\/127\.0\.0\.1:\d+$/);
  assert.match(databaseUrl, /^postgresql:\/\/supabase_admin:isolated-pipeline-only@127\.0\.0\.1:\d+\/postgres$/);
  const inspection = await new Deno.Command('docker', { args: ['inspect', container!, '--format',
    '{{index .Config.Labels "nara.test"}}'] }).output();
  assert.equal(new TextDecoder().decode(inspection.stdout).trim(), 'server-pipeline');
  assert.ok(output);
  const stat = await Deno.lstat(recordingPath!);
  assert.ok(stat.isFile && !stat.isSymlink && stat.size <= 64 * 1024 * 1024);
  assert.equal((stat.mode ?? 0) & 0o077, 0, 'recording must remain private');
  const recordingBytes = await Deno.readFile(recordingPath!);
  const recording = JSON.parse(new TextDecoder().decode(recordingBytes));
  const exportReceiptBytes = await regularBytes(Deno.env.get('PIPELINE_TEST_RECORDING_PROVENANCE')!, 1024 * 1024);
  const exportReceipt = JSON.parse(new TextDecoder().decode(exportReceiptBytes));
  assert.equal(exportReceipt.schemaVersion, 1);
  assert.equal(exportReceipt.sourceRecordingSha256, hash(recordingBytes));
  assert.equal(exportReceipt.productionMutation, false);
  assert.equal(exportReceipt.readOnlyTransaction, true);
  assert.equal(exportReceipt.tlsMode, 'verify-full');
  for (const field of ['exporterSha256', 'sourceScopeReceiptSha256', 'exportReceiptSha256', 'tlsReceiptSha256']) {
    assert.match(exportReceipt[field], /^[0-9a-f]{64}$/);
  }
  assert.equal(recording.schemaVersion, 1);
  assert.equal(recording.sourceKind, 'actual_hosted_scalar_projection_subset');
  assert.equal(recording.bounds.semantics, 'frozen_v1_UserDayBounds_exact_inclusive');
  assert.match(recording.day, /^\d{4}-\d{2}-\d{2}$/);
  assert.equal(recording.bounds.nightLo, recording.bounds.dayLo - 30 * 3600);
  assert.equal(recording.bounds.nightHi, recording.bounds.dayLo + 12 * 3600);
  assert.equal(typeof recording.profile.timezone, 'string');
  for (const key of ['hr', 'gravity', 'events']) {
    assert.ok(Array.isArray(recording[key]) && recording[key].length <= (key === 'events' ? 10_000 : 151_201));
    let previous = Number.NEGATIVE_INFINITY;
    for (const row of recording[key]) {
      assert.ok(Number.isSafeInteger(row.ts) && row.ts >= recording.bounds.nightLo && row.ts <= recording.bounds.nightHi);
      assert.ok(row.ts >= previous); previous = row.ts;
    }
  }
  assert.ok(recording.hr.length > 0 && recording.gravity.length > 0);
  const baselineBinary = Deno.env.get('PIPELINE_TEST_V1_BINARY')!;
  const workerSource = Deno.env.get('PIPELINE_TEST_V1_SOURCE_REVISION')!;
  assert.ok(baselineBinary); assert.match(workerSource, /^[0-9a-f]{40}$/);
  const distribution = await baselineDistribution(baselineBinary);
  const buildProvenanceBytes = await regularBytes(Deno.env.get('PIPELINE_TEST_V1_PROVENANCE')!, 1024 * 1024);
  const buildProvenance = JSON.parse(new TextDecoder().decode(buildProvenanceBytes));
  assert.equal(buildProvenance.algorithm_version, 'frwhoop-server-1');
  assert.equal(buildProvenance.canonical_math_changed, false);
  assert.equal(buildProvenance.build_status, 'built_and_repository_tests_passed');
  assert.equal(buildProvenance.baseline_commit, '5caa31689da0023e111beb36850d3f81d67e1be2');
  assert.equal(buildProvenance.frozen_files_sha256, 'd081ce1f0686271660b7239b35a012088c834fb3c8cd48f7e9d16b4b8f84b085');
  assert.equal(buildProvenance.baseline_result_mapper_sha256, '360580662c058579b9e9842853552d568d2a99357f67fa84b7a2f2df985f18d4');
  const testFileSha256 = hash(await Deno.readFile(new URL(import.meta.url)));
  await Deno.mkdir(output!, { recursive: true, mode: 0o700 });
  await Deno.writeTextFile(`${output}/baseline-distribution-receipt.json`, JSON.stringify({
    schemaVersion: 1, workerSourceRevision: workerSource, distribution,
    buildProvenanceSha256: hash(buildProvenanceBytes),
  }, null, 2), { mode: 0o600 });
  await Deno.writeFile(`${output}/source-export-provenance.json`, exportReceiptBytes, { mode: 0o600 });
  const jwtBody = btoa(JSON.stringify({ role: 'service_role', exp: Math.floor(Date.now() / 1000) + 3600 })).replaceAll('=', '');
  const jwtHeader = btoa(JSON.stringify({ alg: 'HS256', typ: 'JWT' })).replaceAll('=', '');
  const token = `${jwtHeader}.${jwtBody}.${createHmac('sha256', 'isolated-pipeline-jwt-secret-never-used-outside-tests')
    .update(`${jwtHeader}.${jwtBody}`).digest('base64url')}`;
  const rest = createSupabaseRest({ cfg: { supabaseUrl: restUrl, supabaseServiceRoleKey: token },
    fetchImpl: (input, init) => fetch(String(input).replace('/rest/v1/', '/'), { ...init, signal: AbortSignal.timeout(30_000) }) });
  for (let attempt = 0; attempt < 60; attempt++) {
    try {
      await rest.select('devices', 'select=id&limit=1');
      const ready = await fetch(`${authUrl}/health`); await ready.body?.cancel();
      if (!ready.ok) throw new Error('auth_pending'); break;
    } catch (error) { if (attempt === 59) throw error; await new Promise(resolve => setTimeout(resolve, 250)); }
  }
  const signup = await fetch(`${authUrl}/signup`, { method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ email: 'private-recording@example.test', password: 'isolated-test-password-never-production' }) });
  assert.equal(signup.status, 200);
  const session = await signup.json(); const owner = session.user.id;
  const source = crypto.randomUUID(); const enrollment = crypto.randomUUID(); const externalDevice = 'whoop-REALREPLAY';
  assert.match(owner, /^[0-9a-f-]{36}$/);
  await rest.upsert('profiles', { id: owner, ...recording.profile }, { onConflict: 'id' });
  await sql(`insert into noop_enrollment_codes(id,user_id,code_hash,expires_at)
    values('${enrollment}','${owner}',repeat('c',64),now()+interval '1 day');
    insert into noop_app_installations(source_id,user_id,enrollment_code_id,platform,app_version)
    values('${source}','${owner}','${enrollment}','ios','private-scalar-replay');
    insert into noop_ingest_tokens(user_id,token_hash,token_kind,source_id,enrollment_code_id) values
    ('${owner}',encode(sha256(convert_to('noop_private_replay','UTF8')),'hex'),'installation','${source}','${enrollment}'),
    (null,encode(sha256(convert_to('noop_private_fleet','UTF8')),'hex'),'fleet',null,null);`);
  const cfg = { supabaseUrl: restUrl, supabaseAnonKey: 'isolated-test-public' };
  const installationHeaders = { authorization: 'Bearer noop_private_replay', 'x-noop-fleet-token': 'noop_private_fleet' };
  const registered = await handleScoresRequest(new Request('http://localhost/functions/v1/scores/devices', {
    method: 'POST', headers: { ...installationHeaders, 'content-type': 'application/json' },
    body: JSON.stringify({ deviceId: externalDevice }),
  }), { rest, cfg });
  assert.equal(registered.status, 200); const identity = (await registered.json()).identity;
  await rest.request('devices', { method: 'PATCH', query: `id=eq.${identity.deviceId}`,
    body: { device_family: recording.device.deviceFamily } });
  const observedBounds = JSON.parse(await sql(`select jsonb_build_object(
    'lo',extract(epoch from ('${recording.day}'::date::timestamp at time zone timezone))::bigint,
    'hi',extract(epoch from (('${recording.day}'::date+1)::timestamp at time zone timezone))::bigint)
    from profiles where id='${owner}';`));
  assert.equal(observedBounds.lo, recording.bounds.dayLo); assert.equal(observedBounds.hi, recording.bounds.dayHi + 1);
  const objectServer = startObjectHttp({ versioned: true, chunkBytes: 8192 });
  const archive = createPushArchive({ cfg: pushConfig({ B2_KEY_ID: 'fixture', B2_APPLICATION_KEY: 'fixture', B2_BUCKET: 'fixture', RAW_STORE: 'b2' }),
    rest, raw: objectServer.raw });
  const intake = createPushIngest({ walStore: createPushWalStore({ rest })!, archiveObject: archive.archiveObject,
    resolveDeviceId: createNoopDeviceResolver({ rest }), receiptStore: createUploadReceiptStore({ rest }),
    commitProjection: (receipt, bytes) => commitArchivedBatch(rest, receipt, bytes) });
  const receiptHashes: string[] = [];
  try {
    for (const [name, stream, table] of [['hr', 'hrSample', 'noop_hr_samples'],
      ['gravity', 'gravitySample', 'noop_gravity_samples'], ['events', 'event', 'noop_events']]) {
      const rows = recording[name];
      for (let offset = 0; offset < rows.length; offset += 1000) {
        const batch = crypto.randomUUID(); const slice = rows.slice(offset, offset + 1000);
        const records = slice.map((row: any) => ({ type: 'record', key: name === 'events' ? { ts: row.ts, kind: row.kind } : { ts: row.ts },
          data: name === 'hr' ? { bpm: row.bpm } : name === 'gravity' ? { x: row.x, y: row.y, z: row.z } : { payloadJSON: row.payloadJSON } }));
        const header = { type: 'batch', protocolVersion: '1.1', stream, deviceId: externalDevice, sourceId: source,
          batchId: batch, endCursor: { ts: slice.at(-1).ts }, delivery: 'append', recordCount: records.length };
        const bytes = new TextEncoder().encode([header, ...records].map(value => JSON.stringify(value)).join('\n') + '\n');
        const upload = await resolveUploadIdentity({ rest, headers: new Headers(installationHeaders) });
        assert.equal(upload.id, owner); assert.equal(upload.sourceId, source);
        assert.equal(await rest.rpc('admit_noop_request', { p_user: owner, p_source: source }), true);
        const args = { userId: owner, sourceId: source, tokenId: upload.tokenId, authMode: upload.authMode, decodedBody: bytes };
        const ack = await intake.acceptBatch(args);
        assert.equal(ack.acceptedRows, records.length); assert.equal(ack.durabilityReceipt.state, 'verified_indexed');
        assert.equal(ack.durabilityReceipt.contentSha256, hash(bytes));
        receiptHashes.push(hash(JSON.stringify(ack.durabilityReceipt)));
        assert.equal(await sql(`select state from noop_projection_debt where object_id='${batch}';`), 'complete');
        assert.equal(await sql(`select sha256_source from object_manifests where id='${batch}';`), 'server_verified');
        if (offset === 0) assert.equal(hash(JSON.stringify(await intake.acceptBatch(args))), hash(JSON.stringify(ack)));
      }
      assert.equal(Number(await sql(`select count(*) from ${table} where user_id='${owner}' and device_id='${identity.deviceId}';`)), rows.length);
    }
    assert.equal(await sql(`select status from scoring_work_items where user_id='${owner}' and device_id='${identity.deviceId}'
      and day='${recording.day}';`), 'pending', 'actual scalar projections must enqueue the selected worker');
    const child = new Deno.Command(baselineBinary, { args: ['--replay-day'], clearEnv: true, env: {
      PATH: Deno.env.get('PATH')!, JAVA_HOME: Deno.env.get('JAVA_HOME')!, DATABASE_URL: databaseUrl,
      SUPABASE_URL: restUrl, SUPABASE_SERVICE_ROLE_KEY: token, INGEST_SECRET: 'isolated-pipeline-only',
      SCORING_WORKER_SOURCE_REVISION: workerSource, SCORING_WORKER_INSTANCE_ID: crypto.randomUUID(),
      SCORING_ALGORITHM_VERSION: 'frwhoop-server-1', REPLAY_USER_ID: owner, REPLAY_DEVICE_ID: identity.deviceId, REPLAY_DAY: recording.day,
    }, stdout: 'piped', stderr: 'piped' }).spawn();
    const timeout = setTimeout(() => { try { child.kill('SIGTERM'); } catch { /* Completed. */ } }, 300_000);
    const result = await child.output(); clearTimeout(timeout);
    await Deno.writeFile(`${output}/private-worker.log`, new Uint8Array([...result.stdout, ...result.stderr]), { mode: 0o600 });
    assert.equal(result.code, 0, 'real recording worker failed; inspect private-worker.log');
    const publication = JSON.parse(await sql(`select jsonb_build_object('revision',input_revision,'hash',payload_hash,'payload',payload)
      from server_physiology_results where user_id='${owner}' and device_id='${identity.deviceId}' and period_day='${recording.day}'
      and algorithm_version='frwhoop-server-1' order by input_revision desc limit 1;`));
    const daily = publication.payload.daily;
    assert.ok(typeof daily.sleep_total_min === 'number' && daily.sleep_total_min > 0, 'real input must produce supported sleep');
    assert.ok(typeof daily.resting_hr_bpm === 'number' && daily.resting_hr_bpm > 0, 'real input must produce resting HR');
    const url = `http://localhost/functions/v1/scores?day=${recording.day}&deviceId=${externalDevice}`;
    const enrolled = await handleScoresRequest(new Request(url, { headers: installationHeaders }), { rest, cfg });
    const account = await handleScoresRequest(new Request(url, { headers: { authorization: `Bearer ${session.access_token}`,
      'x-noop-source-id': source } }), { rest, cfg, fetchImpl: (input, init) => {
      assert.equal(String(input), `${restUrl}/auth/v1/user`); return fetch(`${authUrl}/user`, init);
    } });
    assert.equal(enrolled.status, 200); assert.equal(account.status, 200);
    const enrolledBytes = await enrolled.text(); const accountBytes = await account.text();
    const score = JSON.parse(enrolledBytes).server_scoring;
    assert.equal(hash(JSON.stringify(score)), hash(JSON.stringify(JSON.parse(accountBytes).server_scoring)));
    assert.equal(score.algorithm_version, 'frwhoop-server-1');
    for (const metric of ['sleep_total_min', 'resting_hr_bpm']) assert.equal(score.daily[metric], daily[metric]);
    for (const metric of ['hrv_rmssd_ms', 'hrv_sdnn_ms', 'resp_rate_bpm', 'spo2_pct']) assert.equal(score.daily[metric] ?? null, null);
    assert.equal(score.compute.families.sleep.canonical_qualification, 'retained_legacy');
    assert.equal(score.compute.families.sleep.result_revision, `sha256:${publication.hash}`);
    assert.equal(Number(await sql("select count(*) from physiology_feature_qualifications where qualification='reference_qualified';")), 0);
    const availableFeatures = ['sleep', 'hrv', 'respiration'].filter(key => ['available', 'stale'].includes(score.features[key].status));
    const expectation = { ownerId: owner, day: recording.day, availableFeatures,
      unavailableFeatures: ['sleep', 'hrv', 'respiration'].filter(key => !availableFeatures.includes(key)), expectedDeviceId: identity.deviceId,
      nestedHrvAvailable: false, nestedRespirationAvailable: false, allowedNestedFields: ['resting_hr_bpm', 'overnight_hr_bpm'],
      expectedValues: { sleep: daily.sleep_total_min }, expectedCanonicalValues: {
        sleep_total_min: daily.sleep_total_min, sleep_efficiency: score.compute.families.sleep.values.sleep_efficiency,
        resting_hr_bpm: daily.resting_hr_bpm } };
    await Deno.writeTextFile(`${output}/real-enrolled.json`, enrolledBytes, { mode: 0o600 });
    await Deno.writeTextFile(`${output}/real-account.json`, accountBytes, { mode: 0o600 });
    await Deno.writeTextFile(`${output}/expectations.json`, JSON.stringify(['real-enrolled.json', 'real-account.json']
      .map(file => ({ ...expectation, file }))), { mode: 0o600 });
    await Deno.writeTextFile(`${output}/real_recording_input_to_result_trace.sanitized.json`, JSON.stringify({
      schemaVersion: 1, evidenceKind: 'actual_scalar_recording_private_local_replay', sourceRecordingSha256: hash(recordingBytes),
      sourceExportProvenanceSha256: hash(exportReceiptBytes), testFileSha256,
      workerDistributionSha256: distribution.sha256, workerBuildProvenanceSha256: hash(buildProvenanceBytes),
      testSourceRevision: Deno.env.get('PIPELINE_TEST_SOURCE_SHA'), workerSourceRevision: workerSource,
      sourceWorktreeClean: Deno.env.get('PIPELINE_TEST_SOURCE_CLEAN') === 'true', sourceReceipt: '../source-receipt.json',
      inputCounts: { hr: recording.hr.length, gravity: recording.gravity.length, events: recording.events.length, rr: 0, respiration: 0 },
      inputScope: 'same_historical_phone_owner_source_device_exact_frozen_baseline_42h_window',
      acquisition: 'original_scalar_projection_timestamps_and_values_preserved; not_original_mobile_bytes',
      gaps: 'preserved_without_interpolation', profile: 'actual_nullable_fields_and_timezone; baseline_defaults_unchanged',
      firmware: 'current_catalog_not_historical_qualification', identity: 'new_local_pseudonyms_and_batch_ids',
      transport: 'local_NDJSON_WAL_signed_loopback_S3_streamed_byte_verification_atomic_projection',
      receiptCount: receiptHashes.length, receiptSetSha256: hash(JSON.stringify(receiptHashes)),
      queue: 'scoring_work_items_created_by_actual_projection', execution: 'explicit_baseline_replay_day',
      algorithm: 'frwhoop-server-1', qualification: 'retained_legacy', referenceApprovalRows: 0,
      outputMetrics: ['sleep_total_min', 'resting_hr_bpm'], outputValues: 'PRIVATE_NOT_PUBLISHED',
      immutablePayloadSha256: publication.hash, enrolledEnvelopeSha256: hash(enrolledBytes), accountEnvelopeSha256: hash(accountBytes),
      accountAuth: 'real_disposable_GoTrue_issued_and_verified', nativeDecoderEvidence: 'runner_mobile_log_required',
      productionMutation: false, physicalPhoneReadback: 'NOT_MEASURED', hostedB2Acceptance: 'NOT_MEASURED',
    }, null, 2), { mode: 0o600 });
  } finally { await objectServer.close(); }
} });
