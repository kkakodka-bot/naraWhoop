-- Requires the separately built, token-aware v1 transport patch. Its numerical kernel
-- remains pinned to 5caa31689da0023e111beb36850d3f81d67e1be2. Unpatched workers fail closed.
-- Stop unpatched baseline workers before this migration, then start the reviewed patched
-- baseline image. Existing measurements and archives remain readable throughout.
begin;
lock table public.scoring_work_items in share row exclusive mode;
drop trigger legacy_scoring_queue_transition on public.scoring_work_items;
-- A pre-protocol claim has no trustworthy baseline lease identity. Revoke that authority;
-- retain all results/receipts and requeue baseline work independently of live v2 claims.
update public.scoring_work_items set input_revision=input_revision+1,
  measurement_revision=measurement_revision+1,failure_revision=input_revision+1,
  done_at=null,claimed_at=null,claimed_revision=null,lease_token=null,run_id=null,
  lease_expires_at=null,attempts=0,consecutive_failures=0,status='pending',
  next_attempt_at=clock_timestamp(),last_error=null;

create function public.scoring_legacy_write_guard() returns trigger
language plpgsql set search_path='' as $$
begin
  if current_setting('physiology.legacy_queue_write',true) is distinct from txid_current()::text then
    raise exception 'token-aware baseline worker required' using errcode='42501';
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end $$;
create trigger scoring_legacy_write_guard before insert or update on public.scoring_work_items
  for each row execute function public.scoring_legacy_write_guard();

create function public.scoring_enqueue_legacy_fenced(p_user uuid,p_device uuid,p_day date,p_timezone text,
  p_debounce_seconds integer default 0) returns bigint
language plpgsql security definer set search_path='' as $$
declare revision bigint; previous text:=current_setting('physiology.legacy_queue_write',true);
begin
  perform public.scoring_lock_device(p_user,p_device);
  if not exists(select 1 from public.devices where id=p_device and user_id=p_user) then
    raise exception 'device does not belong to user' using errcode='23503';
  end if;
  if not exists(select 1 from pg_timezone_names where name=p_timezone) then
    raise exception 'invalid timezone' using errcode='22023';
  end if;
  perform set_config('physiology.legacy_queue_write',txid_current()::text,true);
  insert into public.scoring_work_items(user_id,device_id,day,timezone_id,dirty_at,next_attempt_at)
    values(p_user,p_device,p_day,p_timezone,clock_timestamp(),clock_timestamp()+make_interval(secs=>greatest(0,p_debounce_seconds)))
  on conflict(user_id,device_id,day) do update set input_revision=scoring_work_items.input_revision+1,
    measurement_revision=scoring_work_items.measurement_revision+1,failure_revision=scoring_work_items.input_revision+1,
    dirty_at=clock_timestamp(),done_at=null,claimed_at=null,claimed_revision=null,lease_token=null,run_id=null,
    lease_expires_at=null,attempts=0,consecutive_failures=0,status='pending',last_error=null,
    next_attempt_at=clock_timestamp()+make_interval(secs=>greatest(0,p_debounce_seconds))
  returning input_revision into revision;
  perform set_config('physiology.legacy_queue_write',coalesce(previous,''),true);
  return revision;
end $$;

create or replace function public.scoring_enqueue_legacy(p_user uuid,p_device uuid,p_day date,p_timezone text)
returns void language plpgsql security definer set search_path='' as $$
begin
  perform public.scoring_enqueue_legacy_fenced(p_user,p_device,p_day,p_timezone,2);
end $$;


create or replace function public.scoring_enqueue_day(p_user uuid,p_device uuid,p_day date,p_timezone text,
  p_debounce_seconds integer default 2) returns bigint language plpgsql security definer set search_path='' as $$
declare revision bigint;
begin
  revision:=public.physiology_enqueue_day(p_user,p_device,p_day,p_timezone,p_debounce_seconds);
  perform public.scoring_enqueue_legacy_fenced(p_user,p_device,p_day,p_timezone,p_debounce_seconds);
  return revision;
