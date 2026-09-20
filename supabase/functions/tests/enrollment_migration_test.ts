import { assert, assertMatch } from 'jsr:@std/assert';

const migration = await Deno.readTextFile(
  new URL('../../migrations/20260919200000_noop_enrollment_identity.sql', import.meta.url),
);

Deno.test('enrollment migration: stable tables, token kinds, and upload provenance are present', () => {
  for (const name of [
    'noop_enrollment_codes',
    'noop_app_installations',
    'noop_enrollment_redemptions',
    'noop_upload_receipts',
  ]) {
    assert(migration.includes(`public.${name}`), `${name} missing`);
  }
  for (const column of ['token_kind', 'source_id', 'expires_at', 'enrollment_code_id']) {
    assert(migration.includes(column), `${column} missing`);
  }
  for (const provenance of ['stream text not null', 'body_sha256 text not null', 'auth_mode text not null']) {
    assert(migration.includes(provenance), `${provenance} missing`);
  }
});

Deno.test('enrollment migration: atomic RPC is service-role-only with a locked search path', () => {
  assertMatch(
    migration,
    /create or replace function public\.redeem_noop_enrollment\(\s*p_code_hash text,\s*p_source_id uuid,\s*p_platform text,\s*p_app_version text,\s*p_token_hash text,\s*p_retry_window_seconds integer\s*\)/s,
  );
  assertMatch(migration, /security definer\s*set search_path = pg_catalog/s);
  assertMatch(
    migration,
    /revoke all on function public\.redeem_noop_enrollment\(text, uuid, text, text, text, integer\) from authenticated/,
  );
  assertMatch(
    migration,
    /grant execute on function public\.redeem_noop_enrollment\(text, uuid, text, text, text, integer\) to service_role/,
  );
  assertMatch(migration, /pg_advisory_xact_lock/);
  assertMatch(migration, /for update/);
});

Deno.test('enrollment migration: admin tables and raw token hashes are not directly readable by clients', () => {
  assertMatch(
    migration,
    /revoke all on table public\.noop_enrollment_codes from public, anon, authenticated/,
  );
  assertMatch(
    migration,
    /revoke all on table public\.noop_ingest_tokens from public, anon, authenticated/,
  );
  assertMatch(migration, /validate constraint noop_ingest_tokens_identity_shape_check/);
});
