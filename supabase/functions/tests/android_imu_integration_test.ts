import assert from 'node:assert/strict';
import { inflateRawSync, inflateSync } from 'node:zlib';
import { decompress } from 'npm:fzstd@0.1.1';
import { createPushObjects } from '../_shared/objects.ts';
import { reconcileIntake } from '../_shared/durability.ts';
import { noopDeviceId } from '../_shared/keys.ts';
import { sha256Hex } from '../_shared/s3.ts';
import { startLocalPostgres, USER_B } from './local_postgres.ts';
import { startObjectHttp } from './local_objects.ts';
import { ingestFailure } from './native_assertions.ts';

const text = new TextDecoder();
const view = (bytes: Uint8Array) => new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);

/** Test-only inspection of unchanged production-Android NPB1. No physiological qualification. */
function rawMembers(wire: Uint8Array) {
  const bytes = decompress(wire), v = view(bytes);
  assert.deepEqual([...bytes.subarray(0, 6)], [78, 80, 66, 49, 1, 4]);
  const count = v.getUint32(6, true);
  let offset = 10;
  const records = [];
  for (let i = 0; i < count; i++) {
    const rowId = Number(v.getBigInt64(offset, true)); offset += 8;
    const ts = Number(v.getBigInt64(offset, true)); offset += 8;
    const size = v.getUint32(offset, true); offset += 4;
    assert.equal(size, 1200); assert.ok(offset + size <= bytes.length);
    records.push({ rowId, ts, columns: bytes.slice(offset, offset + size) }); offset += size;
  }
  assert.equal(offset, bytes.length);
  return { bytes, records };
}

function exactArchive(wire: Uint8Array) {
  const bytes = decompress(wire), v = view(bytes);
  assert.deepEqual([...bytes.subarray(0, 6)], [78, 80, 66, 49, 1, 3]);
  const idSize = v.getUint16(6, true);
  const archiveId = text.decode(bytes.subarray(8, 8 + idSize));
  let offset = 8 + idSize;
  const timestamps = Array.from({ length: 5 }, () => { const value = Number(v.getBigInt64(offset, true)); offset += 8; return value; });
  assert.equal(v.getInt32(offset, true), 2); offset += 4;
  const byteSize = v.getInt32(offset, true); offset += 4;
  const blobSize = v.getUint32(offset, true); offset += 4;
  assert.equal(offset + blobSize, bytes.length);
  const decodedSize = v.getUint32(offset, true); offset += 4;
  const packed = new Uint8Array(inflateRawSync(bytes.subarray(offset), { maxOutputLength: 9 * 1024 * 1024 }));
  assert.equal(packed.length, decodedSize);
  const p = view(packed);
  assert.equal(p.getUint32(0, true), 2);
  const descriptorSize = p.getUint32(4, true);
  const descriptorBytes = packed.slice(8, 8 + descriptorSize);
  const fileSize = p.getUint32(8 + descriptorSize, true);
  const file = packed.slice(12 + descriptorSize);
  assert.equal(file.length, fileSize); assert.equal(descriptorSize + fileSize, byteSize);
  const descriptor = JSON.parse(text.decode(descriptorBytes));
  assert.equal(descriptor.kind, 'noop.imus.archive'); assert.equal(descriptor.version, 1);
  assert.equal(descriptor.platform, 'android');
  assert.equal(descriptor.fileSHA256, sha256Hex(file)); assert.equal(descriptor.fileBytes, fileSize);
  assert.equal(archiveId, `imf1.${sha256Hex(descriptorBytes)}.${sha256Hex(file)}`);
  assert.equal(timestamps[3], descriptor.bucket); assert.equal(timestamps[4], descriptor.bucket + 1800);
  // NOOPIMU2 Android uses big-endian record headers, little-endian columns and zlib-wrapped blocks.
  const f = view(file);
  assert.equal(text.decode(file.slice(0, 8)), 'NOOPIMU2');
  assert.equal(Number(f.getBigInt64(8)), descriptor.bucket);
  assert.equal(f.getInt32(16), 100); assert.equal(f.getInt32(20), 6);
  assert.equal(f.getInt32(24), 1);
  const rawSize = f.getInt32(28), compressedSize = f.getInt32(32);
  assert.equal(36 + compressedSize, file.length);
  const raw = new Uint8Array(inflateSync(file.subarray(36), { maxOutputLength: 4 * 1024 * 1024 }));
  assert.equal(raw.length, rawSize); assert.equal(raw.length, 1220);
  const r = view(raw), ts = Number(r.getBigInt64(0));
  assert.equal(r.getInt32(16), 1200);
  const columns = raw.slice(20);
  assert.equal(descriptor.members.length, 1); assert.equal(descriptor.members[0].ts, ts);
  assert.equal(descriptor.members[0].sha256, sha256Hex(columns));
  return { bytes, archiveId, descriptor, descriptorBytes, file, ts, columns };
}

