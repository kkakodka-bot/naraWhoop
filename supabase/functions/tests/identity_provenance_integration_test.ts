import assert from 'node:assert/strict';
import { gzipSync, gunzipSync } from 'node:zlib';
import { createPushObjects } from '../_shared/objects.ts';
import { createPushArchive, createPushIngest } from '../_shared/ingest.ts';
import { createPushWalStore } from '../_shared/wal.ts';
import { registerDevice, reconcileIntake } from '../_shared/durability.ts';
import { commitArchivedBatch, reconcileProjections } from '../_shared/projections.ts';
import { sweepExpiredManifests } from '../_shared/workers.ts';
import { sha256Hex } from '../_shared/s3.ts';
import { startLocalPostgres, USER_A, USER_B } from './local_postgres.ts';
import { startObjectHttp } from './local_objects.ts';
import { buildIngestVerifyReport } from '../_shared/ingestVerify.ts';

const DEVICE = '33333333-3333-4333-8333-333333333333';
const SOURCE = '44444444-4444-4444-8444-444444444444';
const SECOND = 1_790_000_000;
const provenance = { v: 1, origin: 'whoop-v18', recordIndex: 25443699,
  frameSHA256: 'f33c461502c48aa493723f437268fbe88b2d08e25b7c73deedd427544b8a9ade' };

function auxiliaryFixture(unsupported = false, seconds = [SECOND, SECOND, SECOND]) {
  assert.equal(seconds.length, 3);
  const packed = [0x4e, 0x50, 0x42, 0x31, 2, 2, 3, 0, 0, 0];
  const int = (value: number, size: number) => {
    const bytes = new Uint8Array(size), v = new DataView(bytes.buffer);
    if (size === 8) v.setBigInt64(0, BigInt(value), true); else v.setUint32(0, value, true);
    packed.push(...bytes);
  };
  for (const [row, index] of [0, 4294967295, null].entries()) {
    int(row + 1, 8); int(seconds[row], 8); packed.push(index == null ? 0 : 1);
    if (index != null) int(index, 8);
    const fields = index == null ? [2, 2, 0, 0, 0, 1] : [2, 1, 0, 0, 0, ...new Uint8Array(4).map((_, i) => (index >>> (8 * i)) & 255)];
    if (unsupported && row === 2) fields[0] = 3;
    int(fields.length, 4); packed.push(...fields);
  }
  const payload = Uint8Array.from(packed), wire = new Uint8Array(gzipSync(payload));
  return { payload, wire, manifest: { type: 'binaryObject', protocolVersion: '1.4', schemaVersion: 2,
    stream: 'v18AuxSample', deviceId: DEVICE, sourceId: SOURCE, objectId: crypto.randomUUID(), batchId: crypto.randomUUID(),
    startTs: Math.min(...seconds), endTs: Math.max(...seconds) + 1, sampleCount: 3, compressedBytes: wire.length,
    uncompressedBytes: payload.length, contentSha256: sha256Hex(payload), contentEncoding: 'gzip' } };
}

