-- W4: effective-dated inputs and ordered, transactionally published historical state.
-- Raw step counter projection. Edge's append registry/replay integration is separately owned.
create table public.noop_step_samples (
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null references public.devices(id) on delete cascade,
  source_id uuid not null,
  ts bigint not null,
  counter integer not null,
  activity_class integer,
  batch_id uuid not null,
  ingested_at timestamptz not null default now(),
  primary key(user_id,device_id,ts)
);
alter table public.noop_step_samples enable row level security;
create policy noop_step_samples_read_own on public.noop_step_samples for select using(auth.uid()=user_id);
create policy noop_step_samples_service on public.noop_step_samples for all
  using(auth.role()='service_role') with check(auth.role()='service_role');
grant select on public.noop_step_samples to authenticated;
grant all on public.noop_step_samples to service_role;
create trigger scoring_insert_v2 after insert on public.noop_step_samples referencing new table as new_rows
  for each statement execute function public.invalidate_scoring_stream_v2('ts','ts');
create trigger scoring_update_v2 after update on public.noop_step_samples referencing old table as old_rows new table as new_rows
  for each statement execute function public.invalidate_scoring_stream_v2('ts','ts');
create trigger scoring_delete_v2 after delete on public.noop_step_samples referencing old table as old_rows
  for each statement execute function public.invalidate_scoring_stream_v2('ts','ts');

create table public.scoring_history_inputs_v3 (
  revision bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null references public.devices(id) on delete cascade,
  kind text not null check(kind in ('profile','config','sleep_edit','context','period','imported_daily','manual_workout')),
  entity text not null check(length(entity) between 1 and 128),
  effective_day date not null,
  payload jsonb not null check(jsonb_typeof(payload)='object'),
  deleted boolean not null default false,
  expected_revision bigint not null check(expected_revision>=0),
  client_id uuid not null,
  client_mutation_id uuid not null,
  client_revision bigint not null check(client_revision>0),
  received_at timestamptz not null default clock_timestamp(),
  invalidated_from date not null,
  unique(user_id,client_mutation_id),
  unique(user_id,device_id,kind,entity,client_id,client_revision)
);
create index scoring_history_input_asof_v3 on public.scoring_history_inputs_v3
  (user_id,device_id,kind,entity,effective_day desc,revision desc);
create trigger scoring_history_input_immutable_v3 before update on public.scoring_history_inputs_v3
  for each row execute function public.reject_snapshot_update_v2();

create table public.scoring_history_algorithms_v3 (
  algorithm_version text primary key references public.scoring_algorithms_v2 on delete cascade,
  state_schema_version integer not null default 1 check(state_schema_version=1)
);
create table public.scoring_history_heads_v3 (
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null references public.devices(id) on delete cascade,
  algorithm_version text not null references public.scoring_history_algorithms_v3 on delete cascade,
  generation bigint not null default 1 check(generation>0),
  dirty_from date,
  latest_day date not null,
  primary key(user_id,device_id,algorithm_version)
);
alter table public.scoring_jobs_v2 add column history_generation bigint not null default 0;
alter table public.scoring_jobs_v2 add column history_claim_generation bigint;
alter table public.scoring_jobs_v2 add column history_predecessor_revision bigint;

create table public.scoring_history_checkpoints_v3 (
  result_revision bigint primary key references public.scoring_snapshots_v2 on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null references public.devices(id) on delete cascade,
  algorithm_version text not null references public.scoring_history_algorithms_v3,
  day date not null,
  input_revision bigint not null,
  generation bigint not null,
  predecessor_result_revision bigint references public.scoring_history_checkpoints_v3,
  timezone text not null,
  configuration_revision bigint not null,
  profile_revision bigint not null,
  state_schema_version integer not null default 1 check(state_schema_version=1),
  state jsonb not null check(jsonb_typeof(state)='object'),
  unique(user_id,device_id,algorithm_version,day,input_revision)
);
create index scoring_history_checkpoint_previous_v3 on public.scoring_history_checkpoints_v3
  (user_id,device_id,algorithm_version,day desc,result_revision desc);
create trigger scoring_history_checkpoint_immutable_v3 before update on public.scoring_history_checkpoints_v3
  for each row execute function public.reject_snapshot_update_v2();

-- A mutable current profile timezone must not hide a raw correction from an older effective zone.
-- UTC-1 through UTC+3 covers every IANA offset and the reader's 30-hour lookback. This is conservative
-- invalidation only; scoring still selects the exact effective zone and real calendar boundaries.
create function public.scoring_timestamp_v3(p_time text) returns timestamptz
language sql stable set search_path=public as $$
  select case when p_time ~ '^-?[0-9]+(\.[0-9]+)?$' then to_timestamp(p_time::double precision)
    else p_time::timestamptz end
$$;

-- Preserve v2 semantics but resolve the timezone catalog ONCE per bulk statement, not once per
-- sample/end-point. Repeated pg_timezone_names scans made even 240-row uploads take seconds.
create or replace function public.invalidate_scoring_stream_v2() returns trigger
language plpgsql security definer set search_path=public as $$
declare r record; v record; d date; query text; source_sql text; ts_field text:=TG_ARGV[0];
begin
  if TG_OP='UPDATE' then
    source_sql:='(select to_jsonb(n)-array[''ingested_at'',''updated_at'',''batch_id'',''source_id''] as b from new_rows n EXCEPT select to_jsonb(o)-array[''ingested_at'',''updated_at'',''batch_id'',''source_id''] from old_rows o) union (select to_jsonb(o)-array[''ingested_at'',''updated_at'',''batch_id'',''source_id''] from old_rows o EXCEPT select to_jsonb(n)-array[''ingested_at'',''updated_at'',''batch_id'',''source_id''] from new_rows n)';
  elsif TG_OP='INSERT' then source_sql:='select to_jsonb(n) as b from new_rows n';
  else source_sql:='select to_jsonb(o) as b from old_rows o'; end if;
  query:='with changed as materialized ('||source_sql||'), zones as materialized (
    select p.id,coalesce(t.name,''UTC'') as zone from profiles p
    join (select distinct (b->>''user_id'')::uuid id from changed) owners using(id)
    left join pg_timezone_names t on t.name=p.timezone)
    select distinct (b->>''user_id'')::uuid as u,(b->>''device_id'')::uuid as dev,
    (scoring_timestamp_v3(b->>'||quote_literal(ts_field)||') at time zone p.zone)::date as day,
    (scoring_timestamp_v3(coalesce(b->>'||quote_literal(coalesce(TG_ARGV[1],ts_field))||',b->>'||quote_literal(ts_field)||')) at time zone p.zone)::date as through_day
    from changed join zones p on p.id=(b->>''user_id'')::uuid order by u,dev,day';
  for r in execute query loop
    if not exists(select 1 from devices where id=r.dev and user_id=r.u) then continue; end if;
    perform pg_advisory_xact_lock(hashtextextended('scoring-inputs-v2:'||r.u,0));
    for v in select algorithm_version from scoring_algorithms_v2 where enabled loop
      if r.through_day-r.day>7 then
        insert into scoring_invalidations_v2(user_id,device_id,algorithm_version,next_day,through_day,reason)
          values(r.u,r.dev,v.algorithm_version,r.day,r.through_day+2,TG_TABLE_NAME);
      else
        for d in select generate_series(r.day,r.through_day+2,interval '1 day')::date loop
          perform enqueue_scoring_v2(r.u,r.dev,d,v.algorithm_version,TG_TABLE_NAME);
        end loop;
      end if;
    end loop;
  end loop;
  return null;
