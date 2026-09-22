
// Phase 2 worker tests — mirror the retired Node receiver for the Edge ports:
// reconcileObjects, sweepExpiredManifests, createDeletionService.
import { assertEquals, assert } from 'jsr:@std/assert';
import { makeMemRest } from './helpers.ts';
import {
  reconcileObjects,
  sweepExpiredManifests,
  createDeletionService,
  DELETION_TABLES,
} from '../_shared/workers.ts';

const USER = '7f2c9a10-4b3e-4d8a-9c11-00000000f001';

async function memRest(rows: any[]) {
  const rest = makeMemRest();
  for (const row of rows) await rest.upsert('object_manifests', { ...row });
  return rest;
}

Deno.test('reconcile finds pending without object, ready without object, and orphans', async () => {
  const rest = await memRest([
    { id: '1', object_key: 'missing', status: 'pending', created_at: '2020-01-01T00:00:00.000Z', user_id: USER },
    { id: '2', object_key: 'gone', status: 'ready', user_id: USER },
  ]);
  const report = await reconcileObjects({
    rest: rest as any,
    objectStore: { head: async () => null } as any,
    userId: USER,
    listPrefix: async () => ['orphan-key'],
  });
  assert(report.pending_missing_object >= 1);
  assert(report.ready_missing_object >= 1);
  assertEquals(report.orphan_objects, 1);
});

Deno.test('reconcile lists v3 prefixes for orphan census', async () => {
  const prefixes: string[] = [];
  const report = await reconcileObjects({
    rest: await memRest([]) as any,
    objectStore: { head: async () => null } as any,
    userId: USER,
    listPrefix: async (p) => { prefixes.push(p); return p.startsWith('v3/') ? ['v3/core/users/u/physiology/x'] : []; },
  });
  assert(prefixes.some((p) => p.startsWith('v3/core/')));
  assertEquals(report.listed_objects, 1);
  assertEquals(report.orphan_objects, 1);
});

Deno.test('sweep deletes expired manifests and marks them deleted; failure marks failed', async () => {
  const rest = makeMemRest();
  await rest.upsert('object_manifests', { id: 'a', object_key: 'expired-key', status: 'ready', expires_at: '2020-01-01T00:00:00Z', user_id: USER });
  await rest.upsert('object_manifests', { id: 'b', object_key: 'throw-key', status: 'verified', expires_at: '2020-01-01T00:00:00Z', user_id: USER });
  const deleted: string[] = [];
  const objectStore = {
    async deleteObject(key: string) { if (key === 'throw-key') throw new Error('boom'); deleted.push(key); return {}; },
  } as any;
  const report = await sweepExpiredManifests({ rest: rest as any, objectStore, now: () => new Date('2021-01-01T00:00:00Z') });
  assertEquals(report.deleted, 1);
  const byId = Object.fromEntries([...rest.manifests.entries()].map(([id, r]: any) => [id, r]));
  assertEquals(byId.a.status, 'deleted');
  assertEquals(byId.b.status, 'failed');
});

Deno.test('reconcile marks derived ready row corrupt when B2 HEAD is missing', async () => {
  const derivedKey = `v3/derived/users/${USER}/days/2026-06-15/frwhoop-server-1.json.zst`;
  const rest = await memRest([
    { id: 'd1', object_key: derivedKey, status: 'ready', user_id: USER, compressed_bytes: 100 },
  ]);
  const report = await reconcileObjects({
    rest: rest as any,
    objectStore: { head: async () => null } as any,
    userId: USER,
    listPrefix: async () => [],
  });
  assertEquals(report.ready_missing_object, 1);
  const row = [...rest.manifests.values()].find((r: any) => r.id === 'd1');
  assertEquals(row?.status, 'corrupt');
});

Deno.test('reconcile counts derived prefix orphans', async () => {
  const orphanKey = `v3/derived/users/${USER}/days/2026-06-15/frwhoop-server-1.json.zst`;
  const prefixes: string[] = [];
  const report = await reconcileObjects({
    rest: await memRest([]) as any,
    objectStore: { head: async () => null } as any,
    userId: USER,
    listPrefix: async (p) => {
      prefixes.push(p);
      return p.startsWith('v3/derived/') ? [orphanKey] : [];
    },
  });
  assert(prefixes.some((p) => p.startsWith('v3/derived/')));
  assertEquals(report.orphan_objects, 1);
});

Deno.test('sweep deletes expired derived manifest', async () => {
  const derivedKey = `v3/derived/users/${USER}/days/2026-06-15/frwhoop-server-1.json.zst`;
  const rest = makeMemRest();
  await rest.upsert('object_manifests', {
    id: 'd-exp',
    object_key: derivedKey,
    status: 'ready',
    expires_at: '2020-01-01T00:00:00Z',
    user_id: USER,
    object_kind: 'derived_scores',
  });
  const deleted: string[] = [];
  const objectStore = {
    async deleteObject(key: string) { deleted.push(key); return {}; },
  } as any;
  const report = await sweepExpiredManifests({
    rest: rest as any,
    objectStore,
    now: () => new Date('2021-01-01T00:00:00Z'),
  });
  assertEquals(report.deleted, 1);
  assertEquals(deleted[0], derivedKey);
});

Deno.test('deletion is resumable and deletes b2 before auth', async () => {
  const order: string[] = [];
  const rest = {
    configured: true,
    request: async () => [],
    async select(table: string) { return table === 'object_manifests' ? [{ id: 'm', object_key: 'k', status: 'ready' }] : []; },
    async upsert(_t: string, row: any) { order.push(`job:${row.status}:${row.step}`); return row; },
    async delete(table: string) { order.push(`sql:${table}`); return []; },
    async adminDeleteAuthUser(id: string) { order.push(`auth:${id}`); return { deleted: true }; },
  } as any;
  const objectStore = {
    async deleteObject(key: string) { order.push(`b2-obj:${key}`); return {}; },
    async listPrefix(prefix: string) { order.push(`b2:${prefix}`); return []; },
  } as any;
  const deletion = createDeletionService({ rest, objectStore, uuid: () => 'job-1' });
  const result = await deletion.run(USER, {
    existing: { id: 'job-1', user_id: USER, status: 'pending', step: 'record_job', state: { failures: [], deleted_keys: [] } },
  });
  assertEquals(result.status, 'deleted');
  assert(order.some((s) => s.startsWith('b2')));
  assert(order.indexOf(`b2:v2/users/${USER}/`) < order.indexOf(`auth:${USER}`));
  // profiles deletes by id, other tables by user_id
  assert(order.includes('sql:object_manifests'));
  assertEquals(new Set(DELETION_TABLES).size, DELETION_TABLES.length);
});
