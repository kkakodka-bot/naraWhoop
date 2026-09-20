-- Immutable device/revision results keep the old server tables readable for rollback.
-- A result's generated episode set is one JSON snapshot, replaced atomically by revision.
create table public.physiology_algorithm_versions (
  algorithm_version text primary key check (algorithm_version ~ '^[A-Za-z0-9._-]+$'),
  manifest jsonb not null,
  manifest_hash text not null check (manifest_hash ~ '^[a-f0-9]{64}$'),
  computation_kind text not null check (computation_kind in ('deterministic', 'learned')),
  qualification text not null default 'shadow' check (qualification in ('baseline', 'shadow', 'reference_qualified')),
  evaluation_manifest_hash text,
  created_at timestamptz not null default now(),
  check (qualification <> 'reference_qualified' or evaluation_manifest_hash ~ '^[a-f0-9]{64}$'),
  check (computation_kind <> 'learned' or qualification <> 'baseline')
);

insert into public.physiology_algorithm_versions
  (algorithm_version, manifest, manifest_hash, computation_kind, qualification)
select version, manifest, encode(sha256(convert_to(manifest::text, 'UTF8')), 'hex'), 'deterministic', qualification
from (values
  ('frwhoop-server-1', '{"algorithm":"frwhoop-server-1","accuracy":"unvalidated","preprocess":"legacy","quality":"legacy"}'::jsonb, 'baseline'),
  ('frwhoop-physiology-2', '{"algorithm":"frwhoop-physiology-2","accuracy":"unvalidated","preprocess":"physiology-v2","quality":"continuity-v2","mode":"retrospective"}'::jsonb, 'shadow')
) v(version, manifest, qualification);

create table public.physiology_feature_defaults (
  feature text primary key check (feature in ('hrv', 'sleep', 'respiration')),
  algorithm_version text not null references public.physiology_algorithm_versions,
  updated_at timestamptz not null default now()
);
insert into public.physiology_feature_defaults(feature, algorithm_version)
values ('hrv', 'frwhoop-server-1'), ('sleep', 'frwhoop-server-1'), ('respiration', 'frwhoop-server-1');

-- Qualification of one feature never qualifies the other outputs of the same bundle. These
-- records are operator-managed after the signed offline gate AND explicit human review.
create table public.physiology_feature_qualifications (
  algorithm_version text not null references public.physiology_algorithm_versions,
  feature text not null references public.physiology_feature_defaults,
  qualification text not null default 'shadow' check(qualification in ('baseline','shadow','reference_qualified')),
  policy_sha256 text,
  evaluation_sha256 text,
  signed_policy jsonb,
  signed_evaluation jsonb,
  reviewed_by text,
  reviewed_at timestamptz,
  primary key(algorithm_version,feature),
  check(qualification<>'baseline' or algorithm_version='frwhoop-server-1'),
  check(qualification<>'reference_qualified' or (
    policy_sha256 ~ '^[a-f0-9]{64}$' and evaluation_sha256 ~ '^[a-f0-9]{64}$'
    and jsonb_typeof(signed_policy)='object' and jsonb_typeof(signed_evaluation)='object'
    and signed_policy#>>'{payload,metric_family}'=feature
    and signed_evaluation#>>'{payload,policy_sha256}'=policy_sha256
    and signed_policy#>>'{signature,algorithm}'='HMAC-SHA256'
    and signed_evaluation#>>'{signature,algorithm}'='HMAC-SHA256'
    and nullif(reviewed_by,'') is not null and reviewed_at is not null) is true)
);
insert into public.physiology_feature_qualifications(algorithm_version,feature,qualification)
select v.algorithm_version,f.feature,case when v.algorithm_version='frwhoop-server-1' then 'baseline' else 'shadow' end
from public.physiology_algorithm_versions v cross join public.physiology_feature_defaults f;

create table public.physiology_source_selection (
  user_id uuid not null references auth.users on delete cascade,
  feature text not null references public.physiology_feature_defaults,
  device_id uuid not null references public.devices on delete cascade,
  algorithm_version text not null references public.physiology_algorithm_versions,
  updated_at timestamptz not null default now(),
  primary key (user_id, feature)
);

create table public.server_physiology_results (
  user_id uuid not null references auth.users on delete cascade,
  device_id uuid not null references public.devices on delete cascade,
  period_day date not null,
  algorithm_version text not null references public.physiology_algorithm_versions,
  input_revision bigint not null check (input_revision > 0),
  run_id uuid not null,
  manifest_hash text not null,
  payload jsonb not null,
  payload_hash text not null check (payload_hash ~ '^[a-f0-9]{64}$'),
  observed_through timestamptz,
  computed_at timestamptz not null,
  publication_status text not null check (publication_status in ('provisional', 'final')),
  primary key (user_id, device_id, period_day, algorithm_version, input_revision)
);
create index physiology_result_latest on public.server_physiology_results
  (user_id, device_id, period_day, algorithm_version, input_revision desc);

