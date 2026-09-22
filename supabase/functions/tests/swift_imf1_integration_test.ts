import assert from 'node:assert/strict';
import { inflateRawSync } from 'node:zlib';
import { decompress } from 'npm:fzstd@0.1.1';
import { createPushObjects } from '../_shared/objects.ts';
import { reconcileIntake } from '../_shared/durability.ts';
import { noopDeviceId } from '../_shared/keys.ts';
import { sha256Hex } from '../_shared/s3.ts';
import { startLocalPostgres, USER_B } from './local_postgres.ts';
import { startObjectHttp } from './local_objects.ts';

/** Test-only reversible archive inspection. Production retains the opaque NPB1 without BLE decoding. */
function unpackImf1(wire: Uint8Array) {
  const bytes = decompress(wire), view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  assert.deepEqual([...bytes.subarray(0, 6)], [78, 80, 66, 49, 1, 3]);
  const idLength = view.getUint16(6, true);
  let offset = 8;
  const archiveId = new TextDecoder().decode(bytes.subarray(offset, offset + idLength)); offset += idLength;
  const timestamps = Array.from({ length: 5 }, () => { const ts = Number(view.getBigInt64(offset, true)); offset += 8; return ts; });
  const count = view.getInt32(offset, true); offset += 4; assert.equal(count, 2);
  const byteSize = view.getInt32(offset, true); offset += 4;
  const blobSize = view.getUint32(offset, true); offset += 4; assert.equal(offset + blobSize, bytes.length);
  const decodedSize = view.getUint32(offset, true); offset += 4;
  const packed = new Uint8Array(inflateRawSync(bytes.subarray(offset), { maxOutputLength: 9 * 1024 * 1024 }));
  assert.equal(packed.length, decodedSize);
  const p = new DataView(packed.buffer, packed.byteOffset, packed.byteLength);
  assert.equal(p.getUint32(0, true), 2);
  const descriptorLength = p.getUint32(4, true);
  const descriptorBytes = packed.slice(8, 8 + descriptorLength);
  const fileLength = p.getUint32(8 + descriptorLength, true);
  const file = packed.slice(12 + descriptorLength);
  assert.equal(file.length, fileLength); assert.equal(descriptorLength + fileLength, byteSize);
  const descriptor = JSON.parse(new TextDecoder().decode(descriptorBytes));
  assert.equal(descriptor.kind, 'noop.imus.archive'); assert.equal(descriptor.version, 1);
  assert.equal(descriptor.fileSHA256, sha256Hex(file)); assert.equal(descriptor.fileBytes, fileLength);
  assert.equal(archiveId, `imf1.${sha256Hex(descriptorBytes)}.${sha256Hex(file)}`);
  assert.equal(timestamps[3], descriptor.bucket); assert.equal(timestamps[4], descriptor.bucket + 1800);
  return { bytes, archiveId, descriptor, descriptorBytes, file };
}

