-- Forward-only read eligibility. Original results, hashes and archives remain immutable.
-- Frozen v1 stage emissions consume RR-derived respiratory regularity; without
-- the explicit RR-excluded receipt, stage-dependent sleep fields are ineligible.
-- Initial session bounds and resting HR depend on HR/gravity, not RR.
begin;
set local lock_timeout='5s';
set local statement_timeout='60s';

create function public.server_legacy_read_eligibility(p_payload jsonb) returns jsonb
language plpgsql immutable security invoker set search_path=pg_catalog,public as $$
declare
 result jsonb:=p_payload; daily jsonb:=p_payload->'daily'; nights jsonb:='[]'; n jsonb;
 marker jsonb:=p_payload->'input_eligibility'; excluded boolean;
 key text; missing jsonb:='{}'; reason jsonb:='{"status":"unqualified","reason":"beat_timing_unverified"}';
 always_keys text[]:=array['hrv_rmssd_ms','hrv_sdnn_ms','resp_rate_bpm','recovery'];
 sleep_keys text[]:=array['sleep_total_min','sleep_awake_min','sleep_light_min','sleep_deep_min',
   'sleep_rem_min','sleep_efficiency','disturbances','rest','sleep_onset_at','wake_onset_at',
   'sleep_unstaged_min','state_unknown_min','off_body_min'];
begin
 excluded:=coalesce(marker='{"policy_version":"legacy-rr-excluded-1","rr_input":"excluded"}'::jsonb,false);
 foreach key in array always_keys loop
   missing:=missing||jsonb_build_object(key,reason);
   if jsonb_typeof(daily)='object' then daily:=daily||jsonb_build_object(key,null); end if;
 end loop;
 if jsonb_typeof(daily)='object' then
   daily:=daily||jsonb_build_object('hrv_summary',null,'respiration_summary',null,
     'respiration_unavailable_reason','beat_timing_unverified');
 end if;
 if not excluded then
   foreach key in array sleep_keys loop
     missing:=missing||jsonb_build_object(key,reason);
     if jsonb_typeof(daily)='object' then daily:=daily||jsonb_build_object(key,null); end if;
   end loop;
   if jsonb_typeof(daily)='object' then daily:=daily||jsonb_build_object('full_day_sleep_epochs','[]'::jsonb); end if;
 end if;
 for n in select value from jsonb_array_elements(coalesce(p_payload->'nights','[]')) loop
   foreach key in array always_keys||array['hrv_summary','respiration_summary','avg_hrv','avg_hrv_ms','sdnn_ms'] loop
     n:=n||jsonb_build_object(key,null);
   end loop;
   n:=n||jsonb_build_object('respiration_unavailable_reason','beat_timing_unverified');
   if not excluded then
     foreach key in array array['asleep_min','awake_min','light_min','deep_min','rem_min','efficiency',
         'disturbances','rest','sleep_unstaged_min','state_unknown_min','off_body_min','state_coverage'] loop
       n:=n||jsonb_build_object(key,null);
     end loop;
     n:=n||jsonb_build_object('stages','[]'::jsonb,'hypnogram','[]'::jsonb,
       'measurement_available',false,'measurement_unavailable_reason','beat_timing_unverified');
   end if;
   nights:=nights||jsonb_build_array(n);
 end loop;
 return result||jsonb_build_object('daily',daily,'nights',nights,'measurements','[]'::jsonb,
   'input_eligibility',case when excluded then marker else null end,'metric_availability',missing);
end $$;
revoke all on function public.server_legacy_read_eligibility(jsonb) from public,anon;
grant execute on function public.server_legacy_read_eligibility(jsonb) to authenticated,service_role;

