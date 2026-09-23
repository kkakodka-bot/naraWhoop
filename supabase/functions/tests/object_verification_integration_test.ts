import assert from 'node:assert/strict';
import { gzipSync } from 'node:zlib';
import { createPushObjects } from '../_shared/objects.ts';
import { completeDurableObject, reconcileIntake } from '../_shared/durability.ts';
import { objectCompletionResponse, reconcileObjectVerification } from '../_shared/objectVerification.ts';
import { pushConfig } from '../_shared/config.ts';
import { capabilitiesBody } from '../_shared/registry.ts';
import { sha256Hex } from '../_shared/s3.ts';
import { startLocalPostgres, USER_A, USER_B } from './local_postgres.ts';
import { startObjectHttp } from './local_objects.ts';

Deno.test('async object completion is opt-in and preserves capability defaults', async () => {
  assert.equal(pushConfig({}).asyncObjectVerification,false);
  assert.equal(pushConfig({NOOP_ASYNC_OBJECT_VERIFICATION:'true'}).asyncObjectVerification,false);
  assert.equal(pushConfig({NOOP_ASYNC_OBJECT_VERIFICATION:'1'}).asyncObjectVerification,true);
  const common={receiverStateId:'00000000-0000-4000-8000-000000000000',protocolVersion:'1.3',streams:['ppgWaveformSample']};
  const lane={endpoint:'/functions/v1/push/objects',maxObjectBytes:4194304,urlTtlSec:900};
  assert.equal(capabilitiesBody({...common,objectLane:lane}).objectLane.completionModes,undefined);
  assert.deepEqual(capabilitiesBody({...common,objectLane:{...lane,completionModes:['sync','async-v1']}}).objectLane.completionModes,['sync','async-v1']);
  for(const mode of [null,'sync','unknown']) {
    let sync=0;
    const response=await objectCompletionResponse({mode,completeSync:async()=>{sync++;return {status:'ready'};},
      enqueue:()=>{throw new Error('must not opt in');},hasDebt:async()=>false});
    assert.equal(response.status,200);assert.deepEqual(await response.json(),{type:'objectAck',status:'ready'});assert.equal(sync,1);
  }
});

