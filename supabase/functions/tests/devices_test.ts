import { assertEquals, assertNotEquals, assertRejects } from 'jsr:@std/assert';
import { createDeviceRegistrar } from '../_shared/devices.ts';
import { createSupabaseRest } from '../_shared/rest.ts';

Deno.test('device registration and retries use the atomic database RPC', async () => {
  const calls: { path: string; body: unknown }[] = [];
  const rest = createSupabaseRest({
    cfg: { supabaseUrl: 'https://fixture.invalid', supabaseServiceRoleKey: 'fixture-only' },
    fetchImpl: async (input, init) => {
      calls.push({ path: new URL(String(input)).pathname, body: JSON.parse(String(init?.body)) });
      return new Response('"device"', { status: 200 });
    },
  });
  const register = createDeviceRegistrar(rest);
  const row = { id: 'device', user_id: 'owner', external_device_id: 'strap', last_seen_at: '2026-09-18T00:00:00Z' };
  await register(row);
  await register(row);
  assertEquals(calls, [0, 1].map(() => ({ path: '/rest/v1/rpc/register_noop_device', body: {
    p_device: 'device', p_user: 'owner', p_external_device_id: 'strap', p_last_seen_at: '2026-09-18T00:00:00Z',
  } })));
});

Deno.test('device registration propagates database rejection before ingestion proceeds', async () => {
  const rest = createSupabaseRest({
    cfg: { supabaseUrl: 'https://fixture.invalid', supabaseServiceRoleKey: 'fixture-only' },
    fetchImpl: async () => new Response(JSON.stringify({ message: 'device_registration_conflict' }), { status: 409 }),
  });
  await assertRejects(() => createDeviceRegistrar(rest)({ id: 'device', user_id: 'owner' }), Error, 'device_registration_conflict');
});
import { createNoopDeviceResolver, scopedExternalDeviceId } from '../_shared/devices.ts';
import { isSafeExternalDeviceId, noopDeviceId } from '../_shared/keys.ts';
import { makeMemRest } from './helpers.ts';

const USER_A = '11111111-1111-4111-8111-111111111111';
const USER_B = '22222222-2222-4222-8222-222222222222';

Deno.test('devices: UUID-looking wearable ids are namespaced per user', () => {
  const raw = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  assertNotEquals(noopDeviceId(USER_A, raw), raw);
  assertNotEquals(noopDeviceId(USER_A, raw), noopDeviceId(USER_B, raw));
});

Deno.test('devices: resolver preserves an existing user-scoped id before deriving a new one', async () => {
  const rest = makeMemRest();
  const raw = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  await rest.upsert('devices', {
    id: raw,
    user_id: USER_A,
    source_kind: 'noop_push',
    external_device_id: raw,
  }, { onConflict: 'id' });

  rest.rpc = async (_name: string, args: any) => args.p_device;
  const resolve = createNoopDeviceResolver({ rest: rest as any });
  assertEquals(await resolve({ userId: USER_A, externalDeviceId: raw }), raw);
  const userB = await resolve({ userId: USER_B, externalDeviceId: raw });
  assertEquals(userB, noopDeviceId(USER_B, raw));
  assertNotEquals(userB, raw);
});

Deno.test('devices: external ids are printable, bounded, and non-PII', async () => {
  assertEquals(isSafeExternalDeviceId('my-whoop'), true);
  assertEquals(isSafeExternalDeviceId('WHOOP-1234'), true);
  assertEquals(isSafeExternalDeviceId('a'.repeat(255)), true);
  assertEquals(isSafeExternalDeviceId('a'.repeat(256)), false);
  assertEquals(isSafeExternalDeviceId('strap\ncontrol'), false);
  assertEquals(isSafeExternalDeviceId('tester@example.test'), false);
  assertEquals(isSafeExternalDeviceId('+15551234567'), false);

  const resolve = createNoopDeviceResolver({ rest: makeMemRest() as any });
  await assertRejects(() => resolve({ userId: USER_A, externalDeviceId: 'tester@example.test' }));
});

Deno.test('devices: legacy names and provisional BLE UUIDs never join different installations', () => {
  const a = '33333333-3333-4333-8333-333333333333';
  const b = '44444444-4444-4444-8444-444444444444';
  for (const local of ['my-whoop', 'whoop-AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA', 'apple-health']) {
    assertNotEquals(scopedExternalDeviceId(local, a), scopedExternalDeviceId(local, b));
  }
  assertEquals(scopedExternalDeviceId('whoop-ABC123456', a), 'whoop-ABC123456');
  assertEquals(scopedExternalDeviceId('whoop-ABC123456', a), scopedExternalDeviceId('whoop-ABC123456', b));
});