end $$;

create function public.invalidate_scoring_history_stream_v3() returns trigger
language plpgsql security definer set search_path=public as $$
declare source_sql text; query text; r record; v record;
begin
  if TG_OP='UPDATE' then
    source_sql:='(select to_jsonb(n)-array[''ingested_at'',''updated_at'',''batch_id'',''source_id''] b from new_rows n EXCEPT select to_jsonb(o)-array[''ingested_at'',''updated_at'',''batch_id'',''source_id''] from old_rows o) union (select to_jsonb(o)-array[''ingested_at'',''updated_at'',''batch_id'',''source_id''] from old_rows o EXCEPT select to_jsonb(n)-array[''ingested_at'',''updated_at'',''batch_id'',''source_id''] from new_rows n)';
  elsif TG_OP='INSERT' then source_sql:='select to_jsonb(n) b from new_rows n';
  else source_sql:='select to_jsonb(o) b from old_rows o'; end if;
  query:='select (b->>''user_id'')::uuid u,(b->>''device_id'')::uuid dev,
    min((scoring_timestamp_v3(b->>'||quote_literal(TG_ARGV[0])||') at time zone ''UTC'')::date)-1 lo,
    max((scoring_timestamp_v3(coalesce(b->>'||quote_literal(TG_ARGV[1])||',b->>'||quote_literal(TG_ARGV[0])||')) at time zone ''UTC'')::date)+3 hi
    from ('||source_sql||') changed group by u,dev order by u,dev';
  for r in execute query loop
    if not exists(select 1 from devices where id=r.dev and user_id=r.u) then continue; end if;
    perform pg_advisory_xact_lock(hashtextextended('scoring-inputs-v2:'||r.u,0));
    for v in select a.algorithm_version from scoring_history_algorithms_v3 a join scoring_algorithms_v2 b using(algorithm_version) where b.enabled loop
      -- Dirties the head immediately, so a later claimed day cannot publish while expansion waits.
      perform enqueue_scoring_v2(r.u,r.dev,r.lo,v.algorithm_version,'historical_timezone_raw_correction');
      insert into scoring_invalidations_v2(user_id,device_id,algorithm_version,next_day,through_day,reason)
        values(r.u,r.dev,v.algorithm_version,r.lo,r.hi,'historical_timezone_raw_correction');
    end loop;
  end loop;
  return null;
end $$;
do $$ declare t text; lo text; hi text; begin
  foreach t in array array['noop_hr_samples','noop_rr_intervals','noop_resp_samples','noop_gravity_samples',
    'noop_events','noop_skin_temp_samples','noop_spo2_samples','noop_sleep_state_samples','noop_ppg_hr_samples','noop_step_samples','noop_signal_windows','sessions'] loop
    lo:=case when t='noop_signal_windows' then 'start_ts' when t='sessions' then 'start_at' else 'ts' end;
    hi:=case when t='noop_signal_windows' then 'end_ts' when t='sessions' then 'end_at' else 'ts' end;
    execute format('create trigger history_insert_v3 after insert on public.%I referencing new table as new_rows for each statement execute function public.invalidate_scoring_history_stream_v3(%L,%L)',t,lo,hi);
    execute format('create trigger history_update_v3 after update on public.%I referencing old table as old_rows new table as new_rows for each statement execute function public.invalidate_scoring_history_stream_v3(%L,%L)',t,lo,hi);
    execute format('create trigger history_delete_v3 after delete on public.%I referencing old table as old_rows for each statement execute function public.invalidate_scoring_history_stream_v3(%L,%L)',t,lo,hi);
  end loop;
end $$;

create function public.mark_scoring_history_dirty_v3() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  if new.reason='history_forward_v3' or not exists(select 1 from scoring_history_algorithms_v3
    where algorithm_version=new.algorithm_version) then return new; end if;
  insert into scoring_history_heads_v3(user_id,device_id,algorithm_version,dirty_from,latest_day)
    values(new.user_id,new.device_id,new.algorithm_version,new.day,new.day)
  on conflict(user_id,device_id,algorithm_version) do update set
    generation=scoring_history_heads_v3.generation+1,
    dirty_from=least(coalesce(scoring_history_heads_v3.dirty_from,excluded.dirty_from),excluded.dirty_from),
    latest_day=greatest(scoring_history_heads_v3.latest_day,excluded.latest_day);
  return new;
end $$;
create trigger scoring_history_dirty_v3 after insert or update of input_revision on public.scoring_jobs_v2
  for each row execute function public.mark_scoring_history_dirty_v3();

create function public.register_scoring_history_v3(p_version text) returns boolean
language plpgsql security definer set search_path=public as $$
begin
  perform register_scoring_algorithm_v2(p_version);
  insert into scoring_history_algorithms_v3 values(p_version,1) on conflict do nothing;
  if not found then return false; end if;
  insert into scoring_history_heads_v3(user_id,device_id,algorithm_version,dirty_from,latest_day)
    select user_id,device_id,p_version,min(day),max(day) from scoring_jobs_v2
    where algorithm_version=p_version group by user_id,device_id;
  return true;
end $$;

create function public.expand_scoring_history_v3(p_limit integer default 128) returns integer
language plpgsql security definer set search_path=public as $$
declare h scoring_history_heads_v3; n integer:=0; changed integer;
begin
  for h in select * from scoring_history_heads_v3 where dirty_from is not null
    order by dirty_from,user_id,device_id,algorithm_version for update skip locked
  loop
    exit when n>=least(greatest(coalesce(p_limit,0),0),1000);
    with due as (
      select q.user_id,q.device_id,q.day,q.algorithm_version from scoring_jobs_v2 q
      where q.user_id=h.user_id and q.device_id=h.device_id and q.algorithm_version=h.algorithm_version
        and q.day>=h.dirty_from and q.history_generation<h.generation
      order by q.day for update skip locked limit least(greatest(p_limit,0),1000)-n
    ) update scoring_jobs_v2 q set input_revision=q.input_revision+1,history_generation=h.generation,
      reason='history_forward_v3',not_before=clock_timestamp(),dirty_at=clock_timestamp(),
      consecutive_failures=0,dead_letter=false,last_error=null
      from due d where (q.user_id,q.device_id,q.day,q.algorithm_version)=(d.user_id,d.device_id,d.day,d.algorithm_version);
    get diagnostics changed=row_count; n:=n+changed;
  end loop;
  return n;
