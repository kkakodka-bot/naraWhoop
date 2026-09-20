import { assertEquals, assert } from 'jsr:@std/assert';
import { makeMemRest } from './helpers.ts';
import { buildIngestVerifyReport } from '../_shared/ingestVerify.ts';
import { authorizeWorkerRequest } from '../_shared/workerAuth.ts';

const USER = '7f2c9a10-4b3e-4d8a-9c11-00000000f001';
const DAY = '2026-09-10';

Deno.test('ingest-verify auth: fails closed without WORKER_SECRET or service-role bearer', () => {
  const prev = Deno.env.get('WORKER_SECRET');
  Deno.env.delete('WORKER_SECRET');
  assertEquals(
    authorizeWorkerRequest(new Request('https://x'), { supabaseServiceRoleKey: '' }),
    false,
  );
  if (prev) Deno.env.set('WORKER_SECRET', prev);
});

Deno.test('ingest-verify: reports first incomplete stage from receipts through projection', async () => {
  const rest = makeMemRest();
  await rest.upsert('noop_push_wal', {
    user_id: USER,
    batch_id: 'batch-1',
    stream: 'hrSample',
    device_id: 'dev',
    record_count: 2,
    body_sha256: 'a'.repeat(64),
    received_at: '2026-09-10T12:00:00.000Z',
  });
  await rest.upsert('noop_push_acks', {
    user_id: USER,
    batch_id: 'batch-1',
    body_sha256: 'a'.repeat(64),
    ack: { status: 'accepted' },
    saved_at: '2026-09-10T12:00:01.000Z',
  });
  await rest.upsert('object_manifests', {
    id: 'obj-1',
    user_id: USER,
    period_day: DAY,
    object_key: 'v3/core/users/u/raw/x',
    status: 'ready',
    object_kind: 'rawBatch',
    sha256_source: 'server_verified', indexed_at: '2026-09-10T12:00:01Z',
    durability_receipt: { version: 1, state: 'verified_indexed', ownerUserId: USER, objectId: 'obj-1', objectKey: 'v3/core/users/u/raw/x' },
  });
  await rest.upsert('noop_signal_windows', { user_id: USER, object_id: 'obj-1', object_key: 'v3/core/users/u/raw/x' });
  await rest.upsert('daily_metrics', {
    user_id: USER,
    day: DAY,
    computed_at: '2026-09-10T13:00:00.000Z',
    algorithm_version: 'noop-client',
    provenance: { source: 'noop_push' },
  });

  const report = await buildIngestVerifyReport({
    rest: rest as any,
    objectStore: {
      async head(key: string) {
        return { exists: key === 'v3/core/users/u/raw/x', contentLength: 128 };
      },
    },
    userId: USER,
    day: DAY,
  });

  assertEquals(report.complete, true);
  assertEquals(report.first_incomplete_stage, null);
  assertEquals(report.complete_scope, 'ingestion_only');
  assertEquals(report.push_receipts.ack_batches, 1);
  assertEquals(report.manifest_statuses.ready, 1);
  assert(report.b2_presence['v3/core/users/u/raw/x']?.exists);
  assert(report.projections.daily_metrics.present);
});

Deno.test('ingest-verify: missing B2 object surfaces b2_object stage', async () => {
  const rest = makeMemRest();
  await rest.upsert('noop_push_acks', {
    user_id: USER,
    batch_id: 'batch-2',
    body_sha256: 'b'.repeat(64),
    ack: { status: 'accepted' },
    saved_at: '2026-09-10T12:00:01.000Z',
  });
  await rest.upsert('object_manifests', {
    id: 'obj-2',
    user_id: USER,
    period_day: DAY,
    object_key: 'missing-key',
    status: 'ready',
    object_kind: 'rawBatch',
    sha256_source: 'server_verified', indexed_at: '2026-09-10T12:00:01Z',
    durability_receipt: { version: 1, state: 'verified_indexed', ownerUserId: USER, objectId: 'obj-2', objectKey: 'missing-key' },
  });
  await rest.upsert('noop_signal_windows', { user_id: USER, object_id: 'obj-2', object_key: 'missing-key' });

  const report = await buildIngestVerifyReport({
    rest: rest as any,
    objectStore: { async head() { return { exists: false, contentLength: null }; } },
    userId: USER,
    day: DAY,
  });

  assertEquals(report.first_incomplete_stage, 'b2_object');
  assertEquals(report.complete, false);
});