create table public.physiology_archive_outbox (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  device_id uuid not null,
  period_day date not null,
  algorithm_version text not null,
  input_revision bigint not null,
  object_key text not null unique,
  status text not null default 'pending' check (status in ('pending', 'uploading', 'uploaded', 'verified', 'failed')),
  lease_token uuid,
  lease_expires_at timestamptz,
  attempts integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  last_error text,
  content_sha256 text,
  uploaded_at timestamptz,
  verified_at timestamptz,
  foreign key (user_id, device_id, period_day, algorithm_version, input_revision)
    references public.server_physiology_results on delete cascade,
  unique (user_id, device_id, period_day, algorithm_version, input_revision)
);

create table public.physiology_sleep_overrides (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users on delete cascade,
  device_id uuid not null references public.devices on delete cascade,
  original_start_at timestamptz not null,
  original_end_at timestamptz not null,
  start_at timestamptz not null,
  end_at timestamptz not null,
  tombstone boolean not null default false,
  revision bigint not null default 1,
  updated_at timestamptz not null default now(),
  check (original_end_at > original_start_at and end_at > start_at)
);

create function public.physiology_dirty_override() returns trigger
language plpgsql security definer set search_path = pg_catalog, public as $$
begin
  if tg_op <> 'INSERT' then
    perform public.scoring_dirty_span(old.user_id, old.device_id,
      extract(epoch from least(old.original_start_at, old.start_at))::bigint,
      extract(epoch from greatest(old.original_end_at, old.end_at))::bigint);
  end if;
  if tg_op <> 'DELETE' then
    perform public.scoring_dirty_span(new.user_id, new.device_id,
      extract(epoch from least(new.original_start_at, new.start_at))::bigint,
      extract(epoch from greatest(new.original_end_at, new.end_at))::bigint);
  end if;
  return null;
end;
$$;
create trigger physiology_override_dirty after insert or update or delete on public.physiology_sleep_overrides
  for each row execute function public.physiology_dirty_override();

-- Owner-scoped optimistic updates. Deletion is a durable tombstone, not loss of the suppression
-- record that would allow late backfill to recreate a dismissed generated episode.
create function public.set_physiology_sleep_override(p_id uuid,p_device uuid,
    p_original_start timestamptz,p_original_end timestamptz,p_start timestamptz,p_end timestamptz,
    p_tombstone boolean,p_expected_revision bigint default 0)
returns bigint language plpgsql security definer set search_path=pg_catalog,public as $$
declare u uuid:=auth.uid(); result_revision bigint;
begin
  if u is null or not exists(select 1 from public.devices where id=p_device and user_id=u) then
    raise exception 'owned device required' using errcode='42501';
  end if;
  if p_id is null or p_original_start is null or p_original_end is null or p_start is null or p_end is null
    or p_tombstone is null or p_expected_revision is null or p_expected_revision<0
    or p_original_end<=p_original_start or p_end<=p_start
    or p_end-p_start>interval '48 hours' or p_original_end-p_original_start>interval '48 hours' then
    raise exception 'invalid boundary override' using errcode='22023';
  end if;
  -- Share the queue/publication mutex, including competing inserts with distinct IDs.
  -- Do not lock the devices row: raw inserts can already hold its FK key-share lock
  -- before their revision trigger waits for this mutex, which would invert lock order.
  perform public.scoring_lock_device(u,p_device);
  if not p_tombstone and exists(select 1 from public.physiology_sleep_overrides
      where user_id=u and device_id=p_device and id<>p_id and not tombstone
        and start_at<p_end and p_start<end_at) then
    raise exception 'overlapping boundary overrides' using errcode='22023';
  end if;
  if p_expected_revision=0 then
    insert into public.physiology_sleep_overrides(id,user_id,device_id,original_start_at,original_end_at,start_at,end_at,tombstone)
      values(p_id,u,p_device,p_original_start,p_original_end,p_start,p_end,p_tombstone)
      on conflict(id) do nothing returning revision into result_revision;
  else
    update public.physiology_sleep_overrides set start_at=p_start,end_at=p_end,tombstone=p_tombstone,
      revision=revision+1,updated_at=clock_timestamp()
      where id=p_id and user_id=u and device_id=p_device and revision=p_expected_revision
        and original_start_at=p_original_start and original_end_at=p_original_end
      returning revision into result_revision;
  end if;
  if result_revision is null then raise exception 'override revision changed' using errcode='40001'; end if;
  return result_revision;
end;
$$;
revoke all on function public.set_physiology_sleep_override(uuid,uuid,timestamptz,timestamptz,timestamptz,timestamptz,boolean,bigint)
  from public,anon;
grant execute on function public.set_physiology_sleep_override(uuid,uuid,timestamptz,timestamptz,timestamptz,timestamptz,boolean,bigint)
  to authenticated;

