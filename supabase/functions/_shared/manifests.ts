// Port of the retired Node receiver — object_manifests store + the idempotent completion helper.
import type { SupabaseRest } from './rest.ts';

export const READY_STATUSES = new Set(['verified', 'ready']);

export function createManifestStore({ rest, now = () => new Date() }: { rest: SupabaseRest; now?: () => Date }) {
  async function insertPending(row: Record<string, unknown>) {
    const body = {
      ...row,
      status: row.status || 'pending',
      created_at: now().toISOString(),
    };
    const saved = await rest.upsert('object_manifests', body, { onConflict: 'id' });
    return Array.isArray(saved) ? saved[0] : saved;
  }

  async function mark(id: string, patch: Record<string, unknown>) {
    return rest.request(`object_manifests?id=eq.${id}`, {
      method: 'PATCH',
      body: { ...patch, updated_at: now().toISOString() },
      prefer: 'return=representation',
    });
  }

  async function get(id: string) {
    const rows = await rest.select('object_manifests', `id=eq.${id}&select=*`);
    return rows[0] || null;
  }

  async function byKey(objectKey: string) {
    const rows = await rest.select(
      'object_manifests',
      `object_key=eq.${encodeURIComponent(objectKey)}&select=*`,
    );
    return rows[0] || null;
  }

  async function byUserBatch(userId: string, batchId: string) {
    const rows = await rest.select(
      'object_manifests',
      `user_id=eq.${userId}&batch_id=eq.${batchId}&select=*`,
    );
    return rows[0] || null;
  }

  async function listByUser(userId: string, extra = '') {
    const q = [`user_id=eq.${userId}`, 'select=*', extra].filter(Boolean).join('&');
    return rest.select('object_manifests', q);
  }

  async function listPendingStale(beforeIso: string) {
    return rest.select(
      'object_manifests',
      `status=in.(pending,uploading,uploaded)&created_at=lt.${beforeIso}&select=*`,
    );
  }

  async function listReady(userId: string) {
    return rest.select(
      'object_manifests',
      `user_id=eq.${userId}&status=in.(ready,verified)&select=*`,
    );
  }

  return { insertPending, mark, get, byKey, byUserBatch, listByUser, listPendingStale, listReady };
}

export type ManifestStore = ReturnType<typeof createManifestStore>;

/**
 * pending → uploading → uploaded → verified/ready.
 * Idempotent: a second complete with the same id does not duplicate.
 */
export async function completeUpload({
  manifests,
  objectStore,
  objectId,
  expectedBytes,
  expectedSha256,
  now = () => new Date(),
}: {
  manifests: ManifestStore;
  objectStore: { head(key: string): Promise<{ exists: boolean; contentLength: number | null } | null>; getObject?(key: string): Promise<any> };
  objectId: string;
  expectedBytes?: number;
  expectedSha256?: string;
  now?: () => Date;
}) {
  const row = await manifests.get(objectId);
  if (!row) return { ok: false, error: 'missing_manifest' };
  if (READY_STATUSES.has(row.status)) return { ok: true, row, duplicate: true };
  await manifests.mark(objectId, { status: 'uploading' });
  const head = await objectStore.head(row.object_key);
  if (!head?.exists) {
    await manifests.mark(objectId, { status: 'failed' });
    return { ok: false, error: 'object_missing', row };
  }
  const bytes = head.contentLength;
  const wantBytes = expectedBytes ?? row.compressed_bytes;
  if (wantBytes != null && bytes != null && Number(bytes) !== Number(wantBytes)) {
    await manifests.mark(objectId, { status: 'failed' });
    return { ok: false, error: 'size_mismatch', row };
  }
  const etag = (head as any).etag || null;
  let sha = expectedSha256 || row.sha256 || null;
  if (!sha) {
    const obj = objectStore.getObject ? await objectStore.getObject(row.object_key) : null;
    if (!obj?.body) {
      await manifests.mark(objectId, { status: 'corrupt' });
      return { ok: false, error: 'object_missing', row };
    }
    const { sha256Hex } = await import('./s3.ts');
    sha = sha256Hex(obj.body);
    if (expectedBytes != null && obj.body.length !== Number(expectedBytes)) {
      await manifests.mark(objectId, { status: 'failed' });
      return { ok: false, error: 'size_mismatch', row };
    }
  }
  const verifiedAt = now().toISOString();
  const updated = await manifests.mark(objectId, {
    status: 'ready',
    sha256: sha,
    etag,
    compressed_bytes: bytes ?? wantBytes,
    uploaded_at: verifiedAt,
    verified_at: verifiedAt,
  });
  const next = Array.isArray(updated) ? updated[0] : updated;
  return { ok: true, row: next, duplicate: false };
}