const NOW = new Date('2026-09-10T13:00:00Z');
const PHYSIOLOGY = 'frwhoop-physiology-2';
const PRIVATE_DEVICE = '11111111-1111-4111-8111-111111111111';

function snapshot({ published = false, unavailable = false, stale = false } = {}) {
  return {
    schema_version: 2, user_id: USER, day: DAY,
    features: Object.fromEntries(['sleep', 'hrv', 'respiration'].map((key) => [key, {
      device_id: PRIVATE_DEVICE, algorithm_version: PHYSIOLOGY,
      status: stale ? 'stale' : published ? unavailable ? 'unavailable' : 'available' : 'unavailable',
      input_revision: published ? 10 : null, required_revision: stale ? 11 : 10,
      computed_at: published ? '2026-09-10T12:59:00Z' : null,
      reason: published ? null : 'awaiting_result',
    }])),
    daily: published ? { resp_rate_bpm: null, spo2_pct: null, private_health_payload: 'never-return-this' } : null,
    measurements: published ? [{ feature: 'hrv', measurement_valid: false, device_id: PRIVATE_DEVICE,
      original_ids: ['private-beat-identity'], reason: 'no_observations' }] : [],
    nights: [],
  };
}

async function physiologyFixture({ worker = { version: PHYSIOLOGY, last_poll_at: '2026-09-10T12:59:59Z',
  last_score_at: null, last_error: null } as any, work = [] as any[], result = snapshot() as any,
  failedRead = '' } = {}) {
  const memory = makeMemRest();
  await memory.upsert('noop_push_acks', { user_id: USER, batch_id: 'receipt', saved_at: NOW.toISOString() });
  await memory.upsert('daily_metrics', { user_id: USER, day: DAY });
  // A live legacy worker must not mask a dead v2 worker.
  await memory.upsert('scoring_service_heartbeats', { id: 1, version: 'frwhoop-server-1', last_poll_at: NOW.toISOString() });
  const requests: Array<{ table: string; query: string }> = [];
  const rest = {
    ...memory,
    async select(table: string, query = '') {
      requests.push({ table, query });
      if (table === failedRead) throw new Error(`private-error-${PRIVATE_DEVICE}`);
      if (table === 'physiology_service_heartbeats') return worker ? [worker] : [];
      if (table === 'physiology_work_items') {
        const scope = new URLSearchParams(query);
        assertEquals(scope.get('user_id'), `eq.${USER}`);
        assertEquals(scope.get('day'), `eq.${DAY}`);
        assertEquals(scope.get('select'), 'status,lease_expires_at');
        return work;
      }
      return memory.select(table, query);
    },
    async rpc(name: string, args: unknown) {
      assertEquals(name, 'server_scoring_for_day');
      assertEquals(args, { p_user: USER, p_day: DAY });
      if (name === failedRead) throw new Error(`private-error-${PRIVATE_DEVICE}`);
      return result;
    },
  };
  const report = await buildIngestVerifyReport({ rest: rest as any, objectStore: null, userId: USER, day: DAY, now: NOW });
  return { report, requests };
}

