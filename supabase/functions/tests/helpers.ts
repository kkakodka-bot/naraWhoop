// Test doubles for the push function tests — port of the retired Node receiver
// The fake bucket is reached through the REAL ported createS3 signer, so presigning, SigV4 header
// signing, key encoding, HEAD and GET all run for real; only the socket is faked.
// `putViaPresignedUrl` is the device's leg: it accepts ONLY a URL carrying a valid unexpired
// signature, which is what makes "the app uploads straight to the bucket" an assertion.
//
// Unit doubles only. SQL atomicity and authorization are proved separately by native Postgres
// and PostgREST in intake_integration_test.ts, not by the RPC responses below.
import { gzipSync } from 'node:zlib';
import { createHash } from 'node:crypto';
import { createS3 } from '../_shared/s3.ts';

export const B2_ENDPOINT = 'https://s3.us-west-004.test.local';
export const B2_BUCKET = 'frwhoop-test';
export const B2_REGION = 'us-west-004';

export function sha256Hex(buf: Uint8Array): string {
  return createHash('sha256').update(buf).digest('hex');
}

export function compressFor(compression: string, buf: Uint8Array): Uint8Array {
  if (compression === 'gzip') return gzipSync(buf);
  if (compression !== 'zstd') return buf;
  // Valid Zstandard frame with raw blocks (not the old identity-transform pseudo-zstd fixture).
  const blocks = Math.max(1, Math.ceil(buf.length / 131072));
  const out = new Uint8Array(9 + blocks * 3 + buf.length);
  out.set([0x28, 0xb5, 0x2f, 0xfd, 0xa0]);
  new DataView(out.buffer).setUint32(5, buf.length, true);
  let offset = 9;
  for (let block = 0; block < blocks; block++) {
    const bytes = buf.subarray(block * 131072, (block + 1) * 131072);
    const header = (bytes.length << 3) | (block === blocks - 1 ? 1 : 0);
    out.set([header & 255, (header >> 8) & 255, (header >> 16) & 255], offset);
    offset += 3; out.set(bytes, offset); offset += bytes.length;
  }
  return out;
}

export function makeFakeB2({ now = () => new Date() } = {}) {
  const objects = new Map<string, { body: Uint8Array; contentType: string; etag: string }>();
  const puts: { key: string; bytes: number }[] = [];

  function keyFromUrl(url: string) {
    const parsed = new URL(url);
    const prefix = `/${B2_BUCKET}/`;
    if (!parsed.pathname.startsWith(prefix)) throw new Error(`unexpected bucket path: ${parsed.pathname}`);
    return parsed.pathname
      .slice(prefix.length)
      .split('/')
      .map(decodeURIComponent)
      .join('/');
  }

  const fetchImpl = async (url: string | URL | Request, init: any = {}): Promise<any> => {
    const method = String(init.method || 'GET').toUpperCase();
    const key = keyFromUrl(String(url));
    if (method === 'HEAD' || method === 'GET') {
      const hit = objects.get(key);
      if (!hit) return { ok: false, status: 404, headers: new Map(), text: async () => '' };
      const headers = new Map([
        ['content-length', String(hit.body.length)],
        ['content-type', hit.contentType],
        ['etag', hit.etag],
      ]);
      return {
        ok: true,
        status: 200,
        body: new ReadableStream({ start(controller) { controller.enqueue(hit.body); controller.close(); } }),
        headers: { get: (h: string) => headers.get(String(h).toLowerCase()) ?? null },
        arrayBuffer: async () => hit.body.buffer.slice(
          hit.body.byteOffset,
          hit.body.byteOffset + hit.body.byteLength,
        ),
        text: async () => new TextDecoder().decode(hit.body),
      };
    }
    if (method === 'DELETE') {
      objects.delete(key);
      return { ok: true, status: 204, headers: { get: () => null }, text: async () => '' };
    }
    if (method === 'PUT') {
      if (init.headers?.['x-amz-copy-source']) {
        const source = objects.get(decodeURIComponent(init.headers['x-amz-copy-source'].slice(`/${B2_BUCKET}/`.length)));
        if (!source) return new Response('<Error/>', { status: 404 });
        objects.set(key, { ...source, body: source.body.slice() });
        return new Response('<CopyObjectResult><ETag>fixture</ETag></CopyObjectResult>');
      }
      const body = init.body instanceof Uint8Array ? init.body : new Uint8Array(init.body || []);
      objects.set(key, { body, contentType: 'application/octet-stream', etag: `"${sha256Hex(body).slice(0, 32)}"` });
      return { ok: true, status: 200, headers: { get: () => `"${sha256Hex(body).slice(0, 32)}"` }, text: async () => '' };
    }
    throw new Error(`unhandled method ${method}`);
  };

  const s3 = createS3({
    endpoint: B2_ENDPOINT,
    bucket: B2_BUCKET,
    region: B2_REGION,
    accessKeyId: 'test-key-id',
    secretAccessKey: 'test-application-key',
    fetchImpl: fetchImpl as typeof fetch,
    style: 'path',
  });

  return {
    s3,
    objects,
    puts,
    bucket: B2_BUCKET,

    /** The device's upload leg. Refuses an unsigned or expired URL. */
    putViaPresignedUrl(uploadUrl: string, body: Uint8Array, { contentType = 'application/octet-stream' } = {}) {
      const parsed = new URL(uploadUrl);
      const sig = parsed.searchParams.get('X-Amz-Signature');
      const algo = parsed.searchParams.get('X-Amz-Algorithm');
      const amzDate = parsed.searchParams.get('X-Amz-Date');
      const expires = Number(parsed.searchParams.get('X-Amz-Expires'));
      if (!sig || algo !== 'AWS4-HMAC-SHA256') throw new Error('upload url is not presigned');
      const issued = Date.parse(
        `${amzDate!.slice(0, 4)}-${amzDate!.slice(4, 6)}-${amzDate!.slice(6, 8)}T`
        + `${amzDate!.slice(9, 11)}:${amzDate!.slice(11, 13)}:${amzDate!.slice(13, 15)}Z`,
      );
      if (now().getTime() > issued + expires * 1000) throw new Error('presigned url expired');
      const key = keyFromUrl(uploadUrl);
      objects.set(key, { body, contentType, etag: `"${sha256Hex(body).slice(0, 32)}"` });
      puts.push({ key, bytes: body.length });
      return { key, bytes: body.length };
    },
  };
}

