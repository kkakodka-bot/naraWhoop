import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { gzipSync } from 'node:zlib';
import { createSupabaseRest } from '../_shared/rest.ts';
import { createIntakeConsumer, runIntakeConsumer } from '../_shared/intakeConsumer.ts';
import { createPushObjects } from '../_shared/objects.ts';
import { createPushArchive, createPushIngest } from '../_shared/ingest.ts';
import { createPushWalStore } from '../_shared/wal.ts';
import { commitArchivedBatch } from '../_shared/projections.ts';
import { completeDurableObject } from '../_shared/durability.ts';
import { asyncVerificationAvailable } from '../_shared/objectVerification.ts';
import { startObjectHttp } from './local_objects.ts';
import { sha256Hex } from '../_shared/s3.ts';

const container=Deno.env.get('PIPELINE_TEST_DATABASE_CONTAINER');
const origin=Deno.env.get('PIPELINE_TEST_REST_URL');
async function sql(query:string) {
  if (!container?.startsWith('nara-db-')) throw Error('disposable_database_required');
  const child=new Deno.Command('docker',{args:['exec','-i',container,'psql','-U','postgres','-d','postgres','-X','-qAt','-v','ON_ERROR_STOP=1'],
    stdin:'piped',stdout:'piped',stderr:'piped'}).spawn();
  const writer=child.stdin.getWriter();await writer.write(new TextEncoder().encode(query));await writer.close();
  const r=await child.output();assert.equal(r.code,0,new TextDecoder().decode(r.stderr));return new TextDecoder().decode(r.stdout).trim();
}
function token(role='service_role') {
  const header=btoa(JSON.stringify({alg:'HS256',typ:'JWT'})).replaceAll('=','');
  const body=btoa(JSON.stringify({role,exp:Math.floor(Date.now()/1000)+3600})).replaceAll('=','');
  return `${header}.${body}.${createHmac('sha256','isolated-pipeline-jwt-secret-never-used-outside-tests').update(`${header}.${body}`).digest('base64url')}`;
}