Deno.test('ingest-verify: successful ingestion cannot hide a v2 worker that never polled', async () => {
  const { report, requests } = await physiologyFixture({
    worker: { version: PHYSIOLOGY, last_poll_at: null, last_score_at: '2026-09-09T12:00:00Z', last_error: PRIVATE_DEVICE },
    work: [{ status: 'pending', lease_expires_at: null }],
  });
  assertEquals(report.complete, true);
  assertEquals(report.first_incomplete_stage, null);
  assertEquals(report.physiology_processing.status, 'worker_never_polled');
  assertEquals(report.physiology_processing.processing_complete, false);
  assertEquals(report.physiology_processing.worker.error_present, true);
  assertEquals(report.physiology_processing.work.status_counts.pending, 1);
  assertEquals(report.physiology_processing.publication.status, 'awaiting_result');
  assertEquals(report.physiology_processing.measurement_availability.hrv, null);
  assert(requests.some((request) => request.table === 'physiology_service_heartbeats'));
  assert(!JSON.stringify(report.physiology_processing).includes(PRIVATE_DEVICE));
});

Deno.test('ingest-verify: worker liveness is separate from queue and publication state', async () => {
  for (const [worker, expected] of [
    [null, 'missing'],
    [{ version: PHYSIOLOGY, last_poll_at: '2026-09-10T12:00:00Z' }, 'stale'],
    [{ version: 'frwhoop-server-1', last_poll_at: NOW.toISOString() }, 'version_mismatch'],
    [{ version: PHYSIOLOGY, last_poll_at: 'not-a-date' }, 'invalid_heartbeat_time'],
    [{ version: PHYSIOLOGY, last_poll_at: '2026-09-11T12:00:00Z' }, 'invalid_heartbeat_time'],
  ] as const) {
    const { report } = await physiologyFixture({ worker });
    assertEquals(report.physiology_processing.worker.status, expected);
    assertEquals(report.physiology_processing.status, `worker_${expected}`);
  }
  for (const [state, expected] of [
    ['pending', 'queued'], ['running', 'running'], ['retry', 'retrying'],
    ['exhausted', 'retry_exhausted'], ['waiting', 'waiting_for_inputs'],
  ]) {
    const { report } = await physiologyFixture({ work: [{ status: state, lease_expires_at: '2026-09-10T13:01:00Z' }] });
    assertEquals(report.physiology_processing.status, expected);
    assertEquals(report.physiology_processing.work.status_counts[state], 1);
    assertEquals(report.physiology_processing.processing_complete, false);
  }
  const { report } = await physiologyFixture({ work: [{ status: 'running', lease_expires_at: '2026-09-10T12:59:59Z' }] });
  assertEquals(report.physiology_processing.status, 'expired_lease');
  assertEquals(report.physiology_processing.work.expired_running_leases, 1);
});

Deno.test('ingest-verify: published unavailable measurements are completed processing, not missing results', async () => {
  for (const unavailable of [false, true]) {
    const { report } = await physiologyFixture({ work: [{ status: 'done' }], result: snapshot({ published: true, unavailable }) });
    const processing = report.physiology_processing;
    assertEquals(processing.status, 'published');
    assertEquals(processing.processing_complete, true);
    assertEquals(processing.publication.features.hrv.status, unavailable ? 'published_unavailable' : 'published');
    assertEquals(processing.measurement_availability.hrv, { windows: 1, valid_windows: 0, unavailable_windows: 1 });
    assertEquals(processing.measurement_availability.sleep, { episodes: 0, measured_episodes: 0 });
    assertEquals(processing.measurement_availability.respiration_summary_available, false);
    assertEquals(processing.measurement_availability.spo2_summary_available, false);
    const sanitized = JSON.stringify(processing);
    for (const secret of [USER, PRIVATE_DEVICE, 'never-return-this', 'private-beat-identity', 'no_observations']) assert(!sanitized.includes(secret));
  }
});

Deno.test('ingest-verify: stale publication remains visible while newer work is queued', async () => {
  const result = snapshot({ published: true, stale: true });
  result.measurements[0].measurement_valid = true;
  result.daily!.resp_rate_bpm = 12 as any;
  result.daily!.spo2_pct = 97 as any;
  const { report } = await physiologyFixture({ result, work: [{ status: 'pending' }] });
  assertEquals(report.physiology_processing.status, 'queued');
  assertEquals(report.physiology_processing.publication.status, 'published_stale');
  assertEquals(report.physiology_processing.processing_complete, false);
  assertEquals(report.physiology_processing.measurement_availability.hrv?.valid_windows, 1);
  assertEquals(report.physiology_processing.measurement_availability.respiration_summary_available, true);
  assertEquals(report.physiology_processing.measurement_availability.spo2_summary_available, true);
});

