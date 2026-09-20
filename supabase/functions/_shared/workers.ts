
// Scheduled-worker ports for the backend retirement (Phase 2). These mirror the Node
// implementations in the retired Node receiver,deletion,retention}.js so the Edge functions
// preserve semantics exactly — including ordering (B2 → rows → Auth, never Auth first) and
// resumability (deletion_jobs status machine). Metrics counters (`inc`) are Node-process
// facilities and are not ported.
import type { SupabaseRest } from './rest.ts';
import type { S3Store } from './s3.ts';
import { allUserPrefixes, isUuid } from './keys.ts';

const STALE_PENDING_MS = 60 * 60 * 1000;

/** NPB1 digests cover decoded content; append and derived digests cover stored bytes. */
async function checksumBytes(row: any, bytes: Uint8Array): Promise<Uint8Array> {
  if (row.object_class === 'raw' && row.format === 'ndjson_gzip_noop_push_v1' && row.compression === 'gzip') return bytes;
  const rawFormats = ['bin_gzip_noop_push_v1', 'bin_zstd_noop_push_v1', 'protobuf_zstd_noop_push_v1'];
  if (rawFormats.includes(row.format)) {
    // zstd decoding belongs to the bounded JVM verifier, never hash its compressed bytes as raw content.
    if (row.compression !== 'gzip') throw new Error('raw_decoder_unavailable');
    const limit = Number(row.uncompressed_bytes);
    if (!Number.isSafeInteger(limit) || limit <= 0 || limit > 64 * 1024 * 1024) throw new Error('raw_size_limit');
    const stream = new Blob([new Uint8Array(bytes)]).stream().pipeThrough(new DecompressionStream('gzip'));
    const reader = stream.getReader(); const chunks: Uint8Array[] = []; let length = 0;
    try {
      while (true) {
        const { value, done } = await reader.read(); if (done) break;
        length += value.length;
        if (length > limit) throw new Error('raw_decoded_size_mismatch');
        chunks.push(value);
      }
    } finally { await reader.cancel().catch(() => {}); }
    if (length !== limit) throw new Error('raw_decoded_size_mismatch');
    const decoded = new Uint8Array(length); let offset = 0;
    for (const chunk of chunks) { decoded.set(chunk, offset); offset += chunk.length; }
    return decoded;
  }
  if (row.object_class === 'derived' && ['json_zstd_frwhoop_derived_v1', 'json_zstd_frwhoop_derived_v2'].includes(row.format)) return bytes;
  throw new Error('digest_contract_unknown');
}
export const DELETION_STEPS = [
  'record_job', 'list_manifests', 'delete_b2_versions', 'delete_supabase_rows',
  'delete_auth_user', 'complete',
] as const;

export const DELETION_TABLES = [
  'noop_rr_packet_provenance',
  'noop_standard_hr_receipts',
  'physiology_buckets', 'daily_physiology_series', 'ingest_gaps', 'measurements',
  'sleep_details', 'events', 'sessions', 'daily_metrics', 'metric_runs', 'object_manifests',
  'sensor_objects', 'derived_objects', 'live_windows', 'sleep_nights', 'coach_messages',
  'coach_sessions', 'coach_memories', 'user_documents', 'algorithm_results', 'user_settings',
  'integration_connections', 'user_sync_state', 'devices', 'profiles',
] as const;

/** Port of the retired Node receiver sweepExpiredManifests. */
export async function sweepExpiredManifests({
  rest,
  objectStore,
  now = () => new Date(),
}: {
  rest: SupabaseRest;
  objectStore: S3Store;
  now?: () => Date;
}) {
  if (!rest?.configured || !objectStore) return { deleted: 0 };
  const iso = now().toISOString();
  const rows = await rest.select(
    'object_manifests',
    `status=in.(ready,verified,expired)&expires_at=lte.${encodeURIComponent(iso)}&select=id,object_key,status`,
  );
  let deleted = 0;
  for (const row of rows || []) {
    try {
      await objectStore.deleteObject(row.object_key);
      await rest.request(`object_manifests?id=eq.${row.id}`, {
        method: 'PATCH',
        body: { status: 'deleted' },
      });
      deleted += 1;
    } catch {
      await rest.request(`object_manifests?id=eq.${row.id}`, {
        method: 'PATCH',
        body: { status: 'failed' },
      }).catch(() => {});
    }
  }
  return { deleted };
}