end $$;

create function public.claim_scoring_history_v3(p_version text,p_lease_seconds integer default 300)
returns setof public.scoring_jobs_v2 language plpgsql security definer set search_path=public as $$
declare j scoring_jobs_v2; g bigint; predecessor bigint;
begin
  if p_lease_seconds<1 or p_lease_seconds>3600 then raise exception 'invalid_lease'; end if;
  select q.* into j from scoring_jobs_v2 q join scoring_history_heads_v3 h
    using(user_id,device_id,algorithm_version)
  where q.algorithm_version=p_version and q.day>=h.dirty_from and q.history_generation=h.generation
    and q.completed_revision<q.input_revision and not q.dead_letter and q.not_before<=clock_timestamp()
    and (q.lease_until is null or q.lease_until<=clock_timestamp())
    and exists(select 1 from scoring_algorithms_v2 a where a.algorithm_version=p_version and a.enabled)
    and not exists(select 1 from scoring_jobs_v2 prior where prior.user_id=q.user_id
      and prior.device_id=q.device_id and prior.algorithm_version=q.algorithm_version
      and prior.day>=h.dirty_from and prior.day<q.day)
    and not exists(select 1 from scoring_invalidations_v2 i where i.user_id=q.user_id
      and i.device_id=q.device_id and i.algorithm_version=q.algorithm_version and i.next_day<=q.day)
  order by q.dirty_at,q.user_id,q.day,q.device_id for update of q skip locked limit 1;
  if not found then return; end if;
  select generation into g from scoring_history_heads_v3
    where user_id=j.user_id and device_id=j.device_id and algorithm_version=p_version;
  select result_revision into predecessor from scoring_history_checkpoints_v3
    where user_id=j.user_id and device_id=j.device_id and algorithm_version=p_version and day<j.day
    order by day desc,result_revision desc limit 1;
  return query update scoring_jobs_v2 q set lease_token=gen_random_uuid(),
    lease_until=clock_timestamp()+make_interval(secs=>p_lease_seconds),history_claim_generation=g,
    history_predecessor_revision=predecessor,last_claimed_at=clock_timestamp(),claim_count=q.claim_count+1,
    lease_expiry_count=q.lease_expiry_count+case when q.lease_token is null then 0 else 1 end
    where (q.user_id,q.device_id,q.day,q.algorithm_version)=(j.user_id,j.device_id,j.day,j.algorithm_version)
    returning q.*;
end $$;

create function public.publish_scoring_history_v3(p_token uuid,p_revision bigint,p_generation bigint,
  p_predecessor bigint,p_payload jsonb,p_state jsonb,p_profile_revision bigint,p_configuration_revision bigint,p_duration_ms bigint)
returns bigint language plpgsql security definer set search_path=public as $$
declare j scoring_jobs_v2; h scoring_history_heads_v3; u uuid; result bigint; predecessor bigint;
  expected_profile bigint; expected_config bigint;
begin
  select user_id into u from scoring_jobs_v2 where lease_token=p_token;
  if not found then return null; end if;
  perform pg_advisory_xact_lock_shared(hashtextextended('scoring-inputs-v2:'||u,0));
  select * into j from scoring_jobs_v2 where lease_token=p_token for update;
  if not found or j.lease_until<=clock_timestamp() or j.input_revision<>p_revision then return null; end if;
  select * into h from scoring_history_heads_v3 where user_id=j.user_id and device_id=j.device_id
    and algorithm_version=j.algorithm_version for update;
  if not found or h.generation<>p_generation or j.history_claim_generation<>p_generation
    or j.history_generation<>p_generation or h.dirty_from is null or j.day<h.dirty_from then return null; end if;
  if exists(select 1 from scoring_jobs_v2 where user_id=j.user_id and device_id=j.device_id
    and algorithm_version=j.algorithm_version and day>=h.dirty_from and day<j.day) then return null; end if;
  select result_revision into predecessor from scoring_history_checkpoints_v3 where user_id=j.user_id
    and device_id=j.device_id and algorithm_version=j.algorithm_version and day<j.day
    order by day desc,result_revision desc limit 1;
  if predecessor is distinct from p_predecessor or j.history_predecessor_revision is distinct from p_predecessor then return null; end if;
  select revision into expected_profile from scoring_history_inputs_v3 where user_id=j.user_id
    and device_id=j.device_id and kind='profile' and entity='primary' and effective_day<=j.day
    order by effective_day desc,revision desc limit 1;
  select revision into expected_config from scoring_history_inputs_v3 where user_id=j.user_id
    and device_id=j.device_id and kind='config' and entity='primary' and effective_day<=j.day
    order by effective_day desc,revision desc limit 1;
  if p_profile_revision is distinct from coalesce(expected_profile,0)
    or p_configuration_revision is distinct from coalesce(expected_config,0) then return null; end if;
  if jsonb_typeof(p_state) is distinct from 'object' or (p_state->>'schemaVersion')::integer is distinct from 1
    or (p_state->>'throughDay')::date is distinct from j.day then raise exception 'invalid_history_checkpoint'; end if;
  result:=publish_scoring_snapshot_v2(p_token,p_revision,p_payload,p_duration_ms);
  if result is null then return null; end if;
  insert into scoring_history_checkpoints_v3(result_revision,user_id,device_id,algorithm_version,day,input_revision,
    generation,predecessor_result_revision,timezone,profile_revision,configuration_revision,state)
    values(result,j.user_id,j.device_id,j.algorithm_version,j.day,p_revision,p_generation,p_predecessor,
      p_payload->>'timezone',p_profile_revision,p_configuration_revision,p_state);
  update scoring_history_heads_v3 set dirty_from=(select min(day) from scoring_jobs_v2
    where user_id=j.user_id and device_id=j.device_id and algorithm_version=j.algorithm_version and day>j.day)
    where user_id=j.user_id and device_id=j.device_id and algorithm_version=j.algorithm_version;
  return result;
end $$;

create function public.check_scoring_history_publication_v3() returns trigger language plpgsql as $$
begin
  if exists(select 1 from public.scoring_history_algorithms_v3 where algorithm_version=new.algorithm_version)
    and not exists(select 1 from public.scoring_history_checkpoints_v3 where result_revision=new.result_revision
      and user_id=new.user_id and device_id=new.device_id and day=new.day and input_revision=new.input_revision) then
    raise exception 'history_checkpoint_required';
  end if;
  return new;
end $$;
create constraint trigger scoring_history_publication_v3 after insert on public.scoring_snapshots_v2
  deferrable initially deferred for each row execute function public.check_scoring_history_publication_v3();