Deno.test('actual Android IMU session/continuous identities survive real PostgreSQL and object HTTP without qualified time coverage', async (t) => {
  const root = Deno.env.get('ANDROID_IMU_FIXTURE_DIR');
  assert.ok(root, 'Supply the exact CloudImuPushSourceTest export; no replacement fixture is generated here');
  const fixtureBytes = await Deno.readFile(`${root}/fixture.json`);
  const fixture = JSON.parse(text.decode(fixtureBytes));
  assert.equal(fixture.synthetic, true); assert.equal(fixture.producer, 'android.CloudImuPushSource');
  assert.match(fixture.ownerUserId, /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/);
  assert.notEqual(fixture.ownerUserId, USER_B);
  assert.deepEqual(fixture.cases.map((c: any) => c.origin).sort(), ['continuous', 'session']);
  const db = await startLocalPostgres({ auxiliaryIdentity: true });
  const bucket = startObjectHttp();
  const cfg: any = { b2KeyId: 'fixture', b2ApplicationKey: 'fixture', b2Bucket: 'fixture', rawStore: 'b2' };
  const objects = createPushObjects({ cfg, rest: db.rest, raw: bucket.raw });
  const get = async (id: string) => (await db.rest.select('object_manifests', `id=eq.${id}`))[0];
  const proof: any = { synthetic: true, fixtureSHA256: sha256Hex(fixtureBytes),
    timingQualification: 'not_evaluated_by_receiver', inferredDuration: null, origins: [], rawMembers: [] };
  const members = new Map<number, { origin: string; window: string; ts: number; columns: Uint8Array }>();
  try {
    // This harness applies 070/080, not the complete physiology chain. Execute only the unchanged
    // forward coverage normalizer from1200; full migration acceptance is a separate DB suite.
    const migration = await Deno.readFile(new URL('../../migrations/20260921120000_sensor_acquisition_windows.sql', import.meta.url));
    const marker = '-- Evidence is issued by the operator after capture review.';
    const sql = text.decode(migration).split(marker);
    assert.equal(sql.length, 2);
    assert.ok(sql[0].includes('create function internal.sensor_raw_coverage_unknown()'));
    assert.ok(sql[0].includes('create trigger sensor_raw_coverage_unknown'));
    await db.sql(`${sql[0]}\ncommit;`);
    proof.coverageMigrationSHA256 = sha256Hex(migration);
    proof.migrationScope = '070/080 plus exact1200 coverage-normalizer prefix only';
    await db.sql(`insert into auth.users(id) values ('${fixture.ownerUserId}') on conflict do nothing`);

    async function readCase(directory: string, hashes: Record<string, string>) {
      const files: Record<string, Uint8Array> = {};
      for (const [name, hash] of Object.entries(hashes)) {
        assert.ok(['manifest.json', 'payload.zst', 'payload.npb1', 'descriptor.json', 'source.imus'].includes(name));
        files[name] = await Deno.readFile(`${root}/${directory}/${name}`);
        assert.equal(sha256Hex(files[name]), hash);
      }
      const original = JSON.parse(text.decode(files['manifest.json']));
      assert.equal(original.deviceId, fixture.deviceId); assert.equal(original.sourceId, fixture.sourceId);
      assert.equal(original.contentSha256, sha256Hex(files['payload.npb1']));
      assert.deepEqual(decompress(files['payload.zst']), files['payload.npb1']);
      return { files, original, manifest: { ...original, compressedBytes: files['payload.zst'].length } };
    }

    async function receive(manifest: any, files: Record<string, Uint8Array>) {
      const wire = files['payload.zst'];
      const intent = await objects.createIntent({ userId: fixture.ownerUserId, manifest });
      const sent = await fetch(intent.uploadUrl!, { method: 'PUT', headers: intent.requiredHeaders, body: new Uint8Array(wire) });
      await sent.body?.cancel(); assert.equal(sent.status, 200);
      await assert.rejects(objects.completeObject({ userId: USER_B, objectId: manifest.objectId }), /forbidden/);
      await db.sql(`create or replace function fixture_android_imu_failure() returns trigger language plpgsql as $$begin raise exception 'fixture_index'; end$$;
        create trigger fixture_android_imu_failure before insert on noop_signal_windows for each row execute function fixture_android_imu_failure();`);
      try {
        await assert.rejects(objects.completeObject({ userId: fixture.ownerUserId, objectId: manifest.objectId }),
          ingestFailure('archive_verify', manifest.stream));
        assert.equal((await get(manifest.objectId)).durability_receipt, null);
        assert.equal((await db.rest.select('noop_signal_windows', `object_id=eq.${manifest.objectId}`)).length, 0);
      } finally { await db.sql('drop trigger fixture_android_imu_failure on noop_signal_windows'); }
      for (let page = 0; page < 8 && !(await get(manifest.objectId)).durability_receipt; page++)
        await reconcileIntake(db.rest, bucket.raw, 1);
      const saved = await get(manifest.objectId), receipt = saved.durability_receipt;
      assert.equal(receipt.state, 'verified_indexed'); assert.equal(receipt.ownerUserId, fixture.ownerUserId);
      assert.equal(receipt.deviceId, noopDeviceId(fixture.ownerUserId, fixture.deviceId));
      assert.equal(receipt.sourceId, fixture.sourceId); assert.equal(receipt.objectId, manifest.objectId);
      assert.equal(receipt.batchId, manifest.batchId); assert.equal(receipt.stream, manifest.stream);
      assert.equal(receipt.contentSha256, manifest.contentSha256); assert.equal(receipt.wireSha256, sha256Hex(wire));
      assert.equal(receipt.uncompressedBytes, files['payload.npb1'].length); assert.equal(receipt.compressedBytes, wire.length);
      assert.deepEqual(bucket.objects.get(receipt.objectKey), wire);
      const [window] = await db.rest.select('noop_signal_windows', `object_id=eq.${manifest.objectId}`);
      assert.equal(window.received_records, manifest.sampleCount); assert.equal(window.interpolated_records, 0);
      for (const key of ['expected_records', 'missing_records', 'coverage']) assert.equal(window[key], null);
      const revision = await db.sql('select sum(input_revision) from scoring_jobs_v2');
      for (const ack of await Promise.all([objects.createIntent({ userId: fixture.ownerUserId, manifest }),
        objects.completeObject({ userId: fixture.ownerUserId, objectId: manifest.objectId })]))
        assert.deepEqual(ack.durabilityReceipt, receipt);
      assert.equal(await db.sql('select sum(input_revision) from scoring_jobs_v2'), revision);
      const own = await db.request(`object_manifests?id=eq.${manifest.objectId}`, 'authenticated', fixture.ownerUserId);
      const other = await db.request(`object_manifests?id=eq.${manifest.objectId}`, 'authenticated', USER_B);
      assert.equal(own.status, 200); assert.equal(own.body.length, 1);
      assert.equal(other.status, 200); assert.equal(other.body.length, 0);
      assert.equal((await db.rest.select('noop_projection_debt', `object_id=eq.${manifest.objectId}`)).length, 0);
      assert.equal(saved.expires_at, null);
      return { receipt, window, recovered: bucket.objects.get(receipt.objectKey)! };
    }

    for (const sample of fixture.cases) await t.step(`${sample.origin}: exact imf1 provenance and recoverable archive`, async () => {
      const { files, manifest } = await readCase(sample.origin, sample.files);
      assert.equal(manifest.objectId, sample.objectId); assert.equal(manifest.batchId, sample.batchId);
      const before = exactArchive(files['payload.zst']);
      assert.equal(before.archiveId, sample.archiveBatchId); assert.equal(before.descriptor.origin, sample.origin);
      assert.equal(before.descriptor.ownerNamespace, fixture.ownerNamespace);
      assert.equal(before.descriptor.sourceId, fixture.sourceId); assert.equal(before.descriptor.device, fixture.deviceId);
      assert.equal(before.descriptor.recordCount, sample.recordCount);
      assert.equal(before.descriptor.prefixBytes, 0); assert.equal(before.descriptor.prefixRecords, 0);
      assert.deepEqual(before.descriptorBytes, files['descriptor.json']); assert.deepEqual(before.file, files['source.imus']);
      const member = before.descriptor.members[0]; assert.ok(!members.has(member.rowID));
      members.set(member.rowID, { origin: sample.origin, window: before.descriptor.window, ts: before.ts, columns: before.columns });
      const received = await receive(manifest, files), after = exactArchive(received.recovered);
      assert.deepEqual(after.descriptorBytes, before.descriptorBytes); assert.deepEqual(after.file, before.file);
      proof.origins.push({ origin: sample.origin, archiveId: before.archiveId, receipt: received.receipt,
        descriptorSHA256: sha256Hex(before.descriptorBytes), fileSHA256: sha256Hex(before.file), window: received.window });
    });
    await t.step('rawImuSession: both same-second kind4 row identities match exact origin descriptors', async () => {
      const { files, manifest } = await readCase('rawImuSession', fixture.rawImuSession.files);
      assert.equal(manifest.objectId, fixture.rawImuSession.objectId); assert.equal(manifest.batchId, fixture.rawImuSession.batchId);
      const before = rawMembers(files['payload.zst']);
      assert.equal(before.records.length, 2); assert.equal(new Set(before.records.map((r) => r.ts)).size, 1);
      for (const row of before.records) {
        const member = members.get(row.rowId)!; assert.ok(member);
        assert.equal(row.ts, member.ts); assert.deepEqual(row.columns, member.columns);
        proof.rawMembers.push({ rowId: row.rowId, ts: row.ts, origin: member.origin, window: member.window, columnsSHA256: sha256Hex(row.columns) });
      }
      const received = await receive(manifest, files);
      assert.deepEqual(rawMembers(received.recovered), before);
      proof.rawReceipt = received.receipt; proof.rawWindow = received.window;
      assert.equal(await db.sql('select count(*) from noop_hr_samples'), '0');
    });
    await Deno.writeTextFile(`${db.base}/android-imu-receiver-proof.json`, JSON.stringify(proof, null, 2));
    console.log(`Actual Android IMU proof: ${db.base}/android-imu-receiver-proof.json`);
  } finally { await bucket.close(); await db.close(); }
});
