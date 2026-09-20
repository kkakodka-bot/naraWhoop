import assert from 'node:assert/strict';
import { gunzipSync } from 'node:zlib';
import { createPushObjects } from '../_shared/objects.ts';
import { auxiliaryFingerprint } from '../_shared/auxiliaryIdentity.ts';
import { reconcileIntake } from '../_shared/durability.ts';
import { noopDeviceId } from '../_shared/keys.ts';
import { sha256Hex } from '../_shared/s3.ts';
import { startLocalPostgres, USER_A, USER_B } from './local_postgres.ts';
import { startObjectHttp } from './local_objects.ts';

Deno.test('actual Swift auxiliary1.4 whole070 intake: exact siblings, atomic rollback, server-only recovery', async (t) => {
  const directory = `${Deno.env.get('EDGE_TEST_ARTIFACTS')}/aux14-swift-intake-v1`;
  const manifestBytes = await Deno.readFile(`${directory}/manifest.json`);
  const manifest = JSON.parse(new TextDecoder().decode(manifestBytes));
  const golden = JSON.parse(await Deno.readTextFile(`${directory}/golden.json`));
  const payload = await Deno.readFile(`${directory}/payload.npb1`);
  const wire = await Deno.readFile(`${directory}/payload.gz`);
  // These hashes identify the unchanged production-Swift export, not a reconstructed encoder.
  assert.equal(sha256Hex(payload), 'f9662b4ac975b3e51527dbac18732a67b9cb72d284f73a854ec8289c3931bb10');
  assert.equal(sha256Hex(wire), '8eb0062d16944dec323ab30884d1407e6706f9524b5c15b473c35e92d75d1275');
  assert.deepEqual(new Uint8Array(gunzipSync(wire)), payload);
  assert.equal([...payload].map((byte) => byte.toString(16).padStart(2, '0')).join(''), golden.hex);
  assert.equal(manifest.compressedBytes, wire.length); assert.equal(manifest.uncompressedBytes, payload.length);
  assert.equal(manifest.contentSha256, sha256Hex(payload)); assert.equal(manifest.protocolVersion, '1.4');
  assert.equal(manifest.startTs, 1_800_000_000); assert.equal(manifest.endTs, manifest.startTs + 1);
  assert.equal(manifest.sampleCount, 3);
  assert.deepEqual([0, 4294967295, null].map((index) => auxiliaryFingerprint(manifest.deviceId, manifest.startTs, index)), golden.fingerprints);

  const db = await startLocalPostgres({ auxiliaryIdentity: true });
  const bucket = startObjectHttp();
  const cfg: any = { b2KeyId: 'fixture', b2ApplicationKey: 'fixture', b2Bucket: 'fixture', rawStore: 'b2' };
  const objects = createPushObjects({ cfg, rest: db.rest, raw: bucket.raw });
  const get = async () => (await db.rest.select('object_manifests', `id=eq.${manifest.objectId}`))[0];
  const validation = () => db.rest.select('noop_aux_object_validation', `object_id=eq.${manifest.objectId}`);
  const windows = () => db.rest.select('noop_signal_windows', `object_id=eq.${manifest.objectId}`);
  let intent: Awaited<ReturnType<typeof objects.createIntent>>;
  try {
    await t.step('unchanged sender manifest reserves schema2; actual gzip crosses signed loopback PUT', async () => {
      intent = await objects.createIntent({ userId: USER_A, manifest });
      assert.equal(intent.protocolVersion, '1.4'); assert.equal(intent.status, 'pending');
      assert.equal((await get()).schema_version, 2);
      assert.equal((await get()).device_id, noopDeviceId(USER_A, manifest.deviceId));
      const sent = await fetch(intent.uploadUrl!, { method: 'PUT', headers: intent.requiredHeaders, body: wire });
      await sent.body?.cancel(); assert.equal(sent.status, 200);
      assert.deepEqual(bucket.objects.get(intent.objectKey), wire);
    });
    await t.step('real index fault rolls back validation, receipt and index without changing the producer object', async () => {
      await db.sql(`create function fixture_swift_aux_index() returns trigger language plpgsql as $$begin raise exception 'fixture_swift_aux_index'; end$$;
        create trigger fixture_swift_aux_index before insert on noop_signal_windows for each row execute function fixture_swift_aux_index();`);
      await assert.rejects(objects.completeObject({ userId: USER_A, objectId: manifest.objectId }), /fixture_swift_aux_index/);
      assert.equal((await get()).durability_receipt, null); assert.notEqual((await get()).status, 'ready');
      assert.equal((await validation()).length, 0); assert.equal((await windows()).length, 0);
      assert.deepEqual(bucket.objects.get(intent.objectKey), wire);
      await db.sql('drop trigger fixture_swift_aux_index on noop_signal_windows');
    });
    await t.step('bounded server-only reconciliation publishes one exact owner/source/object receipt and all three identities', async () => {
      const result = await reconcileIntake(db.rest, bucket.raw, 1);
      assert.deepEqual(result, { scanned: 1, verifiedIndexed: 1, deferred: 0 });
      const row = await get(), receipt = row.durability_receipt;
      assert.equal(row.status, 'ready'); assert.equal(receipt.state, 'verified_indexed');
      assert.equal(receipt.ownerUserId, USER_A); assert.equal(receipt.deviceId, noopDeviceId(USER_A, manifest.deviceId));
      assert.equal(receipt.objectId, manifest.objectId); assert.equal(receipt.batchId, manifest.batchId);
      assert.equal(receipt.sourceId, manifest.sourceId); assert.equal(receipt.stream, 'v18AuxSample');
      assert.equal(receipt.schemaVersion, 2); assert.equal(receipt.contentSha256, manifest.contentSha256);
      assert.equal(receipt.wireSha256, sha256Hex(wire)); assert.equal(receipt.compressedBytes, wire.length);
      assert.equal(receipt.uncompressedBytes, payload.length);
      assert.deepEqual(bucket.objects.get(receipt.objectKey), wire);
      assert.deepEqual(new Uint8Array(gunzipSync(bucket.objects.get(receipt.objectKey)!)), payload);
      const [v] = await validation();
      assert.equal(v.state, 'validated'); assert.equal(v.content_sha256, receipt.contentSha256);
      assert.equal(v.wire_sha256, receipt.wireSha256);
      assert.deepEqual(v.validation, { version: 1, format: 2, records: 3, supportedRecords: 3,
        unknownIdentityRecords: 1, unsupportedFieldsRecords: 0, state: 'validated' });
      const index = await windows(); assert.equal(index.length, 1);
      assert.equal(index[0].received_records, 3); assert.equal(index[0].object_key, receipt.objectKey);
      assert.equal((await db.rest.select('noop_projection_debt', `object_id=eq.${manifest.objectId}`)).length, 0);
    });
    await t.step('lost-response/concurrent duplicates preserve original receipt/index and actual owner-role isolation', async () => {
      const receipt = (await get()).durability_receipt;
      const before = await db.sql('select sum(input_revision) from scoring_jobs_v2');
      const duplicates = await Promise.all([objects.createIntent({ userId: USER_A, manifest }),
        objects.completeObject({ userId: USER_A, objectId: manifest.objectId }),
        objects.completeObject({ userId: USER_A, objectId: manifest.objectId })]);
      for (const duplicate of duplicates) assert.deepEqual(duplicate.durabilityReceipt, receipt);
      assert.equal(duplicates[0].uploadUrl, undefined);
      assert.equal((await windows()).length, 1); assert.equal((await validation()).length, 1);
      assert.equal(await db.sql('select sum(input_revision) from scoring_jobs_v2'), before);
      await assert.rejects(objects.completeObject({ userId: USER_B, objectId: manifest.objectId }), /forbidden/);
      for (const table of ['object_manifests', 'noop_signal_windows', 'noop_aux_object_validation']) {
        const key = table === 'object_manifests' ? 'id' : 'object_id';
        const own = await db.request(`${table}?${key}=eq.${manifest.objectId}`, 'authenticated', USER_A);
        const other = await db.request(`${table}?${key}=eq.${manifest.objectId}`, 'authenticated', USER_B);
        assert.equal(own.status, 200); assert.equal(own.body.length, 1);
        assert.equal(other.status, 200); assert.equal(other.body.length, 0);
      }
      // Confirm this run did not rewrite the sender artifacts or coalesce same-second siblings.
      assert.deepEqual(await Deno.readFile(`${directory}/manifest.json`), manifestBytes);
      assert.deepEqual(await Deno.readFile(`${directory}/payload.npb1`), payload);
      assert.deepEqual(await Deno.readFile(`${directory}/payload.gz`), wire);
      const proof = { producerFixture: directory, manifestSHA256: sha256Hex(manifestBytes),
        originalGoldenUnchanged: true, receipt, fingerprints: golden.fingerprints,
        validation: (await validation())[0].validation, index: (await windows())[0],
        serverOnlyReconcile: true, duplicateInvalidationDelta: 0, ownerRows: 1, otherOwnerRows: 0 };
      await Deno.writeTextFile(`${db.base}/swift-auxiliary-070-proof.json`, JSON.stringify(proof, null, 2));
      console.log(`Actual Swift auxiliary070 proof: ${db.base}/swift-auxiliary-070-proof.json`);
    });
  } finally { await bucket.close(); await db.close(); }
});
