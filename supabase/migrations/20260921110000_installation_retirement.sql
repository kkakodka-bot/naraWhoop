begin;

alter table public.noop_app_installations add column retired_at timestamptz;
alter table public.noop_app_installations add column retirement_id uuid unique;
alter table public.noop_app_installations add constraint retirement_shape
  check ((retired_at is null) = (retirement_id is null));

create function public.noop_installation_immutable() returns trigger
language plpgsql set search_path='' as $$
begin
  if new.user_id is distinct from old.user_id or new.source_id is distinct from old.source_id
    or (old.retired_at is not null and (
      new.retired_at is distinct from old.retired_at or new.retirement_id is distinct from old.retirement_id
      or new.revoked_at is null)) then
    raise exception 'installation_epoch_immutable' using errcode='23514';
  end if;
  return new;
end $$;
create trigger noop_installation_immutable before update on public.noop_app_installations
  for each row execute function public.noop_installation_immutable();

-- Retirement is permanent; ordinary credential rotation and account deletion are separate.
-- The caller hashes an installation bearer, even on an idempotent retry after revocation.
create function public.retire_noop_installation(p_token_hash text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare t public.noop_ingest_tokens%rowtype; i public.noop_app_installations%rowtype;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'service role required' using errcode='42501';
  end if;
  select * into t from public.noop_ingest_tokens
    where token_hash=p_token_hash and token_kind='installation';
  if not found then raise exception 'installation authorization required' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(t.source_id::text,0));
  select * into i from public.noop_app_installations
    where user_id=t.user_id and source_id=t.source_id for update;
  if not found or (i.retired_at is null and
    (t.revoked_at is not null or t.expires_at<=clock_timestamp())) then
    raise exception 'installation authorization required' using errcode='42501';
  end if;
  if i.retired_at is null then
    update public.noop_app_installations set retired_at=clock_timestamp(),
      retirement_id=gen_random_uuid(),revoked_at=clock_timestamp()
      where user_id=t.user_id and source_id=t.source_id returning * into i;
    update public.noop_ingest_tokens set revoked_at=coalesce(revoked_at,i.retired_at)
      where user_id=i.user_id and source_id=i.source_id and token_kind='installation';
  end if;
  return jsonb_build_object('userId',i.user_id,'sourceId',i.source_id,
    'retirementId',i.retirement_id,'retiredAt',i.retired_at,'policy','retain_original_owner');
end $$;

-- Serialize the final durable write with retirement, including an HTTP request that authenticated
-- before retirement. Already accepted rows remain owned by their original principal.
create function public.noop_require_active_source() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if tg_table_name='object_manifests' and tg_op='UPDATE' then
    if old.status in ('ready','verified') and new.user_id=old.user_id
      and new.source_id is not distinct from old.source_id and new.device_id=old.device_id
      then return new; end if;
  end if;
  if new.source_id is not null and exists(select 1 from public.noop_app_installations where source_id=new.source_id) then
    perform 1 from public.noop_app_installations where source_id=new.source_id
      and user_id=new.user_id and revoked_at is null and retired_at is null for share;
    if not found then raise exception 'inactive_installation' using errcode='42501'; end if;
  end if;
  return new;
end $$;
create trigger noop_active_source before insert or update on public.noop_upload_receipts
  for each row execute function public.noop_require_active_source();
create trigger noop_active_source before insert or update on public.object_manifests
  for each row execute function public.noop_require_active_source();

-- The original durable reservation did not persist the enrollment fields. Bind them once
-- to the authenticated request without changing the original owner/source/device or token.
alter function public.noop_reserve_object_manifest(jsonb) rename to noop_reserve_object_manifest_lifecycle_core;
revoke all on function public.noop_reserve_object_manifest_lifecycle_core(jsonb) from public,anon,authenticated,service_role;
create function public.noop_reserve_object_manifest(p_manifest jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare p public.object_manifests%rowtype; v public.object_manifests%rowtype;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'service role required' using errcode='42501'; end if;
  p:=jsonb_populate_record(null::public.object_manifests,p_manifest);
  p.auth_mode:=coalesce(p.auth_mode,'legacy_fleet');
  if p.auth_mode not in ('installation','legacy_fleet') then raise exception 'invalid_auth_mode' using errcode='22023'; end if;
  if p.auth_mode='installation' then
    perform 1 from public.noop_app_installations where user_id=p.user_id and source_id=p.source_id
      and retired_at is null and revoked_at is null for share;
    if not found then raise exception 'inactive_installation' using errcode='42501'; end if;
    if p.ingest_token_id is not null and not exists(select 1 from public.noop_ingest_tokens
      where id=p.ingest_token_id and user_id=p.user_id and source_id=p.source_id and token_kind='installation'
        and revoked_at is null and (expires_at is null or expires_at>clock_timestamp())) then
      raise exception 'installation_token_mismatch' using errcode='42501';
    end if;
  end if;
  v:=jsonb_populate_record(null::public.object_manifests,public.noop_reserve_object_manifest_lifecycle_core(p_manifest));
  if v.auth_mode is not null and v.auth_mode<>p.auth_mode then
    raise exception 'object_owner_conflict' using errcode='42501';
  end if;
  if v.auth_mode is null or (v.ingest_token_id is null and p.ingest_token_id is not null) then
    update public.object_manifests set auth_mode=coalesce(auth_mode,p.auth_mode),
      ingest_token_id=coalesce(ingest_token_id,p.ingest_token_id) where id=v.id returning * into v;
  end if;
  return to_jsonb(v);
end $$;

-- Return the database authorization time, not a later Edge timestamp. A suspended request
-- cannot extend its signed PUT beyond the deletion freeze's maximum URL lifetime.
create function public.authorize_noop_object_put(p_user uuid,p_source uuid,p_object uuid)
returns timestamptz language plpgsql security definer set search_path='' as $$
begin
  if auth.role() is distinct from 'service_role' then raise exception 'service role required' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended('account-admission:'||p_user,0));
  perform 1 from public.noop_app_installations where user_id=p_user and source_id=p_source
    and revoked_at is null and retired_at is null for share;
  if not found or not exists(select 1 from public.object_manifests where id=p_object
    and user_id=p_user and source_id=p_source and auth_mode='installation'
    and status not in ('ready','verified','deleted','deleting','expired')) then
    raise exception 'active_owned_upload_required' using errcode='42501';
  end if;
  return clock_timestamp();
end $$;

revoke all on function public.noop_installation_immutable(), public.noop_require_active_source(),
  public.retire_noop_installation(text),public.authorize_noop_object_put(uuid,uuid,uuid),
  public.noop_reserve_object_manifest(jsonb) from public,anon,authenticated;
grant execute on function public.retire_noop_installation(text),public.authorize_noop_object_put(uuid,uuid,uuid),
  public.noop_reserve_object_manifest(jsonb) to service_role;
commit;