Deno.test('native asynchronous object verification debt and exact receipt polling', async (t) => {
  const db=await startLocalPostgres({statementTimeoutMs:30_000});
  const bucket=startObjectHttp({versioned:true});
  const cfg:any={b2KeyId:'fixture',b2ApplicationKey:'fixture',b2Bucket:'fixture',asyncObjectVerification:true};
  let storageCalls=0;
  const raw={...bucket.raw,
    head:async (...args:Parameters<typeof bucket.raw.head>) => { storageCalls++;return await bucket.raw.head(...args); },
    copyObject:async (...args:Parameters<typeof bucket.raw.copyObject>) => { storageCalls++;return await bucket.raw.copyObject(...args); },
    getObjectStream:async (...args:Parameters<typeof bucket.raw.getObjectStream>) => { storageCalls++;return await bucket.raw.getObjectStream(...args); },
  };
  const objects=createPushObjects({cfg,rest:db.rest,raw});
  const get=async (id:string) => (await db.rest.select('object_manifests',`id=eq.${id}`))[0];
  const debt=async (id:string) => (await db.rest.select('noop_object_verification_debt',`object_id=eq.${id}`))[0];
  const poll=(id:string,userId=USER_A) => objects.requestVerification({userId,objectId:id});
  async function upload(userId=USER_A) {
    const payload=new TextEncoder().encode('synthetic verification fixture');
    const wire=new Uint8Array(gzipSync(payload));
    const id=crypto.randomUUID();
    const intent=await objects.createIntent({userId,manifest:{
      type:'binaryObject',protocolVersion:'1.3',stream:'ppgWaveformSample',
      deviceId:userId===USER_A?'33333333-3333-4333-8333-333333333333':'55555555-5555-4555-8555-555555555555',
      objectId:id,batchId:crypto.randomUUID(),sourceId:'44444444-4444-4444-8444-444444444444',
      startTs:1_790_000_000,endTs:1_790_000_002,sampleCount:1,
      uncompressedBytes:payload.length,compressedBytes:wire.length,contentSha256:sha256Hex(payload),contentEncoding:'gzip',
    }});
    async function put(body:Uint8Array) {
      const response=await fetch(intent.uploadUrl!,{method:'PUT',body:new Uint8Array(body),headers:intent.requiredHeaders});
      await response.body?.cancel();assert.equal(response.status,200);
    }
    await put(wire);
    return {id,wire,payload,put,row:await get(id),staging:intent.objectKey};
  }
  const claim=() => db.rest.rpc('noop_claim_object_verification',{});
  const finish=(value:any,over:Record<string,unknown>={}) => db.rest.rpc('noop_finish_object_verification',{
    p_object_id:value.objectId,p_lease_token:value.token,p_failure_code:null,p_failure_status:503,p_retryable:true,p_verification_ms:1,...over,
  });
  const expire=(id:string) => db.sql(`update noop_object_verification_debt set lease_until=now()-interval '1 second',next_attempt_at=now()-interval '1 second' where object_id='${id}'`);
  try {
    await t.step('default completion stays synchronous and returns the unchanged exact receipt',async () => {
      const f=await upload();storageCalls=0;
      const ack=await objects.completeObject({userId:USER_A,objectId:f.id});
      assert.equal(ack.status,'ready');assert.equal(ack.durabilityReceipt.state,'verified_indexed');assert(storageCalls>=3);
      assert.equal(await debt(f.id),undefined);
    });
    await t.step('enqueue and repeated polls do no object I/O and do not reset debt',async () => {
      const f=await upload();storageCalls=0;
      const pending=await poll(f.id);assert.equal(pending.status,503);assert.equal(pending.retryAfter,'15');
      assert.equal(pending.body.type,'error');assert.equal(pending.body.protocolVersion,'1.3');
      assert.equal(pending.body.code,'verification_pending');assert.equal(pending.body.state,'pending_verification');
      assert.equal(pending.body.durabilityReceipt,undefined);
      const http=await objectCompletionResponse({mode:'async-v1',allowNewAsync:async()=>true,enqueue:()=>poll(f.id),
        completeSync:()=>{throw new Error('must only enqueue');},hasDebt:async()=>false});
      assert.equal(http.status,503);assert.equal(http.headers.get('Retry-After'),'15');assert.deepEqual(await http.json(),pending.body);
      const before=await debt(f.id);assert.equal(before.attempts,0);
      assert.deepEqual(await poll(f.id),pending);assert.deepEqual(await debt(f.id),before);assert.equal(storageCalls,0);
      for(const mode of [null,'unknown']) {
        const downgraded=await objectCompletionResponse({mode,enqueue:()=>poll(f.id),
          completeSync:()=>objects.completeObject({userId:USER_A,objectId:f.id}),
          hasDebt:()=>objects.hasVerificationDebt({userId:USER_A,objectId:f.id})});
        assert.equal(downgraded.status,503);await downgraded.body?.cancel();assert.equal(storageCalls,0);
      }
      assert.equal((await reconcileIntake(db.rest,raw,64)).scanned,0,'legacy repair excludes opt-in debt');
      const report=await reconcileObjectVerification(db.rest,raw);assert.equal(report.verifiedIndexed,1);
      const saved=(await get(f.id)).durability_receipt;storageCalls=0;
      const ready=await poll(f.id);assert.equal(ready.status,200);assert.deepEqual(ready.body.durabilityReceipt,saved);
      assert.deepEqual(await poll(f.id),ready);assert.equal(storageCalls,0,'poll must not repeat GET/decode/hash');
      assert.equal((await debt(f.id)).state,'complete');
    });
    await t.step('simultaneous claims use one lease; crash after claim is recovered, stale settlement rejected',async () => {
      const f=await upload();await poll(f.id);
      const claims=await Promise.all([claim(),claim()]);assert.equal(claims.filter(Boolean).length,1);
      const first=claims.find(Boolean);const before=await debt(f.id);await poll(f.id);
      assert.deepEqual(await debt(f.id),before,'poll must not extend a worker lease');
      await expire(f.id);const second=await claim();assert.notEqual(second.token,first.token);
      assert.equal(await finish(first,{p_failure_code:'verification_failed'}),false);
      await assert.rejects(db.rest.rpc('noop_reserve_copy_intent',{p_user_id:USER_A,p_object_id:f.id,p_verification_token:first.token}),/verification_lease_lost/);
      await completeDurableObject({rest:db.rest,raw,row:second.manifest,verificationToken:second.token});
      assert.equal(await finish(second),true);assert.equal(await finish(second),true);
      assert.equal((await debt(f.id)).failures,0);
      assert.equal((await debt(f.id)).lease_recoveries,1);
      assert.equal((await debt(f.id)).retry_attempts,0,'expired lease recovery is not a failed-outcome retry');
    });
    await t.step('lost receipt and debt responses heal without recopy or repeated failure accounting',async () => {
      const f=await upload();await poll(f.id);
      const lostRest={...db.rest,rpc:async (name:string,args:unknown) => {
        const result=await db.rest.rpc(name,args);if(name==='noop_commit_copy_receipt') throw new Error('fixture lost receipt response');return result;
      }};
      assert.equal((await reconcileObjectVerification(lostRest,raw)).verifiedIndexed,1);
      assert.equal((await debt(f.id)).failures,0);storageCalls=0;assert.equal((await poll(f.id)).status,200);assert.equal(storageCalls,0);
      const g=await upload();await poll(g.id);const leased=await claim();
      await completeDurableObject({rest:db.rest,raw,row:leased.manifest,verificationToken:leased.token});
      await expire(g.id);storageCalls=0;
      assert.equal((await reconcileObjectVerification(db.rest,raw)).verifiedIndexed,1);assert.equal(storageCalls,0);
      assert.equal(await finish(leased),false);
      const h=await upload();await poll(h.id);const attempt=await claim();
      const failure={p_failure_code:'verification_failed',p_failure_status:503,p_retryable:true};
      assert.equal(await finish(attempt,failure),true);const failed=await debt(h.id);
      assert.equal(await finish(attempt,failure),false);assert.deepEqual(await debt(h.id),failed);
      await db.sql(`update noop_object_verification_debt set next_attempt_at=now() where object_id='${h.id}'`);
      assert.equal((await reconcileObjectVerification(db.rest,raw)).verifiedIndexed,1);
      assert.equal((await debt(h.id)).retry_attempts,1);
      assert.equal((await debt(h.id)).lease_recoveries,0);
    });
    await t.step('lost enqueue and COPY responses retain debt, source and every copy attempt',async () => {
      const f=await upload();const ambiguous=createPushObjects({cfg,raw,rest:{...db.rest,rpc:async(name,args)=>{
        const result=await db.rest.rpc(name,args);
        if(name==='noop_enqueue_object_verification') throw new Error('fixture lost enqueue response');return result;
      }}});
      await assert.rejects(ambiguous.requestVerification({userId:USER_A,objectId:f.id}),/fixture lost enqueue response/);
      const saved=await debt(f.id);assert.equal(saved.state,'pending');await poll(f.id);assert.deepEqual(await debt(f.id),saved);
      const report=await reconcileObjectVerification(db.rest,{...raw,copyObject:async(source,destination)=>{
        await raw.copyObject(source,destination);throw new Error('fixture lost COPY response');
      }});
      assert.equal(report.retry,1);assert.equal((await get(f.id)).durability_receipt,null);
      const [copy]=await db.rest.select('noop_object_copy_intents',`object_id=eq.${f.id}`);
      assert.equal(copy.state,'abandoned');assert(bucket.objects.has(copy.verified_key));assert(bucket.objects.has(f.staging));
      await db.sql(`update noop_object_verification_debt set next_attempt_at=now() where object_id='${f.id}'`);
      assert.equal((await reconcileObjectVerification(db.rest,raw)).verifiedIndexed,1);
      assert.notEqual((await get(f.id)).durability_receipt.objectKey,copy.verified_key);
      assert.equal((await db.rest.select('noop_signal_windows',`object_id=eq.${f.id}`)).length,1);
    });
    await t.step('transient errors persist retry time and terminal bytes require explicit resolution',async () => {
      const f=await upload();await poll(f.id);
      assert.equal((await reconcileObjectVerification(db.rest,{...raw,copyObject:async () => {throw new Error('fixture storage outage');}})).retry,1);
      const failed=await debt(f.id);assert.equal(failed.failures,1);assert(Date.parse(failed.next_attempt_at)>Date.now());
      await poll(f.id);assert.deepEqual(await debt(f.id),failed);
      await db.sql(`update noop_object_verification_debt set next_attempt_at=now() where object_id='${f.id}'`);
      assert.equal((await reconcileObjectVerification(db.rest,raw)).verifiedIndexed,1);
      const g=await upload();await g.put(g.wire.subarray(0,g.wire.length-1));await poll(g.id);
      assert.equal((await reconcileObjectVerification(db.rest,raw)).paused,1);
      const paused=await poll(g.id);assert.equal(paused.status,409);assert.equal(paused.body.code,'size_mismatch');
      assert.equal(paused.body.durabilityReceipt,undefined);assert(bucket.objects.has(g.staging));
      const downgraded=await objectCompletionResponse({mode:null,enqueue:()=>poll(g.id),
        completeSync:()=>objects.completeObject({userId:USER_A,objectId:g.id}),
        hasDebt:()=>objects.hasVerificationDebt({userId:USER_A,objectId:g.id})});
      assert.equal(downgraded.status,409);await downgraded.body?.cancel();
      assert.equal((await reconcileIntake(db.rest,raw,64)).scanned,0);assert.equal((await reconcileObjectVerification(db.rest,raw)).claimed,0);
      await g.put(g.wire);assert.equal((await poll(g.id)).status,409,'repair alone does not hot-loop a paused selection');
      assert.equal(await db.rest.rpc('noop_retry_object_verification',{p_user_id:USER_B,p_object_id:g.id}),false);
      assert.equal(await db.rest.rpc('noop_retry_object_verification',{p_user_id:USER_A,p_object_id:g.id}),true);
      assert.equal((await reconcileObjectVerification(db.rest,raw)).verifiedIndexed,1);assert.equal((await poll(g.id)).status,200);
    });
    await t.step('missing index blocks cached receipt and bounded repair retains the immutable object key',async () => {
      const f=await upload();await poll(f.id);await reconcileObjectVerification(db.rest,raw);
      const saved=(await get(f.id)).durability_receipt;
      await db.sql(`delete from noop_signal_windows where object_id='${f.id}'`);
      assert.equal((await poll(f.id)).status,503);
      assert.equal((await reconcileObjectVerification(db.rest,raw)).verifiedIndexed,1);
      assert.deepEqual((await poll(f.id)).body.durabilityReceipt,saved);
    });
    await t.step('a malformed cached receipt cannot become successful polling or an endless retry',async () => {
      const f=await upload();await poll(f.id);await reconcileObjectVerification(db.rest,raw);
      const saved=(await get(f.id)).durability_receipt;
      for(const invalid of [
        {...saved,ownerUserId:USER_B},{...saved,receiptId:undefined},{...saved,receiptId:'invalid'},
        {...saved,receiptId:null},{...saved,verifiedAt:'not-a-time'},{...saved,verifiedAt:'2026-99-99T00:00:00Z'},
        {...saved,indexedAt:'1970-01-01T00:00:00Z'},{...saved,schemaVersion:'1'},
        {...saved,compressedBytes:String(saved.compressedBytes)},
      ]) {
        await db.rest.patch('object_manifests',{durability_receipt:invalid},`id=eq.${f.id}`);storageCalls=0;
        const response=await poll(f.id);assert.equal(response.status,409);assert.equal(response.body.code,'receipt_mismatch');
        assert.equal(response.body.durabilityReceipt,undefined);assert(bucket.objects.has(saved.objectKey));
        assert.equal((await reconcileObjectVerification(db.rest,raw)).claimed,0);assert.equal(storageCalls,0);
        await db.rest.patch('object_manifests',{durability_receipt:saved},`id=eq.${f.id}`);
        assert.deepEqual((await poll(f.id)).body.durabilityReceipt,saved);
      }
      await db.rest.patch('noop_signal_windows',{start_ts:1_789_999_999,received_records:99},`object_id=eq.${f.id}`);
      assert.equal((await poll(f.id)).status,503);
      assert.equal((await reconcileObjectVerification(db.rest,raw)).paused,1);
      assert.equal((await poll(f.id)).body.code,'receipt_mismatch');
      await db.rest.patch('noop_signal_windows',{start_ts:1_790_000_000,received_records:1},`object_id=eq.${f.id}`);
      assert.deepEqual((await poll(f.id)).body.durabilityReceipt,saved);
    });
    await t.step('async enqueue and debt lookup retain installation source scope through receipt polling', async () => {
      const f = await upload();
      const owned = { userId: USER_A, objectId: f.id, sourceId: '44444444-4444-4444-8444-444444444444' };
      const foreign = { ...owned, sourceId: '66666666-6666-4666-8666-666666666666' };
      for (const read of [objects.requestVerification, objects.hasVerificationDebt]) {
        await assert.rejects(read(foreign), (error: any) => error.code === 'forbidden' && error.status === 403);
      }
      assert.equal(await debt(f.id), undefined);
      assert.equal(await objects.hasVerificationDebt(owned), false);
      assert.equal((await objects.requestVerification(owned)).status, 503);
      assert.equal(await objects.hasVerificationDebt(owned), true);
      assert.equal((await reconcileObjectVerification(db.rest, raw)).verifiedIndexed, 1);
      assert.equal((await objects.requestVerification(owned)).status, 200);
      for (const read of [objects.requestVerification, objects.hasVerificationDebt]) {
        await assert.rejects(read(foreign), (error: any) => error.code === 'forbidden' && error.status === 403);
      }
    });
    await t.step('wrong owner and real authenticated/anonymous roles cannot enqueue, claim, settle or read debt',async () => {
      const f=await upload();await assert.rejects(poll(f.id,USER_B),(error:any)=>error.code==='forbidden' && error.status===403);assert.equal(await debt(f.id),undefined);
      await assert.rejects(poll(crypto.randomUUID()),/missing_manifest/);
      for(const role of ['authenticated','anon']) {
        assert((await db.request('noop_object_verification_debt',role)).status>=400);
        assert((await db.request('noop_object_verification_metrics',role)).status>=400);
        for(const [name,args] of [
          ['noop_enqueue_object_verification',{p_user_id:USER_A,p_object_id:f.id}],
          ['noop_current_object_receipt',{p_user_id:USER_A,p_object_id:f.id}],
          ['noop_claim_object_verification',{}],
          ['noop_finish_object_verification',{p_object_id:f.id,p_lease_token:crypto.randomUUID()}],
          ['noop_retry_object_verification',{p_user_id:USER_A,p_object_id:f.id}],
          ['noop_defer_object_verification',{p_object_id:f.id,p_lease_token:crypto.randomUUID()}],
        ] as const) assert((await db.request(`rpc/${name}`,role,USER_A,'POST',args)).status>=400);
      }
      await poll(f.id);await reconcileObjectVerification(db.rest,raw);
    });
    await t.step('opt-in racing a legacy request fences COPY; earlier admitted COPY delays new worker admission',async () => {
      const f=await upload();storageCalls=0;
      const response=await objectCompletionResponse({mode:null,hasDebt:async()=>false,enqueue:()=>poll(f.id),
        completeSync:async()=>{await poll(f.id);return await objects.completeObject({userId:USER_A,objectId:f.id});}});
      assert.equal(response.status,503);await response.body?.cancel();assert.equal(storageCalls,0);
      await assert.rejects(completeDurableObject({rest:db.rest,raw,row:f.row}),/async_verification_required/);
      assert.equal(storageCalls,0);await reconcileObjectVerification(db.rest,raw);
      const g=await upload();
      const earlier=await db.rest.rpc('noop_reserve_copy_intent',{p_user_id:USER_A,p_object_id:g.id});
      await poll(g.id);assert.equal(await claim(),null,'live COPY predating opt-in is allowed to finish before a worker starts');
      await db.rest.rpc('noop_abandon_copy_intent',{p_intent_id:earlier.id,p_lease_token:earlier.lease_token,p_failure_code:'copy_failed'});
      assert.equal((await reconcileObjectVerification(db.rest,raw)).verifiedIndexed,1);
      await assert.rejects(db.rest.rpc('noop_reserve_copy_intent_unfenced',{p_user_id:USER_A,p_object_id:g.id}),/permission denied/);
    });
    await t.step('row, compressed/decoded byte and admission-time budgets stop new claims',async () => {
      const f=await upload(),g=await upload();await poll(f.id);await poll(g.id);
      assert.equal((await reconcileObjectVerification(db.rest,raw,{limit:0})).claimed,0);
      assert.equal((await reconcileObjectVerification(db.rest,raw,{maxBytes:f.wire.length-1})).claimed,0);
      assert.equal((await reconcileObjectVerification(db.rest,raw,{maxDecodedBytes:f.payload.length-1})).claimed,0);
      assert.equal((await reconcileObjectVerification(db.rest,raw,{maxMilliseconds:0})).claimed,0);
      assert.equal((await reconcileObjectVerification(db.rest,raw,{limit:1,maxBytes:f.wire.length,maxDecodedBytes:f.payload.length})).verifiedIndexed,1);
      assert.equal((await reconcileObjectVerification(db.rest,raw)).verifiedIndexed,1);
      const h=await upload(),j=await upload();await poll(h.id);await poll(j.id);let tick=0;
      assert.equal((await reconcileObjectVerification(db.rest,raw,{maxMilliseconds:10,clock:()=>tick++<4?0:20})).claimed,1);
      await reconcileObjectVerification(db.rest,raw);
      const k=await upload();await poll(k.id);tick=0;storageCalls=0;
      const deferred=await reconcileObjectVerification(db.rest,raw,{maxMilliseconds:10,clock:()=>tick++<2?0:20});
      assert.equal(deferred.deferred,1);assert.equal(storageCalls,0);assert.equal((await debt(k.id)).state,'pending');
      assert.equal((await debt(k.id)).failures,0);await reconcileObjectVerification(db.rest,raw);
    });
    await t.step('manifest/account removal rejects settlement while preserving delayed-copy cleanup tombstones',async () => {
      const f=await upload();await poll(f.id);const leased=await claim();
      const intent=await db.rest.rpc('noop_reserve_copy_intent',{p_user_id:USER_A,p_object_id:f.id,p_verification_token:leased.token});
      await db.sql(`delete from object_manifests where id='${f.id}'`);
      await raw.copyObject(intent.upload_key,intent.verified_key);
      assert.equal(await finish(leased),false);assert.equal(await debt(f.id),undefined);
      const attempt=(await db.rest.select('noop_object_copy_intents',`id=eq.${intent.id}`))[0];
      assert.equal(attempt.object_id,null);assert.equal(attempt.state,'abandoned');assert(bucket.objects.has(intent.verified_key));
      const g=await upload(USER_B);await poll(g.id,USER_B);const other=await claim();
      const copy=await db.rest.rpc('noop_reserve_copy_intent',{p_user_id:USER_B,p_object_id:g.id,p_verification_token:other.token});
      await db.sql(`delete from auth.users where id='${USER_B}'`);await raw.copyObject(copy.upload_key,copy.verified_key);
      assert.equal(await finish(other),false);assert.equal(await debt(g.id),undefined);
      const detached=(await db.rest.select('noop_object_copy_intents',`id=eq.${copy.id}`))[0];
      assert.equal(detached.user_id,null);assert.equal(detached.state,'abandoned');
    });
    await t.step('aggregate metrics expose debt and phase durations without owner or object identifiers',async () => {
      const [metrics]=await db.rest.select('noop_object_verification_metrics');
      assert.equal(Number(metrics.queue_depth),0);assert(Number(metrics.verification_ms_avg)>=0);
      assert(Number(metrics.receipt_latency_ms_max)>=0);assert(Number(metrics.retries)>=2);
      assert(Number(metrics.failures)>=3);assert(Number(metrics.lease_recoveries)>=2);
      assert(!Object.keys(metrics).some(k=>/user|device|object_id/.test(k)));
    });
  } finally { await bucket.close();await db.close(); }
});