end $$;

create function public.scoring_legacy_begin_publication(p_user uuid,p_device uuid,p_day date,p_revision bigint,
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

create function public.scoring_legacy_claim_one(p_lease_seconds integer default 300,p_max_failures integer default 8,
  p_user uuid default null,p_device uuid default null,p_day date default null)
returns setof public.scoring_work_items language plpgsql security definer set search_path='' as $$
declare previous text:=current_setting('physiology.legacy_queue_write',true);
begin
  perform set_config('physiology.legacy_queue_write',txid_current()::text,true);
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
  perform set_config('physiology.legacy_queue_write',coalesce(previous,''),true);
end $$;

create function public.scoring_legacy_renew_lease(p_user uuid,p_device uuid,p_day date,p_revision bigint,
  p_lease_token uuid,p_run_id uuid,p_lease_seconds integer default 300) returns boolean
language plpgsql security definer set search_path='' as $$
declare previous text:=current_setting('physiology.legacy_queue_write',true);
begin
  begin
    perform public.scoring_legacy_begin_publication(p_user,p_device,p_day,p_revision,p_lease_token,p_run_id);
  exception when serialization_failure then return false; end;
  perform set_config('physiology.legacy_queue_write',txid_current()::text,true);
  update public.scoring_work_items set lease_expires_at=clock_timestamp()+make_interval(secs=>greatest(1,least(p_lease_seconds,3600)))
  where user_id=p_user and device_id=p_device and day=p_day;
  perform set_config('physiology.legacy_queue_write',coalesce(previous,''),true);
  return true;
end $$;

create function public.scoring_legacy_finish_work(p_user uuid,p_device uuid,p_day date,p_revision bigint,
  p_lease_token uuid,p_run_id uuid,p_outcome text,p_duration_ms integer default null,p_error text default null)
returns boolean language plpgsql security definer set search_path='' as $$
declare failures integer; previous text:=current_setting('physiology.legacy_queue_write',true);
begin
  if p_outcome not in ('done','waiting','failed') then raise exception 'invalid outcome'; end if;
  begin
    perform public.scoring_legacy_begin_publication(p_user,p_device,p_day,p_revision,p_lease_token,p_run_id);
  exception when serialization_failure then return false; end;
  select case when failure_revision=p_revision then consecutive_failures else 0 end into failures
    from public.scoring_work_items where user_id=p_user and device_id=p_device and day=p_day;
  if p_outcome='failed' then failures:=failures+1;
  elsif p_outcome='done' then failures:=0; end if;
  perform set_config('physiology.legacy_queue_write',txid_current()::text,true);
  update public.scoring_work_items set done_at=case when p_outcome='done' then clock_timestamp() end,
    claimed_at=null,claimed_revision=null,lease_token=null,run_id=null,lease_expires_at=null,
    consecutive_failures=failures,failure_revision=p_revision,attempts=failures,
    status=case when p_outcome='failed' then case when failures>=8 then 'exhausted' else 'retry' end else p_outcome end,
    next_attempt_at=clock_timestamp()+make_interval(secs=>case when p_outcome='failed'
      then least(3600,5*power(2,least(failures-1,10))) when p_outcome='waiting' then 300 else 0 end),
    last_error=case when p_outcome='done' then null else left(p_error,2000) end,last_duration_ms=p_duration_ms
  where user_id=p_user and device_id=p_device and day=p_day;
  perform set_config('physiology.legacy_queue_write',coalesce(previous,''),true);
  return true;
end $$;

create or replace function public.scoring_capture_measurement_revision() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  -- engine_publish_physiology holds this row from scoring_begin_publication through commit.
  perform public.scoring_lock_device(new.user_id,new.device_id);
  if new.algorithm_version='frwhoop-server-1' then
    select q.measurement_revision into new.measurement_revision from public.scoring_work_items q
      where q.user_id=new.user_id and q.device_id=new.device_id and q.day=new.period_day
        and q.input_revision=new.input_revision for update;
  else
    select q.measurement_revision into new.measurement_revision from public.physiology_work_items q
      where q.user_id=new.user_id and q.device_id=new.device_id and q.day=new.period_day
        and q.input_revision=new.input_revision for update;
  end if;
  if new.measurement_revision is null then
    raise exception 'measurement revision is no longer current' using errcode='40001';
  end if;
  return new;
end $$;

-- Keep the original baseline serialization/arithmetic SQL, but remove its unfenced entry.
alter function public.engine_ingest_scored(text,jsonb) rename to engine_ingest_scored_legacy_internal;
revoke all on function public.engine_ingest_scored_legacy_internal(text,jsonb) from public,anon,authenticated,service_role;
create function public.engine_ingest_scored(p_secret text,p_payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
  raise exception 'token-aware baseline publication required' using errcode='42501';
end $$;
revoke all on function public.engine_ingest_scored(text,jsonb) from public,anon,authenticated;
grant execute on function public.engine_ingest_scored(text,jsonb) to service_role;

create function public.engine_publish_legacy_fenced(p_secret text,p_payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare u uuid:=(p_payload->>'user_id')::uuid; d uuid:=(p_payload->>'device_id')::uuid;
  period date:=(p_payload->>'day')::date; revision bigint:=(p_payload->>'input_revision')::bigint;
  token uuid:=(p_payload->>'lease_token')::uuid; run uuid:=(p_payload->>'run_id')::uuid;
  item jsonb; stored jsonb; manifest text; content_hash text;
begin
  perform internal.assert_ingest_secret(p_secret);
  if u is null or d is null or period is null or revision is null or token is null or run is null
      or p_payload->>'algorithm_version' is distinct from 'frwhoop-server-1' then
    raise exception 'baseline publication identity required' using errcode='22023';
  end if;
  perform public.scoring_legacy_begin_publication(u,d,period,revision,token,run);
  if not exists(select 1 from public.devices where id=d and user_id=u) then
    raise exception 'device owner mismatch' using errcode='42501';
  end if;
  if jsonb_typeof(p_payload->'daily_metrics') is distinct from 'array'
      or jsonb_array_length(p_payload->'daily_metrics')<>1
      or jsonb_typeof(p_payload->'sleep_nights') is distinct from 'array' then
    raise exception 'one baseline day and episode array required' using errcode='22023';
  end if;
  item:=p_payload->'daily_metrics'->0;
  if item->>'source_device_id' is distinct from d::text or item->>'day' is distinct from period::text
      or item->>'computed_at' is null then
    raise exception 'baseline daily owner mismatch' using errcode='22023';
  end if;
  for item in select value from jsonb_array_elements(p_payload->'sleep_nights') loop
    if item->>'device_id' is distinct from d::text or item->>'period_day' is distinct from period::text
        or item->>'start_at' is null or item->>'end_at' is null
        or not ((item->>'end_at')::timestamptz>(item->>'start_at')::timestamptz) then
      raise exception 'baseline episode owner mismatch' using errcode='22023';
    end if;
  end loop;
  -- Same revision retries retain the first immutable baseline result and archive object.
  if exists(select 1 from public.server_physiology_results where user_id=u and device_id=d
      and period_day=period and algorithm_version='frwhoop-server-1' and input_revision=revision) then
    return jsonb_build_object('ok',true,'input_revision',revision);
  end if;
  perform public.engine_ingest_scored_legacy_internal(p_secret,p_payload);
  select manifest_hash into manifest from public.physiology_algorithm_versions where algorithm_version='frwhoop-server-1';
  -- The legacy upsert table retains prior start keys for rollback. Only this publication's
  -- complete episode set belongs in the immutable current result, including an empty set.
  stored:=public.scoring_legacy_snapshot(u,d,period)||jsonb_build_object(
    'nights',coalesce((select jsonb_agg(to_jsonb(n) order by n.start_at)
      from public.server_sleep_nights n where n.user_id=u and n.device_id=d and n.period_day=period
        and n.algorithm_version='frwhoop-server-1' and exists(
          select 1 from jsonb_array_elements(p_payload->'sleep_nights') e
          where (e->>'start_at')::timestamptz=n.start_at)),'[]'::jsonb),
    'schema_version',2,'user_id',u,'device_id',d,'day',period,'algorithm_version','frwhoop-server-1',
    'input_revision',revision,'run_id',run,'manifest_hash',manifest,'measurements','[]'::jsonb,
    'computed_at',p_payload#>'{daily_metrics,0,computed_at}','publication_status','provisional',
    'observed_through',null,'computation_mode','retrospective','revision_protocol','fenced_v1');
  content_hash:=encode(sha256(convert_to(stored::text,'UTF8')),'hex');
  insert into public.server_physiology_results(user_id,device_id,period_day,algorithm_version,input_revision,
    run_id,manifest_hash,payload,payload_hash,observed_through,computed_at,publication_status)
  values(u,d,period,'frwhoop-server-1',revision,run,manifest,stored,content_hash,null,
    (stored->>'computed_at')::timestamptz,'provisional');
  insert into public.physiology_archive_outbox(user_id,device_id,period_day,algorithm_version,input_revision,object_key)
  values(u,d,period,'frwhoop-server-1',revision,
    format('v3/derived/users/%s/devices/%s/days/%s/frwhoop-server-1/revisions/%s/%s.json.zst',u,d,period,revision,content_hash));
  return jsonb_build_object('ok',true,'input_revision',revision,'payload_hash',content_hash);
end $$;


create or replace function public.engine_publish_physiology(p_secret text, p_payload jsonb)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  u uuid := (p_payload->>'user_id')::uuid;
  d uuid := (p_payload->>'device_id')::uuid;
  day_key date := (p_payload->>'day')::date;
  version text := p_payload->>'algorithm_version';
  revision bigint := (p_payload->>'input_revision')::bigint;
  token uuid := (p_payload->>'lease_token')::uuid;
  run uuid := (p_payload->>'run_id')::uuid;
  manifest text;
  stored jsonb;
  content_hash text;
  item jsonb;
begin
  perform internal.assert_ingest_secret(p_secret);
  if version is distinct from 'frwhoop-physiology-2' then
    raise exception 'shadow worker algorithm identity mismatch' using errcode='22023';
  end if;
  if u is null or d is null or day_key is null or revision is null or token is null or run is null then
    raise exception 'publication identity required' using errcode = '22023';
  end if;
  perform public.scoring_begin_publication(u, d, day_key, revision, token, run);
  if not exists(select 1 from public.devices where id = d and user_id = u) then
    raise exception 'device owner mismatch' using errcode = '42501';
  end if;
  select manifest_hash into manifest from public.physiology_algorithm_versions where algorithm_version = version;
  if manifest is null then raise exception 'unregistered algorithm version'; end if;
  if p_payload->>'schema_version' is distinct from '2'
      or jsonb_typeof(p_payload->'daily') is distinct from 'object'
      or jsonb_typeof(p_payload->'nights') is distinct from 'array'
      or jsonb_typeof(p_payload->'measurements') is distinct from 'array'
      or p_payload#>>'{daily,source_device_id}' is distinct from d::text
      or p_payload#>>'{daily,day}' is distinct from day_key::text
      or p_payload->>'computed_at' is null then
    raise exception 'invalid canonical result' using errcode = '22023';
  end if;
  for item in select value from jsonb_array_elements(p_payload->'nights') loop
    if item->>'device_id' is distinct from d::text
        or item->>'period_day' is distinct from day_key::text
        or item->>'start_at' is null or item->>'end_at' is null
        or not ((item->>'end_at')::timestamptz > (item->>'start_at')::timestamptz)
        or (item->>'end_at')::timestamptz-(item->>'start_at')::timestamptz>interval '48 hours' then
      raise exception 'invalid episode ownership or bounds' using errcode = '22023';
    end if;
  end loop;
  for item in select value from jsonb_array_elements(p_payload->'measurements') loop
    if item->>'user_id' is distinct from u::text or item->>'device_id' is distinct from d::text
        or item->>'input_revision' is distinct from revision::text
        or coalesce(item->>'feature','') not in ('hrv','respiration')
        or item->>'algorithm_version' is null or item->>'quality_version' is null
        or jsonb_typeof(item->'start') is distinct from 'number'
        or jsonb_typeof(item->'end') is distinct from 'number'
        or (item->>'end')::numeric<=(item->>'start')::numeric then
      raise exception 'invalid measurement ownership or provenance' using errcode='22023';
    end if;
  end loop;
  if exists(select 1 from (
      select (n->>'start_at')::timestamptz as lo,
        lag((n->>'end_at')::timestamptz) over(order by (n->>'start_at')::timestamptz) as previous_hi
      from jsonb_array_elements(p_payload->'nights') n) bounds where lo<previous_hi) then
    raise exception 'overlapping generated episodes' using errcode='22023';
  end if;
  -- The lease is a write capability, not part of an archived/user-visible result.
  stored := (p_payload - 'lease_token') || jsonb_build_object('manifest_hash', manifest);
  content_hash := encode(sha256(convert_to(stored::text, 'UTF8')), 'hex');
  insert into public.server_physiology_results
    (user_id,device_id,period_day,algorithm_version,input_revision,run_id,manifest_hash,payload,payload_hash,
      observed_through,computed_at,publication_status) values (
    u, d, day_key, version, revision, run, manifest, stored, content_hash,
    (stored->>'observed_through')::timestamptz, (stored->>'computed_at')::timestamptz,
    coalesce(stored->>'publication_status', 'provisional')
  ) on conflict (user_id, device_id, period_day, algorithm_version, input_revision) do nothing;
  -- A replay of an already committed revision archives the original committed snapshot.
  select payload_hash into content_hash from public.server_physiology_results
    where user_id = u and device_id = d and period_day = day_key
      and algorithm_version = version and input_revision = revision;
  insert into public.physiology_archive_outbox
    (user_id, device_id, period_day, algorithm_version, input_revision, object_key)
  values (u, d, day_key, version, revision,
    format('v3/derived/users/%s/devices/%s/days/%s/%s/revisions/%s/%s.json.zst',
      u, d, day_key, version, revision, content_hash))
  on conflict (user_id, device_id, period_day, algorithm_version, input_revision) do nothing;
  return jsonb_build_object('ok', true, 'input_revision', revision, 'payload_hash', content_hash);
end;
$$;

create or replace function public.physiology_processing_metadata(p_user uuid,p_device uuid,p_day date,p_version text,p_revision bigint)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare required bigint; zone text; processing_status text; archive_status text; own jsonb; context jsonb; zones jsonb; legacy_current boolean:=false;
begin
  if auth.uid() is distinct from p_user and auth.role() is distinct from 'service_role' then
    raise exception 'owner required' using errcode='42501';
  end if;
  select q.input_revision,q.timezone_id,q.status into required,zone,processing_status
    from public.physiology_work_items q where q.user_id=p_user and q.device_id=p_device and q.day=p_day;
  if p_version='frwhoop-server-1' then
    select q.input_revision,q.status into required,processing_status from public.scoring_work_items q
      where q.user_id=p_user and q.device_id=p_device and q.day=p_day;
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
      case when p_version='frwhoop-server-1' and p_revision is null then 'legacy_unfenced'
        when p_version='frwhoop-server-1' then 'fenced_v1' else 'fenced_v2' end);
end $$;


do $$ declare f record; begin
  for f in select p.oid::regprocedure as signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('scoring_legacy_write_guard','scoring_enqueue_legacy_fenced',
      'scoring_legacy_begin_publication','scoring_legacy_claim_one','scoring_legacy_renew_lease',
      'scoring_legacy_finish_work','engine_publish_legacy_fenced') loop
    execute format('revoke all on function %s from public,anon,authenticated',f.signature);
    execute format('grant execute on function %s to service_role',f.signature);
  end loop;
end $$;
commit;