create function public.validate_scoring_history_input_v3(p_kind text,p_payload jsonb,p_deleted boolean) returns void
language plpgsql security definer set search_path=public as $$
declare k text; n jsonb; previous_end bigint; allowed text[]; purpose text; expected_unit text; previous_bound numeric;
begin
  if jsonb_typeof(p_payload) is distinct from 'object' or octet_length(p_payload::text)>65536 then
    raise exception 'invalid_history_input_payload' using errcode='22023'; end if;
  if p_deleted then
    if p_payload<>'{}'::jsonb then raise exception 'tombstone_payload_must_be_empty' using errcode='22023'; end if;
    return;
  end if;
  if p_payload->'schemaVersion' is distinct from '1'::jsonb then raise exception 'unsupported_history_input_schema' using errcode='22023'; end if;
  if p_kind='profile' then
    for k in select jsonb_object_keys(p_payload) loop
      if k<>all(array['schemaVersion','age','sex','weightKg','heightCm','waistCm','timezone','stepTicksPerStep']) then
        raise exception 'unsupported_profile_field: %',k using errcode='22023'; end if;
    end loop;
    if not exists(select 1 from pg_timezone_names where name=p_payload->>'timezone') then
      raise exception 'invalid_profile_timezone' using errcode='22023'; end if;
    if p_payload ? 'sex' and p_payload->'sex'<>'null'::jsonb and p_payload->>'sex'<>all(array['male','female','nonbinary']) then
      raise exception 'invalid_profile_sex' using errcode='22023'; end if;
    foreach k in array array['age','weightKg','heightCm','waistCm','stepTicksPerStep'] loop
      if p_payload ? k and p_payload->k<>'null'::jsonb and (jsonb_typeof(p_payload->k)<>'number'
        or (p_payload->>k)::numeric<=0 or (p_payload->>k)::numeric>500) then
        raise exception 'invalid_profile_number: %',k using errcode='22023'; end if;
    end loop;
  elsif p_kind='config' then
    for k in select jsonb_object_keys(p_payload) loop
      if k<>all(array['schemaVersion','maxHR','effortMethod','deepHrvWindow','useSleepStagerV2','useMotionAwareWake',
        'sleepNeedHours','hrvBaselineEpoch','recoveryBaselineEpoch','sourceEra','journalContextEnabled','cycleAwarenessEnabled','daytimePersonalBaselineEnabled',
        'customHRZoneLowerBounds','stepsManualCoefficient','spo2CandidateDisplayEnabled','dayCycleMode']) then
        raise exception 'unsupported_config_field: %',k using errcode='22023'; end if;
    end loop;
    if p_payload ? 'effortMethod' and (jsonb_typeof(p_payload->'effortMethod')<>'string'
      or p_payload->>'effortMethod'<>all(array['EDWARDS','BANISTER'])) then
      raise exception 'invalid_effort_method' using errcode='22023'; end if;
    if p_payload ? 'dayCycleMode' and (jsonb_typeof(p_payload->'dayCycleMode')<>'string'
      or p_payload->>'dayCycleMode'<>all(array['sleep_onset','midnight'])) then
      raise exception 'invalid_day_cycle_mode' using errcode='22023'; end if;
    foreach k in array array['deepHrvWindow','useSleepStagerV2','useMotionAwareWake','journalContextEnabled','cycleAwarenessEnabled','daytimePersonalBaselineEnabled','spo2CandidateDisplayEnabled'] loop
      if p_payload ? k and jsonb_typeof(p_payload->k)<>'boolean' then raise exception 'invalid_config_boolean' using errcode='22023'; end if;
    end loop;
    foreach k in array array['maxHR','sleepNeedHours','hrvBaselineEpoch','recoveryBaselineEpoch'] loop
      if p_payload ? k and p_payload->k<>'null'::jsonb and (jsonb_typeof(p_payload->k)<>'number' or (p_payload->>k)::numeric<0) then
        raise exception 'invalid_config_number' using errcode='22023'; end if;
    end loop;
    if (p_payload->>'maxHR')::numeric not between 80 and 240
      or (p_payload->>'sleepNeedHours')::numeric not between 3 and 14 then raise exception 'invalid_config_range' using errcode='22023'; end if;
    if p_payload ? 'sourceEra' and (jsonb_typeof(p_payload->'sourceEra')<>'string'
      or length(p_payload->>'sourceEra') not between 1 and 128) then
      raise exception 'invalid_source_era' using errcode='22023'; end if;
    if p_payload ? 'customHRZoneLowerBounds' and p_payload->'customHRZoneLowerBounds'<>'null'::jsonb then
      if jsonb_typeof(p_payload->'customHRZoneLowerBounds')<>'array' then
        raise exception 'invalid_custom_hr_zones' using errcode='22023'; end if;
      if jsonb_array_length(p_payload->'customHRZoneLowerBounds')<>5 then
        raise exception 'invalid_custom_hr_zones' using errcode='22023'; end if;
      previous_bound:=0;
      for n in select value from jsonb_array_elements(p_payload->'customHRZoneLowerBounds') loop
        if jsonb_typeof(n)<>'number' then raise exception 'invalid_custom_hr_zones' using errcode='22023'; end if;
        if n::text::numeric not between 30 and 250 or n::text::numeric<=previous_bound then
          raise exception 'invalid_custom_hr_zones' using errcode='22023'; end if;
        previous_bound:=n::text::numeric;
      end loop;
    end if;
    if p_payload ? 'stepsManualCoefficient' and p_payload->'stepsManualCoefficient'<>'null'::jsonb then
      if jsonb_typeof(p_payload->'stepsManualCoefficient')<>'number' then
        raise exception 'invalid_steps_coefficient' using errcode='22023'; end if;
      if (p_payload->>'stepsManualCoefficient')::numeric not between 0 and 1000000 then
        raise exception 'invalid_steps_coefficient' using errcode='22023'; end if;
    end if;
  elsif p_kind='sleep_edit' then
    for k in select jsonb_object_keys(p_payload) loop
      if k<>all(array['schemaVersion','originalStart','originalEnd','start','end','stages','isNap','dismissed']) then
        raise exception 'unsupported_sleep_edit_field: %',k using errcode='22023'; end if;
    end loop;
    if not (p_payload ?& array['originalStart','originalEnd','start','end','isNap','dismissed']) then
      raise exception 'sleep_edit_fields_required' using errcode='22023'; end if;
    foreach k in array array['originalStart','originalEnd','start','end'] loop
      if jsonb_typeof(p_payload->k)<>'number' or (p_payload->>k)::numeric<>trunc((p_payload->>k)::numeric)
        or (p_payload->>k)::numeric not between 1 and 7289654400 then
        raise exception 'invalid_sleep_edit_timestamp' using errcode='22023'; end if;
    end loop;
    if (p_payload->>'end')::bigint<=(p_payload->>'start')::bigint
      or (p_payload->>'originalEnd')::bigint<=(p_payload->>'originalStart')::bigint
      or (p_payload->>'end')::bigint-(p_payload->>'start')::bigint>172800
      or jsonb_typeof(p_payload->'isNap')<>'boolean' or jsonb_typeof(p_payload->'dismissed')<>'boolean' then
      raise exception 'invalid_sleep_edit_bounds' using errcode='22023'; end if;
    if p_payload ? 'stages' then
      if jsonb_typeof(p_payload->'stages')<>'array' or jsonb_array_length(p_payload->'stages')>5760 then
        raise exception 'invalid_sleep_edit_stages' using errcode='22023'; end if;
      previous_end:=(p_payload->>'start')::bigint;
      for n in select value from jsonb_array_elements(p_payload->'stages') loop
        if jsonb_typeof(n) is distinct from 'object' then
          raise exception 'invalid_sleep_edit_stage' using errcode='22023'; end if;
        if jsonb_typeof(n->'start') is distinct from 'number'
          or jsonb_typeof(n->'end') is distinct from 'number'
          or jsonb_typeof(n->'stage') is distinct from 'string'
          or n-array['start','end','stage'] <> '{}'::jsonb then
          raise exception 'invalid_sleep_edit_stage' using errcode='22023'; end if;
        if (n->>'start')::numeric<>trunc((n->>'start')::numeric)
          or (n->>'end')::numeric<>trunc((n->>'end')::numeric)
          or (n->>'start')::numeric<previous_end
          or (n->>'end')::numeric<=(n->>'start')::numeric or (n->>'end')::numeric>(p_payload->>'end')::bigint
          or n->>'stage'<>all(array['wake','light','deep','rem']) then raise exception 'invalid_sleep_edit_stage' using errcode='22023'; end if;
        previous_end:=(n->>'end')::numeric::bigint;
      end loop;
    end if;
  elsif p_kind in ('context','period','imported_daily','manual_workout') then
    allowed:=case p_kind
      when 'context' then array['schemaVersion','day','timezone','flags','consent']
      when 'period' then array['schemaVersion','day','timezone','event','consent']
      when 'imported_daily' then array['schemaVersion','day','timezone','source','values','consent']
      else array['schemaVersion','timezone','originalStart','originalSport','start','end','sport','dismissed','energyKcal','distanceM','steps','consent'] end;
    for k in select jsonb_object_keys(p_payload) loop
      if k<>all(allowed) then raise exception 'unsupported_context_input_field' using errcode='22023'; end if;
    end loop;
    if not (p_payload ?& allowed) then raise exception 'context_input_fields_required' using errcode='22023'; end if;
    if not exists(select 1 from pg_timezone_names where name=p_payload->>'timezone') then
      raise exception 'invalid_context_timezone' using errcode='22023'; end if;
    if p_kind<>'manual_workout' and (jsonb_typeof(p_payload->'day') is distinct from 'string'
      or p_payload->>'day' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
      or (p_payload->>'day')::date not between date '1900-01-01' and date '2200-12-31') then
      raise exception 'invalid_context_day' using errcode='22023'; end if;
    purpose:=case p_kind when 'context' then 'journal_context' when 'period' then 'cycle_context'
      when 'imported_daily' then 'imported_metrics' else 'manual_workouts' end;
    n:=p_payload->'consent';
    if jsonb_typeof(n) is distinct from 'object' or not (n ?& array['purpose','policyVersion','decisionId'])
      or n->>'purpose' is distinct from purpose or n->'policyVersion' is distinct from '1'::jsonb
      or jsonb_typeof(n->'decisionId') is distinct from 'string'
      or n->>'decisionId' !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      or n-array['purpose','policyVersion','decisionId']<>'{}'::jsonb then
      raise exception 'invalid_context_consent_provenance' using errcode='22023'; end if;
    if p_kind='context' then
      n:=p_payload->'flags'; allowed:=array['alcohol','stress','sauna','hardOrLateWorkout','travelPhaseJump','alreadyUnwell'];
      if jsonb_typeof(n) is distinct from 'object' or not (n ?& allowed) or n-allowed<>'{}'::jsonb then
        raise exception 'invalid_context_flags' using errcode='22023'; end if;
      foreach k in array allowed loop
        if jsonb_typeof(n->k) not in ('boolean','null') then raise exception 'invalid_context_flag' using errcode='22023'; end if;
      end loop;
    elsif p_kind='period' then
      if p_payload->>'event' is distinct from 'period_start' then raise exception 'invalid_period_event' using errcode='22023'; end if;
    elsif p_kind='imported_daily' then
      n:=p_payload->'source';
      if jsonb_typeof(n) is distinct from 'object' or not(n ?& array['kind','externalDeviceId','method'])
        or n-array['kind','externalDeviceId','method']<>'{}'::jsonb
        or jsonb_typeof(n->'kind') is distinct from 'string'
        or n->>'kind' not in ('apple_health','health_connect','oura_import','whoop_import','miband_import')
        or jsonb_typeof(n->'externalDeviceId') is distinct from 'string' or length(n->>'externalDeviceId') not between 1 and 256
        or jsonb_typeof(n->'method') is distinct from 'string' or length(n->>'method') not between 1 and 128 then
        raise exception 'invalid_imported_source' using errcode='22023'; end if;
      if jsonb_typeof(p_payload->'values') is distinct from 'object' then raise exception 'invalid_imported_values' using errcode='22023'; end if;
      for k,n in select * from jsonb_each(p_payload->'values') loop
        expected_unit:=case k when 'steps_count' then 'count' when 'active_energy_kcal' then 'kcal'
          when 'basal_energy_kcal' then 'kcal' when 'vo2max_ml_kg_min' then 'mL/kg/min'
          when 'body_mass_kg' then 'kg' when 'lean_mass_kg' then 'kg' when 'body_fat_pct' then '%'
          when 'spo2_pct' then '%' when 'bmi_kg_m2' then 'kg/m2' when 'avg_hr_bpm' then 'bpm'
          when 'resting_hr_bpm' then 'bpm' when 'hrv_rmssd_ms' then 'ms' when 'hrv_sdnn_ms' then 'ms'
          when 'resp_rate_bpm' then 'breaths/min' when 'skin_temp_c' then 'degC'
          when 'sleep_total_min' then 'min' when 'sleep_debt_min' then 'min' when 'sleep_need_min' then 'min'
          when 'sleep_performance_pct' then '%' when 'sleep_consistency_pct' then '%'
          when 'miband_max_hr_bpm' then 'bpm' when 'miband_vitality_points' then 'vendor_points'
          when 'miband_sleep_deep_min' then 'min' when 'miband_sleep_rem_min' then 'min'
          when 'miband_sleep_light_min' then 'min' when 'miband_sleep_awake_min' then 'min'
          when 'miband_intensity_min' then 'min'
          when 'miband_sleep_score_0_100' then 'vendor_score_0_100'
          when 'miband_stress_score_0_100' then 'vendor_score_0_100' else null end;
        if k like 'miband_%' and p_payload->'source'->>'kind'<>'miband_import' then
          raise exception 'imported_metric_source_mismatch' using errcode='22023'; end if;
        if expected_unit is null or jsonb_typeof(n) is distinct from 'object'
          or not(n ?& array['value','unit']) or n-array['value','unit']<>'{}'::jsonb
          or n->>'unit' is distinct from expected_unit or jsonb_typeof(n->'value') not in ('number','null') then
          raise exception 'invalid_imported_metric' using errcode='22023'; end if;
        if n->'value'<>'null'::jsonb and (abs((n->>'value')::numeric)>1000000
          or (n->>'value')::numeric<0
          or (k in ('body_fat_pct','spo2_pct','sleep_performance_pct','sleep_consistency_pct') and (n->>'value')::numeric>100)
          or (k='sleep_need_min' and (n->>'value')::numeric>1440)
          or (k in ('miband_sleep_score_0_100','miband_stress_score_0_100') and (n->>'value')::numeric>100)
          or (k in ('miband_max_hr_bpm','miband_vitality_points','miband_sleep_score_0_100','miband_stress_score_0_100') and (n->>'value')::numeric<=0)
          or (k in ('miband_sleep_deep_min','miband_sleep_rem_min','miband_sleep_light_min','miband_sleep_awake_min','miband_intensity_min') and (n->>'value')::numeric>1440)
          or (k in ('miband_max_hr_bpm','miband_vitality_points','miband_sleep_score_0_100','miband_stress_score_0_100') and (n->>'value')::numeric<>trunc((n->>'value')::numeric))
          or (k='steps_count' and (n->>'value')::numeric<>trunc((n->>'value')::numeric))) then
          raise exception 'invalid_imported_metric_range' using errcode='22023'; end if;
      end loop;
    else
      foreach k in array array['originalStart','start','end'] loop
        if jsonb_typeof(p_payload->k) is distinct from 'number'
          or (p_payload->>k)::numeric<>trunc((p_payload->>k)::numeric)
          or (p_payload->>k)::numeric not between 1 and 7289654400 then
          raise exception 'invalid_workout_timestamp' using errcode='22023'; end if;
      end loop;
      if (p_payload->>'end')::bigint-(p_payload->>'start')::bigint not between 1 and 172800
        or jsonb_typeof(p_payload->'dismissed') is distinct from 'boolean' then
        raise exception 'invalid_workout_bounds' using errcode='22023'; end if;
      foreach k in array array['originalSport','sport'] loop
        if jsonb_typeof(p_payload->k) is distinct from 'string' or length(p_payload->>k) not between 1 and 128 then
          raise exception 'invalid_workout_sport' using errcode='22023'; end if;
      end loop;
      foreach k in array array['energyKcal','distanceM','steps'] loop
        if p_payload->k<>'null'::jsonb and (jsonb_typeof(p_payload->k)<>'number'
          or (p_payload->>k)::numeric not between 0 and 1000000
          or (k='steps' and (p_payload->>k)::numeric<>trunc((p_payload->>k)::numeric))) then
          raise exception 'invalid_workout_measurement' using errcode='22023'; end if;
      end loop;
    end if;
  end if;
