
// Phase 2 worker tests — mirror the retired Node receiver for the Edge ports:
// reconcileObjects, sweepExpiredManifests, createDeletionService.
import { assertEquals, assert } from 'jsr:@std/assert';
import { compressFor, makeFakeB2, makeMemRest } from './helpers.ts';
import { reconcileIntake, verifyStoredObject } from '../_shared/durability.ts';
import {
  reconcileObjects,
  sweepExpiredManifests,
  createDeletionService,
  DELETION_TABLES,
} from '../_shared/workers.ts';

const USER = '7f2c9a10-4b3e-4d8a-9c11-00000000f001';
const DEVICE = '11111111-1111-4111-8111-111111111111';

async function digest(bytes: Uint8Array): Promise<string> {
  return [...new Uint8Array(await crypto.subtle.digest('SHA-256', new Uint8Array(bytes)))].map(b => b.toString(16).padStart(2, '0')).join('');
}

function rawManifest(id: string, format: string, compression: string, encoded: Uint8Array, decoded: Uint8Array) {
  return {
    id, user_id: USER, device_id: DEVICE, object_key: `v3/core/users/${USER}/devices/${DEVICE}/rawBatch/${id}.bin`,
    status: 'uploaded', object_class: 'raw', object_kind: 'rawBatch', format, compression,
    compressed_bytes: encoded.length, uncompressed_bytes: decoded.length, schema_version: 1,
    start_at: '2026-09-10T12:00:00Z', end_at: '2026-09-10T12:00:01Z', sample_count: 1,
  };
}

async function intakeHarness(rows: any[], bytes: Map<string, Uint8Array>) {
  const rest = await memRest(rows), bucket = makeFakeB2();
  await rest.upsert('devices', { id: DEVICE, user_id: USER });
  for (const row of rows) await bucket.s3.putObject(row.object_key, bytes.get(row.id)!);
  const rpc = rest.rpc.bind(rest);
  rest.rpc = async (name, args) => {
    if (name === 'noop_intake_reconcile_page') {
      // Only the SQL page transport is doubled here. Native integration tests cover its cursor,
      // authorization and transactionality; real storage reads and byte verification run below.
      assert(Number.isSafeInteger(args.p_limit) && args.p_limit > 0);
      return [...rest.manifests.values()].filter((row) => row.object_class === 'raw' && !row.durability_receipt)
        .slice(0, args.p_limit);
    }
    return rpc(name, args);
  };
  return { rest, raw: bucket.s3 };
}

Deno.test('append gzip intake reconciliation uses the original stored-byte digest and rejects changed bytes', async () => {
  const decoded = new TextEncoder().encode('{"fixture":"append archive"}\n');
  const encoded = compressFor('gzip', decoded);
  // Change only gzip's mtime metadata: decoded content is unchanged, but the legacy wire digest
  // must still reject the different stored object.
  const changed = new Uint8Array(encoded); changed[4] ^= 1;
  const ids = ['aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'];
  const rows = ids.map((id, index) => ({ ...rawManifest(id, 'ndjson_gzip_noop_push_v1', 'gzip', encoded, decoded),
    status: index === 0 ? 'pending' : 'uploaded', sha256: '' }));
  for (const row of rows) row.sha256 = await digest(encoded);
  const { rest, raw } = await intakeHarness(rows, new Map([[ids[0], encoded], [ids[1], encoded], [ids[2], changed]]));
  let mismatch = false;
  try { await verifyStoredObject(raw, rows[2], rows[2].object_key); }
  catch (error) { mismatch = (error as Error).message === 'digest_mismatch'; }
  assert(mismatch, 'unchanged decoded content must not hide a changed legacy stored-byte digest');
  const report = await reconcileIntake(rest as any, raw);
  assertEquals(report, { scanned: 3, verifiedIndexed: 2, deferred: 1 });
  assertEquals(rest.rowCount('noop_signal_windows'), 2);
  for (const id of ids.slice(0, 2)) {
    const row = rest.manifests.get(id);
    assertEquals(row.status, 'ready');
    assertEquals(row.durability_receipt.wireSha256, await digest(encoded));
    assertEquals(row.durability_receipt.contentSha256, await digest(decoded));
  }
  assertEquals(rest.manifests.get(ids[2]).status, 'failed');
  assertEquals(rest.manifests.get(ids[2]).durability_receipt, undefined);
});

