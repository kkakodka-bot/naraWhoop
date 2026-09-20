-- Independent work debt for the retained v1 binary and the v2 shadow worker.
-- Existing queue rows, results, raw inputs and live claims are preserved. The migration
-- changes only future routing and requeues unclaimed debt without an attributable result.
begin;
lock table public.scoring_work_items in share row exclusive mode;
create table public.physiology_work_items (like public.scoring_work_items including all);
alter table public.physiology_work_items
  add foreign key(user_id) references auth.users(id) on delete cascade,
  add foreign key(device_id) references public.devices(id) on delete cascade;
insert into public.physiology_work_items select * from public.scoring_work_items;
alter table public.physiology_work_items enable row level security;
create policy physiology_work_items_service on public.physiology_work_items for all to service_role
  using(true) with check(true);
grant all on public.physiology_work_items to service_role;
comment on table public.physiology_work_items is
  'Exclusive frwhoop-physiology-2 shadow work. Retained frwhoop-server-1 uses scoring_work_items. A new algorithm needs independent work ownership.';

-- A legacy claim lacks v2 lease identity. Its copied shadow debt must be runnable.
update public.physiology_work_items q set done_at=null,claimed_at=null,claimed_revision=null,
  lease_token=null,run_id=null,lease_expires_at=null,status='pending',attempts=0,
  consecutive_failures=0,next_attempt_at=clock_timestamp()
where (q.claimed_at is null or q.lease_token is null or q.run_id is null)
  and not exists(select 1 from public.server_physiology_results r where r.user_id=q.user_id
    and r.device_id=q.device_id and r.period_day=q.day and r.algorithm_version='frwhoop-physiology-2'
    and r.input_revision=q.input_revision);

drop trigger scoring_hrv_input_invalidated on public.scoring_work_items;
create trigger scoring_hrv_input_invalidated after update of measurement_revision on public.physiology_work_items
  for each row execute function public.scoring_hrv_input_invalidated();

-- The retained binary has no revision/lease token in its publication request. This receipt
-- attests only a completed legacy run and exact stored payload, never fenced provenance.
create table public.legacy_scoring_receipts (
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null references public.devices(id) on delete cascade,
  day date not null,
  input_revision bigint not null,
  result_hash text not null check(result_hash ~ '^[a-f0-9]{64}$'),
  completed_at timestamptz not null default clock_timestamp(),
  primary key(user_id,device_id,day)
);
alter table public.legacy_scoring_receipts enable row level security;
create policy legacy_scoring_receipts_service on public.legacy_scoring_receipts for all to service_role
  using(true) with check(true);
grant all on public.legacy_scoring_receipts to service_role;

create function public.scoring_legacy_snapshot(p_user uuid,p_device uuid,p_day date) returns jsonb
language sql stable security definer set search_path='' as $$
  select jsonb_build_object('daily',to_jsonb(d),'nights',coalesce((
    select jsonb_agg(to_jsonb(n) order by n.start_at) from public.server_sleep_nights n
    where n.user_id=p_user and n.device_id=p_device and n.period_day=p_day
      and n.algorithm_version='frwhoop-server-1'),'[]'::jsonb))
  from public.server_daily_scores d where d.user_id=p_user and d.source_device_id=p_device
    and d.day=p_day and d.algorithm_version='frwhoop-server-1'
$$;

