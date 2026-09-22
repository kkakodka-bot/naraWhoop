import { assert, assertEquals } from 'jsr:@std/assert';
import { handleScoresRequest } from '../_shared/serverScores.ts';
import { hashIngestToken } from '../_shared/tokens.ts';
import { noopDeviceId } from '../_shared/keys.ts';
import { makeMemRest } from './helpers.ts';

const USER = '11111111-1111-4111-8111-111111111111';
const OTHER = '22222222-2222-4222-8222-222222222222';
const SOURCE = '33333333-3333-4333-8333-333333333333';
const LOCAL = 'whoop-ABC123456';
const DEVICE = noopDeviceId(USER, LOCAL);
const cfg = { supabaseUrl: 'https://test.invalid', supabaseAnonKey: 'fixture-public' };

async function fixture() {
  const rest = makeMemRest() as any;
  await rest.upsert('noop_ingest_tokens', [
    { id: 'personal', token_hash: hashIngestToken('noop_personal'), token_kind: 'installation', user_id: USER, source_id: SOURCE },
    { id: 'fleet', token_hash: hashIngestToken('noop_fleet'), token_kind: 'fleet' },
    { id: 'legacy', token_hash: hashIngestToken('noop_legacy'), token_kind: 'legacy_upload', user_id: USER },
  ]);
  await rest.upsert('noop_app_installations', { user_id: USER, source_id: SOURCE });
  await rest.upsert('devices', { id: DEVICE, user_id: USER, source_kind: 'noop_push', external_device_id: LOCAL });
  const calls: any[] = [];
  rest.rpc = async (name: string, args: any) => {
    calls.push({ name, args });
    if (name === 'register_noop_device') return args.p_device;
    if (name === 'enrolled_physiology_sleep_override') return 2;
    return { schema_version: 2, user_id: args.p_user, day: args.p_day, features: {
      hrv: { device_id: args.p_device, status: 'unavailable', reason:
        name==='server_scoring_pending_contract'?'device_registration_pending':'awaiting_result' },
    } };
  };
  return { rest, calls };
}

