// Reuse the existing disposable PG/PostgREST fixture; never accept production URLs/credentials.
import { startLocalPostgres, USER_A, USER_B } from '../../supabase/functions/tests/local_postgres.ts';

const executable = Deno.args[0];
if (!executable?.startsWith('/Volumes/')) throw new Error('Pass the native test binary on the external SSD');
const db = await startLocalPostgres();
let gateway: Deno.HttpServer | undefined;
try {
  const migration = await Deno.readTextFile(new URL('../../supabase/migrations/20260918050000_production_scoring_history.sql', import.meta.url));
  await db.sql(migration);
  for (const device of ['bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'cccccccc-cccc-cccc-cccc-cccccccccccc',
    'dddddddd-dddd-dddd-dddd-dddddddddddd', 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee',
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'abababab-abab-4bab-8bab-abababababab']) {
    await db.sql(`insert into devices(id,user_id,source_kind) values('${device}','${USER_A}','whoop');`);
  }
  await db.sql(`insert into devices(id,user_id,source_kind) values('ffffffff-ffff-ffff-ffff-ffffffffffff','${USER_B}','whoop'); notify pgrst,'reload schema';`);
  let ready = false;
  for (let attempt = 0; attempt < 100; attempt++) {
    const result = await db.request('rpc/get_scoring_history_input_head_v3', 'authenticated', USER_A, 'POST', {
      p_device: 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', p_kind: 'profile', p_entity: 'primary',
    });
    if (result.status === 200) { ready = true; break; }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  if (!ready) throw new Error('PostgREST did not reload history RPCs');

  // Model only Supabase's gateway prefix. The helper generates short-lived, test-cluster JWTs
  // and calls real PostgREST with role=authenticated. No service-role token reaches Swift.
  const allowed = new Set(['put_scoring_history_input_v3', 'get_scoring_history_input_v3', 'get_scoring_history_input_head_v3']);
  const observations: { rpc: string; status: number; role: string; code?: string; message?: string }[] = [];
  gateway = Deno.serve({ hostname: '127.0.0.1', port: 0, onListen: () => {} }, async (request) => {
    const path = new URL(request.url).pathname;
    const rpc = path.replace('/rest/v1/rpc/', '');
    const credential = request.headers.get('authorization');
    if (request.method !== 'POST' || !path.startsWith('/rest/v1/rpc/') || !allowed.has(rpc) ||
        !['Bearer fixture-a', 'Bearer fixture-b'].includes(credential ?? '')) return new Response(null, { status: 403 });
    const result = await db.request(`rpc/${rpc}`, 'authenticated', credential === 'Bearer fixture-a' ? USER_A : USER_B,
      'POST', await request.json());
    observations.push({ rpc, status: result.status, role: 'authenticated', code: result.body?.code, message: result.body?.message });
    return new Response(JSON.stringify(result.body), { status: result.status, headers: { 'content-type': 'application/json' } });
  });
  const origin = `http://127.0.0.1:${(gateway.addr as Deno.NetAddr).port}`;
  const result = await new Deno.Command(executable, { clearEnv: true, env: {
    PATH: '/usr/bin:/bin', TMPDIR: db.base, SCORING_INPUT_LOOPBACK_URL: origin,
  }, stdout: 'inherit', stderr: 'inherit' }).output();
  if (!result.success) throw new Error(`Native loopback tests failed (${result.code})`);

  const summary = JSON.parse(await db.sql(`select jsonb_build_object('rows',count(*),
    'mutations',count(distinct client_mutation_id),'owners',count(distinct user_id)) from scoring_history_inputs_v3;`));
  if (summary.rows !== 13 || summary.mutations !== 13 || summary.owners !== 1) throw new Error(`Unexpected server mutations: ${JSON.stringify(summary)}`);
  const read = { p_device: 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', p_kind: 'profile', p_entity: 'primary', p_as_of_day: '2026-09-18' };
  const wrongOwner = await db.request('rpc/get_scoring_history_input_v3', 'authenticated', USER_B, 'POST', read);
  const directTable = await db.request('scoring_history_inputs_v3?select=revision', 'authenticated', USER_A);
  const ownEmpty = await db.request('rpc/get_scoring_history_input_v3', 'authenticated', USER_B, 'POST', {
    ...read, p_device: 'ffffffff-ffff-ffff-ffff-ffffffffffff',
  });
  if (wrongOwner.status !== 403 || directTable.status !== 403 || ownEmpty.status !== 200 || ownEmpty.body.revision !== null) {
    throw new Error('Ordinary authenticated owner/RPC-only table checks failed');
  }
  const evidence = { summary, wrongOwnerRead: wrongOwner.status, directHistoryTable: directTable.status,
    otherOwnerOwnDevice: ownEmpty.status, observations,
    migrationSHA256: Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(migration))))
      .map((byte) => byte.toString(16).padStart(2, '0')).join('') };
  await Deno.writeTextFile(`${db.base}/scoring-input-loopback.json`, JSON.stringify(evidence, null, 2));
  console.log(`Real PostgREST: 7 native tests, ${summary.rows} distinct server mutations; authenticated role checks passed.`);
  console.log(`Evidence: ${db.base}/scoring-input-loopback.json`);
} finally {
  if (gateway) await gateway.shutdown();
  await db.close();
}
