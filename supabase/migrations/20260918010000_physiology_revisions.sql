-- Revisions are advanced in the ingest transaction, including corrections and deletions.
-- Publication must hold the same queue row lock until its output transaction commits.
alter table public.scoring_work_items
  add column input_revision bigint not null default 1,
  add column claimed_revision bigint,
  add column lease_token uuid,
  add column run_id uuid,
  add column lease_expires_at timestamptz,
  add column failure_revision bigint not null default 1,
  add column consecutive_failures integer not null default 0,
  add column next_attempt_at timestamptz not null default now(),
  add column status text not null default 'pending',
  add column timezone_id text not null default 'UTC',
  add constraint scoring_revision_positive check (input_revision > 0),
  add constraint scoring_failure_nonnegative check (consecutive_failures >= 0),
  add constraint scoring_status_check check (status in ('pending','running','waiting','retry','exhausted','done'));

create table public.scoring_timezone_history (
  user_id uuid not null references auth.users(id) on delete cascade,
  effective_at timestamptz not null,
  timezone_id text not null,
  provenance text not null,
  primary key (user_id,effective_at)
);
alter table public.scoring_timezone_history enable row level security;
create policy scoring_timezone_history_service on public.scoring_timezone_history for all to service_role
  using (true) with check (true);
create policy scoring_timezone_history_owner on public.scoring_timezone_history for select to authenticated
  using (user_id = (select auth.uid()));
grant select on public.scoring_timezone_history to authenticated;
grant all on public.scoring_timezone_history to service_role;

-- The pre-migration travel history is unavailable. Preserve this explicitly identified snapshot;
-- subsequent profile edits are effective prospectively, including for late-arriving records.
insert into public.scoring_timezone_history(user_id,effective_at,timezone_id,provenance)
select id,'-infinity',case when exists(select 1 from pg_timezone_names z where z.name=p.timezone)
  then p.timezone else 'UTC' end,'migration_profile_snapshot'
from public.profiles p;

create function public.scoring_record_timezone() returns trigger language plpgsql security definer
set search_path = '' as $$
begin
  if not exists(select 1 from pg_timezone_names where name=new.timezone) then
    raise exception 'invalid IANA timezone' using errcode='22023';
  end if;
  if tg_op='INSERT' then
    insert into public.scoring_timezone_history values(new.id,'-infinity',new.timezone,'initial_profile')
      on conflict(user_id,effective_at) do nothing;
  elsif new.timezone is distinct from old.timezone then
    insert into public.scoring_timezone_history values(new.id,clock_timestamp(),new.timezone,'profile_change');
  end if;
  return new;
end $$;
create trigger scoring_profile_timezone after insert or update of timezone on public.profiles
for each row execute function public.scoring_record_timezone();

create function public.scoring_timezone_at(p_user uuid,p_at timestamptz) returns text
language sql stable security definer set search_path='' as $$
  select coalesce((select timezone_id from public.scoring_timezone_history
    where user_id=p_user and effective_at<=p_at order by effective_at desc limit 1),'UTC')
$$;

create table public.scoring_dependency_policy (
  id integer primary key check(id=1),
  preceding_context_days integer not null check(preceding_context_days between 0 and 31),
  following_context_days integer not null check(following_context_days between 0 and 31)
);
-- A day reads the preceding local day and its full own day. Expand this policy before deploying
-- any model with a wider temporal receptive field; dirtying includes both sides of that field.
insert into public.scoring_dependency_policy values(1,1,0);
alter table public.scoring_dependency_policy enable row level security;
create policy scoring_dependency_policy_service on public.scoring_dependency_policy for all to service_role
  using(true) with check(true);
grant all on public.scoring_dependency_policy to service_role;

create function public.scoring_affected_days(p_user uuid,p_start bigint,p_end bigint)
returns table(day date,timezone_id text) language plpgsql stable security definer set search_path='' as $$
#variable_conflict use_column
begin
  return query with history as (
    select effective_at,timezone_id from public.scoring_timezone_history where user_id=p_user
    union all select '-infinity'::timestamptz,'UTC' where not exists(
      select 1 from public.scoring_timezone_history where user_id=p_user)
  ), segments as (
    select greatest(h.effective_at,to_timestamp(p_start)) as first_at,
      least(coalesce(lead(h.effective_at) over(order by h.effective_at),'infinity'),
        to_timestamp(greatest(p_start+1,p_end))) as last_at,h.timezone_id
    from history h
  ), local_spans as (
    select (first_at at time zone s.timezone_id)::date - p.following_context_days as first_day,
      ((last_at-interval '1 microsecond') at time zone s.timezone_id)::date + p.preceding_context_days as last_day,
      s.timezone_id
    from segments s cross join public.scoring_dependency_policy p where first_at<last_at
  )
  select distinct first_day + n,timezone_id from local_spans
  cross join lateral generate_series(0,last_day-first_day) n;