Deno.test('070 native receiver: provenance, auxiliary identity debt, transaction recovery and actual RLS', async (t) => {
  const db = await startLocalPostgres({ auxiliaryIdentity: true });
  const bucket = startObjectHttp();
  const cfg: any = { b2KeyId: 'fixture', b2ApplicationKey: 'fixture', b2Bucket: 'fixture', rawStore: 'b2' };
  const objects = createPushObjects({ cfg, rest: db.rest, raw: bucket.raw });
  const archive = createPushArchive({ cfg, rest: db.rest, raw: bucket.raw });
  const ingest = (fault = false) => createPushIngest({ walStore: createPushWalStore({ rest: db.rest })!,
    ensureDevice: (row) => registerDevice(db.rest, row), archiveObject: (args) => archive.archiveObject(args),
    commitProjection: (receipt, bytes) => { if (fault) throw new Error('fixture_after_archive'); return commitArchivedBatch(db.rest, receipt, bytes); } });
  const get = async (id: string) => (await db.rest.select('object_manifests', `id=eq.${id}`))[0];
  const validation = async (id: string) => (await db.rest.select('noop_aux_object_validation', `object_id=eq.${id}`))[0];
  const proof: unknown[] = [];
  async function upload(f = auxiliaryFixture()) {
    const intent = await objects.createIntent({ userId: USER_A, manifest: f.manifest });
    const sent = await fetch(intent.uploadUrl!, { method: 'PUT', body: f.wire, headers: intent.requiredHeaders });
    await sent.body?.cancel(); assert.equal(sent.status, 200); return { ...f, intent };
  }
  try {
    await t.step('three scalar schema2 receipts preserve exact provenance through server-only replay', async () => {
      const cases = [
        ['stepSample', 'noop_step_samples', { counter: 65535, activityClass: null }],
        ['sleepStateSample', 'noop_sleep_state_samples', { state: 3, rawByte: 48 }],
        ['ppgHrSample', 'noop_ppg_hr_samples', { bpm: 72, conf: null }],
      ] as const;
      for (const [i, [stream, table, data]] of cases.entries()) {
        const p = stream === 'ppgHrSample' ? { v: 1, origin: 'whoop-v26-ppg-derived', algorithm: 'ppg-acf-v1',
          sampleRateHz: 24, windowSettingSeconds: 8, inputStartTs: 100, inputEndTs: 102,
          inputSHA256: 'c0c4d0701eb3741fd07bd4a62d2cc23f6caccc91819f927e7df30ab07ef66ac4' } : provenance;
        const header = { type: 'batch', protocolVersion: '1.4', schemaVersion: 2, stream, deviceId: DEVICE,
          sourceId: SOURCE, batchId: crypto.randomUUID(), delivery: 'append', recordCount: 1 };
        const bytes = (h = header, pr: unknown = p) => new TextEncoder().encode([h,
          { type: 'record', key: { ts: SECOND + i }, data: { ...data, provenance: pr } }].map((v) => JSON.stringify(v)).join('\n') + '\n');
        const body = bytes();
        await assert.rejects(ingest(true).acceptBatch({ userId: USER_A, decodedBody: body }), /fixture_after_archive/);
        assert.equal((await get(header.batchId)).durability_receipt.schemaVersion, 2);
        assert.equal((await db.rest.select(table, `ts=eq.${SECOND + i}`)).length, 0);
        assert.equal((await reconcileProjections(db.rest, bucket.raw, 1)).settled, 1);
        const row = (await db.rest.select(table, `ts=eq.${SECOND + i}`))[0]; assert.deepEqual(row.provenance, p);
        const ack = await ingest().acceptBatch({ userId: USER_A, decodedBody: body });
        assert.equal(ack.protocolVersion, '1.4'); assert.equal(ack.durabilityReceipt.schemaVersion, 2);
        assert.deepEqual(new Uint8Array(gunzipSync(bucket.objects.get(ack.durabilityReceipt.objectKey)!)), body);
        const before = bucket.objects.size;
        await assert.rejects(ingest().acceptBatch({ userId: USER_A, decodedBody: bytes({ ...header, protocolVersion: '1.3', schemaVersion: 1 }) }), /invalid_scalar_provenance/);
        await assert.rejects(ingest().acceptBatch({ userId: USER_A, decodedBody: bytes(header, { ...p, extra: 1 }) }), /invalid_scalar_provenance/);
        assert.equal(bucket.objects.size, before);
        const invalid = await db.rest.rpc('noop_valid_scalar_provenance', { p: { ...p, extra: 1 } }); assert.equal(invalid, false);
        await assert.rejects(db.rest.upsert(table, [{ ...row, ts: SECOND + 100 + i, provenance: { ...p, extra: 1 } }], { onConflict: 'user_id,device_id,ts' }), /provenance_valid/);
        const conflictHeader = { ...header, batchId: crypto.randomUUID() };
        await assert.rejects(ingest().acceptBatch({ userId: USER_A, decodedBody: bytes(conflictHeader, null) }), /scalar_identity_conflict/);
        assert.deepEqual((await db.rest.select(table, `ts=eq.${SECOND + i}`))[0].provenance, p);
        await db.sql(`update noop_projection_debt set not_before=clock_timestamp()+interval '1 hour' where object_id='${conflictHeader.batchId}'`);
        proof.push({ stream, receipt: ack.durabilityReceipt, provenance: p });
      }
    });
    await t.step('auxiliary siblings zero/u32max/unknown retain exact bytes with one validated atomic receipt', async () => {
      const f = await upload();
      const [a, b] = await Promise.all([objects.completeObject({ userId: USER_A, objectId: f.manifest.objectId }),
        objects.completeObject({ userId: USER_A, objectId: f.manifest.objectId })]);
      assert.deepEqual(a.durabilityReceipt, b.durabilityReceipt);
      assert.equal(a.durabilityReceipt.schemaVersion, 2); assert.equal(a.protocolVersion, '1.4');
      assert.deepEqual(bucket.objects.get(a.objectKey), f.wire);
      const v = await validation(f.manifest.objectId);
      assert.equal(v.state, 'validated'); assert.equal(v.validation.records, 3); assert.equal(v.validation.unknownIdentityRecords, 1);
      assert.equal(v.content_sha256, a.durabilityReceipt.contentSha256);
      assert.equal((await db.rest.select('noop_signal_windows', `object_id=eq.${f.manifest.objectId}`)).length, 1);
      assert.equal((await db.rest.select('noop_projection_debt', `object_id=eq.${f.manifest.objectId}`)).length, 0);
      for (const user of [USER_A, USER_B]) {
        const read = await db.request(`noop_aux_object_validation?object_id=eq.${f.manifest.objectId}`, 'authenticated', user);
        assert.equal(read.status, 200); assert.equal(read.body.length, user === USER_A ? 1 : 0);
        assert.equal((await db.request('noop_aux_object_validation', 'authenticated', user, 'POST', v)).status, 403);
        const call = await db.request('rpc/noop_commit_aux_object_receipt', 'authenticated', user, 'POST', {
          p_user_id: USER_A, p_object_id: f.manifest.objectId, p_verified_key: a.objectKey,
          p_wire_sha256: v.wire_sha256, p_content_sha256: v.content_sha256,
          p_compressed_bytes: f.wire.length, p_uncompressed_bytes: f.payload.length, p_validation: v.validation });
        assert.equal(call.status, 403);
      }
      proof.push({ receipt: a.durabilityReceipt, validation: v.validation });
    });
    await t.step('auxiliary identity count never claims time coverage, including sibling gaps and legacy receipt repair', async () => {
      for (const seconds of [[SECOND, SECOND, SECOND + 2], [SECOND, SECOND + 1, SECOND + 2]]) {
        const f = await upload(auxiliaryFixture(false, seconds));
        const ack = await objects.completeObject({ userId: USER_A, objectId: f.manifest.objectId });
        const checkWindow = async () => {
          const rows = await db.rest.select('noop_signal_windows', `object_id=eq.${f.manifest.objectId}`);
          assert.equal(rows.length, 1);
          assert.equal(rows[0].received_records, 3);
          assert.equal(rows[0].start_ts, SECOND);
          assert.equal(rows[0].end_ts, SECOND + 3);
          assert.equal(rows[0].expected_records, null);
          assert.equal(rows[0].missing_records, null);
          assert.equal(rows[0].coverage, null);
        };
        await checkWindow();
        assert.equal((await validation(f.manifest.objectId)).validation.records, 3);
        assert.deepEqual(bucket.objects.get(ack.objectKey), f.wire);
        // The old service entrypoint can rebuild an index from an existing validated receipt.
        // It must not recreate the inherited records-per-second assumption on that path either.
        await db.sql(`delete from noop_signal_windows where object_id='${f.manifest.objectId}'`);
        const repaired = await db.rest.rpc('noop_commit_object_receipt', {
          p_user_id: USER_A, p_object_id: f.manifest.objectId, p_verified_key: ack.objectKey,
          p_wire_sha256: ack.durabilityReceipt.wireSha256,
          p_content_sha256: ack.durabilityReceipt.contentSha256,
          p_compressed_bytes: f.wire.length, p_uncompressed_bytes: f.payload.length });
        assert.deepEqual(repaired, ack.durabilityReceipt);
        await checkWindow();
      }
    });
    await t.step('auxiliary index failure rolls validation/receipt back; server-only reconcile recovers', async () => {
      const f = await upload();
      await db.sql(`create function fixture_aux_index_failure() returns trigger language plpgsql as $$begin raise exception 'fixture_aux_index'; end$$;
        create trigger fixture_aux_index_failure before insert on noop_signal_windows for each row execute function fixture_aux_index_failure();`);
      await assert.rejects(objects.completeObject({ userId: USER_A, objectId: f.manifest.objectId }), /fixture_aux_index/);
      assert.equal(await validation(f.manifest.objectId), undefined); assert.equal((await get(f.manifest.objectId)).durability_receipt, null);
      await db.sql('drop trigger fixture_aux_index_failure on noop_signal_windows');
      for (let page = 0; page < 10 && !(await get(f.manifest.objectId)).durability_receipt; page++) await reconcileIntake(db.rest, bucket.raw, 2);
      assert.equal((await get(f.manifest.objectId)).durability_receipt.state, 'verified_indexed');
      assert.equal((await validation(f.manifest.objectId)).state, 'validated');
    });
    await t.step('PPG format2 bytes and schema2 remain unchanged under protocol1.3 and1.4', async () => {
      const hex = '4e5042310201010000000100000000000000803bb16a0000000001000000000000000000020000000100';
      const payload = Uint8Array.from(hex.match(/../g)!, (pair) => parseInt(pair, 16));
      const wire = new Uint8Array(gzipSync(payload));
      for (const version of ['1.3', '1.4']) {
        const f = auxiliaryFixture();
        const manifest = { ...f.manifest, protocolVersion: version, stream: 'ppgWaveformSample', sampleCount: 1,
          compressedBytes: wire.length, uncompressedBytes: payload.length, contentSha256: sha256Hex(payload) };
        const intent = await objects.createIntent({ userId: USER_A, manifest });
        const sent = await fetch(intent.uploadUrl!, { method: 'PUT', headers: intent.requiredHeaders, body: wire });
        await sent.body?.cancel(); assert.equal(sent.status, 200);
        const ack = await objects.completeObject({ userId: USER_A, objectId: manifest.objectId });
        assert.equal(ack.durabilityReceipt.schemaVersion, 2); assert.equal(ack.durabilityReceipt.contentSha256, sha256Hex(payload));
        assert.deepEqual(bucket.objects.get(ack.objectKey), wire);
      }
    });
    await t.step('unsupported fields archive remains exact, typed debt is visible and retention holds it', async () => {
      const f = await upload(auxiliaryFixture(true));
      const ack = await objects.completeObject({ userId: USER_A, objectId: f.manifest.objectId });
      assert.deepEqual(bucket.objects.get(ack.objectKey), f.wire);
      const v = await validation(f.manifest.objectId); assert.equal(v.state, 'pending');
      assert.equal(v.validation.unsupportedFieldsRecords, 1);
      const report = await buildIngestVerifyReport({ rest: db.rest, objectStore: bucket.raw, userId: USER_A,
        day: new Date(SECOND * 1000).toISOString().slice(0, 10) });
      assert.equal(report.first_incomplete_stage, 'auxiliary_validation');
      assert.equal(report.auxiliary_validation.find((v: any) => v.object_id === f.manifest.objectId)?.state, 'pending');
      await db.rest.patch('object_manifests', { expires_at: '2000-01-01T00:00:00Z' }, `id=eq.${f.manifest.objectId}`);
      await sweepExpiredManifests({ rest: db.rest, objectStore: bucket.raw });
      assert.equal((await get(f.manifest.objectId)).status, 'ready'); assert(bucket.objects.has(ack.objectKey));
      proof.push({ receipt: ack.durabilityReceipt, validation: v.validation, retentionHeld: true });
    });
    await t.step('complete supported blob identity mismatch never publishes receipt or index', async () => {
      const f = auxiliaryFixture(); f.payload[27] = 1;
      f.wire = new Uint8Array(gzipSync(f.payload)); f.manifest.compressedBytes = f.wire.length; f.manifest.contentSha256 = sha256Hex(f.payload);
      await upload(f);
      await assert.rejects(objects.completeObject({ userId: USER_A, objectId: f.manifest.objectId }), /aux_fields_identity_mismatch/);
      assert.equal((await get(f.manifest.objectId)).durability_receipt, null); assert.equal(await validation(f.manifest.objectId), undefined);
      assert.equal((await db.rest.select('noop_signal_windows', `object_id=eq.${f.manifest.objectId}`)).length, 0);
    });
    await Deno.writeTextFile(`${db.base}/identity-provenance-proof.json`, JSON.stringify(proof, null, 2));
    console.log(`070 proof: ${db.base}/identity-provenance-proof.json`);
  } finally { await bucket.close(); await db.close(); }
});
