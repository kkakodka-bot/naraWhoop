-- Direct measurement inputs and derived baseline inputs have different receptive fields.
-- input_revision still fences the entire publication. measurement_revision only changes when
-- sensor/context/manual inputs change, so a baseline refresh does not hide unchanged HRV history.
alter table public.scoring_work_items add column measurement_revision bigint not null default 1
  check(measurement_revision > 0);
update public.scoring_work_items set measurement_revision=input_revision;
alter table public.server_physiology_results add column measurement_revision bigint not null default 1
  check(measurement_revision > 0);
update public.server_physiology_results set measurement_revision=input_revision;
alter table public.scoring_dependency_policy
  add column hrv_history_seconds integer not null default 2419200 check(hrv_history_seconds between 0 and 2678400),
  add column hrv_history_algorithm_version text not null default 'frwhoop-physiology-2'
    references public.physiology_algorithm_versions;

-- Only the effective measurement contribution is retained here, not a second result archive.
-- Removing envelope revisions and baseline outputs makes derived-only refreshes a fixed point.
create function public.scoring_hrv_contribution(p_payload jsonb) returns jsonb
language sql immutable set search_path='' as $$
  select coalesce(jsonb_agg(value-ARRAY['input_revision','baseline'] order by value->>'window_id',value::text),'[]'::jsonb)
  from jsonb_array_elements(coalesce(p_payload->'measurements','[]'::jsonb))
  where value->>'feature'='hrv' and value->>'measurement_valid'='true'
    and value->>'baseline_eligible'='true'
$$;

create table public.physiology_hrv_dependency_snapshots (
  user_id uuid not null references auth.users on delete cascade,
  device_id uuid not null references public.devices on delete cascade,
  period_day date not null,
  algorithm_version text not null references public.physiology_algorithm_versions,
  measurement_revision bigint not null,
  measurements jsonb not null check(jsonb_typeof(measurements)='array'),
  primary key(user_id,device_id,period_day,algorithm_version)
);
alter table public.physiology_hrv_dependency_snapshots enable row level security;
create policy physiology_hrv_dependency_service on public.physiology_hrv_dependency_snapshots
  for all to service_role using(true) with check(true);
grant all on public.physiology_hrv_dependency_snapshots to service_role;
insert into public.physiology_hrv_dependency_snapshots
select distinct on(r.user_id,r.device_id,r.period_day,r.algorithm_version)
  r.user_id,r.device_id,r.period_day,r.algorithm_version,r.measurement_revision,
  public.scoring_hrv_contribution(r.payload)
from public.server_physiology_results r
order by r.user_id,r.device_id,r.period_day,r.algorithm_version,r.input_revision desc;

-- Dependencies never create future/empty calendar jobs. Direct input ingestion still creates its
-- exact local-day/context jobs through scoring_affected_days; this only refreshes existing jobs.
create function public.scoring_lock_device(p_user uuid,p_device uuid) returns void
language sql security definer set search_path='' as $$
  select pg_advisory_xact_lock(hashtextextended(p_user::text||':'||p_device::text,230918))
$$;

create function public.scoring_enqueue_dependency(p_user uuid,p_device uuid,p_day date)
returns boolean language plpgsql security definer set search_path='' as $$
begin
  perform public.scoring_lock_device(p_user,p_device);
  update public.scoring_work_items set
    input_revision=input_revision+1,failure_revision=input_revision+1,
    consecutive_failures=0,attempts=0,dirty_at=clock_timestamp(),done_at=null,
    claimed_at=null,claimed_revision=null,lease_token=null,run_id=null,lease_expires_at=null,
    status='pending',last_error=null,next_attempt_at=clock_timestamp()+interval '2 seconds'
  where user_id=p_user and device_id=p_device and day=p_day
    and day <= (clock_timestamp() at time zone timezone_id)::date;
  return found;
end $$;

create function public.scoring_dirty_hrv_dependents(p_user uuid,p_device uuid,p_source_day date,
  p_measurements jsonb) returns void language plpgsql security definer set search_path='' as $$
declare target record;
begin
  -- Match SignalSampleReader's UTC-duration history bounds using each target's frozen IANA zone.
  -- Strictly forward edges plus direct-only measurement revisions prevent feedback cascades.
  for target in
    select q.day from public.scoring_work_items q cross join public.scoring_dependency_policy p
    where q.user_id=p_user and q.device_id=p_device and q.day>p_source_day
      and q.day <= (clock_timestamp() at time zone q.timezone_id)::date
      and exists(select 1 from jsonb_array_elements(p_measurements) m
        where (m->>'end')::numeric <= extract(epoch from q.day::timestamp at time zone q.timezone_id)
          and (m->>'start')::numeric >= extract(epoch from q.day::timestamp at time zone q.timezone_id)-p.hrv_history_seconds)
    order by q.day
  loop perform public.scoring_enqueue_dependency(p_user,p_device,target.day); end loop;
end $$;

create or replace function public.scoring_enqueue_day(p_user uuid,p_device uuid,p_day date,p_timezone text,
  p_debounce_seconds integer default 2) returns bigint language plpgsql security definer set search_path='' as $$