Deno.test({name:'actual intake consumer preserves source-scoped atomic projection and bounded fair verification',ignore:!container||!origin,fn:async(t)=>{
  assert.equal(new URL(origin!).hostname,'127.0.0.1');
  const rest=createSupabaseRest({cfg:{supabaseUrl:origin!,supabaseServiceRoleKey:token()},
    fetchImpl:(input,init)=>fetch(String(input).replace('/rest/v1/','/'),{...init,signal:AbortSignal.timeout(15_000)})});
  const bucket=startObjectHttp({versioned:true});
  const cfg:any={b2KeyId:'fixture',b2ApplicationKey:'fixture',b2Bucket:'fixture',rawStore:'b2',asyncObjectVerification:true};
  const owner=crypto.randomUUID(),source=crypto.randomUUID(),device=crypto.randomUUID(),code=crypto.randomUUID();
  const sibling=crypto.randomUUID();
  const owner2=crypto.randomUUID(),source2=crypto.randomUUID(),device2=crypto.randomUUID(),code2=crypto.randomUUID();
  await sql(`insert into auth.users(id) values('${owner}'),('${owner2}');
    insert into public.noop_enrollment_codes(id,user_id,code_hash,expires_at)
      values('${code}','${owner}',repeat('a',64),now()+interval '1 day'),('${code2}','${owner2}',repeat('b',64),now()+interval '1 day');
    insert into public.noop_app_installations(source_id,user_id,enrollment_code_id,platform,app_version)
      values('${source}','${owner}','${code}','ios','fixture'),('${source2}','${owner2}','${code2}','android','fixture');
    insert into public.devices(id,user_id,source_kind,external_device_id)
      values('${device}','${owner}','noop_push','fixture-a'),('${device2}','${owner2}','noop_push','fixture-b'),('${sibling}','${owner}','noop_push','fixture-c');`);
  const objects=createPushObjects({cfg,rest,raw:bucket.raw,resolveDeviceId:async({userId,externalDeviceId})=>userId!==owner?device2:externalDeviceId==='fixture-c'?sibling:device});
  const archive=createPushArchive({cfg,rest,raw:bucket.raw});
  const ingest=createPushIngest({walStore:createPushWalStore({rest})!,archiveObject:archive.archiveObject,
    resolveDeviceId:async()=>device,commitProjection:(receipt,bytes)=>commitArchivedBatch(rest,receipt,bytes)});
  const identity={processId:crypto.randomUUID(),instanceId:crypto.randomUUID(),sourceRevision:'a'.repeat(40),admission:{mode:'all-eligible' as const}};
  const consumer=createIntakeConsumer(rest,bucket.raw,identity);
  const scope={userId:owner,sourceId:source,tokenId:null,authMode:'installation' as const};
  const latest=()=>Math.floor(Date.now()/1000)-5;
  function batch(stream:string,rows:any[],ts:number) {
    const batchId=crypto.randomUUID();
    const header={type:'batch',protocolVersion:'1.1',stream,deviceId:'fixture-a',sourceId:source,batchId,endCursor:{ts},delivery:'append',recordCount:rows.length};
    const bytes=new TextEncoder().encode([header,...rows.map(data=>({type:'record',key:{ts},data}))].map(x=>JSON.stringify(x)).join('\n')+'\n');
    return {batchId,bytes,header};
  }
  async function rawUpload(which=0,historical=false) {
    const who=which!==1?scope:{userId:owner2,sourceId:source2,authMode:'installation' as const};
    const bytes=new TextEncoder().encode('synthetic waveform bytes');const wire=new Uint8Array(gzipSync(bytes));
    const start=latest()-(historical?86400:0),id=crypto.randomUUID();
    const intent=await objects.createIntent({...who,manifest:{type:'binaryObject',protocolVersion:'1.3',stream:'ppgWaveformSample',deviceId:['fixture-a','fixture-b','fixture-c'][which],
      sourceId:who.sourceId,objectId:id,batchId:crypto.randomUUID(),startTs:start,endTs:start+1,sampleCount:1,
      uncompressedBytes:bytes.length,compressedBytes:wire.length,contentSha256:sha256Hex(bytes),contentEncoding:'gzip'}});
    const put=await fetch(intent.uploadUrl!,{method:'PUT',body:wire,headers:intent.requiredHeaders});await put.body?.cancel();assert.equal(put.status,200);
    return {id,who};
  }
  try {
    await t.step('startup checks actual migrated contract and readiness follows successful real queue polling',async()=>{
      assert.equal(await asyncVerificationAvailable(cfg,rest),false);
      await consumer.preflight();
      await runIntakeConsumer(consumer,{once:true});
      assert.equal(await asyncVerificationAvailable(cfg,rest),true);
      await sql(`update noop_intake_consumers set last_successful_poll_at=now()-interval '31 seconds';`);
      assert.equal(await asyncVerificationAvailable(cfg,rest),false);
      await consumer.poll('verification');assert.equal(await asyncVerificationAvailable(cfg,rest),true);
      const status=await rest.rpc('noop_intake_status',{});
      assert.equal(status.async_consumer_liveness,true);
      assert.equal(status.capacity_acceptance,'NOT_MEASURED');
      assert.equal(status.physical_continuity,'NOT_MEASURED');
      assert.equal(status.queue_sample_limit,1000);
      await assert.rejects(rest.rpc('noop_intake_consumer_poll_v2',{p_admission_mode:'all-eligible',p_user_id:null,p_device_id:null,p_process:identity.processId,p_instance:crypto.randomUUID(),p_source_revision:identity.sourceRevision,
        p_lane:'verification',p_claimed:0,p_completed:0,p_failures:0}),/consumer_identity_changed/);
    });
    await t.step('real HR and gravity wire bytes settle lifecycle observations and projection debt with one ACK',async()=>{
      for(const [stream,data] of [['hrSample',{bpm:61}],['gravitySample',{x:0,y:0,z:1}] ] as const) {
        const f=batch(stream,[data],latest());
        const ack=await ingest.acceptBatch({...scope,decodedBody:f.bytes});
        assert.equal(ack.durabilityReceipt.state,'verified_indexed');
        assert.equal(await sql(`select state from noop_projection_debt where object_id='${f.batchId}'`),'complete');
        assert.equal(await sql(`select count(*) from noop_projection_observations where batch_id='${f.batchId}'`),'1');
        assert.deepEqual(await ingest.acceptBatch({...scope,decodedBody:f.bytes}),ack);
        const row=(await rest.select('object_manifests',`id=eq.${f.batchId}`))[0];
        await sql(`update object_manifests set sha256_source='client_claimed',verified_at=null where id='${f.batchId}';`);
        const repaired=await completeDurableObject({rest,raw:bucket.raw,row});
        assert.deepEqual(repaired,ack.durabilityReceipt);
        assert.equal(await sql(`select sha256_source||':'||(verified_at is not null)::text from object_manifests where id='${f.batchId}'`),'server_verified:true');
      }
    });
    await t.step('conflicting second installation observation is preserved and removes the canonical scalar',async()=>{
      const another=crypto.randomUUID();await sql(`insert into noop_app_installations(source_id,user_id,enrollment_code_id,platform,app_version)
        values('${another}','${owner}','${code}','ios','fixture');`);
      const ts=latest()+2;const one=batch('hrSample',[{bpm:62}],ts);await ingest.acceptBatch({...scope,decodedBody:one.bytes});
      const two=batch('hrSample',[{bpm:63}],ts);const changed=new TextDecoder().decode(two.bytes).replaceAll(source,another);
      await ingest.acceptBatch({...scope,sourceId:another,decodedBody:new TextEncoder().encode(changed)});
      assert.equal(await sql(`select count(*) from noop_hr_samples where user_id='${owner}' and device_id='${device}' and ts=${ts}`),'0');
      assert.equal(await sql(`select count(*) from noop_projection_conflicts where user_id='${owner}' and stream='hrSample'`),'1');
      assert.equal(await sql(`select state from noop_projection_debt where object_id='${two.batchId}'`),'complete');
    });
    await t.step('actual verifier obtains immutable byte receipt and source-bound polling without repeated storage',async()=>{
      const f=await rawUpload();assert.equal((await objects.requestVerification({...f.who,objectId:f.id})).status,503);
      const result=await consumer.poll('verification');

      assert.equal(result.completed,1);
      const ack=await objects.requestVerification({...f.who,objectId:f.id});assert.equal(ack.status,200);
      assert.equal(ack.body.durabilityReceipt.state,'verified_indexed');
      assert.equal((await objects.requestVerification({...f.who,objectId:f.id})).status,200);
      await assert.rejects(objects.requestVerification({...f.who,sourceId:source2,objectId:f.id}),/forbidden/);
    });
    await t.step('owner scheduling rotates and serves both fresh and history lanes',async()=>{
      const old=await rawUpload(0,true),fresh=await rawUpload(0),other=await rawUpload(1);
      for(const f of [old,fresh,other]) await objects.requestVerification({...f.who,objectId:f.id});
      const first=await rest.rpc('noop_claim_object_verification',{}),second=await rest.rpc('noop_claim_object_verification',{});
      assert.notEqual(first.manifest.user_id,second.manifest.user_id);
      const third=await rest.rpc('noop_claim_object_verification',{});
      assert.deepEqual(new Set([first.objectId,second.objectId,third.objectId]),new Set([old.id,fresh.id,other.id]));
      for(const item of [first,second,third]) await rest.rpc('noop_defer_object_verification',{p_object_id:item.objectId,p_lease_token:item.token});
      for(let i=0;i<3;i++) assert.equal((await consumer.poll('verification')).completed,1);
      const status=await rest.rpc('noop_intake_status',{});assert.equal(status.verification.pending_at_least,0);
    });
    await t.step('scalar replay rotates owners and fresh/history archives then drains actual wire bytes',async()=>{
      const disconnected=createPushIngest({walStore:createPushWalStore({rest})!,archiveObject:archive.archiveObject,
        resolveDeviceId:async({userId})=>userId===owner?device:device2,
        commitProjection:async()=>{throw Error('synthetic interruption before projection');}});
      async function pending(which:number,historical:boolean) {
        const f=batch('hrSample',[{bpm:65}],latest()-(historical?86400:100));
        const who=which===0?scope:{userId:owner2,sourceId:source2,tokenId:null,authMode:'installation' as const};
        const bytes=which===0?f.bytes:new TextEncoder().encode(new TextDecoder().decode(f.bytes).replaceAll(source,source2).replaceAll('fixture-a','fixture-b'));
        await assert.rejects(disconnected.acceptBatch({...who,decodedBody:bytes}));
        assert.equal(await sql(`select state from noop_projection_debt where object_id='${f.batchId}'`),'pending');
        return f.batchId;
      }
      const history=await pending(0,true),live=await pending(0,false),other=await pending(1,false);
      const first=await rest.rpc('noop_claim_projection_debt',{}),second=await rest.rpc('noop_claim_projection_debt',{});
      assert.notEqual(first.manifest.user_id,second.manifest.user_id);
      const third=await rest.rpc('noop_claim_projection_debt',{});
      assert.deepEqual(new Set([first.manifest.id,second.manifest.id,third.manifest.id]),new Set([history,live,other]));
      for(const id of [history,live,other]) await sql(`update noop_projection_debt set lease_token=null,lease_until=null where object_id='${id}'`);
      for(let i=0;i<3;i++) assert.equal((await consumer.poll('projection')).completed,1);
      for(const id of [history,live,other]) assert.equal(await sql(`select state from noop_projection_debt where object_id='${id}'`),'complete');
    });
    await t.step('canary drains only one admitted device across every real lane and retains sibling and foreign debt',async()=>{
      const scopedIdentity={...identity,processId:crypto.randomUUID(),instanceId:crypto.randomUUID(),
        admission:{mode:'canary' as const,ownerId:owner,deviceId:device}};
      const scoped=createIntakeConsumer(rest,bucket.raw,scopedIdentity);
      await sql(`update noop_intake_consumers set last_successful_poll_at=now()-interval '31 seconds';`);
      await rest.rpc('noop_intake_consumer_poll',{p_process:crypto.randomUUID(),p_instance:crypto.randomUUID(),p_source_revision:'c'.repeat(40),
        p_lane:'verification',p_claimed:0,p_completed:0,p_failures:0});
      assert.equal(await asyncVerificationAvailable(cfg,rest),false,'contract1 must not establish compatibility');
      await scoped.preflight();
      const rawJobs=[];
      for(let which=0;which<3;which++) {const f=await rawUpload(which);rawJobs.push(f);await objects.requestVerification({...f.who,objectId:f.id});}
      const ownerScheduler=await sql(`select jsonb_agg(to_jsonb(s) order by user_id)::text from noop_verification_owner_service s`);
      assert.equal((await scoped.poll('verification')).completed,1);
      assert.equal(await sql(`select jsonb_agg(to_jsonb(s) order by user_id)::text from noop_verification_owner_service s`),ownerScheduler);
      assert.equal(await sql(`select state from noop_object_verification_debt where object_id='${rawJobs[0].id}'`),'complete');
      for(const f of rawJobs.slice(1)) assert.equal(await sql(`select state||':'||attempts from noop_object_verification_debt where object_id='${f.id}'`),'pending:0');
      assert.equal(await asyncVerificationAvailable(cfg,rest),false,'scoped consumer must not enable global async admission');
      await assert.rejects(rest.rpc('noop_intake_consumer_poll',{p_process:scopedIdentity.processId,p_instance:scopedIdentity.instanceId,p_source_revision:identity.sourceRevision,
        p_lane:'verification',p_claimed:0,p_completed:0,p_failures:0}),/consumer_identity_changed/);
      await assert.rejects(rest.rpc('noop_intake_consumer_poll_v2',{p_process:scopedIdentity.processId,p_instance:scopedIdentity.instanceId,p_source_revision:identity.sourceRevision,
        p_lane:'verification',p_claimed:0,p_completed:0,p_failures:0,p_admission_mode:'canary',p_user_id:owner,p_device_id:sibling}),/consumer_identity_changed/);

      const disconnected=createPushIngest({walStore:createPushWalStore({rest})!,archiveObject:archive.archiveObject,
        resolveDeviceId:async({userId,externalDeviceId})=>userId!==owner?device2:externalDeviceId==='fixture-c'?sibling:device,
        commitProjection:async()=>{throw Error('synthetic interruption before projection');}});
      const projections=[];
      for(let which=0;which<3;which++) {
        const f=batch('hrSample',[{bpm:64}],latest()-500-which);
        const who=which===1?{userId:owner2,sourceId:source2,tokenId:null,authMode:'installation' as const}:scope;
        const bytes=new TextEncoder().encode(new TextDecoder().decode(f.bytes).replaceAll(source,who.sourceId)
          .replaceAll('fixture-a',['fixture-a','fixture-b','fixture-c'][which]));
        await assert.rejects(disconnected.acceptBatch({...who,decodedBody:bytes}));projections.push(f.batchId);
      }
      const projectionScheduler=await sql(`select jsonb_agg(to_jsonb(s) order by user_id)::text from noop_projection_owner_service s`);
      const globalCursors=await sql(`select jsonb_build_array((select to_jsonb(s) from noop_projection_scan s),(select to_jsonb(s) from noop_intake_reconcile_state s))::text`);
      assert.equal((await scoped.poll('projection')).completed,1);
      assert.equal(await sql(`select state from noop_projection_debt where object_id='${projections[0]}'`),'complete');
      for(const id of projections.slice(1)) assert.equal(await sql(`select state||':'||(lease_token is null)::text from noop_projection_debt where object_id='${id}'`),'pending:true');
      assert.equal(await sql(`select jsonb_agg(to_jsonb(s) order by user_id)::text from noop_projection_owner_service s`),projectionScheduler);

      // These objects have no async debt: only the separate legacy cursor can repair them.
      const legacy=[];for(let which=0;which<3;which++) legacy.push(await rawUpload(which));
      const beforeLegacy=await rest.rpc('noop_intake_canary_status',{p_user:owner,p_device:device,p_source_revision:identity.sourceRevision,p_instance:scopedIdentity.instanceId});
      assert.equal(beforeLegacy.legacy.pending_at_least,1);assert.equal(beforeLegacy.legacy.truncated,false);
      assert.equal((await scoped.poll('legacy')).completed,1);
      assert.equal(await sql(`select (durability_receipt is not null)::text from object_manifests where id='${legacy[0].id}'`),'true');
      for(const f of legacy.slice(1)) assert.equal(await sql(`select (durability_receipt is null)::text from object_manifests where id='${f.id}'`),'true');
      assert.equal(await sql(`select jsonb_build_array((select to_jsonb(s) from noop_projection_scan s),(select to_jsonb(s) from noop_intake_reconcile_state s))::text`),globalCursors);
      const status=await rest.rpc('noop_intake_canary_status',{p_user:owner,p_device:device,p_source_revision:identity.sourceRevision,p_instance:scopedIdentity.instanceId});
      assert.equal(status.contract_version,2);assert.equal(status.admission_mode,'canary');assert.equal(status.owner_cap,1);assert.equal(status.device_cap,1);
      assert.equal(status.lanes.length,3);assert.equal(status.verification.pending_at_least,0);assert.equal(status.projection.pending_at_least,0);assert.equal(status.legacy.pending_at_least,0);
      assert.equal(status.latest_publication_marker,null);
      assert.equal(status.capacity_acceptance,'NOT_MEASURED');
      for(const privateValue of [owner,device,sibling,source,...rawJobs.map(f=>f.id)]) assert(!JSON.stringify(status).includes(privateValue));
      assert.equal((await rest.rpc('noop_intake_canary_status',{p_user:owner,p_device:device,p_source_revision:'d'.repeat(40),p_instance:scopedIdentity.instanceId})).lanes.length,0);
      assert(Number.isInteger(status.database.connections));assert(status.database.max_connections>status.database.reserved_connections);
      const rawWithRevoke=(revoke:()=>Promise<unknown>)=>({...bucket.raw,getObjectStream:async(key:string)=>{
        const result=await bucket.raw.getObjectStream(key);await revoke();return result;
      }});
      const revokedRaw=await rawUpload();await objects.requestVerification({...revokedRaw.who,objectId:revokedRaw.id});
      const revokeDuringGet=createIntakeConsumer(rest,rawWithRevoke(()=>sql(`update devices set is_active=false where id='${device}'`)),scopedIdentity);
      await assert.rejects(revokeDuringGet.poll('verification'),/intake_admission_scope_mismatch/);
      assert.equal(await sql(`select (durability_receipt is null)::text from object_manifests where id='${revokedRaw.id}'`),'true');
      assert.equal(await sql(`select count(*) from noop_signal_windows where object_id='${revokedRaw.id}'`),'0');
      assert.equal(await sql(`select state||':'||failures from noop_object_verification_debt where object_id='${revokedRaw.id}'`),'leased:0');
      assert.equal(await sql(`select state from noop_object_copy_intents where object_id='${revokedRaw.id}'`),'copying');
      await sql(`update devices set is_active=true where id='${device}'`);
      const revokeProjection=batch('hrSample',[{bpm:66}],latest()-8000);
      await assert.rejects(disconnected.acceptBatch({...scope,decodedBody:revokeProjection.bytes}));
      await assert.rejects(revokeDuringGet.poll('projection'),/intake_admission_scope_mismatch/);
      assert.equal(await sql(`select state||':'||(lease_token is not null)::text from noop_projection_debt where object_id='${revokeProjection.batchId}'`),'pending:true');
      assert.equal(await sql(`select count(*) from noop_push_acks where batch_id='${revokeProjection.batchId}'`),'0');
      assert.equal(await sql(`select count(*) from noop_hr_samples where user_id='${owner}' and device_id='${device}' and ts=${revokeProjection.header.endCursor.ts}`),'0');
      await sql(`update devices set is_active=true where id='${device}'`);
      const validate=(p_user:string,p_device:string)=>rest.rpc('noop_intake_canary_validate',{p_user,p_device});
      await assert.rejects(validate(owner,device2),/intake_admission_scope_mismatch/);
      await assert.rejects(validate(owner,crypto.randomUUID()),/intake_admission_scope_mismatch/);
      const queueDay='2026-08-01';
      for(const [p_user,p_device] of [[owner,device],[owner,sibling],[owner2,device2]]) {
        assert.equal(await rest.rpc('scoring_canary_enqueue_legacy',{p_user,p_device,p_day:queueDay,p_timezone:'UTC',p_debounce_seconds:0}),1);
      }
      const claimed=await rest.rpc('scoring_canary_claim_one',{p_lease_seconds:30,p_max_failures:8,p_user:owner,p_device:device,p_day:queueDay});
      assert.equal(claimed.length,1);assert.equal(claimed[0].user_id,owner);assert.equal(claimed[0].device_id,device);
      assert.equal(await sql(`select count(*) from scoring_work_items where day='${queueDay}' and lease_token is not null`),'1');
      assert.equal((await rest.rpc('scoring_canary_claim_one',{p_lease_seconds:30,p_max_failures:8,p_user:owner,p_device:device,p_day:queueDay})).length,0);
      await sql(`update devices set is_active=false where id='${device}'`);
      await assert.rejects(scoped.preflight(),/intake_admission_scope_mismatch/);
      for(const lane of ['verification','projection','legacy'] as const) await assert.rejects(scoped.poll(lane),/intake_admission_scope_mismatch/);
      await assert.rejects(rest.rpc('scoring_canary_claim_one',{p_lease_seconds:30,p_max_failures:8,p_user:owner,p_device:device,p_day:null}),/intake_admission_scope_mismatch/);
      await assert.rejects(rest.rpc('scoring_canary_enqueue_legacy',{p_user:owner,p_device:device,p_day:'2026-09-10',p_timezone:'UTC',p_debounce_seconds:0}),/intake_admission_scope_mismatch/);
      await sql(`update devices set is_active=true where id='${device}'`);
      const retiredLegacy=await rawUpload();
      await sql(`update noop_intake_canary_state set legacy_cursor=null where user_id='${owner}' and device_id='${device}'`);
      const retireDuringGet=createIntakeConsumer(rest,rawWithRevoke(()=>sql(`insert into noop_account_retirements(user_id) values('${owner}')`)),scopedIdentity);
      await assert.rejects(retireDuringGet.poll('legacy'),/intake_admission_scope_mismatch/);
      assert.equal(await sql(`select (durability_receipt is null)::text from object_manifests where id='${retiredLegacy.id}'`),'true');
      assert.equal(await sql(`select count(*) from noop_signal_windows where object_id='${retiredLegacy.id}'`),'0');
      assert.equal(await sql(`select state from noop_object_copy_intents where object_id='${retiredLegacy.id}'`),'copying');
      await assert.rejects(validate(owner,device),/intake_admission_scope_mismatch/);
      await assert.rejects(rest.rpc('scoring_canary_claim_one',{p_lease_seconds:30,p_max_failures:8,p_user:owner,p_device:device,p_day:null}),/intake_admission_scope_mismatch/);
      await assert.rejects(rest.rpc('scoring_canary_enqueue_legacy',{p_user:owner,p_device:device,p_day:'2026-09-10',p_timezone:'UTC',p_debounce_seconds:0}),/intake_admission_scope_mismatch/);
      assert.equal(await sql(`select count(*) from scoring_work_items where user_id='${owner}' and day='2026-09-10'`),'0');
    });
    await t.step('anonymous and account roles cannot claim or announce consumer readiness',async()=>{
      for(const role of ['anon','authenticated']) {
        const response=await fetch(`${origin}/rpc/noop_intake_consumer_poll`,{method:'POST',headers:{authorization:`Bearer ${token(role)}`,'content-type':'application/json'},
          body:JSON.stringify({p_process:crypto.randomUUID(),p_instance:crypto.randomUUID(),p_source_revision:'b'.repeat(40),p_lane:'verification',p_claimed:0,p_completed:0,p_failures:0})});
        await response.body?.cancel();assert(response.status>=400);
        const validation=await fetch(`${origin}/rpc/noop_intake_canary_validate`,{method:'POST',
          headers:{authorization:`Bearer ${token(role)}`,'content-type':'application/json'},body:JSON.stringify({p_user:owner2,p_device:device2})});
        await validation.body?.cancel();assert(validation.status>=400);
      }
    });
  } finally {await bucket.close();}
}});