exception when datetime_field_overflow or numeric_value_out_of_range then
  -- Unrepresentable sensor clocks remain in raw projections; they cannot identify a calendar job.
  return;
end
$$;

create function public.scoring_enqueue_day(p_user uuid,p_device uuid,p_day date,p_timezone text,
  p_debounce_seconds integer default 2) returns bigint language plpgsql security definer set search_path='' as $$
declare v_revision bigint;
begin
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
    failure_revision=scoring_work_items.input_revision+1, consecutive_failures=0, attempts=0,
    dirty_at=clock_timestamp(),done_at=null,claimed_at=null,claimed_revision=null,
    lease_token=null,run_id=null,lease_expires_at=null,status='pending',last_error=null,
    next_attempt_at=clock_timestamp()+make_interval(secs=>greatest(0,p_debounce_seconds))
  returning input_revision into v_revision;
  return v_revision;
end $$;

create function public.scoring_dirty_span(p_user uuid,p_device uuid,p_start bigint,p_end bigint)
returns void language plpgsql security definer set search_path='' as $$
declare r record;
begin
  -- Device-less annotations apply to each registered device, never another owner's device.
  for r in select d.id,a.day,a.timezone_id from public.devices d
    cross join lateral public.scoring_affected_days(p_user,p_start,p_end) a
    where d.user_id=p_user and (p_device is null or d.id=p_device)
    order by d.id,a.day,a.timezone_id
  loop
    perform public.scoring_enqueue_day(p_user,r.id,r.day,r.timezone_id);
  end loop;
end $$;

-- Existing native motion counters are contextual inputs, not a new step algorithm.
create table public.noop_step_samples (
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null,
  source_id uuid not null,
  ts bigint not null,
  counter integer not null,
  "activityClass" integer,
  batch_id uuid not null,
  ingested_at timestamptz not null default now(),
  primary key(user_id,device_id,ts)
);
create index noop_step_samples_user_ts_idx on public.noop_step_samples(user_id,ts desc);
alter table public.noop_step_samples enable row level security;
create policy noop_step_samples_select_own on public.noop_step_samples for select to authenticated
  using(user_id=(select auth.uid()));
create policy noop_step_samples_service_write on public.noop_step_samples for all to service_role
  using(true) with check(true);
grant select on public.noop_step_samples to authenticated;
grant all on public.noop_step_samples to service_role;

create function public.scoring_dirty_projection() returns trigger language plpgsql security definer
set search_path='' as $$
declare q text; r record;
begin
  -- Transition tables coalesce a bulk ingest to one revision per affected device/day.
  -- Arrival metadata changes alone are replay, whereas any actual value/provenance change dirties.
  if tg_op='UPDATE' then
    q := '(select to_jsonb(n)-ARRAY[''ingested_at'',''updated_at'',''batch_id'',''replacement_id''] as j from new_rows n
      except select to_jsonb(o)-ARRAY[''ingested_at'',''updated_at'',''batch_id'',''replacement_id''] from old_rows o)
      union (select to_jsonb(o)-ARRAY[''ingested_at'',''updated_at'',''batch_id'',''replacement_id''] from old_rows o
      except select to_jsonb(n)-ARRAY[''ingested_at'',''updated_at'',''batch_id'',''replacement_id''] from new_rows n)';
  elsif tg_op='INSERT' then q := 'select to_jsonb(n) as j from new_rows n';
  else q := 'select to_jsonb(o) as j from old_rows o'; end if;
  for r in execute 'with changed as ('||q||'), spans as (
    select (j->>''user_id'')::uuid as owner,(j->>''device_id'')::uuid as device,
      coalesce((j->>''ts'')::bigint,(j->>''start_ts'')::bigint,
        extract(epoch from (j->>''start_at'')::timestamptz)::bigint) as first_ts,
      coalesce((j->>''end_ts'')::bigint,extract(epoch from (j->>''end_at'')::timestamptz)::bigint,
        case when j->>''ts'' is not null then least((j->>''ts'')::numeric+1,9223372036854775807)::bigint end,
        case when j->>''start_ts'' is not null then least((j->>''start_ts'')::numeric+1,9223372036854775807)::bigint end) as last_ts
    from changed
  ), coalesced as (
    select owner,device,min(first_ts) as first_ts,max(last_ts) as last_ts from spans
    where first_ts is not null group by owner,device,first_ts/3600
  ) select distinct s.owner,d.id as device,a.day,a.timezone_id
    from coalesced s join public.devices d on d.user_id=s.owner and (s.device is null or d.id=s.device)
    cross join lateral public.scoring_affected_days(s.owner,s.first_ts,s.last_ts) a
    where s.first_ts is not null order by s.owner,d.id,a.day,a.timezone_id'
  loop perform public.scoring_enqueue_day(r.owner,r.device,r.day,r.timezone_id); end loop;
  return null;
