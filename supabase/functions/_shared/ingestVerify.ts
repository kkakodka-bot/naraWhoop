// Slim ingest-verify report: push receipts, manifest statuses, B2 presence, projection rows.
// Deliberately omits diagnoseDay / replay accounting / persistSidecars (Node-only engine deps).

import type { SupabaseRest } from './rest.ts';
import type { S3Store } from './s3.ts';
import { isUuid } from './keys.ts';

const PROJECTION_TABLES = [
  { table: 'daily_metrics', dayColumn: 'day' },
  { table: 'sessions', dayColumn: null },
  { table: 'noop_journal_entries', dayColumn: 'day' },
] as const;

const PHYSIOLOGY_VERSION = 'frwhoop-physiology-2';
const WORK_STATUS = ['pending', 'running', 'waiting', 'retry', 'exhausted', 'done'] as const;
const WORK_LIMIT = 1000;
// Eight bounded 120-second jobs plus the largest supported 10-minute poll delay fit here.
// This is a liveness diagnostic, not a five-minute upload or calculation SLA.
const HEARTBEAT_STALE_SECONDS = 30 * 60;

function timestamp(value: unknown): string | null {
  return typeof value === 'string' && Number.isFinite(Date.parse(value)) ? value : null;
}

async function physiologyProcessing(rest: SupabaseRest, userId: string, day: string, now: Date) {
  const reads = await Promise.allSettled([
    rest.select('physiology_service_heartbeats',
      'id=eq.1&select=version,last_poll_at,last_score_at,last_error&limit=1'),
    rest.select('physiology_work_items',
      `user_id=eq.${userId}&day=eq.${day}&select=status,lease_expires_at&order=device_id&limit=${WORK_LIMIT}`),
    // This is the same owner-scoped selection used by both clients. Only availability/counts
    // leave this function; physiological values, identities, payloads and errors do not.
    rest.rpc('server_scoring_for_day', { p_user: userId, p_day: day }),
  ]);
  const [heartbeatRead, workRead, snapshotRead] = reads;
  const heartbeat = heartbeatRead.status === 'fulfilled' ? heartbeatRead.value[0] : null;
  const lastPoll = timestamp(heartbeat?.last_poll_at);
  const pollAgeSeconds = lastPoll ? (now.getTime() - Date.parse(lastPoll)) / 1000 : null;
  const workerStatus = heartbeatRead.status === 'rejected' ? 'query_failed'
    : !heartbeat ? 'missing'
    : heartbeat.version !== PHYSIOLOGY_VERSION ? 'version_mismatch'
    : heartbeat.last_poll_at == null ? 'never_polled'
    : pollAgeSeconds == null || pollAgeSeconds < -60 ? 'invalid_heartbeat_time'
    : pollAgeSeconds > HEARTBEAT_STALE_SECONDS ? 'stale' : 'healthy';

  const rows: any[] = workRead.status === 'fulfilled' ? workRead.value.slice(0, WORK_LIMIT) : [];
  const counts = Object.fromEntries([...WORK_STATUS, 'unknown'].map((status) => [status, 0]));
  let expiredLeases = 0;
  for (const row of rows) {
    const key = WORK_STATUS.includes(row.status) ? row.status : 'unknown';
    counts[key]++;
    if (row.status === 'running' && (!timestamp(row.lease_expires_at) || Date.parse(row.lease_expires_at) <= now.getTime())) expiredLeases++;
  }
  const truncated = rows.length >= WORK_LIMIT;
  const snapshot = snapshotRead.status === 'fulfilled' ? snapshotRead.value : null;
  const snapshotOk = typeof snapshot?.user_id === 'string' && snapshot.user_id.toLowerCase() === userId.toLowerCase() &&
    snapshot?.day === day && snapshot?.schema_version === 2 &&
    snapshot.features != null && typeof snapshot.features === 'object' && !Array.isArray(snapshot.features);
  const features = Object.fromEntries(['sleep', 'hrv', 'respiration'].map((key) => {
    const feature = snapshotOk ? snapshot.features[key] : null;
    const selected = feature?.algorithm_version === PHYSIOLOGY_VERSION;
    const computed = timestamp(feature?.computed_at);
    const published = selected && feature?.input_revision != null && computed != null;
    const status = !snapshotOk || !feature || !['available', 'stale', 'unavailable'].includes(feature.status) ? 'diagnostics_unavailable'
      : !selected ? 'different_or_unavailable_selection'
      : !published ? 'awaiting_result'
      : feature.status === 'stale' ? 'published_stale'
      : feature.status === 'unavailable' ? 'published_unavailable' : 'published';
    return [key, { status, computed_at: computed }];
  }));
  const featureStates = Object.values(features).map((feature) => feature.status);
  const publicationStatus = !snapshotOk ? 'diagnostics_unavailable'
    : featureStates.every((status) => status.startsWith('published'))
    ? featureStates.includes('published_stale') ? 'published_stale' : 'published'
    : featureStates.some((status) => status.startsWith('published')) ? 'partially_published'
    : featureStates.includes('awaiting_result') ? 'awaiting_result' : 'selection_unavailable';
  const measurements: any[] = snapshotOk && Array.isArray(snapshot.measurements) ? snapshot.measurements : [];
  const hrv = measurements.filter((row) => row?.feature === 'hrv');
  const nights: any[] = snapshotOk && Array.isArray(snapshot.nights) ? snapshot.nights : [];
  const daily = snapshotOk ? snapshot.daily : null;
  const hasFiniteValue = (value: unknown) => typeof value === 'number' && Number.isFinite(value);
  const published = (key: string) => features[key].status.startsWith('published');
  const readsOk = reads.every((read) => read.status === 'fulfilled') && snapshotOk && !truncated && counts.unknown === 0 &&
    !featureStates.includes('diagnostics_unavailable');
  const pending = counts.pending + counts.running + counts.waiting + counts.retry + counts.exhausted;
  const complete = readsOk && pending === 0 && featureStates.every((status) => status === 'published' || status === 'published_unavailable');
  const status = !readsOk ? 'diagnostics_unavailable'
    : workerStatus !== 'healthy' ? `worker_${workerStatus}`
    : counts.exhausted > 0 ? 'retry_exhausted'
    : expiredLeases > 0 ? 'expired_lease'
    : counts.running > 0 ? 'running'
    : counts.retry > 0 ? 'retrying'
    : counts.pending > 0 ? 'queued'
    : counts.waiting > 0 ? 'waiting_for_inputs' : publicationStatus;

  return {
    algorithm_version: PHYSIOLOGY_VERSION,
    scope: 'requested_user_day',
    status,
    processing_complete: complete,
    // Independent REST reads may straddle an input revision; repeat when state changes.
    observation_is_atomic: false,
    worker: {
      scope: 'shared_worker',
      status: workerStatus,
      last_poll_at: lastPoll,
      last_score_at: timestamp(heartbeat?.last_score_at),
      error_present: Boolean(heartbeat?.last_error),
      stale_after_seconds: HEARTBEAT_STALE_SECONDS,
    },
    work: { query_ok: workRead.status === 'fulfilled', items_examined: rows.length, counts_truncated: truncated,
      status_counts: counts, expired_running_leases: expiredLeases },
    publication: { status: publicationStatus, features },
    measurement_availability: {
      hrv: published('hrv') ? { windows: hrv.length, valid_windows: hrv.filter((row) => row.measurement_valid === true).length,
        unavailable_windows: hrv.filter((row) => row.measurement_valid === false).length } : null,
      sleep: published('sleep') ? { episodes: nights.length,
        measured_episodes: nights.filter((row) => row.measurement_available === true).length } : null,
      respiration_summary_available: published('respiration') ? hasFiniteValue(daily?.resp_rate_bpm) : null,
      spo2_summary_available: published('hrv') ? hasFiniteValue(daily?.spo2_pct) : null,
    },
  };
}

