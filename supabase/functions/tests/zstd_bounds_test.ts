import assert from 'node:assert/strict';
import { ZstdBounds } from '../_shared/zstdBounds.ts';
import { compressFor } from './helpers.ts';

Deno.test('zstd bounds: split headers, empty payload, multiple frames and truncated blocks', () => {
  for (const payload of [new Uint8Array(0), new Uint8Array(131074)]) {
    const bytes = compressFor('zstd',payload);
    const guard = new ZstdBounds(200000);
    for (const byte of bytes) guard.push(Uint8Array.of(byte));
    guard.finish();
    const truncated = new ZstdBounds(200000);
    truncated.push(bytes.subarray(0,bytes.length-1));
    assert.throws(() => truncated.finish(), /invalid_compressed_object/);
  }
  const a = compressFor('zstd',new Uint8Array(3));
  const guard = new ZstdBounds(100);
  guard.push(a); guard.push(a); guard.finish();
});

Deno.test('zstd bounds: reject oversized output or history before decoder allocation, including a later frame', () => {
  const frame = compressFor('zstd',new Uint8Array(3));
  const forged = frame.slice();
  new DataView(forged.buffer).setUint32(5, 1024*1024*1024, true);
  assert.throws(() => new ZstdBounds(1024).push(forged), /decoded_size_mismatch/);
  new DataView(forged.buffer).setUint32(5, 40*1024*1024, true);
  const guard = new ZstdBounds(512*1024*1024);
  guard.push(frame);
  assert.throws(() => guard.push(forged), /zstd_window_too_large/);
});