end $$;

do $$ declare t text; begin
  foreach t in array array['noop_hr_samples','noop_rr_intervals','noop_resp_samples','noop_gravity_samples',
    'noop_events','noop_step_samples','noop_sleep_state_samples','noop_event_labels','sessions','sleep_nights'] loop
    execute format('create trigger scoring_dirty_insert after insert on public.%I referencing new table as new_rows for each statement execute function public.scoring_dirty_projection()',t);
    execute format('create trigger scoring_dirty_update after update on public.%I referencing old table as old_rows new table as new_rows for each statement execute function public.scoring_dirty_projection()',t);
    execute format('create trigger scoring_dirty_delete after delete on public.%I referencing old table as old_rows for each statement execute function public.scoring_dirty_projection()',t);
  end loop;
end $$;

create function public.scoring_dirty_sleep_details() returns trigger language plpgsql security definer
set search_path='' as $$
declare r record; edits jsonb[] := array[]::jsonb[];
begin
  if tg_op='UPDATE' and to_jsonb(new)-ARRAY['updated_at','computed_at']=
    to_jsonb(old)-ARRAY['updated_at','computed_at'] then return new; end if;
  if tg_op<>'INSERT' then edits:=array_append(edits,to_jsonb(old)); end if;
  if tg_op<>'DELETE' then edits:=array_append(edits,to_jsonb(new)); end if;
  for r in select distinct s.user_id,d.id as device_id,a.day,a.timezone_id
    from unnest(edits) e
    join public.sessions s on s.id=(e->>'session_id')::uuid
    join public.devices d on d.user_id=s.user_id and (s.device_id is null or d.id=s.device_id)
    cross join lateral (values
      (s.start_at,s.end_at),
      (coalesce((e->>'user_start_at')::timestamptz,(e->>'original_start_at')::timestamptz,s.start_at),
       coalesce((e->>'user_end_at')::timestamptz,(e->>'original_end_at')::timestamptz,s.end_at))
    ) span(start_at,end_at)
    cross join lateral public.scoring_affected_days(s.user_id,
      extract(epoch from span.start_at)::bigint,extract(epoch from span.end_at)::bigint) a
    order by s.user_id,d.id,a.day,a.timezone_id
  loop
    perform public.scoring_enqueue_day(r.user_id,r.device_id,r.day,r.timezone_id);
  end loop;
  if tg_op='DELETE' then return old; end if;
  return new;
end $$;
create trigger scoring_sleep_details after insert or update or delete on public.sleep_details
for each row execute function public.scoring_dirty_sleep_details();

create function public.scoring_dirty_context() returns trigger language plpgsql security definer
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
    for r in select * from public.scoring_work_items where user_id=owner
      and (device is null or device_id=device) order by device_id,day loop
      perform public.scoring_enqueue_day(r.user_id,r.device_id,r.day,r.timezone_id);
    end loop;
  end if;
  return new;
end $$;
create trigger scoring_profile_context after update on public.profiles
for each row execute function public.scoring_dirty_context();
create trigger scoring_device_context after update on public.devices
for each row execute function public.scoring_dirty_context();

-- SHA verification alone is not decoding evidence. A waveform reader records both after fetching
-- and validating bytes, digest, native units/channels and the decoder's input contract.
alter table public.object_manifests add column decode_verified_at timestamptz,
  add column decoder_version text;