/** Port of the retired Node receiver reconcileObjects. */
export async function reconcileObjects({
  rest,
  objectStore,
  now = () => new Date(),
  userId,
  verifyChecksums = false,
  listPrefix,
}: {
  rest: SupabaseRest;
  objectStore: Pick<S3Store, 'head' | 'getObject'>;
  now?: () => Date;
  userId?: string;
  verifyChecksums?: boolean;
  listPrefix?: (prefix: string) => Promise<string[]>;
}) {
  const report = {
    pending_missing_object: 0, ready_missing_object: 0, orphan_objects: 0,
    checksum_mismatch: 0, size_mismatch: 0, stale_pending: 0,
    marked_failed: 0, marked_ready: 0, listed_objects: 0, index_missing_objects: 0, checksum_unverified: 0,
  };

  const query = userId ? `user_id=eq.${userId}&select=*` : 'select=*&limit=5000';
  const manifests = await rest.select('object_manifests', query);
  const byKey = new Map(manifests.map((m: any) => [m.object_key, m]));
  const staleBefore = new Date(now().getTime() - STALE_PENDING_MS).toISOString();

  for (const row of manifests as any[]) {
    if (row.status === 'deleted' || row.status === 'deleting') continue;
    let head: any = null;
    try { head = await objectStore.head(row.object_key); } catch { head = null; }
    const exists = Boolean(head?.exists);

    if (['pending', 'uploading', 'uploaded'].includes(row.status)) {
      if (row.created_at && row.created_at < staleBefore && !exists) {
        report.stale_pending += 1; report.pending_missing_object += 1;
        await rest.request(`object_manifests?id=eq.${row.id}`, { method: 'PATCH', body: { status: 'failed' } });
        report.marked_failed += 1;
        continue;
      }
      if (!exists) { report.pending_missing_object += 1; continue; }
      if (row.compressed_bytes != null && head.contentLength != null &&
          Number(head.contentLength) !== Number(row.compressed_bytes)) {
        report.size_mismatch += 1;
        await rest.request(`object_manifests?id=eq.${row.id}`, { method: 'PATCH', body: { status: 'failed' } });
        report.marked_failed += 1;
        continue;
      }
      if (verifyChecksums && row.sha256 && objectStore.getObject) {
        let actual: string | null = null;
        try {
          const obj = await objectStore.getObject(row.object_key);
          if (obj?.body) {
            const buf = obj.body instanceof Uint8Array ? obj.body : new Uint8Array(obj.body);
            const hash = await crypto.subtle.digest('SHA-256', new Uint8Array(await checksumBytes(row, buf)));
            actual = [...new Uint8Array(hash)].map((b) => b.toString(16).padStart(2, '0')).join('');
          }
        } catch { actual = null; }
        if (actual == null) {
          report.checksum_unverified += 1;
          // An unsupported decoder or failed GET is not a digest match or corruption proof.
          continue;
        }
        if (actual != null && actual !== row.sha256) {
          report.checksum_mismatch += 1;
          await rest.request(`object_manifests?id=eq.${row.id}`, {
            method: 'PATCH', body: { status: 'corrupt', verified_at: now().toISOString() },
          });
          report.marked_failed += 1;
          continue;
        }
      }
      await rest.request(`object_manifests?id=eq.${row.id}`, {
        method: 'PATCH',
        body: { status: 'ready', verified_at: now().toISOString(), uploaded_at: now().toISOString(), etag: head.etag || row.etag },
      });
      report.marked_ready += 1;
      continue;
    }

    if (['ready', 'verified'].includes(row.status) && !exists) {
      report.ready_missing_object += 1;
      await rest.request(`object_manifests?id=eq.${row.id}`, { method: 'PATCH', body: { status: 'corrupt' } });
      report.marked_failed += 1;
    }
  }

  if (typeof listPrefix === 'function') {
    const prefixes = userId
      ? [
          `v3/core/users/${userId}/`, `v3/imu/users/${userId}/`,
          `v3/derived/users/${userId}/`,
          `v2/users/${userId}/`, `v1/users/${userId}/`,
        ]
      : ['v3/core/', 'v3/imu/', 'v3/derived/', 'v2/', 'v1/'];
    const seen = new Set<string>();
    for (const prefix of prefixes) {
      let keys: string[] = [];
      try { keys = await listPrefix(prefix); } catch { keys = []; }
      for (const key of keys) {
        if (!key || seen.has(key)) continue;
        seen.add(key);
        report.listed_objects += 1;
        if (!byKey.has(key)) report.orphan_objects += 1;
      }
    }
    for (const row of manifests as any[]) {
      if (!['ready', 'verified'].includes(row.status) || !row.object_key) continue;
      if (/^v[123]\//.test(row.object_key) && !seen.has(row.object_key)) report.index_missing_objects += 1;
    }
  }
  return report;
}

/** Port of the retired Node receiver createDeletionService (resumable; B2 → rows → Auth). */
export function createDeletionService({
  rest,
  objectStore,
  now = () => new Date(),
  uuid,
}: {
  rest: SupabaseRest;
  objectStore: Pick<S3Store, 'deleteObject' | 'listPrefix'>;
  now?: () => Date;
  uuid?: () => string;
}) {
  async function loadJob(userId: string) {
    const rows = await rest.select(
      'deletion_jobs',
      `user_id=eq.${userId}&status=in.(pending,running,blocked)&order=created_at.desc&limit=1`,
    );
    return (rows as any[] | undefined)?.[0] || null;
  }

  async function saveJob(job: any) {
    return rest.upsert('deletion_jobs', job, { onConflict: 'id' });
  }

  async function run(userId: string, { existing }: { existing?: any } = {}) {
    if (!isUuid(userId)) throw new Error('user id must be a uuid');
    const job = existing || (await loadJob(userId)) || {
      id: uuid ? uuid() : crypto.randomUUID(),
      user_id: userId,
      status: 'running',
      step: 'record_job',
      state: { failures: [], deleted_keys: [] },
      created_at: now().toISOString(),
      updated_at: now().toISOString(),
    };
    job.status = 'running';
    job.updated_at = now().toISOString();
    await saveJob(job);

    try {
      job.step = 'list_manifests';
      const manifests = (await rest.select('object_manifests', `user_id=eq.${userId}&select=id,object_key,status`)) as any[];
      job.state.manifest_ids = manifests.map((m) => m.id);
      job.state.object_keys = [...new Set(manifests.map((m) => m.object_key).filter(Boolean))];
      await saveJob(job);

      job.step = 'delete_b2_versions';
      const failures: { key?: string; prefix?: string }[] = [];
      for (const key of job.state.object_keys || []) {
        try { await objectStore.deleteObject(key); } catch { failures.push({ key }); }
      }
      for (const prefix of allUserPrefixes(userId)) {
        try {
          const leftover = await objectStore.listPrefix(prefix);
          for (const key of leftover) {
            try { await objectStore.deleteObject(key); } catch { failures.push({ key }); }
          }
        } catch { failures.push({ prefix }); }
      }
      job.state.failures = failures;
      if (failures.length) {
        job.status = 'blocked'; job.updated_at = now().toISOString();
        await saveJob(job);
        return { status: 'retry', remaining: failures.length, job_id: job.id };
      }
      await saveJob(job);

      job.step = 'delete_supabase_rows';
      for (const table of DELETION_TABLES) {
        try {
          const col = table === 'profiles' ? 'id' : 'user_id';
          await rest.delete(table, `${col}=eq.${userId}`);
        } catch { /* table may not exist in older environments */ }
      }
      try {
        await rest.request(`integration_credentials?user_id=eq.${userId}`, { method: 'DELETE', schema: 'internal' });
      } catch { /* schema-qualified */ }
      await saveJob(job);

      job.step = 'delete_auth_user';
      await rest.adminDeleteAuthUser(userId);

      job.step = 'complete';
      job.status = 'complete';
      job.completed_at = now().toISOString();
      job.updated_at = now().toISOString();
      await saveJob(job);
      return { status: 'deleted', job_id: job.id };
    } catch (err: any) {
      job.status = 'blocked';
      job.state = { ...(job.state || {}), error: String(err?.message || err).slice(0, 200) };
      job.updated_at = now().toISOString();
      await saveJob(job);
      return { status: 'retry', job_id: job.id, error: job.state.error };
    }
  }

  return { run, loadJob, steps: DELETION_STEPS };
}
