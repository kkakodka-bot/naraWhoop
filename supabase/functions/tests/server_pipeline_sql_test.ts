import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { createSupabaseRest } from '../_shared/rest.ts';
import { handleScoresRequest } from '../_shared/serverScores.ts';

const container = Deno.env.get('PIPELINE_TEST_DATABASE_CONTAINER');
const restUrl = Deno.env.get('PIPELINE_TEST_REST_URL');
const output = Deno.env.get('PIPELINE_TEST_OUTPUT');
const day = '2026-09-15';
const owner = '11111111-1111-4111-8111-111111111111';
const other = '22222222-2222-4222-8222-222222222222';
const source = '33333333-3333-4333-8333-333333333333';
const secondSource = '44444444-4444-4444-8444-444444444444';
const allFeatures = ['sleep', 'hrv', 'respiration'];

async function sql(statement: string): Promise<string> {
  const process = new Deno.Command('docker', { args: ['exec', '-i', container!, 'psql', '-U', 'postgres',
    '-d', 'postgres', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1'], stdin: 'piped', stdout: 'piped', stderr: 'piped' }).spawn();
  const writer = process.stdin.getWriter();
  await writer.write(new TextEncoder().encode(statement));
  await writer.close();
  const result = await process.output();
  assert.equal(result.code, 0, new TextDecoder().decode(result.stderr));
  return new TextDecoder().decode(result.stdout).trim();
}

Deno.test({ name: 'real SQL -> enrolled Edge contract, qualification, isolation, and diagnostic stages',
  ignore: !container, sanitizeOps: false, sanitizeResources: false, fn: async () => {
  assert.match(container!, /^nara-db-server-pipeline\.[a-z0-9]+$/);
  assert.match(restUrl!, /^http:\/\/127\.0\.0\.1:\d+$/);
  assert.ok(output);
  const inspection = await new Deno.Command('docker', { args: ['inspect', container!, '--format',
    '{{index .Config.Labels "nara.test"}}'] }).output();
  assert.equal(new TextDecoder().decode(inspection.stdout).trim(), 'server-pipeline');
  const jwtBody = btoa(JSON.stringify({ role: 'service_role', exp: Math.floor(Date.now() / 1000) + 3600 })).replaceAll('=', '');
  const jwtHeader = btoa(JSON.stringify({ alg: 'HS256', typ: 'JWT' })).replaceAll('=', '');
  const token = `${jwtHeader}.${jwtBody}.${createHmac('sha256', 'isolated-pipeline-jwt-secret-never-used-outside-tests')
    .update(`${jwtHeader}.${jwtBody}`).digest('base64url')}`;
  // PostgREST runs without Kong in this isolated test. Only the URL prefix is adapted.
  const rest = createSupabaseRest({ cfg: { supabaseUrl: restUrl!, supabaseServiceRoleKey: token },
    fetchImpl: (input, init) => fetch(String(input).replace('/rest/v1/', '/'), {
      ...init,signal:AbortSignal.timeout(15_000),
    }) });
  for (let attempt = 0; attempt < 60; attempt++) {
    try { await rest.select('devices', 'select=id&limit=1'); break; }
    catch (error) { if (attempt === 59) throw error; await new Promise(resolve => setTimeout(resolve, 250)); }
  }
  await sql(`
    insert into auth.users(id) values ('${owner}'),('${other}');
    insert into profiles(id,timezone) values ('${owner}','UTC'),('${other}','UTC') on conflict(id) do update set timezone='UTC';
    insert into noop_enrollment_codes(id,user_id,code_hash,expires_at) values
      ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','${owner}',repeat('a',64),now()+interval '1 day'),
      ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','${other}',repeat('b',64),now()+interval '1 day');
    insert into noop_app_installations(source_id,user_id,enrollment_code_id,platform,app_version) values
      ('${source}','${owner}','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','ios','pipeline-test'),
      ('${secondSource}','${other}','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','android','pipeline-test');
    insert into noop_ingest_tokens(user_id,token_hash,token_kind,source_id,enrollment_code_id) values
      ('${owner}',encode(sha256(convert_to('noop_pipeline_a','UTF8')),'hex'),'installation','${source}','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
      ('${other}',encode(sha256(convert_to('noop_pipeline_b','UTF8')),'hex'),'installation','${secondSource}','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'),
      (null,encode(sha256(convert_to('noop_pipeline_fleet','UTF8')),'hex'),'fleet',null,null);
  `);
  const cfg = { supabaseUrl: restUrl!, supabaseAnonKey: 'isolated-test-public' };
  async function request(device: string, who = 'a', route = '/', body?: unknown) {
    return await handleScoresRequest(new Request(`http://localhost/functions/v1/scores${route}?day=${day}&deviceId=${device}`, {
      method: body === undefined ? 'GET' : 'POST', headers: { authorization: `Bearer noop_pipeline_${who}`,
        'x-noop-fleet-token': 'noop_pipeline_fleet', 'content-type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body),
    }), { rest, cfg });
  }
  const identities: any[] = [];
  for (const [who, local] of [['a','whoop-TESTA001'],['a','whoop-TESTA002'],['b','whoop-TESTB001'],['b','whoop-TESTB002']]) {
    const response = await request(local,who,'/devices',{deviceId:local});
    assert.equal(response.status,200,await response.clone().text());
    identities.push((await response.json()).identity);
  }
  const device = identities[0].deviceId;
  await rest.rpc('server_scoring_for_device_day',{p_user:owner,p_day:day,p_device:device});
  const expectations: any[] = [];
  await Deno.mkdir(output!, { recursive: true });
  async function capture(name: string, available: string[], nestedHrv = false, nestedRespiration = false, local = 'whoop-TESTA001') {
    const response = await request(local);
    assert.equal(response.status,200,await response.clone().text());
    assert.equal(response.headers.get('cache-control'),'no-store');
    const bytes = await response.text();
    const body = JSON.parse(bytes);
    assert.equal(body.identity.userId,owner);
    const score = body.server_scoring;
    for (const key of allFeatures) {
      assert.equal(['available','stale'].includes(score.features[key].status),available.includes(key),`${name}: ${key}`);
      if (score.features[key].device_id) assert.equal(score.features[key].device_id,body.identity.deviceId);
    }
    for (const night of score.nights) {
      if (!nestedHrv) assert.equal(night.hrv_rmssd_ms,undefined,`${name} leaks nested HRV`);
      if (!nestedRespiration) assert.equal(night.resp_rate_bpm,undefined,`${name} leaks nested respiration`);
    }
    await Deno.writeTextFile(`${output}/${name}.json`,bytes);
    expectations.push({file:`${name}.json`,ownerId:owner,day,availableFeatures:available,
      unavailableFeatures:allFeatures.filter(key=>!available.includes(key)),
      nestedHrvAvailable:nestedHrv,nestedRespirationAvailable:nestedRespiration,expectedDeviceId:body.identity.deviceId,
      expectedValues:name==='approved-v2'?{hrv:0,sleep:420,respiration:14}:name==='sleep-only'?{sleep:420}:undefined});
    return score;
  }
  await capture('missing',[]);
  const baselineBinary = Deno.env.get('PIPELINE_TEST_V1_BINARY');
  const physiologyBinary = Deno.env.get('PIPELINE_TEST_V2_BINARY');
  if (baselineBinary || physiologyBinary) {
    assert.ok(baselineBinary && physiologyBinary, 'both real worker binaries are required');
    const workerDay = '2026-09-14';
    const ts = Math.floor(Date.parse(`${workerDay}T12:00:00Z`) / 1000);
    const sourceRevision = new TextDecoder().decode((await new Deno.Command('git', { args: ['rev-parse', 'HEAD'] }).output()).stdout).trim();
    for (const [index, identity] of identities.entries()) {
      const batch = crypto.randomUUID();
      const rows = Array.from({length:600},(_,n)=>({user_id:identity.userId,device_id:identity.deviceId,
        source_id:identity.sourceId,batch_id:batch,ts:ts+n,bpm:60+index*10}));
      const args = {p_user:identity.userId,p_device:identity.deviceId,p_source:identity.sourceId,
        p_batch:batch,p_stream:'hrSample',p_rows:rows};
      assert.equal(await rest.rpc('noop_project_append_batch',args),600);
      const revision = await sql(`select input_revision from physiology_work_items where user_id='${identity.userId}' and device_id='${identity.deviceId}' and day='${workerDay}';`);
      assert.equal(await rest.rpc('noop_project_append_batch',args),600);
      assert.equal(await sql(`select input_revision from physiology_work_items where user_id='${identity.userId}' and device_id='${identity.deviceId}' and day='${workerDay}';`),revision,'duplicate batch does not dirty revision');
      assert.ok(Number(await sql(`select count(*) from scoring_jobs_v2 where user_id='${identity.userId}'
        and device_id='${identity.deviceId}' and day='${workerDay}' and algorithm_version='frwhoop-server-1';`))>0,
        'historical queue coexistence must not suppress fenced baseline publication');
      const workerBinaries: Array<[string,string]> = [['frwhoop-server-1',baselineBinary],['frwhoop-physiology-2',physiologyBinary]];
      for (const [version,binary] of workerBinaries) {
        const child: Deno.ChildProcess = new Deno.Command(binary, { args:['--replay-day'], clearEnv:true,
          env:{PATH:Deno.env.get('PATH')!,JAVA_HOME:Deno.env.get('JAVA_HOME')!,
            DATABASE_URL:Deno.env.get('PIPELINE_TEST_DATABASE_URL')!,
            SUPABASE_URL:restUrl!,SUPABASE_SERVICE_ROLE_KEY:token,INGEST_SECRET:'isolated-pipeline-only',
            SCORING_ALGORITHM_VERSION:version!,REPLAY_USER_ID:identity.userId,REPLAY_DEVICE_ID:identity.deviceId,REPLAY_DAY:workerDay,
            SCORING_WORKER_INSTANCE_ID:crypto.randomUUID(),SCORING_WORKER_SOURCE_REVISION:sourceRevision},
          stdout:'piped',stderr:'piped' }).spawn();
        const timeout=setTimeout(()=>{try {child.kill('SIGTERM');} catch { /* Already exited. */ }},120_000);
        const result: Deno.CommandOutput = await child.output(); clearTimeout(timeout);
        const log=new TextDecoder().decode(result.stdout)+new TextDecoder().decode(result.stderr);
        await Deno.writeTextFile(`${output}/worker-${index}-${version}.log`,log);
        assert.equal(result.code,0,log);
        const published=JSON.parse(await sql(`select jsonb_build_object('revision',input_revision,'device',device_id)
          from server_physiology_results where user_id='${identity.userId}' and device_id='${identity.deviceId}'
          and period_day='${workerDay}' and algorithm_version='${version}' order by input_revision desc limit 1;`));
        assert.equal(published.device,identity.deviceId);
        assert.ok(published.revision>0,'actual worker published');
      }
      const response=await handleScoresRequest(new Request(`http://localhost/functions/v1/scores?day=${workerDay}&deviceId=${identity.externalDeviceId}`,{
        headers:{authorization:`Bearer noop_pipeline_${identity.userId===owner?'a':'b'}`,'x-noop-fleet-token':'noop_pipeline_fleet'},
      }),{rest,cfg});
      assert.equal(response.status,200,await response.clone().text());
      const bytes=await response.text(); const body=JSON.parse(bytes);
      assert.equal(body.server_scoring.algorithm_version,'frwhoop-server-1','v2 shadow cannot replace retained v1');
      assert.equal(body.server_scoring.daily.source_device_id,identity.deviceId);
      await Deno.writeTextFile(`${output}/worker-${index}.json`,bytes);
      const available=allFeatures.filter(key=>['available','stale'].includes(body.server_scoring.features[key].status));
      assert.equal(available.length,3,'retained v1 publication is readable, even with null unsupported measurements');
      expectations.push({file:`worker-${index}.json`,ownerId:identity.userId,day:workerDay,
        availableFeatures:available,unavailableFeatures:[],expectedDeviceId:identity.deviceId,
        nestedHrvAvailable:false,nestedRespirationAvailable:false});
    }
    // Read every device again after both devices for each owner have published. The old
    // user/day upsert table cannot substitute the most recently scored sibling device.
    for (const identity of identities) {
      const result=await rest.rpc('server_scoring_for_device_day',{
        p_user:identity.userId,p_device:identity.deviceId,p_day:workerDay});
      assert.equal(result.daily.source_device_id,identity.deviceId);
      for (const feature of allFeatures) assert.equal(result.features[feature].device_id,identity.deviceId);
    }
    // Serializer regression: the compatibility sleep table has a user/start/version key.
    // Concurrent owned devices with the same start must retain separate immutable episodes.
    await Promise.all(identities.slice(0,2).map(async(identity,index)=>{
      const previous=await rest.rpc('server_scoring_for_device_day',{
        p_user:owner,p_device:identity.deviceId,p_day:workerDay});
      await rest.rpc('scoring_enqueue_legacy_fenced',{
        p_user:owner,p_device:identity.deviceId,p_day:workerDay,p_timezone:'UTC',p_debounce_seconds:0});
      const [claim]=await rest.rpc('scoring_legacy_claim_one',{
        p_user:owner,p_device:identity.deviceId,p_day:workerDay});
      await rest.rpc('engine_publish_legacy_fenced',{p_secret:'isolated-pipeline-only',p_payload:{
        user_id:owner,device_id:identity.deviceId,day:workerDay,algorithm_version:'frwhoop-server-1',
        input_revision:claim.input_revision,lease_token:claim.lease_token,run_id:claim.run_id,
        daily_metrics:[previous.daily],sleep_nights:[{device_id:identity.deviceId,period_day:workerDay,
          start_at:`${workerDay}T00:00:00Z`,end_at:`${workerDay}T08:00:00Z`,is_nap:false,
          asleep_min:360+index*30,in_bed_min:480,stages:[],hypnogram:[]}],
      }});
      assert.equal(await rest.rpc('scoring_legacy_finish_work',{
        p_user:owner,p_device:identity.deviceId,p_day:workerDay,p_revision:claim.input_revision,
        p_lease_token:claim.lease_token,p_run_id:claim.run_id,p_outcome:'done'}),true);
    }));
    for (const [index,identity] of identities.slice(0,2).entries()) {
      const result=await rest.rpc('server_scoring_for_device_day',{
        p_user:owner,p_device:identity.deviceId,p_day:workerDay});
      assert.equal(result.nights.length,1);
      assert.equal(result.nights[0].device_id,identity.deviceId);
      assert.equal(result.nights[0].asleep_min,360+index*30);
    }
    // The forward serializer repair must retain private entrypoints, immutable retries,
    // and the same live revision/lease checks even when the history queue owns a key.
    assert.equal(await sql(`select has_function_privilege('service_role',
      'internal.engine_ingest_scored(text,jsonb)','EXECUTE');`),'f');
    assert.equal(await sql(`select has_function_privilege('service_role',
      'public.engine_ingest_scored_legacy_internal(text,jsonb)','EXECUTE');`),'f');
    for (const name of ['engine_publish_legacy_fenced','engine_publish_physiology']) {
      assert.equal(await sql(`select has_function_privilege('service_role','internal.${name}(text,jsonb)','EXECUTE');`),'f');
    }
    await assert.rejects(()=>rest.rpc('engine_ingest_scored',{
      p_secret:'isolated-pipeline-only',p_payload:{}}),/token-aware baseline publication required/);
    const retained=JSON.parse(await sql(`select payload from server_physiology_results where user_id='${owner}'
      and device_id='${device}' and period_day='${workerDay}' and algorithm_version='frwhoop-server-1'
      order by input_revision desc limit 1;`));
    await rest.rpc('scoring_enqueue_legacy_fenced',{
      p_user:owner,p_device:device,p_day:workerDay,p_timezone:'UTC',p_debounce_seconds:0});
    const [claim]=await rest.rpc('scoring_legacy_claim_one',{p_user:owner,p_device:device,p_day:workerDay});
    const fenced={user_id:owner,device_id:device,day:workerDay,algorithm_version:'frwhoop-server-1',
      input_revision:claim.input_revision,lease_token:claim.lease_token,run_id:claim.run_id,
      daily_metrics:[retained.daily],sleep_nights:retained.nights};
    const first=await rest.rpc('engine_publish_legacy_fenced',{p_secret:'isolated-pipeline-only',p_payload:fenced});
    await rest.rpc('engine_publish_legacy_fenced',{p_secret:'isolated-pipeline-only',
      p_payload:{...fenced,daily_metrics:[{...retained.daily,hrv_rmssd_ms:999}]}});
    assert.equal(await sql(`select payload_hash from server_physiology_results where user_id='${owner}'
      and device_id='${device}' and period_day='${workerDay}' and algorithm_version='frwhoop-server-1'
      and input_revision=${claim.input_revision};`),first.payload_hash,'retry cannot mutate accepted snapshot');
    await rest.rpc('scoring_enqueue_legacy_fenced',{
      p_user:owner,p_device:device,p_day:workerDay,p_timezone:'UTC',p_debounce_seconds:0});
    const conflictStarted=performance.now();
    await assert.rejects(()=>rest.rpc('engine_publish_legacy_fenced',{
      p_secret:'isolated-pipeline-only',p_payload:fenced}),/\(409\) stale scoring lease or input revision/);
    assert.ok(performance.now()-conflictStarted<5000,'stale lease is a bounded conflict, not a PostgREST retry loop');
  }
  // Test-only signed evidence uses the real signature verifier and selection guard.
  await sql(`create schema pipeline_test; revoke all on schema pipeline_test from public;
    create function pipeline_test.approve(f text) returns uuid language plpgsql as $body$
    declare m jsonb; a jsonb; canon text; algorithm_hash text; mh text; result uuid:=gen_random_uuid();
      kid text:=encode(sha256(decode(repeat('a',64),'hex')),'hex');
    begin
      select manifest_hash into algorithm_hash from physiology_algorithm_versions where algorithm_version='frwhoop-physiology-2';
      insert into internal.physiology_approval_keys values (kid,decode(repeat('a',64),'hex'),'disposable-test',null) on conflict do nothing;
      m:=jsonb_build_object('algorithm_version','frwhoop-physiology-2','feature',f,'checkpoint_sha256',repeat('c',64),
        'preprocessing_version','test-1','preprocessing_sha256',repeat('d',64),'quality_policy_version','test-1','quality_policy_sha256',repeat('e',64));
      canon:=m::text; mh:=encode(sha256(convert_to(canon,'UTF8')),'hex');
      insert into physiology_feature_manifests values ('frwhoop-physiology-2',f,m,canon,mh,algorithm_hash,
        repeat('c',64),'test-1',repeat('d',64),'test-1',repeat('e',64),now()) on conflict do nothing;
      a:=m||jsonb_build_object('schema_version',1,'purpose','physiology_feature_promotion','approval_id',result,
        'key_id',kid,'reviewer','disposable-test','decision','approved','manifest_sha256',mh,
        'algorithm_manifest_sha256',algorithm_hash,'evaluation_sha256',repeat('b',64),'policy_sha256',repeat('a',64),
        'reference_artifact_sha256',repeat('f',64),'reference_kind',case f when 'hrv' then 'synchronized_ecg_nn'
          when 'sleep' then 'psg_30s_and_sleep_opportunities' else 'synchronized_respiratory_reference' end,
        'evaluation_partition','test','participant_disjoint',true,'functional_gates_passed',true,'promotion_policy_passed',true,
        'policy_frozen_at','2020-01-01T00:00:00Z','evaluation_started_at','2020-01-02T00:00:00Z',
        'evaluation_finished_at','2020-01-03T00:00:00Z','approved_at','2020-01-04T00:00:00Z');
      perform set_config('request.jwt.claim.role','service_role',true);
      perform register_physiology_promotion(a::text,encode(extensions.hmac(convert_to(a::text,'UTF8'),decode(repeat('a',64),'hex'),'sha256'),'hex'));
      update physiology_feature_qualifications set qualification='reference_qualified',policy_sha256=repeat('a',64),evaluation_sha256=repeat('b',64),
        signed_policy=jsonb_build_object('payload',jsonb_build_object('metric_family',f),'signature',jsonb_build_object('algorithm','HMAC-SHA256')),
        signed_evaluation=jsonb_build_object('payload',jsonb_build_object('policy_sha256',repeat('a',64)),'signature',jsonb_build_object('algorithm','HMAC-SHA256')),
        reviewed_by='disposable-test',reviewed_at=now() where algorithm_version='frwhoop-physiology-2' and feature=f;
      return result;
    end $body$;
  `);
  async function publish(mismatch = false) {
    await rest.rpc('physiology_enqueue_day',{p_user:owner,p_device:device,p_day:day,p_timezone:'UTC',p_debounce_seconds:0});
    const [claim] = await rest.rpc('scoring_claim_one',{p_user:owner,p_device:device,p_day:day});
    assert.ok(claim,'real queue claim');
    const hashes = Object.fromEntries((await rest.select('physiology_feature_manifests','select=feature,manifest_sha256'))
      .map((row:any)=>[row.feature,mismatch?'0'.repeat(64):row.manifest_sha256]));
    const start = Math.floor(Date.parse(`${day}T00:00:00Z`)/1000);
    const payload = {schema_version:2,user_id:owner,device_id:device,day,algorithm_version:'frwhoop-physiology-2',
      input_revision:claim.input_revision,lease_token:claim.lease_token,run_id:claim.run_id,
      computed_at:new Date().toISOString(),publication_status:'provisional',feature_manifest_hashes:hashes,
      daily:{day,source_device_id:device,hrv_rmssd_ms:0,hrv_sdnn_ms:0,resting_hr_bpm:60,resp_rate_bpm:14,sleep_total_min:420,
        sleep_efficiency:0.875,sleep_in_bed_min:480,sleep_awake_min:60,sleep_light_min:240,sleep_deep_min:120,sleep_rem_min:60},
      nights:[{id:'55555555-5555-4555-8555-555555555555',device_id:device,period_day:day,
        start_at:`${day}T00:00:00Z`,end_at:`${day}T08:00:00Z`,start,end:start+28800,is_nap:false,
        asleep_min:420,in_bed_min:480,awake_min:60,light_min:240,deep_min:120,rem_min:60,efficiency:0.875,
        hrv_rmssd_ms:0,hrv_sdnn_ms:0,resting_hr_bpm:60,resp_rate_bpm:14,stages:[],measurement_available:true}],measurements:[]};
    await rest.rpc('engine_publish_physiology',{p_secret:'isolated-pipeline-only',p_payload:payload});
    assert.equal(await rest.rpc('scoring_finish_work',{p_user:owner,p_device:device,p_day:day,p_revision:claim.input_revision,
      p_lease_token:claim.lease_token,p_run_id:claim.run_id,p_outcome:'done',p_duration_ms:1,p_error:null}),true);
    await assert.rejects(()=>rest.rpc('engine_publish_physiology',{
      p_secret:'isolated-pipeline-only',p_payload:payload}),/\(409\) stale scoring lease or input revision/);
  }
  await publish();
  await capture('shadow',[]);
  await sql(`do $$ begin
    begin update physiology_feature_defaults set algorithm_version='frwhoop-physiology-2';
      raise exception 'unsigned selection accepted'; exception when sqlstate '22023' then null; end;
  end $$;`);
  await capture('missing-approval',[]);
  for (const feature of allFeatures) await sql(`select pipeline_test.approve('${feature}');`);
  await publish();
  await sql("update physiology_feature_defaults set algorithm_version='frwhoop-physiology-2';");
  const approved = await capture('approved-v2',allFeatures,true,true);
  assert.equal(approved.daily.hrv_rmssd_ms,0,'valid zero is retained');
  await sql(`begin; select set_config('request.jwt.claim.sub','${owner}',true);
    select select_physiology_source(feature,'${device}','frwhoop-physiology-2') from physiology_feature_defaults; commit;`);
  const account = await rest.rpc('server_scoring_for_day',{p_user:owner,p_day:day});
  assert.deepEqual(account,approved,'account and enrolled SQL wrappers share serialization');
  const accountBody = btoa(JSON.stringify({role:'authenticated',sub:owner,exp:Math.floor(Date.now()/1000)+3600})).replaceAll('=','');
  const accountToken = `${jwtHeader}.${accountBody}.${createHmac('sha256','isolated-pipeline-jwt-secret-never-used-outside-tests')
    .update(`${jwtHeader}.${accountBody}`).digest('base64url')}`;
  const accountRest = createSupabaseRest({cfg:{supabaseUrl:restUrl!,supabaseServiceRoleKey:accountToken},
    fetchImpl:(input,init)=>fetch(String(input).replace('/rest/v1/','/'),init)});
  assert.deepEqual(await accountRest.rpc('server_scoring_for_day',{p_user:owner,p_day:day}),approved);
  await assert.rejects(()=>accountRest.rpc('server_scoring_for_day',{p_user:other,p_day:day}),/403/);
  await assert.rejects(()=>rest.rpc('server_scoring_for_device_day',{p_user:owner,p_device:identities[2].deviceId,p_day:day}),/403/);
  await sql(`delete from physiology_source_selection where user_id='${owner}';`);
  await sql("update physiology_feature_defaults set algorithm_version='frwhoop-server-1' where feature<>'sleep';");
  await capture('sleep-only',['sleep']);
  await sql("insert into physiology_promotion_revocations(approval_id,reason) select approval_id,'disposable revocation test' from physiology_promotion_approvals where feature='sleep';");
  const revoked = await capture('revoked',[]);
  assert.equal(revoked.features.sleep.reason,'unqualified_version');
  await sql("select pipeline_test.approve('sleep'); update physiology_feature_defaults set algorithm_version='frwhoop-physiology-2';");
  await publish(true);
  const mismatched = await capture('manifest-mismatch',[]);
  assert.equal(mismatched.features.sleep.reason,'manifest_mismatch');
  await capture('other-device-missing',[],false,false,'whoop-TESTA002');
  const cross = await request('whoop-TESTA001','b');
  assert.equal((await cross.json()).identity.deviceId,null);
  for (const identity of identities) {
    const who=identity.userId===owner?'a':'b';
    const diagnostic = await request(identity.externalDeviceId,who,'/diagnostics');
    assert.equal(diagnostic.status,200,await diagnostic.clone().text());
    const report = await diagnostic.json();
    assert.equal(report.read_rpc,'server_scoring_for_device_day');
    assert.equal(report.stages.acquired.status,'not_measured');
    assert.equal(report.stages.displayed.status,'not_measured');
    assert.equal(report.capabilities.hrv_timing.reason,'continuity_unverified');
    const encoded=JSON.stringify(report);
    assert.ok(!encoded.includes(identity.userId) && !encoded.includes(identity.deviceId));
    assert.ok(!encoded.includes('hrv_rmssd_ms') && !encoded.includes('resp_rate_bpm'));
  }
  await Deno.writeTextFile(`${output}/expectations.json`,JSON.stringify(expectations,null,2));
  await Deno.writeTextFile(`${output}/identities.json`,JSON.stringify(identities,null,2));
}});
