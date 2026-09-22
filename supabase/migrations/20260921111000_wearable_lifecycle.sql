begin;

create table public.noop_wearable_aliases (
  user_id uuid not null,
  source_id uuid not null,
  provisional_device_id uuid not null,
  canonical_device_id uuid not null,
  evidence jsonb not null,
  confirmed_at timestamptz not null default clock_timestamp(),
  primary key(user_id,provisional_device_id),
  foreign key(user_id,source_id) references public.noop_app_installations(user_id,source_id) on delete cascade,
  foreign key(user_id,provisional_device_id) references public.devices(user_id,id) on delete cascade,
  foreign key(user_id,canonical_device_id) references public.devices(user_id,id) on delete cascade,
  check(provisional_device_id<>canonical_device_id)
);
create table public.noop_collection_leases (
  user_id uuid not null,
  device_id uuid not null,
  source_id uuid not null,
  generation uuid not null default gen_random_uuid(),
  expires_at timestamptz not null,
  primary key(user_id,device_id),
  foreign key(user_id,source_id) references public.noop_app_installations(user_id,source_id) on delete cascade,
  foreign key(user_id,device_id) references public.devices(user_id,id) on delete cascade
);

-- These observations preserve both receptions even when one scalar wins the natural-key insert.
create table public.noop_projection_observations (
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null,
  source_id uuid not null,
  batch_id uuid not null,
  stream text not null,
  measurement_key jsonb not null,
  row_data jsonb not null,
  received_at timestamptz not null default clock_timestamp(),
  primary key(user_id,source_id,batch_id,stream,measurement_key),
  foreign key(user_id,device_id) references public.devices(user_id,id) on delete cascade
);
create table public.noop_projection_conflicts (
  user_id uuid not null,
  device_id uuid not null,
  stream text not null,
  measurement_key jsonb not null,
  detected_at timestamptz not null default clock_timestamp(),
  reason text not null default 'conflicting_measurement',
  primary key(user_id,device_id,stream,measurement_key),
  foreign key(user_id,device_id) references public.devices(user_id,id) on delete cascade
);
create table public.noop_rr_clock_conflicts (
  user_id uuid not null,
  device_id uuid not null,
  ts bigint not null,
  primary key(user_id,device_id,ts),
  foreign key(user_id,device_id) references public.devices(user_id,id) on delete cascade
);

do $$ declare t text; begin
  foreach t in array array['noop_wearable_aliases','noop_collection_leases',
      'noop_projection_observations','noop_projection_conflicts','noop_rr_clock_conflicts'] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('create policy owner_read on public.%I for select to authenticated using(user_id=(select auth.uid()))',t);
    execute format('create policy service_all on public.%I for all to service_role using(true) with check(true)',t);
    execute format('grant select on public.%I to authenticated',t);
    execute format('revoke insert,update,delete,truncate,references,trigger on public.%I from anon,authenticated',t);
    execute format('grant all on public.%I to service_role',t);
  end loop;
end $$;

create function public.noop_projection_target(p_stream text) returns table(table_name text,key_columns text[])
language sql immutable set search_path='' as $$
  select table_name,key_columns from (values
    ('hrSample','noop_hr_samples',array['ts']),
    ('rrInterval','noop_rr_intervals',array['ts','rrMs','seq']),
    ('rrPacketProvenance','noop_rr_packet_provenance',array['sensorTs','recordIndex']),
    ('standardHRReceipt','noop_standard_hr_receipts',array['receiptId']),
    ('stepSample','noop_step_samples',array['ts']),
    ('sleepStateSample','noop_sleep_state_samples',array['ts']),
    ('ppgHrSample','noop_ppg_hr_samples',array['ts']),
    ('event','noop_events',array['ts','kind']),
    ('battery','noop_battery_samples',array['ts']),
    ('spo2Sample','noop_spo2_samples',array['ts']),
    ('skinTempSample','noop_skin_temp_samples',array['ts']),
    ('respSample','noop_resp_samples',array['ts']),
    ('gravitySample','noop_gravity_samples',array['ts'])
  ) t(stream,table_name,key_columns) where stream=p_stream;
$$;

alter function public.noop_project_append_batch(uuid,uuid,uuid,uuid,text,jsonb)
  rename to noop_project_append_batch_core;
revoke all on function public.noop_project_append_batch_core(uuid,uuid,uuid,uuid,text,jsonb)
  from public,anon,authenticated,service_role;