export type IngestVerifyStage =
  | 'push_receipt'
  | 'manifest_ready'
  | 'receipt_verified'
  | 'signal_index'
  | 'projection_debt'
  | 'auxiliary_validation'
  | 'b2_object'
  | 'projection_row';

export async function buildIngestVerifyReport({
  rest,
  objectStore,
  userId,
  day,
  now = new Date(),
}: {
  rest: SupabaseRest;
  objectStore: Pick<S3Store, 'head'> | null;
  userId: string;
  day: string;
  now?: Date;
}) {
  if (!isUuid(userId)) throw Object.assign(new Error('user required'), { code: 'unauthorized' });
  if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) {
    throw Object.assign(new Error('invalid day'), { code: 'invalid_day' });
  }

  const [walRows, ackRows, manifestRows, windows, dailyRows, heartbeatRows, projectionDebt, physiology] = await Promise.all([
    rest.select(
      'noop_push_wal',
      `user_id=eq.${userId}&select=batch_id,stream,device_id,record_count,body_sha256,received_at&order=received_at.desc&limit=200`,
    ).catch(() => []),
    rest.select(
      'noop_push_acks',
      `user_id=eq.${userId}&select=batch_id,body_sha256,saved_at&order=saved_at.desc&limit=200`,
    ).catch(() => []),
    rest.select(
      'object_manifests',
      `user_id=eq.${userId}&period_day=eq.${day}&select=id,object_key,status,object_class,object_kind,push_protocol_version,format,compressed_bytes,sha256,sha256_source,durability_receipt,indexed_at,created_at,updated_at&order=created_at.asc`,
    ).catch(() => []),
    rest.select('noop_signal_windows', `user_id=eq.${userId}&select=object_id,object_key`).catch(() => []),
    rest.select(
      'daily_metrics',
      `user_id=eq.${userId}&day=eq.${day}&select=day,computed_at,algorithm_version,provenance&limit=1`,
    ).catch(() => []),
    rest.select(
      'scoring_service_heartbeats',
      'id=eq.1&select=version,started_at,last_poll_at,last_score_at,last_error&limit=1',
    ).catch(() => []),
    rest.select('noop_projection_debt', `user_id=eq.${userId}&select=object_id,state,failures,not_before&limit=2000`).catch(() => []),
    physiologyProcessing(rest, userId, day, now),
  ]);

  const manifests = (manifestRows as any[]).map((m) => ({
    id: m.id,
    object_key: m.object_key,
    status: m.status,
    object_kind: m.object_kind,
    push_protocol_version: m.push_protocol_version,
    format: m.format,
    object_class: m.object_class ?? 'raw',
    durability_receipt: m.durability_receipt ?? null,
    indexed_at: m.indexed_at ?? null,
    sha256_source: m.sha256_source ?? null,
    compressed_bytes: m.compressed_bytes ?? null,
    sha256: m.sha256 ?? null,
    created_at: m.created_at,
    updated_at: m.updated_at,
  }));
  const auxiliaryObjects = manifests.filter((m) => m.object_kind === 'v18AuxSample' && m.push_protocol_version === '1.4' && m.status !== 'deleted');
  const auxiliaryValidation = auxiliaryObjects.length ? await rest.select('noop_aux_object_validation',
    `user_id=eq.${userId}&select=object_id,state,validation&limit=2000`).catch(() => []) : [];

  const b2Presence: Record<string, { exists: boolean; contentLength: number | null }> = {};
  if (objectStore) {
    for (const m of manifests) {
      if (!m.object_key) continue;
      try {
        const head = await objectStore.head(m.object_key);
        b2Presence[m.object_key] = {
          exists: Boolean(head?.exists),
          contentLength: head?.contentLength ?? null,
        };
      } catch {
        b2Presence[m.object_key] = { exists: false, contentLength: null };
      }
    }
  }

  const manifestStatuses = manifests.reduce<Record<string, number>>((acc, m) => {
    const s = String(m.status || 'unknown');
    acc[s] = (acc[s] || 0) + 1;
    return acc;
  }, {});

  const projections: Record<string, { present: boolean; count: number }> = {};
  for (const { table, dayColumn } of PROJECTION_TABLES) {
    try {
      const query = dayColumn
        ? `user_id=eq.${userId}&${dayColumn}=eq.${day}&select=${dayColumn}&limit=5`
        : `user_id=eq.${userId}&select=id&limit=5`;
      const rows = await rest.select(table, query);
      const count = Array.isArray(rows) ? rows.length : 0;
      projections[table] = { present: count > 0, count };
    } catch {
      projections[table] = { present: false, count: 0 };
    }
  }

  const pushReceipts = {
    wal_batches: (walRows as any[]).length,
    ack_batches: (ackRows as any[]).length,
    newest_wal_at: (walRows as any[])[0]?.received_at ?? null,
    newest_ack_at: (ackRows as any[])[0]?.saved_at ?? null,
    unacked_estimate: Math.max(0, (walRows as any[]).length - (ackRows as any[]).length),
  };

  const firstIncompleteStage = ((): IngestVerifyStage | null => {
    if (pushReceipts.ack_batches === 0 && !manifests.some((m) => m.durability_receipt?.state === 'verified_indexed')) return 'push_receipt';
    if (!manifests.length) return 'manifest_ready';
    const pendingManifest = manifests.find((m) => !['ready', 'verified', 'deleted'].includes(String(m.status)));
    if (pendingManifest) return 'manifest_ready';
    const raw = manifests.filter((m) => m.object_class === 'raw' && m.status !== 'deleted');
    if (raw.some((m) => m.sha256_source !== 'server_verified' ||
      m.durability_receipt?.version !== 1 || m.durability_receipt?.state !== 'verified_indexed' ||
      m.durability_receipt?.ownerUserId !== userId || m.durability_receipt?.objectId !== m.id ||
      m.durability_receipt?.objectKey !== m.object_key)) return 'receipt_verified';
    if (raw.some((m) => !m.indexed_at || !windows.some((w: any) => w.object_id === m.id && w.object_key === m.object_key))) return 'signal_index';
    const missingB2 = manifests.some((m) => {
      const hit = b2Presence[m.object_key];
      return m.object_key && (!hit || !hit.exists);
    });
    if (missingB2) return 'b2_object';
    if (auxiliaryObjects.some((m) => !auxiliaryValidation.some((v: any) => v.object_id === m.id && v.state === 'validated'))) return 'auxiliary_validation';
    if (raw.some((m) => String(m.format).startsWith('ndjson') &&
      !projectionDebt.some((d: any) => d.object_id === m.id && d.state === 'complete'))) return 'projection_debt';
    if (!projections.daily_metrics?.present) return 'projection_row';
    return null;
  })();

  const heartbeat = (heartbeatRows as any[])[0] ?? null;

  return {
    user_id: userId,
    day,
    push_receipts: pushReceipts,
    manifest_statuses: manifestStatuses,
    manifests,
    b2_presence: b2Presence,
    projections,
    projection_debt: projectionDebt.filter((d: any) => manifests.some((m) => m.id === d.object_id)),
    auxiliary_validation: auxiliaryValidation.filter((v: any) => auxiliaryObjects.some((m) => m.id === v.object_id)),
    daily_metrics_row: (dailyRows as any[])[0] ?? null,
    scoring_service_heartbeat: heartbeat
      ? {
        version: heartbeat.version ?? null,
        started_at: heartbeat.started_at ?? null,
        last_poll_at: heartbeat.last_poll_at ?? null,
        last_score_at: heartbeat.last_score_at ?? null,
        last_error: heartbeat.last_error ?? null,
      }
      : null,
    physiology_processing: physiology,
    first_incomplete_stage: firstIncompleteStage,
    complete_scope: 'ingestion_only',
    complete: firstIncompleteStage === null,
  };
}
