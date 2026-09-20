-- Prefer the device that actually has recent samples. A new app install mints a new
-- push source-id and therefore a new devices row; last_seen_at then follows the empty
-- device and every overlay feature stays awaiting_result.

begin;

create or replace function public.server_scoring_for_day(p_user uuid, p_day date)
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
  for feature_key in select feature from public.physiology_feature_defaults order by feature loop
    select s.device_id, s.algorithm_version into device, version
      from public.physiology_source_selection s where s.user_id=p_user and s.feature=feature_key;
    if device is null then
      select d.id into device
        from public.devices d
        where d.user_id=p_user
        order by (
          select max(h.ts) from public.noop_hr_samples h
          where h.user_id=p_user and h.device_id=d.id
        ) desc nulls last,
        d.last_seen_at desc nulls last,
        d.id
        limit 1;
      if device is null then
        features := features || jsonb_build_object(feature_key,
          jsonb_build_object('status','unavailable','reason','source_selection_required'));
        is_stale := true;
        continue;
      end if;
      select algorithm_version into version from public.physiology_feature_defaults where feature=feature_key;
    end if;
    if not exists(select 1 from public.physiology_feature_qualifications
      where algorithm_version=version and feature=feature_key
        and qualification in ('baseline','reference_qualified','published')) then
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
      when 'hrv' then array['hrv_rmssd_ms','hrv_sdnn_ms','resting_hr_bpm','overnight_hr_bpm','hrv_summary',
        'recovery','strain','spo2_pct','skin_temp_c','skin_temp_dev_c']
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

revoke all on function public.server_scoring_for_day(uuid, date) from public, anon;
grant execute on function public.server_scoring_for_day(uuid, date) to authenticated, service_role;

commit;