create function public.noop_project_append_batch(p_user uuid,p_device uuid,p_source uuid,p_batch uuid,
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
    execute format('select to_jsonb(x) from jsonb_populate_record(null::public.%I,$1) x',target) into typed using r;
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
    execute format('select to_jsonb(t) from public.%I t,jsonb_populate_record(null::public.%I,$1) x
      where t.user_id=$2 and t.device_id=$3 and %s',target,target,predicate) into prior using r,p_user,p_device;
    -- Compare only the supplied, typed measurement columns, never receipt metadata/default timestamps.
    conflicted := prior is not null and exists(select 1 from jsonb_object_keys(r) k
      where k<>all(array['source_id','batch_id','ingested_at']) and prior->k is distinct from typed->k);
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

create function public.confirm_noop_wearable(p_user uuid,p_source uuid,p_provisional uuid,p_canonical uuid,p_evidence jsonb)
returns uuid language plpgsql security definer set search_path='' as $$
declare d public.devices%rowtype; target record; batch record; rows jsonb; existing uuid; predicate text;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'service role required' using errcode='42501'; end if;
  perform 1 from public.noop_app_installations where user_id=p_user and source_id=p_source
    and revoked_at is null and retired_at is null for share;
  if not found then raise exception 'inactive_installation' using errcode='42501'; end if;
  select * into d from public.devices where id=p_canonical and user_id=p_user;
  if not found or d.external_device_id !~ '^whoop-[A-Z0-9-]{6,}$'
    or p_evidence->>'method' is distinct from 'device_information_serial_v1'
    or p_evidence->>'serial' is distinct from substr(d.external_device_id,7)
    or coalesce(p_evidence->>'receiptSha256','') !~ '^[a-f0-9]{64}$'
    or not exists(select 1 from public.devices where id=p_provisional and user_id=p_user
      and starts_with(external_device_id,'installation:'||p_source||':')) then
    raise exception 'supported_serial_evidence_required' using errcode='22023';
  end if;
  -- Stable lock order permits two phone confirmations without deadlock.
  perform public.scoring_acquire_input_gate(p_user,least(p_provisional,p_canonical));
  perform public.scoring_acquire_input_gate(p_user,greatest(p_provisional,p_canonical));
  select canonical_device_id into existing from public.noop_wearable_aliases
    where user_id=p_user and provisional_device_id=p_provisional;
  if found then
    if existing<>p_canonical then raise exception 'wearable_association_conflict' using errcode='23505'; end if;
    return existing;
  end if;
  insert into public.noop_rr_clock_conflicts select p_user,p_canonical,ts
    from public.noop_rr_clock_conflicts where user_id=p_user and device_id=p_provisional on conflict do nothing;
  insert into public.noop_projection_conflicts(user_id,device_id,stream,measurement_key,detected_at,reason)
    select p_user,p_canonical,stream,measurement_key,detected_at,reason from public.noop_projection_conflicts
      where user_id=p_user and device_id=p_provisional on conflict do nothing;
  delete from public.noop_rr_intervals r using public.noop_rr_clock_conflicts c
    where r.user_id=p_user and r.device_id=p_canonical and c.user_id=r.user_id and c.device_id=r.device_id and c.ts=r.ts;
  for target in select s.*,p.* from unnest(array['hrSample','rrInterval','rrPacketProvenance','standardHRReceipt',
    'stepSample','sleepStateSample','ppgHrSample','event','battery','spo2Sample','skinTempSample','respSample','gravitySample']) s(stream)
    cross join lateral public.noop_projection_target(s.stream) p loop
    -- A conflict may already have removed every provisional row. Its quarantine must also remove
    -- any canonical copy; otherwise merging only surviving rows would resurrect that measurement.
    select string_agg(format('t.%I is not distinct from x.%I',k,k),' and ')
      into predicate from unnest(target.key_columns) k;
    execute format('delete from public.%I t using public.noop_projection_conflicts c,
      lateral jsonb_populate_record(null::public.%I,c.measurement_key) x
      where c.user_id=$1 and c.device_id=$2 and c.stream=$3
        and t.user_id=c.user_id and t.device_id=c.device_id and %s',
      target.table_name,target.table_name,predicate) using p_user,p_canonical,target.stream;
    for batch in execute format('select source_id,batch_id from public.%I where user_id=$1 and device_id=$2
      group by source_id,batch_id',target.table_name) using p_user,p_provisional loop
      if batch.source_id is distinct from p_source or batch.batch_id is null then
        raise exception 'unattributed_provisional_input_requires_review' using errcode='22023';
      end if;
      execute format('select jsonb_agg(to_jsonb(t)||jsonb_build_object(''device_id'',$3)) from public.%I t
        where user_id=$1 and device_id=$2 and source_id=$4 and batch_id=$5',target.table_name)
        into rows using p_user,p_provisional,p_canonical,batch.source_id,batch.batch_id;
      -- Receipt observations retain the provisional row unchanged. Reconciliation uses a separate
      -- deterministic batch namespace and leaves the original raw objects/manifests untouched.
      rows := (select jsonb_agg(r||jsonb_build_object('batch_id',md5(batch.batch_id::text||p_canonical::text)::uuid))
        from jsonb_array_elements(rows) r);
      perform public.noop_project_append_batch(p_user,p_canonical,p_source,
        md5(batch.batch_id::text||p_canonical::text)::uuid,target.stream,rows);
    end loop;
    execute format('delete from public.%I where user_id=$1 and device_id=$2',target.table_name) using p_user,p_provisional;
  end loop;
  insert into public.noop_wearable_aliases values(p_user,p_source,p_provisional,p_canonical,p_evidence,clock_timestamp());
  for target in select w.start_ts,w.end_ts from public.noop_signal_windows w
      join public.object_manifests m on m.id=w.object_id and m.user_id=w.user_id and m.device_id=w.device_id
      where w.user_id=p_user and w.device_id=p_provisional and m.source_id=p_source loop
    perform public.scoring_dirty_span(p_user,p_canonical,target.start_ts,target.end_ts);
  end loop;
  return p_canonical;
end $$;

-- Raw objects retain their original tenant/source/device keys. Their canonical dependency follows
-- only an immutable, source-matched alias; late verification/retention must revoke that result too.
create function public.noop_alias_raw_dependency() returns trigger
language plpgsql security definer set search_path='' as $$
declare row_json jsonb; r record;
begin
  if tg_op='UPDATE' and to_jsonb(new)-'updated_at'=to_jsonb(old)-'updated_at' then return new; end if;
  for row_json in select * from unnest(case when tg_op='INSERT' then array[to_jsonb(new)]
    when tg_op='DELETE' then array[to_jsonb(old)] else array[to_jsonb(old),to_jsonb(new)] end) loop
    for r in select distinct a.user_id,a.canonical_device_id,w.start_ts,w.end_ts
      from (select user_id,device_id,object_id,start_ts,end_ts from public.noop_signal_windows
            where tg_table_name='object_manifests'
        union all select (row_json->>'user_id')::uuid,(row_json->>'device_id')::uuid,
            (row_json->>'object_id')::uuid,(row_json->>'start_ts')::bigint,(row_json->>'end_ts')::bigint
            where tg_table_name='noop_signal_windows') w
      join public.object_manifests m on m.id=w.object_id
      join public.noop_wearable_aliases a on a.user_id=w.user_id and a.provisional_device_id=w.device_id
        and a.source_id=m.source_id
      where m.user_id=w.user_id and m.device_id=w.device_id
        and m.id=case when tg_table_name='object_manifests' then (row_json->>'id')::uuid else (row_json->>'object_id')::uuid end
      order by a.user_id,a.canonical_device_id,w.start_ts,w.end_ts loop
      if not pg_try_advisory_xact_lock_shared(hashtextextended('physiology-input:'||r.user_id||':'||r.canonical_device_id,230919)) then
        raise exception 'scoring_input_gate_busy' using errcode='55P03';
      end if;
      perform public.scoring_dirty_span(r.user_id,r.canonical_device_id,r.start_ts,r.end_ts);
    end loop;
  end loop;
  if tg_op='DELETE' then return old; end if;
  return new;
end $$;
create trigger noop_alias_raw_dependency before update or delete on public.object_manifests
  for each row execute function public.noop_alias_raw_dependency();
create trigger noop_alias_raw_dependency after insert or update or delete on public.noop_signal_windows
  for each row execute function public.noop_alias_raw_dependency();

create function public.handoff_noop_collection(p_user uuid,p_device uuid,p_source uuid,p_expected uuid,p_seconds integer default 120)
returns jsonb language plpgsql security definer set search_path='' as $$
declare prior public.noop_collection_leases%rowtype;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'service role required' using errcode='42501'; end if;
  perform 1 from public.noop_app_installations where user_id=p_user and source_id=p_source
    and revoked_at is null and retired_at is null for share;
  if not found or not exists(select 1 from public.devices where user_id=p_user and id=p_device)
    or p_seconds not between 10 and 300 then raise exception 'invalid_collection_owner' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended('collection:'||p_user||':'||p_device,0));
  select * into prior from public.noop_collection_leases where user_id=p_user and device_id=p_device for update;
  if found and prior.expires_at>clock_timestamp() and prior.generation is distinct from p_expected then
    raise exception 'collection_generation_conflict' using errcode='PT409';
  end if;
  insert into public.noop_collection_leases(user_id,device_id,source_id,expires_at)
    values(p_user,p_device,p_source,clock_timestamp()+make_interval(secs=>p_seconds))
    on conflict(user_id,device_id) do update set source_id=excluded.source_id,generation=gen_random_uuid(),expires_at=excluded.expires_at
    returning * into prior;
  return to_jsonb(prior);
end $$;

revoke all on function public.noop_alias_raw_dependency(),public.noop_projection_target(text),public.noop_project_append_batch(uuid,uuid,uuid,uuid,text,jsonb),
  public.confirm_noop_wearable(uuid,uuid,uuid,uuid,jsonb),public.handoff_noop_collection(uuid,uuid,uuid,uuid,integer)
  from public,anon,authenticated;
grant execute on function public.noop_project_append_batch(uuid,uuid,uuid,uuid,text,jsonb),
  public.confirm_noop_wearable(uuid,uuid,uuid,uuid,jsonb),public.handoff_noop_collection(uuid,uuid,uuid,uuid,integer) to service_role;
commit;