create function public.scoring_dirty_raw_object() returns trigger language plpgsql security definer
set search_path='' as $$
declare r record; ids uuid[]; was_available boolean; is_available boolean;
begin
  if tg_table_name='object_manifests' then
    if tg_op='UPDATE' and new.sha256_source is not distinct from old.sha256_source
      and new.sha256 is not distinct from old.sha256 and new.status is not distinct from old.status
      and new.decode_verified_at is not distinct from old.decode_verified_at
      and new.decoder_version is not distinct from old.decoder_version then return new; end if;
    was_available := old.sha256_source='server_verified' and old.decode_verified_at is not null
      and old.decoder_version is not null and old.status in ('ready','verified');
    is_available := case when tg_op='UPDATE' then new.sha256_source='server_verified'
      and new.decode_verified_at is not null and new.decoder_version is not null
      and new.status in ('ready','verified') else false end;
    ids := case when tg_op='DELETE' then array[old.id] else array[new.id] end;
    for r in select w.* from public.noop_signal_windows w where w.object_id=any(ids) loop
      if was_available or is_available then
        perform public.scoring_dirty_span(r.user_id,r.device_id,r.start_ts,r.end_ts);
      end if;
    end loop;
  else
    if tg_op='UPDATE' and to_jsonb(new)-'updated_at'=to_jsonb(old)-'updated_at' then return null; end if;
    if tg_op in ('UPDATE','DELETE') and exists(select 1 from public.object_manifests m where m.id=old.object_id
      and m.sha256_source='server_verified' and m.decode_verified_at is not null and m.decoder_version is not null
      and m.status in ('ready','verified')) then
      perform public.scoring_dirty_span(old.user_id,old.device_id,old.start_ts,old.end_ts);
    end if;
    if tg_op in ('INSERT','UPDATE') and exists(select 1 from public.object_manifests m where m.id=new.object_id
      and m.sha256_source='server_verified' and m.decode_verified_at is not null and m.decoder_version is not null
      and m.status in ('ready','verified')) then
      perform public.scoring_dirty_span(new.user_id,new.device_id,new.start_ts,new.end_ts);
    end if;
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end $$;
create trigger scoring_raw_availability before update or delete on public.object_manifests
for each row execute function public.scoring_dirty_raw_object();
create trigger scoring_window_availability after insert or update or delete on public.noop_signal_windows
for each row execute function public.scoring_dirty_raw_object();

-- Existing jobs are intentionally recomputed once under the new revision protocol.
update public.scoring_work_items set timezone_id=public.scoring_timezone_at(user_id,day::timestamp at time zone 'UTC'),
  done_at=null,claimed_at=null,attempts=0;

-- One migration-time catch-up covers existing rows missed by the retired watermark discovery.
-- Normal polling never scans signal history. Future changes are covered by the triggers above.
do $$ declare t text; r record; begin
  foreach t in array array['noop_hr_samples','noop_rr_intervals','noop_resp_samples','noop_gravity_samples',
    'noop_events','noop_step_samples','noop_sleep_state_samples'] loop
    for r in execute format('with spans as (
      select user_id,device_id,min(ts) as first_ts,
        least(max(ts)::numeric+1,9223372036854775807)::bigint as last_ts from public.%I
      group by user_id,device_id,ts/3600
    ) select distinct s.user_id,s.device_id,a.day,a.timezone_id
      from spans s join public.devices d on d.id=s.device_id and d.user_id=s.user_id
      cross join lateral public.scoring_affected_days(s.user_id,s.first_ts,s.last_ts) a
      order by s.user_id,s.device_id,a.day,a.timezone_id',t)
    loop perform public.scoring_enqueue_day(r.user_id,r.device_id,r.day,r.timezone_id); end loop;
  end loop;
end $$;

create function public.scoring_claim_one(p_lease_seconds integer default 300,p_max_failures integer default 8,
  p_user uuid default null,p_device uuid default null,p_day date default null)
returns setof public.scoring_work_items language plpgsql security definer set search_path='' as $$
begin
  return query with candidate as (
    select w.user_id,w.device_id,w.day from public.scoring_work_items w
    where w.done_at is null and w.next_attempt_at<=clock_timestamp()
      and (w.lease_expires_at is null or w.lease_expires_at<=clock_timestamp())
      and (w.failure_revision<>w.input_revision or w.consecutive_failures<p_max_failures)
      and (p_user is null or w.user_id=p_user) and (p_device is null or w.device_id=p_device)
      and (p_day is null or w.day=p_day)
    order by w.next_attempt_at,w.dirty_at,w.user_id,w.device_id,w.day
    for update skip locked limit 1
  ) update public.scoring_work_items w set claimed_at=clock_timestamp(),claimed_revision=w.input_revision,
    lease_token=gen_random_uuid(),run_id=gen_random_uuid(),status='running',
    lease_expires_at=clock_timestamp()+make_interval(secs=>greatest(1,least(p_lease_seconds,3600)))
  from candidate c where w.user_id=c.user_id and w.device_id=c.device_id and w.day=c.day returning w.*;