create or replace function internal.engine_publish_legacy_fenced(p_secret text,p_payload jsonb) returns jsonb
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
  -- A producer gate receipt is not a beat qualification or model approval. Only
  -- the explicit RR-excluded transport may assert this exact immutable marker.
  if p_payload ? 'input_eligibility' and p_payload->'input_eligibility' is distinct from
    '{"policy_version":"legacy-rr-excluded-1","rr_input":"excluded"}'::jsonb then
    raise exception 'invalid legacy input eligibility' using errcode='22023';
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
  if exists(select 1 from public.server_physiology_results where user_id=u and device_id=d
      and period_day=period and algorithm_version='frwhoop-server-1' and input_revision=revision) then
    return jsonb_build_object('ok',true,'input_revision',revision);
  end if;
  -- The original serializer's upsert locks retain this device's serialized rows until
  -- its immutable snapshot is captured. Another device can never supply this snapshot.
  -- Do not call the pre-fence compatibility wrapper or acquire its inverted owner lock.
  perform internal.engine_ingest_scored(p_secret,p_payload);
  select manifest_hash into manifest from public.physiology_algorithm_versions where algorithm_version='frwhoop-server-1';
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
  if stored is null then raise exception 'baseline snapshot missing after serialization' using errcode='22023'; end if;
  if p_payload ? 'input_eligibility' then
    stored:=stored||jsonb_build_object('input_eligibility',p_payload->'input_eligibility');
  end if;
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

create or replace function public.server_scoring_read_contract_before_signals(p_user uuid, p_day date, p_device uuid default null)
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
    if version='frwhoop-server-1' and result is not null then
      result:=public.server_legacy_read_eligibility(result);
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
      'input_eligibility',result->'input_eligibility','metric_availability',result->'metric_availability',
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

create or replace function public.server_scoring_read_contract(p_user uuid,p_day date,p_device uuid default null)
returns jsonb language plpgsql stable security invoker set search_path=pg_catalog,public as $$
declare
 base jsonb; families jsonb:='{}'; policy compute_family_policy; feature jsonb;
 disposition server_compute_dispositions; stored server_physiology_results;
 result jsonb; vals jsonb; metric text; status text; reason text; revision text;
 input_revision bigint; computed timestamptz; device uuid; details jsonb; hrv_window jsonb; expires timestamptz;
 required_revisions jsonb:='{}'; required_revision bigint;
