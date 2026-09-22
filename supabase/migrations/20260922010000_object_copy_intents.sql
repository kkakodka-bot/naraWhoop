-- Reserve every immutable copy before touching object storage. Existing receipts keep their keys.
create table public.noop_object_copy_intents (
  id uuid primary key default gen_random_uuid(),
  -- An already-issued COPY can finish after account deletion. Keep the minimal cleanup
  -- owner even when its manifest/account are gone; detached attempts cannot publish.
  object_id uuid references public.object_manifests(id) on delete set null,
  user_id uuid references auth.users(id) on delete set null,
  upload_key text not null,
  verified_key text not null unique,
  compressed_bytes bigint not null check (compressed_bytes > 0 and compressed_bytes <= 268435456),
  state text not null default 'copying' check (state in ('copying','published','abandoned','deleting','swept')),
  lease_token uuid not null default gen_random_uuid(),
  lease_until timestamptz not null default (now() + interval '10 minutes'),
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  verification_ms integer check (verification_ms >= 0),
  failure_code text,
  sweep_token uuid,
  sweep_lease_until timestamptz,
  sweep_attempts integer not null default 0,
  next_sweep_at timestamptz not null default (now() + interval '24 hours'),
  last_swept_at timestamptz
);
create index noop_copy_intent_object on public.noop_object_copy_intents(object_id,created_at);
create index noop_copy_intent_sweep on public.noop_object_copy_intents(next_sweep_at,id)
  where state <> 'published';
alter table public.noop_object_copy_intents enable row level security;
revoke all on public.noop_object_copy_intents from public,anon,authenticated;
grant all on public.noop_object_copy_intents to service_role;
create policy noop_copy_intent_service on public.noop_object_copy_intents
  for all to service_role using (true) with check (true);

create function public.noop_copy_parent_detached() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if new.object_id is null or new.user_id is null then
    new.state := 'abandoned';
    new.lease_until := now();
    new.next_sweep_at := greatest(new.next_sweep_at,now()+interval '24 hours');
  end if;
  return new;
end;
$$;
create trigger noop_copy_parent_detached before update of object_id,user_id
  on public.noop_object_copy_intents for each row execute function public.noop_copy_parent_detached();
revoke all on function public.noop_copy_parent_detached() from public,anon,authenticated;

create function public.noop_reserve_copy_intent(p_user_id uuid,p_object_id uuid)
returns jsonb language plpgsql security definer set search_path = pg_catalog,public as $$
declare m public.object_manifests; i public.noop_object_copy_intents; k text; attempt uuid := gen_random_uuid();
begin
  select * into m from public.object_manifests where id=p_object_id for update;
  if not found or m.user_id is distinct from p_user_id or not exists
    (select 1 from public.devices where id=m.device_id and user_id=p_user_id) then
    raise exception 'object_owner_conflict' using errcode='42501';
  end if;
  if m.status in ('deleted','deleting','expired') then raise exception 'object_unavailable'; end if;
  -- A completion that raced reservation uses the already-published immutable receipt.
  if m.durability_receipt is not null then return jsonb_build_object('receipt',m.durability_receipt); end if;
  if (select count(*) from public.noop_object_copy_intents where object_id=m.id
      and state not in ('published','swept')) >= 64 then
    raise exception 'copy_attempt_limit';
  end if;
  k := coalesce(m.upload_object_key,m.object_key);
  if k like '%/verified/%' or k not like ('%/users/'||m.user_id::text||'/%') then
    raise exception 'object_verification_mismatch';
  end if;
  insert into public.noop_object_copy_intents(id,object_id,user_id,upload_key,verified_key,compressed_bytes)
    values(attempt,m.id,m.user_id,k,
      regexp_replace(k,'/[^/]+$','')||'/verified/'||m.id::text||'/'||attempt::text||'/'||regexp_replace(k,'^.*/',''),
      m.compressed_bytes) returning * into i;
  return to_jsonb(i);
end;
$$;

