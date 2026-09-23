-- Matched intake consumer contract. Applied histories remain unchanged; async stays opt-in.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

-- Only a successful byte verifier calls this publication function. Correct stale metadata
-- on an otherwise identical receipt without replacing its immutable identity or contents.
create or replace function public.noop_commit_object_receipt(
  p_user_id uuid, p_object_id uuid, p_verified_key text, p_wire_sha256 text,
  p_content_sha256 text, p_compressed_bytes bigint, p_uncompressed_bytes bigint
) returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v public.object_manifests; v_receipt jsonb; v_scope text;
  v_start bigint; v_end bigint; v_expected bigint; v_key text; v_index_changes integer; v_now timestamptz := now();
begin
  select * into v from public.object_manifests where id = p_object_id for update;
  if not found or v.user_id is distinct from p_user_id or not exists
    (select 1 from public.devices where id = v.device_id and user_id = p_user_id) then
    raise exception 'object_owner_conflict' using errcode = '42501';
  end if;
  v_scope := coalesce(v.digest_scope, case when v.format like 'ndjson%' then 'wire' else 'decoded' end);
  if v.object_class <> 'raw' or v.status in ('deleted','deleting','expired')
     or coalesce(p_wire_sha256,'') !~ '^[0-9a-f]{64}$'
     or coalesce(p_content_sha256,'') !~ '^[0-9a-f]{64}$'
     or p_compressed_bytes is distinct from v.compressed_bytes
     or coalesce(p_uncompressed_bytes,0) <= 0 or p_uncompressed_bytes > 536870912
     or (v.uncompressed_bytes is not null and p_uncompressed_bytes <> v.uncompressed_bytes)
     or lower(v.sha256) is distinct from
       (case when v_scope = 'wire' then p_wire_sha256 else p_content_sha256 end)
     or coalesce(p_verified_key,'') not like ('%/users/' || v.user_id::text || '/%/verified/' || v.id::text || '/%') then
    raise exception 'object_verification_mismatch' using errcode = '23514';
  end if;
  if v.durability_receipt is not null and (
       v.durability_receipt->>'wireSha256' is distinct from p_wire_sha256
       or v.durability_receipt->>'contentSha256' is distinct from p_content_sha256) then
    raise exception 'receipt_immutable' using errcode = '23514';
  end if;
  -- A concurrent identical verifier may already have published another immutable snapshot.
  v_key := coalesce(v.durability_receipt->>'objectKey',p_verified_key);
  v_start := floor(extract(epoch from v.start_at));
  v_end := greatest(v_start + 1, ceil(extract(epoch from v.end_at)));
  if v_start is null or v_end is null then
    raise exception 'object_window_missing' using errcode = '23514';
  end if;
  v_expected := case when v.object_kind in ('ppgWaveformSample','v18AuxSample','rawImuSession')
    then v_end - v_start else null end;
  insert into public.noop_signal_windows
    (user_id,device_id,stream,hour_start,object_id,object_key,start_ts,end_ts,expected_records,
     received_records,missing_records,coverage,interpolated_records,compressed_bytes,uncompressed_bytes)
  values (v.user_id,v.device_id,v.object_kind,(v_start / 3600)*3600,v.id,v_key,v_start,v_end,
    v_expected,coalesce(v.sample_count,0),case when v_expected is not null then greatest(v_expected-v.sample_count,0) end,
    case when v_expected > 0 then least(1.0,v.sample_count::double precision/v_expected) else null end,
    0,p_compressed_bytes,p_uncompressed_bytes)
  on conflict (user_id,device_id,stream,hour_start,object_id) do update set
    object_key=excluded.object_key, compressed_bytes=excluded.compressed_bytes,
    uncompressed_bytes=excluded.uncompressed_bytes, updated_at=v_now
    where public.noop_signal_windows.object_key is distinct from excluded.object_key
       or public.noop_signal_windows.compressed_bytes is distinct from excluded.compressed_bytes
       or public.noop_signal_windows.uncompressed_bytes is distinct from excluded.uncompressed_bytes;
  get diagnostics v_index_changes = row_count;
  v_receipt := coalesce(v.durability_receipt, jsonb_build_object(
    'version',1,'state','verified_indexed','receiptId',gen_random_uuid(),
    'ownerUserId',v.user_id,'deviceId',v.device_id,'objectId',v.id,
    'batchId',v.batch_id,'sourceId',v.source_id,'stream',v.object_kind,
    'schemaVersion',coalesce(v.schema_version,1),'objectKey',v_key,
    'contentSha256',p_content_sha256,'wireSha256',p_wire_sha256,
    'compressedBytes',p_compressed_bytes,'uncompressedBytes',p_uncompressed_bytes,
    'verifiedAt',v_now,'indexedAt',v_now));
  -- A legacy repair may precede the original intent retry. Fill unknown provenance once;
  -- already-bound provenance is compared by reservation and is never reassigned.
  if v_receipt->>'batchId' is null and v.batch_id is not null then
    v_receipt := v_receipt || jsonb_build_object('batchId',v.batch_id);
  end if;
  if v_receipt->>'sourceId' is null and v.source_id is not null then
    v_receipt := v_receipt || jsonb_build_object('sourceId',v.source_id);
  end if;
  update public.object_manifests set
    upload_object_key=coalesce(upload_object_key,object_key), object_key=v_key,
    wire_sha256=p_wire_sha256, sha256_source='server_verified', digest_scope=v_scope,
    status='ready', verified_at=(v_receipt->>'verifiedAt')::timestamptz, indexed_at=v_now,
    uploaded_at=coalesce(uploaded_at,v_now), durability_receipt=v_receipt, updated_at=v_now
    where id=v.id and (status <> 'ready' or object_key is distinct from v_key
      or wire_sha256 is distinct from p_wire_sha256 or durability_receipt is distinct from v_receipt
      or indexed_at is null or v_index_changes > 0
      or sha256_source is distinct from 'server_verified' or digest_scope is distinct from v_scope
      or verified_at is distinct from (v_receipt->>'verifiedAt')::timestamptz);
  -- The raw-input invalidation trigger correctly clears proof when object_key changes.
  -- Attach this verifier's byte proof only after that new immutable location is stable,
  -- under the same manifest lock/transaction. Decoder/model qualification stays cleared.
  update public.object_manifests set sha256_source='server_verified',
    verified_at=(v_receipt->>'verifiedAt')::timestamptz
    where id=v.id and (sha256_source is distinct from 'server_verified'
      or verified_at is distinct from (v_receipt->>'verifiedAt')::timestamptz);
  return v_receipt;