declare v_revision bigint;
begin
  -- Always before a queue row lock. Claims and worker computation do not take this mutex.
  -- It closes the invisible-new-job race between a dependency scan and calendar creation.
  perform public.scoring_lock_device(p_user,p_device);
  if not exists(select 1 from public.devices where id=p_device and user_id=p_user) then
    raise exception 'device does not belong to user' using errcode='23503';
  end if;
  if not exists(select 1 from pg_timezone_names where name=p_timezone) then
    raise exception 'invalid timezone' using errcode='22023';
  end if;
  insert into public.scoring_work_items(user_id,device_id,day,timezone_id,next_attempt_at)
    values(p_user,p_device,p_day,p_timezone,clock_timestamp()+make_interval(secs=>greatest(0,p_debounce_seconds)))
  on conflict(user_id,device_id,day) do update set
    input_revision=scoring_work_items.input_revision+1,
    measurement_revision=scoring_work_items.measurement_revision+1,
    failure_revision=scoring_work_items.input_revision+1,consecutive_failures=0,attempts=0,
    dirty_at=clock_timestamp(),done_at=null,claimed_at=null,claimed_revision=null,
    lease_token=null,run_id=null,lease_expires_at=null,status='pending',last_error=null,
    next_attempt_at=clock_timestamp()+make_interval(secs=>greatest(0,p_debounce_seconds))
  returning input_revision into v_revision;
  return v_revision;
end $$;

create or replace function public.scoring_begin_publication(p_user uuid,p_device uuid,p_day date,p_revision bigint,
  p_lease_token uuid,p_run_id uuid) returns void language plpgsql security definer set search_path='' as $$
declare w public.scoring_work_items%rowtype;
begin
  perform public.scoring_lock_device(p_user,p_device);
  select * into w from public.scoring_work_items q where q.user_id=p_user and q.device_id=p_device
    and q.day=p_day for update;
  if not found or w.input_revision is distinct from p_revision or w.claimed_revision is distinct from p_revision
    or w.lease_token is distinct from p_lease_token or w.run_id is distinct from p_run_id
    or w.lease_token is null or w.run_id is null or w.lease_expires_at is null
    or w.lease_expires_at<=clock_timestamp() or w.status<>'running' then
    raise exception 'stale scoring lease or input revision' using errcode='40001';
  end if;
end $$;

-- These row triggers can touch both old and new identities. Lock their device sets in the same
-- order as projection transition-table triggers, device-less annotations and profile invalidation.
create or replace function public.physiology_dirty_override() returns trigger
language plpgsql security definer set search_path='' as $$
declare edits jsonb[]:=array[]::jsonb[]; r record;
begin
  if tg_op<>'INSERT' then edits:=array_append(edits,to_jsonb(old)); end if;
  if tg_op<>'DELETE' then edits:=array_append(edits,to_jsonb(new)); end if;
  for r in select (e->>'user_id')::uuid as owner,(e->>'device_id')::uuid as device,
      least((e->>'original_start_at')::timestamptz,(e->>'start_at')::timestamptz) as lo,
      greatest((e->>'original_end_at')::timestamptz,(e->>'end_at')::timestamptz) as hi
    from unnest(edits) e order by owner,device,lo,hi
  loop perform public.scoring_dirty_span(r.owner,r.device,extract(epoch from r.lo)::bigint,extract(epoch from r.hi)::bigint); end loop;
  return null;
end $$;

create or replace function public.scoring_dirty_raw_object() returns trigger language plpgsql security definer
set search_path='' as $$
declare r record; ids uuid[]; was_available boolean; is_available boolean; edits jsonb[]:=array[]::jsonb[];
begin
  if tg_table_name='object_manifests' then
    if tg_op='UPDATE' and row(new.user_id,new.device_id,new.object_key,new.sha256,new.compressed_bytes,
        new.uncompressed_bytes,new.compression,new.format,new.sample_count,new.object_class) is distinct from
        row(old.user_id,old.device_id,old.object_key,old.sha256,old.compressed_bytes,
        old.uncompressed_bytes,old.compression,old.format,old.sample_count,old.object_class) then
      -- The old bytes/decoder contract cannot attest changed catalogue metadata, even when the
      -- caller carries old proof columns forward. Reverification records a fresh proof later.
      new.sha256_source:='client_claimed'; new.verified_at:=null;
      new.decode_verified_at:=null; new.decoder_version:=null;
    end if;
    if tg_op='UPDATE' and new.sha256_source is not distinct from old.sha256_source
      and new.sha256 is not distinct from old.sha256 and new.status is not distinct from old.status
      and new.decode_verified_at is not distinct from old.decode_verified_at
      and new.decoder_version is not distinct from old.decoder_version then return new; end if;
    was_available:=old.sha256_source='server_verified' and old.decode_verified_at is not null
      and old.decoder_version is not null and old.status in ('ready','verified');
    is_available:=case when tg_op='UPDATE' then new.sha256_source='server_verified'
      and new.decode_verified_at is not null and new.decoder_version is not null
      and new.status in ('ready','verified') else false end;
    ids:=case when tg_op='DELETE' then array[old.id] else array[new.id] end;
    for r in select w.* from public.noop_signal_windows w where w.object_id=any(ids)
      order by w.user_id,w.device_id,w.start_ts,w.end_ts loop
      if was_available or is_available then
        perform public.scoring_dirty_span(r.user_id,r.device_id,r.start_ts,r.end_ts);
      end if;
    end loop;
  else
    if tg_op='UPDATE' and to_jsonb(new)-'updated_at'=to_jsonb(old)-'updated_at' then return new; end if;
    if tg_op<>'INSERT' then edits:=array_append(edits,to_jsonb(old)); end if;
    if tg_op<>'DELETE' then edits:=array_append(edits,to_jsonb(new)); end if;
    for r in select (e->>'user_id')::uuid as owner,(e->>'device_id')::uuid as device,
        (e->>'start_ts')::bigint as lo,(e->>'end_ts')::bigint as hi
      from unnest(edits) e join public.object_manifests m on m.id=(e->>'object_id')::uuid
      where m.sha256_source='server_verified' and m.decode_verified_at is not null
        and m.decoder_version is not null and m.status in ('ready','verified')
      order by owner,device,lo,hi
    loop perform public.scoring_dirty_span(r.owner,r.device,r.lo,r.hi); end loop;
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end $$;