end $$;

create function public.scoring_begin_publication(p_user uuid,p_device uuid,p_day date,p_revision bigint,
  p_lease_token uuid,p_run_id uuid) returns void language plpgsql security definer set search_path='' as $$
declare w public.scoring_work_items%rowtype;
begin
  select * into w from public.scoring_work_items q where q.user_id=p_user and q.device_id=p_device
    and q.day=p_day for update;
  -- Check the clock after obtaining the lock: a waiter may have expired while blocked.
  if not found or w.input_revision is distinct from p_revision or w.claimed_revision is distinct from p_revision
    or w.lease_token is distinct from p_lease_token or w.run_id is distinct from p_run_id
    or w.lease_token is null or w.run_id is null or w.lease_expires_at is null
    or w.lease_expires_at<=clock_timestamp() or w.status<>'running' then
    raise exception 'stale scoring lease or input revision' using errcode='40001';
  end if;
end $$;

create function public.scoring_renew_lease(p_user uuid,p_device uuid,p_day date,p_revision bigint,
  p_lease_token uuid,p_run_id uuid,p_lease_seconds integer default 300) returns boolean
language plpgsql security definer set search_path='' as $$
begin
  begin
    perform public.scoring_begin_publication(p_user,p_device,p_day,p_revision,p_lease_token,p_run_id);
  exception when serialization_failure then return false; end;
  update public.scoring_work_items set lease_expires_at=clock_timestamp()+make_interval(secs=>greatest(1,least(p_lease_seconds,3600)))
  where user_id=p_user and device_id=p_device and day=p_day;
  return found;
end $$;

create function public.scoring_finish_work(p_user uuid,p_device uuid,p_day date,p_revision bigint,
  p_lease_token uuid,p_run_id uuid,p_outcome text,p_duration_ms integer default null,p_error text default null)
returns boolean language plpgsql security definer set search_path='' as $$
declare failures integer;
begin
  if p_outcome not in ('done','waiting','failed') then raise exception 'invalid outcome'; end if;
  begin
    perform public.scoring_begin_publication(p_user,p_device,p_day,p_revision,p_lease_token,p_run_id);
  exception when serialization_failure then return false; end;
  select case when failure_revision=p_revision then consecutive_failures else 0 end into failures
    from public.scoring_work_items where user_id=p_user and device_id=p_device and day=p_day;
  if p_outcome='failed' then failures:=failures+1;
  elsif p_outcome='done' then failures:=0; end if;
  update public.scoring_work_items set done_at=case when p_outcome='done' then clock_timestamp() end,
    claimed_at=null,claimed_revision=null,lease_token=null,run_id=null,lease_expires_at=null,
    consecutive_failures=failures,failure_revision=p_revision,attempts=failures,
    status=case when p_outcome='failed' then case when failures>=8 then 'exhausted' else 'retry' end else p_outcome end,
    next_attempt_at=clock_timestamp()+make_interval(secs=>case when p_outcome='failed'
      then least(3600,5*power(2,least(failures-1,10))) when p_outcome='waiting' then 300 else 0 end),
    last_error=case when p_outcome='done' then null else left(p_error,2000) end,last_duration_ms=p_duration_ms
  where user_id=p_user and device_id=p_device and day=p_day;
  return true;
end $$;

create index scoring_work_items_runnable on public.scoring_work_items(next_attempt_at,dirty_at)
  where done_at is null;

do $$ declare r record; begin
  for r in select oid::regprocedure as signature from pg_proc where pronamespace='public'::regnamespace
    and proname in ('scoring_record_timezone','scoring_timezone_at','scoring_affected_days','scoring_enqueue_day',
      'scoring_dirty_span','scoring_dirty_projection','scoring_dirty_raw_object','scoring_claim_one',
      'scoring_dirty_sleep_details','scoring_dirty_context','scoring_begin_publication','scoring_renew_lease','scoring_finish_work') loop
    execute format('revoke all on function %s from public,anon,authenticated',r.signature);
    execute format('grant execute on function %s to service_role',r.signature);
  end loop;
end $$;