create function public.scoring_legacy_queue_transition() returns trigger
language plpgsql security definer set search_path='' as $$
declare snapshot jsonb; completed timestamptz;
begin
  if new.dirty_at>old.dirty_at or new.input_revision>old.input_revision then
    new.input_revision:=greatest(new.input_revision,old.input_revision+1);
    new.done_at:=null;new.claimed_at:=null;new.claimed_revision:=null;
    new.attempts:=0;new.status:='pending';new.last_error:=null;
    delete from public.legacy_scoring_receipts where user_id=new.user_id and device_id=new.device_id and day=new.day;
  elsif new.claimed_at is not null and new.claimed_at is distinct from old.claimed_at then
    new.claimed_revision:=new.input_revision;new.status:='running';
    new.lease_token:=null;new.run_id:=null;new.lease_expires_at:=null;
  elsif new.done_at is not null and new.done_at is distinct from old.done_at then
    snapshot:=public.scoring_legacy_snapshot(new.user_id,new.device_id,new.day);
    completed:=(snapshot#>>'{daily,computed_at}')::timestamptz;
    if old.claimed_at is not null and old.claimed_revision=old.input_revision
        and completed>=old.claimed_at and completed>=old.dirty_at then
      insert into public.legacy_scoring_receipts(user_id,device_id,day,input_revision,result_hash)
      values(new.user_id,new.device_id,new.day,new.input_revision,
        encode(sha256(convert_to(snapshot::text,'UTF8')),'hex'))
      on conflict(user_id,device_id,day) do update set input_revision=excluded.input_revision,
        result_hash=excluded.result_hash,completed_at=clock_timestamp();
      new.status:='done';new.attempts:=0;
    else
      -- A shadow or unmatched completion cannot make an absent baseline result current.
      new.done_at:=null;new.status:='pending';
    end if;
  elsif new.claimed_at is null and old.claimed_at is not null then
    new.status:=case when new.attempts>=8 then 'exhausted' else 'retry' end;
  end if;
  return new;
end $$;
create trigger legacy_scoring_queue_transition before update on public.scoring_work_items
  for each row execute function public.scoring_legacy_queue_transition();

-- Previously shared completion is ambiguous. Preserve active legacy claims and all data;
-- unclaimed baseline work obtains its own completion receipt on its next successful run.
update public.scoring_work_items set done_at=null,attempts=0,status='pending'
  where claimed_at is null;

create function public.scoring_enqueue_legacy(p_user uuid,p_device uuid,p_day date,p_timezone text)
returns void language plpgsql security definer set search_path='' as $$
begin
  insert into public.scoring_work_items(user_id,device_id,day,timezone_id,dirty_at)
    values(p_user,p_device,p_day,p_timezone,clock_timestamp())
  on conflict(user_id,device_id,day) do update set
    input_revision=scoring_work_items.input_revision+1,dirty_at=clock_timestamp(),done_at=null,
    claimed_at=null,claimed_revision=null,attempts=0,status='pending',last_error=null;
end $$;


create or replace function public.physiology_enqueue_day(p_user uuid,p_device uuid,p_day date,p_timezone text,
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
  insert into public.physiology_work_items(user_id,device_id,day,timezone_id,next_attempt_at)
    values(p_user,p_device,p_day,p_timezone,clock_timestamp()+make_interval(secs=>greatest(0,p_debounce_seconds)))
  on conflict(user_id,device_id,day) do update set
    input_revision=physiology_work_items.input_revision+1,
    measurement_revision=physiology_work_items.measurement_revision+1,
    failure_revision=physiology_work_items.input_revision+1,consecutive_failures=0,attempts=0,
    dirty_at=clock_timestamp(),done_at=null,claimed_at=null,claimed_revision=null,
    lease_token=null,run_id=null,lease_expires_at=null,status='pending',last_error=null,
    next_attempt_at=clock_timestamp()+make_interval(secs=>greatest(0,p_debounce_seconds))
  returning input_revision into v_revision;
  return v_revision;
end $$;


create or replace function public.scoring_enqueue_day(p_user uuid,p_device uuid,p_day date,p_timezone text,
  p_debounce_seconds integer default 2) returns bigint language plpgsql security definer set search_path='' as $$
declare revision bigint;
begin
  -- Fixed lock order: device, shadow queue, legacy queue. Legacy completion never locks shadow.
  revision:=public.physiology_enqueue_day(p_user,p_device,p_day,p_timezone,p_debounce_seconds);
  perform public.scoring_enqueue_legacy(p_user,p_device,p_day,p_timezone);
  return revision;
end $$;


create or replace function public.scoring_dirty_context() returns trigger language plpgsql security definer
set search_path='' as $$
declare keys text[]; k text; changed boolean:=false; owner uuid; device uuid; r record;
begin
  if tg_table_name='profiles' then
    keys:=array['date_of_birth','sex_model','weight_kg','height_cm','preferences']; owner:=new.id;
  else
    keys:=array['device_family','firmware','calibration']; owner:=new.user_id; device:=new.id;
  end if;
  foreach k in array keys loop
    changed:=changed or (to_jsonb(new)->k is distinct from to_jsonb(old)->k);
  end loop;
  if changed then
    for r in select * from public.physiology_work_items where user_id=owner
      and (device is null or device_id=device) order by device_id,day loop
      perform public.scoring_enqueue_day(r.user_id,r.device_id,r.day,r.timezone_id);
    end loop;
  end if;
  return new;
end $$;

create or replace function public.scoring_begin_publication(p_user uuid,p_device uuid,p_day date,p_revision bigint,
  p_lease_token uuid,p_run_id uuid) returns void language plpgsql security definer set search_path='' as $$
declare w public.physiology_work_items%rowtype;
begin
  perform public.scoring_lock_device(p_user,p_device);
  select * into w from public.physiology_work_items q where q.user_id=p_user and q.device_id=p_device
    and q.day=p_day for update;
  if not found or w.input_revision is distinct from p_revision or w.claimed_revision is distinct from p_revision
    or w.lease_token is distinct from p_lease_token or w.run_id is distinct from p_run_id
    or w.lease_token is null or w.run_id is null or w.lease_expires_at is null
    or w.lease_expires_at<=clock_timestamp() or w.status<>'running' then
    raise exception 'stale scoring lease or input revision' using errcode='40001';
  end if;
end $$;

create or replace function public.scoring_renew_lease(p_user uuid,p_device uuid,p_day date,p_revision bigint,
  p_lease_token uuid,p_run_id uuid,p_lease_seconds integer default 300) returns boolean
language plpgsql security definer set search_path='' as $$
begin
  begin
    perform public.scoring_begin_publication(p_user,p_device,p_day,p_revision,p_lease_token,p_run_id);
  exception when serialization_failure then return false; end;
  update public.physiology_work_items set lease_expires_at=clock_timestamp()+make_interval(secs=>greatest(1,least(p_lease_seconds,3600)))
  where user_id=p_user and device_id=p_device and day=p_day;
  return found;
end $$;

create or replace function public.scoring_finish_work(p_user uuid,p_device uuid,p_day date,p_revision bigint,
  p_lease_token uuid,p_run_id uuid,p_outcome text,p_duration_ms integer default null,p_error text default null)
returns boolean language plpgsql security definer set search_path='' as $$
declare failures integer;
begin
  if p_outcome not in ('done','waiting','failed') then raise exception 'invalid outcome'; end if;
  begin
    perform public.scoring_begin_publication(p_user,p_device,p_day,p_revision,p_lease_token,p_run_id);
  exception when serialization_failure then return false; end;
  select case when failure_revision=p_revision then consecutive_failures else 0 end into failures
    from public.physiology_work_items where user_id=p_user and device_id=p_device and day=p_day;
  if p_outcome='failed' then failures:=failures+1;
  elsif p_outcome='done' then failures:=0; end if;
  update public.physiology_work_items set done_at=case when p_outcome='done' then clock_timestamp() end,
    claimed_at=null,claimed_revision=null,lease_token=null,run_id=null,lease_expires_at=null,
    consecutive_failures=failures,failure_revision=p_revision,attempts=failures,
    status=case when p_outcome='failed' then case when failures>=8 then 'exhausted' else 'retry' end else p_outcome end,
    next_attempt_at=clock_timestamp()+make_interval(secs=>case when p_outcome='failed'
      then least(3600,5*power(2,least(failures-1,10))) when p_outcome='waiting' then 300 else 0 end),
    last_error=case when p_outcome='done' then null else left(p_error,2000) end,last_duration_ms=p_duration_ms
  where user_id=p_user and device_id=p_device and day=p_day;
  return true;
end $$;

create or replace function public.scoring_capture_measurement_revision() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  -- engine_publish_physiology holds this row from scoring_begin_publication through commit.
  perform public.scoring_lock_device(new.user_id,new.device_id);
  select q.measurement_revision into new.measurement_revision from public.physiology_work_items q
    where q.user_id=new.user_id and q.device_id=new.device_id and q.day=new.period_day
      and q.input_revision=new.input_revision for update;
  if new.measurement_revision is null then
    raise exception 'measurement revision is no longer current' using errcode='40001';
  end if;
  return new;
end $$;

create or replace function public.scoring_record_timezone() returns trigger language plpgsql security definer
set search_path='' as $$
declare d record; q record; change_at timestamptz; key_day date;
begin
  if not exists(select 1 from pg_timezone_names where name=new.timezone) then
    raise exception 'invalid IANA timezone' using errcode='22023';
  end if;
  if tg_op='INSERT' then
    insert into public.scoring_timezone_history values(new.id,'-infinity',new.timezone,'initial_profile')
      on conflict(user_id,effective_at) do nothing;
  elsif new.timezone is distinct from old.timezone then
    for d in select id from public.devices where user_id=new.id order by id loop
      perform public.scoring_lock_device(new.id,d.id);
    end loop;
    change_at:=clock_timestamp();
    insert into public.scoring_timezone_history values(new.id,change_at,new.timezone,'profile_change');
    -- Existing future/context jobs may have been precreated in the old zone. Historical dates
    -- whose complete ownership ended before the change retain their revision and prior calendar.
    for q in select * from public.physiology_work_items where user_id=new.id and (
      (day+1)::timestamp at time zone old.timezone > change_at or
      (day+1)::timestamp at time zone new.timezone > change_at) order by device_id,day
    loop perform public.scoring_enqueue_day(q.user_id,q.device_id,q.day,q.timezone_id); end loop;
    for d in select id from public.devices where user_id=new.id order by id loop
      for key_day in select distinct base_day+n from (values
        ((change_at at time zone old.timezone)::date),((change_at at time zone new.timezone)::date)) days(base_day)
        cross join public.scoring_dependency_policy p
        cross join lateral generate_series(0,p.preceding_context_days) n order by 1
      loop perform public.scoring_enqueue_day(new.id,d.id,key_day,new.timezone); end loop;
    end loop;
  end if;
  return new;
end $$;

create or replace function public.scoring_dirty_wear_state() returns trigger
language plpgsql security definer set search_path='' as $$
declare changes text; owner_device record; affected record;
begin
  if tg_op='UPDATE' then
    changes := '(select to_jsonb(n)-ARRAY[''ingested_at'',''updated_at'',''batch_id'',''replacement_id''] as j from new_rows n
      except select to_jsonb(o)-ARRAY[''ingested_at'',''updated_at'',''batch_id'',''replacement_id''] from old_rows o)
      union (select to_jsonb(o)-ARRAY[''ingested_at'',''updated_at'',''batch_id'',''replacement_id''] from old_rows o
      except select to_jsonb(n)-ARRAY[''ingested_at'',''updated_at'',''batch_id'',''replacement_id''] from new_rows n)';
  elsif tg_op='INSERT' then changes:='select to_jsonb(n) as j from new_rows n';
  else changes:='select to_jsonb(o) as j from old_rows o'; end if;
  -- Same globally sorted owner/device mutex order as projection/publication. No unbounded future jobs.
  for owner_device in execute 'with changed as ('||changes||')
    select distinct (j->>''user_id'')::uuid as owner,(j->>''device_id'')::uuid as device from changed
    where left(j->>''kind'',9)=''WRIST_OFF'' or left(j->>''kind'',8)=''WRIST_ON'' order by owner,device'
  loop
    perform public.scoring_lock_device(owner_device.owner,owner_device.device);
    for affected in execute 'with changed as ('||changes||'), spans as (
      select (j->>''ts'')::bigint as lo,coalesce((select min(e.ts) from public.noop_events e
        where e.user_id=$1 and e.device_id=$2 and e.ts>(j->>''ts'')::bigint
          and (left(e.kind,9)=''WRIST_OFF'' or left(e.kind,8)=''WRIST_ON'')),9223372036854775807) as hi
      from changed where (j->>''user_id'')::uuid=$1 and (j->>''device_id'')::uuid=$2
        and (left(j->>''kind'',9)=''WRIST_OFF'' or left(j->>''kind'',8)=''WRIST_ON''))
      select distinct q.day,q.timezone_id from public.physiology_work_items q
      where q.user_id=$1 and q.device_id=$2
        and q.day<=(clock_timestamp() at time zone public.scoring_timezone_at($1,clock_timestamp()))::date
        and exists(select 1 from spans s cross join lateral (
          select start_ts,end_ts from public.scoring_day_segments($1,q.day)
          union all select start_ts,end_ts from public.scoring_day_segments($1,q.day-1)
        ) calendar where s.lo<calendar.end_ts and s.hi>calendar.start_ts)
      order by q.day,q.timezone_id'
      using owner_device.owner,owner_device.device
    loop
      perform public.scoring_enqueue_day(owner_device.owner,owner_device.device,affected.day,affected.timezone_id);
    end loop;
  end loop;
  return null;