end;
$$;

create or replace function public.noop_intake_reconcile_page(p_limit integer default 16)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_cursor uuid; v_rows jsonb; v_last uuid;
begin
  select cursor_id into v_cursor from public.noop_intake_reconcile_state where id for update;
  select jsonb_agg(to_jsonb(x) order by x.id),max(x.id::text)::uuid into v_rows,v_last from (
    select * from public.object_manifests m where object_class='raw'
      and status not in ('deleted','deleting','expired') and sha256 is not null
      and not exists(select 1 from public.noop_object_verification_debt v where v.object_id=m.id)
      and (durability_receipt is null or indexed_at is null or status not in ('ready','verified')
        or sha256_source is distinct from 'server_verified' or verified_at is null
        or not exists(select 1 from public.noop_signal_windows w where w.object_id=m.id and w.user_id=m.user_id
          and w.device_id=m.device_id and w.object_key=m.object_key))
      and (v_cursor is null or id>v_cursor) order by id limit greatest(1,least(p_limit,64))
  ) x;
  update public.noop_intake_reconcile_state set cursor_id=v_last,updated_at=now() where id;
  return coalesce(v_rows,'[]'::jsonb);
end;
$$;

-- A gravity channel named x must not shadow the row alias during typed-identity extraction.
create or replace function public.noop_project_append_batch(p_user uuid,p_device uuid,p_source uuid,p_batch uuid,
  p_stream text,p_rows jsonb) returns integer
