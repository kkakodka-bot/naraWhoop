import assert from 'node:assert/strict';
import { createHash, createHmac } from 'node:crypto';
import { createSupabaseRest } from '../_shared/rest.ts';
import { handleScoresRequest } from '../_shared/serverScores.ts';
import { createPushArchive, createPushIngest } from '../_shared/ingest.ts';
import { createPushWalStore } from '../_shared/wal.ts';
import { commitArchivedBatch } from '../_shared/projections.ts';
import { createNoopDeviceResolver } from '../_shared/devices.ts';
import { createUploadReceiptStore } from '../_shared/receipts.ts';
import { resolveUploadIdentity } from '../_shared/tokens.ts';
import { pushConfig } from '../_shared/config.ts';
import { startObjectHttp } from './local_objects.ts';

const container = Deno.env.get('PIPELINE_TEST_DATABASE_CONTAINER');
const restUrl = Deno.env.get('PIPELINE_TEST_REST_URL');
const authUrl = Deno.env.get('PIPELINE_TEST_AUTH_URL');
const output = Deno.env.get('PIPELINE_TEST_OUTPUT');
const day = '2026-09-15';
const source = '33333333-3333-4333-8333-333333333333';
const secondSource = '44444444-4444-4444-8444-444444444444';
const allFeatures = ['sleep', 'hrv', 'respiration'];
const sleepCompatibilityKeys = ['full_day_sleep_epochs', 'main_sleep_group_id', 'off_body_min',
  'opportunity_kind', 'sleep_onset_at', 'sleep_unstaged_min', 'state_unknown_min', 'wake_onset_at'];

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
  assert.match(authUrl!, /^http:\/\/127\.0\.0\.1:\d+$/);
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
  // Real isolated GoTrue issues and validates the account credential. Only the
  // Kong URL prefix is adapted; no user/authentication response is fabricated.
  for (let attempt = 0; attempt < 60; attempt++) {
    try {
      const response=await fetch(`${authUrl}/health`,{signal:AbortSignal.timeout(2000)});
      await response.body?.cancel();
      if (!response.ok) throw new Error('auth_not_ready');
      break;
    } catch(error) { if(attempt===59) throw error; await new Promise(resolve=>setTimeout(resolve,250)); }
  }
  async function signup(name:string) {
    const response=await fetch(`${authUrl}/signup`,{method:'POST',headers:{'content-type':'application/json'},
      body:JSON.stringify({email:`pipeline-${name}@example.test`,password:'isolated-test-password-never-production'}),
      signal:AbortSignal.timeout(15000)});
    assert.equal(response.status,200,await response.clone().text());
    const session=await response.json();
    assert.match(session.user.id,/^[a-f0-9-]{36}$/);
    assert.equal(typeof session.access_token,'string');
    return session;
  }
  const ownerSession=await signup('owner');
  const otherSession=await signup('other');
  const owner=ownerSession.user.id;
  const other=otherSession.user.id;
  const accountToken=ownerSession.access_token;
  await sql(`
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
  async function accountRequest(device: string, requestSource=source, requestedDay=day, bearer=accountToken) {
    return await handleScoresRequest(new Request(`http://localhost/functions/v1/scores?day=${requestedDay}&deviceId=${device}`, {
      headers:{authorization:`Bearer ${bearer}`,'x-noop-source-id':requestSource},
    }),{rest,cfg,fetchImpl:async(input,init)=>{
      assert.equal(String(input),`${restUrl}/auth/v1/user`);
      return fetch(`${authUrl}/user`,{...init,signal:AbortSignal.timeout(15000)});
    }});
  }
  const tokenParts=accountToken.split('.');
  tokenParts[2]=(tokenParts[2][0]==='a'?'b':'a')+tokenParts[2].slice(1);
  assert.equal((await accountRequest('whoop-TESTA001',source,day,tokenParts.join('.'))).status,401,
    'actual Auth must reject an invalid signature');
  assert.equal((await accountRequest('whoop-TESTA001',source,day,otherSession.access_token)).status,401,
    'actual other-owner Auth cannot use this source');
  const identities: any[] = [];
  for (const [who, local] of [['a','whoop-TESTA001'],['a','whoop-TESTA002'],['b','whoop-TESTB001'],['b','whoop-TESTB002']]) {
    const response = await request(local,who,'/devices',{deviceId:local});
    assert.equal(response.status,200,await response.clone().text());
    identities.push((await response.json()).identity);
  }
  const device = identities[0].deviceId;
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
    assert.equal(score.contract_revision,2);
    assert.equal(score.compute.mode,'final_hosted');
    assert.equal(Object.keys(score.compute.families).length,27);
    const account=await accountRequest(local);
    assert.equal(account.status,200,await account.clone().text());
    const accountBytes=await account.text();
    assert.deepEqual(JSON.parse(accountBytes).server_scoring,score,`${name}: account/enrollment divergence`);
    assert.equal(score.compute.owner_id,score.user_id,`${name}: compute owner differs from legacy scope`);
    assert.equal(score.compute.device_id,body.identity.deviceId,`${name}: compute device differs from Edge identity`);
    assert.equal(score.compute.day,score.day,`${name}: compute day differs from legacy scope`);
    for (const [familyName,family] of Object.entries(score.compute.families) as [string,any][]) {
      assert.equal(family.owner,'server');
      assert.equal(family.owner_id,owner);
      assert.equal(family.device_id,body.identity.deviceId);
      assert.equal(family.window,score.day,`${name}: ${familyName} window differs from response day`);
      assert.equal(family.source_id,source);
      assert.equal(family.project,restUrl);
      assert.ok(family.result_revision===null || /^(sha256:[a-f0-9]{64}|compute:\d+)$/.test(family.result_revision));
      if (!family.canonical_qualification) assert.ok(Object.values(family.values).every(value=>value===null));
      if (family.canonical_qualification && ['available','stale'].includes(family.status) && score.daily) {
        for (const metric of family.metrics as string[]) {
          if (metric==='sleep_sessions' || !Object.hasOwn(score.daily,metric)) continue;
          const expected=metric==='sleep_efficiency' && typeof score.daily[metric]==='number'
            ? score.daily[metric]*100 : score.daily[metric];
          assert.deepEqual(family.values[metric],expected,
            `${name}: ${familyName}.${metric} differs from its top-level compatibility value`);
        }
      }
    }
    const sleep=score.compute.families.sleep;
    if (sleep.canonical_qualification && ['available','stale'].includes(sleep.status)) {
      assert.ok(Array.isArray(score.nights),`${name}: authorized top-level nights must be an array`);
      assert.ok(Array.isArray(sleep.values.sleep_sessions),`${name}: authorized sleep_sessions must be an array`);
      assert.ok(Array.isArray(sleep.details.nights),`${name}: authorized sleep details.nights must be an array`);
      assert.deepEqual(sleep.values.sleep_sessions,score.nights,`${name}: sleep_sessions diverges from top-level nights`);
      assert.deepEqual(sleep.details.nights,score.nights,`${name}: sleep details.nights diverges from top-level nights`);
      assert.equal(JSON.stringify(sleep.values.sleep_sessions),JSON.stringify(score.nights),
        `${name}: sleep_sessions wire ordering differs from top-level nights`);
      assert.equal(JSON.stringify(sleep.details.nights),JSON.stringify(score.nights),
        `${name}: sleep details wire ordering differs from top-level nights`);
      const compatibility=sleep.details.daily_compatibility;
      assert.deepEqual(Object.keys(compatibility).sort(),sleepCompatibilityKeys,
        `${name}: sleep daily compatibility key set drifted`);
      for (const key of sleepCompatibilityKeys) {
        assert.ok(Object.hasOwn(score.daily,key),`${name}: top-level daily omits ${key}`);
        assert.deepEqual(compatibility[key],score.daily[key],`${name}: sleep daily compatibility ${key} diverged`);
      }
      assert.equal(JSON.stringify(compatibility.full_day_sleep_epochs),JSON.stringify(score.daily.full_day_sleep_epochs),
        `${name}: full-day epoch wire ordering differs from top-level daily`);
      if (name==='approved-v2') {
        assert.equal(compatibility.sleep_unstaged_min,0,'valid-zero sleep compatibility is preserved');
        assert.equal(compatibility.state_unknown_min,null,'explicit-null sleep compatibility is preserved');
        assert.deepEqual(compatibility.full_day_sleep_epochs.map((epoch:any)=>epoch.state),['state_unknown','off_body'],
          'full-day epoch order is preserved');
      }
      if (name==='sleep-only') assert.deepEqual(compatibility.full_day_sleep_epochs,[],
        'an explicit empty full-day epoch array is preserved');
    } else {
      assert.ok(Array.isArray(score.nights),`${name}: compatibility nights must remain an explicit array`);
      assert.equal(sleep.values.sleep_sessions,null,`${name}: unavailable sleep must remain explicit null`);
      assert.equal(Object.hasOwn(sleep.details,'nights'),false,`${name}: unavailable sleep cannot invent episode details`);
      assert.equal(Object.hasOwn(sleep.details,'daily_compatibility'),false,
        `${name}: unavailable sleep cannot invent daily compatibility details`);
    }
    if (name==='approved-v2') {
      assert.equal(score.compute.families.sleep.values.sleep_efficiency,87.5,'canonical metric contract uses percent');
      assert.equal(score.compute.families.night_hrv.values.hrv_rmssd_ms,0,'owned valid zero is preserved');
    }
    if (name==='sleep-only') {
      assert.equal(score.compute.families.night_hrv.values.hrv_rmssd_ms,null);
      assert.equal(score.compute.families.temperature.values.skin_temp_c,null);
      for (const night of score.compute.families.sleep.details.nights) {
        assert.equal(night.hrv_rmssd_ms,undefined);
        assert.equal(night.resp_rate_bpm,undefined);
        assert.equal(night.skin_temp_c,undefined);
      }
    }
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
      expectedValues:name==='approved-v2'?{hrv:0,sleep:420,respiration:14}:name==='sleep-only'?{sleep:420}:undefined,
      expectedCanonicalValues:name==='approved-v2'?{hrv_rmssd_ms:0,hrv_sdnn_ms:0,resting_hr_bpm:60,
        resp_rate_bpm:14,sleep_total_min:420,sleep_efficiency:87.5}:name==='sleep-only'?{sleep_total_min:420,sleep_efficiency:87.5}:undefined});
    await Deno.writeTextFile(`${output}/account-${name}.json`,accountBytes);
    expectations.push({...expectations.at(-1),file:`account-${name}.json`});
    return score;
  }
  const sessionId=crypto.randomUUID();
  const sessionRequest={id:crypto.randomUUID(),family:'spot_hrv',session_id:sessionId,
    event_start:`${day}T12:00:00Z`,event_end:`${day}T12:02:00Z`,timezone_id:'UTC',input_revision:0,
    algorithm_version:'vps-only-1',configuration_version:'vps-only-1',consent:true,expires_at:null};
  for (let retry=0;retry<2;retry++) {
    const submitted=await request('whoop-TESTA001','a','/compute-requests',{deviceId:'whoop-TESTA001',request:sessionRequest});
    assert.equal(submitted.status,200,await submitted.clone().text());
    assert.equal((await submitted.json()).request_id,sessionRequest.id);
  }
  const conflict=await request('whoop-TESTA001','a','/compute-requests',
    {deviceId:'whoop-TESTA001',request:{...sessionRequest,input_revision:1}});
  assert.equal(conflict.status,409,'same request ID cannot mutate input');
  const baselineBinary = Deno.env.get('PIPELINE_TEST_V1_BINARY');
  const physiologyBinary = Deno.env.get('PIPELINE_TEST_V2_BINARY');
  if (baselineBinary || physiologyBinary) {
    assert.ok(baselineBinary && physiologyBinary, 'both real worker binaries are required');
    const workerDay = '2026-09-07';
    const ts = Math.floor(Date.parse(`${workerDay}T12:00:00Z`) / 1000);
    const sourceRevision = new TextDecoder().decode((await new Deno.Command('git', { args: ['rev-parse', 'HEAD'] }).output()).stdout).trim();
    const objectServer=startObjectHttp({versioned:true,chunkBytes:8192});
    const intakeConfig=pushConfig({B2_KEY_ID:'fixture',B2_APPLICATION_KEY:'fixture',B2_BUCKET:'fixture',RAW_STORE:'b2'});
    const archive=createPushArchive({cfg:intakeConfig,rest,raw:objectServer.raw});
    const intake=createPushIngest({walStore:createPushWalStore({rest})!,archiveObject:archive.archiveObject,
      resolveDeviceId:createNoopDeviceResolver({rest}),receiptStore:createUploadReceiptStore({rest}),
      commitProjection:(receipt,bytes)=>commitArchivedBatch(rest,receipt,bytes)});
    try {
    for (const [index, identity] of identities.entries()) {
      const batchReceipts: Array<{batch_id:string;receipt_id:string;content_sha256:string;wire_sha256:string;stream:string}>=[];
      // Synthetic acquisition fixture for the unchanged baseline; no RR/beat timing is invented.
      // Three hours of 1 Hz HR and gravity match the kernel's supported scalar inputs.
      const positive = index === 0;
      const inputStart = positive ? Math.floor(Date.parse(`${workerDay}T01:00:00Z`) / 1000) : ts;
      const inputCount = positive ? 10_800 : 600;
      for (const stream of positive ? ['hrSample','gravitySample'] : ['hrSample']) {
        for (let offset=0;offset<inputCount;offset+=1000) {
          const batch = crypto.randomUUID();
          const records = Array.from({length:Math.min(1000,inputCount-offset)},(_,n)=>({type:'record',key:{ts:inputStart+offset+n},
            data:stream==='hrSample' ? {bpm:positive ? 52+Math.floor((offset+n)/60)%3 : 60+index*10} : {x:0,y:0,z:1}}));
          const header={type:'batch',protocolVersion:'1.1',stream,deviceId:identity.externalDeviceId,sourceId:identity.sourceId,
            batchId:batch,endCursor:{ts:inputStart+offset+records.length-1},delivery:'append',recordCount:records.length};
          const decodedBody=new TextEncoder().encode([header,...records].map(value=>JSON.stringify(value)).join('\n')+'\n');
          const upload=await resolveUploadIdentity({rest,headers:new Headers({
            authorization:`Bearer noop_pipeline_${identity.userId===owner?'a':'b'}`,'x-noop-fleet-token':'noop_pipeline_fleet'})});
          assert.equal(upload.id,identity.userId);assert.equal(upload.sourceId,identity.sourceId);
          assert.equal(await rest.rpc('admit_noop_request',{p_user:upload.id,p_source:upload.sourceId}),true);
          const args={userId:upload.id,sourceId:upload.sourceId,tokenId:upload.tokenId,authMode:upload.authMode,decodedBody};
          const ack=await intake.acceptBatch(args);
          assert.equal(ack.acceptedRows,records.length);assert.equal(ack.durabilityReceipt.state,'verified_indexed');
          assert.equal(ack.durabilityReceipt.contentSha256,createHash('sha256').update(decodedBody).digest('hex'));
          assert.equal(await sql(`select state from noop_projection_debt where object_id='${batch}';`),'complete');
          assert.equal(await sql(`select sha256_source from object_manifests where id='${batch}';`),'server_verified');
          assert.equal(await sql(`select count(*) from noop_projection_observations where batch_id='${batch}';`),String(records.length));
          batchReceipts.push({batch_id:batch,receipt_id:ack.durabilityReceipt.receiptId,content_sha256:ack.durabilityReceipt.contentSha256,
            wire_sha256:ack.durabilityReceipt.wireSha256,stream});
          const revision = await sql(`select input_revision from physiology_work_items where user_id='${identity.userId}' and device_id='${identity.deviceId}' and day='${workerDay}';`);
          assert.deepEqual(await intake.acceptBatch(args),ack);
          assert.equal(await sql(`select input_revision from physiology_work_items where user_id='${identity.userId}' and device_id='${identity.deviceId}' and day='${workerDay}';`),revision,'duplicate durable batch does not dirty revision');
        }
        const table=stream==='hrSample' ? 'noop_hr_samples' : 'noop_gravity_samples';
        assert.equal(Number(await sql(`select count(*) from ${table} where user_id='${identity.userId}'
          and device_id='${identity.deviceId}' and ts>=${inputStart} and ts<${inputStart+inputCount};`)),inputCount);
      }
      const workerEnv={PATH:Deno.env.get('PATH')!,JAVA_HOME:Deno.env.get('JAVA_HOME')!,
        DATABASE_URL:Deno.env.get('PIPELINE_TEST_DATABASE_URL')!,SUPABASE_URL:restUrl!,
        SUPABASE_SERVICE_ROLE_KEY:token,INGEST_SECRET:'isolated-pipeline-only',
        SCORING_WORKER_SOURCE_REVISION:sourceRevision};
      if (positive) {
        assert.equal(await sql(`select status from scoring_work_items where user_id='${identity.userId}'
          and device_id='${identity.deviceId}' and day='${workerDay}';`),'pending',
          'durable scalar projection must enqueue the selected baseline without test-only enqueue');
        // A retained replay environment must not turn the production daemon into a one-shot process.
        const daemon=new Deno.Command(baselineBinary,{args:[],clearEnv:true,env:{...workerEnv,
          SCORING_ALGORITHM_VERSION:'frwhoop-server-1',SCORING_POLL_SECONDS:'1',
          SCORING_WORKER_INSTANCE_ID:crypto.randomUUID(),REPLAY_USER_ID:'invalid-stale-user',
          REPLAY_DEVICE_ID:'invalid-stale-device',REPLAY_DAY:'invalid-stale-day'},stdout:'piped',stderr:'piped'}).spawn();
        let exited=false;
        const daemonOutput=daemon.output().then(result=>{exited=true;return result;});
        const timeout=setTimeout(()=>{try {daemon.kill('SIGTERM');} catch { /* Already exited. */ }},120_000);
        try {
          let priorRevision=0;
          for (let cycle=0;cycle<2;cycle++) {
            let publicationRevision=0;
            for (let attempt=0;attempt<100;attempt++) {
              assert.equal(exited,false,'persistent worker exited before bounded test shutdown');
              publicationRevision=Number(await sql(`select coalesce(max(input_revision),0) from server_physiology_results
                where user_id='${identity.userId}' and device_id='${identity.deviceId}' and period_day='${workerDay}'
                and algorithm_version='frwhoop-server-1';`));
              if (publicationRevision>priorRevision) break;
              await new Promise(resolve=>setTimeout(resolve,500));
            }
            assert.ok(publicationRevision>priorRevision,'persistent daemon must claim and publish each queued revision');
            priorRevision=publicationRevision;
            if (cycle===0) await rest.rpc('scoring_enqueue_legacy_fenced',{
              p_user:identity.userId,p_device:identity.deviceId,p_day:workerDay,p_timezone:'UTC',p_debounce_seconds:0});
          }
          assert.equal(exited,false,'daemon remains alive after multiple publications');
        } finally {
          clearTimeout(timeout);
          try {daemon.kill('SIGTERM');} catch { /* Already exited. */ }
          const result=await daemonOutput;
          const log=new TextDecoder().decode(result.stdout)+new TextDecoder().decode(result.stderr);
          await Deno.writeTextFile(`${output}/worker-0-persistent-v1.log`,log);
          assert.match(log,/Ignoring REPLAY_\* in persistent baseline mode/);
        }
      }
      assert.ok(Number(await sql(`select count(*) from scoring_jobs_v2 where user_id='${identity.userId}'
        and device_id='${identity.deviceId}' and day='${workerDay}' and algorithm_version='frwhoop-server-1';`))>0,
        'historical queue coexistence must not suppress fenced baseline publication');
      const workerBinaries: Array<[string,string]> = [['frwhoop-server-1',baselineBinary],['frwhoop-physiology-2',physiologyBinary]];
      for (const [version,binary] of workerBinaries) {
        const child: Deno.ChildProcess = new Deno.Command(binary, { args:['--replay-day'], clearEnv:true,
          env:{...workerEnv,
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
        if (version==='frwhoop-physiology-2') {
          assert.equal(Number(await sql(`select count(*) from server_compute_dispositions where user_id='${identity.userId}'
            and device_id='${identity.deviceId}' and day='${workerDay}' and input_revision=${published.revision};`)),27,
            'actual production worker publishes all family dispositions');
        }
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
      const expectation={file:`worker-${index}.json`,ownerId:identity.userId,day:workerDay,
        availableFeatures:available,unavailableFeatures:[],expectedDeviceId:identity.deviceId,
        nestedHrvAvailable:false,nestedRespirationAvailable:false,
        allowedNestedFields:positive ? ['resting_hr_bpm','overnight_hr_bpm'] : undefined,
        expectedValues:positive ? {sleep:179.98333333333332} : undefined,
        expectedCanonicalValues:positive ? {sleep_total_min:179.98333333333332,sleep_efficiency:100,resting_hr_bpm:53} : undefined};
      expectations.push(expectation);
      if (positive) {
        const publication=JSON.parse(await sql(`select jsonb_build_object('revision',input_revision,
          'payload_hash',payload_hash,'payload',payload) from server_physiology_results
          where user_id='${identity.userId}' and device_id='${identity.deviceId}' and period_day='${workerDay}'
          and algorithm_version='frwhoop-server-1' order by input_revision desc limit 1;`));
        const value=publication.payload.daily.sleep_total_min;
        assert.ok(value>0,'unchanged v1 must actually compute a supported numerical sleep result');
        assert.equal(value,expectation.expectedValues!.sleep,'frozen kernel numerical fixture changed');
        const selected=await rest.rpc('server_scoring_for_device_day',{
          p_user:identity.userId,p_device:identity.deviceId,p_day:workerDay});
        const sleep=body.server_scoring.compute.families.sleep;
        for (const metric of ['hrv_rmssd_ms','hrv_sdnn_ms','spo2_pct','resp_rate_bpm']) {
          assert.equal(body.server_scoring.daily[metric] ?? null,null,`no source fixture may manufacture ${metric}`);
        }
        assert.equal(selected.daily.sleep_total_min,value);
        assert.equal(body.server_scoring.daily.sleep_total_min,value);
        assert.equal(sleep.values.sleep_total_min,value);
        assert.equal(sleep.canonical_qualification,'retained_legacy','positive proof must not manufacture qualification');
        assert.equal(sleep.result_revision,`sha256:${publication.payload_hash}`);
        assert.equal(sleep.input_revision,publication.revision);
        assert.equal(Number(await sql("select count(*) from physiology_feature_qualifications where qualification='reference_qualified';")),0,
          'positive baseline proof runs before any test-only qualification fixtures');
        const account=await accountRequest(identity.externalDeviceId,identity.sourceId,workerDay);
        assert.equal(account.status,200,await account.clone().text());
        const accountBytes=await account.text();
        assert.deepEqual(JSON.parse(accountBytes).server_scoring,body.server_scoring,'computed account/enrolled parity');
        await Deno.writeTextFile(`${output}/account-worker-${index}.json`,accountBytes);
        expectations.push({...expectation,file:`account-worker-${index}.json`});
        await Deno.writeTextFile(`${output}/computed_fixture_input_to_result_trace.json`,JSON.stringify({
          schema_version:1,evidence_kind:'synthetic_supported_input_executed_workers',source_revision:sourceRevision,
          source_worktree_clean:Deno.env.get('PIPELINE_TEST_SOURCE_CLEAN')==='true',
          source_status_sha256:Deno.env.get('PIPELINE_TEST_SOURCE_STATUS_SHA256') ?? null,
          source_receipt:'../source-receipt.json',
          physical_phone_readback:'NOT_MEASURED',account_auth_provider:'disposable_gotrue_issued_and_verified_bearer',
          owner_id:identity.userId,source_id:identity.sourceId,device_id:identity.deviceId,day:workerDay,
          inputs:{hr:{count:inputCount,rate_hz:1,unit:'bpm',formula:'52 + floor(sample_index / 60) % 3'},
            gravity:{count:inputCount,rate_hz:1,unit:'g',xyz:[0,0,1]},start_epoch_s:inputStart,
            end_epoch_s:inputStart+inputCount-1,rr_count:0,respiration_count:0},
          input_transport:'real_NDJSON_parser_WAL_signed_loopback_S3_streamed_byte_verification',
          acquisition:'synthetic_1Hz_supported_scalar_fixture_not_physical_BLE',storage_provider:'synthetic_loopback_S3_not_hosted_B2',
          upload_auth:'actual_source_bound_installation_and_fleet_lookup',durability_receipts:batchReceipts,
          durable_projection:'noop_commit_push_projection_atomic_lifecycle',queue:'scoring_work_items',
          initial_queue_admission:'actual_scalar_change_trigger_no_test_enqueue',
          worker:'frwhoop-server-1',numerical_source_revision:'5caa31689da0023e111beb36850d3f81d67e1be2',
          input_revision:publication.revision,immutable_payload_sha256:publication.payload_hash,
          qualification:sleep.canonical_qualification,metric:'sleep_total_min',unit:'min',value,
          sql_selected_value:selected.daily.sleep_total_min,enrolled_value:sleep.values.sleep_total_min,
          account_value:JSON.parse(accountBytes).server_scoring.compute.families.sleep.values.sleep_total_min,
          native_expectation_files:[expectation.file,`account-worker-${index}.json`],
          persistent_daemon:'two_publications_with_stale_replay_environment',
        },null,2)+'\n');
      }
    }
    } finally {await objectServer.close();}
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
  await rest.rpc('server_scoring_for_device_day',{p_user:owner,p_day:day,p_device:device});
  await capture('missing',[]);
  await capture('pending-device',[],false,false,'whoop-UNREGISTERED');
  assert.equal((await accountRequest('whoop-TESTA001',secondSource)).status,401,'other-owner source rejected');
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
  async function publish(mismatch = false, fullDaySleepEpochs?: unknown[]) {
    await rest.rpc('physiology_enqueue_day',{p_user:owner,p_device:device,p_day:day,p_timezone:'UTC',p_debounce_seconds:0});
    const [claim] = await rest.rpc('scoring_claim_one',{p_user:owner,p_device:device,p_day:day});
    assert.ok(claim,'real queue claim');
    const hashes = Object.fromEntries((await rest.select('physiology_feature_manifests','select=feature,manifest_sha256'))
      .map((row:any)=>[row.feature,mismatch?'0'.repeat(64):row.manifest_sha256]));
    const start = Math.floor(Date.parse(`${day}T00:00:00Z`)/1000);
    const epochs=fullDaySleepEpochs ?? [
      {start,end:start+3600,stage:'unknown',state:'state_unknown'},
      {start:start+3600,end:start+7200,stage:'unknown',state:'off_body'},
    ];
    const payload = {schema_version:2,user_id:owner,device_id:device,day,algorithm_version:'frwhoop-physiology-2',
      input_revision:claim.input_revision,lease_token:claim.lease_token,run_id:claim.run_id,
      computed_at:new Date().toISOString(),publication_status:'provisional',feature_manifest_hashes:hashes,
      daily:{day,source_device_id:device,hrv_rmssd_ms:0,hrv_sdnn_ms:0,resting_hr_bpm:60,resp_rate_bpm:14,sleep_total_min:420,
        sleep_efficiency:0.875,sleep_in_bed_min:480,sleep_awake_min:60,sleep_light_min:240,sleep_deep_min:120,sleep_rem_min:60,
        sleep_onset_at:`${day}T00:00:00Z`,wake_onset_at:`${day}T08:00:00Z`,sleep_unstaged_min:0,state_unknown_min:null,
        off_body_min:15,main_sleep_group_id:'group-a',opportunity_kind:'estimated_sleep_opportunity',full_day_sleep_epochs:epochs},
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
  const sqlApproved=structuredClone(approved);
  delete sqlApproved.compute.project; delete sqlApproved.compute.source_id;
  for (const family of Object.values(sqlApproved.compute.families) as any[]) {
    delete family.project; delete family.source_id;
  }
  assert.deepEqual(account,sqlApproved,'account and enrolled SQL wrappers share serialization before trusted Edge project/source binding');
  const accountRest = createSupabaseRest({cfg:{supabaseUrl:restUrl!,supabaseServiceRoleKey:accountToken},
    fetchImpl:(input,init)=>fetch(String(input).replace('/rest/v1/','/'),init)});
  assert.deepEqual(await accountRest.rpc('server_scoring_for_day',{p_user:owner,p_day:day}),sqlApproved);
  await assert.rejects(()=>accountRest.rpc('server_scoring_for_day',{p_user:other,p_day:day}),/403/);
  await assert.rejects(()=>rest.rpc('server_scoring_for_device_day',{p_user:owner,p_device:identities[2].deviceId,p_day:day}),/403/);
  await sql(`delete from physiology_source_selection where user_id='${owner}';`);
  await sql("update physiology_feature_defaults set algorithm_version='frwhoop-server-1' where feature<>'sleep';");
  await publish(false,[]);
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
  const crossBody=await cross.json();
  assert.equal(crossBody.identity.deviceId,null);
  assert.equal(Object.keys(crossBody.server_scoring.compute.families).length,27);
  assert.ok(Object.values(crossBody.server_scoring.compute.families).every((f:any)=>f.result_revision===null && f.device_id===null));
  if (!(baselineBinary && physiologyBinary)) await sql('select process_compute_session_request();');
  const readSession=()=>handleScoresRequest(new Request(`http://localhost/functions/v1/scores/compute-requests?deviceId=whoop-TESTA001&requestId=${sessionRequest.id}`,{
    headers:{authorization:'Bearer noop_pipeline_a','x-noop-fleet-token':'noop_pipeline_fleet'},
  }),{rest,cfg});
  const sessionResponse=await readSession();
  assert.equal(sessionResponse.status,200,await sessionResponse.clone().text());
  const sessionResult=await sessionResponse.json();
  assert.equal(sessionResult.result.status,'unqualified');
  assert.equal(sessionResult.result.reason,'producer_not_implemented');
  assert.equal(sessionResult.result.status,'unqualified');
  const insightPolicy = await sql("select unavailable_status||':'||unavailable_reason from compute_family_policy where family='insights';");
  assert.equal(insightPolicy, 'unqualified:producer_not_implemented',
    'unfinished engineering must not be reported as unsupported hardware');
  assert.match(sessionResult.result.result_revision,/^session:\d+$/);
  assert.deepEqual(sessionResult.result.values,{spot_hrv_rmssd_ms:null,spot_hrv_sdnn_ms:null});
  assert.deepEqual(await (await readSession()).json(),sessionResult,'immutable retry readback');
  const expired={...sessionRequest,id:crypto.randomUUID(),family:'live_coaching',
    event_end:`${day}T12:01:00Z`,expires_at:`${day}T12:02:00Z`};
  assert.equal((await request('whoop-TESTA001','a','/compute-requests',{deviceId:'whoop-TESTA001',request:expired})).status,200);
  await sql('select process_compute_session_request();');
  const expiredResult=await rest.rpc('read_compute_session_result',{p_user:owner,p_device:device,p_source:source,p_request:expired.id});
  assert.equal(expiredResult.result.reason,'decision_expired');
  assert.equal(expiredResult.result.freshness,'expired');
  assert.ok(Object.values(expiredResult.result.values).every(value=>value===null));
  await assert.rejects(()=>rest.rpc('read_compute_session_result',{p_user:other,p_device:identities[2].deviceId,p_source:secondSource,p_request:sessionRequest.id}),/404/);
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
  // Link exact production DayScorer artifacts from the disposable JVM/SQL tests to
  // the real enrolled Edge handler and native decoders. This is artifact replay,
  // not a claim of hardware capture or a live deployed worker/phone round trip.
  const sensorFixtures = Deno.env.get('PIPELINE_SENSOR_FIXTURES');
  if (sensorFixtures) for (const name of ['hrv', 'ppg', 'imu-temperature']) {
    const originalBytes = await Deno.readTextFile(`${sensorFixtures}/${name}-worker-payload.json`);
    const original = JSON.parse(originalBytes);
    const acquisition = JSON.parse(await Deno.readTextFile(`${sensorFixtures}/${name === 'imu-temperature' ? 'imu' : name}-acquisition.json`));
    assert.equal(acquisition.fixture_only, true);
    assert.equal(acquisition.validation_scope, 'synthetic_not_device_qualification');
    const uid = original.user_id, did = original.device_id, sid = acquisition.source_id;
    for (const id of [uid, did, sid]) assert.match(id, /^[0-9a-f-]{36}$/);
    assert.equal(uid, acquisition.user_id); assert.equal(did, acquisition.device_id);
    assert.match(original.day, /^\d{4}-\d{2}-\d{2}$/);
    const revision = Number(original.input_revision);
    assert.ok(Number.isSafeInteger(revision) && revision > 0 && revision <= 1024);
    const code = crypto.randomUUID(), external = `whoop-SENSOR-${name.toUpperCase()}`;
    const installationToken = `noop_sensor_${crypto.randomUUID()}`;
    await sql(`insert into auth.users(id) values ('${uid}');
      insert into profiles(id,timezone) values ('${uid}','UTC') on conflict(id) do update set timezone='UTC';
      insert into devices(id,user_id,source_kind,external_device_id,device_family)
        values ('${did}','${uid}','noop_push','${external}','whoop5');
      insert into noop_enrollment_codes(id,user_id,code_hash,expires_at)
        values ('${code}','${uid}',encode(sha256(convert_to('${code}','UTF8')),'hex'),now()+interval '1 day');
      insert into noop_app_installations(source_id,user_id,enrollment_code_id,platform,app_version)
        values ('${sid}','${uid}','${code}','android','synthetic-artifact-replay');
      insert into noop_ingest_tokens(user_id,token_hash,token_kind,source_id,enrollment_code_id)
        values ('${uid}',encode(sha256(convert_to('${installationToken}','UTF8')),'hex'),'installation','${sid}','${code}');`);
    for (let n = 0; n < revision; n++) await rest.rpc('physiology_enqueue_day', {
      p_user: uid, p_device: did, p_day: original.day, p_timezone: 'UTC', p_debounce_seconds: 0,
    });
    const [claim] = await rest.rpc('scoring_claim_one', {p_user:uid,p_device:did,p_day:original.day});
    assert.equal(Number(claim.input_revision), revision);
    // Only the destination's transient lease/run token changes. Identity, window
    // revisions, original computed values/reasons and acquisition provenance do not.
    const replay = {...original, lease_token:claim.lease_token, run_id:claim.run_id};
    await rest.rpc('engine_publish_physiology', {p_secret:'isolated-pipeline-only',p_payload:replay});
    assert.equal(await rest.rpc('scoring_finish_work', {p_user:uid,p_device:did,p_day:original.day,
      p_revision:claim.input_revision,p_lease_token:claim.lease_token,p_run_id:claim.run_id,
      p_outcome:'done',p_duration_ms:1,p_error:null}), true);
    const response = await handleScoresRequest(new Request(
      `http://localhost/functions/v1/scores?day=${original.day}&deviceId=${external}`, {
        headers:{authorization:`Bearer ${installationToken}`,'x-noop-fleet-token':'noop_pipeline_fleet'},
      }), {rest,cfg});
    assert.equal(response.status,200,await response.clone().text());
    const bytes = await response.text(), body = JSON.parse(bytes), score = body.server_scoring;
    assert.equal(body.identity.userId,uid); assert.equal(body.identity.deviceId,did);
    assert.deepEqual(score.signal_windows.map((w:any)=>w.window_id), original.signal_windows.map((w:any)=>w.window_id));
    for (const window of score.signal_windows) {
      assert.equal(window.values,null); assert.equal(window.publication_status,'shadow');
      assert.ok(window.reason); assert.ok(['unavailable','unqualified','blocked'].includes(window.measurement_status));
    }
    assert.ok(score.signal_windows.some((w:any)=>w.analysis_status==='available' && w.reason==='not_reference_validated'));
    assert.ok(allFeatures.every(key=>!['available','stale'].includes(score.features[key].status)));
    const file = `sensor-${name}.json`;
    await Deno.writeTextFile(`${output}/${file}`,bytes);
    await Deno.writeTextFile(`${output}/sensor-${name}-replay-evidence.json`,JSON.stringify({
      scope:'linked_synthetic_artifact_replay_not_deployed_round_trip',
      worker_payload_sha256:createHash('sha256').update(originalBytes).digest('hex'),
      original_user_id:uid,original_device_id:did,input_revision:revision,
      changed_fields:['lease_token','run_id'],
    },null,2));
    expectations.push({file,ownerId:uid,day:original.day,availableFeatures:[],unavailableFeatures:allFeatures,
      expectedDeviceId:did,nestedHrvAvailable:false,nestedRespirationAvailable:false,
      signalWindows:score.signal_windows.map((w:any)=>({id:w.window_id,kind:w.kind,reason:w.reason,
        status:w.measurement_status,revision:Number(w.input_revision)}))});
  }
  await Deno.writeTextFile(`${output}/expectations.json`,JSON.stringify(expectations,null,2));
  await Deno.writeTextFile(`${output}/identities.json`,JSON.stringify(identities,null,2));
}});