end;
$$;

create or replace function public.physiology_required_revision(p_user uuid,p_device uuid,p_day date)
returns bigint language plpgsql stable security definer set search_path = pg_catalog,public as $$
declare revision bigint;
begin
  if auth.uid() is distinct from p_user and auth.role() is distinct from 'service_role' then
    raise exception 'owner required' using errcode = '42501';
  end if;
  select input_revision into revision from public.physiology_work_items
    where user_id=p_user and device_id=p_device and day=p_day;
  return revision;
end;
$$;

-- Preserve the RPC result shape for existing v2 clients; only its debt table changes.
create or replace function public.scoring_claim_one(p_lease_seconds integer default 300,p_max_failures integer default 8,
  p_user uuid default null,p_device uuid default null,p_day date default null)
returns setof public.scoring_work_items language plpgsql security definer set search_path='' as $$
begin
  return query with candidate as (
    select w.user_id,w.device_id,w.day from public.physiology_work_items w
    where w.done_at is null and w.next_attempt_at<=clock_timestamp()
      and (w.lease_expires_at is null or w.lease_expires_at<=clock_timestamp())
      and (w.failure_revision<>w.input_revision or w.consecutive_failures<p_max_failures)
      and (p_user is null or w.user_id=p_user) and (p_device is null or w.device_id=p_device)
      and (p_day is null or w.day=p_day)
    order by w.next_attempt_at,w.dirty_at,w.user_id,w.device_id,w.day
    for update skip locked limit 1
  ) update public.physiology_work_items w set claimed_at=clock_timestamp(),claimed_revision=w.input_revision,
    lease_token=gen_random_uuid(),run_id=gen_random_uuid(),status='running',
    lease_expires_at=clock_timestamp()+make_interval(secs=>greatest(1,least(p_lease_seconds,3600)))
  from candidate c where w.user_id=c.user_id and w.device_id=c.device_id and w.day=c.day returning w.*;
