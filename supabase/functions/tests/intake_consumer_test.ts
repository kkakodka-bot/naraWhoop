import assert from 'node:assert/strict';
import { asyncVerificationAvailable, objectCompletionResponse } from '../_shared/objectVerification.ts';
import { runIntakeConsumer, validateIntakeEnvironment } from '../_shared/intakeConsumer.ts';

Deno.test('async admission requires opt-in and compatible successful queue service; existing debt drains', async () => {
  let calls=0;
  const ready={rpc:async()=>{calls++;return true;}};
  assert.equal(await asyncVerificationAvailable({asyncObjectVerification:false},ready),false);assert.equal(calls,0);
  assert.equal(await asyncVerificationAvailable({asyncObjectVerification:true},ready),true);
  assert.equal(await asyncVerificationAvailable({asyncObjectVerification:true},{rpc:async()=>false}),false);
  assert.equal(await asyncVerificationAvailable({asyncObjectVerification:true},{rpc:async()=>{throw Error('offline');}}),false);
  let enqueues=0;
  const enqueue=async()=>{enqueues++;return {status:503,retryAfter:'15',body:{type:'error',protocolVersion:'1.3',objectId:'11111111-1111-4111-8111-111111111111',state:'pending_verification',code:'verification_pending'}};};
  const absent=await objectCompletionResponse({mode:'async-v1',hasDebt:async()=>false,
    completeSync:async()=>{throw Error('must not verify');},enqueue});
  assert.equal(absent.status,503);assert.equal((await absent.json()).code,'verification_consumer_unavailable');assert.equal(enqueues,0);
  const old=await objectCompletionResponse({mode:'async-v1',hasDebt:async()=>true,
    completeSync:async()=>{throw Error('must not verify');},enqueue,allowNewAsync:async()=>false});
  assert.equal(old.status,503);assert.equal((await old.json()).code,'verification_pending');assert.equal(enqueues,1);
  const admitted=await objectCompletionResponse({mode:'async-v1',hasDebt:async()=>false,
    completeSync:async()=>{throw Error('must not verify');},enqueue,allowNewAsync:async()=>true});
  assert.equal(admitted.status,503);await admitted.body?.cancel();assert.equal(enqueues,2);
});

Deno.test('intake startup binds packaged source and configured hosted project', () => {
  const revision='a'.repeat(40);
  const env={INTAKE_ADMISSION_MODE:'all-eligible',INTAKE_WORKER_SOURCE_REVISION:revision,INTAKE_WORKER_INSTANCE_ID:'11111111-1111-4111-8111-111111111111',
    INTAKE_EXPECTED_SUPABASE_PROJECT:'abcdefghijklmnopqrst',SUPABASE_URL:'https://abcdefghijklmnopqrst.supabase.co',SUPABASE_SERVICE_ROLE_KEY:'synthetic-only'};
  assert.equal(validateIntakeEnvironment(env,revision+'\n').sourceRevision,revision);
  for(const variant of [
    {...env,SUPABASE_URL:'https://another-project.supabase.co'},
    {...env,SUPABASE_URL:'http://abcdefghijklmnopqrst.supabase.co'},
    {...env,SUPABASE_URL:'https://abcdefghijklmnopqrst.supabase.co/rest/v1'},
    {...env,INTAKE_WORKER_SOURCE_REVISION:'b'.repeat(40)},
    {...env,INTAKE_WORKER_INSTANCE_ID:''},
  ]) assert.throws(()=>validateIntakeEnvironment(variant,revision));
});

Deno.test('slow raw verification cannot block the independent projection lane', async () => {
  const events:string[]=[];
  let finishRaw!:()=>void;
  const held=new Promise<void>((resolve)=>{finishRaw=resolve;});
  const run=runIntakeConsumer({preflight:async()=>{events.push('preflight');},poll:async(lane)=>{
    events.push('begin:'+lane);
    if(lane==='verification') await held;
    events.push('end:'+lane);
    return {lane,claimed:1,completed:1,failures:0};
  }},{once:true});
  await new Promise((resolve)=>setTimeout(resolve,5));
  assert(events.includes('end:projection'));assert(!events.includes('end:verification'));
  finishRaw();await run;
});

Deno.test('one-shot intake worker fails on an actual lane failure', async () => {
  const events:unknown[]=[];
  await assert.rejects(runIntakeConsumer({preflight:async()=>{},poll:async()=>{throw Error('private service failure');}},
    {once:true,report:(event)=>events.push(event)}),/intake_lane_failed/);
  assert.equal(JSON.stringify(events).includes('private'),false);
});