exception when invalid_text_representation or numeric_value_out_of_range or datetime_field_overflow or invalid_datetime_format then
  raise exception 'invalid_history_input_field_value' using errcode='22023';
end $$;

-- Snapshot sleep IDs identify the original session across days/algorithm versions. The legacy
-- table has a GLOBAL UUID primary key, so its materialized row ID needs a separate namespace.
-- Do not change the canonical snapshot or its editEntity to satisfy that legacy storage detail.
create or replace function public.refresh_scoring_legacy_v2(p_user uuid,p_day date,p_version text)
returns void language plpgsql security definer set search_path=public as $$
declare s scoring_snapshots_v2; d jsonb; n jsonb; dev uuid;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_user::text||p_day::text||p_version,0));
  dev:=selected_scoring_device_v2(p_user,p_day,p_version);
  select * into s from scoring_snapshots_v2 where user_id=p_user and day=p_day
    and algorithm_version=p_version and device_id=dev order by result_revision desc limit 1;
  if not found then
    delete from server_daily_scores where user_id=p_user and day=p_day and algorithm_version=p_version;
    delete from server_sleep_nights where user_id=p_user and period_day=p_day and algorithm_version=p_version;
    return;
  end if;
  d:=s.payload->'daily';
  insert into server_daily_scores(user_id,day,algorithm_version,source_device_id,
    hrv_rmssd_ms,hrv_sdnn_ms,resting_hr_bpm,resp_rate_bpm,sleep_total_min,sleep_in_bed_min,sleep_awake_min,
    sleep_light_min,sleep_deep_min,sleep_rem_min,sleep_efficiency,sleep_onset_at,wake_onset_at,
    overnight_hr_bpm,disturbances,provenance,computed_at)
  values(p_user,p_day,p_version,dev,(d->>'hrv_rmssd_ms')::numeric,(d->>'hrv_sdnn_ms')::numeric,
    (d->>'resting_hr_bpm')::numeric,(d->>'resp_rate_bpm')::numeric,(d->>'sleep_total_min')::numeric,
    (d->>'sleep_in_bed_min')::numeric,(d->>'sleep_awake_min')::numeric,(d->>'sleep_light_min')::numeric,
    (d->>'sleep_deep_min')::numeric,(d->>'sleep_rem_min')::numeric,(d->>'sleep_efficiency')::numeric,
    (d->>'sleep_onset_at')::timestamptz,(d->>'wake_onset_at')::timestamptz,(d->>'overnight_hr_bpm')::numeric,
    (d->>'disturbances')::integer,jsonb_build_object('schemaVersion',2,'resultRevision',s.result_revision),s.computed_at)
  on conflict(user_id,day,algorithm_version) do update set source_device_id=excluded.source_device_id,
    hrv_rmssd_ms=excluded.hrv_rmssd_ms,hrv_sdnn_ms=excluded.hrv_sdnn_ms,resting_hr_bpm=excluded.resting_hr_bpm,
    resp_rate_bpm=excluded.resp_rate_bpm,sleep_total_min=excluded.sleep_total_min,sleep_in_bed_min=excluded.sleep_in_bed_min,
    sleep_awake_min=excluded.sleep_awake_min,sleep_light_min=excluded.sleep_light_min,sleep_deep_min=excluded.sleep_deep_min,
    sleep_rem_min=excluded.sleep_rem_min,sleep_efficiency=excluded.sleep_efficiency,sleep_onset_at=excluded.sleep_onset_at,
    wake_onset_at=excluded.wake_onset_at,overnight_hr_bpm=excluded.overnight_hr_bpm,disturbances=excluded.disturbances,
    readiness_level=null,skin_temp_c=null,skin_temp_dev_c=null,spo2_pct=null,confidence='{}',
    provenance=excluded.provenance,computed_at=excluded.computed_at;
  delete from server_sleep_nights where user_id=p_user and period_day=p_day and algorithm_version=p_version;
  for n in select value from jsonb_array_elements(s.payload->'sleep') loop
    insert into server_sleep_nights(id,user_id,device_id,period_day,start_at,end_at,is_nap,
      in_bed_min,asleep_min,awake_min,light_min,deep_min,rem_min,efficiency,resting_hr_bpm,hrv_rmssd_ms,
      stages,algorithm_version,computed_at)
    values(md5('legacy-sleep-v3|'||p_user||'|'||dev||'|'||p_day||'|'||p_version||'|'||(n->>'id'))::uuid,
      p_user,dev,p_day,(n->>'start_at')::timestamptz,(n->>'end_at')::timestamptz,
      (n->>'is_nap')::boolean,(n->>'in_bed_min')::numeric,(n->>'asleep_min')::numeric,(n->>'awake_min')::numeric,
      (n->>'light_min')::numeric,(n->>'deep_min')::numeric,(n->>'rem_min')::numeric,(n->>'efficiency')::numeric,
      (n->>'resting_hr_bpm')::numeric,(n->>'hrv_rmssd_ms')::numeric,n->'stages',p_version,s.computed_at);
  end loop;