end $$;

create or replace function public.scoring_enqueue_dependency(p_user uuid,p_device uuid,p_day date)
returns boolean language plpgsql security definer set search_path='' as $$
begin
  perform public.scoring_lock_device(p_user,p_device);
  update public.physiology_work_items set
    input_revision=input_revision+1,failure_revision=input_revision+1,
    consecutive_failures=0,attempts=0,dirty_at=clock_timestamp(),done_at=null,
    claimed_at=null,claimed_revision=null,lease_token=null,run_id=null,lease_expires_at=null,
    status='pending',last_error=null,next_attempt_at=clock_timestamp()+interval '2 seconds'
  where user_id=p_user and device_id=p_device and day=p_day
    and exists(select 1 from public.scoring_day_segments(p_user,p_day) s
      where s.start_ts<=ceil(extract(epoch from clock_timestamp())));
  return found;
end $$;

create or replace function public.scoring_dirty_hrv_dependents(p_user uuid,p_device uuid,p_source_day date,
  p_measurements jsonb) returns void language plpgsql security definer set search_path='' as $$
declare target record;
begin
  for target in
    select q.day from public.physiology_work_items q cross join public.scoring_dependency_policy p
    cross join lateral (select min(s.start_ts) as day_lo from public.scoring_day_segments(p_user,q.day) s) calendar
    cross join lateral (select min(s.start_ts) as context_lo from (values(q.day-1),(q.day)) days(day)
      cross join lateral public.scoring_day_segments(p_user,days.day) s) receptive
    where q.user_id=p_user and q.device_id=p_device and q.day>p_source_day
      and exists(select 1 from public.scoring_day_segments(p_user,q.day) s
        where s.start_ts<=ceil(extract(epoch from clock_timestamp())))
      and exists(select 1 from jsonb_array_elements(p_measurements) m
        where (m->>'end')::numeric <= calendar.day_lo
          and (m->>'start')::numeric >= receptive.context_lo-p.hrv_history_seconds)
    order by q.day
  loop perform public.scoring_enqueue_dependency(p_user,p_device,target.day); end loop;