-- Machine writes; users can inspect only their own snapshots and manually scoped overrides.
do $$
declare t text;
begin
  foreach t in array array['physiology_algorithm_versions', 'physiology_feature_defaults',
      'physiology_feature_qualifications',
      'physiology_source_selection', 'server_physiology_results', 'physiology_archive_outbox',
      'physiology_sleep_overrides'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('grant all on public.%I to service_role', t);
    execute format('create policy machine_access on public.%I for all to service_role using (true) with check (true)', t);
  end loop;
  foreach t in array array['physiology_algorithm_versions', 'physiology_feature_defaults','physiology_feature_qualifications'] loop
    execute format('grant select on public.%I to authenticated', t);
    execute format('create policy read_versions on public.%I for select to authenticated using (true)', t);
  end loop;
  foreach t in array array['physiology_source_selection', 'server_physiology_results', 'physiology_sleep_overrides'] loop
    execute format('grant select on public.%I to authenticated', t);
    execute format('create policy read_owner on public.%I for select to authenticated using ((select auth.uid()) = user_id)', t);
  end loop;
end;
$$;
grant usage, select on sequence public.physiology_archive_outbox_id_seq to service_role;

create function public.engine_publish_physiology(p_secret text, p_payload jsonb)
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

-- Selection is explicit and can roll back each feature independently.
create function public.select_physiology_source(p_feature text, p_device uuid, p_version text)
returns void language plpgsql security definer set search_path = pg_catalog, public as $$
declare u uuid := auth.uid();
begin
  if u is null or not exists(select 1 from public.devices where id = p_device and user_id = u) then
    raise exception 'owned device required' using errcode = '42501';
  end if;
  if not exists(select 1 from public.physiology_feature_qualifications
    where algorithm_version = p_version and feature=p_feature and qualification in ('baseline', 'reference_qualified')) then
    raise exception 'algorithm is not qualified for canonical display' using errcode = '22023';
  end if;
  insert into public.physiology_source_selection(user_id, feature, device_id, algorithm_version)
  values (u, p_feature, p_device, p_version)
  on conflict (user_id, feature) do update set device_id = excluded.device_id,
    algorithm_version = excluded.algorithm_version, updated_at = now();
end;
$$;

revoke all on function public.physiology_dirty_override() from public, anon, authenticated;
revoke all on function public.engine_publish_physiology(text, jsonb) from public, anon, authenticated;
grant execute on function public.engine_publish_physiology(text, jsonb) to service_role;
revoke all on function public.select_physiology_source(text, uuid, text) from public, anon;
grant execute on function public.select_physiology_source(text, uuid, text) to authenticated;

comment on table public.server_physiology_results is
  'Immutable canonical DTO snapshots. Selecting a newer revision atomically replaces the complete generated episode set. Legacy server tables remain available for rollback.';
comment on table public.physiology_algorithm_versions is
  'No learned model can be a baseline. Shadow is the default and cannot be selected for canonical display.';

-- The existing snapshot RPC calls this function. Old tables remain the baseline read path;
-- per-feature selection resolves device and version before reading any result.
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
    feature_stale := result is null or coalesce(result_revision < current_revision,false)
      or (result_revision is null and current_revision is not null);
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

create function public.physiology_processing_metadata(p_user uuid,p_device uuid,p_day date,p_version text,p_revision bigint)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare required bigint; zone text; processing_status text; archive_status text;
begin
  if auth.uid() is distinct from p_user and auth.role() is distinct from 'service_role' then
    raise exception 'owner required' using errcode='42501';
  end if;
  select q.input_revision,q.timezone_id,q.status into required,zone,processing_status
    from public.scoring_work_items q where q.user_id=p_user and q.device_id=p_device and q.day=p_day;
  zone:=coalesce(zone,public.scoring_timezone_at(p_user,p_day::timestamp at time zone 'UTC'));
  select o.status into archive_status from public.physiology_archive_outbox o
    where o.user_id=p_user and o.device_id=p_device and o.period_day=p_day
      and o.algorithm_version=p_version and o.input_revision=p_revision;
  return jsonb_build_object('required_revision',required,'timezone_id',zone,
    'processing_status',processing_status,'archive_status',archive_status);
end;
$$;
revoke all on function public.physiology_processing_metadata(uuid,uuid,date,text,bigint) from public,anon;
grant execute on function public.physiology_processing_metadata(uuid,uuid,date,text,bigint) to authenticated,service_role;

create function public.physiology_required_revision(p_user uuid,p_device uuid,p_day date)
returns bigint language plpgsql stable security definer set search_path = pg_catalog,public as $$
declare revision bigint;
begin
  if auth.uid() is distinct from p_user and auth.role() is distinct from 'service_role' then
    raise exception 'owner required' using errcode = '42501';
  end if;
  select input_revision into revision from public.scoring_work_items
    where user_id=p_user and device_id=p_device and day=p_day;
  return revision;
end;
$$;
revoke all on function public.physiology_required_revision(uuid,uuid,date) from public,anon;
grant execute on function public.physiology_required_revision(uuid,uuid,date) to authenticated,service_role;
revoke all on function public.server_scoring_for_day(uuid,date) from public,anon;
grant execute on function public.server_scoring_for_day(uuid,date) to authenticated,service_role;