Deno.test('actual Swift imf1 session/continuous bytes cross real070/PostgREST/object HTTP unchanged', async (t) => {
  const root = `${Deno.env.get('EDGE_TEST_ARTIFACTS')}/imf1-swift-native-v1`;
  const fixture = JSON.parse(await Deno.readTextFile(`${root}/fixture.json`));
  assert.equal(fixture.synthetic, true); assert.equal(fixture.cases.length, 2);
  const db = await startLocalPostgres({ auxiliaryIdentity: true });
  const bucket = startObjectHttp();
  const cfg: any = { b2KeyId: 'fixture', b2ApplicationKey: 'fixture', b2Bucket: 'fixture', rawStore: 'b2' };
  const objects = createPushObjects({ cfg, rest: db.rest, raw: bucket.raw });
  const get = async (id: string) => (await db.rest.select('object_manifests', `id=eq.${id}`))[0];
  const proofs: unknown[] = [];
  try {
    for (const sample of fixture.cases) {
      await t.step(`${sample.origin}: exact producer manifest, compressed payload and two members survive server-only recovery`, async () => {
        const path = `${root}/${sample.origin}`;
        const manifestBytes = await Deno.readFile(`${path}/manifest.json`);
        const wire = await Deno.readFile(`${path}/payload.zst`);
        const descriptor = await Deno.readFile(`${path}/descriptor.json`);
        const source = await Deno.readFile(`${path}/source.imus`);
        for (const [name, bytes] of Object.entries({ 'manifest.json': manifestBytes, 'payload.zst': wire,
          'descriptor.json': descriptor, 'source.imus': source })) assert.equal(sha256Hex(bytes), sample.files[name]);
        const original = JSON.parse(new TextDecoder().decode(manifestBytes));
        // Production direct-lane sender adds only this measured transport byte count to manifestJSON.
        const manifest = { ...original, compressedBytes: wire.length };
        assert.equal(manifest.objectId, sample.objectId); assert.equal(manifest.deviceId, fixture.deviceId);
        const before = unpackImf1(wire);
        assert.equal(before.archiveId, sample.archiveBatchId);
        assert.equal(before.descriptor.ownerNamespace, fixture.ownerNamespace);
        assert.equal(before.descriptor.recordCount, sample.recordCount); assert.equal(before.descriptor.members.length, sample.recordCount);
        assert.deepEqual(before.descriptorBytes, descriptor); assert.deepEqual(before.file, source);
        assert.equal(sha256Hex(before.bytes), manifest.contentSha256);
        const intent = await objects.createIntent({ userId: fixture.ownerUserId, manifest });
        const sent = await fetch(intent.uploadUrl!, { method: 'PUT', headers: intent.requiredHeaders, body: wire });
        await sent.body?.cancel(); assert.equal(sent.status, 200);
        await assert.rejects(objects.completeObject({ userId: USER_B, objectId: manifest.objectId }), /forbidden/);
        await db.sql(`create or replace function fixture_imf_index_failure() returns trigger language plpgsql as $$begin raise exception 'fixture_imf_index'; end$$;
          create trigger fixture_imf_index_failure before insert on noop_signal_windows for each row execute function fixture_imf_index_failure();`);
        await assert.rejects(objects.completeObject({ userId: fixture.ownerUserId, objectId: manifest.objectId }), /fixture_imf_index/);
        assert.equal((await get(manifest.objectId)).durability_receipt, null);
        assert.equal((await db.rest.select('noop_signal_windows', `object_id=eq.${manifest.objectId}`)).length, 0);
        await db.sql('drop trigger fixture_imf_index_failure on noop_signal_windows');
        for (let page = 0; page < 8 && !(await get(manifest.objectId)).durability_receipt; page++) await reconcileIntake(db.rest, bucket.raw, 1);
        const saved = await get(manifest.objectId), receipt = saved.durability_receipt;
        assert.equal(receipt.state, 'verified_indexed'); assert.equal(receipt.schemaVersion, 1);
        assert.equal(receipt.ownerUserId, fixture.ownerUserId);
        assert.equal(receipt.deviceId, noopDeviceId(fixture.ownerUserId, fixture.deviceId));
        assert.equal(receipt.sourceId, fixture.sourceId); assert.equal(receipt.objectId, sample.objectId);
        assert.equal(receipt.batchId, sample.batchId); assert.equal(receipt.stream, 'rawBatch');
        assert.equal(receipt.contentSha256, original.contentSha256); assert.equal(receipt.wireSha256, sha256Hex(wire));
        assert.equal(receipt.compressedBytes, wire.length); assert.equal(receipt.uncompressedBytes, before.bytes.length);
        assert.deepEqual(bucket.objects.get(receipt.objectKey), wire);
        const recovered = unpackImf1(bucket.objects.get(receipt.objectKey)!);
        assert.deepEqual(recovered.descriptorBytes, descriptor); assert.deepEqual(recovered.file, source);
        const [window] = await db.rest.select('noop_signal_windows', `object_id=eq.${sample.objectId}`);
        assert.equal(window.object_key, receipt.objectKey); assert.equal(window.received_records, 2);
        for (const key of ['expected_records', 'missing_records', 'coverage']) assert.equal(window[key], null);
        assert.equal(window.interpolated_records, 0); assert.equal(saved.expires_at, null);
        assert.equal((await db.rest.select('noop_projection_debt', `object_id=eq.${sample.objectId}`)).length, 0);
        const revision = await db.sql('select sum(input_revision) from scoring_jobs_v2');
        const retry = await Promise.all([objects.completeObject({ userId: fixture.ownerUserId, objectId: manifest.objectId }),
          objects.createIntent({ userId: fixture.ownerUserId, manifest })]);
        for (const ack of retry) assert.deepEqual(ack.durabilityReceipt, receipt);
        assert.equal(await db.sql('select sum(input_revision) from scoring_jobs_v2'), revision);
        const own = await db.request(`object_manifests?id=eq.${sample.objectId}`, 'authenticated', fixture.ownerUserId);
        const other = await db.request(`object_manifests?id=eq.${sample.objectId}`, 'authenticated', USER_B);
        assert.equal(own.status, 200); assert.equal(own.body.length, 1);
        assert.equal(other.status, 200); assert.equal(other.body.length, 0);
        assert.equal(await db.sql('select count(*) from noop_hr_samples'), '0');
        proofs.push({ origin: sample.origin, receipt, descriptorSHA256: sha256Hex(descriptor), fileSHA256: sha256Hex(source),
          records: sample.recordCount, framedMembers: 2, window, ownerRows: 1, otherOwnerRows: 0 });
      });
    }
    await Deno.writeTextFile(`${db.base}/swift-imf1-receiver-proof.json`, JSON.stringify(proofs, null, 2));
    console.log(`Actual Swift imf1 proof: ${db.base}/swift-imf1-receiver-proof.json`);
  } finally { await bucket.close(); await db.close(); }
});