Deno.test('raw intake verifies decoded gzip and zstd content while malformed compression stays unverified', async () => {
  const decoded = new TextEncoder().encode('NPB1 synthetic raw compression contract fixture');
  const gzip = compressFor('gzip', decoded), zstd = compressFor('zstd', decoded);
  const ids = ['aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'];
  const rows = [rawManifest(ids[0], 'bin_gzip_noop_push_v1', 'gzip', gzip, decoded),
    rawManifest(ids[1], 'bin_zstd_noop_push_v1', 'zstd', zstd, decoded),
    rawManifest(ids[2], 'bin_zstd_noop_push_v1', 'zstd', gzip, decoded)]
    .map((row) => ({ ...row, sha256: '' }));
  for (const row of rows) row.sha256 = await digest(decoded);
  const { rest, raw } = await intakeHarness(rows, new Map([[ids[0], gzip], [ids[1], zstd], [ids[2], gzip]]));
  const report = await reconcileIntake(rest as any, raw);
  assertEquals(report, { scanned: 3, verifiedIndexed: 2, deferred: 1 });
  assertEquals(rest.rowCount('noop_signal_windows'), 2);
  for (const id of ids.slice(0, 2)) {
    const row = rest.manifests.get(id);
    assertEquals(row.status, 'ready');
    assertEquals(row.durability_receipt.contentSha256, await digest(decoded));
    assertEquals(row.durability_receipt.uncompressedBytes, decoded.length);
  }
  assertEquals(rest.manifests.get(ids[2]).status, 'failed');
  assertEquals(rest.manifests.get(ids[2]).durability_receipt, undefined);
});

Deno.test('legacy HEAD reconciler cannot promote raw intake or bypass its atomic receipt verifier', async () => {
  const rest = await memRest(['pending', 'uploaded', 'ready'].map((status) => ({
    id: status, user_id: USER, object_key: status, object_class: 'raw', status,
  })));
  const before = structuredClone([...rest.manifests.values()]);
  const report = await reconcileObjects({ rest: rest as any, verifyChecksums: true, objectStore: {
    head: () => { throw new Error('raw intake must not use legacy HEAD reconciliation'); },
    getObject: () => { throw new Error('raw intake must use the streaming verifier'); },
  } as any });
  assertEquals(report.marked_ready, 0);
  assertEquals(report.marked_failed, 0);
  assertEquals([...rest.manifests.values()], before);
  assertEquals(rest.rowCount('noop_signal_windows'), 0);
});

Deno.test('derived checksum covers stored bytes and unknown digest contracts do not become ready', async () => {
  const bytes = new Uint8Array([1, 2, 3, 4]);
  const rest = await memRest([
    { id: 'derived', object_key: 'derived', status: 'uploaded', user_id: USER, sha256: await digest(bytes),
      object_class: 'derived', format: 'json_zstd_frwhoop_derived_v2', compression: 'zstd' },
    { id: 'unknown', object_key: 'unknown', status: 'uploaded', user_id: USER, sha256: await digest(bytes), format: 'unknown' },
  ]);
  const report = await reconcileObjects({ rest: rest as any, verifyChecksums: true,
    objectStore: { head: async () => ({ exists: true }), getObject: async () => ({ body: bytes }) } as any });
  assertEquals(report.checksum_mismatch, 0); assertEquals(report.checksum_unverified, 1);
  assertEquals([...rest.manifests.values()].find((r: any) => r.id === 'derived')?.status, 'ready');
  assertEquals([...rest.manifests.values()].find((r: any) => r.id === 'unknown')?.status, 'uploaded');
});

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
  let lateObject=true;
  const rest = {
    configured: true,
    request: async () => [],
    rpc: async () => null,
    async select(table: string) {
      if (table === 'noop_account_retirements') return [{requested_at:'2020-01-01T00:00:00Z'}];
      return table === 'object_manifests' ? [{ id: 'm', object_key: `v2/users/${USER}/raw/fixture`, status: 'ready' }] : [];
    },
    async upsert(_t: string, row: any) { order.push(`job:${row.status}:${row.step}`); return row; },
    async delete(table: string) { order.push(`sql:${table}`); return []; },
    async adminDeleteAuthUser(id: string) { order.push(`auth:${id}`); return { deleted: true }; },
  } as any;
  const objectStore = {
    async deleteObject(key: string) { order.push(`b2-obj:${key}`); return {}; },
    async listPrefix(prefix: string) {
      order.push(`b2:${prefix}`);
      if (lateObject && prefix===`v2/users/${USER}/`) {lateObject=false;return [prefix+'late-object'];}
      return [];
    },
    async purgePrefixVersions(prefix: string) { order.push(`versions:${prefix}`); return {deleted:0}; },
  } as any;
  const deletion = createDeletionService({ rest, objectStore, uuid: () => 'job-1' });
  const job={id:'job-1',user_id:USER,status:'pending',step:'record_job',state:{failures:[],deleted_keys:[]}};
  assertEquals((await deletion.run(USER,{existing:job})).status,'retry');
  assert(!order.some(s=>s.startsWith('auth:')),'late version must be censused before Auth erasure');
  const result = await deletion.run(USER, { existing: job });
  assertEquals(result.status, 'deleted');
  assert(order.some((s) => s.startsWith('b2')));
  assert(order.indexOf(`b2:v2/users/${USER}/`) < order.indexOf(`auth:${USER}`));
  // profiles deletes by id, other tables by user_id
  assert(order.includes('sql:object_manifests'));
  assertEquals(new Set(DELETION_TABLES).size, DELETION_TABLES.length);
});
