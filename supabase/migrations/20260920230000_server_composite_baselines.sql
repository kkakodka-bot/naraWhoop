-- Restore native composites without changing their formulas or promoting model qualifications.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

-- Excludes derived Charge, Rest, baseline deviations, timestamps and queue revisions:
-- recomputing only a baseline cannot recursively invalidate the entire future.
create function public.scoring_composite_contribution(p_payload jsonb) returns jsonb
language sql immutable set search_path='' as $$
  select case when p_payload->>'algorithm_version' is distinct from 'frwhoop-physiology-2'
      or p_payload->>'schema_version' is distinct from '2' or p_payload->>'period_closed' is distinct from 'true'
      or nullif(p_payload->>'unavailable_reason','') is not null then '{}'::jsonb
    else jsonb_strip_nulls(jsonb_build_object(
      'hrv',case when p_payload#>>'{daily,hrv_summary,representative}'='true'
        and jsonb_typeof(p_payload#>'{daily,hrv_rmssd_ms}')='number'
        then p_payload#>'{daily,hrv_rmssd_ms}' end,
      'resting_hr',case when jsonb_typeof(p_payload#>'{daily,resting_hr_bpm}')='number'
        and coalesce((p_payload#>>'{daily,sleep_total_min}')::numeric,0)>0
        then p_payload#>'{daily,resting_hr_bpm}' end,
      'resp',case when jsonb_typeof(p_payload#>'{daily,resp_rate_bpm}')='number'
        and p_payload#>>'{daily,respiration_summary,measurement_context}'='qualified_sleep'
        and coalesce((p_payload#>>'{daily,respiration_summary,accepted_windows}')::integer,0)>0
        then p_payload#>'{daily,resp_rate_bpm}' end,
      'skin_temp',case when jsonb_typeof(p_payload#>'{daily,skin_temp_c}')='number'
        and coalesce((p_payload#>>'{daily,sleep_total_min}')::numeric,0)>0
        then p_payload#>'{daily,skin_temp_c}' end))
    end
$$;

create table public.physiology_composite_dependency_snapshots (
  user_id uuid not null references auth.users on delete cascade,
  device_id uuid not null references public.devices on delete cascade,
  period_day date not null,
  algorithm_version text not null references public.physiology_algorithm_versions,
  measurement_revision bigint not null,
  contribution jsonb not null check(jsonb_typeof(contribution)='object'),
  primary key(user_id,device_id,period_day,algorithm_version)
);
alter table public.physiology_composite_dependency_snapshots enable row level security;
create policy physiology_composite_dependency_service on public.physiology_composite_dependency_snapshots
  for all to service_role using(true) with check(true);
grant all on public.physiology_composite_dependency_snapshots to service_role;

create function public.scoring_dirty_composite_dependents(p_user uuid,p_device uuid,p_source_day date)
returns void language plpgsql security definer set search_path='' as $$
declare target record;
begin
  perform public.scoring_lock_device(p_user,p_device);
  -- Exactly matches CanonicalBaselineReader's 28 previous calendar dates.
  for target in select day from public.physiology_work_items q
    where q.user_id=p_user and q.device_id=p_device and q.day>p_source_day and q.day<=p_source_day+28
      and exists(select 1 from public.scoring_day_segments(p_user,q.day) s
        where s.start_ts<=ceil(extract(epoch from clock_timestamp())))
    order by day
  loop perform public.scoring_enqueue_dependency(p_user,p_device,target.day); end loop;
end $$;

create function public.scoring_composite_input_invalidated() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if new.measurement_revision<>old.measurement_revision and exists(
    select 1 from public.physiology_composite_dependency_snapshots s
    where s.user_id=new.user_id and s.device_id=new.device_id and s.period_day=new.day
      and s.algorithm_version='frwhoop-physiology-2' and s.measurement_revision=old.measurement_revision
      and s.contribution<>'{}'::jsonb) then
    perform public.scoring_dirty_composite_dependents(new.user_id,new.device_id,new.day);
  end if;
  return new;
end $$;
create trigger scoring_composite_input_invalidated after update of measurement_revision on public.physiology_work_items
  for each row execute function public.scoring_composite_input_invalidated();

create function public.scoring_composite_result_changed() returns trigger
language plpgsql security definer set search_path='' as $$
declare previous public.physiology_composite_dependency_snapshots; contribution jsonb;
begin
  if new.algorithm_version<>'frwhoop-physiology-2' then return new; end if;
  contribution:=public.scoring_composite_contribution(new.payload);
  select * into previous from public.physiology_composite_dependency_snapshots
    where user_id=new.user_id and device_id=new.device_id and period_day=new.period_day
      and algorithm_version=new.algorithm_version for update;
  if (previous.measurement_revision is distinct from new.measurement_revision
      or previous.contribution is distinct from contribution)
      and (coalesce(previous.contribution,'{}'::jsonb)<>'{}'::jsonb or contribution<>'{}'::jsonb) then
    perform public.scoring_dirty_composite_dependents(new.user_id,new.device_id,new.period_day);
  end if;
  insert into public.physiology_composite_dependency_snapshots values
    (new.user_id,new.device_id,new.period_day,new.algorithm_version,new.measurement_revision,contribution)
  on conflict(user_id,device_id,period_day,algorithm_version) do update set
    measurement_revision=excluded.measurement_revision,contribution=excluded.contribution;
  return new;
end $$;
create trigger scoring_composite_result_changed after insert on public.server_physiology_results
  for each row execute function public.scoring_composite_result_changed();

-- Qualification revocation must also revoke dependent cached composites. This changes no qualification.
create function public.scoring_composite_qualification_changed() returns trigger
language plpgsql security definer set search_path='' as $$
declare target record;
begin
  if tg_op='UPDATE' and row(new.algorithm_version,new.feature,new.qualification)
      is not distinct from row(old.algorithm_version,old.feature,old.qualification) then return null; end if;
  if coalesce(new.algorithm_version,'')<>'frwhoop-physiology-2'
      and coalesce(old.algorithm_version,'')<>'frwhoop-physiology-2' then return null; end if;
  -- A never-published device with no prior observations cannot have consumed a
  -- baseline. Preserve those independent pending/running acquisition jobs.
  for target in select q.user_id,q.device_id,q.day from public.physiology_work_items q
    where exists(select 1 from public.server_physiology_results r
      where r.user_id=q.user_id and r.device_id=q.device_id and r.algorithm_version='frwhoop-physiology-2'
        and r.period_day between q.day-28 and q.day)
    order by q.user_id,q.device_id,q.day
  loop perform public.scoring_enqueue_dependency(target.user_id,target.device_id,target.day); end loop;
  return null;
end $$;
create trigger scoring_composite_qualification_changed after insert or update or delete on public.physiology_feature_qualifications
  for each row execute function public.scoring_composite_qualification_changed();

lock table public.server_physiology_results in share mode;
do $$ begin
  if (select count(*) from (select distinct user_id,device_id,period_day from public.server_physiology_results
    where algorithm_version='frwhoop-physiology-2' limit 10001) affected)>10000 then
    raise exception 'composite_backfill_requires_reviewed_batches' using errcode='54000';
  end if;
end $$;
insert into public.physiology_composite_dependency_snapshots
select distinct on(r.user_id,r.device_id,r.period_day,r.algorithm_version)
  r.user_id,r.device_id,r.period_day,r.algorithm_version,r.measurement_revision,
  public.scoring_composite_contribution(r.payload)
from public.server_physiology_results r where r.algorithm_version='frwhoop-physiology-2'
order by r.user_id,r.device_id,r.period_day,r.algorithm_version,r.input_revision desc;

do $$ declare target record; begin
  for target in select distinct user_id,device_id,period_day from public.server_physiology_results
    where algorithm_version='frwhoop-physiology-2' order by user_id,device_id,period_day
  loop perform public.scoring_enqueue_dependency(target.user_id,target.device_id,target.period_day); end loop;
end $$;

do $$ declare f record; begin
  for f in select p.oid::regprocedure as signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('scoring_composite_contribution','scoring_dirty_composite_dependents',
      'scoring_composite_input_invalidated','scoring_composite_result_changed','scoring_composite_qualification_changed') loop
    execute format('revoke all on function %s from public,anon,authenticated',f.signature);
    execute format('grant execute on function %s to service_role',f.signature);
  end loop;
end $$;

create or replace function public.server_scoring_for_device_day(p_user uuid, p_day date, p_device uuid)
returns jsonb language plpgsql stable security invoker set search_path = pg_catalog, public as $$
declare
  feature_key text;
  device uuid;
  version text;
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
  if not exists(select 1 from public.devices where id=p_device and user_id=p_user) then
    raise exception 'owned device required' using errcode='42501';
  end if;
  for feature_key in select feature from public.physiology_feature_defaults order by feature loop
    device := p_device;
    select coalesce((select s.algorithm_version from public.physiology_source_selection s
        where s.user_id=p_user and s.feature=feature_key and s.device_id=p_device),
      d.algorithm_version) into version
      from public.physiology_feature_defaults d where d.feature=feature_key;
    if not exists(select 1 from public.physiology_feature_qualifications
      where algorithm_version=version and feature=feature_key
        and qualification in ('baseline','reference_qualified','published')) then
      features := features || jsonb_build_object(feature_key,
        jsonb_build_object('status','unavailable','reason','unqualified_version',
          'device_id',device,'algorithm_version',version));
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
      when 'hrv' then array['hrv_rmssd_ms','hrv_sdnn_ms','resting_hr_bpm','overnight_hr_bpm','hrv_summary','heart_rate_windows',
        'recovery','strain','spo2_pct','skin_temp_c','skin_temp_dev_c']
      when 'respiration' then array['resp_rate_bpm','respiration_summary','respiration_unavailable_reason']
      else array['rest','sleep_total_min','sleep_in_bed_min','sleep_awake_min','sleep_light_min','sleep_deep_min',
        'sleep_rem_min','sleep_efficiency','sleep_onset_at','wake_onset_at','sleep_unstaged_min',
        'state_unknown_min','off_body_min','main_sleep_group_id','opportunity_kind','disturbances'] end;
    foreach key in array keys loop
      daily := daily || jsonb_build_object(key,result->'daily'->key);
    end loop;
    measurements := measurements || coalesce((select jsonb_agg(m) from jsonb_array_elements(
      coalesce(result->'measurements','[]'::jsonb)) m where m->>'feature'=feature_key),'[]'::jsonb);
    if feature_key='sleep' then
      nights := coalesce(result->'nights','[]'::jsonb);
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

revoke all on function public.server_scoring_for_device_day(uuid,date,uuid) from public,anon,authenticated;
grant execute on function public.server_scoring_for_device_day(uuid,date,uuid) to service_role;

commit;
