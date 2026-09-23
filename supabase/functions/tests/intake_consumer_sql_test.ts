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
  const owner2=crypto.randomUUID(),source2=crypto.randomUUID(),device2=crypto.randomUUID(),code2=crypto.randomUUID();
  await sql(`insert into auth.users(id) values('${owner}'),('${owner2}');
    insert into public.noop_enrollment_codes(id,user_id,code_hash,expires_at)
      values('${code}','${owner}',repeat('a',64),now()+interval '1 day'),('${code2}','${owner2}',repeat('b',64),now()+interval '1 day');
    insert into public.noop_app_installations(source_id,user_id,enrollment_code_id,platform,app_version)
      values('${source}','${owner}','${code}','ios','fixture'),('${source2}','${owner2}','${code2}','android','fixture');
    insert into public.devices(id,user_id,source_kind,external_device_id)
      values('${device}','${owner}','noop_push','fixture-a'),('${device2}','${owner2}','noop_push','fixture-b');`);
  const objects=createPushObjects({cfg,rest,raw:bucket.raw,resolveDeviceId:async({userId})=>userId===owner?device:device2});
  const archive=createPushArchive({cfg,rest,raw:bucket.raw});
  const ingest=createPushIngest({walStore:createPushWalStore({rest})!,archiveObject:archive.archiveObject,
    resolveDeviceId:async()=>device,commitProjection:(receipt,bytes)=>commitArchivedBatch(rest,receipt,bytes)});
  const identity={processId:crypto.randomUUID(),instanceId:crypto.randomUUID(),sourceRevision:'a'.repeat(40)};
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
    const who=which===0?scope:{userId:owner2,sourceId:source2,authMode:'installation' as const};
    const bytes=new TextEncoder().encode('synthetic waveform bytes');const wire=new Uint8Array(gzipSync(bytes));
    const start=latest()-(historical?86400:0),id=crypto.randomUUID();
    const intent=await objects.createIntent({...who,manifest:{type:'binaryObject',protocolVersion:'1.3',stream:'ppgWaveformSample',deviceId:which===0?'fixture-a':'fixture-b',
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
      await assert.rejects(rest.rpc('noop_intake_consumer_poll',{p_process:identity.processId,p_instance:crypto.randomUUID(),p_source_revision:identity.sourceRevision,
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
    await t.step('anonymous and account roles cannot claim or announce consumer readiness',async()=>{
      for(const role of ['anon','authenticated']) {
        const response=await fetch(`${origin}/rpc/noop_intake_consumer_poll`,{method:'POST',headers:{authorization:`Bearer ${token(role)}`,'content-type':'application/json'},
          body:JSON.stringify({p_process:crypto.randomUUID(),p_instance:crypto.randomUUID(),p_source_revision:'b'.repeat(40),p_lane:'verification',p_claimed:0,p_completed:0,p_failures:0})});
        await response.body?.cancel();assert(response.status>=400);
      }
    });
  } finally {await bucket.close();}
}});
