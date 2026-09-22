import assert from 'node:assert/strict';
import { gzipSync } from 'node:zlib';
import { sha256Hex } from '../_shared/s3.ts';
import { createPushObjects } from '../_shared/objects.ts';
import { createPushArchive, createPushIngest } from '../_shared/ingest.ts';
import { createPushWalStore } from '../_shared/wal.ts';
import { registerDevice, reconcileIntake } from '../_shared/durability.ts';
import { commitArchivedBatch, reconcileProjections } from '../_shared/projections.ts';
import { sweepExpiredManifests } from '../_shared/workers.ts';
import { startLocalPostgres, USER_A, USER_B } from './local_postgres.ts';
import { compressFor } from './helpers.ts';
import { startObjectHttp } from './local_objects.ts';

const DEVICE = '33333333-3333-4333-8333-333333333333';
const SOURCE = '44444444-4444-4444-8444-444444444444';
const SECOND = 1_790_000_000;

function objectFixture(over: Record<string, unknown> = {}) {
  // Exact NPB1 PPG v2 layout from PushBinaryCodec: rowId, ts, optional i64 recordIndex,
  // optional i32 burstIndex, length-prefixed samples. Unknown identity has presence flag 0.
  const packed = [0x4e,0x50,0x42,0x31,2,1,3,0,0,0];
  const i64 = (value: number) => { const b = new Uint8Array(8); new DataView(b.buffer).setBigInt64(0,BigInt(value),true); packed.push(...b); };
  for (const [rowId,index] of [[1,101],[2,102],[3,null]]) {
    i64(rowId!); i64(SECOND);
    packed.push(index == null ? 0 : 1); if (index != null) i64(index);
    packed.push(0,2,0,0,0,rowId!,rowId!+1);
  }
  const payload = Uint8Array.from(packed);
  const wire = new Uint8Array(gzipSync(payload));
  const manifest = {
    type: 'binaryObject', protocolVersion: '1.3', stream: 'ppgWaveformSample',
    deviceId: DEVICE, objectId: crypto.randomUUID(), batchId: crypto.randomUUID(), sourceId: SOURCE,
    startTs: SECOND, endTs: SECOND + 2, sampleCount: 3,
    uncompressedBytes: payload.length, compressedBytes: wire.length,
    contentSha256: sha256Hex(payload), contentEncoding: 'gzip', ...over,
  };
  return { manifest, payload, wire };
}

