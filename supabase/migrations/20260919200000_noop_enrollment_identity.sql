-- Stable tester identity for NOOP push.
--
-- A fleet credential authorizes this build to talk to the receiver, but never names a tester.
-- Enrollment exchanges a high-entropy, peppered code for an installation token bound to one
-- auth.users id and one app source id. The Edge function holds the plaintext code and token only
-- long enough to hash them; Postgres stores hashes and server-stamped provenance.

-- Existing opaque credentials predate token kinds. Preserve them as legacy credentials so the
-- rollout can explicitly decide where they are accepted instead of silently treating them as
-- either fleet or personal identity.
alter table public.noop_ingest_tokens
  alter column user_id drop not null;

alter table public.noop_ingest_tokens
  add column if not exists token_kind text not null default 'legacy_upload',
  add column if not exists source_id uuid,
  add column if not exists expires_at timestamptz,
  add column if not exists enrollment_code_id uuid;

alter table public.noop_ingest_tokens
  drop constraint if exists noop_ingest_tokens_token_kind_check;
alter table public.noop_ingest_tokens
  add constraint noop_ingest_tokens_token_kind_check
  check (token_kind = any (array['legacy_upload'::text, 'fleet'::text, 'installation'::text]));

alter table public.noop_ingest_tokens
  drop constraint if exists noop_ingest_tokens_identity_shape_check;
alter table public.noop_ingest_tokens
  add constraint noop_ingest_tokens_identity_shape_check check (
    (token_kind = 'fleet' and source_id is null and enrollment_code_id is null)
    or (token_kind = 'legacy_upload' and user_id is not null and source_id is null and enrollment_code_id is null)
    or (token_kind = 'installation' and user_id is not null and source_id is not null and enrollment_code_id is not null)
  ) not valid;

alter table public.noop_ingest_tokens
  validate constraint noop_ingest_tokens_identity_shape_check;

create index if not exists noop_ingest_tokens_kind_hash_idx
  on public.noop_ingest_tokens (token_kind, token_hash)
  where revoked_at is null;

create index if not exists noop_ingest_tokens_installation_idx
  on public.noop_ingest_tokens (user_id, source_id, created_at desc)
  where token_kind = 'installation';

create table if not exists public.noop_enrollment_codes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  code_hash text not null,
  label text not null default '',
  expires_at timestamptz not null,
  revoked_at timestamptz,
  redeemed_source_id uuid,
  redeemed_at timestamptz,
  redemption_count integer not null default 0,
  max_redemptions integer not null default 1,
  created_at timestamptz not null default now(),
  constraint noop_enrollment_codes_hash_len check (char_length(code_hash) = 64),
  constraint noop_enrollment_codes_hash_hex check (code_hash ~ '^[0-9a-f]{64}$'),
  constraint noop_enrollment_codes_redemption_count_check check (redemption_count >= 0),
  constraint noop_enrollment_codes_max_redemptions_check check (max_redemptions > 0),
  constraint noop_enrollment_codes_redemption_limit_check check (redemption_count <= max_redemptions)
);

create unique index if not exists noop_enrollment_codes_hash_uidx
  on public.noop_enrollment_codes (code_hash);

create index if not exists noop_enrollment_codes_user_created_idx
  on public.noop_enrollment_codes (user_id, created_at desc);

create table if not exists public.noop_app_installations (
  source_id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  enrollment_code_id uuid not null references public.noop_enrollment_codes(id) on delete cascade,
  platform text not null,
  app_version text not null,
  first_enrolled_at timestamptz not null default now(),
  last_enrolled_at timestamptz not null default now(),
  last_seen_at timestamptz,
  revoked_at timestamptz,
  constraint noop_app_installations_platform_check
    check (platform = any (array['ios'::text, 'macos'::text, 'android'::text])),
  constraint noop_app_installations_app_version_len
    check (char_length(app_version) between 1 and 64),
  unique (user_id, source_id)
);

alter table public.noop_ingest_tokens
  drop constraint if exists noop_ingest_tokens_enrollment_code_fkey;
alter table public.noop_ingest_tokens
  add constraint noop_ingest_tokens_enrollment_code_fkey
  foreign key (enrollment_code_id) references public.noop_enrollment_codes(id) on delete cascade;

