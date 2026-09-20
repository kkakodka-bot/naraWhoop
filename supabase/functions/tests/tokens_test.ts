// Token lifecycle tests for the Edge port of the retired Node receiver +
// the retired Node receiver createIngestTokenStore.
import { assert, assertEquals, assertRejects } from 'jsr:@std/assert';
import {
  createIngestTokenStore,
  hashIngestToken,
  IdentityError,
  resolveFleetAuthorization,
  resolveJwtUser,
  resolvePushUser,
  resolveUploadIdentity,
  publicIngestTokenRow,
} from '../_shared/tokens.ts';
import { makeMemRest } from './helpers.ts';

const USER = '7f2c9a10-4b3e-4d8a-9c11-00000000f001';
const SOURCE = '7f2c9a10-4b3e-4d8a-9c11-00000000f002';

async function insertToken(rest: ReturnType<typeof makeMemRest>, {
  token,
  kind,
  userId = USER,
  sourceId = null,
  expiresAt = null,
}: {
  token: string;
  kind: 'legacy_upload' | 'fleet' | 'installation';
  userId?: string | null;
  sourceId?: string | null;
  expiresAt?: string | null;
}) {
  const [row] = await rest.upsert('noop_ingest_tokens', {
    user_id: userId,
    source_id: sourceId,
    token_hash: hashIngestToken(token),
    token_kind: kind,
    expires_at: expiresAt,
    revoked_at: null,
  }) as any[];
  return row;
}

Deno.test('tokens: mint stores the SHA-256 hash, returns the raw token once', async () => {
  const rest = makeMemRest();
  const store = createIngestTokenStore({ rest });
  const minted = await store.mint({ userId: USER, label: 'conformance' });
  assert(typeof minted.token === 'string' && minted.token.startsWith('noop_'));
  assertEquals(minted.row?.label, 'conformance');
  const rows = rest.tables.get('noop_ingest_tokens') || [];
  assertEquals(rows.length, 1);
  assertEquals(rows[0].token_hash, hashIngestToken(minted.token));
  assert(!String(rows[0].token_hash).includes(minted.token), 'hash must not leak the raw token');
});

Deno.test('tokens: list returns every minted token for the user', async () => {
  const rest = makeMemRest();
  const store = createIngestTokenStore({ rest });
  await store.mint({ userId: USER, label: 'a' });
  await store.mint({ userId: USER, label: 'b' });
  const listed = await store.list({ userId: USER });
  assertEquals(listed.length, 2);
  assertEquals(new Set(listed.filter((r) => r != null).map((r) => r!.label)), new Set(['a', 'b']));
});

Deno.test('tokens: revoke hides the token and the revoked bearer no longer authenticates', async () => {
  const rest = makeMemRest();
  const store = createIngestTokenStore({ rest });
  const minted = await store.mint({ userId: USER, label: 'revoke-me' });
  const revoked = await store.revoke({ userId: USER, id: String(minted.row?.id) });
  assert(revoked != null && revoked.revokedAt != null);
  // A revoked bearer must be rejected by resolvePushUser (same path the function uses).
  const headers = new Headers({ authorization: `Bearer ${minted.token}` });
  let denied = false;
  try {
    await resolvePushUser({
      headers,
      rest: rest as any,
      supabaseUrl: 'http://127.0.0.1:54321',
      anonKey: 'anon',
    });
  } catch {
    denied = true;
  }
  assert(denied, 'revoked token must fail resolvePushUser');
});

Deno.test('tokens: revoking a missing or already-revoked id returns null', async () => {
  const rest = makeMemRest();
  const store = createIngestTokenStore({ rest });
  assertEquals(await store.revoke({ userId: USER, id: '00000000-0000-4000-8000-000000000000' }), null);
  const minted = await store.mint({ userId: USER });
  await store.revoke({ userId: USER, id: String(minted.row?.id) });
  assertEquals(await store.revoke({ userId: USER, id: String(minted.row?.id) }), null);
});

Deno.test('tokens: publicIngestTokenRow never exposes the hash', async () => {
  const pub = publicIngestTokenRow({ id: 'x', label: 'l', created_at: '2026-01-01T00:00:00Z', token_hash: 'secret', last_used_at: null, revoked_at: null });
  assert(!JSON.stringify(pub).includes('secret'));
  assertEquals(pub?.id, 'x');
});

Deno.test('tokens: an installation upload requires a second valid fleet credential', async () => {
  const rest = makeMemRest();
  const installation = 'noop_installation-test-token';
  const fleet = 'noop_fleet-test-token';
  const installationRow = await insertToken(rest, {
    token: installation,
    kind: 'installation',
    sourceId: SOURCE,
    expiresAt: '2099-01-01T00:00:00.000Z',
  });
  await insertToken(rest, { token: fleet, kind: 'fleet', userId: null });
  await rest.upsert('noop_app_installations', {
    user_id: USER,
    source_id: SOURCE,
    revoked_at: null,
  }, { onConflict: 'source_id' });

  const identity = await resolveUploadIdentity({
    headers: new Headers({
      authorization: `Bearer ${installation}`,
      'x-noop-fleet-token': fleet,
    }),
    rest: rest as any,
  });
  assertEquals(identity.id, USER);
  assertEquals(identity.sourceId, SOURCE);
  assertEquals(identity.tokenId, installationRow.id);
  assertEquals(identity.authMode, 'installation');

  let denied = false;
  try {
    await resolveUploadIdentity({
      headers: new Headers({ authorization: `Bearer ${installation}` }),
      rest: rest as any,
    });
  } catch (err) {
    denied = err instanceof IdentityError && err.status === 401;
  }
  assert(denied, 'installation bearer without fleet authorization must fail closed');
});

