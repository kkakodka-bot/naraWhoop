-- Additive canary admission. Existing ingestion and global workers retain their contracts.
begin;
set local lock_timeout='5s';
set local statement_timeout='60s';

create function public.noop_intake_canary_validate(p_user uuid,p_device uuid) returns void
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  -- JDBC uses the existing postgres login; REST requires the service role. Checking
  -- current_user here would incorrectly authorize every SECURITY DEFINER caller.
  if auth.role() is distinct from 'service_role' and session_user<>'postgres' then
    raise exception 'intake_admission_scope_mismatch' using errcode='42501';
  end if;
  if p_user is null or p_device is null then
    raise exception 'intake_admission_scope_mismatch' using errcode='42501';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('account-admission:'||p_user::text,0));
  perform 1 from public.devices d where d.id=p_device and d.user_id=p_user and d.is_active is true
    and exists(select 1 from auth.users u where u.id=p_user)
    and not exists(select 1 from public.noop_account_retirements r where r.user_id=p_user)
    for share of d;
  if not found then raise exception 'intake_admission_scope_mismatch' using errcode='42501'; end if;
end $$;

-- Every scoped lane has independent cursor/rotation state. It cannot advance the
-- global cursor, claim a sibling device, or consume another owner's scheduler turn.
create table public.noop_intake_canary_state (
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null references public.devices(id) on delete cascade,
  legacy_cursor uuid, projection_cursor uuid,
  verification_lane text check(verification_lane in ('live','history')),
  projection_lane text check(projection_lane in ('live','history')),
  updated_at timestamptz not null default now(), primary key(user_id,device_id)
);
alter table public.noop_intake_canary_state enable row level security;
revoke all on public.noop_intake_canary_state from public,anon,authenticated,service_role;
create index noop_canary_manifest_scope on public.object_manifests(user_id,device_id,id);
create index noop_canary_projection_scope on public.noop_projection_debt(user_id,device_id,created_at,object_id)
  where state in ('pending','staged');
create index noop_canary_scoring_scope on public.scoring_work_items(user_id,device_id,dirty_at) where done_at is null;
create index noop_canary_publication_scope on public.physiology_archive_outbox(user_id,device_id,algorithm_version,id desc);
create index noop_canary_legacy_scope on public.object_manifests(user_id,device_id,created_at,id)
  where object_class='raw' and status not in ('deleted','deleting','expired') and sha256 is not null;

create function public.noop_intake_reconcile_page_scoped(p_user_id uuid,p_device_id uuid,p_limit integer default 16)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_cursor uuid; v_rows jsonb; v_last uuid;
begin
  perform public.noop_intake_canary_validate(p_user_id,p_device_id);
  insert into public.noop_intake_canary_state(user_id,device_id) values(p_user_id,p_device_id) on conflict do nothing;
  select legacy_cursor into v_cursor from public.noop_intake_canary_state
    where user_id=p_user_id and device_id=p_device_id for update;
  select jsonb_agg(to_jsonb(x) order by x.id),max(x.id::text)::uuid into v_rows,v_last from (
    select * from public.object_manifests m where m.user_id=p_user_id and m.device_id=p_device_id and object_class='raw'
      and status not in ('deleted','deleting','expired') and sha256 is not null
      and not exists(select 1 from public.noop_object_verification_debt v where v.object_id=m.id)
      and (durability_receipt is null or indexed_at is null or status not in ('ready','verified')
        or sha256_source is distinct from 'server_verified' or verified_at is null
        or not exists(select 1 from public.noop_signal_windows w where w.object_id=m.id and w.user_id=m.user_id
          and w.device_id=m.device_id and w.object_key=m.object_key))
      and (v_cursor is null or id>v_cursor) order by id limit greatest(1,least(p_limit,64))
  ) x;
  update public.noop_intake_canary_state set legacy_cursor=v_last,updated_at=now()
    where user_id=p_user_id and device_id=p_device_id;
  return coalesce(v_rows,'[]'::jsonb);
end $$;