alter table public.noop_ingest_tokens
  drop constraint if exists noop_ingest_tokens_installation_fkey;
alter table public.noop_ingest_tokens
  add constraint noop_ingest_tokens_installation_fkey
  foreign key (user_id, source_id)
  references public.noop_app_installations(user_id, source_id) on delete cascade;

-- Only one live personal token may represent an app installation. A fresh enrollment code rotates
-- that token while preserving the installation's stable user_id/source_id tuple.
create unique index if not exists noop_ingest_tokens_active_installation_uidx
  on public.noop_ingest_tokens (user_id, source_id)
  where token_kind = 'installation' and revoked_at is null;

create table if not exists public.noop_enrollment_redemptions (
  id uuid primary key default gen_random_uuid(),
  enrollment_code_id uuid not null references public.noop_enrollment_codes(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  source_id uuid not null,
  token_id uuid not null references public.noop_ingest_tokens(id) on delete cascade,
  platform text not null,
  app_version text not null,
  is_retry boolean not null default false,
  redeemed_at timestamptz not null default now(),
  foreign key (user_id, source_id)
    references public.noop_app_installations(user_id, source_id) on delete cascade,
  constraint noop_enrollment_redemptions_platform_check
    check (platform = any (array['ios'::text, 'macos'::text, 'android'::text])),
  constraint noop_enrollment_redemptions_app_version_len
    check (char_length(app_version) between 1 and 64)
);

create index if not exists noop_enrollment_redemptions_code_idx
  on public.noop_enrollment_redemptions (enrollment_code_id, redeemed_at desc);

create index if not exists noop_enrollment_redemptions_source_idx
  on public.noop_enrollment_redemptions (user_id, source_id, redeemed_at desc);

-- Durable, server-stamped receipt for accepted inline batches and completed direct objects. The
-- receipt names the credential row, never the plaintext token.
create table if not exists public.noop_upload_receipts (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  source_id uuid,
  device_id uuid not null references public.devices(id) on delete cascade,
  token_id uuid references public.noop_ingest_tokens(id) on delete set null,
  auth_mode text not null,
  lane text not null,
  stream text not null,
  batch_id uuid not null,
  object_id uuid references public.object_manifests(id) on delete set null,
  body_sha256 text not null,
  accepted_status text not null,
  accepted_rows bigint,
  accepted_at timestamptz not null default now(),
  constraint noop_upload_receipts_auth_mode_check
    check (auth_mode = any (array['installation'::text, 'legacy_fleet'::text])),
  constraint noop_upload_receipts_lane_check
    check (lane = any (array['inline'::text, 'object'::text])),
  constraint noop_upload_receipts_body_sha256_len check (char_length(body_sha256) = 64),
  constraint noop_upload_receipts_body_sha256_hex check (body_sha256 ~ '^[0-9a-f]{64}$'),
  constraint noop_upload_receipts_accepted_rows_check check (accepted_rows is null or accepted_rows >= 0)
);

create index if not exists noop_upload_receipts_user_accepted_idx
  on public.noop_upload_receipts (user_id, accepted_at desc);

create index if not exists noop_upload_receipts_source_accepted_idx
  on public.noop_upload_receipts (user_id, source_id, accepted_at desc);

-- Inline and direct object manifests carry the same provenance as the durable receipt.
alter table public.object_manifests
  add column if not exists ingest_token_id uuid references public.noop_ingest_tokens(id) on delete set null,
  add column if not exists auth_mode text;

alter table public.object_manifests
  drop constraint if exists object_manifests_auth_mode_check;
alter table public.object_manifests
  add constraint object_manifests_auth_mode_check
  check (auth_mode is null or auth_mode = any (array['installation'::text, 'legacy_fleet'::text]));

-- One object upload owns one receipt/idempotency batch id. This also closes the intent-time race
-- between separate Edge isolates trying to create different objects for the same batch.
create unique index if not exists object_manifests_user_batch_uidx
  on public.object_manifests (user_id, batch_id)
  where batch_id is not null;

alter table public.noop_signal_windows
  add column if not exists source_id uuid,
  add column if not exists batch_id uuid,
  add column if not exists ingest_token_id uuid references public.noop_ingest_tokens(id) on delete set null,
  add column if not exists auth_mode text;

alter table public.noop_signal_windows
  drop constraint if exists noop_signal_windows_auth_mode_check;
alter table public.noop_signal_windows
  add constraint noop_signal_windows_auth_mode_check
  check (auth_mode is null or auth_mode = any (array['installation'::text, 'legacy_fleet'::text]));

-- Atomic enrollment redemption. Edge deterministically derives the installation token from the
-- code/source pair and a server-only pepper, then passes only its SHA-256 hash. A same-source retry
-- inside the bounded window reasserts that same hash on the original token row, so duplicated or
-- reordered HTTP responses cannot invalidate one another. A different source never inherits the
-- first source's identity.
create or replace function public.redeem_noop_enrollment(
  p_code_hash text,
  p_source_id uuid,
  p_platform text,
  p_app_version text,
  p_token_hash text,
  p_retry_window_seconds integer
) returns table(user_id uuid, token_id uuid)
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_code public.noop_enrollment_codes%rowtype;
  v_existing_user uuid;
  v_token_id uuid;
  v_first_redeemed_at timestamptz;
  v_now timestamptz := clock_timestamp();
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'enrollment_service_role_required' using errcode = '42501';
  end if;
  if p_code_hash is null or p_code_hash !~ '^[0-9a-f]{64}$'
      or p_token_hash is null or p_token_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'enrollment_hash_invalid' using errcode = '22023';
  end if;
  if p_source_id is null then
    raise exception 'enrollment_source_invalid' using errcode = '22023';
  end if;
  if p_platform is null or p_platform <> all (array['ios'::text, 'macos'::text, 'android'::text]) then
    raise exception 'enrollment_platform_invalid' using errcode = '22023';
  end if;
  if p_app_version is null or char_length(p_app_version) not between 1 and 64 then
    raise exception 'enrollment_app_version_invalid' using errcode = '22023';
  end if;
  if p_retry_window_seconds is null or p_retry_window_seconds not between 1 and 900 then
    raise exception 'enrollment_retry_window_invalid' using errcode = '22023';
  end if;

  select c.* into v_code
  from public.noop_enrollment_codes c
  where c.code_hash = p_code_hash
  for update;

  if not found then
    raise exception 'enrollment_code_invalid' using errcode = 'P0001';
  end if;
  if v_code.revoked_at is not null then
    raise exception 'enrollment_code_revoked' using errcode = 'P0001';
  end if;
  if v_code.expires_at <= v_now then
    raise exception 'enrollment_code_expired' using errcode = 'P0001';
  end if;

  -- Serialize all codes that race to claim the same installation id.
  perform pg_advisory_xact_lock(hashtextextended(p_source_id::text, 0));

  if v_code.redeemed_source_id is not null then
    if v_code.redeemed_source_id <> p_source_id then
      raise exception 'enrollment_code_already_used' using errcode = 'P0001';
    end if;

    select r.token_id, min(r.redeemed_at)
      into v_token_id, v_first_redeemed_at
    from public.noop_enrollment_redemptions r
    where r.enrollment_code_id = v_code.id
      and r.source_id = p_source_id
    group by r.token_id
    order by min(r.redeemed_at)
    limit 1;

    if v_token_id is null
        or v_first_redeemed_at < v_now - make_interval(secs => p_retry_window_seconds) then
      raise exception 'enrollment_retry_window_elapsed' using errcode = 'P0001';
    end if;

    update public.noop_ingest_tokens t
    set token_hash = p_token_hash,
        expires_at = v_now + interval '365 days',
        last_used_at = null
    where t.id = v_token_id
      and t.user_id = v_code.user_id
      and t.source_id = p_source_id
      and t.token_kind = 'installation'
      and t.last_used_at is null
      and t.revoked_at is null;
    if not found then
      raise exception 'enrollment_retry_unavailable' using errcode = 'P0001';
    end if;

    update public.noop_app_installations i
    set platform = p_platform,
        app_version = p_app_version,
        last_enrolled_at = v_now
    where i.source_id = p_source_id and i.user_id = v_code.user_id;

    insert into public.noop_enrollment_redemptions (
      enrollment_code_id, user_id, source_id, token_id, platform, app_version, is_retry, redeemed_at
    ) values (
      v_code.id, v_code.user_id, p_source_id, v_token_id, p_platform, p_app_version, true, v_now
    );

    return query select v_code.user_id, v_token_id;
    return;
  end if;

  if v_code.redemption_count >= v_code.max_redemptions then
    raise exception 'enrollment_code_already_used' using errcode = 'P0001';
  end if;

  select i.user_id into v_existing_user
  from public.noop_app_installations i
  where i.source_id = p_source_id
  for update;

  if v_existing_user is not null and v_existing_user <> v_code.user_id then
    raise exception 'enrollment_source_already_bound' using errcode = 'P0001';
  end if;

  insert into public.noop_app_installations (
    source_id, user_id, enrollment_code_id, platform, app_version,
    first_enrolled_at, last_enrolled_at
  ) values (
    p_source_id, v_code.user_id, v_code.id, p_platform, p_app_version, v_now, v_now
  )
  on conflict (source_id) do update
    set enrollment_code_id = excluded.enrollment_code_id,
        platform = excluded.platform,
        app_version = excluded.app_version,
        last_enrolled_at = excluded.last_enrolled_at,
        revoked_at = null
  where public.noop_app_installations.user_id = excluded.user_id;

  update public.noop_ingest_tokens t
  set revoked_at = v_now
  where t.user_id = v_code.user_id
    and t.source_id = p_source_id
    and t.token_kind = 'installation'
    and t.revoked_at is null;

  insert into public.noop_ingest_tokens (
    user_id, token_hash, label, token_kind, source_id, expires_at, enrollment_code_id
  ) values (
    v_code.user_id,
    p_token_hash,
    'enrollment:' || p_platform,
    'installation',
    p_source_id,
    v_now + interval '365 days',
    v_code.id
  ) returning id into v_token_id;

  insert into public.noop_enrollment_redemptions (
    enrollment_code_id, user_id, source_id, token_id, platform, app_version, is_retry, redeemed_at
  ) values (
    v_code.id, v_code.user_id, p_source_id, v_token_id, p_platform, p_app_version, false, v_now
  );

  update public.noop_enrollment_codes c
  set redeemed_source_id = p_source_id,
      redeemed_at = v_now,
      redemption_count = c.redemption_count + 1
  where c.id = v_code.id;

  return query select v_code.user_id, v_token_id;
end;
$$;

-- Enrollment administration and receipts are never client-facing tables. The service role may use
-- them through Edge/ops code; anon and authenticated roles receive no table or RPC privileges.
alter table public.noop_enrollment_codes enable row level security;
alter table public.noop_app_installations enable row level security;
alter table public.noop_enrollment_redemptions enable row level security;
alter table public.noop_upload_receipts enable row level security;

revoke all on table public.noop_enrollment_codes from public, anon, authenticated;
revoke all on table public.noop_app_installations from public, anon, authenticated;
revoke all on table public.noop_enrollment_redemptions from public, anon, authenticated;
revoke all on table public.noop_upload_receipts from public, anon, authenticated;
grant all on table public.noop_enrollment_codes to service_role;
grant all on table public.noop_app_installations to service_role;
grant all on table public.noop_enrollment_redemptions to service_role;
grant all on table public.noop_upload_receipts to service_role;

drop policy if exists noop_ingest_tokens_insert_own on public.noop_ingest_tokens;
drop policy if exists noop_ingest_tokens_update_own on public.noop_ingest_tokens;
revoke all on table public.noop_ingest_tokens from public, anon, authenticated;
grant all on table public.noop_ingest_tokens to service_role;

revoke all on function public.redeem_noop_enrollment(text, uuid, text, text, text, integer) from public;
revoke all on function public.redeem_noop_enrollment(text, uuid, text, text, text, integer) from anon;
revoke all on function public.redeem_noop_enrollment(text, uuid, text, text, text, integer) from authenticated;
grant execute on function public.redeem_noop_enrollment(text, uuid, text, text, text, integer) to service_role;

comment on table public.noop_enrollment_codes is
  'Ops-issued enrollment codes stored only as HMAC-SHA256 hashes; plaintext is never persisted.';
comment on table public.noop_app_installations is
  'Stable tester/source bindings created atomically by enrollment redemption.';
comment on table public.noop_upload_receipts is
  'Durable server-stamped receipt for each accepted inline batch or completed direct object.';