function request(path = `?day=2026-09-19&deviceId=${LOCAL}`, body?: unknown, bearer = 'noop_personal', fleet = 'noop_fleet') {
  return new Request(`https://test.invalid/functions/v1/scores${path}`, {
    method: body === undefined ? 'GET' : 'POST',
    headers: { authorization: `Bearer ${bearer}`, 'x-noop-fleet-token': fleet, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

Deno.test('scores: fleet-only, legacy and unvalidated JWT credentials cannot read personal data', async () => {
  for (const bearer of ['noop_fleet', 'noop_legacy', 'header.payload.signature']) {
    const { rest, calls } = await fixture();
    assertEquals((await handleScoresRequest(request(undefined, undefined, bearer), {
      rest, cfg, fetchImpl:async()=>Response.json({error:'invalid_token'},{status:401}),
    })).status, 401);
    assertEquals(calls.length, 0);
  }
});

Deno.test('enrolled scores: expired token, revoked installation and missing fleet fail before results', async () => {
  for (const failure of ['expired', 'revoked', 'fleet']) {
    const { rest, calls } = await fixture();
    if (failure === 'expired') rest.tables.get('noop_ingest_tokens')[0].expires_at = '2020-01-01T00:00:00Z';
    if (failure === 'revoked') rest.tables.get('noop_app_installations')[0].revoked_at = '2020-01-01T00:00:00Z';
    const res = await handleScoresRequest(request(undefined, undefined, 'noop_personal', failure === 'fleet' ? '' : 'noop_fleet'), { rest, cfg });
    assertEquals(res.status, 401); assertEquals(calls.length, 0);
  }
});

Deno.test('account scores: explicit source revocation cannot fall back to an active installation', async () => {
  for (const binding of [
    { user_id: USER, revoked_at: '2026-09-20T00:00:00Z' },
    { user_id: OTHER, revoked_at: null },
  ]) {
    const { rest, calls } = await fixture();
    await rest.upsert('compute_account_sources', { ...binding, source_id: SOURCE });
    const req = request(undefined, undefined, 'header.payload.signature');
    req.headers.set('x-noop-source-id', SOURCE);
    const response = await handleScoresRequest(req, {
      rest, cfg, fetchImpl: async () => Response.json({ id: USER }),
    });
    assertEquals(response.status, 401);
    assertEquals(calls, []);
  }
});

Deno.test('account scores: an active owned account source and enrollment use the same selected-device RPC', async () => {
  const { rest, calls } = await fixture();
  await rest.upsert('compute_account_sources', { user_id: USER, source_id: SOURCE, revoked_at: null });
  const account = request(undefined, undefined, 'header.payload.signature');
  account.headers.set('x-noop-source-id', SOURCE);
  const response = await handleScoresRequest(account, {
    rest, cfg, fetchImpl: async () => Response.json({ id: USER }),
  });
  assertEquals(response.status, 200);
  const accountBody = await response.json();
  const enrolled = await handleScoresRequest(request(), { rest, cfg });
  assertEquals(await enrolled.json(), accountBody);
  assertEquals(calls.length, 2);
  assertEquals(calls[0], calls[1]);
});

Deno.test('enrolled scores: requested user cannot override token owner; missing device never defaults', async () => {
  const { rest, calls } = await fixture();
  const res = await handleScoresRequest(request(`?day=2026-09-19&deviceId=${LOCAL}&userId=${OTHER}`), { rest, cfg });
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.identity, { userId: USER, sourceId: SOURCE, deviceId: DEVICE, externalDeviceId: LOCAL, project:cfg.supabaseUrl });
  assertEquals(calls[0].args, { p_user: USER, p_day: '2026-09-19', p_device: DEVICE });
  calls.length = 0;
  const other = await handleScoresRequest(request('?day=2026-09-19&deviceId=whoop-OTHER123'), { rest, cfg });
  const unavailable = await other.json();
  assertEquals(unavailable.identity.deviceId, null);
  assertEquals(unavailable.server_scoring.features.hrv.reason, 'device_registration_pending');
  assertEquals(calls, [{name:'server_scoring_pending_contract',args:{p_user:USER,p_day:'2026-09-19'}}]);
  assertEquals((await handleScoresRequest(request('?day=2026-09-19'), { rest, cfg })).status, 400);
});

Deno.test('enrolled scores: invalid calendar dates do not call the database', async () => {
  const { rest, calls } = await fixture();
  assertEquals((await handleScoresRequest(request(`?day=2026-02-30&deviceId=${LOCAL}`), { rest, cfg })).status, 400);
  assertEquals(calls.length, 0);
});

Deno.test('enrolled diagnostics: exact installation and registered device scope, no user override', async () => {
  const { rest, calls } = await fixture();
  const response = await handleScoresRequest(request(`/diagnostics?day=2026-09-19&deviceId=${LOCAL}&userId=${OTHER}`), { rest, cfg });
  assertEquals(response.status, 200);
  assertEquals(response.headers.get('cache-control'), 'no-store');
  assertEquals(calls, [{ name: 'server_pipeline_diagnostics', args: {
    p_user: USER, p_source: SOURCE, p_device: DEVICE, p_day: '2026-09-19',
  } }]);
  calls.length = 0;
  assertEquals((await handleScoresRequest(request('/diagnostics?day=2026-09-19&deviceId=whoop-MISSING'), { rest, cfg })).status, 409);
  assertEquals((await handleScoresRequest(request(`/diagnostics?day=2026-02-30&deviceId=${LOCAL}`), { rest, cfg })).status, 400);
  assertEquals(calls.length, 0);
});

Deno.test('enrolled registration: ACK follows atomic owned-device RPC', async () => {
  const { rest, calls } = await fixture();
  const res = await handleScoresRequest(request('/devices', { deviceId: LOCAL }), { rest, cfg });
  assertEquals(res.status, 200);
  assertEquals(calls[0].name, 'register_noop_device');
  assertEquals(calls[0].args.p_user, USER);
  assertEquals((await res.json()).identity.deviceId, DEVICE);
});

Deno.test('enrolled overrides: preserve optimistic revision and reject owner/device overrides', async () => {
  const args = { p_id: '44444444-4444-4444-8444-444444444444', p_device: DEVICE,
    p_original_start: '2026-09-19T00:00:00Z', p_original_end: '2026-09-19T08:00:00Z',
    p_start: '2026-09-19T00:10:00Z', p_end: '2026-09-19T08:00:00Z', p_tombstone: false, p_expected_revision: 1 };
  const { rest, calls } = await fixture();
  const accepted = await handleScoresRequest(request('/sleep-overrides', { deviceId: LOCAL, arguments: args }), { rest, cfg });
  assertEquals(accepted.status, 200); assertEquals(await accepted.json(), 2);
  assertEquals(calls[0].args.p_user, USER);
  assertEquals(calls[0].args.p_expected_revision, 1);
  for (const altered of [{ ...args, p_device: OTHER }, { ...args, p_user: OTHER }]) {
    const rejected = await handleScoresRequest(request('/sleep-overrides', { deviceId: LOCAL, arguments: altered }), { rest, cfg });
    assertEquals(rejected.status, 400);
  }
  assertEquals(calls.length, 1);
  rest.rpc = async () => { throw Object.assign(new Error('conflict'), { status: 409 }); };
  assertEquals((await handleScoresRequest(request('/sleep-overrides', { deviceId: LOCAL, arguments: args }), { rest, cfg })).status, 409);
});
