// Native PostgreSQL + real PostgREST. This harness never accepts a database URL or credentials.
// All clusters are created under the explicitly supplied external artifact directory. Supabase
// auth helper functions below model JWT claims; no production Auth/storage services are used.
import { createHmac } from 'node:crypto';
import { Buffer } from 'node:buffer';
import { createSupabaseRest } from '../_shared/rest.ts';

export const USER_A = '11111111-1111-4111-8111-111111111111';
export const USER_B = '22222222-2222-4222-8222-222222222222';
const decoder = new TextDecoder();

export async function startLocalPostgres({ scalarProjections = false, auxiliaryIdentity = false }:
  { scalarProjections?: boolean; auxiliaryIdentity?: boolean } = {}) {
  const artifacts = Deno.env.get('EDGE_TEST_ARTIFACTS');
  if (!artifacts?.startsWith('/Volumes/')) throw new Error('EDGE_TEST_ARTIFACTS must name an external-volume directory');
  const base = await Deno.makeTempDir({ dir: artifacts, prefix: 'edge-pg-' });
  const bin = Deno.env.get('EDGE_TEST_PG_BIN') || '/opt/homebrew/bin';
  const data = `${base}/data`;
  const env = { PATH: '/opt/homebrew/bin:/usr/bin:/bin', TMPDIR: base, LC_ALL: 'C' };
  let started = false;
  let restProcess: Deno.ChildProcess | undefined;
  const logs: string[] = [];
  async function run(executable: string, args: string[]) {
    const result = await new Deno.Command(executable, { args, env, clearEnv: true, stdout: 'piped', stderr: 'piped' }).output();
    const output = decoder.decode(result.stdout);
    const error = decoder.decode(result.stderr);
    logs.push(`${executable.split('/').pop()} ${args[0]}: ${output}${error}`);
    if (!result.success) throw new Error(`${executable.split('/').pop()} failed: ${error.slice(-2000)}`);
    return output.trim();
  }
  const sql = (statement: string) => run(`${bin}/psql`, ['-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-h', base, '-U', 'edge_test', '-d', 'postgres', '-c', statement]);
  async function close() {
    if (restProcess) { restProcess.kill('SIGTERM'); await restProcess.status; }
    if (started) await run(`${bin}/pg_ctl`, ['-D', data, '-m', 'fast', '-w', 'stop']);
    await Deno.writeTextFile(`${base}/harness.log`, logs.join('\n'));
    console.log(`Disposable DB stopped; synthetic evidence retained at ${base}`);
  }
  try {
    await run(`${bin}/initdb`, ['-D', data, '-U', 'edge_test', '--auth-local=trust', '--auth-host=reject', '--no-locale', '--encoding=UTF8']);
    await run(`${bin}/pg_ctl`, ['-D', data, '-l', `${base}/postgres.log`, '-o', `-k ${base} -c listen_addresses='' -c unix_socket_permissions=0700 -c max_connections=30`, '-w', 'start']);
    started = true;
    await sql(`
      create role postgres nologin; create role anon nologin; create role authenticated nologin;
      create role service_role nologin bypassrls; create role authenticator login noinherit;
      grant anon,authenticated,service_role to authenticator;
      create schema auth; create schema extensions;
      create publication supabase_realtime;
      create table auth.users (id uuid primary key, raw_user_meta_data jsonb default '{}'::jsonb, email text);
      create function auth.uid() returns uuid language sql stable as $$
        select coalesce(nullif(current_setting('request.jwt.claim.sub',true),''),
          nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'sub')::uuid $$;
      create function auth.role() returns text language sql stable as $$
        select coalesce(nullif(current_setting('request.jwt.claim.role',true),''),
          nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role',current_user::text) $$;
      grant usage on schema public,auth,extensions to anon,authenticated,service_role;
      alter default privileges in schema public grant all on tables to service_role;
      alter default privileges in schema public grant all on sequences to service_role;
    `);
    const migrations = [
      '20260819190000_frwhoop_base_schema.sql',
      '20260824180000_production_persistence.sql',
      '20260907133000_noop_hr_samples.sql',
      '20260907133100_noop_append_stream_projections.sql',
      '20260907140000_noop_ingest_tokens.sql',
      '20260907150000_noop_push_wal.sql',
      '20260907160000_noop_journal_entries.sql',
      '20260907170000_noop_raw_object_lane.sql',
      '20260908120000_noop_push_staging_parts.sql',
      '20260911120000_noop_remaining_append_projections.sql',
      '20260916160000_scoring_service_state.sql',
      '20260916170000_scoring_work_items_device_id.sql',
      '20260917190000_scoring_derived_artifact.sql',
      '20260918010000_production_scoring_durability.sql',
      '20260918020000_production_intake_durability.sql',
      '20260918030000_production_scoring_review_repairs.sql',
      '20260918040000_production_projection_debt.sql',
    ];
    if (scalarProjections || auxiliaryIdentity) migrations.push('20260918050000_production_scoring_history.sql',
      '20260918060000_production_scalar_projections.sql');
    if (auxiliaryIdentity) migrations.push('20260918070000_production_aux_identity_provenance.sql',
      '20260918080000_production_ppg_input_selection.sql');
    for (const migration of migrations) {
      const file = new URL(`../../migrations/${migration}`, import.meta.url);
      await run(`${bin}/psql`, ['-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-h', base, '-U', 'edge_test', '-d', 'postgres', '-f', decodeURIComponent(file.pathname)]);
    }
    await sql(`insert into auth.users(id) values ('${USER_A}'),('${USER_B}');`);
    const jwtSecret = 'disposable-edge-test-only-' + crypto.randomUUID();
    function token(role: string, userId?: string) {
      const header = Buffer.from(JSON.stringify({ alg: 'HS256', typ: 'JWT' })).toString('base64url');
      const body = Buffer.from(JSON.stringify({ role, sub: userId, exp: Math.floor(Date.now()/1000)+3600 })).toString('base64url');
      const content = `${header}.${body}`;
      return `${content}.${createHmac('sha256', jwtSecret).update(content).digest('base64url')}`;
    }
    const listener = Deno.listen({ hostname: '127.0.0.1', port: 0 });
    const port = (listener.addr as Deno.NetAddr).port;
    listener.close();
    const log = await Deno.open(`${base}/postgrest.log`, { create: true, write: true });
    restProcess = new Deno.Command(`${bin}/postgrest`, {
      env: { ...env, PGRST_DB_URI: `postgresql://authenticator@/postgres?host=${encodeURIComponent(base)}`,
        PGRST_DB_SCHEMAS: 'public', PGRST_DB_ANON_ROLE: 'anon', PGRST_JWT_SECRET: jwtSecret,
        PGRST_SERVER_HOST: '127.0.0.1', PGRST_SERVER_PORT: String(port), PGRST_DB_POOL: '5' },
      clearEnv: true, stdout: 'null', stderr: 'piped',
    }).spawn();
    const drainLog = restProcess.stderr.pipeTo(log.writable).catch(() => {});
    const origin = `http://127.0.0.1:${port}`;
    let ready = false;
    for (let attempt = 0; attempt < 100; attempt++) {
      try { const response = await fetch(`${origin}/`); await response.body?.cancel(); if (response.ok) { ready = true; break; } } catch { /* startup */ }
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    if (!ready) throw new Error('disposable PostgREST did not start');
    // Supabase adds /rest/v1 before proxying to PostgREST. Keep the real client and strip only
    // that gateway prefix; all requests still cross a real socket and execute real SQL/RLS.
    const fetchImpl: typeof fetch = (input, init) => fetch(String(input).replace('/rest/v1/', '/'), init);
    const serviceToken = token('service_role');
    const rest = createSupabaseRest({ cfg: { supabaseUrl: origin, supabaseServiceRoleKey: serviceToken }, fetchImpl });
    async function request(path: string, role = 'authenticated', userId = USER_A, method = 'GET', body?: unknown) {
      const response = await fetch(`${origin}/${path}`, { method,
        headers: { authorization: `Bearer ${token(role,userId)}`, 'content-type': 'application/json', prefer: 'return=representation' },
        body: body == null ? undefined : JSON.stringify(body) });
      const text = await response.text();
      return { status: response.status, body: text ? JSON.parse(text) : null };
    }
    return { rest, sql, request, base, close: async () => { await close(); await drainLog; } };
  } catch (err) { await close(); throw err; }
}