begin
 base:=server_scoring_read_contract_v1(p_user,p_day,p_device);
 for policy in select * from compute_family_policy order by family loop
   feature:=base->'features'->policy.feature;
   device:=coalesce(p_device,(base->'daily'->>'source_device_id')::uuid,(feature->>'device_id')::uuid);
   -- The work queue is private. Its existing owner-authorized projection is
   -- shared by authenticated and service-role callers; never grant queue reads.
   if device is not null then
     if not required_revisions ? device::text then
       required_revisions:=required_revisions||jsonb_build_object(device::text,
         physiology_processing_metadata(p_user,device,p_day,'frwhoop-physiology-2',null)->'required_revision');
     end if;
     required_revision:=(required_revisions->>device::text)::bigint;
   else required_revision:=null; end if;
   disposition:=null; stored:=null;
   select * into disposition from server_compute_dispositions d where d.user_id=p_user and d.device_id=device
     and d.day=p_day and d.family=policy.family and d.policy_version=policy.policy_version
     order by input_revision desc,revision desc limit 1;
   vals:='{}'; details:='{}'; expires:=null;
   foreach metric in array policy.metrics loop vals:=vals||jsonb_build_object(metric,null); end loop;
   status:=coalesce(disposition.status,policy.unavailable_status);
   reason:=coalesce(disposition.reason,policy.unavailable_reason);
   revision:=case when disposition.revision is not null then 'compute:'||disposition.revision end;
   input_revision:=disposition.input_revision; computed:=disposition.computed_at;
   if device is null then status:='unavailable'; reason:='device_registration_pending'; end if;
   if policy.feature is not null then
     if feature->>'status' in ('available','stale') then
       select * into stored from server_physiology_results r where r.user_id=p_user and r.device_id=device
         and r.period_day=p_day and r.algorithm_version=feature->>'algorithm_version'
         and r.input_revision=(feature->>'input_revision')::bigint;
       if stored.payload_hash is not null then
         revision:='sha256:'||stored.payload_hash; input_revision:=stored.input_revision; computed:=stored.computed_at;
         status:=feature->>'status'; reason:=feature->>'reason';
         foreach metric in array policy.metrics loop
           vals:=vals||jsonb_build_object(metric,case
             when metric='sleep_sessions' then base->'nights'
             when metric='sleep_efficiency' and jsonb_typeof(base->'daily'->metric)='number'
               then to_jsonb((base->'daily'->>metric)::numeric*100)
             else base->'daily'->metric end);
         end loop;
         if policy.family='current_hrv' then
           -- Window selection belongs to the server result. The client may render the
           -- authorized series, but must not reconstruct RMSSD from RR observations.
           details:=jsonb_build_object('measurements',(select coalesce(jsonb_agg(m),'[]')
             from jsonb_array_elements(coalesce(base->'measurements','[]')) m where m->>'feature'='hrv'));
           status:='insufficient_quality'; reason:='qualified_closed_window_required';
           select m into hrv_window from jsonb_array_elements(coalesce(base->'measurements','[]')) m
             where m->>'feature'='hrv' and m->>'metric'='rmssd' and m->>'unit'='ms'
             and m->>'measurement_schema_version'='1' and m->>'user_id'=p_user::text
             and m->>'device_id'=device::text and m->>'input_revision'=stored.input_revision::text
             and (m->>'start')::bigint%300=0 and (m->>'end')::bigint-(m->>'start')::bigint=300
             and (m->>'end')::bigint<=extract(epoch from now())
             order by (m->>'end')::bigint desc limit 1;
           if hrv_window is not null then
             expires:=to_timestamp((hrv_window->>'end')::double precision)+interval '10 minutes';
             details:=details||jsonb_build_object('selected_window',hrv_window);
             if hrv_window->>'measurement_valid'='true' and hrv_window->>'reason' is null
               and nullif(hrv_window->>'source','') is not null and nullif(hrv_window->>'modality','') is not null
               and jsonb_typeof(hrv_window->'observed_rmssd_ms')='number'
               and (hrv_window->>'observed_rmssd_ms')::numeric>=0 then
               vals:=jsonb_build_object('current_hrv',hrv_window->'observed_rmssd_ms');
               status:=feature->>'status'; reason:=feature->>'reason';
               if expires<=now() then status:='stale'; reason:='window_expired'; end if;
             else reason:=coalesce(hrv_window->>'reason',reason); end if;
           end if;
         elsif policy.family='sleep' then details:=jsonb_build_object(
           'nights',base->'nights','sleep_overrides',base->'sleep_overrides',
           'daily_compatibility',jsonb_build_object(
             'sleep_onset_at',base->'daily'->'sleep_onset_at',
             'wake_onset_at',base->'daily'->'wake_onset_at',
             'sleep_unstaged_min',base->'daily'->'sleep_unstaged_min',
             'state_unknown_min',base->'daily'->'state_unknown_min',
             'off_body_min',base->'daily'->'off_body_min',
             'main_sleep_group_id',base->'daily'->'main_sleep_group_id',
             'opportunity_kind',base->'daily'->'opportunity_kind',
             'full_day_sleep_epochs',base->'daily'->'full_day_sleep_epochs'));
         elsif policy.family='respiration' then details:=jsonb_build_object('summary',base->'daily'->'respiration_summary');
         elsif policy.family='night_hrv' then details:=jsonb_build_object('summary',base->'daily'->'hrv_summary','heart_rate_windows',base->'daily'->'heart_rate_windows');
         end if;
         if status in ('available','stale') and not exists(select 1 from jsonb_each(vals) e where e.value<>'null'::jsonb) then
           status:='insufficient_input'; reason:=coalesce(feature->>'reason','no_qualified_value');
         end if;
       else status:='unavailable'; reason:='immutable_result_required'; end if;
     else
       status:=case when feature->>'reason'='unqualified_version' then 'unqualified'
         when feature->>'reason'='awaiting_result' then 'processing' else 'unavailable' end;
       reason:=coalesce(feature->>'reason','awaiting_result');
     end if;
   end if;
   if stored.payload_hash is not null and feature->>'algorithm_version'='frwhoop-server-1' then
     details:=details||jsonb_build_object('input_eligibility',feature->'input_eligibility',
       'read_eligibility_policy','legacy-beat-read-1','metric_availability',
       coalesce((select jsonb_object_agg(e.key,e.value) from jsonb_each(feature->'metric_availability') e
         where e.key=any(policy.metrics)),'{}'::jsonb));
     if policy.family in ('current_hrv','respiration','recovery') or
       (policy.family='night_hrv' and vals->'resting_hr_bpm'='null'::jsonb) then
       status:='unqualified'; reason:='beat_timing_unverified';
       foreach metric in array policy.metrics loop vals:=vals||jsonb_build_object(metric,null); end loop;
     end if;
     if policy.family='current_hrv' then
       details:=details||jsonb_build_object('measurements','[]'::jsonb);
       details:=details-'selected_window'; expires:=null;
     end if;
   end if;
   result:=jsonb_build_object('owner','server','metrics',policy.metrics,'status',status,'reason',reason,
     'result_revision',revision,'input_revision',input_revision,
     'algorithm_version',case when stored.payload_hash is not null then feature->>'algorithm_version' else 'vps-only-1' end,
     'selected_algorithm_version',feature->>'algorithm_version',
     'configuration_version',case when stored.payload_hash is null then policy.policy_version else stored.payload->>'configuration_version' end,
     'model_version',stored.payload->'feature_manifests'->policy.feature->>'model_version',
     'preprocessing_version',stored.payload->'feature_manifests'->policy.feature->>'preprocessing_version',
     'quality_version',stored.payload->'feature_manifests'->policy.feature->>'quality_policy_version',
     'manifest_hash',feature->'manifest_hash','feature_manifest_hash',feature->'feature_manifest_hash',
     'canonical_qualification',case when stored.payload_hash is not null then feature->'canonical_qualification' end,
     'owner_id',p_user,'device_id',device,'window',p_day,'timezone_id',case when stored.payload_hash is not null then
       case when jsonb_array_length(stored.payload->'calendar_ownership'->'timezone_ids')=1
         then stored.payload->'calendar_ownership'->'timezone_ids'->>0 end
       else coalesce(disposition.timezone_id,case when disposition.revision is null then feature->>'timezone_id' end) end,
     'computed_at',computed,'observed_through',stored.observed_through,
     'freshness',case when expires<=now() then 'expired'
       when feature->>'status'='stale' then 'stale'
       when disposition.input_revision<required_revision then 'stale'
       when revision is null then 'unavailable' else 'current' end,
     'expires_at',expires,'decision_id',null,'values',vals,'details',details||jsonb_build_object('calendar_ownership',
       coalesce(stored.payload->'calendar_ownership',disposition.calendar_ownership),
       'source_result_hash',coalesce(stored.payload_hash,disposition.source_result_hash),
       'configuration_metadata_status',case when stored.payload_hash is not null and stored.payload->>'configuration_version' is null then 'unavailable_in_source_contract' else 'available' end));
   families:=families||jsonb_build_object(policy.family,result);
 end loop;
 return base||jsonb_build_object('contract_revision',2,'compute',jsonb_build_object('mode','final_hosted',
   'policy_version','vps-only-1','owner_id',p_user,'device_id',coalesce(p_device,(base->'daily'->>'source_device_id')::uuid),
   'day',p_day,'families',families));
end $$;
notify pgrst,'reload schema';
commit;
