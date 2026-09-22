import assert from 'node:assert/strict';
import { createPushArchive, createPushIngest } from '../_shared/ingest.ts';
import { createPushWalStore } from '../_shared/wal.ts';
import { registerDevice } from '../_shared/durability.ts';
import { commitArchivedBatch } from '../_shared/projections.ts';
import { scopedExternalDeviceId } from '../_shared/devices.ts';
import { noopDeviceId } from '../_shared/keys.ts';
import { startLocalPostgres, USER_A } from './local_postgres.ts';
import { startObjectHttp } from './local_objects.ts';
import { createPushObjects } from '../_shared/objects.ts';
import { gzipSync } from 'node:zlib';
import { sha256Hex } from '../_shared/s3.ts';

Deno.test('enrolled upload preserves canonical device through WAL, archive, projection and durable replay', async () => {
  const db = await startLocalPostgres({ scalarProjections: true, installationLifecycle: true });
  const bucket = startObjectHttp();
  try {
    const source = '44444444-4444-4444-8444-444444444444';
    const enrollmentCode = crypto.randomUUID();
    await db.sql(`insert into noop_enrollment_codes(id,user_id,code_hash,expires_at)
      values('${enrollmentCode}','${USER_A}',repeat('a',64),now()+interval '1 day');
      insert into noop_app_installations(source_id,user_id,enrollment_code_id,platform,app_version)
      values('${source}','${USER_A}','${enrollmentCode}','ios','fixture');`);
    const external = 'my-whoop';
    const scoped = scopedExternalDeviceId(external, source);
    const device = noopDeviceId(USER_A, scoped);
    assert.notEqual(device, noopDeviceId(USER_A, external));
    const archive = createPushArchive({ rest: db.rest, raw: bucket.raw,
      cfg: { b2KeyId: 'fixture', b2ApplicationKey: 'fixture', b2Bucket: 'fixture', rawStore: 'b2' } as any });
    const accepted: any[] = [];
    const ingest = createPushIngest({
      walStore: createPushWalStore({ rest: db.rest })!,
      archiveObject: archive.archiveObject,
      resolveDeviceId: async () => {
        await registerDevice(db.rest, { id: device, user_id: USER_A, external_device_id: scoped });
        return device;
      },
      commitProjection: (receipt, bytes) => commitArchivedBatch(db.rest, receipt, bytes),
      receiptStore: { configured: true, recordAccepted: async (receipt) => {
        accepted.push(receipt);
        return receipt;
      } },
    });
    const batch = crypto.randomUUID();
    const header = { type: 'batch', protocolVersion: '1.1', stream: 'hrSample',
      deviceId: external, sourceId: source, batchId: batch, endCursor: { ts: 1790000000 },
      delivery: 'append', recordCount: 1 };
    const bytes = new TextEncoder().encode([header,
      { type: 'record', key: { ts: 1790000000 }, data: { bpm: 61 } },
    ].map((row) => JSON.stringify(row)).join('\n') + '\n');
    const request = { userId: USER_A, sourceId: source, tokenId: null,
      authMode: 'installation' as const, decodedBody: bytes };
    const ack = await ingest.acceptBatch(request);
    assert.equal(ack.durabilityReceipt.deviceId, device);
    assert.equal(ack.durabilityReceipt.state, 'verified_indexed');
    assert.equal(ack.acceptedRows, 1);
    assert.equal(accepted.length, 1);
    assert.equal(accepted[0].deviceId, device);
    assert.equal(accepted[0].authMode, 'installation');
    assert.equal(await db.sql(`select device_id from noop_push_reservations where batch_id='${batch}'`), device);
    assert.equal(await db.sql(`select bpm from noop_hr_samples where device_id='${device}'`), '61');
    assert.equal(await db.sql(`select state from noop_projection_debt where object_id='${batch}'`), 'complete');
    assert.deepEqual(await ingest.acceptBatch(request), ack);
    assert.equal(accepted.length, 2);
    assert.equal(await db.sql(`select count(*) from noop_hr_samples where device_id='${device}'`), '1');
    assert.equal(await db.sql(`select count(*) from noop_push_wal where batch_id='${batch}'`), '0');
    await assert.rejects(ingest.acceptBatch({ ...request, sourceId: crypto.randomUUID() }), /source_id_mismatch/);
    const forged = { ...ack.durabilityReceipt, deviceId: crypto.randomUUID() };
    // A settled receipt cannot be substituted: the returned DB receipt must match exactly.
    await assert.rejects(commitArchivedBatch(db.rest, forged, bytes), /projection_ack_mismatch/);

    const objects = createPushObjects({ rest: db.rest, raw: bucket.raw,
      cfg: { b2KeyId: 'fixture', b2ApplicationKey: 'fixture', b2Bucket: 'fixture', rawStore: 'b2' } as any,
      resolveDeviceId: async () => device });
    const rawBytes = new TextEncoder().encode('synthetic raw archive');
    const wire = new Uint8Array(gzipSync(rawBytes));
    const manifest = { type: 'binaryObject', protocolVersion: '1.2', stream: 'ppgWaveformSample',
      deviceId: external, sourceId: source, objectId: crypto.randomUUID(), batchId: crypto.randomUUID(),
      startTs: 1790000000, endTs: 1790000001, sampleCount: 1,
      uncompressedBytes: rawBytes.length, compressedBytes: wire.length,
      contentSha256: sha256Hex(rawBytes), contentEncoding: 'gzip' };
    const identity = { userId: USER_A, sourceId: source, authMode: 'installation' as const };
    const intent = await objects.createIntent({ ...identity, manifest });
    const upload = await fetch(intent.uploadUrl!, { method: 'PUT', body: wire });
    await upload.body?.cancel();
    assert.equal(upload.status, 200);
    const complete = await objects.completeObject({ ...identity, objectId: manifest.objectId });
    const retry = await objects.createIntent({ ...identity, manifest });
    assert.equal(retry.duplicate, true);
    assert.equal(retry.uploadUrl, undefined);
    assert.deepEqual(retry.durabilityReceipt, complete.durabilityReceipt);
    assert.equal(retry.durabilityReceipt!.deviceId, device);

    for (const field of ['activity_class', '"activityClass"']) {
      const ts = field === 'activity_class' ? 1790000002 : 1790000003;
      await db.sql(`insert into noop_step_samples(user_id,device_id,source_id,ts,counter,${field},batch_id)
        values('${USER_A}','${device}','${source}',${ts},100,2,'${crypto.randomUUID()}')`);
      assert.equal(await db.sql(`select activity_class||':'||"activityClass" from noop_step_samples where ts=${ts}`), '2:2');
    }
    await assert.rejects(db.sql(`insert into noop_step_samples(user_id,device_id,source_id,ts,counter,activity_class,"activityClass",batch_id)
      values('${USER_A}','${device}','${source}',1790000004,100,1,2,'${crypto.randomUUID()}')`), /step_activity_schema_conflict/);
    await assert.rejects(db.sql(`update noop_step_samples set "activityClass"=1 where ts=1790000003`), /scalar_identity_conflict/);
  } finally {
    await bucket.close();
    await db.close();
  }
});