create function public.noop_seed_projection_debt_scoped(p_user_id uuid,p_device_id uuid,p_limit integer default 16)
returns integer language plpgsql security definer set search_path=pg_catalog,public as $$
declare c uuid; m public.object_manifests; n integer:=0; last_id uuid;
begin
  perform public.noop_intake_canary_validate(p_user_id,p_device_id);
  insert into public.noop_intake_canary_state(user_id,device_id) values(p_user_id,p_device_id) on conflict do nothing;
  select projection_cursor into c from public.noop_intake_canary_state
    where user_id=p_user_id and device_id=p_device_id for update;
  for m in select * from public.object_manifests where user_id=p_user_id and device_id=p_device_id
    and format like 'ndjson%' and durability_receipt->>'state'='verified_indexed' and status in ('ready','verified')
    and (c is null or id>c) order by id limit greatest(1,least(p_limit,64)) loop
    insert into public.noop_projection_debt(object_id,user_id,device_id,created_at,state,completed_at)
      values(m.id,m.user_id,m.device_id,m.created_at,
        case when exists(select 1 from public.noop_push_acks a where a.user_id=m.user_id and a.batch_id=m.batch_id)
          and not exists(select 1 from public.noop_push_staging_parts s where s.user_id=m.user_id and s.batch_id=m.batch_id::text)
          then 'complete' else 'pending' end,
        case when exists(select 1 from public.noop_push_acks a where a.user_id=m.user_id and a.batch_id=m.batch_id)
          and not exists(select 1 from public.noop_push_staging_parts s where s.user_id=m.user_id and s.batch_id=m.batch_id::text)
          then clock_timestamp() else null end)
      on conflict(object_id) do nothing;
    n:=n+1; last_id:=m.id;
  end loop;
  update public.noop_intake_canary_state set projection_cursor=last_id,updated_at=now()
    where user_id=p_user_id and device_id=p_device_id;
  return n;
end $$;

create function public.noop_claim_object_verification_scoped(p_user_id uuid,p_device_id uuid,
  p_max_bytes bigint default 268435456,p_max_decoded_bytes bigint default 536870912)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare d public.noop_object_verification_debt; m public.object_manifests; token uuid:=gen_random_uuid(); previous_lane text;
begin
  perform public.noop_intake_canary_validate(p_user_id,p_device_id);
  insert into public.noop_intake_canary_state(user_id,device_id) values(p_user_id,p_device_id) on conflict do nothing;
  select verification_lane into previous_lane from public.noop_intake_canary_state
    where user_id=p_user_id and device_id=p_device_id for update;
  select v.* into d from public.noop_object_verification_debt v join public.object_manifests o on o.id=v.object_id
    where v.user_id=p_user_id and o.user_id=p_user_id and o.device_id=p_device_id and v.state in ('pending','retry','leased')
      and v.next_attempt_at<=now() and (v.state<>'leased' or v.lease_until<=now())
      and o.status not in ('deleted','deleting','expired') and o.compressed_bytes>0
      and o.compressed_bytes<=least(greatest(p_max_bytes,0),268435456)
      and coalesce(o.uncompressed_bytes,536870912)<=least(greatest(p_max_decoded_bytes,0),536870912)
      and not exists(select 1 from public.noop_object_copy_intents c where c.object_id=o.id and c.state='copying' and c.lease_until>now())
    order by case when (o.end_at>now()-interval '10 minutes')=(previous_lane is distinct from 'live') then 0 else 1 end,
      v.next_attempt_at,v.requested_at,v.object_id for update of v skip locked limit 1;
  if d.object_id is null then return null; end if;
  select * into strict m from public.object_manifests where id=d.object_id and user_id=p_user_id and device_id=p_device_id;
  update public.noop_intake_canary_state set updated_at=clock_timestamp(),
    verification_lane=case when m.end_at>now()-interval '10 minutes' then 'live' else 'history' end
    where user_id=p_user_id and device_id=p_device_id;
  update public.noop_object_verification_debt set state='leased',lease_token=token,
    lease_until=now()+interval '10 minutes',attempts=attempts+1,
    retry_attempts=retry_attempts+case when d.state='retry' then 1 else 0 end,
    lease_recoveries=lease_recoveries+case when d.state='leased' then 1 else 0 end,
    updated_at=now() where object_id=d.object_id;
  return jsonb_build_object('objectId',d.object_id,'token',token,'manifest',to_jsonb(m));