end $$;

create function public.put_scoring_history_input_v3(p_device uuid,p_kind text,p_entity text,p_effective_day date,
  p_payload jsonb,p_expected_revision bigint,p_deleted boolean,p_client_id uuid,p_client_mutation_id uuid,p_client_revision bigint)
returns jsonb language plpgsql security definer set search_path=public as $$
declare u uuid:=auth.uid(); old scoring_history_inputs_v3; anchor scoring_history_inputs_v3; inserted scoring_history_inputs_v3;
  head bigint; first_day date; last_day date; zone text;
begin
  if u is null then raise exception 'authentication_required' using errcode='42501'; end if;
  if not exists(select 1 from devices where id=p_device and user_id=u) then raise exception 'device_owner_mismatch' using errcode='42501'; end if;
  if p_kind is null or p_kind<>all(array['profile','config','sleep_edit','context','period','imported_daily','manual_workout'])
    or p_entity is null or length(p_entity) not between 1 and 128 or p_effective_day is null
    or p_effective_day not between date '1900-01-01' and date '2200-12-31'
    or p_expected_revision is null or p_expected_revision<0 or p_deleted is null
    or p_client_id is null or p_client_mutation_id is null or p_client_revision is null or p_client_revision<1 then
    raise exception 'invalid_history_input_identity' using errcode='22023'; end if;
  if p_kind in ('profile','config') and p_entity<>'primary' then raise exception 'singleton_entity_must_be_primary' using errcode='22023'; end if;
  perform validate_scoring_history_input_v3(p_kind,p_payload,p_deleted);
  if p_kind in ('sleep_edit','period','manual_workout') and p_entity !~
    ('^'||case p_kind when 'sleep_edit' then 'sleep' when 'period' then 'period' else 'workout' end||
      ':[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') then
    raise exception 'invalid_event_entity' using errcode='22023'; end if;
  if p_kind='context' and p_entity<>('context:'||p_effective_day::text) then
    raise exception 'invalid_context_entity' using errcode='22023'; end if;
  if p_kind='imported_daily' and p_entity not like 'import:%' then
    raise exception 'invalid_imported_entity' using errcode='22023'; end if;
  if p_kind in ('context','period','imported_daily') and not p_deleted
    and p_effective_day is distinct from (p_payload->>'day')::date then
    raise exception 'observation_effective_day_mismatch' using errcode='22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended('scoring-inputs-v2:'||u,0));
  select * into old from scoring_history_inputs_v3 where user_id=u and client_mutation_id=p_client_mutation_id;
  if found then
    if (old.device_id,old.kind,old.entity,old.effective_day,old.payload,old.expected_revision,old.deleted,old.client_id,old.client_revision)
      is distinct from (p_device,p_kind,p_entity,p_effective_day,p_payload,p_expected_revision,p_deleted,p_client_id,p_client_revision) then
      raise exception 'idempotency_conflict' using errcode='23505'; end if;
    inserted:=old;
  else
    select coalesce(max(revision),0) into head from scoring_history_inputs_v3
      where user_id=u and device_id=p_device and kind=p_kind and entity=p_entity;
    if head<>p_expected_revision then raise exception 'history_revision_conflict' using errcode='40001'; end if;
    if exists(select 1 from scoring_history_inputs_v3 where user_id=u and device_id=p_device and kind=p_kind
      and entity=p_entity and client_id=p_client_id and client_revision>=p_client_revision) then
      raise exception 'client_revision_conflict' using errcode='40001'; end if;
    select * into old from scoring_history_inputs_v3 where revision=head;
    select * into anchor from scoring_history_inputs_v3 where user_id=u and device_id=p_device
      and kind=p_kind and entity=p_entity and not deleted order by revision limit 1;
    if p_kind='sleep_edit' and not p_deleted and anchor.revision is not null
      and (anchor.payload->>'originalStart',anchor.payload->>'originalEnd') is distinct from
          (p_payload->>'originalStart',p_payload->>'originalEnd') then
      raise exception 'sleep_edit_original_identity_changed' using errcode='22023'; end if;
    if anchor.revision is not null then
      if p_kind in ('context','period','imported_daily') and p_effective_day<>anchor.effective_day then
        raise exception 'observation_day_identity_changed' using errcode='22023'; end if;
      if not p_deleted and p_kind='imported_daily' and p_payload->'source' is distinct from anchor.payload->'source' then
        raise exception 'imported_source_identity_changed' using errcode='22023'; end if;
      if not p_deleted and p_kind='manual_workout' and (p_payload->>'originalStart',p_payload->>'originalSport')
        is distinct from (anchor.payload->>'originalStart',anchor.payload->>'originalSport') then
        raise exception 'workout_original_identity_changed' using errcode='22023'; end if;
    end if;
    first_day:=p_effective_day;
    select coalesce(timezone,'UTC') into zone from profiles where id=u;
    zone:=coalesce(zone,'UTC');
    if p_kind in ('sleep_edit','manual_workout') then
      first_day:=least(first_day,
        scoring_local_day_v2(p_payload->>'originalStart',zone),scoring_local_day_v2(p_payload->>'start',zone),
        scoring_local_day_v2(old.payload->>'originalStart',zone),scoring_local_day_v2(old.payload->>'start',zone));
    end if;
    -- Conservative overnight/timezone overlap; the state reader still selects strictly as of D.
    first_day:=first_day-2;
    select greatest(p_effective_day+2,coalesce(max(day),p_effective_day+2)) into last_day
      from scoring_jobs_v2 where user_id=u and device_id=p_device;
    if p_kind in ('sleep_edit','manual_workout') then
      last_day:=greatest(last_day,scoring_local_day_v2(p_payload->>'end',zone)+2,
        scoring_local_day_v2(old.payload->>'end',zone)+2,scoring_local_day_v2(anchor.payload->>'originalEnd',zone)+2);
    end if;
    insert into scoring_history_inputs_v3(user_id,device_id,kind,entity,effective_day,payload,deleted,expected_revision,
      client_id,client_mutation_id,client_revision,invalidated_from)
      values(u,p_device,p_kind,p_entity,p_effective_day,p_payload,p_deleted,p_expected_revision,
        p_client_id,p_client_mutation_id,p_client_revision,first_day) returning * into inserted;
    perform invalidate_scoring_history_v2(u,p_device,first_day,last_day,'history_input:'||p_kind);
  end if;
  return jsonb_build_object('schemaVersion',1,'userId',u,'sourceDeviceId',p_device,'kind',p_kind,'entity',p_entity,
    'revision',inserted.revision,'clientId',p_client_id,'clientMutationId',p_client_mutation_id,'clientRevision',p_client_revision,
    'effectiveDay',inserted.effective_day,'deleted',inserted.deleted,'invalidatedFrom',inserted.invalidated_from);