Deno.test('native intake durability: PostgreSQL, PostgREST roles, and loopback object HTTP', async (t) => {
  const db = await startLocalPostgres();
  const bucket = startObjectHttp();
  const cfg: any = { b2KeyId: 'fixture', b2ApplicationKey: 'fixture', b2Bucket: 'fixture', rawStore: 'b2' };
  const objects = createPushObjects({ cfg, rest: db.rest, raw: bucket.raw });
  const get = async (id: string) => (await db.rest.select('object_manifests', `id=eq.${id}&select=*`))[0];
  async function upload(fixture = objectFixture()) {
    const intent = await objects.createIntent({ userId: USER_A, manifest: fixture.manifest });
    const response = await fetch(intent.uploadUrl!, { method: 'PUT', body: fixture.wire, headers: intent.requiredHeaders });
    await response.body?.cancel(); assert.equal(response.status, 200);
    return { ...fixture, intent };
  }
  let completed: Awaited<ReturnType<typeof upload>>;
  function inline(ts: number, bpm = 60, over: Record<string, unknown> = {}) {
    const header = { type: 'batch', protocolVersion: '1.1', stream: 'hrSample', deviceId: DEVICE,
      sourceId: SOURCE, batchId: crypto.randomUUID(), delivery: 'append', recordCount: 1, ...over };
    const body = new TextEncoder().encode([header,{ type: 'record', key: { ts }, data: { bpm } }]
      .map((row) => JSON.stringify(row)).join('\n')+'\n');
    return { header, body };
  }
  function nativeIngest(commit = (receipt: any, body: Uint8Array) => commitArchivedBatch(db.rest,receipt,body)) {
    return createPushIngest({ walStore: createPushWalStore({ rest: db.rest })!,
      archiveObject: (args) => createPushArchive({ cfg, rest: db.rest, raw: bucket.raw }).archiveObject(args),
      ensureDevice: (row) => registerDevice(db.rest,row), commitProjection: commit });
  }
  const inputRevision = () => db.sql('select sum(input_revision) from scoring_jobs_v2');
  try {
    await t.step('immutable owner registration precedes object writes', async () => {
      await registerDevice(db.rest, { id: DEVICE, user_id: USER_A, external_device_id: DEVICE });
      const f = objectFixture();
      await assert.rejects(objects.createIntent({ userId: USER_B, manifest: f.manifest }), /device_owner_conflict/);
      assert.equal(await get(f.manifest.objectId), undefined);
      assert.equal(bucket.objects.size, 0);
      await assert.rejects(db.rest.patch('devices', { user_id: USER_B }, `id=eq.${DEVICE}`), /device_owner_immutable/);
      assert.equal((await db.rest.select('devices', `id=eq.${DEVICE}`))[0].user_id, USER_A);
    });
    await t.step('digest and all immutable metadata reserve atomically', async () => {
      const f = objectFixture();
      const raced = await Promise.allSettled([
        objects.createIntent({ userId: USER_A, manifest: f.manifest }),
        objects.createIntent({ userId: USER_A, manifest: { ...f.manifest, contentSha256: 'b'.repeat(64) } }),
      ]);
      assert.equal(raced.filter((r) => r.status === 'fulfilled').length, 1);
      assert.equal(bucket.objects.size, 0);
      const row = await get(f.manifest.objectId);
      await assert.rejects(objects.createIntent({ userId: USER_A, manifest: { ...f.manifest, contentSha256: row.sha256, sampleCount: 99 } }), /object_id_conflict/);
    });
    await t.step('verified receipt binds stored size, both digests, owner and raw identity payload', async () => {
      completed = await upload();
      const ack = await objects.completeObject({ userId: USER_A, objectId: completed.manifest.objectId });
      const receipt = ack.durabilityReceipt;
      assert.equal(ack.protocolVersion, '1.3');
      assert.equal(receipt.version, 1); assert.equal(receipt.state, 'verified_indexed');
      assert.equal(receipt.ownerUserId, USER_A); assert.equal(receipt.deviceId, DEVICE);
      assert.equal(receipt.batchId, completed.manifest.batchId); assert.equal(receipt.sourceId, SOURCE);
      assert.equal(receipt.schemaVersion, 2); assert.equal(receipt.contentSha256, sha256Hex(completed.payload));
      assert.equal(receipt.wireSha256, sha256Hex(completed.wire));
      assert.equal(receipt.compressedBytes, completed.wire.length); assert.equal(receipt.uncompressedBytes, completed.payload.length);
      assert.notEqual(receipt.objectKey, completed.intent.objectKey);
      assert.deepEqual(bucket.objects.get(receipt.objectKey), new Uint8Array(completed.wire));
      const windows = await db.rest.select('noop_signal_windows', `object_id=eq.${receipt.objectId}`);
      assert.equal(windows.length, 1); assert.equal(windows[0].object_key, receipt.objectKey);
      const publishedAt = (await get(receipt.objectId)).updated_at;
      assert.deepEqual((await objects.completeObject({ userId: USER_A, objectId: receipt.objectId })).durabilityReceipt, receipt);
      assert.equal((await get(receipt.objectId)).updated_at, publishedAt, 'identical retry must not trigger a new input generation');
      const replay = await objects.createIntent({ userId: USER_A, manifest: completed.manifest });
      assert.equal(replay.uploadUrl, undefined); assert.deepEqual(replay.durabilityReceipt, receipt);
      await Deno.writeTextFile(`${db.base}/receipt-example.json`, JSON.stringify(ack,null,2));
    });
    await t.step('a still-valid staging PUT cannot replace the attested archive', async () => {
      const before = (await get(completed.manifest.objectId)).durability_receipt;
      const response = await fetch(completed.intent.uploadUrl!, { method: 'PUT', body: new Uint8Array(completed.wire.length) });
      await response.body?.cancel();
      const after = await objects.completeObject({ userId: USER_A, objectId: completed.manifest.objectId });
      assert.deepEqual(after.durabilityReceipt, before);
      assert.deepEqual(bucket.objects.get(after.objectKey), new Uint8Array(completed.wire));
    });
    await t.step('same-size wrong content, decoded size mismatch, and truncated uploads never get receipts', async () => {
      for (const mode of ['digest','decoded','truncated']) {
        const f = objectFixture(mode === 'digest' ? { contentSha256: '0'.repeat(64) } : mode === 'decoded' ? { uncompressedBytes: 1 } : {});
        if (mode === 'truncated') f.wire = f.wire.subarray(0, f.wire.length-1);
        const shipped = await upload(f);
        await assert.rejects(objects.completeObject({ userId: USER_A, objectId: shipped.manifest.objectId }), /digest_mismatch|decoded_size_mismatch|size_mismatch/);
        assert.equal((await get(shipped.manifest.objectId)).durability_receipt, null);
        assert.equal((await db.rest.select('noop_signal_windows', `object_id=eq.${shipped.manifest.objectId}`)).length, 0);
      }
    });
    await t.step('actual streamed byte count works with absent Content-Length; zstd is decoded', async () => {
      bucket.setOmitLength(true);
      try {
        const f = objectFixture({ stream: 'rawImuSession', contentEncoding: 'zstd' });
        f.wire = new Uint8Array(compressFor('zstd', f.payload));
        f.manifest.compressedBytes = f.wire.length;
        const shipped = await upload(f);
        assert.equal((await objects.completeObject({ userId: USER_A, objectId: shipped.manifest.objectId })).durabilityReceipt.contentSha256, sha256Hex(f.payload));
      } finally { bucket.setOmitLength(false); }
    });
    await t.step('COPY HTTP 200 error and index transaction failure recover without a phone reupload', async () => {
      const f = await upload();
      bucket.setFailCopy(true);
      await assert.rejects(objects.completeObject({ userId: USER_A, objectId: f.manifest.objectId }), /object copy failed/);
      bucket.setFailCopy(false);
      await db.sql(`create function public.fixture_index_failure() returns trigger language plpgsql as $$begin raise exception 'fixture_index_failure'; end$$;
        create trigger fixture_index_failure before insert on public.noop_signal_windows for each row execute function public.fixture_index_failure();`);
      await assert.rejects(objects.completeObject({ userId: USER_A, objectId: f.manifest.objectId }), /fixture_index_failure/);
      const failed = await get(f.manifest.objectId);
      assert.notEqual(failed.status, 'ready'); assert.equal(failed.durability_receipt, null);
      await db.sql('drop trigger fixture_index_failure on public.noop_signal_windows;');
      const races = await Promise.all([
        objects.completeObject({ userId: USER_A, objectId: f.manifest.objectId }),
        objects.completeObject({ userId: USER_A, objectId: f.manifest.objectId }),
      ]);
      assert.deepEqual(races[0].durabilityReceipt, races[1].durabilityReceipt);
      assert.equal((await db.rest.select('noop_signal_windows', `object_id=eq.${f.manifest.objectId}`)).length, 1);
    });
    await t.step('bounded persistent cursor repairs legacy ready rows and missing indexes', async () => {
      const legacy = await upload();
      await db.rest.patch('object_manifests', { status: 'ready' }, `id=eq.${legacy.manifest.objectId}`);
      await db.rest.delete('noop_signal_windows', `object_id=eq.${completed.manifest.objectId}`);
      const seenCursors = new Set();
      for (let page = 0; page < 20; page++) {
        const report = await reconcileIntake(db.rest, bucket.raw, 2);
        assert(report.scanned <= 2);
        const cursor = await db.sql('select coalesce(cursor_id::text,\'wrap\') from public.noop_intake_reconcile_state;');
        seenCursors.add(cursor);
        if (cursor === 'wrap') break;
      }
      assert(seenCursors.size > 2);
      assert.equal((await get(legacy.manifest.objectId)).durability_receipt.state, 'verified_indexed');
      assert.equal((await db.rest.select('noop_signal_windows', `object_id=eq.${completed.manifest.objectId}`)).length, 1);
    });
    await t.step('real authenticated and anon roles cannot forge receipts, call privileged RPCs, or read other owners', async () => {
      for (const table of ['object_manifests','noop_signal_windows','noop_push_reservations']) {
        const own = await db.request(`${table}?user_id=eq.${USER_A}`, 'authenticated', USER_A);
        assert.equal(own.status, 200);
        if (table !== 'noop_push_reservations') assert(own.body.length > 0);
        const other = await db.request(`${table}?user_id=eq.${USER_A}`, 'authenticated', USER_B);
        assert.equal(other.status, 200); assert.deepEqual(other.body, []);
        assert([401,403].includes((await db.request(table, 'anon')).status));
      }
      for (const role of ['anon','authenticated']) {
        const denied = await db.request('rpc/noop_register_push_device', role, USER_A, 'POST', {
          p_user_id: USER_A, p_device_id: DEVICE, p_external_device_id: DEVICE,
        });
        assert([401,403,404].includes(denied.status));
        const forge = await db.request(`object_manifests?id=eq.${completed.manifest.objectId}`, role, USER_A, 'PATCH', { durability_receipt: { state: 'verified_indexed' } });
        assert([401,403].includes(forge.status));
      }
      await assert.rejects(objects.completeObject({ userId: USER_B, objectId: completed.manifest.objectId }), /forbidden/);
    });
    await t.step('server-only replay repairs archive-to-projection crash and invalidates a settled score', async () => {
      const archive = createPushArchive({ cfg, rest: db.rest, raw: bucket.raw });
      const wal = createPushWalStore({ rest: db.rest })!;
      const batchId = crypto.randomUUID();
      const header = { type: 'batch', protocolVersion: '1.1', stream: 'hrSample', deviceId: DEVICE, sourceId: SOURCE, batchId,
        endCursor: { rowId: 42, ts: SECOND, nested: { longerKey: true, a: [2, 3] } }, delivery: 'append', recordCount: 1 };
      const body = (bpm: number) => new TextEncoder().encode([header,{ type: 'record', key: { ts: SECOND }, data: { bpm } }].map((row) => JSON.stringify(row)).join('\n')+'\n');
      const common = { walStore: wal, archiveObject: (args: any) => archive.archiveObject(args), ensureDevice: (row: any) => registerDevice(db.rest,row),
        commitProjection: (receipt: any, body: Uint8Array) => commitArchivedBatch(db.rest, receipt, body) };
      const crashing = createPushIngest({ ...common, commitProjection: () => { throw new Error('fixture_projection_crash'); } });
      await assert.rejects(crashing.acceptBatch({ userId: USER_A, decodedBody: body(60) }), /fixture_projection_crash/);
      assert.equal((await db.rest.select('noop_push_acks', `batch_id=eq.${batchId}`)).length, 0);
      const saved = await get(batchId);
      assert.equal(saved.durability_receipt.state, 'verified_indexed');
      assert.equal((await db.rest.select('noop_hr_samples', `batch_id=eq.${batchId}`)).length, 0);
      assert.equal(await db.sql(`select state from noop_projection_debt where object_id='${batchId}'`), 'pending');
      // Publish genuine no-data snapshots using the real lease/revision RPCs, as a scorer can
      // legitimately settle the archive-index generation before the missing projection exists.
      for(let i=0;i<3;i++) {
        const [job]=await db.rest.rpc('claim_scoring_v2',{p_version:'frwhoop-server-1'});
        assert(job);
        assert(await db.rest.rpc('publish_scoring_snapshot_v2',{p_token:job.lease_token,p_revision:job.input_revision,
          p_payload:{status:'no_data',daily:null,sleep:[],coverage:{},dataThrough:null,timezone:'UTC'},p_duration_ms:1}));
      }
      const revision = await db.sql(`select sum(input_revision) from scoring_jobs_v2 where user_id='${USER_A}' and device_id='${DEVICE}'`);
      assert(Number(revision)>0, 'actual scoring triggers must be present');
      const report = await reconcileProjections(db.rest,bucket.raw,1);
      assert.equal(report.settled,1);
      assert.equal((await db.rest.select('noop_hr_samples', `batch_id=eq.${batchId}`))[0].bpm,60);
      assert(Number(await db.sql(`select sum(input_revision) from scoring_jobs_v2 where user_id='${USER_A}' and device_id='${DEVICE}'`))>Number(revision));
      assert.equal(await db.sql(`select count(*) from scoring_jobs_v2 where user_id='${USER_A}' and completed_revision<input_revision`),'3');
      assert.equal(await db.sql(`select state from noop_projection_debt where object_id='${batchId}'`),'complete');
      const ingest = createPushIngest(common);
      await assert.rejects(ingest.acceptBatch({ userId: USER_A, decodedBody: body(70) }), /batch_id_conflict/);
      assert.equal((await get(batchId)).sha256, saved.sha256);
      const ack = await ingest.acceptBatch({ userId: USER_A, decodedBody: body(60) });
      assert.equal(ack.durabilityReceipt?.state, 'verified_indexed');
      assert.deepEqual(ack.endCursor,header.endCursor);
      assert.deepEqual(await ingest.acceptBatch({ userId: USER_A, decodedBody: body(60) }), ack);
      assert.equal((await db.rest.select('noop_hr_samples', `batch_id=eq.${batchId}`)).length, 1);
      assert.equal((await db.rest.select('noop_push_reservations', `batch_id=eq.${batchId}`)).length, 1);
      assert.equal((await db.rest.select('noop_push_wal', `batch_id=eq.${batchId}`)).length, 0);
      const settledRevision = await db.sql('select sum(input_revision) from scoring_jobs_v2');
      assert.deepEqual(await commitArchivedBatch(db.rest,ack.durabilityReceipt,body(60)),ack);
      assert.equal((await reconcileProjections(db.rest,bucket.raw,1)).scanned,0);
      assert.equal(await db.sql('select sum(input_revision) from scoring_jobs_v2'),settledRevision);
    });
    await t.step('projection, scoring invalidation, ACK and debt roll back together then server replay recovers', async () => {
      const f = inline(SECOND+10);
      await db.sql(`create function fixture_projection_invalidation_failure() returns trigger language plpgsql as $$begin
        if new.reason='noop_hr_samples' then raise exception 'fixture_invalidation_failure'; end if; return new; end$$;
        create trigger fixture_projection_invalidation_failure before update on scoring_jobs_v2
          for each row execute function fixture_projection_invalidation_failure();`);
      let afterArchive = '';
      const ingest = nativeIngest(async (receipt,body) => {
        afterArchive=await inputRevision();
        return commitArchivedBatch(db.rest,receipt,body);
      });
      await assert.rejects(ingest.acceptBatch({userId:USER_A,decodedBody:f.body}),/fixture_invalidation_failure/);
      assert.equal(await inputRevision(),afterArchive);
      assert.equal((await db.rest.select('noop_hr_samples',`ts=eq.${SECOND+10}`)).length,0);
      assert.equal((await db.rest.select('noop_push_acks',`batch_id=eq.${f.header.batchId}`)).length,0);
      assert.equal(await db.sql(`select state from noop_projection_debt where object_id='${f.header.batchId}'`),'pending');
      assert.equal((await reconcileProjections(db.rest,bucket.raw,1)).deferred,1);
      assert.equal(await inputRevision(),afterArchive);
      await db.sql(`drop trigger fixture_projection_invalidation_failure on scoring_jobs_v2;
        update noop_projection_debt set not_before=clock_timestamp() where object_id='${f.header.batchId}';`);
      assert.equal((await reconcileProjections(db.rest,bucket.raw,1)).settled,1);
      assert.equal((await db.rest.select('noop_hr_samples',`ts=eq.${SECOND+10}`)).length,1);
      assert(Number(await inputRevision())>Number(afterArchive));
    });
    await t.step('lost settlement response and duplicate replay cannot overwrite a later correction or reinvalidate', async () => {
      const original = inline(SECOND+20,60);
      const ambiguousRest = { ...db.rest, rpc: async (name: string,args: unknown) => {
        const result = await db.rest.rpc(name,args);
        if(name==='noop_commit_push_projection') throw new Error('fixture_lost_committed_response');
        return result;
      }};
      await assert.rejects(nativeIngest((receipt,body)=>commitArchivedBatch(ambiguousRest,receipt,body))
        .acceptBatch({userId:USER_A,decodedBody:original.body}),/fixture_lost_committed_response/);
      assert.equal(await db.sql(`select state from noop_projection_debt where object_id='${original.header.batchId}'`),'complete');
      const receipt = (await get(original.header.batchId)).durability_receipt;
      const correction = inline(SECOND+20,75);
      await nativeIngest().acceptBatch({userId:USER_A,decodedBody:correction.body});
      const revision = await inputRevision();
      const duplicate = await commitArchivedBatch(db.rest,receipt,original.body);
      assert.equal(duplicate.batchId,original.header.batchId);
      assert.equal((await db.rest.select('noop_hr_samples',`ts=eq.${SECOND+20}`))[0].bpm,75);
      assert.equal(await inputRevision(),revision);
      assert.equal((await reconcileProjections(db.rest,bucket.raw,2)).scanned,0);
    });
    await t.step('older unprojected archive cannot overwrite a newer correction; stale lease is fenced', async () => {
      const older = inline(SECOND+30,60);
      await assert.rejects(nativeIngest(()=>{throw new Error('fixture_pre_projection');})
        .acceptBatch({userId:USER_A,decodedBody:older.body}),/fixture_pre_projection/);
      const first = await db.rest.rpc('noop_claim_projection_debt',{});
      assert.equal(first.manifest.id,older.header.batchId);
      await db.sql(`update noop_projection_debt set lease_until=clock_timestamp()-interval '1 second' where object_id='${older.header.batchId}'`);
      const next = await db.rest.rpc('noop_claim_projection_debt',{});
      assert.notEqual(first.leaseToken,next.leaseToken);
      await assert.rejects(commitArchivedBatch(db.rest,first.manifest.durability_receipt,older.body,first.leaseToken),/projection_lease_lost/);
      const newer = inline(SECOND+30,80);
      await nativeIngest().acceptBatch({userId:USER_A,decodedBody:newer.body});
      const revision = await inputRevision();
      await commitArchivedBatch(db.rest,next.manifest.durability_receipt,older.body,next.leaseToken);
      await db.rest.rpc('noop_fail_projection_debt',{p_object_id:older.header.batchId,p_token:first.leaseToken});
      assert.equal((await db.rest.select('noop_hr_samples',`ts=eq.${SECOND+30}`))[0].bpm,80);
      assert.equal(await inputRevision(),revision);
      assert.equal(await db.sql(`select state from noop_projection_debt where object_id='${older.header.batchId}'`),'complete');
    });
    await t.step('concurrent pending settlement commits one projection and one invalidation generation', async () => {
      const f=inline(SECOND+35);
      await assert.rejects(nativeIngest(()=>{throw new Error('fixture_pending_race');})
        .acceptBatch({userId:USER_A,decodedBody:f.body}),/fixture_pending_race/);
      const [a,b]=await Promise.all([db.rest.rpc('noop_claim_projection_debt',{}),db.rest.rpc('noop_claim_projection_debt',{})]);
      assert.equal([a,b].filter(Boolean).length,1);
      const job=a||b;
      const before=Number(await inputRevision());
      const [first,duplicate]=await Promise.all([
        commitArchivedBatch(db.rest,job.manifest.durability_receipt,f.body,job.leaseToken),
        commitArchivedBatch(db.rest,job.manifest.durability_receipt,f.body,job.leaseToken),
      ]);
      assert.deepEqual(first,duplicate);
      assert.equal(Number(await inputRevision())-before,3);
      assert.equal((await db.rest.select('noop_hr_samples',`batch_id=eq.${f.header.batchId}`)).length,1);
      assert.equal((await reconcileProjections(db.rest,bucket.raw,1)).scanned,0);
    });
    await t.step('bounded upgrade scan repairs indexed legacy debt; archive corruption never settles projections', async () => {
      const f = inline(SECOND+40);
      await assert.rejects(nativeIngest(()=>{throw new Error('fixture_pre_projection');})
        .acceptBatch({userId:USER_A,decodedBody:f.body}),/fixture_pre_projection/);
      const row = await get(f.header.batchId);
      await db.sql(`delete from noop_projection_debt where object_id='${f.header.batchId}'; update noop_projection_scan set cursor_id=null;`);
      const wire = bucket.objects.get(row.object_key)!;
      bucket.objects.set(row.object_key,new Uint8Array(wire.length));
      let sawFailure = false;
      for(let i=0;i<32;i++) {
        const report=await reconcileProjections(db.rest,bucket.raw,1);
        assert(report.scanned<=1);
        if(report.deferred) { sawFailure=true; break; }
      }
      assert(sawFailure);
      assert.equal((await db.rest.select('noop_hr_samples',`ts=eq.${SECOND+40}`)).length,0);
      bucket.objects.set(row.object_key,wire);
      await db.sql(`update noop_projection_debt set not_before=clock_timestamp() where object_id='${f.header.batchId}'`);
      assert.equal((await reconcileProjections(db.rest,bucket.raw,1)).settled,1);
    });
    await t.step('multipart replacement completes from archived final part without a phone and deletes atomically', async () => {
      const replacementId=crypto.randomUUID();
      const part=(number: number,question: string)=> {
        const header={ type:'batch',protocolVersion:'1.1',stream:'journal',deviceId:DEVICE,sourceId:SOURCE,
          batchId:crypto.randomUUID(),delivery:'replace_window',recordCount:1,
          window:{replacementId,selector:'day',startInclusive:'2026-09-18',endExclusive:'2026-09-19',part:number,parts:2} };
        const body=new TextEncoder().encode([header,{type:'record',key:{day:'2026-09-18',question},data:{answeredYes:true}}]
          .map(row=>JSON.stringify(row)).join('\n')+'\n');
        return {header,body};
      };
      await db.rest.upsert('noop_journal_entries',{user_id:USER_A,device_id:DEVICE,source_id:SOURCE,
        day:'2026-09-18',question:'old',answered_yes:false,batch_id:crypto.randomUUID(),replacement_id:crypto.randomUUID()},
        {onConflict:'user_id,device_id,day,question'});
      const first=part(1,'first'); const last=part(2,'last');
      const ack=await nativeIngest().acceptBatch({userId:USER_A,decodedBody:first.body});
      assert.equal(await db.sql(`select state from noop_projection_debt where object_id='${first.header.batchId}'`),'staged');
      await assert.rejects(nativeIngest(()=>{throw new Error('fixture_final_part_crash');})
        .acceptBatch({userId:USER_A,decodedBody:last.body}),/fixture_final_part_crash/);
      assert.equal((await db.rest.select('noop_journal_entries',`device_id=eq.${DEVICE}`)).length,1);
      assert.equal((await reconcileProjections(db.rest,bucket.raw,1)).settled,1);
      assert.deepEqual((await db.rest.select('noop_journal_entries',`device_id=eq.${DEVICE}&order=question.asc`)).map(r=>r.question),['first','last']);
      assert.equal(await db.sql(`select count(*) from noop_projection_debt where object_id in ('${first.header.batchId}','${last.header.batchId}') and state='complete'`),'2');
      assert.deepEqual(await commitArchivedBatch(db.rest,ack.durabilityReceipt,first.body),ack);
    });
    await t.step('projection debt and settlement RPCs deny real authenticated and anonymous roles', async () => {
      for(const role of ['authenticated','anon']) {
        for(const table of ['noop_projection_debt','noop_projection_scan','noop_projection_replacements','noop_projection_metrics']) {
          assert([401,403].includes((await db.request(table,role,USER_A)).status));
        }
        for(const [rpc,args] of [
          ['noop_claim_projection_debt',{}],['noop_seed_projection_debt',{p_limit:1}],
          ['noop_fail_projection_debt',{p_object_id:completed.manifest.objectId,p_token:crypto.randomUUID()}],
          ['noop_apply_projection_rows',{p_stream:'hrSample',p_rows:[]}],
          ['noop_commit_push_projection',{p_object_id:completed.manifest.objectId,p_body_sha256:'0'.repeat(64),p_header:{},p_rows:[],p_keep_keys:[]}],
        ] as const) assert([401,403,404].includes((await db.request(`rpc/${rpc}`,role,USER_A,'POST',args)).status));
      }
    });
    await t.step('delayed replacement replay preserves newer overlapping corrections and deletions', async () => {
      function journalWindow(start: string,end: string,records: {day:string;question:string}[]) {
        const header={type:'batch',protocolVersion:'1.1',stream:'journal',deviceId:DEVICE,sourceId:SOURCE,
          batchId:crypto.randomUUID(),delivery:'replace_window',recordCount:records.length,
          window:{replacementId:crypto.randomUUID(),selector:'day',startInclusive:start,endExclusive:end,part:1,parts:1}};
        const body=new TextEncoder().encode([header,...records.map(key=>({type:'record',key,data:{answeredYes:true}}))]
          .map(row=>JSON.stringify(row)).join('\n')+'\n');
        return {header,body};
      }
      const older=journalWindow('2026-09-28','2026-09-30',[
        {day:'2026-09-28',question:'outside'},{day:'2026-09-29',question:'obsolete'},
      ]);
      await assert.rejects(nativeIngest(()=>{throw new Error('fixture_old_window');})
        .acceptBatch({userId:USER_A,decodedBody:older.body}),/fixture_old_window/);
      const newer=journalWindow('2026-09-29','2026-10-01',[{day:'2026-09-29',question:'newer'}]);
      await nativeIngest().acceptBatch({userId:USER_A,decodedBody:newer.body});
      assert.equal((await reconcileProjections(db.rest,bucket.raw,1)).settled,1);
      const rows=await db.rest.select('noop_journal_entries',`user_id=eq.${USER_A}&day=gte.2026-09-28&order=day.asc`);
      assert.deepEqual(rows.map(row=>row.question),['outside','newer']);
      assert.equal(await db.sql(`select state from noop_projection_debt where object_id='${older.header.batchId}'`),'complete');
    });
    await t.step('retention holds the only archive while projection recovery is pending', async () => {
      const f=inline(SECOND+50);
      await assert.rejects(nativeIngest(()=>{throw new Error('fixture_before_projection');})
        .acceptBatch({userId:USER_A,decodedBody:f.body}),/fixture_before_projection/);
      const row=await get(f.header.batchId);
      await db.rest.patch('object_manifests',{expires_at:'2000-01-01T00:00:00Z'},`id=eq.${row.id}`);
      await sweepExpiredManifests({rest:db.rest,objectStore:bucket.raw});
      assert(bucket.objects.has(row.object_key));
      assert.equal((await get(row.id)).status,'ready');
      assert.equal((await reconcileProjections(db.rest,bucket.raw,1)).settled,1);
      await sweepExpiredManifests({rest:db.rest,objectStore:bucket.raw});
      assert(!bucket.objects.has(row.object_key));
      assert.equal((await get(row.id)).status,'deleted');
    });
    await t.step('atomic settlement executes every append stream mapper against native tables', async () => {
      const ts=SECOND+60;
      const cases = [
        ['hrSample','noop_hr_samples',{ts},{bpm:65},'bpm',65],
        ['rrInterval','noop_rr_intervals',{ts,rrMs:925,seq:3},{ord:5,srcChannel:5,tsSuspect:0},'srcChannel',5],
        ['event','noop_events',{ts,kind:'fixture'},{payloadJSON:'{"v":1}'},'payloadJSON','{"v":1}'],
        ['battery','noop_battery_samples',{ts},{soc:87,mv:4100,charging:false},'charging',false],
        ['spo2Sample','noop_spo2_samples',{ts},{red:900,ir:950},'ir',950],
        ['skinTempSample','noop_skin_temp_samples',{ts},{raw:900,aux1Raw:20,aux2Raw:30},'aux2Raw',30],
        ['respSample','noop_resp_samples',{ts},{raw:900},'raw',900],
        ['gravitySample','noop_gravity_samples',{ts},{x:1,y:2,z:3,dynAccel:4},'dynAccel',4],
      ] as const;
      for(const [stream,table,key,data,column,value] of cases) {
        const header={type:'batch',protocolVersion:'1.1',stream,deviceId:DEVICE,sourceId:SOURCE,
          batchId:crypto.randomUUID(),delivery:'append',recordCount:1};
        const body=new TextEncoder().encode([header,{type:'record',key,data}].map(row=>JSON.stringify(row)).join('\n')+'\n');
        const ack=await nativeIngest().acceptBatch({userId:USER_A,decodedBody:body});
        const [row]=await db.rest.select(table,`user_id=eq.${USER_A}&device_id=eq.${DEVICE}&ts=eq.${ts}`);
        assert.equal(row[column],value,stream);
        assert.equal(row.batch_id,header.batchId,stream);
        assert.equal(await db.sql(`select state from noop_projection_debt where object_id='${header.batchId}'`),'complete',stream);
        assert.deepEqual(await commitArchivedBatch(db.rest,ack.durabilityReceipt,body),ack);
      }
    });
    await t.step('daily and session replacement mappings and empty-window deletion execute natively', async () => {
      const day='2026-09-25';
      const ts=Date.parse(`${day}T10:00:00Z`)/1000;
      const cases = [
        ['dailyMetric','daily_metrics',{day},{totalSleepMin:420},'day',day,'day',day,'2026-09-26'],
        ['sleepSession','sessions',{startTs:ts},{endTs:ts+60},'external_id',`sleep:${DEVICE}:${ts}`,'startTs',ts,ts+1],
        ['workout','sessions',{startTs:ts,sport:'running'},{endTs:ts+60},'external_id',`workout:${DEVICE}:${ts}:running`,'startTs',ts,ts+1],
      ] as const;
      for(const [stream,table,key,data,column,value,selector,startInclusive,endExclusive] of cases) {
        async function replace(empty: boolean) {
          const header={type:'batch',protocolVersion:'1.1',stream,deviceId:DEVICE,sourceId:SOURCE,
            batchId:crypto.randomUUID(),delivery:'replace_window',recordCount:empty?0:1,
            window:{replacementId:crypto.randomUUID(),selector,startInclusive,endExclusive,part:1,parts:1}};
          const body=new TextEncoder().encode([header,...empty?[]:[{type:'record',key,data}]].map(row=>JSON.stringify(row)).join('\n')+'\n');
          return await nativeIngest().acceptBatch({userId:USER_A,decodedBody:body});
        }
        await replace(false);
        const query=`user_id=eq.${USER_A}&${column}=eq.${value}`;
        assert.equal((await db.rest.select(table,query)).length,1,stream);
        await replace(true);
        assert.equal((await db.rest.select(table,query)).length,0,stream);
      }
    });
    await t.step('empty-batch retry after lost committed response keeps its original archive window', async () => {
      const archive = createPushArchive({ cfg, rest: db.rest, raw: bucket.raw });
      const wal = createPushWalStore({ rest: db.rest })!;
      const batchId = crypto.randomUUID();
      const body = new TextEncoder().encode(JSON.stringify({ type: 'batch', protocolVersion: '1.1', stream: 'hrSample',
        deviceId: DEVICE, sourceId: SOURCE, batchId, delivery: 'append', recordCount: 0 })+'\n');
      const common = { archiveObject: (args: any) => archive.archiveObject(args), ensureDevice: (row: any) => registerDevice(db.rest,row),
      };
      const failed = createPushIngest({ ...common, walStore: wal, commitProjection: async (receipt,body) => {
        await commitArchivedBatch(db.rest,receipt,body); throw new Error('fixture_ack_failure');
      } });
      await assert.rejects(failed.acceptBatch({ userId: USER_A, decodedBody: body }), /fixture_ack_failure/);
      const original = await get(batchId);
      const retry = createPushIngest({ ...common, walStore: wal, now: () => new Date('2030-01-01'),
        commitProjection:(receipt,body)=>commitArchivedBatch(db.rest,receipt,body) });
      await retry.acceptBatch({ userId: USER_A, decodedBody: body });
      assert.deepEqual((await get(batchId)).durability_receipt, original.durability_receipt);
    });
    await t.step('legacy provenance is bound once on intent retry after background receipt repair', async () => {
      const f = await upload();
      await db.rest.patch('object_manifests', { status: 'ready', batch_id: null, source_id: null, uncompressed_bytes: null, digest_scope: null }, `id=eq.${f.manifest.objectId}`);
      const first = await objects.completeObject({ userId: USER_A, objectId: f.manifest.objectId });
      assert.equal(first.durabilityReceipt.batchId, null);
      const retry = await objects.createIntent({ userId: USER_A, manifest: f.manifest });
      assert.equal(retry.durabilityReceipt?.receiptId, first.durabilityReceipt.receiptId);
      assert.equal(retry.durabilityReceipt?.batchId, f.manifest.batchId);
      assert.equal(retry.durabilityReceipt?.sourceId, SOURCE);
      await assert.rejects(objects.createIntent({ userId: USER_A, manifest: { ...f.manifest, sourceId: crypto.randomUUID() } }), /object_id_conflict/);
    });
  } finally { await bucket.close(); await db.close(); }
});
