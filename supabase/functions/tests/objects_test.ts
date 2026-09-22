// Deno mirror of the portable cases in the retired Node receiver — the object-lane
// state machine running on the PORTED modules (objects.ts, manifests.ts, s3.ts, keys.ts). The
// reader/decode cases stay in Node with verifyObjectDigest; what is pinned here is the housing:
// intents, resumes, refusals, coverage accounting.
import assert from 'node:assert/strict';
import { createPushObjects, windowCoverage } from '../_shared/objects.ts';
import { noopDeviceId } from '../_shared/keys.ts';
import { makeFakeB2, makeMemRest, compressFor, sha256Hex, B2_BUCKET } from './helpers.ts';

const USER = '11111111-1111-4111-8111-111111111111';
const OTHER_USER = '22222222-2222-4222-8222-222222222222';
const STRAP = 'strap-local-01';
const SECOND = 1_780_000_000; // inside a UTC hour, deliberately not on the boundary
const CFG: any = {
  b2KeyId: 'k',
  b2ApplicationKey: 's',
  b2Bucket: B2_BUCKET,
  rawStore: 'b2',
};

function harness({ now = () => new Date('2026-09-07T18:30:00.000Z') } = {}) {
  const b2 = makeFakeB2({ now });
  const rest = makeMemRest();
  const objects = createPushObjects({
    cfg: CFG,
    rest: rest as any,
    raw: b2.s3,
    upsertRows: (table: string, rows: unknown[], opts: { onConflict: string }) => rest.upsert(table, rows, opts),
    ensureDevice: (row: Record<string, unknown>) => rest.upsert('devices', row, { onConflict: 'id' }),
    now,
  });
  return { b2, rest, objects, now };
}

/** A stand-in payload: the lane cares about bytes and counts, not signal content. */
function payloadOf(seconds: number): Uint8Array {
  const body = new Uint8Array(seconds * 64);
  for (let i = 0; i < body.length; i += 1) body[i] = (i * 31 + seconds) % 251;
  return body;
}

/** Builds the manifest the device computes before it uploads anything. */
function manifestFor({ stream, payload, startTs, endTs, sampleCount, compression, objectId }: {
  stream: string;
  payload: Uint8Array;
  startTs: number;
  endTs: number;
  sampleCount: number;
  compression: string;
  objectId: string;
}) {
  const wire = compressFor(compression, payload);
  return {
    manifest: {
      type: 'binaryObject',
      protocolVersion: '1.2',
      batchId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
      sourceId: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
      deviceId: STRAP,
      stream,
      objectId,
      startTs,
      endTs,
      sampleCount,
      uncompressedBytes: payload.length,
      compressedBytes: wire.length,
      contentSha256: sha256Hex(payload),
      contentEncoding: compression,
    },
    wire,
  };
}

/** Full device round: intent, PUT straight to the bucket with the signed URL, then complete. */
async function shipObject(h: ReturnType<typeof harness>, spec: any) {
  const { manifest, wire } = manifestFor(spec);
  const intent = await h.objects.createIntent({ userId: USER, manifest });
  assert.ok(intent.uploadUrl, 'intent must return a presigned upload url');
  h.b2.putViaPresignedUrl(intent.uploadUrl, wire, {
    contentType: intent.requiredHeaders!['content-type'],
  });
  const ack = await h.objects.completeObject({ userId: USER, objectId: manifest.objectId });
  return { manifest, wire, intent, ack };
}

Deno.test('housing: a PPG object round-trips through a presigned PUT byte-for-byte', async () => {
  const h = harness();
  const payload = payloadOf(10);
  const objectId = '1a1a1a1a-1a1a-4a1a-8a1a-1a1a1a1a1a1a';
  const { intent, wire, ack } = await shipObject(h, {
    stream: 'ppgWaveformSample',
    payload,
    startTs: SECOND,
    endTs: SECOND + 10,
    sampleCount: 10,
    compression: 'gzip',
    objectId,
  });

  assert.equal(ack.status, 'ready');
  assert.equal(ack.duplicate, false);
  const stored = h.b2.objects.get(intent.objectKey!);
  assert.ok(stored, 'object must be in the bucket');
  assert.deepEqual(stored.body, wire, 'bucket bytes must be the uploaded bytes');
  assert.ok(intent.objectKey!.startsWith(`v3/research/users/${USER}/`));
  assert.ok(intent.objectKey!.endsWith('.bin.gz'));

  const row = h.rest.manifests.get(objectId);
  assert.equal(row.status, 'ready');
  assert.equal(row.sha256_source, 'server_verified');
  assert.equal(ack.durabilityReceipt.state, 'verified_indexed');
  assert.equal(ack.durabilityReceipt.contentSha256, sha256Hex(payload));
  assert.equal(row.compressed_bytes, wire.length);
  assert.equal(h.rest.rowCount('noop_signal_windows'), 1);
});