end $$;

-- Head metadata is separate from as-of payload selection. A fresh installation may discover
-- a scheduled future head, but this RPC never returns that future profile/configuration body.
create function public.get_scoring_history_input_head_v3(p_device uuid,p_kind text,p_entity text)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare u uuid:=auth.uid(); head bigint;
begin
  if u is null then raise exception 'authentication_required' using errcode='42501'; end if;
  if not exists(select 1 from devices where id=p_device and user_id=u) then raise exception 'device_owner_mismatch' using errcode='42501'; end if;
  if p_kind is null or p_kind<>all(array['profile','config','sleep_edit','context','period','imported_daily','manual_workout'])
    or p_entity is null or length(p_entity) not between 1 and 128 then
    raise exception 'invalid_history_input_identity' using errcode='22023'; end if;
  if p_kind in ('profile','config') and p_entity<>'primary' then raise exception 'singleton_entity_must_be_primary' using errcode='22023'; end if;
  select coalesce(max(revision),0) into head from scoring_history_inputs_v3
    where user_id=u and device_id=p_device and kind=p_kind and entity=p_entity;
  return jsonb_build_object('schemaVersion',1,'userId',u,'sourceDeviceId',p_device,
    'kind',p_kind,'entity',p_entity,'headRevision',head);
end $$;