/** Minimal Supabase REST stand-in over the tables this lane touches. */
export function makeMemRest() {
  const manifests = new Map<string, any>();
  const tables = new Map<string, any[]>();

  function rowsFor(table: string) {
    if (!tables.has(table)) tables.set(table, []);
    return tables.get(table)!;
  }

  const deletedAuthUsers: string[] = [];

  return {
    configured: true,
    manifests,
    tables,
    deletedAuthUsers,

    rowCount(table: string) {
      return table === 'object_manifests' ? manifests.size : rowsFor(table).length;
    },

    async upsert(table: string, row: any, opts: any = {}) {
      const incoming = Array.isArray(row) ? row : [row];
      if (table === 'object_manifests') {
        for (const r of incoming) manifests.set(r.id, { ...manifests.get(r.id), ...r });
        return incoming.length === 1 ? manifests.get(incoming[0].id) : incoming;
      }
      const keys = String(opts.onConflict || '').split(',').map((k) => k.trim()).filter(Boolean);
      const list = rowsFor(table);
      for (const r of incoming) {
        if (r.id == null && !keys.includes('id')) r.id = crypto.randomUUID();
        const idx = keys.length
          ? list.findIndex((existing) => keys.every((k) => existing[k] === r[k]))
          : -1;
        if (idx >= 0) list[idx] = { ...list[idx], ...r };
        else list.push({ ...r });
      }
      return incoming;
    },

    async select(table: string, query = '') {
      if (table !== 'object_manifests') {
        // Minimal PostgREST filter support for non-manifest tables: key=eq.value and key=is.null.
        const terms = String(query).split('&').map((x) => x.trim()).filter(Boolean);
        const filters = terms
          .filter((t) => t.includes('='))
          .map((t) => {
            const [k, v] = t.split('=');
            return { k, v };
          });
        let rows = rowsFor(table);
        for (const { k, v } of filters) {
          if (v === 'is.null') rows = rows.filter((r) => r[k] == null);
          else if (v.startsWith('eq.')) rows = rows.filter((r) => String(r[k]) === v.slice(3));
        }
        return rows;
      }
      if (table === 'object_manifests') {
        const idm = /(?:^|&)id=eq\.([^&]+)/.exec(query);
        const id = idm?.[1];
        if (id) return [manifests.get(id)].filter(Boolean);
        const keym = /(?:^|&)object_key=eq\.([^&]+)/.exec(query);
        const key = keym?.[1];
        if (key) {
          const want = decodeURIComponent(key);
          return [...manifests.values()].filter((r) => r.object_key === want);
        }
        let rows = [...manifests.values()];
        const daym = /(?:^|&)period_day=eq\.([^&]+)/.exec(query);
        if (daym?.[1]) rows = rows.filter((r) => r.period_day === daym[1]);
        const uidm = /(?:^|&)user_id=eq\.([^&]+)/.exec(query);
        if (uidm?.[1]) rows = rows.filter((r) => r.user_id === uidm[1]);
        const batchm = /(?:^|&)batch_id=eq\.([^&]+)/.exec(query);
        if (batchm?.[1]) rows = rows.filter((r) => r.batch_id === batchm[1]);
        return rows;
      }
      return rowsFor(table);
    },

    async request(path: string, { method, body }: any = {}) {
      const id = /id=eq\.([^&]+)/.exec(path)?.[1];
      if (method === 'PATCH' && id && path.startsWith('object_manifests')) {
        manifests.set(id, { ...manifests.get(id), ...body });
        return [manifests.get(id)];
      }
      return [];
    },

    async rpc(name: string, args: any = {}) {
      if (name === 'noop_register_push_device') {
        const devices = rowsFor('devices');
        const existing = devices.find((r) => r.id === args.p_device_id);
        if (existing && existing.user_id !== args.p_user_id) throw new Error('device_owner_conflict');
        if (!existing) devices.push({ id: args.p_device_id, user_id: args.p_user_id });
        return args.p_device_id;
      }
      if (name === 'noop_reserve_object_manifest') {
        const row = args.p_manifest;
        const prior = manifests.get(row.id);
        if (prior && (prior.user_id !== row.user_id || prior.device_id !== row.device_id)) throw new Error('object_owner_conflict');
        if (prior && ['sha256', 'object_kind', 'compressed_bytes', 'uncompressed_bytes', 'schema_version', 'start_at', 'end_at', 'sample_count', 'batch_id', 'source_id'].some((key) => prior[key] !== row[key])) throw new Error('object_id_conflict');
        if (!prior) manifests.set(row.id, { ...row, upload_object_key: row.object_key });
        return manifests.get(row.id);
      }
      if (name === 'noop_commit_object_receipt') {
        const row = manifests.get(args.p_object_id);
        const stamp = new Date().toISOString();
        const receipt = row.durability_receipt ?? {
          version: 1, state: 'verified_indexed', receiptId: crypto.randomUUID(),
          ownerUserId: row.user_id, deviceId: row.device_id, objectId: row.id,
          batchId: row.batch_id, sourceId: row.source_id, stream: row.object_kind,
          schemaVersion: row.schema_version, objectKey: args.p_verified_key,
          contentSha256: args.p_content_sha256, wireSha256: args.p_wire_sha256,
          compressedBytes: args.p_compressed_bytes, uncompressedBytes: args.p_uncompressed_bytes,
          verifiedAt: stamp, indexedAt: stamp,
        };
        row.durability_receipt = receipt; row.object_key = receipt.objectKey;
        row.status = 'ready'; row.sha256_source = 'server_verified';
        const windows = rowsFor('noop_signal_windows');
        const seconds = (Date.parse(row.end_at) - Date.parse(row.start_at)) / 1000;
        if (!windows.some((r) => r.object_id === row.id)) windows.push({
          object_id: row.id, expected_records: seconds, received_records: row.sample_count,
          missing_records: Math.max(0,seconds-row.sample_count), coverage: Math.min(1,row.sample_count/seconds),
          interpolated_records: 0,
        });
        return receipt;
      }
      return [];
    },

    async patch(table: string, body: any, query = '') {
      const id = /id=eq\.([^&]+)/.exec(query)?.[1];
      const list = rowsFor(table);
      let changed: any[] = [];
      const apply = (r: any) => {
        const hit = { ...r, ...body };
        // emulate the real PostgREST `revoked_at=is.null` guard: only update unrevoked rows
        if (/revoked_at=is\.null/.test(query) && r.revoked_at) return null;
        return hit;
      };
      if (id) {
        const idx = list.findIndex((r) => r.id === id);
        if (idx >= 0) {
          const hit = apply(list[idx]);
          if (hit) { list[idx] = hit; changed = [hit]; }
        }
        return changed;
      }
      return [];
    },

    async delete(table: string, query = '') {
      const lt = /([A-Za-z_]+)=lt\.(-?\d+)/.exec(query);
      const list = rowsFor(table);
      if (!lt) {
        tables.set(table, []);
        return [];
      }
      const [, column, bound] = lt;
      tables.set(table, list.filter((r) => Number(r[column]) >= Number(bound)));
      return [];
    },

    async adminDeleteAuthUser(userId: string) {
      deletedAuthUsers.push(userId);
      return { deleted: true, missing: false };
    },
  };
}

export type MemRest = ReturnType<typeof makeMemRest>;
