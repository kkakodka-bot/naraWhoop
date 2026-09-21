-- Shared owner/device selection and serialization. Applied migrations remain unchanged.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

create function public.server_scoring_read_contract(p_user uuid, p_day date, p_device uuid default null)
returns jsonb language plpgsql stable security invoker set search_path = pg_catalog, public as $$
declare
  feature_key text; device uuid; version text; result jsonb; stored_manifest text;
  expected_manifest text; expected_feature_manifest text;
  daily jsonb := '{}'::jsonb; nights jsonb := '[]'::jsonb;
  measurements jsonb := '[]'::jsonb; sleep_overrides jsonb := '[]'::jsonb;
  features jsonb := '{}'::jsonb; processing jsonb;
  current_revision bigint; result_revision bigint;
  is_stale boolean := false; feature_stale boolean;
  computed timestamptz; feature_computed timestamptz;
  key text; keys text[]; unavailable_reason text; feature_status text;
  selected_versions text[] := '{}'::text[]; selected_devices uuid[] := '{}'::uuid[];
begin
  if auth.uid() is distinct from p_user and auth.role() is distinct from 'service_role' then
    raise exception 'owner required' using errcode='42501';
  end if;
  if p_device is not null and not exists(select 1 from public.devices where id=p_device and user_id=p_user) then
    raise exception 'owned device required' using errcode='42501';
  end if;
  for feature_key in select feature from public.physiology_feature_defaults order by feature loop
    device := null; version := null;
    select s.device_id,s.algorithm_version into device,version
      from public.physiology_source_selection s
      where s.user_id=p_user and s.feature=feature_key and (p_device is null or s.device_id=p_device);
    if device is null then
      device := p_device;
      if device is null then
        select d.id into device from public.devices d where d.user_id=p_user
          order by (select max(h.ts) from public.noop_hr_samples h
            where h.user_id=p_user and h.device_id=d.id) desc nulls last,
            d.last_seen_at desc nulls last,d.id limit 1;
      end if;
      select algorithm_version into version from public.physiology_feature_defaults where feature=feature_key;
    end if;
    if device is null or not exists(select 1 from public.devices where id=device and user_id=p_user) then
      features := features || jsonb_build_object(feature_key,jsonb_build_object(
        'status','unavailable','reason','source_selection_required'));
      is_stale := true;
      continue;
    end if;
    selected_versions := array_append(selected_versions,version);
    selected_devices := array_append(selected_devices,device);
    if not public.physiology_feature_is_canonical(version,feature_key) then
      features := features || jsonb_build_object(feature_key,jsonb_build_object(
        'status','unavailable','reason','unqualified_version','device_id',device,'algorithm_version',version));
      is_stale := true;
      continue;
    end if;

    result := null; result_revision := null; feature_computed := null; stored_manifest := null;
    unavailable_reason := null;
    select v.manifest_hash into expected_manifest from public.physiology_algorithm_versions v
      where v.algorithm_version=version;
    select m.manifest_sha256 into expected_feature_manifest from public.physiology_feature_manifests m
      where m.algorithm_version=version and m.feature=feature_key;
    select r.payload,r.input_revision,r.computed_at,r.manifest_hash
      into result,result_revision,feature_computed,stored_manifest
      from public.server_physiology_results r where r.user_id=p_user and r.device_id=device
        and r.period_day=p_day and r.algorithm_version=version order by r.input_revision desc limit 1;
    -- Do not silently fall back to an older result when the newest release identity is incompatible.
    if result is not null and (stored_manifest is distinct from expected_manifest
      or (version<>'frwhoop-server-1' and (expected_feature_manifest is null
        or result->'feature_manifest_hashes'->>feature_key is distinct from expected_feature_manifest))) then
      result := null; unavailable_reason := 'manifest_mismatch';
    elsif result is null and version='frwhoop-server-1' then
      select jsonb_build_object('daily',to_jsonb(d),'nights',coalesce((
          select jsonb_agg(to_jsonb(n) order by n.start_at) from public.server_sleep_nights n
          where n.user_id=p_user and n.device_id=device and n.period_day=p_day and n.algorithm_version=version
        ),'[]'::jsonb)),d.computed_at into result,feature_computed
        from public.server_daily_scores d where d.user_id=p_user and d.source_device_id=device
          and d.day=p_day and d.algorithm_version=version;
    end if;
    processing := public.physiology_processing_metadata(p_user,device,p_day,version,result_revision);
    current_revision := (processing->>'required_revision')::bigint;
    feature_stale := case when version='frwhoop-server-1' and result_revision is null
      then result is null or not coalesce((processing->>'legacy_result_current')::boolean,false)
      else result is null or coalesce(result_revision<current_revision,false)
        or (result_revision is null and current_revision is not null) end;
    is_stale := is_stale or feature_stale;
    unavailable_reason := coalesce(unavailable_reason,nullif(result->>'unavailable_reason',''),
      case when result is null then 'awaiting_result' end);
    feature_status := case when unavailable_reason is not null then 'unavailable'
      when feature_stale then 'stale' else 'available' end;
    if result is not null and feature_computed is not null then computed := greatest(computed,feature_computed); end if;
    features := features || jsonb_build_object(feature_key,jsonb_build_object(
      'status',feature_status,'reason',coalesce(unavailable_reason,case when feature_stale then 'newer_input_pending' end),
      'device_id',device,'algorithm_version',version,'input_revision',result_revision,
      'required_revision',current_revision,'computed_at',feature_computed,
      'observed_through',result->'observed_through','publication_status',result->'publication_status',
      'manifest_hash',case when result is not null then expected_manifest end,
      'feature_manifest_hash',case when result is not null then expected_feature_manifest end,
      'canonical_qualification',case when version='frwhoop-server-1' then 'retained_legacy'
        else 'signed_reference_approval' end,
      'computation_mode',result->'computation_mode',
      'archive_status',processing->'archive_status','processing_status',processing->'processing_status',
      'revision_protocol',processing->'revision_protocol','timezone_id',processing->'timezone_id',
      'timezone_ids',processing->'timezone_ids','day_intervals',processing->'day_intervals',
      'context_intervals',processing->'context_intervals',
      'supports_boundary_overrides',feature_key='sleep' and version='frwhoop-physiology-2'));
    if feature_status='unavailable' then continue; end if;
    keys := case feature_key
      when 'hrv' then array['hrv_rmssd_ms','hrv_sdnn_ms','resting_hr_bpm','overnight_hr_bpm','hrv_summary','heart_rate_windows',
        'recovery','strain','spo2_pct','skin_temp_c','skin_temp_dev_c']
      when 'respiration' then array['resp_rate_bpm','respiration_summary','respiration_unavailable_reason']
      when 'sleep' then array['rest','sleep_total_min','sleep_in_bed_min','sleep_awake_min','sleep_light_min','sleep_deep_min',
        'sleep_rem_min','sleep_efficiency','sleep_onset_at','wake_onset_at','sleep_unstaged_min','state_unknown_min',
        'off_body_min','main_sleep_group_id','opportunity_kind','disturbances','full_day_sleep_epochs']
      else '{}'::text[] end;
    foreach key in array keys loop daily := daily || jsonb_build_object(key,result->'daily'->key); end loop;
    measurements := measurements || coalesce((select jsonb_agg(m) from jsonb_array_elements(
      coalesce(result->'measurements','[]'::jsonb)) m where m->>'feature'=feature_key),'[]'::jsonb);
    if feature_key='sleep' then
      nights := coalesce(result->'nights','[]'::jsonb);
      sleep_overrides := public.physiology_owned_sleep_overrides(p_user,device,p_day);
    end if;
  end loop;
  -- Sleep ownership alone cannot authorize embedded physiology from a different snapshot.
  if not coalesce(features->'hrv'->>'status' in ('available','stale')
    and features->'hrv'->>'algorithm_version'=features->'sleep'->>'algorithm_version'
    and features->'hrv'->>'device_id'=features->'sleep'->>'device_id'
    and (features->'hrv'->'input_revision') is not distinct from (features->'sleep'->'input_revision'),false) then
    select coalesce(jsonb_agg(n-array['hrv_rmssd_ms','hrv_sdnn_ms','resting_hr_bpm','overnight_hr_bpm',
      'hrv_summary','heart_rate_windows','recovery','strain','spo2_pct','skin_temp_c','skin_temp_dev_c'] order by ordinal),'[]'::jsonb)
      into nights from jsonb_array_elements(nights) with ordinality as episode(n,ordinal);
  end if;
  if not coalesce(features->'respiration'->>'status' in ('available','stale')
    and features->'respiration'->>'algorithm_version'=features->'sleep'->>'algorithm_version'
    and features->'respiration'->>'device_id'=features->'sleep'->>'device_id'
    and (features->'respiration'->'input_revision') is not distinct from (features->'sleep'->'input_revision'),false) then
    select coalesce(jsonb_agg(n-array['resp_rate_bpm','respiration_summary','respiration_unavailable_reason'] order by ordinal),'[]'::jsonb)
      into nights from jsonb_array_elements(nights) with ordinality as episode(n,ordinal);
  end if;
  return jsonb_build_object('schema_version',2,'contract_revision',1,'user_id',p_user,'day',p_day,
    'algorithm_version',case when cardinality(array(select distinct unnest(selected_versions)))=1
      then selected_versions[1] else 'per_feature' end,
    'daily',case when computed is null then null else daily || jsonb_build_object('day',p_day,'computed_at',computed,
      'source_device_id',case when cardinality(array(select distinct unnest(selected_devices)))=1
        then selected_devices[1] else null end) end,
    'nights',nights,'features',features,'measurements',measurements,'sleep_overrides',sleep_overrides,
    'computed_at',computed,'stale',is_stale);
end $$;
revoke all on function public.server_scoring_read_contract(uuid,date,uuid) from public,anon;
grant execute on function public.server_scoring_read_contract(uuid,date,uuid) to authenticated,service_role;

create or replace function public.server_scoring_for_day(p_user uuid,p_day date)
returns jsonb language sql stable security invoker set search_path='' as $$
  select public.server_scoring_read_contract(p_user,p_day,null)
$$;
create or replace function public.server_scoring_for_device_day(p_user uuid,p_day date,p_device uuid)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
begin
  if p_device is null then raise exception 'owned device required' using errcode='42501'; end if;
  return public.server_scoring_read_contract(p_user,p_day,p_device);
end $$;
revoke all on function public.server_scoring_for_day(uuid,date) from public,anon;
grant execute on function public.server_scoring_for_day(uuid,date) to authenticated,service_role;
revoke all on function public.server_scoring_for_device_day(uuid,date,uuid) from public,anon,authenticated;
grant execute on function public.server_scoring_for_device_day(uuid,date,uuid) to service_role;

commit;