end $$;

create or replace function public.physiology_processing_metadata(p_user uuid,p_device uuid,p_day date,p_version text,p_revision bigint)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare required bigint; zone text; processing_status text; archive_status text; own jsonb; context jsonb; zones jsonb; legacy_current boolean:=false;
begin
  if auth.uid() is distinct from p_user and auth.role() is distinct from 'service_role' then
    raise exception 'owner required' using errcode='42501';
  end if;
  select q.input_revision,q.timezone_id,q.status into required,zone,processing_status
    from public.physiology_work_items q where q.user_id=p_user and q.device_id=p_device and q.day=p_day;
  if p_version='frwhoop-server-1' and p_revision is null then
    select q.status,exists(select 1 from public.legacy_scoring_receipts r
      where r.user_id=q.user_id and r.device_id=q.device_id and r.day=q.day
        and r.input_revision=q.input_revision and r.result_hash=encode(sha256(convert_to(
          public.scoring_legacy_snapshot(p_user,p_device,p_day)::text,'UTF8')),'hex'))
      into processing_status,legacy_current from public.scoring_work_items q
      where q.user_id=p_user and q.device_id=p_device and q.day=p_day;
    -- The unmodified retained binary cannot attest a fenced input revision.
    required:=null;
  end if;
  select coalesce(jsonb_agg(jsonb_build_array(s.start_ts,s.end_ts) order by s.start_ts),'[]'::jsonb),
      coalesce(jsonb_agg(to_jsonb(s.timezone_id) order by s.start_ts),'[]'::jsonb)
    into own,zones from public.scoring_day_segments(p_user,p_day) s;
  zone:=coalesce(zones->>0,zone,public.scoring_timezone_at(p_user,p_day::timestamp at time zone 'UTC'));
  select coalesce(jsonb_agg(jsonb_build_array(s.start_ts,s.end_ts) order by s.start_ts),'[]'::jsonb)
    into context from (values (p_day-1),(p_day)) days(calendar_day)
    cross join lateral public.scoring_day_segments(p_user,days.calendar_day) s;
  select o.status into archive_status from public.physiology_archive_outbox o
    where o.user_id=p_user and o.device_id=p_device and o.period_day=p_day
      and o.algorithm_version=p_version and o.input_revision=p_revision;
  return jsonb_build_object('required_revision',required,'timezone_id',zone,'timezone_ids',zones,
    'day_intervals',own,'context_intervals',context,'processing_status',processing_status,'archive_status',archive_status,
    'legacy_result_current',coalesce(legacy_current,false),'revision_protocol',
      case when p_version='frwhoop-server-1' and p_revision is null then 'legacy_unfenced' else 'fenced_v2' end);