Deno.test('ingest-verify: failed, incomplete, wrong-owner, or truncated diagnostics never become healthy', async () => {
  for (const failedRead of ['physiology_service_heartbeats', 'physiology_work_items', 'server_scoring_for_day']) {
    const { report } = await physiologyFixture({ failedRead, result: snapshot({ published: true }) });
    assertEquals(report.complete, true);
    assertEquals(report.physiology_processing.status, 'diagnostics_unavailable');
    assertEquals(report.physiology_processing.processing_complete, false);
    assert(!JSON.stringify(report.physiology_processing).includes('private-error'));
  }
  for (const result of [{}, { ...snapshot({ published: true }), features: {} },
    { ...snapshot({ published: true }), user_id: PRIVATE_DEVICE },
    { ...snapshot({ published: true }), day: '2026-09-09' }]) {
    const { report } = await physiologyFixture({ result });
    assertEquals(report.physiology_processing.status, 'diagnostics_unavailable');
    assertEquals(report.physiology_processing.processing_complete, false);
  }
  const { report } = await physiologyFixture({ work: Array.from({ length: 1000 }, () => ({ status: 'done' })),
    result: snapshot({ published: true }) });
  assertEquals(report.physiology_processing.work.counts_truncated, true);
  assertEquals(report.physiology_processing.processing_complete, false);
  assertEquals(report.physiology_processing.status, 'diagnostics_unavailable');
});

Deno.test('ingest-verify: a ready flag and HEAD are not a receipt or an index', async () => {
  const rest = makeMemRest();
  await rest.upsert('noop_push_acks', { user_id: USER, batch_id: 'batch', saved_at: '2026-09-10T12:00:01Z' });
  await rest.upsert('daily_metrics', { user_id: USER, day: DAY });
  await rest.upsert('object_manifests', { id: 'object', user_id: USER, period_day: DAY, object_key: 'key', status: 'ready' });
  const args = { rest: rest as any, objectStore: { async head() { return { exists: true, contentLength: 128 }; } }, userId: USER, day: DAY };
  assertEquals((await buildIngestVerifyReport(args)).first_incomplete_stage, 'receipt_verified');
  await rest.upsert('object_manifests', { id: 'object', sha256_source: 'server_verified', indexed_at: '2026-09-10T12:00:01Z',
    durability_receipt: { version: 1, state: 'verified_indexed', ownerUserId: USER, objectId: 'object', objectKey: 'key' } });
  assertEquals((await buildIngestVerifyReport(args)).first_incomplete_stage, 'signal_index');
  await rest.upsert('noop_signal_windows', { user_id: USER, object_id: 'object', object_key: 'key' });
  assertEquals((await buildIngestVerifyReport(args)).complete, true);
  await rest.upsert('object_manifests', { id: 'object', format: 'ndjson_gzip_noop_push_v1' });
  assertEquals((await buildIngestVerifyReport(args)).first_incomplete_stage, 'projection_debt');
  await rest.upsert('noop_projection_debt', { user_id: USER, object_id: 'object', state: 'pending' }, { onConflict: 'object_id' });
  assertEquals((await buildIngestVerifyReport(args)).first_incomplete_stage, 'projection_debt');
  await rest.upsert('noop_projection_debt', { user_id: USER, object_id: 'object', state: 'staged' }, { onConflict: 'object_id' });
  assertEquals((await buildIngestVerifyReport(args)).complete, false);
  await rest.upsert('noop_projection_debt', { user_id: USER, object_id: 'object', state: 'complete' }, { onConflict: 'object_id' });
  assertEquals((await buildIngestVerifyReport(args)).complete, true);
});
