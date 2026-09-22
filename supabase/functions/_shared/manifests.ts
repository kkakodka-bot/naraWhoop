// Manifest lookup helpers. Raw writes/completion belong to the durability RPCs, not an upsert
// or HEAD-only ready transition.
import type { SupabaseRest } from './rest.ts';

export function createManifestStore({ rest, now = () => new Date() }: { rest: SupabaseRest; now?: () => Date }) {
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

  return { mark, get, byKey, listByUser, listPendingStale, listReady };
}

export type ManifestStore = ReturnType<typeof createManifestStore>;