create function public.scoring_hrv_input_invalidated() returns trigger
language plpgsql security definer set search_path='' as $$
declare contribution jsonb;
begin
  if new.measurement_revision=old.measurement_revision then return new; end if;
  -- Existing contributions become unavailable in the same transaction as a direct correction.
  -- An already unavailable source cannot remove anything twice.
  select s.measurements into contribution from public.physiology_hrv_dependency_snapshots s
    join public.scoring_dependency_policy p on p.hrv_history_algorithm_version=s.algorithm_version
    where s.user_id=new.user_id and s.device_id=new.device_id and s.period_day=new.day
      and s.measurement_revision=old.measurement_revision;
  if contribution is not null and contribution<>'[]'::jsonb then
    perform public.scoring_dirty_hrv_dependents(new.user_id,new.device_id,new.day,contribution);
  end if;
  return new;
end $$;
create trigger scoring_hrv_input_invalidated after update of measurement_revision on public.scoring_work_items
for each row execute function public.scoring_hrv_input_invalidated();

create function public.scoring_capture_measurement_revision() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  -- engine_publish_physiology holds this row from scoring_begin_publication through commit.
  perform public.scoring_lock_device(new.user_id,new.device_id);
  select q.measurement_revision into new.measurement_revision from public.scoring_work_items q
    where q.user_id=new.user_id and q.device_id=new.device_id and q.day=new.period_day
      and q.input_revision=new.input_revision for update;
  if new.measurement_revision is null then
    raise exception 'measurement revision is no longer current' using errcode='40001';
  end if;
  return new;
end $$;
create trigger scoring_capture_measurement_revision before insert on public.server_physiology_results
for each row execute function public.scoring_capture_measurement_revision();

create function public.scoring_hrv_result_changed() returns trigger
language plpgsql security definer set search_path='' as $$
declare previous public.physiology_hrv_dependency_snapshots; contribution jsonb;
begin
  if not exists(select 1 from public.scoring_dependency_policy
    where hrv_history_algorithm_version=new.algorithm_version) then return new; end if;
  contribution:=public.scoring_hrv_contribution(new.payload);
  select * into previous from public.physiology_hrv_dependency_snapshots
    where user_id=new.user_id and device_id=new.device_id and period_day=new.period_day
      and algorithm_version=new.algorithm_version for update;
  -- Restoration matters even when corrected/replayed inputs produce identical measurements:
  -- a later day may already have completed while this source was unavailable or failed.
  if previous.measurement_revision is distinct from new.measurement_revision
      or previous.measurements is distinct from contribution then
    perform public.scoring_dirty_hrv_dependents(new.user_id,new.device_id,new.period_day,
      coalesce(previous.measurements,'[]'::jsonb)||contribution);
  end if;
  insert into public.physiology_hrv_dependency_snapshots values
    (new.user_id,new.device_id,new.period_day,new.algorithm_version,new.measurement_revision,contribution)
  on conflict(user_id,device_id,period_day,algorithm_version) do update set
    measurement_revision=excluded.measurement_revision,measurements=excluded.measurements;
  return new;
end $$;
create trigger scoring_hrv_result_changed after insert on public.server_physiology_results
for each row execute function public.scoring_hrv_result_changed();

do $$ declare f record; begin
  for f in select p.oid::regprocedure as signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('scoring_lock_device','scoring_hrv_contribution','scoring_enqueue_dependency',
      'scoring_dirty_hrv_dependents','scoring_hrv_input_invalidated','scoring_capture_measurement_revision',
      'scoring_hrv_result_changed') loop
    execute format('revoke all on function %s from public,anon,authenticated',f.signature);
    execute format('grant execute on function %s to service_role',f.signature);
  end loop;
end $$;