end $$;

create function public.noop_claim_projection_debt_scoped(p_user_id uuid,p_device_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare d public.noop_projection_debt; m public.object_manifests; previous_lane text;
begin
  perform public.noop_intake_canary_validate(p_user_id,p_device_id);
  insert into public.noop_intake_canary_state(user_id,device_id) values(p_user_id,p_device_id) on conflict do nothing;
  select projection_lane into previous_lane from public.noop_intake_canary_state
    where user_id=p_user_id and device_id=p_device_id for update;
  select q.* into d from public.noop_projection_debt q join public.object_manifests o on o.id=q.object_id
    where q.user_id=p_user_id and q.device_id=p_device_id and o.user_id=p_user_id and o.device_id=p_device_id
      and q.state='pending' and q.not_before<=now() and (q.lease_until is null or q.lease_until<=now())
      and o.status in ('ready','verified') and o.durability_receipt->>'state'='verified_indexed'
    order by case when (o.end_at>now()-interval '10 minutes')=(previous_lane is distinct from 'live') then 0 else 1 end,
      q.not_before,q.created_at,q.object_id for update of q skip locked limit 1;
  if d.object_id is null then return null; end if;
  update public.noop_projection_debt set lease_token=gen_random_uuid(),lease_until=now()+interval '2 minutes'
    where object_id=d.object_id returning * into d;
  select * into strict m from public.object_manifests where id=d.object_id and user_id=p_user_id and device_id=p_device_id;
  update public.noop_intake_canary_state set updated_at=clock_timestamp(),
    projection_lane=case when m.end_at>now()-interval '10 minutes' then 'live' else 'history' end
    where user_id=p_user_id and device_id=p_device_id;
  return jsonb_build_object('manifest',to_jsonb(m),'leaseToken',d.lease_token);
end $$;

create function public.scoring_canary_claim_one(p_lease_seconds integer,p_max_failures integer,
  p_user uuid,p_device uuid,p_day date) returns setof public.scoring_work_items
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  perform public.noop_intake_canary_validate(p_user,p_device);
  return query select * from public.scoring_legacy_claim_one(p_lease_seconds,p_max_failures,p_user,p_device,p_day);
end $$;

create function public.scoring_canary_enqueue_legacy(p_user uuid,p_device uuid,p_day date,p_timezone text,p_debounce_seconds integer)
returns bigint language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  perform public.noop_intake_canary_validate(p_user,p_device);
  return public.scoring_enqueue_legacy_fenced(p_user,p_device,p_day,p_timezone,p_debounce_seconds);
end $$;

-- Claims do not authorize publication after a lifecycle change during object I/O.
-- These wrappers retain the original byte/schema/lease checks in the same transaction.
create function public.noop_intake_canary_commit_receipt(p_user uuid,p_device uuid,p_object uuid,
  p_intent uuid,p_lease uuid,p_verified_key text,p_wire_sha256 text,p_content_sha256 text,
  p_compressed_bytes bigint,p_uncompressed_bytes bigint,p_verification_ms integer,p_validation jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  perform public.noop_intake_canary_validate(p_user,p_device);
  -- Preserve the existing copy receipt lock order: intent, then manifest.
  if p_intent is not null then
    perform 1 from public.noop_object_copy_intents where id=p_intent and object_id=p_object
      and user_id=p_user and verified_key=p_verified_key for update;
    if not found then raise exception 'intake_admission_scope_mismatch' using errcode='42501'; end if;
  elsif p_lease is not null then
    raise exception 'intake_admission_scope_mismatch' using errcode='42501';
  end if;
  perform 1 from public.object_manifests where id=p_object and user_id=p_user and device_id=p_device for update;
  if not found then raise exception 'intake_admission_scope_mismatch' using errcode='42501'; end if;
  if p_intent is not null then
    return public.noop_commit_copy_receipt(p_intent,p_lease,p_wire_sha256,p_content_sha256,
      p_compressed_bytes,p_uncompressed_bytes,p_verification_ms,p_validation);
  elsif p_validation is not null then
    return public.noop_commit_aux_object_receipt(p_user,p_object,p_verified_key,p_wire_sha256,p_content_sha256,
      p_compressed_bytes,p_uncompressed_bytes,p_validation);
  else
    return public.noop_commit_object_receipt(p_user,p_object,p_verified_key,p_wire_sha256,p_content_sha256,
      p_compressed_bytes,p_uncompressed_bytes);
  end if;
end $$;

create function public.noop_intake_canary_commit_projection(p_user uuid,p_device uuid,p_object_id uuid,
  p_body_sha256 text,p_header jsonb,p_rows jsonb,p_keep_keys jsonb,p_token uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  perform public.noop_intake_canary_validate(p_user,p_device);
  perform 1 from public.object_manifests where id=p_object_id and user_id=p_user and device_id=p_device for update;
  if not found then raise exception 'intake_admission_scope_mismatch' using errcode='42501'; end if;
  return public.noop_commit_push_projection(p_object_id,p_body_sha256,p_header,p_rows,p_keep_keys,p_token);
end $$;

create function public.engine_publish_canary_legacy_fenced(p_secret text,p_payload jsonb,p_user uuid,p_device uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  perform public.noop_intake_canary_validate(p_user,p_device);
  if p_payload->>'user_id' is distinct from p_user::text or p_payload->>'device_id' is distinct from p_device::text then
    raise exception 'intake_admission_scope_mismatch' using errcode='42501';
  end if;
  return public.engine_publish_legacy_fenced(p_secret,p_payload);
end $$;

alter table public.noop_intake_consumers drop constraint noop_intake_consumers_contract_version_check;
alter table public.noop_intake_consumers add constraint noop_intake_consumers_contract_version_check check(contract_version in (1,2));
alter table public.noop_intake_consumers add column admission_mode text;
alter table public.noop_intake_consumers add column user_id uuid;
alter table public.noop_intake_consumers add column device_id uuid;
alter table public.noop_intake_consumers add constraint noop_intake_consumer_admission check (
  (contract_version=1 and admission_mode is null and user_id is null and device_id is null) or
  (contract_version=2 and admission_mode is not null and
    ((admission_mode='all-eligible' and user_id is null and device_id is null) or
     (admission_mode='canary' and user_id is not null and device_id is not null))));
create index noop_canary_consumer_identity on public.noop_intake_consumers(user_id,device_id,source_revision,instance_id,lane,last_successful_poll_at desc)
  where contract_version=2 and admission_mode='canary';
create function public.noop_intake_consumer_poll_v2(p_process uuid,p_instance uuid,p_source_revision text,
  p_lane text,p_claimed integer,p_completed integer,p_failures integer,
  p_admission_mode text,p_user_id uuid,p_device_id uuid) returns void
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if auth.role() is distinct from 'service_role' or p_process is null or p_instance is null
    or coalesce(p_source_revision,'')!~'^[0-9a-f]{40}$' or p_lane is null or p_lane not in ('verification','projection','legacy')
    or p_claimed is null or p_completed is null or p_failures is null
    or p_claimed not between 0 and 64 or p_completed not between 0 and p_claimed
    or p_failures not between 0 and p_claimed or p_completed+p_failures>p_claimed
    or p_admission_mode is null or p_admission_mode not in ('canary','all-eligible')
    or (p_admission_mode='all-eligible' and (p_user_id is not null or p_device_id is not null)) then
    raise exception 'invalid_consumer_poll';
  end if;
  if p_admission_mode='canary' then perform public.noop_intake_canary_validate(p_user_id,p_device_id); end if;
  insert into public.noop_intake_consumers(process_id,instance_id,source_revision,contract_version,lane,
    last_successful_poll_at,claimed,completed,failures,last_poll_failed,admission_mode,user_id,device_id)
    values(p_process,p_instance,p_source_revision,2,p_lane,clock_timestamp(),p_claimed,p_completed,p_failures,p_failures>0,
      p_admission_mode,p_user_id,p_device_id)
  on conflict(process_id,lane) do update set last_successful_poll_at=excluded.last_successful_poll_at,
    polls=noop_intake_consumers.polls+1,claimed=noop_intake_consumers.claimed+excluded.claimed,
    completed=noop_intake_consumers.completed+excluded.completed,failures=noop_intake_consumers.failures+excluded.failures,
    last_poll_failed=excluded.last_poll_failed
  where noop_intake_consumers.instance_id=excluded.instance_id and noop_intake_consumers.source_revision=excluded.source_revision
    and noop_intake_consumers.contract_version=2 and noop_intake_consumers.admission_mode=excluded.admission_mode
    and noop_intake_consumers.user_id is not distinct from excluded.user_id
    and noop_intake_consumers.device_id is not distinct from excluded.device_id;
  if not found then raise exception 'consumer_identity_changed'; end if;
  insert into public.noop_intake_service_minutes(bucket,lane,polls,claimed,completed,failures)
    values(date_trunc('minute',clock_timestamp()),p_lane,1,p_claimed,p_completed,p_failures)
  on conflict(bucket,lane) do update set polls=noop_intake_service_minutes.polls+1,
    claimed=noop_intake_service_minutes.claimed+excluded.claimed,
    completed=noop_intake_service_minutes.completed+excluded.completed,failures=noop_intake_service_minutes.failures+excluded.failures;
  delete from public.noop_intake_service_minutes where bucket<now()-interval '1 day';
  delete from public.noop_intake_consumers where (process_id,lane) in (
    select process_id,lane from public.noop_intake_consumers where last_successful_poll_at<now()-interval '1 day'
      order by last_successful_poll_at limit 128);
end $$;

-- A legacy poll cannot refresh the liveness record of an already bound v2 process.
create or replace function public.noop_intake_consumer_poll(p_process uuid,p_instance uuid,p_source_revision text,
  p_lane text,p_claimed integer,p_completed integer,p_failures integer) returns void
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if auth.role() is distinct from 'service_role' or p_process is null or p_instance is null
    or coalesce(p_source_revision,'')!~'^[0-9a-f]{40}$' or p_lane is null or p_lane not in ('verification','projection','legacy')
    or p_claimed is null or p_completed is null or p_failures is null
    or p_claimed not between 0 and 64 or p_completed not between 0 and p_claimed
    or p_failures not between 0 and p_claimed or p_completed+p_failures>p_claimed then raise exception 'invalid_consumer_poll'; end if;
  insert into public.noop_intake_consumers(process_id,instance_id,source_revision,contract_version,lane,
    last_successful_poll_at,claimed,completed,failures,last_poll_failed)
    values(p_process,p_instance,p_source_revision,1,p_lane,clock_timestamp(),p_claimed,p_completed,p_failures,p_failures>0)
  on conflict(process_id,lane) do update set last_successful_poll_at=excluded.last_successful_poll_at,
    polls=noop_intake_consumers.polls+1,claimed=noop_intake_consumers.claimed+excluded.claimed,
    completed=noop_intake_consumers.completed+excluded.completed,failures=noop_intake_consumers.failures+excluded.failures,
    last_poll_failed=excluded.last_poll_failed
  where noop_intake_consumers.contract_version=1 and noop_intake_consumers.admission_mode is null
    and noop_intake_consumers.instance_id=excluded.instance_id and noop_intake_consumers.source_revision=excluded.source_revision;
  if not found then raise exception 'consumer_identity_changed'; end if;
  insert into public.noop_intake_service_minutes(bucket,lane,polls,claimed,completed,failures)
    values(date_trunc('minute',clock_timestamp()),p_lane,1,p_claimed,p_completed,p_failures)
  on conflict(bucket,lane) do update set polls=noop_intake_service_minutes.polls+1,
    claimed=noop_intake_service_minutes.claimed+excluded.claimed,
    completed=noop_intake_service_minutes.completed+excluded.completed,
    failures=noop_intake_service_minutes.failures+excluded.failures;
  delete from public.noop_intake_service_minutes where bucket<now()-interval '1 day';
  delete from public.noop_intake_consumers where (process_id,lane) in (
    select process_id,lane from public.noop_intake_consumers
      where last_successful_poll_at<now()-interval '1 day' order by last_successful_poll_at limit 128);

end $$;

create or replace function public.noop_intake_consumer_contract() returns jsonb
language sql stable security definer set search_path=pg_catalog,public as $$
  select jsonb_build_object('contract_version',2,'completion','verified_indexed',
    'projection','atomic_lifecycle_v1','lanes',jsonb_build_array('verification','projection','legacy'),
    'admission_modes',jsonb_build_array('canary','all-eligible'))
$$;
-- A one-device canary cannot service newly accepted async debt for other devices.
-- Version-one polls also cannot establish compatibility with the new contract.
create or replace function public.noop_async_verification_ready() returns boolean
language sql stable security definer set search_path=pg_catalog,public as $$
  select exists(select 1 from public.noop_intake_consumers where contract_version=2
    and admission_mode='all-eligible' and user_id is null and device_id is null
    and lane='verification' and not last_poll_failed and last_successful_poll_at>now()-interval '30 seconds' and polls>=1)
$$;

-- Scope is validated before any observation. Counts are bounded lower bounds,
-- and timestamps/counters carry no physiological values, paths or owner IDs.
create function public.noop_intake_canary_status(p_user uuid,p_device uuid,p_source_revision text,p_instance uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare result jsonb;
begin
  perform public.noop_intake_canary_validate(p_user,p_device);
  if coalesce(p_source_revision,'')!~'^[0-9a-f]{40}$' or p_instance is null then raise exception 'invalid_consumer_identity'; end if;
  with verification as (
    select d.requested_at as created_at from public.noop_object_verification_debt d
      join public.object_manifests m on m.id=d.object_id
      where d.user_id=p_user and m.user_id=p_user and m.device_id=p_device and d.state in ('pending','retry','leased')
      order by d.requested_at,d.object_id limit 1001
  ), projection as (
    select created_at from public.noop_projection_debt where user_id=p_user and device_id=p_device
      and state in ('pending','staged') order by created_at,object_id limit 1001
  ), legacy as (
    select m.created_at from public.object_manifests m
      where m.user_id=p_user and m.device_id=p_device and m.object_class='raw'
        and m.status not in ('deleted','deleting','expired') and m.sha256 is not null
        and not exists(select 1 from public.noop_object_verification_debt v where v.object_id=m.id)
        and (m.durability_receipt is null or m.indexed_at is null or m.status not in ('ready','verified')
          or m.sha256_source is distinct from 'server_verified' or m.verified_at is null
          or not exists(select 1 from public.noop_signal_windows w where w.object_id=m.id and w.user_id=m.user_id
            and w.device_id=m.device_id and w.object_key=m.object_key))
      order by m.created_at,m.id limit 1001
  ), scoring as (
    select dirty_at as created_at from public.scoring_work_items where user_id=p_user and device_id=p_device
      and done_at is null order by dirty_at limit 1001
  ), lanes as (
    select distinct on (lane) lane,last_successful_poll_at,polls,claimed,completed,failures,last_poll_failed
      from public.noop_intake_consumers where contract_version=2 and admission_mode='canary'
      and user_id=p_user and device_id=p_device and source_revision=p_source_revision and instance_id=p_instance
      order by lane,last_successful_poll_at desc
  ) select jsonb_build_object('captured_at',clock_timestamp(),'contract_version',2,'admission_mode','canary',
    'owner_cap',1,'device_cap',1,'source_revision',p_source_revision,'instance_id',p_instance,
    'capacity_acceptance','NOT_MEASURED','queue_sample_limit',1000,
    'database',jsonb_build_object('connections',(select count(*) from pg_stat_activity),
      'max_connections',current_setting('max_connections')::integer,
      'reserved_connections',current_setting('superuser_reserved_connections')::integer +
        coalesce(nullif(current_setting('reserved_connections',true),'')::integer,0)),
    'lanes',coalesce((select jsonb_agg(to_jsonb(lanes) order by lane) from lanes),'[]'::jsonb),
    'verification',jsonb_build_object('pending_at_least',(select least(count(*),1000) from verification),
      'truncated',(select count(*)>1000 from verification),'oldest_age_seconds',(select extract(epoch from now()-min(created_at)) from verification)),
    'projection',jsonb_build_object('pending_at_least',(select least(count(*),1000) from projection),
      'truncated',(select count(*)>1000 from projection),'oldest_age_seconds',(select extract(epoch from now()-min(created_at)) from projection)),
    'legacy',jsonb_build_object('pending_at_least',(select least(count(*),1000) from legacy),
      'truncated',(select count(*)>1000 from legacy),'oldest_age_seconds',(select extract(epoch from now()-min(created_at)) from legacy)),
    'scoring',jsonb_build_object('pending_at_least',(select least(count(*),1000) from scoring),
      'truncated',(select count(*)>1000 from scoring),'oldest_age_seconds',(select extract(epoch from now()-min(created_at)) from scoring)),
    'latest_publication_marker',(select id::text from public.physiology_archive_outbox
      where user_id=p_user and device_id=p_device and algorithm_version='frwhoop-server-1' order by id desc limit 1)) into result;
  return result;
end $$;

revoke all on function public.noop_intake_canary_validate(uuid,uuid),
  public.noop_intake_reconcile_page_scoped(uuid,uuid,integer),public.noop_seed_projection_debt_scoped(uuid,uuid,integer),
  public.noop_claim_object_verification_scoped(uuid,uuid,bigint,bigint),public.noop_claim_projection_debt_scoped(uuid,uuid),
  public.scoring_canary_claim_one(integer,integer,uuid,uuid,date),
  public.scoring_canary_enqueue_legacy(uuid,uuid,date,text,integer),
  public.noop_intake_canary_commit_receipt(uuid,uuid,uuid,uuid,uuid,text,text,text,bigint,bigint,integer,jsonb),
  public.noop_intake_canary_commit_projection(uuid,uuid,uuid,text,jsonb,jsonb,jsonb,uuid),
  public.engine_publish_canary_legacy_fenced(text,jsonb,uuid,uuid),
  public.noop_intake_consumer_poll_v2(uuid,uuid,text,text,integer,integer,integer,text,uuid,uuid),
  public.noop_intake_canary_status(uuid,uuid,text,uuid) from public,anon,authenticated;
grant execute on function public.noop_intake_canary_validate(uuid,uuid),
  public.noop_intake_reconcile_page_scoped(uuid,uuid,integer),public.noop_seed_projection_debt_scoped(uuid,uuid,integer),
  public.noop_claim_object_verification_scoped(uuid,uuid,bigint,bigint),public.noop_claim_projection_debt_scoped(uuid,uuid),
  public.scoring_canary_claim_one(integer,integer,uuid,uuid,date),
  public.scoring_canary_enqueue_legacy(uuid,uuid,date,text,integer),
  public.noop_intake_canary_commit_receipt(uuid,uuid,uuid,uuid,uuid,text,text,text,bigint,bigint,integer,jsonb),
  public.noop_intake_canary_commit_projection(uuid,uuid,uuid,text,jsonb,jsonb,jsonb,uuid),
  public.engine_publish_canary_legacy_fenced(text,jsonb,uuid,uuid),
  public.noop_intake_consumer_poll_v2(uuid,uuid,text,text,integer,integer,integer,text,uuid,uuid),
  public.noop_intake_canary_status(uuid,uuid,text,uuid) to service_role;
commit;