language plpgsql security definer set search_path='' as $$
declare target text; keys text[]; r jsonb; typed jsonb; identity jsonb; prior jsonb;
  predicate text; accepted jsonb:='[]'; old_observation jsonb; conflicted boolean;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'service role required' using errcode='42501';
  end if;
  select table_name,key_columns into target,keys from public.noop_projection_target(p_stream);
  if target is null or jsonb_typeof(p_rows) is distinct from 'array'
      or jsonb_array_length(p_rows) not between 1 and 5000 or p_batch is null then
    raise exception 'invalid append batch' using errcode='22023';
  end if;
  perform 1 from public.noop_app_installations where user_id=p_user and source_id=p_source
    and revoked_at is null and retired_at is null for share;
  if not found or not exists(select 1 from public.devices where user_id=p_user and id=p_device) then
    raise exception 'owned device and active installation required' using errcode='42501';
  end if;
  if exists(select 1 from public.noop_wearable_aliases where user_id=p_user and provisional_device_id=p_device) then
    raise exception 'device_identity_reconciled_retry' using errcode='PT409';
  end if;
  -- Shared input lock before the projection mutex; a scorer's snapshot never sees half a merge.
  if not pg_try_advisory_xact_lock_shared(hashtextextended('physiology-input:'||p_user||':'||p_device,230919)) then
    raise exception 'scoring_input_gate_busy' using errcode='55P03';
  end if;
  perform public.scoring_lock_device(p_user,p_device);
  select string_agg(format('t.%I is not distinct from x.%I',k,k),' and ') into predicate from unnest(keys) k;
  for r in select value from jsonb_array_elements(p_rows) loop
    if (r->>'user_id')::uuid is distinct from p_user or (r->>'device_id')::uuid is distinct from p_device
      or (r->>'source_id')::uuid is distinct from p_source or (r->>'batch_id')::uuid is distinct from p_batch then
      raise exception 'append row identity mismatch' using errcode='42501';
    end if;
    if exists(select 1 from jsonb_object_keys(r) k where not exists(select 1 from pg_catalog.pg_attribute a
      where a.attrelid=to_regclass('public.'||target) and a.attname=k and a.attnum>0 and not a.attisdropped)) then
      raise exception 'unknown append column' using errcode='22023';
    end if;
    execute format('select to_jsonb(x.*) from jsonb_populate_record(null::public.%I,$1) x',target) into typed using r;
    select jsonb_object_agg(k,typed->k) into identity from unnest(keys) k;
    if exists(select 1 from jsonb_each(identity) e where e.value='null') then
      raise exception 'null measurement identity' using errcode='22023';
    end if;
    select row_data into old_observation from public.noop_projection_observations
      where user_id=p_user and source_id=p_source and batch_id=p_batch and stream=p_stream and measurement_key=identity;
    if found and old_observation is distinct from r and not (
      old_observation-'device_id'=r-'device_id' and exists(select 1 from public.noop_wearable_aliases
        where user_id=p_user and provisional_device_id=(old_observation->>'device_id')::uuid
          and canonical_device_id=p_device)) then
      raise exception 'batch_id_conflict' using errcode='23505';
    end if;
    insert into public.noop_projection_observations(user_id,device_id,source_id,batch_id,stream,measurement_key,row_data)
      values(p_user,p_device,p_source,p_batch,p_stream,identity,r) on conflict do nothing;
    execute format('select to_jsonb(t.*) from public.%I t,jsonb_populate_record(null::public.%I,$1) x
      where t.user_id=$2 and t.device_id=$3 and %s',target,target,predicate) into prior using r,p_user,p_device;
    -- Compare only the supplied, typed measurement columns, never receipt metadata/default timestamps.
    conflicted := prior is not null and exists(select 1 from jsonb_object_keys(r) k
      where k<>all(array['source_id','batch_id','ingested_at']) and prior->k is distinct from typed->k
        and not (p_stream='rrPacketProvenance' and k='rawHex'
          and public.noop_same_rr_payload(prior->>'rawHex',typed->>'rawHex',typed->>'packetId')));
    if conflicted then
      insert into public.noop_projection_conflicts(user_id,device_id,stream,measurement_key)
        values(p_user,p_device,p_stream,identity) on conflict do nothing;
    end if;
    if p_stream='rrPacketProvenance' and exists(select 1 from public.noop_projection_conflicts
      where user_id=p_user and device_id=p_device and stream=p_stream and measurement_key=identity) then
      insert into public.noop_rr_clock_conflicts(user_id,device_id,ts)
        select p_user,p_device,t from unnest(array[(prior->>'ts')::bigint,(typed->>'ts')::bigint]) t
        where t is not null on conflict do nothing;
      delete from public.noop_rr_intervals where user_id=p_user and device_id=p_device
        and ts in ((prior->>'ts')::bigint,(typed->>'ts')::bigint);
    end if;
    if p_stream='rrInterval' and exists(select 1 from public.noop_rr_clock_conflicts
      where user_id=p_user and device_id=p_device and ts=(typed->>'ts')::bigint) then
      insert into public.noop_projection_conflicts(user_id,device_id,stream,measurement_key,reason)
        values(p_user,p_device,p_stream,identity,'packet_clock_or_bytes_disagreement') on conflict do nothing;
    end if;
    if exists(select 1 from public.noop_projection_conflicts where user_id=p_user and device_id=p_device
      and stream=p_stream and measurement_key=identity) then
      execute format('delete from public.%I t using jsonb_populate_record(null::public.%I,$1) x
        where t.user_id=$2 and t.device_id=$3 and %s',target,target,predicate) using r,p_user,p_device;
    elsif prior is null then
      accepted:=accepted||jsonb_build_array(r);
    end if;
  end loop;
  if jsonb_array_length(accepted)>0 then
    perform public.noop_project_append_batch_core(p_user,p_device,p_source,p_batch,p_stream,accepted);
  end if;
  return jsonb_array_length(p_rows);
end $$;

-- The lifecycle projection keeps both receptions, removes conflicting measurements and
-- fences retired sources. Run it within the archive/debt/ACK settlement transaction.
alter function public.noop_apply_projection_rows(text,jsonb) rename to noop_apply_projection_rows_intake_legacy;
revoke all on function public.noop_apply_projection_rows_intake_legacy(text,jsonb) from public,anon,authenticated,service_role;
create function public.noop_apply_projection_rows(p_stream text,p_rows jsonb) returns void
language plpgsql security definer set search_path=pg_catalog,public as $$
declare first_row jsonb; owner uuid; source uuid; device uuid; batch uuid; part record;
begin
  if jsonb_typeof(p_rows) is distinct from 'array' then raise exception 'invalid_projection'; end if;
  if jsonb_array_length(p_rows)=0 then return; end if;
  first_row:=p_rows->0;
  owner:=(first_row->>'user_id')::uuid; source:=(first_row->>'source_id')::uuid;
  device:=(first_row->>'device_id')::uuid; batch:=(first_row->>'batch_id')::uuid;
  if exists(select 1 from public.noop_projection_target(p_stream))
      and exists(select 1 from public.noop_app_installations where source_id=source) then
    for part in select jsonb_agg(value order by ord) as rows
      from jsonb_array_elements(p_rows) with ordinality as x(value,ord)
      group by (ord-1)/5000 order by (ord-1)/5000 loop
      perform public.noop_project_append_batch(owner,device,source,batch,p_stream,part.rows);
    end loop;
  else
    perform public.noop_apply_projection_rows_intake_legacy(p_stream,p_rows);
  end if;
end $$;
revoke all on function public.noop_apply_projection_rows(text,jsonb) from public,anon,authenticated;
grant execute on function public.noop_apply_projection_rows(text,jsonb) to service_role;

-- An indexed receipt, verified bytes and source authorization must agree at settlement.
alter function public.noop_commit_push_projection(uuid,text,jsonb,jsonb,jsonb,uuid)
  rename to noop_commit_push_projection_intake_core;
revoke all on function public.noop_commit_push_projection_intake_core(uuid,text,jsonb,jsonb,jsonb,uuid)
  from public,anon,authenticated,service_role;
create function public.noop_commit_push_projection(p_object_id uuid,p_body_sha256 text,p_header jsonb,
  p_rows jsonb,p_keep_keys jsonb,p_token uuid default null) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public as $$
declare m public.object_manifests;
begin
  select * into m from public.object_manifests where id=p_object_id;
  if not found or public.noop_current_object_receipt(m.user_id,m.id) is null then
    raise exception 'projection_archive_mismatch';
  end if;
  if m.auth_mode='installation' then
    perform 1 from public.noop_app_installations where user_id=m.user_id and source_id=m.source_id
      and revoked_at is null and retired_at is null for share;
    if not found then raise exception 'inactive_installation' using errcode='42501'; end if;
  end if;
  return public.noop_commit_push_projection_intake_core(p_object_id,p_body_sha256,p_header,p_rows,p_keep_keys,p_token);
end $$;
revoke all on function public.noop_commit_push_projection(uuid,text,jsonb,jsonb,jsonb,uuid) from public,anon,authenticated;
grant execute on function public.noop_commit_push_projection(uuid,text,jsonb,jsonb,jsonb,uuid) to service_role;

-- Records are advanced after a real successful queue poll, never by a detached timer.
create table public.noop_intake_consumers (
  process_id uuid not null, instance_id uuid not null, source_revision text not null check(source_revision~'^[0-9a-f]{40}$'),
  contract_version integer not null check(contract_version=1),
  lane text not null check(lane in ('verification','projection','legacy')),
  started_at timestamptz not null default clock_timestamp(), last_successful_poll_at timestamptz not null,
  polls bigint not null default 1, claimed bigint not null default 0, completed bigint not null default 0,
  failures bigint not null default 0, last_poll_failed boolean not null default false, primary key(process_id,lane)
);
create index noop_intake_consumer_recent on public.noop_intake_consumers(last_successful_poll_at);
alter table public.noop_intake_consumers enable row level security;
revoke all on public.noop_intake_consumers from public,anon,authenticated,service_role;
grant select on public.noop_intake_consumers to service_role;
create policy noop_intake_consumers_service on public.noop_intake_consumers for select to service_role using(true);

-- Minute aggregates preserve actual work rates without an unbounded event per poll.
create table public.noop_intake_service_minutes (
  bucket timestamptz not null, lane text not null check(lane in ('verification','projection','legacy')),
  polls bigint not null, claimed bigint not null, completed bigint not null, failures bigint not null,
  primary key(bucket,lane)
);
alter table public.noop_intake_service_minutes enable row level security;
revoke all on public.noop_intake_service_minutes from public,anon,authenticated,service_role;
grant select on public.noop_intake_service_minutes to service_role;
create policy noop_intake_service_minutes_service on public.noop_intake_service_minutes for select to service_role using(true);

create function public.noop_intake_consumer_poll(p_process uuid,p_instance uuid,p_source_revision text,
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
  where noop_intake_consumers.instance_id=excluded.instance_id and noop_intake_consumers.source_revision=excluded.source_revision;
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

create function public.noop_intake_consumer_contract() returns jsonb
language sql stable security definer set search_path=pg_catalog,public as $$
  select jsonb_build_object('contract_version',1,'completion','verified_indexed',
    'projection','atomic_lifecycle_v1','lanes',jsonb_build_array('verification','projection','legacy'))
$$;
create function public.noop_async_verification_ready() returns boolean
language sql stable security definer set search_path=pg_catalog,public as $$
  select exists(select 1 from public.noop_intake_consumers where contract_version=1
    and lane='verification' and not last_poll_failed and last_successful_poll_at>now()-interval '30 seconds' and polls>=1)
$$;
revoke all on function public.noop_intake_consumer_poll(uuid,uuid,text,text,integer,integer,integer),
  public.noop_intake_consumer_contract(),public.noop_async_verification_ready() from public,anon,authenticated;
grant execute on function public.noop_intake_consumer_poll(uuid,uuid,text,text,integer,integer,integer),
  public.noop_intake_consumer_contract(),public.noop_async_verification_ready() to service_role;

-- A busy owner alternates fresh and historical objects, and owners rotate after each claim.
create table public.noop_verification_owner_service (
 user_id uuid primary key references auth.users(id) on delete cascade,
 last_claimed_at timestamptz, next_poll_at timestamptz not null default now(), last_lane text check(last_lane in ('live','history'))
);
alter table public.noop_verification_owner_service enable row level security;
revoke all on public.noop_verification_owner_service from public,anon,authenticated,service_role;
create index noop_verification_owner_due on public.noop_verification_owner_service(next_poll_at,last_claimed_at,user_id);
create index noop_verification_owner_debt on public.noop_object_verification_debt(user_id,next_attempt_at,requested_at,object_id)
  where state in ('pending','retry','leased');
-- Seed historical debt once. New owner enrollment into the scheduler is transactional with debt creation.
insert into public.noop_verification_owner_service(user_id)
  select distinct user_id from public.noop_object_verification_debt on conflict do nothing;
create function public.noop_verification_owner_enqueued() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  insert into public.noop_verification_owner_service(user_id) values(new.user_id)
    on conflict(user_id) do update set next_poll_at=least(noop_verification_owner_service.next_poll_at,now());
  return new;
end $$;
create trigger noop_verification_owner_enqueued after insert on public.noop_object_verification_debt
  for each row execute function public.noop_verification_owner_enqueued();
revoke all on function public.noop_verification_owner_enqueued() from public,anon,authenticated,service_role;

create or replace function public.noop_claim_object_verification(p_max_bytes bigint default 268435456,p_max_decoded_bytes bigint default 536870912)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare d public.noop_object_verification_debt; m public.object_manifests; token uuid:=gen_random_uuid(); owner uuid; previous_lane text;
begin
  -- Inspect at most 128 due owners per claim. Idle owners back off, and a busy owner
  -- goes to the back of the due queue. Both scans have matching partial indexes.
  for owner,previous_lane in select s.user_id,s.last_lane from public.noop_verification_owner_service s
    where s.next_poll_at<=now() order by s.next_poll_at,s.last_claimed_at nulls first,s.user_id
    for update of s skip locked limit 128 loop
    select v.* into d from public.noop_object_verification_debt v join public.object_manifests o on o.id=v.object_id
      where v.user_id=owner and o.user_id=v.user_id and v.state in ('pending','retry','leased')
        and v.next_attempt_at<=now() and (v.state<>'leased' or v.lease_until<=now())
        and o.status not in ('deleted','deleting','expired') and o.compressed_bytes>0
        and o.compressed_bytes<=least(greatest(p_max_bytes,0),268435456)
        and coalesce(o.uncompressed_bytes,536870912)<=least(greatest(p_max_decoded_bytes,0),536870912)
        and not exists(select 1 from public.noop_object_copy_intents c where c.object_id=o.id and c.state='copying' and c.lease_until>now())
      order by case when (o.end_at>now()-interval '10 minutes')=(previous_lane is distinct from 'live') then 0 else 1 end,
        v.next_attempt_at,v.requested_at,v.object_id for update of v skip locked limit 1;
    exit when found;
    update public.noop_verification_owner_service set next_poll_at=now()+interval '10 seconds' where user_id=owner;
  end loop;
  if d.object_id is null then return null; end if;
  select * into m from public.object_manifests where id=d.object_id and user_id=d.user_id;
  if not found then return null; end if;
  update public.noop_verification_owner_service set last_claimed_at=clock_timestamp(),next_poll_at=clock_timestamp(),
    last_lane=case when m.end_at>now()-interval '10 minutes' then 'live' else 'history' end where user_id=owner;
  update public.noop_object_verification_debt set state='leased',lease_token=token,
    lease_until=now()+interval '10 minutes',attempts=attempts+1,
    retry_attempts=retry_attempts+case when d.state='retry' then 1 else 0 end,
    lease_recoveries=lease_recoveries+case when d.state='leased' then 1 else 0 end,
    updated_at=now() where object_id=d.object_id;
  return jsonb_build_object('objectId',d.object_id,'token',token,'manifest',to_jsonb(m));
end $$;
-- Scalar replay has its own fair scheduler so one owner's historical archives do not
-- occupy every claim ahead of another owner's fresh physiological inputs.
create table public.noop_projection_owner_service (
  user_id uuid primary key references auth.users(id) on delete cascade,
  last_claimed_at timestamptz, next_poll_at timestamptz not null default now(),
  last_lane text check(last_lane in ('live','history'))
);
alter table public.noop_projection_owner_service enable row level security;
revoke all on public.noop_projection_owner_service from public,anon,authenticated,service_role;
create index noop_projection_owner_due on public.noop_projection_owner_service(next_poll_at,last_claimed_at,user_id);
create index noop_projection_owner_debt on public.noop_projection_debt(user_id,not_before,created_at,object_id) where state='pending';
insert into public.noop_projection_owner_service(user_id)
  select distinct user_id from public.noop_projection_debt on conflict do nothing;
create function public.noop_projection_owner_enqueued() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  insert into public.noop_projection_owner_service(user_id) values(new.user_id)
    on conflict(user_id) do update set next_poll_at=least(noop_projection_owner_service.next_poll_at,now());
  return new;
end $$;
create trigger noop_projection_owner_enqueued after insert on public.noop_projection_debt
  for each row execute function public.noop_projection_owner_enqueued();
revoke all on function public.noop_projection_owner_enqueued() from public,anon,authenticated,service_role;
create or replace function public.noop_claim_projection_debt() returns jsonb
language plpgsql security definer set search_path=pg_catalog,public as $$
declare d public.noop_projection_debt; m public.object_manifests; owner uuid; previous_lane text;
begin
  for owner,previous_lane in select s.user_id,s.last_lane from public.noop_projection_owner_service s
    where s.next_poll_at<=now() order by s.next_poll_at,s.last_claimed_at nulls first,s.user_id
    for update of s skip locked limit 128 loop
    select q.* into d from public.noop_projection_debt q join public.object_manifests o on o.id=q.object_id
      where q.user_id=owner and o.user_id=q.user_id and q.state='pending' and q.not_before<=now()
        and (q.lease_until is null or q.lease_until<=now())
        and o.status in ('ready','verified') and o.durability_receipt->>'state'='verified_indexed'
      order by case when (o.end_at>now()-interval '10 minutes')=(previous_lane is distinct from 'live') then 0 else 1 end,
        q.not_before,q.created_at,q.object_id for update of q skip locked limit 1;
    exit when found;
    update public.noop_projection_owner_service set next_poll_at=now()+interval '10 seconds' where user_id=owner;
  end loop;
  if d.object_id is null then return null; end if;
  update public.noop_projection_debt set lease_token=gen_random_uuid(),lease_until=now()+interval '2 minutes'
    where object_id=d.object_id returning * into d;
  select * into m from public.object_manifests where id=d.object_id;
  update public.noop_projection_owner_service set last_claimed_at=clock_timestamp(),next_poll_at=clock_timestamp(),
    last_lane=case when m.end_at>now()-interval '10 minutes' then 'live' else 'history' end where user_id=owner;
  return jsonb_build_object('manifest',to_jsonb(m),'leaseToken',d.lease_token);
end $$;

-- Operational readout is bounded and contains no owners, object paths or physiological values.
create index noop_verification_pending_age on public.noop_object_verification_debt(requested_at,object_id)
  where state in ('pending','retry','leased');
create index noop_projection_pending_age on public.noop_projection_debt(created_at,object_id) where state in ('pending','staged');
create function public.noop_intake_status() returns jsonb
language sql stable security definer set search_path=pg_catalog,public as $$
  with verification as (
    select requested_at as created_at from public.noop_object_verification_debt
      where state in ('pending','retry','leased') order by requested_at,object_id limit 1001
  ), projection as (
    select created_at from public.noop_projection_debt where state in ('pending','staged')
      order by created_at,object_id limit 1001
  ), rates as (
    select lane,sum(polls) as successful_polls,sum(claimed) as claimed,sum(completed) as completed,sum(failures) as failures,
      round(sum(completed)/15.0,3) as completed_per_minute
    from public.noop_intake_service_minutes where bucket>=date_trunc('minute',now())-interval '15 minutes'
      and bucket<date_trunc('minute',now()) group by lane
  ) select jsonb_build_object('captured_at',now(),'contract_version',1,
    'async_consumer_liveness',public.noop_async_verification_ready(),
    'capacity_acceptance','NOT_MEASURED','physical_continuity','NOT_MEASURED',
    'queue_sample_limit',1000,'rate_window_seconds',900,'rates',coalesce((select jsonb_agg(to_jsonb(rates)) from rates),'[]'),
    'verification',jsonb_build_object('pending_at_least',(select least(count(*),1000) from verification),
      'truncated',(select count(*)>1000 from verification),'oldest_age_seconds',(select extract(epoch from now()-min(created_at)) from verification)),
    'projection',jsonb_build_object('pending_at_least',(select least(count(*),1000) from projection),
      'truncated',(select count(*)>1000 from projection),'oldest_age_seconds',(select extract(epoch from now()-min(created_at)) from projection)))
$$;
revoke all on function public.noop_intake_status() from public,anon,authenticated;
grant execute on function public.noop_intake_status() to service_role;
notify pgrst,'reload schema';
commit;
