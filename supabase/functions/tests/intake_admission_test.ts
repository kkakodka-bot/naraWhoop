import assert from 'node:assert/strict';
import { validateIntakeEnvironment } from '../_shared/intakeConsumer.ts';
const revision='a'.repeat(40);
const base={INTAKE_WORKER_SOURCE_REVISION:revision,INTAKE_WORKER_INSTANCE_ID:'11111111-1111-4111-8111-111111111111',
  INTAKE_EXPECTED_SUPABASE_PROJECT:'abcdefghijklmnopqrst',SUPABASE_URL:'https://abcdefghijklmnopqrst.supabase.co',SUPABASE_SERVICE_ROLE_KEY:'synthetic-only'};
const owner='22222222-2222-4222-8222-222222222222',device='33333333-3333-4333-8333-333333333333';
Deno.test('production intake refuses missing ambiguous or partial admission configuration before any work',()=>{
  for(const extra of [{},{INTAKE_ADMISSION_MODE:'unknown'}, {INTAKE_ADMISSION_MODE:'canary'},
    {INTAKE_ADMISSION_MODE:'canary',INTAKE_CANARY_OWNER_ID:owner},
    {INTAKE_ADMISSION_MODE:'all-eligible',INTAKE_CANARY_OWNER_ID:owner,INTAKE_CANARY_DEVICE_ID:device},
    {INTAKE_ADMISSION_MODE:'canary',INTAKE_CANARY_OWNER_ID:owner,INTAKE_CANARY_DEVICE_ID:'bad-device'}]) {
    assert.throws(()=>validateIntakeEnvironment({...base,...extra},revision));
  }
});
Deno.test('production intake binds exactly one canonical owner and device or explicitly all eligible',()=>{
  const canary=validateIntakeEnvironment({...base,INTAKE_ADMISSION_MODE:'canary',INTAKE_CANARY_OWNER_ID:owner,INTAKE_CANARY_DEVICE_ID:device},revision);
  assert.deepEqual((canary as any).admission,{mode:'canary',ownerId:owner,deviceId:device});
  const all=validateIntakeEnvironment({...base,INTAKE_ADMISSION_MODE:'all-eligible'},revision);
  assert.deepEqual((all as any).admission,{mode:'all-eligible'});
});

import { createIntakeConsumer, runIntakeConsumer } from '../_shared/intakeConsumer.ts';
import { IntakeAdmissionError } from '../_shared/intakeAdmission.ts';
import { createSupabaseRest } from '../_shared/rest.ts';
const admission={mode:'canary' as const,ownerId:owner,deviceId:device};
const identity={processId:crypto.randomUUID(),instanceId:crypto.randomUUID(),sourceRevision:revision,admission};
const contract={contract_version:2,completion:'verified_indexed',projection:'atomic_lifecycle_v1',
  lanes:['verification','projection','legacy'],admission_modes:['canary','all-eligible']};

Deno.test('canary preflight rejects old schemas and validates active scope before any queue call',async()=>{
  for(const value of [{...contract,contract_version:1},{...contract,admission_modes:undefined}]) {
    const calls:string[]=[];
    const consumer=createIntakeConsumer({rpc:async(name:string)=>{calls.push(name);return value;}} as any,{} as any,identity);
    await assert.rejects(consumer.preflight(),/intake_contract_mismatch/);
    assert.deepEqual(calls,['noop_intake_consumer_contract']);
  }
  const calls:any[]=[];
  await createIntakeConsumer({rpc:async(name:string,args:unknown)=>{calls.push({name,args});return contract;}} as any,{} as any,identity).preflight();
  assert.deepEqual(calls[1],{name:'noop_intake_canary_validate',args:{p_user:owner,p_device:device}});
});

Deno.test('all three canary lanes use only scoped claims, immutable pair and versioned progress',async()=>{
  const calls:any[]=[];
  const input={...identity,admission:{...admission}};
  const rest={rpc:async(name:string,args:any)=>{calls.push({name,args});
    if(name==='noop_intake_reconcile_page_scoped') return [];
    return null;
  }};
  const consumer=createIntakeConsumer(rest as any,{} as any,input);
  input.admission.ownerId=crypto.randomUUID();
  for(const lane of ['verification','projection','legacy'] as const) await consumer.poll(lane);
  assert.deepEqual(calls.map(x=>x.name),['noop_claim_object_verification_scoped','noop_intake_consumer_poll_v2',
    'noop_seed_projection_debt_scoped','noop_claim_projection_debt_scoped','noop_intake_consumer_poll_v2',
    'noop_intake_reconcile_page_scoped','noop_intake_consumer_poll_v2']);
  for(const {args} of calls) {assert.equal(args.p_user_id,owner);assert.equal(args.p_device_id,device);}
});

Deno.test('a missing scoped RPC never falls back to global work',async()=>{
  for(const lane of ['verification','projection','legacy'] as const) {
    const calls:string[]=[];
    const consumer=createIntakeConsumer({rpc:async(name:string)=>{calls.push(name);throw Error('missing scoped RPC');}} as any,{} as any,identity);
    await assert.rejects(consumer.poll(lane),/missing scoped RPC/);
    assert.equal(calls.length,1);assert(calls[0].endsWith('_scoped'));
  }
});

Deno.test('returned sibling-device or foreign-owner rows fail before object I/O, settlement or progress',async()=>{
  for(const lane of ['verification','projection','legacy'] as const) {
    for(const bad of [{user_id:crypto.randomUUID(),device_id:device},{user_id:owner,device_id:crypto.randomUUID()}]) {
      const calls:string[]=[];
      const good={user_id:owner,device_id:device};
      const rest={rpc:async(name:string)=>{calls.push(name);
        if(name==='noop_seed_projection_debt_scoped') return 1;
        if(name==='noop_intake_reconcile_page_scoped') return [good,bad];
        return {manifest:bad};
      }};
      const raw=new Proxy({}, {get(){throw Error('object IO must not run');}});
      await assert.rejects(createIntakeConsumer(rest as any,raw as any,identity).poll(lane),IntakeAdmissionError);
      assert.equal(calls.some(x=>/poll_v2|finish|fail|defer|receipt/.test(x)),false);
    }
  }
});

Deno.test('SQL scope rejection survives REST mapping and terminates continuous lane scheduling',async()=>{
  const rest=createSupabaseRest({cfg:{supabaseUrl:'https://example.invalid',supabaseServiceRoleKey:'synthetic-only'},
    fetchImpl:async()=>new Response(JSON.stringify({code:'42501',message:'intake_admission_scope_mismatch'}),{status:403}) as any});
  let polls=0,sleeps=0;const reports:any[]=[];
  await assert.rejects(runIntakeConsumer({preflight:async()=>{},poll:async()=>{
    polls++;await rest.rpc('noop_claim_object_verification_scoped',{});throw Error('unreachable');
  }},{sleep:async()=>{sleeps++;},report:e=>reports.push(e)}),/intake_admission_scope_mismatch/);
  assert.equal(polls,3);assert.equal(sleeps,0);
  assert(reports.every(x=>x.error==='intake_admission_scope_mismatch'));
});