create function public.get_scoring_history_input_v3(p_device uuid,p_kind text,p_entity text,p_as_of_day date)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare u uuid:=auth.uid(); r scoring_history_inputs_v3; head bigint;
begin
  if u is null then raise exception 'authentication_required' using errcode='42501'; end if;
  if not exists(select 1 from devices where id=p_device and user_id=u) then raise exception 'device_owner_mismatch' using errcode='42501'; end if;
  if p_kind is null or p_kind<>all(array['profile','config','sleep_edit','context','period','imported_daily','manual_workout'])
    or p_entity is null or length(p_entity) not between 1 and 128 or p_as_of_day is null
    or p_as_of_day not between date '1900-01-01' and date '2200-12-31' then
    raise exception 'invalid_history_input_identity' using errcode='22023'; end if;
  if p_kind in ('profile','config') and p_entity<>'primary' then raise exception 'singleton_entity_must_be_primary' using errcode='22023'; end if;
  select coalesce(max(revision),0) into head from scoring_history_inputs_v3
    where user_id=u and device_id=p_device and kind=p_kind and entity=p_entity;
  select * into r from scoring_history_inputs_v3 where user_id=u and device_id=p_device and kind=p_kind and entity=p_entity
    and effective_day<=p_as_of_day
    -- A session is one editable entity, not a scheduled settings timeline. A correction moving
    -- its wake day earlier must replace the older bounds on later days too. Still exclude any
    -- not-yet-effective revision. Profiles/config retain effective-day precedence.
    order by case when p_kind in ('sleep_edit','manual_workout') then null else effective_day end desc,revision desc limit 1;
  return jsonb_build_object('schemaVersion',1,'userId',u,'sourceDeviceId',p_device,'kind',p_kind,'entity',p_entity,
    'headRevision',head,'revision',r.revision,'effectiveDay',r.effective_day,'deleted',r.deleted,
    'payload',case when r.deleted then null else r.payload end);
end $$;

do $$ declare t text; f record; begin
  foreach t in array array['scoring_history_inputs_v3','scoring_history_algorithms_v3','scoring_history_heads_v3','scoring_history_checkpoints_v3'] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('revoke all on public.%I from public,anon,authenticated',t);
    execute format('grant all on public.%I to service_role',t);
    execute format('create policy scoring_history_service_v3 on public.%I for all to service_role using(true) with check(true)',t);
  end loop;
  for f in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('mark_scoring_history_dirty_v3','register_scoring_history_v3',
      'expand_scoring_history_v3','claim_scoring_history_v3','publish_scoring_history_v3','check_scoring_history_publication_v3',
      'validate_scoring_history_input_v3','put_scoring_history_input_v3','get_scoring_history_input_v3',
      'get_scoring_history_input_head_v3','invalidate_scoring_history_stream_v3') loop
    execute format('revoke all on function %s from public,anon,authenticated',f.sig);
    execute format('grant execute on function %s to service_role',f.sig);
  end loop;
end $$;
grant execute on function public.put_scoring_history_input_v3(uuid,text,text,date,jsonb,bigint,boolean,uuid,uuid,bigint) to authenticated;
grant execute on function public.get_scoring_history_input_v3(uuid,text,text,date) to authenticated;
grant execute on function public.get_scoring_history_input_head_v3(uuid,text,text) to authenticated;

-- Preserve readback compatibility while exposing dependency debt before the bounded expander has
-- visited a later day. Old workers must not claim a history job without its predecessor/checkpoint.
alter function public.get_server_score_snapshot_v2(date,text) set schema internal;
revoke all on function internal.get_server_score_snapshot_v2(date,text) from public,anon,authenticated,service_role;
create function public.get_server_score_snapshot_v2(p_day date,p_algorithm_version text default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare snapshot jsonb;
begin
  snapshot:=internal.get_server_score_snapshot_v2(p_day,p_algorithm_version);
  if exists(select 1 from scoring_history_heads_v3 where user_id=auth.uid()
    and device_id=(snapshot->>'sourceDeviceId')::uuid and algorithm_version=snapshot->>'algorithmVersion'
    and dirty_from<=p_day) then
    snapshot:=snapshot || jsonb_build_object('pending',true);
  end if;
  return snapshot;
end $$;
revoke all on function public.get_server_score_snapshot_v2(date,text) from public,anon;
grant execute on function public.get_server_score_snapshot_v2(date,text) to authenticated,service_role;

alter function public.claim_scoring_v2(text,integer) set schema internal;
revoke all on function internal.claim_scoring_v2(text,integer) from public,anon,authenticated,service_role;
create function public.claim_scoring_v2(p_version text,p_lease_seconds integer default 300)
returns setof public.scoring_jobs_v2 language plpgsql security definer set search_path=public as $$
begin
  if exists(select 1 from scoring_history_algorithms_v3 where algorithm_version=p_version) then return; end if;
  return query select * from internal.claim_scoring_v2(p_version,p_lease_seconds);
end $$;
revoke all on function public.claim_scoring_v2(text,integer) from public,anon,authenticated;
grant execute on function public.claim_scoring_v2(text,integer) to service_role;