Deno.test('housing: a truncated upload is refused and never reaches ready', async () => {
  const h = harness();
  const payload = payloadOf(10);
  const objectId = '4d4d4d4d-4d4d-4d4d-8d4d-4d4d4d4d4d4d';
  const { manifest, wire } = manifestFor({
    stream: 'ppgWaveformSample',
    payload,
    startTs: SECOND,
    endTs: SECOND + 10,
    sampleCount: 10,
    compression: 'gzip',
    objectId,
  });

  const intent = await h.objects.createIntent({ userId: USER, manifest });
  h.b2.putViaPresignedUrl(intent.uploadUrl!, wire.subarray(0, wire.length - 8));

  await assert.rejects(
    () => h.objects.completeObject({ userId: USER, objectId }),
    (err: any) => err.code === 'size_mismatch' && err.status === 409,
  );
  assert.equal(h.rest.manifests.get(objectId).status, 'failed');
  assert.equal(h.rest.rowCount('noop_signal_windows'), 0, 'a failed object must not be catalogued');
});

Deno.test('housing: completing before the upload lands is refused as object_missing', async () => {
  const h = harness();
  const payload = payloadOf(4);
  const objectId = '5e5e5e5e-5e5e-4e5e-8e5e-5e5e5e5e5e5e';
  const { manifest } = manifestFor({
    stream: 'ppgWaveformSample',
    payload,
    startTs: SECOND,
    endTs: SECOND + 4,
    sampleCount: 4,
    compression: 'gzip',
    objectId,
  });
  await h.objects.createIntent({ userId: USER, manifest });

  await assert.rejects(
    () => h.objects.completeObject({ userId: USER, objectId }),
    (err: any) => err.code === 'object_missing' && err.status === 409,
  );
  assert.equal(h.rest.manifests.get(objectId).status, 'failed');
});

Deno.test('housing: a manifest rejects a client-chosen key, PII, and a mismatched encoding', async () => {
  const h = harness();
  const payload = payloadOf(4);
  const base = manifestFor({
    stream: 'ppgWaveformSample',
    payload,
    startTs: SECOND,
    endTs: SECOND + 4,
    sampleCount: 4,
    compression: 'gzip',
    objectId: '8b8b8b8b-8b8b-4b8b-8b8b-8b8b8b8b8b8b',
  }).manifest;

  const cases: [string, any][] = [
    ['objectKey', { ...base, objectKey: 'v3/research/users/x/anything' }],
    ['deviceId', { ...base, deviceId: 'patient@example.com' }],
    ['contentEncoding', { ...base, contentEncoding: 'zstd' }],
    ['stream', { ...base, stream: 'hrSample' }],
    ['endTs', { ...base, endTs: base.startTs }],
  ];
  for (const [field, manifest] of cases) {
    await assert.rejects(
      () => h.objects.createIntent({ userId: USER, manifest }),
      (err: any) => err.code === 'invalid_object_manifest' && err.fields.includes(field),
      `expected ${field} to be refused`,
    );
  }
  assert.equal(h.rest.manifests.size, 0);
});

Deno.test('housing: replaying an object is idempotent and writes one manifest row', async () => {
  const h = harness();
  const payload = payloadOf(30);
  const objectId = '9c9c9c9c-9c9c-4c9c-8c9c-9c9c9c9c9c9c';
  const spec = {
    stream: 'ppgWaveformSample',
    payload,
    startTs: SECOND,
    endTs: SECOND + 30,
    sampleCount: 30,
    compression: 'gzip',
    objectId,
  };

  const first = await shipObject(h, spec);
  assert.equal(first.ack.duplicate, false);

  const { manifest } = manifestFor(spec);
  const replay = await h.objects.createIntent({ userId: USER, manifest });
  assert.equal(replay.duplicate, true);
  assert.equal(replay.uploadUrl, undefined, 'a completed object must not be re-signed for upload');

  const secondAck = await h.objects.completeObject({ userId: USER, objectId });
  assert.equal(secondAck.duplicate, true);
  assert.equal(secondAck.status, 'ready');
  assert.equal(h.rest.manifests.size, 1);
  assert.equal(h.rest.rowCount('noop_signal_windows'), 1);
});

Deno.test('housing: an interrupted upload resumes onto the same key', async () => {
  const h = harness();
  const payload = payloadOf(8);
  const objectId = 'a1a1a1a1-a1a1-4a1a-8a1a-a1a1a1a1a1a1';
  const spec = {
    stream: 'ppgWaveformSample',
    payload,
    startTs: SECOND,
    endTs: SECOND + 8,
    sampleCount: 8,
    compression: 'gzip',
    objectId,
  };

  const first = await h.objects.createIntent({ userId: USER, manifest: manifestFor(spec).manifest });
  const resumed = await h.objects.createIntent({ userId: USER, manifest: manifestFor(spec).manifest });
  assert.equal(resumed.objectKey, first.objectKey, 'a retry must not mint a second key');
  assert.ok(resumed.uploadUrl, 'a pending object must still be uploadable');
  assert.equal(h.rest.manifests.size, 1);
});