end $$;

create or replace function public.server_scoring_for_day(p_user uuid, p_day date)
returns jsonb language plpgsql stable security invoker set search_path = pg_catalog, public as $$
declare
  feature_key text;
  device uuid;
  version text;
  device_count integer;
  result jsonb;
  daily jsonb := '{}'::jsonb;
  nights jsonb := '[]'::jsonb;
  measurements jsonb := '[]'::jsonb;
  sleep_overrides jsonb := '[]'::jsonb;
  features jsonb := '{}'::jsonb;
  current_revision bigint;
  result_revision bigint;
  is_stale boolean := false;
  feature_stale boolean;
  computed timestamptz;
  feature_computed timestamptz;
  key text;
  keys text[];
  selected_versions text[] := '{}'::text[];
  selected_devices uuid[] := '{}'::uuid[];
  processing jsonb;
  period_zone text;
  result_unavailable_reason text;
begin
  if auth.uid() is distinct from p_user and auth.role() is distinct from 'service_role' then
    raise exception 'owner required' using errcode = '42501';
  end if;
  for feature_key in select feature from public.physiology_feature_defaults order by feature loop
    select s.device_id, s.algorithm_version into device, version
      from public.physiology_source_selection s where s.user_id=p_user and s.feature=feature_key;
    if device is null then
      select count(*), (array_agg(id order by id))[1] into device_count,device
        from public.devices where user_id=p_user;
      if device_count <> 1 then
        features := features || jsonb_build_object(feature_key,
          jsonb_build_object('status','unavailable','reason','source_selection_required'));
        is_stale := true;
        continue;
      end if;
      select algorithm_version into version from public.physiology_feature_defaults where feature=feature_key;
    end if;
    if not exists(select 1 from public.physiology_feature_qualifications
      where algorithm_version=version and feature=feature_key and qualification in ('baseline','reference_qualified')) then
      features := features || jsonb_build_object(feature_key,
        jsonb_build_object('status','unavailable','reason','unqualified_version'));
      is_stale := true;
      continue;
    end if;
    result := null; result_revision := null; feature_computed := null;
    select payload,input_revision,computed_at into result,result_revision,feature_computed
      from public.server_physiology_results where user_id=p_user and device_id=device
        and period_day=p_day and algorithm_version=version
      order by input_revision desc limit 1;
    if result is null and version='frwhoop-server-1' then
      select jsonb_build_object('daily',to_jsonb(d),'nights',coalesce((
        select jsonb_agg(to_jsonb(n) order by n.start_at) from public.server_sleep_nights n
        where n.user_id=p_user and n.device_id=device and n.period_day=p_day and n.algorithm_version=version
      ),'[]'::jsonb)),d.computed_at into result,feature_computed
      from public.server_daily_scores d where d.user_id=p_user and d.source_device_id=device
        and d.day=p_day and d.algorithm_version=version;
    end if;
    -- Protected queue metadata is exposed through this owner-constrained helper, below.
    processing := public.physiology_processing_metadata(p_user,device,p_day,version,result_revision);
    current_revision := (processing->>'required_revision')::bigint;
    period_zone := processing->>'timezone_id';
    feature_stale := case when version='frwhoop-server-1' and result_revision is null
      then result is null or not coalesce((processing->>'legacy_result_current')::boolean,false)
      else result is null or coalesce(result_revision < current_revision,false)
        or (result_revision is null and current_revision is not null) end;
    is_stale := is_stale or feature_stale;
    selected_versions := array_append(selected_versions,version);
    selected_devices := array_append(selected_devices,device);
    if feature_computed is not null then computed := greatest(computed,feature_computed); end if;
    result_unavailable_reason := nullif(result->>'unavailable_reason','');
    features := features || jsonb_build_object(feature_key,jsonb_build_object(
      'status',case when result is null then 'unavailable' when feature_stale then 'stale'
        when result_unavailable_reason is not null then 'unavailable' else 'available' end,
      'reason',case when result is null then 'awaiting_result' when feature_stale then 'newer_input_pending'
        else result_unavailable_reason end,
      'device_id',device,'algorithm_version',version,'input_revision',result_revision,
      'required_revision',current_revision,'computed_at',feature_computed,
      'observed_through',result->'observed_through','publication_status',result->'publication_status',
      'manifest_hash',result->'manifest_hash','computation_mode',result->'computation_mode',
      'archive_status',processing->'archive_status','processing_status',processing->'processing_status',
      'revision_protocol',processing->'revision_protocol',
      'timezone_id',period_zone,'timezone_ids',processing->'timezone_ids',
      'day_intervals',processing->'day_intervals','context_intervals',processing->'context_intervals',
      'supports_boundary_overrides',feature_key='sleep' and version='frwhoop-physiology-2'));
    keys := case feature_key
      when 'hrv' then array['hrv_rmssd_ms','hrv_sdnn_ms','resting_hr_bpm','overnight_hr_bpm','hrv_summary']
      when 'respiration' then array['resp_rate_bpm','respiration_summary','respiration_unavailable_reason']
      else array['sleep_total_min','sleep_in_bed_min','sleep_awake_min','sleep_light_min','sleep_deep_min',
        'sleep_rem_min','sleep_efficiency','sleep_onset_at','wake_onset_at','sleep_unstaged_min',
        'state_unknown_min','off_body_min','main_sleep_group_id','opportunity_kind','disturbances'] end;
    foreach key in array keys loop
      daily := daily || jsonb_build_object(key,result->'daily'->key);
    end loop;
    measurements := measurements || coalesce((select jsonb_agg(m) from jsonb_array_elements(
      coalesce(result->'measurements','[]'::jsonb)) m where m->>'feature'=feature_key),'[]'::jsonb);
    if feature_key='sleep' then
      nights := coalesce(result->'nights','[]'::jsonb);
      -- Read durable edits immediately against event-time calendar ownership, including travel.
      sleep_overrides := public.physiology_owned_sleep_overrides(p_user,device,p_day);
    end if;
  end loop;
  return jsonb_build_object('schema_version',2,'user_id',p_user,'day',p_day,
    'algorithm_version',case when cardinality(array(select distinct unnest(selected_versions)))=1
      then selected_versions[1] else 'per_feature' end,
    'daily',case when computed is null then null else daily || jsonb_build_object('day',p_day,'computed_at',computed,
      'source_device_id',case when cardinality(array(select distinct unnest(selected_devices)))=1
        then selected_devices[1] else null end) end,
    'nights',nights,'features',features,'measurements',measurements,'sleep_overrides',sleep_overrides,
    'computed_at',computed,'stale',is_stale);
end;
$$;


-- Legacy and shadow workers also need separate liveness records.
create table public.physiology_service_heartbeats (like public.scoring_service_heartbeats including all);
insert into public.physiology_service_heartbeats(id,version) values(1,'frwhoop-physiology-2');
alter table public.physiology_service_heartbeats enable row level security;
create policy physiology_service_heartbeats_service on public.physiology_service_heartbeats
  for all to service_role using(true) with check(true);
grant all on public.physiology_service_heartbeats to service_role;

revoke all on function public.scoring_legacy_snapshot(uuid,uuid,date),public.scoring_legacy_queue_transition(),
  public.scoring_enqueue_legacy(uuid,uuid,date,text),public.physiology_enqueue_day(uuid,uuid,date,text,integer)
  from public,anon,authenticated;
grant execute on function public.scoring_legacy_snapshot(uuid,uuid,date),public.scoring_legacy_queue_transition(),
  public.scoring_enqueue_legacy(uuid,uuid,date,text),public.physiology_enqueue_day(uuid,uuid,date,text,integer)
  to service_role;

commit;
