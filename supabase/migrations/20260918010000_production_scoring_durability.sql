-- W3: additive queue, immutable device snapshots and independent archive debt.
-- Legacy RPC signatures/tables remain available. No production data is reassigned.
create table public.scoring_algorithms_v2 (
  algorithm_version text primary key check (algorithm_version ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$'),
  enabled boolean not null default true,
  active boolean not null default false,
  created_at timestamptz not null default clock_timestamp()
);
create unique index scoring_one_active_algorithm_v2 on public.scoring_algorithms_v2(active) where active;
insert into public.scoring_algorithms_v2 values ('frwhoop-server-1', true, true, clock_timestamp());

create table public.scoring_jobs_v2 (
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null references public.devices(id) on delete cascade,
  day date not null,
  algorithm_version text not null references public.scoring_algorithms_v2,
  input_revision bigint not null default 1 check (input_revision > 0),
  completed_revision bigint not null default 0,
  lease_token uuid,
  lease_until timestamptz,
  consecutive_failures integer not null default 0,
  dead_letter boolean not null default false,
  not_before timestamptz not null default clock_timestamp(),
  dirty_at timestamptz not null default clock_timestamp(),
  last_claimed_at timestamptz,
  last_completed_at timestamptz,
  last_duration_ms bigint,
  last_error text,
  reason text not null default 'input',
  claim_count bigint not null default 0,
  success_count bigint not null default 0,
  renewal_count bigint not null default 0,
  lease_expiry_count bigint not null default 0,
  primary key (user_id, device_id, day, algorithm_version),
  check ((lease_token is null) = (lease_until is null))
);
create index scoring_jobs_due_v2 on public.scoring_jobs_v2(algorithm_version, not_before, day desc)
  where completed_revision < input_revision and not dead_letter;
create unique index scoring_job_token_v2 on public.scoring_jobs_v2(lease_token) where lease_token is not null;
create index scoring_user_last_claim_v2 on public.scoring_jobs_v2(user_id,last_claimed_at desc nulls last);

create table public.scoring_snapshots_v2 (
  result_revision bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null references public.devices(id) on delete cascade,
  day date not null,
  algorithm_version text not null references public.scoring_algorithms_v2,
  input_revision bigint not null,
  computed_at timestamptz not null,
  payload jsonb not null,
  unique (user_id, device_id, day, algorithm_version, input_revision)
);
create index scoring_snapshot_read_v2 on public.scoring_snapshots_v2
  (user_id, device_id, day, algorithm_version, result_revision desc);

create table public.scoring_archive_jobs_v2 (
  result_revision bigint primary key references public.scoring_snapshots_v2 on delete cascade,
  object_key text not null unique,
  lease_token uuid,
  lease_until timestamptz,
  consecutive_failures integer not null default 0,
  dead_letter boolean not null default false,
  not_before timestamptz not null default clock_timestamp(),
  created_at timestamptz not null default clock_timestamp(),
  completed_at timestamptz,
  last_error text,
  sha256 text,
  byte_count bigint,
  check ((lease_token is null) = (lease_until is null))
);
create index scoring_archive_due_v2 on public.scoring_archive_jobs_v2(not_before, result_revision)
  where completed_at is null and not dead_letter;
create unique index scoring_archive_token_v2 on public.scoring_archive_jobs_v2(lease_token) where lease_token is not null;

create table public.scoring_source_preferences_v2 (
  user_id uuid primary key references auth.users(id) on delete cascade,
  device_id uuid not null references public.devices(id) on delete cascade
);
-- Large profile/version invalidations are expanded in bounded batches, never in an upload request.
create table public.scoring_invalidations_v2 (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null references public.devices(id) on delete cascade,
  algorithm_version text not null references public.scoring_algorithms_v2,
  next_day date not null,
  through_day date not null,
  reason text not null,
  created_at timestamptz not null default clock_timestamp(),
  check (next_day <= through_day)
);
create table public.scoring_legacy_repairs_v2 (
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null references public.devices(id) on delete cascade,
  day date not null,
  primary key(user_id, device_id, day)
);

create function public.enqueue_scoring_v2(p_user uuid, p_device uuid, p_day date, p_version text,
  p_reason text default 'input') returns bigint language plpgsql security definer set search_path = public as $$
declare rev bigint;
begin
  if not exists(select 1 from devices where id=p_device and user_id=p_user) then
    raise exception 'device_owner_mismatch';
  end if;
  insert into scoring_jobs_v2(user_id,device_id,day,algorithm_version,reason)
  values(p_user,p_device,p_day,p_version,p_reason)
  on conflict(user_id,device_id,day,algorithm_version) do update set
    input_revision=scoring_jobs_v2.input_revision+1,
    consecutive_failures=0, dead_letter=false, not_before=clock_timestamp(),
    dirty_at=clock_timestamp(), last_error=null, reason=excluded.reason
  returning input_revision into rev;
  -- New source discovery must not leave the legacy projection on the previous source.
  if rev=1 and exists(select 1 from server_daily_scores where user_id=p_user and day=p_day
    and algorithm_version=p_version and source_device_id is distinct from
      selected_scoring_device_v2(p_user,p_day,p_version)) then
    perform refresh_scoring_legacy_v2(p_user,p_day,p_version);
  end if;
  return rev;
end $$;

create function public.claim_scoring_v2(p_version text, p_lease_seconds integer default 300)
returns setof public.scoring_jobs_v2 language plpgsql security definer set search_path = public as $$
declare j scoring_jobs_v2;
begin
  if p_lease_seconds < 1 or p_lease_seconds > 3600 then raise exception 'invalid_lease'; end if;
  -- A single runnable claim. Oldest-served users get a turn; their current days run first.
  select q.* into j from scoring_jobs_v2 q
  where q.algorithm_version=p_version and q.completed_revision<q.input_revision
    and not q.dead_letter and q.not_before<=clock_timestamp()
    and (q.lease_until is null or q.lease_until<=clock_timestamp())
    and exists(select 1 from scoring_algorithms_v2 a where a.algorithm_version=p_version and a.enabled)
    and not exists(select 1 from scoring_invalidations_v2 i where i.user_id=q.user_id and i.device_id=q.device_id
      and i.algorithm_version=q.algorithm_version and q.day between i.next_day and i.through_day)
  order by coalesce((select max(s.last_claimed_at) from scoring_jobs_v2 s where s.user_id=q.user_id),
                    '-infinity'::timestamptz),
           -- A day waiting over an hour takes precedence over continuous current-day updates.
           (q.dirty_at < clock_timestamp()-interval '1 hour') desc,
           case when q.dirty_at < clock_timestamp()-interval '1 hour' then q.dirty_at end,
           q.day desc, q.dirty_at, q.device_id
  for update of q skip locked limit 1;
  if not found then return; end if;
  return query update scoring_jobs_v2 q set lease_token=gen_random_uuid(),
    lease_until=clock_timestamp()+make_interval(secs=>p_lease_seconds),
    last_claimed_at=clock_timestamp(), claim_count=q.claim_count+1,
    lease_expiry_count=q.lease_expiry_count+case when q.lease_token is null then 0 else 1 end
  where q.user_id=j.user_id and q.device_id=j.device_id and q.day=j.day and q.algorithm_version=j.algorithm_version
  returning q.*;
end $$;

create function public.renew_scoring_v2(p_token uuid, p_seconds integer default 300)
returns boolean language plpgsql security definer set search_path=public as $$
begin
  if p_seconds < 1 or p_seconds > 3600 then raise exception 'invalid_lease'; end if;
  update scoring_jobs_v2 set lease_until=clock_timestamp()+make_interval(secs=>p_seconds),
    renewal_count=renewal_count+1 where lease_token=p_token and lease_until>clock_timestamp();
  return found;
end $$;

create function public.fail_scoring_v2(p_token uuid, p_revision bigint, p_error text)
returns boolean language plpgsql security definer set search_path=public as $$
begin
  update scoring_jobs_v2 set
    consecutive_failures=case when input_revision=p_revision then consecutive_failures+1 else 0 end,
    dead_letter=(input_revision=p_revision and consecutive_failures+1>=8),
    not_before=case when input_revision=p_revision then clock_timestamp()+
      make_interval(secs=>least(3600,5*power(2,least(consecutive_failures,10)))::integer) else clock_timestamp() end,
    last_error=case when input_revision=p_revision then left(p_error,2000) else null end,
    lease_token=null, lease_until=null
  where lease_token=p_token and lease_until>clock_timestamp();
  return found;
end $$;

create function public.selected_scoring_device_v2(p_user uuid,p_day date,p_version text)
returns uuid language sql stable security invoker set search_path=public as $$
  select coalesce(
    (select s.device_id from scoring_source_preferences_v2 s join devices d on d.id=s.device_id and d.user_id=s.user_id
       where s.user_id=p_user),
    (select q.device_id from scoring_jobs_v2 q join devices d on d.id=q.device_id and d.user_id=q.user_id
       where q.user_id=p_user and q.day=p_day and q.algorithm_version=p_version order by q.device_id limit 1))
$$;

create function public.refresh_scoring_legacy_v2(p_user uuid,p_day date,p_version text)
returns void language plpgsql security definer set search_path=public as $$
declare s scoring_snapshots_v2; d jsonb; n jsonb; dev uuid;
begin
  -- Serialize user/day projections across devices. Lock BEFORE choosing the latest committed snapshot.
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
  -- Only machine-owned server rows; user edits live in the input lane and are not removed here.
  delete from server_sleep_nights where user_id=p_user and period_day=p_day and algorithm_version=p_version;
  for n in select value from jsonb_array_elements(s.payload->'sleep') loop
    insert into server_sleep_nights(id,user_id,device_id,period_day,start_at,end_at,is_nap,
      in_bed_min,asleep_min,awake_min,light_min,deep_min,rem_min,efficiency,resting_hr_bpm,hrv_rmssd_ms,
      stages,algorithm_version,computed_at)
    values((n->>'id')::uuid,p_user,dev,p_day,(n->>'start_at')::timestamptz,(n->>'end_at')::timestamptz,
      (n->>'is_nap')::boolean,(n->>'in_bed_min')::numeric,(n->>'asleep_min')::numeric,(n->>'awake_min')::numeric,
      (n->>'light_min')::numeric,(n->>'deep_min')::numeric,(n->>'rem_min')::numeric,(n->>'efficiency')::numeric,
      (n->>'resting_hr_bpm')::numeric,(n->>'hrv_rmssd_ms')::numeric,n->'stages',p_version,s.computed_at);
  end loop;
end $$;

create function public.publish_scoring_snapshot_v2(p_token uuid,p_revision bigint,p_payload jsonb,p_duration_ms bigint)
returns bigint language plpgsql security definer set search_path=public as $$
declare j scoring_jobs_v2; rev bigint; payload jsonb; computed timestamptz; owner_id uuid; n jsonb;
begin
  select user_id into owner_id from scoring_jobs_v2 where lease_token=p_token;
  if not found then return null; end if;
  -- Linearize range invalidations/config changes with publication BEFORE taking the job lock.
  perform pg_advisory_xact_lock_shared(hashtextextended('scoring-inputs-v2:'||owner_id,0));
  select * into j from scoring_jobs_v2 where lease_token=p_token for update;
  if not found or j.lease_until<=clock_timestamp() or j.input_revision<>p_revision then return null; end if;
  if not exists(select 1 from scoring_algorithms_v2 where algorithm_version=j.algorithm_version and enabled) then return null; end if;
  if exists(select 1 from scoring_invalidations_v2 i where i.user_id=j.user_id and i.device_id=j.device_id
    and i.algorithm_version=j.algorithm_version and j.day between i.next_day and i.through_day) then return null; end if;
  if jsonb_typeof(p_payload->'sleep') is distinct from 'array'
    or jsonb_typeof(p_payload->'coverage') is distinct from 'object'
    or coalesce(jsonb_typeof(p_payload->'daily'),'missing') not in ('object','null')
    or not (p_payload ? 'daily' and p_payload ? 'dataThrough' and p_payload ? 'timezone')
    or coalesce(p_payload->>'status','') not in ('available','partial','no_data') then
    raise exception 'invalid_snapshot_contract';
  end if;
  perform 1 from pg_timezone_names where name=p_payload->>'timezone';
  if not found then raise exception 'invalid_snapshot_timezone'; end if;
  perform (p_payload->>'dataThrough')::timestamptz;
  for n in select value from jsonb_array_elements(p_payload->'sleep') loop
    if jsonb_typeof(n->'stages') is distinct from 'array'
      or n->>'id' is null or n->>'start_at' is null or n->>'end_at' is null
      or (n->>'end_at')::timestamptz <= (n->>'start_at')::timestamptz then
      raise exception 'invalid_snapshot_sleep';
    end if;
  end loop;
  computed:=clock_timestamp();
  -- Allocate the server revision before constructing the immutable payload.
  rev:=nextval(pg_get_serial_sequence('public.scoring_snapshots_v2','result_revision'));
  payload:=p_payload || jsonb_build_object('schemaVersion',2,'userId',j.user_id,
    'sourceDeviceId',j.device_id,'day',j.day,'algorithmVersion',j.algorithm_version,
    'inputRevision',p_revision,'resultRevision',rev,'computedAt',computed);
  insert into scoring_snapshots_v2 overriding system value
    values(rev,j.user_id,j.device_id,j.day,j.algorithm_version,p_revision,computed,payload);
  insert into scoring_archive_jobs_v2(result_revision,object_key)
    values(rev,'v3/derived/users/'||j.user_id||'/devices/'||j.device_id||'/days/'||j.day||'/'||
      j.algorithm_version||'/revisions/'||rev||'.json');
  update scoring_jobs_v2 set completed_revision=p_revision,lease_token=null,lease_until=null,
    consecutive_failures=0,dead_letter=false,last_error=null,last_completed_at=computed,
    last_duration_ms=greatest(0,p_duration_ms),success_count=success_count+1
  where user_id=j.user_id and device_id=j.device_id and day=j.day and algorithm_version=j.algorithm_version;
  perform refresh_scoring_legacy_v2(j.user_id,j.day,j.algorithm_version);
  return rev;
end $$;

create function public.reject_snapshot_update_v2() returns trigger language plpgsql as $$
begin raise exception 'scoring_snapshots_v2_are_immutable'; end $$;
create trigger scoring_snapshot_immutable before update on public.scoring_snapshots_v2
  for each row execute function public.reject_snapshot_update_v2();

create function public.get_server_score_snapshot_v2(p_day date,p_algorithm_version text default null)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare u uuid:=auth.uid(); v text; dev uuid; j scoring_jobs_v2; s scoring_snapshots_v2;
begin
  if u is null then raise exception 'authentication_required' using errcode='42501'; end if;
  v:=coalesce(p_algorithm_version,(select algorithm_version from scoring_algorithms_v2 where active));
  if not exists(select 1 from scoring_algorithms_v2 where algorithm_version=v and enabled) then
    return jsonb_build_object('schemaVersion',2,'status','unsupported','day',p_day,'algorithmVersion',v);
  end if;
  dev:=selected_scoring_device_v2(u,p_day,v);
  select * into j from scoring_jobs_v2 where user_id=u and device_id=dev and day=p_day and algorithm_version=v;
  select * into s from scoring_snapshots_v2 where user_id=u and device_id=dev and day=p_day and algorithm_version=v
    order by result_revision desc limit 1;
  if not found then
    return jsonb_build_object('schemaVersion',2,'userId',u,'sourceDeviceId',dev,'algorithmVersion',v,'day',p_day,
      'timezone',coalesce((select timezone from profiles where id=u),'UTC'),
      'inputRevision',j.input_revision,'resultRevision',null,'dataThrough',null,'computedAt',null,
      'status',case when j.dead_letter then 'failed' else 'pending' end,
      'coverage','{}'::jsonb,'daily',null,'sleep','[]'::jsonb,
      'requestedInputRevision',j.input_revision,'pending',true,'archiveStatus',null);
  end if;
  return s.payload || jsonb_build_object('requestedInputRevision',j.input_revision,
    'pending',j.input_revision>s.input_revision or exists(select 1 from scoring_invalidations_v2 i
      where i.user_id=u and i.device_id=dev and i.algorithm_version=v and p_day between i.next_day and i.through_day),
    'archiveStatus',(select case when completed_at is not null then 'complete' when dead_letter then 'failed' else 'pending' end
       from scoring_archive_jobs_v2 where result_revision=s.result_revision));
end $$;

create function public.claim_scoring_archive_v2(p_seconds integer default 300)
returns table(result_revision bigint,object_key text,lease_token uuid,payload_text text)
language plpgsql security definer set search_path=public as $$
declare rev bigint;
begin
  if p_seconds<1 or p_seconds>3600 then raise exception 'invalid_lease'; end if;
  select a.result_revision into rev from scoring_archive_jobs_v2 a
    where a.completed_at is null and not a.dead_letter and a.not_before<=clock_timestamp()
      and (a.lease_until is null or a.lease_until<=clock_timestamp())
    order by a.not_before,a.result_revision for update skip locked limit 1;
  if not found then return; end if;
  return query with claimed as (
    update scoring_archive_jobs_v2 a set lease_token=gen_random_uuid(),lease_until=clock_timestamp()+make_interval(secs=>p_seconds)
    where a.result_revision=rev returning a.*)
    select c.result_revision,c.object_key,c.lease_token,s.payload::text from claimed c
      join scoring_snapshots_v2 s on s.result_revision=c.result_revision;
end $$;

create function public.renew_scoring_archive_v2(p_token uuid,p_seconds integer default 300)
returns boolean language plpgsql security definer set search_path=public as $$
begin
  if p_seconds<1 or p_seconds>3600 then raise exception 'invalid_lease'; end if;
  update scoring_archive_jobs_v2 set lease_until=clock_timestamp()+make_interval(secs=>p_seconds)
    where lease_token=p_token and lease_until>clock_timestamp() and completed_at is null;
  return found;
end $$;

create function public.fail_scoring_archive_v2(p_token uuid,p_error text)
returns boolean language plpgsql security definer set search_path=public as $$
begin
  update scoring_archive_jobs_v2 set consecutive_failures=consecutive_failures+1,
    dead_letter=consecutive_failures+1>=12,
    not_before=clock_timestamp()+make_interval(secs=>least(3600,5*power(2,least(consecutive_failures,10)))::integer),
    last_error=left(p_error,2000),lease_token=null,lease_until=null
    where lease_token=p_token and lease_until>clock_timestamp() and completed_at is null;
  return found;
end $$;

create function public.complete_scoring_archive_v2(p_token uuid,p_sha text,p_bytes bigint,p_bucket text,p_retention_days integer)
returns boolean language plpgsql security definer set search_path=public as $$
declare a scoring_archive_jobs_v2; s scoring_snapshots_v2;
begin
  select * into a from scoring_archive_jobs_v2 where lease_token=p_token for update;
  if not found or a.lease_until<=clock_timestamp() or a.completed_at is not null then return false; end if;
  if p_sha is null or p_bytes is null or p_bucket is null or p_retention_days is null
    or p_sha !~ '^[0-9a-f]{64}$' or p_bytes<=0 or p_retention_days<1 then raise exception 'invalid_archive_receipt'; end if;
  select * into s from scoring_snapshots_v2 where result_revision=a.result_revision;
  if p_bytes<>octet_length(convert_to(s.payload::text,'UTF8'))
    or p_sha<>encode(extensions.digest(convert_to(s.payload::text,'UTF8'),'sha256'),'hex') then
    raise exception 'archive_snapshot_mismatch';
  end if;
  insert into object_manifests(user_id,device_id,object_class,object_kind,provider,bucket,object_key,period_day,
    compressed_bytes,uncompressed_bytes,content_type,format,compression,sha256,sha256_source,algorithm_version,
    status,retention_class,expires_at,uploaded_at,verified_at)
  values(s.user_id,s.device_id,'derived','derived_scores','b2',p_bucket,a.object_key,s.day,
    p_bytes,p_bytes,'application/json','json_frwhoop_snapshot_v2','none',p_sha,'server_verified',s.algorithm_version,
    'ready','derived',clock_timestamp()+make_interval(days=>p_retention_days),clock_timestamp(),clock_timestamp())
  on conflict(object_key) do nothing;
  if not exists(select 1 from object_manifests where object_key=a.object_key and sha256=p_sha and compressed_bytes=p_bytes
    and user_id=s.user_id and device_id=s.device_id and bucket=p_bucket and status='ready'
    and format='json_frwhoop_snapshot_v2' and compression='none') then
    raise exception 'immutable_archive_conflict';
  end if;
  update scoring_archive_jobs_v2 set completed_at=clock_timestamp(),lease_token=null,lease_until=null,
    consecutive_failures=0,dead_letter=false,last_error=null,sha256=p_sha,byte_count=p_bytes
    where result_revision=a.result_revision;
  return true;
end $$;

-- Explicit, bounded repair after an operator resolves the cause; never re-score to retry an archive.
create function public.retry_scoring_archive_v2(p_revision bigint) returns boolean
language plpgsql security definer set search_path=public as $$
begin
  update scoring_archive_jobs_v2 set consecutive_failures=0,dead_letter=false,last_error=null,
    not_before=clock_timestamp(),lease_token=null,lease_until=null
    where result_revision=p_revision and completed_at is null
      and (lease_until is null or lease_until<=clock_timestamp());
  return found;
end $$;

create function public.register_scoring_algorithm_v2(p_version text) returns boolean
language plpgsql security definer set search_path=public as $$
begin
  insert into scoring_algorithms_v2(algorithm_version) values(p_version) on conflict do nothing;
  if not found then return false; end if;
  insert into scoring_invalidations_v2(user_id,device_id,algorithm_version,next_day,through_day,reason)
    select user_id,device_id,p_version,min(day),max(day),'algorithm_version' from scoring_jobs_v2 group by user_id,device_id;
  return true;
end $$;

create function public.expand_scoring_invalidations_v2(p_limit integer default 128) returns integer
language plpgsql security definer set search_path=public as $$
declare i scoring_invalidations_v2; n integer:=0;
begin
  while n<least(greatest(p_limit,0),1000) loop
    select * into i from scoring_invalidations_v2 order by id for update skip locked limit 1;
    exit when not found;
    perform enqueue_scoring_v2(i.user_id,i.device_id,i.next_day,i.algorithm_version,i.reason);
    if i.next_day=i.through_day then delete from scoring_invalidations_v2 where id=i.id;
    else update scoring_invalidations_v2 set next_day=next_day+1 where id=i.id; end if;
    n:=n+1;
  end loop;
  return n;
end $$;

create function public.repair_legacy_scoring_v2(p_limit integer default 128) returns integer
language plpgsql security definer set search_path=public as $$
declare r record; v record; n integer:=0;
begin
  for r in select w.* from scoring_work_items w join devices d on d.id=w.device_id and d.user_id=w.user_id
    where not exists(select 1 from scoring_legacy_repairs_v2 x where x.user_id=w.user_id and x.device_id=w.device_id and x.day=w.day)
    order by (w.done_at is null and w.attempts>=8) desc,w.day desc,w.user_id,w.device_id
    for update of w skip locked limit least(greatest(p_limit,0),1000)
  loop
    insert into scoring_legacy_repairs_v2 values(r.user_id,r.device_id,r.day) on conflict do nothing;
    if found then
      for v in select algorithm_version from scoring_algorithms_v2 where enabled loop
        perform enqueue_scoring_v2(r.user_id,r.device_id,r.day,v.algorithm_version,'legacy_repair');
      end loop;
      n:=n+1;
    end if;
  end loop;
  return n;
end $$;

-- Statement-level transition tables coalesce a bulk upload into device/day invalidations.
-- Projection corrections are compared without transport metadata, so identical retries are no-ops.
create function public.scoring_local_day_v2(p_time text,p_zone text) returns date
language sql stable set search_path=public as $$
  select (case when p_time ~ '^-?[0-9]+(\.[0-9]+)?$' then to_timestamp(p_time::double precision)
    else p_time::timestamptz end at time zone coalesce((select name from pg_timezone_names where name=p_zone),'UTC'))::date
$$;

-- Bounded, repeatable safety scan for pre-v2/missed enqueue work. Caller supplies the audited
-- owner/device/date scope and resumes at nextDay; it does not blindly replay fleet history.
-- Existing generations are untouched. Corrections to existing results use the history invalidation RPC.
create function public.reconcile_scoring_days_v2(p_user uuid,p_device uuid,p_from date,p_through date,p_limit integer default 31)
returns jsonb language plpgsql security definer set search_path=public as $$
declare d date:=p_from; zone text; lo bigint; hi bigint; t text; has_input boolean; v record; repaired integer:=0; scanned integer:=0;
begin
  if not exists(select 1 from devices where id=p_device and user_id=p_user) then raise exception 'device_owner_mismatch'; end if;
  if p_from is null or p_through is null or p_from>p_through or p_limit is null or p_limit<1 then raise exception 'invalid_repair_scope'; end if;
  select coalesce((select name from pg_timezone_names where name=p.timezone),'UTC') into zone from profiles p where id=p_user;
  zone:=coalesce(zone,'UTC');
  while d<=p_through and scanned<least(p_limit,31) loop
    lo:=extract(epoch from (d::timestamp at time zone zone)-interval '30 hours')::bigint;
    hi:=extract(epoch from ((d+1)::timestamp at time zone zone))::bigint-1;
    has_input:=false;
    foreach t in array array['noop_hr_samples','noop_rr_intervals','noop_resp_samples','noop_gravity_samples',
      'noop_events','noop_skin_temp_samples','noop_spo2_samples','noop_sleep_state_samples','noop_ppg_hr_samples'] loop
      execute format('select exists(select 1 from public.%I where user_id=$1 and device_id=$2 and ts between $3 and $4)',t)
        into has_input using p_user,p_device,lo,hi;
      exit when has_input;
    end loop;
    has_input:=has_input or exists(select 1 from noop_signal_windows where user_id=p_user and device_id=p_device
      and start_ts<=hi and end_ts>=lo) or exists(select 1 from sessions where user_id=p_user and device_id=p_device
      and start_at<=to_timestamp(hi) and end_at>=to_timestamp(lo));
    if has_input then
      for v in select algorithm_version from scoring_algorithms_v2 where enabled loop
        insert into scoring_jobs_v2(user_id,device_id,day,algorithm_version,reason)
          values(p_user,p_device,d,v.algorithm_version,'input_reconciliation') on conflict do nothing;
        if found then
          repaired:=repaired+1;
          perform refresh_scoring_legacy_v2(p_user,d,v.algorithm_version);
        end if;
      end loop;
    end if;
    d:=d+1; scanned:=scanned+1;
  end loop;
  return jsonb_build_object('nextDay',d,'done',d>p_through,'scanned',scanned,'repaired',repaired);
end $$;

create function public.invalidate_scoring_stream_v2() returns trigger
language plpgsql security definer set search_path=public as $$
declare r record; v record; d date; query text; source_sql text; ts_field text:=TG_ARGV[0];
begin
  if TG_OP='UPDATE' then
    source_sql:='(select to_jsonb(n)-array[''ingested_at'',''updated_at'',''batch_id'',''source_id''] as b from new_rows n EXCEPT select to_jsonb(o)-array[''ingested_at'',''updated_at'',''batch_id'',''source_id''] from old_rows o) union (select to_jsonb(o)-array[''ingested_at'',''updated_at'',''batch_id'',''source_id''] from old_rows o EXCEPT select to_jsonb(n)-array[''ingested_at'',''updated_at'',''batch_id'',''source_id''] from new_rows n)';
  elsif TG_OP='INSERT' then source_sql:='select to_jsonb(n) as b from new_rows n';
  else source_sql:='select to_jsonb(o) as b from old_rows o'; end if;
  query:='select distinct (b->>''user_id'')::uuid as u,(b->>''device_id'')::uuid as dev,
    scoring_local_day_v2(b->>'||quote_literal(ts_field)||',p.timezone) as day,
    scoring_local_day_v2(coalesce(b->>'||quote_literal(coalesce(TG_ARGV[1],ts_field))||',b->>'||quote_literal(ts_field)||'),p.timezone) as through_day
    from ('||source_sql||') changed join profiles p on p.id=(b->>''user_id'')::uuid order by u,dev,day';
  for r in execute query loop
    if not exists(select 1 from devices where id=r.dev and user_id=r.u) then continue; end if;
    perform pg_advisory_xact_lock(hashtextextended('scoring-inputs-v2:'||r.u,0));
    for v in select algorithm_version from scoring_algorithms_v2 where enabled loop
      -- The current reader spans [wake day -30h, wake day end]. Includes the next two wake days.
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

do $$ declare t text; ts_col text; begin
  foreach t in array array['noop_hr_samples','noop_rr_intervals','noop_resp_samples','noop_gravity_samples',
    'noop_events','noop_skin_temp_samples','noop_spo2_samples','noop_sleep_state_samples','noop_ppg_hr_samples','noop_signal_windows','sessions'] loop
    if to_regclass('public.'||t) is null then continue; end if;
    ts_col:=case when t='noop_signal_windows' then 'start_ts' when t='sessions' then 'start_at' else 'ts' end;
    execute format('create trigger scoring_insert_v2 after insert on public.%I referencing new table as new_rows for each statement execute function public.invalidate_scoring_stream_v2(%L,%L)',t,ts_col,case when t='noop_signal_windows' then 'end_ts' when t='sessions' then 'end_at' else ts_col end);
    execute format('create trigger scoring_update_v2 after update on public.%I referencing old table as old_rows new table as new_rows for each statement execute function public.invalidate_scoring_stream_v2(%L,%L)',t,ts_col,case when t='noop_signal_windows' then 'end_ts' when t='sessions' then 'end_at' else ts_col end);
    execute format('create trigger scoring_delete_v2 after delete on public.%I referencing old table as old_rows for each statement execute function public.invalidate_scoring_stream_v2(%L,%L)',t,ts_col,case when t='noop_signal_windows' then 'end_ts' when t='sessions' then 'end_at' else ts_col end);
  end loop;
end $$;

create function public.invalidate_scoring_profile_v2() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  if (to_jsonb(new)-array['updated_at','last_seen_at']) is not distinct from
     (to_jsonb(old)-array['updated_at','last_seen_at']) then return new; end if;
  perform pg_advisory_xact_lock(hashtextextended('scoring-inputs-v2:'||new.id,0));
  insert into scoring_invalidations_v2(user_id,device_id,algorithm_version,next_day,through_day,reason)
    select user_id,device_id,algorithm_version,min(day)-1,max(day)+1,TG_TABLE_NAME
    from scoring_jobs_v2 where user_id=new.id group by user_id,device_id,algorithm_version;
  return new;
end $$;
create trigger scoring_profile_v2 after update on public.profiles
  for each row execute function public.invalidate_scoring_profile_v2();

create function public.invalidate_scoring_history_v2(p_user uuid,p_device uuid,p_from date,p_through date,p_reason text)
returns void language plpgsql security definer set search_path=public as $$
begin
  if not exists(select 1 from devices where id=p_device and user_id=p_user) then raise exception 'device_owner_mismatch'; end if;
  perform pg_advisory_xact_lock(hashtextextended('scoring-inputs-v2:'||p_user,0));
  insert into scoring_invalidations_v2(user_id,device_id,algorithm_version,next_day,through_day,reason)
    select p_user,p_device,algorithm_version,p_from,p_through,left(p_reason,200)
    from scoring_algorithms_v2 where enabled;
end $$;

create function public.set_scoring_source_v2(p_user uuid,p_device uuid) returns void
language plpgsql security definer set search_path=public as $$
declare r record;
begin
  if not exists(select 1 from devices where id=p_device and user_id=p_user) then raise exception 'device_owner_mismatch'; end if;
  perform pg_advisory_xact_lock(hashtextextended('scoring-inputs-v2:'||p_user,0));
  insert into scoring_source_preferences_v2 values(p_user,p_device)
    on conflict(user_id) do update set device_id=excluded.device_id;
  for r in select min(day) as lo,max(day) as hi from scoring_jobs_v2 where user_id=p_user having count(*)>0 loop
    perform invalidate_scoring_history_v2(p_user,p_device,r.lo,r.hi,'source_selection');
  end loop;
end $$;

create function public.invalidate_scoring_device_v2() returns trigger
language plpgsql security definer set search_path=public as $$
declare r record;
begin
  if (new.device_family,new.calibration,new.is_active) is distinct from (old.device_family,old.calibration,old.is_active) then
    for r in select min(day) as lo,max(day) as hi from scoring_jobs_v2 where user_id=new.user_id and device_id=new.id having count(*)>0 loop
      perform invalidate_scoring_history_v2(new.user_id,new.id,r.lo,r.hi,'device_configuration');
    end loop;
  end if;
  return new;
end $$;
create trigger scoring_device_v2 after update on public.devices for each row execute function public.invalidate_scoring_device_v2();

create view public.scoring_queue_metrics_v2 as select
  count(*) filter(where input_revision>completed_revision and not dead_letter) as pending,
  count(*) filter(where lease_until>clock_timestamp()) as running,
  count(*) filter(where dead_letter) as dead_letters,
  coalesce(extract(epoch from clock_timestamp()-min(dirty_at) filter(where input_revision>completed_revision)),0) as oldest_pending_seconds,
  coalesce(sum(claim_count),0) as claims,coalesce(sum(success_count),0) as successes,
  coalesce(sum(lease_expiry_count),0) as lease_expiries,coalesce(sum(renewal_count),0) as renewals,
  coalesce(avg(last_duration_ms),0) as mean_last_duration_ms,
  count(*) filter(where input_revision>completed_revision and not_before>clock_timestamp()) as backing_off,
  (select count(*) from scoring_archive_jobs_v2 where completed_at is null) as archive_pending,
  (select count(*) from scoring_archive_jobs_v2 where dead_letter) as archive_dead_letters,
  (select coalesce(extract(epoch from clock_timestamp()-min(created_at)),0) from scoring_archive_jobs_v2 where completed_at is null) as oldest_archive_seconds,
  (select count(*) from scoring_invalidations_v2) as invalidation_ranges,
  (select coalesce(extract(epoch from clock_timestamp()-min(created_at)),0) from scoring_invalidations_v2) as oldest_invalidation_seconds
from public.scoring_jobs_v2;

-- No v2 work/result mutation is exposed to app roles. Authenticated read RPC derives owner from JWT.
do $$ declare t text; f record; begin
  foreach t in array array['scoring_algorithms_v2','scoring_jobs_v2','scoring_snapshots_v2','scoring_archive_jobs_v2',
    'scoring_source_preferences_v2','scoring_invalidations_v2','scoring_legacy_repairs_v2'] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('revoke all on public.%I from public, anon, authenticated',t);
    execute format('grant all on public.%I to service_role',t);
    execute format('create policy scoring_service_v2 on public.%I for all to service_role using (true) with check (true)',t);
  end loop;
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in (
      'enqueue_scoring_v2','claim_scoring_v2','renew_scoring_v2','fail_scoring_v2','selected_scoring_device_v2',
      'refresh_scoring_legacy_v2','publish_scoring_snapshot_v2','reject_snapshot_update_v2','get_server_score_snapshot_v2',
      'claim_scoring_archive_v2','renew_scoring_archive_v2','fail_scoring_archive_v2','complete_scoring_archive_v2','retry_scoring_archive_v2',
      'register_scoring_algorithm_v2','expand_scoring_invalidations_v2','repair_legacy_scoring_v2',
      'invalidate_scoring_stream_v2','invalidate_scoring_profile_v2','scoring_local_day_v2','reconcile_scoring_days_v2',
      'invalidate_scoring_history_v2','set_scoring_source_v2','invalidate_scoring_device_v2') loop
    execute format('revoke all on function %s from public, anon, authenticated',f.sig);
    execute format('grant execute on function %s to service_role',f.sig);
  end loop;
end $$;
grant usage,select on sequence public.scoring_snapshots_v2_result_revision_seq,
  public.scoring_invalidations_v2_id_seq to service_role;
revoke all on public.scoring_queue_metrics_v2 from public, anon, authenticated;
grant select on public.scoring_queue_metrics_v2 to service_role;
grant execute on function public.get_server_score_snapshot_v2(date,text) to authenticated;
