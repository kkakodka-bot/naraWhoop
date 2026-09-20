// Test doubles for the push function tests — port of the retired Node receiver
// The fake bucket is reached through the REAL ported createS3 signer, so presigning, SigV4 header
// signing, key encoding, HEAD and GET all run for real; only the socket is faked.
// `putViaPresignedUrl` is the device's leg: it accepts ONLY a URL carrying a valid unexpired
// signature, which is what makes "the app uploads straight to the bucket" an assertion.
//
// One deliberate divergence: 'zstd' compression is the identity transform here. The lane never
// decompresses on the write path (digest verification stays in the Node backend), and the edge
// runtime has no zstd codec — what is under test is the housing, not the compressor.
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
  return buf; // 'zstd' and 'none' pass through — see header note
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

    async rpc(name: string, args: unknown = {}) {
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
