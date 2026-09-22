import { createS3 } from '../_shared/s3.ts';

/** Synthetic, loopback-only object server. Uses the real signed S3 client and streamed reads. */
export function startObjectHttp({ versioned = false, chunkBytes = 31 }: { versioned?: boolean; chunkBytes?: number } = {}) {
  if (!Number.isInteger(chunkBytes) || chunkBytes < 1 || chunkBytes > 262144) throw new Error("invalid_fixture_chunk_size");
  const objects = new Map<string, Uint8Array>();
  const versions = new Map<string, Map<string, Uint8Array>>();
  function save(key: string, bytes: Uint8Array) {
    objects.set(key, bytes);
    if (versioned) {
      const saved = versions.get(key) ?? new Map<string, Uint8Array>();
      saved.set(crypto.randomUUID(), bytes);
      versions.set(key, saved);
    }
  }
  const abort = new AbortController();
  let failCopy = false;
  let omitLength = false;
  const server = Deno.serve({ hostname: '127.0.0.1', port: 0, signal: abort.signal, onListen() {} }, async (req) => {
    const key = decodeURIComponent(new URL(req.url).pathname.slice('/fixture/'.length));
    if (req.method === 'PUT') {
      const source = req.headers.get('x-amz-copy-source');
      if (source) {
        if (failCopy) return new Response('<Error><Code>FixtureCopyFailure</Code></Error>');
        const body = objects.get(decodeURIComponent(source.slice('/fixture/'.length)));
        if (!body) return new Response('<Error/>', { status: 404 });
        save(key, body.slice());
        return new Response('<CopyObjectResult><ETag>synthetic</ETag></CopyObjectResult>');
      }
      save(key, new Uint8Array(await req.arrayBuffer()));
      return new Response(null, { status: 200 });
    }
    if (req.method === 'DELETE') {
      const version = new URL(req.url).searchParams.get('versionId');
      if (versioned && version) {
        const saved = versions.get(key);
        saved?.delete(version);
        const remaining = saved && [...saved.values()].at(-1);
        if (remaining) objects.set(key, remaining); else objects.delete(key);
      } else { objects.delete(key); }
      return new Response(null, { status: 204 });
    }
    const bytes = objects.get(key);
    if (!bytes) return new Response(null, { status: 404 });
    const headers: Record<string, string> = omitLength ? {} : { 'content-length': String(bytes.length) };
    headers['x-amz-version-id'] = versioned
      ? [...versions.get(key)!.keys()].at(-1)! : 'fixture-version';
    // Deno emits Content-Length: 0 for a null response body. An unknown-length
    // stream exercises a genuinely absent length on the wire for HEAD too.
    if (req.method === 'HEAD') return new Response(omitLength
      ? new ReadableStream({ start(controller) { controller.close(); } }) : null, { headers });
    return new Response(new ReadableStream({ start(controller) {
      for (let i = 0; i < bytes.length; i += chunkBytes) controller.enqueue(bytes.slice(i, i + chunkBytes));
      controller.close();
    } }), { headers });
  });
  const endpoint = `http://127.0.0.1:${(server.addr as Deno.NetAddr).port}`;
  const raw = createS3({ endpoint, bucket: 'fixture', region: 'local', accessKeyId: 'fixture', secretAccessKey: 'fixture' });
  return { raw, objects, versions, async close() { abort.abort(); await server.finished; },
    setFailCopy(value: boolean) { failCopy = value; }, setOmitLength(value: boolean) { omitLength = value; } };
}
