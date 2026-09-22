import assert from 'node:assert/strict';
import { decompress, Decompress } from 'npm:fzstd@0.1.1';
import { ZstdBounds } from '../_shared/zstdBounds.ts';

const base64 = (text: string) => Uint8Array.from(atob(text), (c) => c.charCodeAt(0));
const digest = async (bytes: Uint8Array) => Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', new Uint8Array(bytes).buffer)))
  .map((value) => value.toString(16).padStart(2, '0')).join('');

Deno.test('pinned iOS Zstandard 1.5.7 level 1 and 3 goldens decode with the production receiver', async () => {
  const fixture = JSON.parse(await Deno.readTextFile(new URL(
    '../../../Packages/NoopPush/Tests/NoopPushTests/Resources/zstd-1.5.7-golden.json', import.meta.url)));
  assert.equal(fixture.upstream_version, '1.5.7');
  for (const vector of fixture.vectors) {
    const expected = base64(vector.decoded_base64);
    assert.equal(await digest(expected), vector.decoded_sha256);
    for (const frame of vector.frames) {
      const wire = base64(frame.wire_base64);
      assert.equal(await digest(wire), frame.wire_sha256);
      assert.deepEqual(decompress(wire), expected);
      const chunks: Uint8Array[] = [];
      const decoder = new Decompress((data) => chunks.push(data));
      const bounds = new ZstdBounds(expected.length);
      for (let offset = 0; offset < wire.length; offset += 7) {
        const chunk = wire.subarray(offset, offset + 7);
        bounds.push(chunk); decoder.push(chunk);
      }
      bounds.finish(); decoder.push(new Uint8Array(0), true);
      const streamed = new Uint8Array(chunks.reduce((sum, data) => sum + data.length, 0));
      let cursor = 0;
      for (const data of chunks) { streamed.set(data, cursor); cursor += data.length; }
      assert.deepEqual(streamed, expected);
      assert.equal(await digest(streamed), vector.decoded_sha256);
    }
  }
});
