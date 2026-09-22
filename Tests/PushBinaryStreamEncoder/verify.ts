import assert from 'node:assert/strict';
import { Decompress, decompress } from 'npm:fzstd@0.1.1';
import { ZstdBounds } from '../../supabase/functions/_shared/zstdBounds.ts';

const bytes = (s: string) => Uint8Array.from(atob(s), c => c.charCodeAt(0));
const digest = async (data: Uint8Array) => Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', new Uint8Array(data).buffer)))
  .map(b => b.toString(16).padStart(2, '0')).join('');
const fixture = JSON.parse(await Deno.readTextFile(new URL(
  '../../Packages/NoopPush/Tests/NoopPushTests/Resources/streaming-npb1-golden.json', import.meta.url)));
assert.equal(fixture.synthetic_only, true);
assert.equal(fixture.zstd_version, 10507);
assert.equal(fixture.vectors.length, 24);
for (const vector of fixture.vectors) {
  const expected = bytes(vector.decoded_base64), wire = bytes(vector.wire_base64);
  assert.equal(await digest(wire), vector.wire_sha256);
  assert.equal(await digest(expected), vector.decoded_sha256);
  let decoded: Uint8Array;
  if (vector.encoding === 'zstd') {
    assert.deepEqual(decompress(wire), expected);
    const chunks: Uint8Array[] = [], bounds = new ZstdBounds(expected.length);
    const decoder = new Decompress(data => chunks.push(data));
    for (let offset = 0; offset < wire.length; offset += 7) {
      const chunk = wire.subarray(offset, offset + 7);
      bounds.push(chunk); decoder.push(chunk);
    }
    bounds.finish(); decoder.push(new Uint8Array(), true);
    decoded = new Uint8Array(chunks.reduce((n, chunk) => n + chunk.length, 0));
    let offset = 0;
    for (const chunk of chunks) { decoded.set(chunk, offset); offset += chunk.length; }
  } else {
    const stream = new ReadableStream<Uint8Array>({ start(controller) {
      for (let offset = 0; offset < wire.length; offset += 7) controller.enqueue(wire.subarray(offset, offset + 7));
      controller.close();
    }}).pipeThrough(new DecompressionStream('gzip'));
    decoded = new Uint8Array(await new Response(stream).arrayBuffer());
  }
  assert.deepEqual(decoded, expected);
  assert.equal(await digest(decoded), vector.decoded_sha256);
}
console.log(JSON.stringify({ vectors: 24, status: 'PASS', receiver: 'production fzstd 0.1.1 + ZstdBounds / gzip DecompressionStream',
  fixture: 'synthetic_only', physical: 'NOT_MEASURED' }));
