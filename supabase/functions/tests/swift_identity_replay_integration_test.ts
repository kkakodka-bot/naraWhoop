import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import { createPushObjects } from '../_shared/objects.ts';
import { createPushArchive, createPushIngest } from '../_shared/ingest.ts';
import { createPushWalStore } from '../_shared/wal.ts';
import { registerDevice } from '../_shared/durability.ts';
import { commitArchivedBatch } from '../_shared/projections.ts';
import { noopDeviceId } from '../_shared/keys.ts';
import { sha256Hex } from '../_shared/s3.ts';
import { startLocalPostgres, USER_A } from './local_postgres.ts';
import { startObjectHttp } from './local_objects.ts';

// Required fresh production-Swift exports; missing files fail CI rather than skipping evidence.
Deno.test('actual Swift identities: mutable reversion and compressed representation replay', async (t) => {
  const directory = Deno.env.get('EDGE_TEST_ARTIFACTS');
  const mutable = JSON.parse(await Deno.readTextFile(`${directory}/mutable-generation-swift/mutable-generations.json`));
  const binary = JSON.parse(await Deno.readTextFile(`${directory}/representation-swift/representation-compatibility.json`));
  assert.equal(mutable.schema_version, 1); assert.equal(mutable.synthetic_only, true);
  assert.equal(binary.schema_version, 1); assert.equal(binary.synthetic_only, true);
  const db = await startLocalPostgres();
  const bucket = startObjectHttp();
  const cfg: any = { b2KeyId: 'fixture', b2ApplicationKey: 'fixture', b2Bucket: 'fixture', rawStore: 'b2' };
  const archive = createPushArchive({ cfg, rest: db.rest, raw: bucket.raw });
  const ingest = createPushIngest({ walStore: createPushWalStore({ rest: db.rest })!,
    archiveObject: (args) => archive.archiveObject(args),
    ensureDevice: (row) => registerDevice(db.rest, row),
    commitProjection: (receipt, body) => commitArchivedBatch(db.rest, receipt, body) });
  const objects = createPushObjects({ cfg, rest: db.rest, raw: bucket.raw });
  try {
    await t.step('cached old A receipt is a negative control; fresh A and empty replacements apply exactly once', async () => {
      for (const group of mutable.groups) {
        const bodies: Uint8Array[] = group.bodies_base64.map((text: string) => new Uint8Array(Buffer.from(text, 'base64')));
        const headers = bodies.map((body) => JSON.parse(new TextDecoder().decode(body).split('\n')[0]));
        const receipts: any[] = [];
        for (let index = 0; index < bodies.length; index++) {
          const ack = await ingest.acceptBatch({ userId: USER_A, decodedBody: bodies[index] });
          const header = headers[index], receipt = ack.durabilityReceipt;
          assert.equal(receipt.state, 'verified_indexed'); assert.equal(receipt.batchId, header.batchId);
          assert.equal(receipt.contentSha256, sha256Hex(bodies[index]));
          assert.equal(receipt.uncompressedBytes, bodies[index].length);
          assert.equal(receipt.ownerUserId, USER_A); assert.equal(receipt.deviceId, noopDeviceId(USER_A, header.deviceId));
          receipts.push(receipt);
        }
        const first = headers[0], day = first.window.startInclusive;
        const rows = () => db.rest.select('noop_journal_entries',
          `user_id=eq.${USER_A}&device_id=eq.${noopDeviceId(USER_A, first.deviceId)}&day=eq.${day}`);
        const before = await rows();
        if (group.name === 'legacy_aba') {
          assert.equal(headers[0].batchId, headers[2].batchId);
          assert.deepEqual(receipts[0], receipts[2]);
          assert.equal(before.length, 1); assert.equal(before[0].answered_yes, false,
            'Negative control exposes content-only replacement identity reusing an earlier cached ACK');
        } else {
          assert.equal(new Set(headers.map((header) => header.batchId)).size, 3);
          assert.equal(before.length, group.name === 'generated_empty' ? 0 : 1);
          if (before.length) assert.equal(before[0].answered_yes, true);
        }
        const last = bodies.length - 1;
        assert.deepEqual((await ingest.acceptBatch({ userId: USER_A, decodedBody: bodies[last] })).durabilityReceipt, receipts[last]);
        assert.deepEqual(await rows(), before, 'Exact saved selection replay does not duplicate or change projected rows');
      }
    });

    await t.step('old and new wire representations of the same decoded batch each receive their own exact receipt', async () => {
      const old = binary.legacy, fresh = binary.streamed;
      assert.equal(old.manifest.batchId, fresh.manifest.batchId);
      assert.equal(old.manifest.contentSha256, fresh.manifest.contentSha256);
      assert.notEqual(old.manifest.objectId, fresh.manifest.objectId);
      assert.notEqual(old.wire_sha256, fresh.wire_sha256);
      const decoded = new Uint8Array(Buffer.from(binary.decoded_base64, 'base64'));
      assert.equal(sha256Hex(decoded), old.manifest.contentSha256);
      const receipts: any[] = [];
      for (const representation of [old, fresh]) {
        const manifest = representation.manifest;
        const wire = new Uint8Array(Buffer.from(representation.wire_base64, 'base64'));
        const intent = await objects.createIntent({ userId: USER_A, manifest });
        assert(intent.uploadUrl, 'Distinct representation must not receive a cached receipt for old wire bytes');
        const response = await fetch(intent.uploadUrl, { method: 'PUT', headers: intent.requiredHeaders, body: wire });
        await response.body?.cancel(); assert.equal(response.status, 200);
        const receipt = (await objects.completeObject({ userId: USER_A, objectId: manifest.objectId })).durabilityReceipt;
        assert.equal(receipt.state, 'verified_indexed'); assert.equal(receipt.objectId, manifest.objectId);
        assert.equal(receipt.batchId, manifest.batchId); assert.equal(receipt.sourceId, manifest.sourceId);
        assert.equal(receipt.contentSha256, sha256Hex(decoded)); assert.equal(receipt.wireSha256, sha256Hex(wire));
        assert.equal(receipt.compressedBytes, wire.length); assert.equal(receipt.uncompressedBytes, decoded.length);
        assert.deepEqual(bucket.objects.get(receipt.objectKey), wire);
        for (let replay = 0; replay < 2; replay++) {
          assert.deepEqual((await objects.completeObject({ userId: USER_A, objectId: manifest.objectId })).durabilityReceipt, receipt);
          const retry = await objects.createIntent({ userId: USER_A, manifest });
          assert.equal(retry.uploadUrl, undefined); assert.deepEqual(retry.durabilityReceipt, receipt);
        }
        assert.equal((await db.rest.select('noop_signal_windows', `object_id=eq.${manifest.objectId}`)).length, 1);
        receipts.push(receipt);
      }
      assert.notEqual(receipts[0].receiptId, receipts[1].receiptId);
      const manifests = await db.rest.select('object_manifests', `batch_id=eq.${fresh.manifest.batchId}`);
      assert.equal(manifests.length, 2, 'Archive index records physical immutable representations separately');
      assert.equal(new Set(manifests.map((m: any) => `${m.user_id}|${m.device_id}|${m.batch_id}|${m.sha256}`)).size, 1,
        'Both representations retain one logical decoded source identity');
      assert.equal((await db.rest.select('noop_push_acks', `batch_id=eq.${fresh.manifest.batchId}`)).length, 0,
        'Object lane must never populate the inline batch-ID receipt cache');
      await Deno.writeTextFile(`${db.base}/representation-receipts.json`, JSON.stringify({ receipts }, null, 2));
    });

    await t.step('binary inline fallback is rejected before any cached receipt or projection can authorize it', async () => {
      for (const representation of [binary.legacy, binary.streamed]) {
        const body = new TextEncoder().encode(JSON.stringify(representation.manifest) + '\n');
        await assert.rejects(ingest.acceptBatch({ userId: USER_A, decodedBody: body }), /missing_batch_header/);
        // Even a scalar-shaped envelope cannot route a raw stream into the inline receipt cache.
        const envelope = new TextEncoder().encode(JSON.stringify({ ...representation.manifest,
          type: 'batch', recordCount: 0, delivery: 'append' }) + '\n');
        await assert.rejects(ingest.acceptBatch({ userId: USER_A, decodedBody: envelope }), /use_object_lane/);
      }
      assert.equal((await db.rest.select('noop_push_acks', `batch_id=eq.${binary.streamed.manifest.batchId}`)).length, 0);
    });
  } finally { await bucket.close(); await db.close(); }
});