create function public.noop_commit_copy_receipt(
  p_intent_id uuid,p_lease_token uuid,p_wire_sha256 text,p_content_sha256 text,
  p_compressed_bytes bigint,p_uncompressed_bytes bigint,p_verification_ms integer,
  p_validation jsonb default null
) returns jsonb language plpgsql security definer set search_path = pg_catalog,public as $$
declare i public.noop_object_copy_intents; receipt jsonb; started timestamptz := clock_timestamp();
begin
  select * into i from public.noop_object_copy_intents where id=p_intent_id for update;
  if not found or i.lease_token is distinct from p_lease_token then raise exception 'copy_lease_lost'; end if;
  if i.object_id is null or i.user_id is null then raise exception 'object_unavailable'; end if;
  -- Lost responses are idempotent, but a retired attempt can never republish a swept key.
  if i.state='published' then
    select durability_receipt into receipt from public.object_manifests
      where id=i.object_id and user_id=i.user_id and object_key=i.verified_key;
    if receipt is not null and receipt->>'wireSha256'=p_wire_sha256
      and receipt->>'contentSha256'=p_content_sha256
      and (receipt->>'compressedBytes')::bigint=p_compressed_bytes
      and (receipt->>'uncompressedBytes')::bigint=p_uncompressed_bytes then return receipt; end if;
    raise exception 'receipt_immutable';
  end if;
  if i.state <> 'copying' or i.lease_until <= now() then raise exception 'copy_lease_lost'; end if;
  if p_validation is null then
    receipt := public.noop_commit_object_receipt(i.user_id,i.object_id,i.verified_key,
      p_wire_sha256,p_content_sha256,p_compressed_bytes,p_uncompressed_bytes);
  else
    receipt := public.noop_commit_aux_object_receipt(i.user_id,i.object_id,i.verified_key,
      p_wire_sha256,p_content_sha256,p_compressed_bytes,p_uncompressed_bytes,p_validation);
  end if;
  update public.noop_object_copy_intents set
    state=case when receipt->>'objectKey'=i.verified_key then 'published' else 'abandoned' end,
    completed_at=now(),verification_ms=greatest(0,p_verification_ms)+
      greatest(0,floor(extract(epoch from clock_timestamp()-started)*1000))::integer,lease_until=now()
    where id=i.id;
  return receipt;
end;
$$;

create function public.noop_abandon_copy_intent(p_intent_id uuid,p_lease_token uuid,p_failure_code text)
returns void language plpgsql security definer set search_path = pg_catalog,public as $$
begin
  update public.noop_object_copy_intents set state='abandoned',lease_until=now(),
    completed_at=now(),failure_code=case when p_failure_code in
      ('copy_failed','verification_failed','receipt_failed') then p_failure_code else 'receipt_failed' end
    where id=p_intent_id and lease_token=p_lease_token and state='copying';
end;
$$;

create function public.noop_claim_copy_orphans(p_limit integer default 16,p_max_bytes bigint default 536870912)
returns jsonb language plpgsql security definer set search_path = pg_catalog,public as $$
declare i public.noop_object_copy_intents; m public.object_manifests; token uuid;
  claimed jsonb := '[]'::jsonb; used bigint := 0; count integer := 0;
begin
  -- Lock attempts before manifests, matching receipt publication. Expired leases alone are
  -- insufficient: retain every key for 24h and re-check both the manifest and exact receipt.
  for i in select * from public.noop_object_copy_intents
    where state <> 'published' and next_sweep_at <= now()
      and created_at <= now()-interval '24 hours' and lease_until < now()
      and (sweep_lease_until is null or sweep_lease_until < now())
    order by next_sweep_at,id limit greatest(1,least(p_limit,64)) for update skip locked
  loop
    select * into m from public.object_manifests where id=i.object_id for update;
    if m.object_key=i.verified_key or m.durability_receipt->>'objectKey'=i.verified_key then
      update public.noop_object_copy_intents set state='published' where id=i.id;
      continue;
    end if;
    if used+i.compressed_bytes > greatest(0,least(p_max_bytes,1073741824)) then continue; end if;
    token := gen_random_uuid();
    update public.noop_object_copy_intents set state='deleting',sweep_token=token,
      sweep_lease_until=now()+interval '5 minutes',sweep_attempts=sweep_attempts+1 where id=i.id;
    claimed := claimed||jsonb_build_array(jsonb_build_object('id',i.id,'key',i.verified_key,
      'bytes',i.compressed_bytes,'token',token));
    used := used+i.compressed_bytes; count := count+1;
  end loop;
  return claimed;
