begin;
set local lock_timeout='5s';
set local statement_timeout='60s';

-- A count of waveform records is not a measured sampling clock. Do not erase
-- retained history in this migration; new/updated receipts cannot claim 1 Hz.
create function internal.sensor_raw_coverage_unknown() returns trigger language plpgsql set search_path='' as $$
begin
  if new.stream in ('ppgWaveformSample','rawImuSession','v18AuxSample','rawBatch') then
    new.expected_records:=null; new.missing_records:=null; new.coverage:=null;
  end if;
  return new;
end $$;
create trigger sensor_raw_coverage_unknown before insert or update on public.noop_signal_windows
  for each row execute function internal.sensor_raw_coverage_unknown();
revoke all on function internal.sensor_raw_coverage_unknown() from public,anon,authenticated,service_role;

-- Evidence is issued by the operator after capture review. Client intake cannot self-qualify.
create table public.sensor_acquisition_contracts (
  user_id uuid not null, device_id uuid not null,
  kind text not null check(kind in ('beat_timing','ppg','imu','temperature')),
  scope_start_s bigint not null check(scope_start_s%300=0),
  scope_end_s bigint not null check(scope_end_s-scope_start_s=300),
  contract_sha256 text not null check(contract_sha256 ~ '^[a-f0-9]{64}$'),
  contract_bytes bytea not null check(octet_length(contract_bytes) between 1 and 2097152),
  created_at timestamptz not null default clock_timestamp(), revoked_at timestamptz,
  primary key(user_id,device_id,kind,scope_start_s,contract_sha256),
  foreign key(user_id,device_id) references public.devices(user_id,id) on delete cascade,
  check(contract_sha256=encode(extensions.digest(contract_bytes,'sha256'),'hex'))
);
create unique index sensor_capture_active on public.sensor_acquisition_contracts(user_id,device_id,kind,scope_start_s)
  where revoked_at is null;
alter table public.sensor_acquisition_contracts enable row level security;
revoke all on public.sensor_acquisition_contracts from public,anon,authenticated,service_role;
grant select on public.sensor_acquisition_contracts to service_role;
create policy sensor_capture_worker on public.sensor_acquisition_contracts for select to service_role using(true);
create function internal.sensor_capture_change() returns trigger language plpgsql security definer set search_path='' as $$
begin
  if tg_op='UPDATE' and (new.user_id,new.device_id,new.kind,new.scope_start_s,new.scope_end_s,new.contract_sha256,new.contract_bytes,new.created_at)
    is distinct from (old.user_id,old.device_id,old.kind,old.scope_start_s,old.scope_end_s,old.contract_sha256,old.contract_bytes,old.created_at) then
    raise exception 'capture_evidence_immutable';
  end if;
  if tg_op='UPDATE' and (old.revoked_at is not null or new.revoked_at is null) then raise exception 'capture_revocation_one_way'; end if;
  perform public.scoring_dirty_span(new.user_id,new.device_id,new.scope_start_s,new.scope_end_s);
  return new;
end $$;
create trigger sensor_capture_change before insert or update on public.sensor_acquisition_contracts
  for each row execute function internal.sensor_capture_change();
revoke all on function internal.sensor_capture_change() from public,anon,authenticated,service_role;

-- An archive may arrive after its capture receipt. Availability/withdrawal dirties dependent
-- windows before any decoder stamp exists; digest validation remains a worker responsibility.
create function internal.sensor_raw_dependency_change() returns trigger language plpgsql security definer set search_path='' as $$
declare before_row jsonb; after_row jsonb; object_ids uuid[]; dependency record;
begin
  if tg_op<>'INSERT' then before_row:=to_jsonb(old); end if;
  if tg_op<>'DELETE' then after_row:=to_jsonb(new); end if;
  if tg_table_name='object_manifests' then
    if tg_op='UPDATE' and (before_row->'status',before_row->'sha256',before_row->'source_id',before_row->'object_key',
        before_row->'compression',before_row->'format',before_row->'compressed_bytes',before_row->'uncompressed_bytes',before_row->'sample_count',before_row->'object_class')
      is not distinct from (after_row->'status',after_row->'sha256',after_row->'source_id',after_row->'object_key',
        after_row->'compression',after_row->'format',after_row->'compressed_bytes',after_row->'uncompressed_bytes',after_row->'sample_count',after_row->'object_class') then return new; end if;
    object_ids:=array[(before_row->>'id')::uuid,(after_row->>'id')::uuid];
    for dependency in select distinct c.user_id,c.device_id,c.scope_start_s,c.scope_end_s
      from public.sensor_acquisition_contracts c join public.noop_signal_windows w
        on w.user_id=c.user_id and w.device_id=c.device_id and w.start_ts<c.scope_end_s and w.end_ts>c.scope_start_s
      where w.object_id=any(object_ids) and c.kind in ('ppg','imu') and c.revoked_at is null
    loop
      if exists(select 1 from public.devices where user_id=dependency.user_id and id=dependency.device_id) then
        perform public.scoring_dirty_span(dependency.user_id,dependency.device_id,dependency.scope_start_s,dependency.scope_end_s);
      end if;
    end loop;
  else
    if tg_op='UPDATE' and before_row=after_row then return new; end if;
    for dependency in select distinct c.user_id,c.device_id,c.scope_start_s,c.scope_end_s
      from public.sensor_acquisition_contracts c cross join lateral (values(before_row),(after_row)) r(value)
      where c.user_id=(r.value->>'user_id')::uuid and c.device_id=(r.value->>'device_id')::uuid
        and c.scope_start_s<(r.value->>'end_ts')::bigint and c.scope_end_s>(r.value->>'start_ts')::bigint
        and c.kind in ('ppg','imu') and c.revoked_at is null
    loop
      if exists(select 1 from public.devices where user_id=dependency.user_id and id=dependency.device_id) then
        perform public.scoring_dirty_span(dependency.user_id,dependency.device_id,dependency.scope_start_s,dependency.scope_end_s);
      end if;
    end loop;
  end if;
  if tg_op='DELETE' then return old; else return new; end if;