Deno.test('housing: reusing an object id for different bytes is a conflict, not an overwrite', async () => {
  const h = harness();
  const objectId = 'b2b2b2b2-b2b2-4b2b-8b2b-b2b2b2b2b2b2';
  await shipObject(h, {
    stream: 'ppgWaveformSample',
    payload: payloadOf(10),
    startTs: SECOND,
    endTs: SECOND + 10,
    sampleCount: 10,
    compression: 'gzip',
    objectId,
  });

  const different = payloadOf(11);
  const { manifest } = manifestFor({
    stream: 'ppgWaveformSample',
    payload: different,
    startTs: SECOND,
    endTs: SECOND + 10,
    sampleCount: 10,
    compression: 'gzip',
    objectId,
  });

  await assert.rejects(
    () => h.objects.createIntent({ userId: USER, manifest }),
    (err: any) => err.code === 'object_id_conflict' && err.status === 409,
  );
});

Deno.test('housing: one subject cannot complete or read another subject object', async () => {
  const h = harness();
  const payload = payloadOf(6);
  const objectId = 'c3c3c3c3-c3c3-4c3c-8c3c-c3c3c3c3c3c3';
  await shipObject(h, {
    stream: 'ppgWaveformSample',
    payload,
    startTs: SECOND,
    endTs: SECOND + 6,
    sampleCount: 6,
    compression: 'gzip',
    objectId,
  });

  await assert.rejects(
    () => h.objects.completeObject({ userId: OTHER_USER, objectId }),
    (err: any) => err.code === 'forbidden' && err.status === 403,
  );

  // Keys are minted per subject, so the other subject's prefix cannot even name this object.
  const row = h.rest.manifests.get(objectId);
  assert.ok(row.object_key.includes(`/users/${USER}/`));
  assert.ok(!row.object_key.includes(OTHER_USER));
});

Deno.test('housing: a dropout is catalogued as missing records, never interpolated', async () => {
  const h = harness();
  const objectId = 'd4d4d4d4-d4d4-4d4d-8d4d-d4d4d4d4d4d4';
  // A 7-minute BLE dropout in the middle of an hour: 3180 records for a 3600-second window.
  const received = 3180;
  await shipObject(h, {
    stream: 'rawImuSession',
    payload: payloadOf(received),
    startTs: SECOND,
    endTs: SECOND + 3600,
    sampleCount: received,
    compression: 'zstd',
    objectId,
  });

  const [window] = h.rest.tables.get('noop_signal_windows')!;
  assert.equal(window.expected_records, 3600);
  assert.equal(window.received_records, 3180);
  assert.equal(window.missing_records, 420, 'the dropout must be reported, not absorbed');
  assert.equal(window.interpolated_records, 0);
  assert.ok(Math.abs(window.coverage - 3180 / 3600) < 1e-9);
});

Deno.test('windowCoverage reports null rather than a guess for a stream with no fixed rate', () => {
  const fixed = windowCoverage({ stream: 'rawImuSession', startTs: 100, endTs: 160, sampleCount: 45 });
  assert.equal(fixed.expectedRecords, 60);
  assert.equal(fixed.missingRecords, 15);
  assert.equal(fixed.coverage, 0.75);

  const unrated = windowCoverage({ stream: 'rawBatch', startTs: 100, endTs: 160, sampleCount: 12 });
  assert.equal(unrated.expectedRecords, null);
  assert.equal(unrated.coverage, null);
  assert.equal(unrated.missingRecords, null);
  assert.equal(unrated.receivedRecords, 12);
});

Deno.test('housing: an object carrying more records than its window claims is capped at full coverage', () => {
  const over = windowCoverage({ stream: 'rawImuSession', startTs: 100, endTs: 110, sampleCount: 40 });
  assert.equal(over.coverage, 1);
  assert.equal(over.missingRecords, 0);
});

Deno.test('housing: an archived object lands under the research prefix for its subject and hour', async () => {
  const h = harness();
  const device = noopDeviceId(USER, STRAP);
  const objectId = 'e5e5e5e5-e5e5-4e5e-8e5e-e5e5e5e5e5e5';
  const { intent } = await shipObject(h, {
    stream: 'rawImuSession',
    payload: payloadOf(4),
    startTs: SECOND,
    endTs: SECOND + 4,
    sampleCount: 4,
    compression: 'zstd',
    objectId,
  });
  const start = new Date(SECOND * 1000);
  const p = (n: number) => String(n).padStart(2, '0');
  const expectPrefix = `v3/research/users/${USER}/devices/${device}/rawImuSession/`
    + `${start.getUTCFullYear()}/${p(start.getUTCMonth() + 1)}/${p(start.getUTCDate())}/${p(start.getUTCHours())}/`;
  assert.ok(intent.objectKey!.startsWith(expectPrefix), `${intent.objectKey} must be under ${expectPrefix}`);
  assert.ok(intent.objectKey!.endsWith('.bin.zst'));
});