end;
$$;

create function public.noop_finish_copy_sweep(p_intent_id uuid,p_sweep_token uuid,p_succeeded boolean)
returns boolean language plpgsql security definer set search_path = pg_catalog,public as $$
declare changed integer;
begin
  update public.noop_object_copy_intents set
    state=case when p_succeeded then 'swept' else 'abandoned' end,
    last_swept_at=case when p_succeeded then now() else last_swept_at end,
    next_sweep_at=now()+case when p_succeeded then interval '24 hours' else interval '1 hour' end,
    sweep_token=null,sweep_lease_until=null
    where id=p_intent_id and state='deleting' and sweep_token=p_sweep_token;
  get diagnostics changed=row_count;
  -- Keep tombstones and periodically recheck them: a very late external COPY is still tracked.
  return changed=1;
end;
$$;

create view public.noop_copy_intake_metrics as select
  (select count(*) from public.object_manifests where object_class='raw' and durability_receipt is null
    and status not in ('deleted','deleting','expired')) as intake_debt_count,
  (select coalesce(max(extract(epoch from now()-created_at)),0) from public.object_manifests
    where object_class='raw' and durability_receipt is null and status not in ('deleted','deleting','expired')) as oldest_intake_debt_seconds,
  count(*) filter(where state='copying' and lease_until>now()) as active_copy_count,
  count(*) filter(where state in ('abandoned','deleting') or (state='copying' and lease_until<=now())) as orphan_candidate_count,
  coalesce(sum(compressed_bytes) filter(where state in ('abandoned','deleting') or (state='copying' and lease_until<=now())),0) as orphan_candidate_bytes,
  coalesce(sum(sweep_attempts),0) as sweep_attempt_count,
  count(*) filter(where failure_code is not null) as failed_copy_attempt_count,
  percentile_cont(0.99) within group(order by verification_ms) filter(where state='published') as verification_index_p99_ms,
  percentile_cont(0.99) within group(order by extract(epoch from completed_at-created_at)*1000)
    filter(where state='published') as copy_to_receipt_p99_ms
  from public.noop_object_copy_intents;
revoke all on public.noop_copy_intake_metrics from public,anon,authenticated;
grant select on public.noop_copy_intake_metrics to service_role;

revoke all on function public.noop_reserve_copy_intent(uuid,uuid) from public,anon,authenticated;
revoke all on function public.noop_commit_copy_receipt(uuid,uuid,text,text,bigint,bigint,integer,jsonb) from public,anon,authenticated;
revoke all on function public.noop_abandon_copy_intent(uuid,uuid,text) from public,anon,authenticated;
revoke all on function public.noop_claim_copy_orphans(integer,bigint) from public,anon,authenticated;
revoke all on function public.noop_finish_copy_sweep(uuid,uuid,boolean) from public,anon,authenticated;
grant execute on function public.noop_reserve_copy_intent(uuid,uuid) to service_role;
grant execute on function public.noop_commit_copy_receipt(uuid,uuid,text,text,bigint,bigint,integer,jsonb) to service_role;
grant execute on function public.noop_abandon_copy_intent(uuid,uuid,text) to service_role;
grant execute on function public.noop_claim_copy_orphans(integer,bigint) to service_role;
grant execute on function public.noop_finish_copy_sweep(uuid,uuid,boolean) to service_role;