end $$;
create trigger sensor_raw_dependency after insert or update or delete on public.object_manifests
  for each row execute function internal.sensor_raw_dependency_change();
create trigger sensor_raw_dependency after insert or update or delete on public.noop_signal_windows
  for each row execute function internal.sensor_raw_dependency_change();
revoke all on function internal.sensor_raw_dependency_change() from public,anon,authenticated,service_role;

-- Retain the existing feature-specific authorization. Diagnostic windows can never activate a headline.
alter function public.server_scoring_read_contract(uuid,date,uuid) rename to server_scoring_read_contract_before_signals;
create function public.server_scoring_read_contract(p_user uuid,p_day date,p_device uuid default null)
returns jsonb language plpgsql stable security invoker set search_path=pg_catalog,public as $$
declare result jsonb; selected uuid; payload jsonb; revision bigint; required bigint; computed timestamptz; windows jsonb;
begin
  result := public.server_scoring_read_contract_before_signals(p_user,p_day,p_device);
  selected := coalesce(p_device,(result->'features'->'hrv'->>'device_id')::uuid);
  if selected is null then return result || jsonb_build_object('signal_windows','[]'::jsonb); end if;
  if not exists(select 1 from public.devices where user_id=p_user and id=selected) then
    raise exception 'owned device required' using errcode='42501';
  end if;
  required := public.physiology_required_revision(p_user,selected,p_day);
  select r.payload,r.input_revision,r.computed_at into payload,revision,computed
    from public.server_physiology_results r
    where r.user_id=p_user and r.device_id=selected and r.period_day=p_day
      and r.algorithm_version='frwhoop-physiology-2' order by r.input_revision desc limit 1;
  select coalesce(jsonb_agg((entry-'values') || jsonb_build_object(
      'values',null,'publication_status','shadow','published_at',computed,
      'required_revision',required,'freshness_status',case when revision<required then 'stale' else 'snapshot' end,
      'analysis_status',entry->>'measurement_status',
      'measurement_status',case when entry->>'measurement_status'='available' then 'unqualified' else entry->>'measurement_status' end,
      'reason',case when entry->>'measurement_status'='available' then 'not_reference_validated' else entry->>'reason' end
    ) order by ordinal),'[]'::jsonb) into windows
    from jsonb_array_elements(coalesce(payload->'signal_windows','[]'::jsonb)) with ordinality as item(entry,ordinal)
    where entry->>'user_id'=p_user::text and entry->>'device_id'=selected::text
      and entry->>'algorithm_version'='sensor-windows-1';
  return result || jsonb_build_object('signal_windows',windows,'signal_windows_device_id',selected);
end $$;
revoke all on function public.server_scoring_read_contract(uuid,date,uuid) from public,anon;
grant execute on function public.server_scoring_read_contract(uuid,date,uuid) to authenticated,service_role;

-- Window closure is a revision, even if no new sample arrives. Existing leases and publication fences still apply.
create function public.sensor_enqueue_closed_windows(p_now timestamptz default clock_timestamp(),p_limit integer default 16)
returns integer language plpgsql security definer set search_path='' as $$
declare candidate record; changed integer:=0; boundary bigint:=floor(extract(epoch from p_now)/300)*300;
begin
  if auth.role() is distinct from 'service_role' and session_user not in ('postgres','supabase_admin') then
    raise exception 'worker required' using errcode='42501';
  end if;
  if p_limit<1 or p_limit>16 then raise exception 'window_close_limit'; end if;
  if not pg_try_advisory_xact_lock(hashtextextended('sensor-window-close-1',0)) then return 0; end if;
  for candidate in
    select w.user_id,w.device_id,w.day,w.timezone_id
    from public.physiology_work_items w
    join lateral (select r.computed_at,r.payload from public.server_physiology_results r
      where r.user_id=w.user_id and r.device_id=w.device_id and r.period_day=w.day
        and r.algorithm_version='frwhoop-physiology-2' order by r.input_revision desc limit 1) r on true
    join lateral (select max((period->>1)::bigint) as ending from jsonb_array_elements(
      coalesce(r.payload->'calendar_ownership'->'day_intervals','[]'::jsonb)) period) ownership on true
    where w.done_at is not null and ownership.ending>=boundary-273600
      and extract(epoch from r.computed_at)<least(boundary,ownership.ending)
    order by r.computed_at,w.user_id,w.device_id,w.day limit p_limit
  loop
    begin
      perform public.physiology_enqueue_day(candidate.user_id,candidate.device_id,candidate.day,candidate.timezone_id,0);
      changed:=changed+1;
    exception when lock_not_available then null;
    end;
  end loop;
  return changed;
end $$;
revoke all on function public.sensor_enqueue_closed_windows(timestamptz,integer) from public,anon,authenticated;
grant execute on function public.sensor_enqueue_closed_windows(timestamptz,integer) to service_role;
commit;
