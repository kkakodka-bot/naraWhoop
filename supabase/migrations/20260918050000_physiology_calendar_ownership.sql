-- Freeze timezone history by event time while allowing one local date to own more than one
-- UTC interval. A queue row's first observed timezone is metadata, not a calendar boundary.
create function public.scoring_day_segments(p_user uuid,p_day date)
returns table(start_ts bigint,end_ts bigint,timezone_id text)
language sql stable security definer set search_path='' as $$
  with history as (
    select h.effective_at,h.timezone_id from public.scoring_timezone_history h where h.user_id=p_user
    union all select '-infinity'::timestamptz,'UTC' where not exists(
      select 1 from public.scoring_timezone_history where user_id=p_user)
  ), segments as (
    select h.effective_at,lead(h.effective_at,1,'infinity') over(order by h.effective_at) as until_at,
      h.timezone_id from history h
  ), intersections as (
    select greatest(effective_at,p_day::timestamp at time zone s.timezone_id) as lo,
      least(until_at,(p_day+1)::timestamp at time zone s.timezone_id) as hi,s.timezone_id
    from segments s
  ) select ceil(extract(epoch from lo))::bigint,ceil(extract(epoch from hi))::bigint,timezone_id
    from intersections where lo<hi and ceil(extract(epoch from lo))<ceil(extract(epoch from hi))
    order by lo,hi,timezone_id
$$;
revoke all on function public.scoring_day_segments(uuid,date) from public,anon,authenticated;
grant execute on function public.scoring_day_segments(uuid,date) to service_role;

-- Serialize before reading timezone history. Otherwise a waiting ingest could retain calendar
-- keys computed before a timezone change, then commit without dirtying the newly owned date.
create or replace function public.scoring_dirty_span(p_user uuid,p_device uuid,p_start bigint,p_end bigint)
returns void language plpgsql security definer set search_path='' as $$
declare r record;
begin
  for r in select id from public.devices where user_id=p_user and (p_device is null or id=p_device) order by id loop
    perform public.scoring_lock_device(p_user,r.id);
  end loop;
  for r in select d.id,a.day,a.timezone_id from public.devices d
    cross join lateral public.scoring_affected_days(p_user,p_start,p_end) a
    where d.user_id=p_user and (p_device is null or d.id=p_device) order by d.id,a.day,a.timezone_id
  loop perform public.scoring_enqueue_day(p_user,r.id,r.day,r.timezone_id); end loop;
end $$;

create or replace function public.scoring_dirty_projection() returns trigger language plpgsql security definer
set search_path='' as $$
declare q text; r record;
begin
  if tg_op='UPDATE' then
    q := '(select to_jsonb(n)-ARRAY[''ingested_at'',''updated_at'',''batch_id'',''replacement_id''] as j from new_rows n
      except select to_jsonb(o)-ARRAY[''ingested_at'',''updated_at'',''batch_id'',''replacement_id''] from old_rows o)
      union (select to_jsonb(o)-ARRAY[''ingested_at'',''updated_at'',''batch_id'',''replacement_id''] from old_rows o
      except select to_jsonb(n)-ARRAY[''ingested_at'',''updated_at'',''batch_id'',''replacement_id''] from new_rows n)';
  elsif tg_op='INSERT' then q := 'select to_jsonb(n) as j from new_rows n';
  else q := 'select to_jsonb(o) as j from old_rows o'; end if;
  for r in execute 'with changed as ('||q||')
    select distinct d.user_id,d.id from changed c join public.devices d
      on d.user_id=(c.j->>''user_id'')::uuid
      and (c.j->>''device_id'' is null or d.id=(c.j->>''device_id'')::uuid)
      order by d.user_id,d.id'
  loop perform public.scoring_lock_device(r.user_id,r.id); end loop;
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
    for q in select * from public.scoring_work_items where user_id=new.id and (
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

-- A precreated queue row may retain its original display timezone after travel. The HRV
-- reader's UTC-duration history cutoff is the first actually owned second, not that zone.
create or replace function public.scoring_dirty_hrv_dependents(p_user uuid,p_device uuid,p_source_day date,
  p_measurements jsonb) returns void language plpgsql security definer set search_path='' as $$
declare target record;
begin
  for target in
    select q.day from public.scoring_work_items q cross join public.scoring_dependency_policy p
    cross join lateral (select min(s.start_ts) as day_lo from public.scoring_day_segments(p_user,q.day) s) calendar
    cross join lateral (select min(s.start_ts) as context_lo from (values(q.day-1),(q.day)) days(day)
      cross join lateral public.scoring_day_segments(p_user,days.day) s) receptive
    where q.user_id=p_user and q.device_id=p_device and q.day>p_source_day
      and q.day <= (clock_timestamp() at time zone q.timezone_id)::date
      and exists(select 1 from jsonb_array_elements(p_measurements) m
        where (m->>'end')::numeric <= calendar.day_lo
          and (m->>'start')::numeric >= receptive.context_lo-p.hrv_history_seconds)
    order by q.day
  loop perform public.scoring_enqueue_dependency(p_user,p_device,target.day); end loop;
end $$;

create function public.physiology_owned_sleep_overrides(p_user uuid,p_device uuid,p_day date)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare edits jsonb;
begin
  if auth.uid() is distinct from p_user and auth.role() is distinct from 'service_role' then
    raise exception 'owner required' using errcode='42501';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',o.id,'device_id',o.device_id,'revision',o.revision,
    'original_start',extract(epoch from o.original_start_at)::bigint,'original_end',extract(epoch from o.original_end_at)::bigint,
    'start',extract(epoch from o.start_at)::bigint,'end',extract(epoch from o.end_at)::bigint,
    'tombstone',o.tombstone,'boundary_provenance','user_boundary:'||o.id::text) order by o.updated_at,o.id),'[]'::jsonb)
    into edits from public.physiology_sleep_overrides o where o.user_id=p_user and o.device_id=p_device and exists(
      select 1 from (values (p_day-1),(p_day)) days(calendar_day)
      cross join lateral public.scoring_day_segments(p_user,days.calendar_day) s
      where (o.original_start_at<to_timestamp(s.end_ts) and o.original_end_at>to_timestamp(s.start_ts)) or
        (o.start_at<to_timestamp(s.end_ts) and o.end_at>to_timestamp(s.start_ts)));
  return edits;
end $$;
revoke all on function public.physiology_owned_sleep_overrides(uuid,uuid,date) from public,anon;
grant execute on function public.physiology_owned_sleep_overrides(uuid,uuid,date) to authenticated,service_role;

create or replace function public.physiology_processing_metadata(p_user uuid,p_device uuid,p_day date,p_version text,p_revision bigint)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare required bigint; zone text; processing_status text; archive_status text; own jsonb; context jsonb; zones jsonb;
begin
  if auth.uid() is distinct from p_user and auth.role() is distinct from 'service_role' then
    raise exception 'owner required' using errcode='42501';
  end if;
  select q.input_revision,q.timezone_id,q.status into required,zone,processing_status
    from public.scoring_work_items q where q.user_id=p_user and q.device_id=p_device and q.day=p_day;
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
    'day_intervals',own,'context_intervals',context,'processing_status',processing_status,'archive_status',archive_status);
end $$;
