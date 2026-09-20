import { createS3 } from '../_shared/s3.ts';

/** Synthetic, loopback-only object server. Uses the real signed S3 client and streamed reads. */
export function startObjectHttp() {
  const objects = new Map<string, Uint8Array>();
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
        objects.set(key, body.slice());
        return new Response('<CopyObjectResult><ETag>synthetic</ETag></CopyObjectResult>');
      }
      objects.set(key, new Uint8Array(await req.arrayBuffer()));
      return new Response(null, { status: 200 });
    }
    if (req.method === 'DELETE') { objects.delete(key); return new Response(null, { status: 204 }); }
    const bytes = objects.get(key);
    if (!bytes) return new Response(null, { status: 404 });
    const headers: Record<string, string> = omitLength ? {} : { 'content-length': String(bytes.length) };
    if (req.method === 'HEAD') return new Response(null, { headers });
    return new Response(new ReadableStream({ start(controller) {
      for (let i = 0; i < bytes.length; i += 31) controller.enqueue(bytes.slice(i, i + 31));
      controller.close();
    } }), { headers });
  });
  const endpoint = `http://127.0.0.1:${(server.addr as Deno.NetAddr).port}`;
  const raw = createS3({ endpoint, bucket: 'fixture', region: 'local', accessKeyId: 'fixture', secretAccessKey: 'fixture' });
  return { raw, objects, async close() { abort.abort(); await server.finished; },
    setFailCopy(value: boolean) { failCopy = value; }, setOmitLength(value: boolean) { omitLength = value; } };
}