Deno.test('tokens: legacy bearer-only upload is disabled by default and explicitly marked when enabled', async () => {
  const rest = makeMemRest();
  const legacy = 'noop_legacy-build-token';
  await insertToken(rest, { token: legacy, kind: 'legacy_upload' });

  let denied = false;
  try {
    await resolveUploadIdentity({
      headers: new Headers({ authorization: `Bearer ${legacy}` }),
      rest: rest as any,
    });
  } catch (err) {
    denied = err instanceof IdentityError && err.status === 401;
  }
  assert(denied);

  const allowed = await resolveUploadIdentity({
    headers: new Headers({ authorization: `Bearer ${legacy}` }),
    rest: rest as any,
    allowLegacyFleetUploads: true,
  });
  assertEquals(allowed.id, USER);
  assertEquals(allowed.sourceId, null);
  assertEquals(allowed.authMode, 'legacy_fleet');
});

Deno.test('tokens: invalid identity plus a present fleet header never falls back to legacy upload', async () => {
  const rest = makeMemRest();
  const legacy = 'noop_legacy-build-token';
  await insertToken(rest, { token: legacy, kind: 'legacy_upload' });
  let denied = false;
  try {
    await resolveUploadIdentity({
      headers: new Headers({
        authorization: `Bearer ${legacy}`,
        'x-noop-fleet-token': 'noop_not-valid',
      }),
      rest: rest as any,
      allowLegacyFleetUploads: true,
    });
  } catch (err) {
    denied = err instanceof IdentityError && err.status === 401;
  }
  assert(denied, 'a present but invalid identity contract must not downgrade to bearer-only mode');
});

Deno.test('tokens: expired installation credentials fail before fleet authorization can identify a user', async () => {
  const rest = makeMemRest();
  const installation = 'noop_expired-installation-token';
  const fleet = 'noop_valid-fleet-token';
  await insertToken(rest, {
    token: installation,
    kind: 'installation',
    sourceId: SOURCE,
    expiresAt: '2020-01-01T00:00:00.000Z',
  });
  await insertToken(rest, { token: fleet, kind: 'fleet', userId: null });
  await rest.upsert('noop_app_installations', {
    user_id: USER,
    source_id: SOURCE,
    revoked_at: null,
  }, { onConflict: 'source_id' });

  let denied = false;
  try {
    await resolveUploadIdentity({
      headers: new Headers({
        authorization: `Bearer ${installation}`,
        'x-noop-fleet-token': fleet,
      }),
      rest: rest as any,
    });
  } catch (err) {
    denied = err instanceof IdentityError && err.status === 401;
  }
  assert(denied);
});

Deno.test('tokens: a legacy row cannot fill the fleet slot until explicitly classified', async () => {
  const rest = makeMemRest();
  const legacy = 'noop_existing-shared-token';
  await insertToken(rest, { token: legacy, kind: 'legacy_upload' });
  await assertRejects(
    () => resolveFleetAuthorization({
      headers: new Headers({ authorization: `Bearer ${legacy}` }),
      rest: rest as any,
      fromAuthorization: true,
    }),
    IdentityError,
    'fleet authorization required',
  );
});

Deno.test('tokens: token management accepts a validated JWT and rejects opaque tokens with 401 identity errors', async () => {
  const jwt = 'header.payload.signature';
  const accepted = await resolveJwtUser({
    headers: new Headers({ authorization: `Bearer ${jwt}` }),
    supabaseUrl: 'https://project.test',
    anonKey: 'anon',
    fetchImpl: (async () => ({
      ok: true,
      json: async () => ({ id: USER, email: 'tester@example.test' }),
    })) as any,
  });
  assertEquals(accepted.id, USER);

  let denied = false;
  try {
    await resolveJwtUser({
      headers: new Headers({ authorization: 'Bearer noop_opaque' }),
      supabaseUrl: 'https://project.test',
      anonKey: 'anon',
    });
  } catch (err) {
    denied = err instanceof IdentityError && err.status === 401;
  }
  assert(denied, 'opaque upload tokens must never manage /tokens');
});

Deno.test('tokens: Edge management handlers catch JWT auth Responses instead of leaking a 500', async () => {
  const source = await Deno.readTextFile(new URL('../push/index.ts', import.meta.url));
  for (const name of ['handleTokenMint', 'handleTokenList', 'handleTokenRevoke']) {
    const start = source.indexOf(`async function ${name}`);
    assert(start >= 0, `${name} missing`);
    const next = source.indexOf('\nasync function ', start + 1);
    const handler = source.slice(start, next >= 0 ? next : source.length);
    const tryAt = handler.indexOf('try {');
    const authAt = handler.indexOf('await authenticateJwt(req)');
    assert(tryAt >= 0 && authAt > tryAt, `${name} must authenticate inside its try block`);
    assert(
      handler.includes('if (err instanceof Response) return err;'),
      `${name} must return the 401 Response thrown by authenticateJwt`,
    );
  }
});
