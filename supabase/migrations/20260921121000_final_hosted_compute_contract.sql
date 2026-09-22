begin;
set local lock_timeout='5s';
set local statement_timeout='60s';

create table public.compute_family_policy (
  family text primary key,
  metrics text[] not null,
  feature text,
  unavailable_status text not null check(unavailable_status in ('unsupported','unqualified')),
  unavailable_reason text not null,
  policy_version text not null default 'vps-only-1'
);
insert into public.compute_family_policy(family,metrics,feature,unavailable_status,unavailable_reason) values
 ('live_hr_selection',array['live_hr_bpm'],null,'unsupported','device_observation_only'),
 ('night_hrv',array['hrv_rmssd_ms','hrv_sdnn_ms','resting_hr_bpm'],'hrv','unqualified','selected_result_required'),
 ('current_hrv',array['current_hrv'],'hrv','unqualified','qualified_closed_window_required'),
 ('spot_hrv',array['spot_hrv_rmssd_ms','spot_hrv_sdnn_ms'],null,'unqualified','verified_session_beat_clock_required'),
 ('sleep',array['sleep_total_min','sleep_in_bed_min','sleep_awake_min','sleep_light_min','sleep_deep_min','sleep_rem_min','sleep_efficiency','disturbances','sleep_sessions'],'sleep','unqualified','selected_result_required'),
 ('sleep_history',array['sleep_performance','hours_vs_needed_pct','sleep_consistency','restorative_pct','restorative_min','sleep_need_min','sleep_debt_min'],null,'unqualified','historical_producer_shadow'),
 ('respiration',array['resp_rate_bpm'],'respiration','unqualified','selected_result_required'),
 ('recovery',array['recovery'],'hrv','unqualified','selected_result_required'),
 ('strain_energy',array['strain','active_kcal_est','avg_hr','max_hr','hr_zones13_min','hr_zones45_min','hr_zones_all_min','strength_min'],'hrv','unqualified','historical_producer_shadow'),
 ('steps',array['steps','steps_est'],null,'unqualified','historical_producer_shadow'),
 ('workouts',array['exercise_count','workouts','workout_strain','workout_kcal','workout_hr_recovery'],null,'unqualified','historical_producer_shadow'),
 ('live_workout',array['live_workout_effort'],null,'unqualified','qualified_incremental_workout_required'),
 ('oxygen',array['spo2_pct','spo2_red','spo2_ir','spo2_candidate'],'hrv','unqualified','calibrated_oxygen_source_required'),
 ('temperature',array['skin_temp_c','skin_temp_dev_c'],'hrv','unqualified','qualified_temperature_source_required'),
 ('intraday_temperature',array['temperature_5min_c'],null,'unqualified','qualified_intraday_temperature_required'),
 ('ppg_hr',array['derived_ppg_hr'],null,'unqualified','optical_clock_channel_unqualified'),
 ('stress',array['stress','daytime_stress_mean','daytime_stress_high_min','baevsky_stress_index','frequency_hrv'],null,'unqualified','historical_producer_shadow'),
 ('stress_events',array['stress_onset'],null,'unqualified','qualified_live_decision_required'),
 ('illness',array['illness_score','illness_distance'],null,'unqualified','historical_producer_shadow'),
 ('cycle',array['cycle_phase','cycle_index'],null,'unqualified','historical_producer_shadow'),
 ('circadian',array['circadian_phase_hour','circadian_offset_min'],null,'unqualified','historical_producer_shadow'),
 ('readiness_load',array['readiness','training_load','acute_load','chronic_load','training_balance','acwr','training_monotony'],null,'unqualified','historical_producer_shadow'),
 ('fitness_longevity',array['fitness_age','vo2max_est','vitality','body_age'],null,'unqualified','historical_producer_shadow'),
 ('baselines',array['historical_baselines','recovery_drivers','recovery_forecast'],null,'unqualified','historical_producer_shadow'),
 ('biofeedback',array['resonance_frequency','resonance_pace'],null,'unqualified','qualified_session_response_required'),
 ('live_coaching',array['coaching_hr_band','coaching_decision'],null,'unqualified','qualified_live_decision_required'),
 ('insights',array['insights'],null,'unsupported','qualified_insight_producer_unavailable');
revoke all on public.compute_family_policy from public,anon,authenticated;
grant select on public.compute_family_policy to authenticated,service_role;

create table public.server_compute_dispositions (
  revision bigint generated always as identity primary key,
  user_id uuid not null references auth.users on delete cascade,
  device_id uuid not null references public.devices on delete cascade,
  day date not null,
  family text not null references public.compute_family_policy,
  input_revision bigint not null check(input_revision>=0),
  source_result_hash text not null,
  policy_version text not null,
  status text not null,
  reason text not null,
  timezone_id text,
  calendar_ownership jsonb,
  computed_at timestamptz not null default now(),
  unique(user_id,device_id,day,family,input_revision,policy_version)
);
alter table public.server_compute_dispositions enable row level security;
create policy compute_disposition_owner on public.server_compute_dispositions for select to authenticated using(user_id=auth.uid());
grant select on public.server_compute_dispositions to authenticated,service_role;
grant insert on public.server_compute_dispositions to service_role;
grant usage,select on sequence public.server_compute_dispositions_revision_seq to service_role;

-- Called by the deterministic JVM after immutable physiology publication. No numeric
-- inference or qualification occurs here; this records the worker's explicit abstentions.
create function public.publish_compute_dispositions(p_user uuid,p_device uuid,p_day date,p_revision bigint)
returns integer language plpgsql security invoker set search_path=pg_catalog,public as $$
declare n integer; zone text; calendar jsonb; source_hash text;
begin
 if auth.role() is distinct from 'service_role' and current_user not in ('postgres','supabase_admin') then
   raise exception 'worker required' using errcode='42501'; end if;
 if not exists(select 1 from server_physiology_results where user_id=p_user and device_id=p_device
   and period_day=p_day and input_revision=p_revision and algorithm_version='frwhoop-physiology-2') then
   raise exception 'published input revision required' using errcode='23514'; end if;
 select payload->'calendar_ownership',payload_hash into calendar,source_hash from server_physiology_results where user_id=p_user and device_id=p_device
   and period_day=p_day and input_revision=p_revision and algorithm_version='frwhoop-physiology-2';
 zone:=case when jsonb_array_length(calendar->'timezone_ids')=1 then calendar->'timezone_ids'->>0 end;
 insert into server_compute_dispositions(user_id,device_id,day,family,input_revision,source_result_hash,policy_version,status,reason,timezone_id,calendar_ownership)
 select p_user,p_device,p_day,family,p_revision,source_hash,policy_version,unavailable_status,unavailable_reason,zone,calendar
 from compute_family_policy on conflict do nothing;
 get diagnostics n=row_count;
 return n;
end $$;
revoke all on function public.publish_compute_dispositions(uuid,uuid,date,bigint) from public,anon,authenticated;
grant execute on function public.publish_compute_dispositions(uuid,uuid,date,bigint) to service_role;

create function public.process_compute_disposition()
returns boolean language plpgsql security invoker set search_path=pg_catalog,public as $$
declare r server_physiology_results;
begin
 if auth.role() is distinct from 'service_role' and current_user not in ('postgres','supabase_admin') then
   raise exception 'worker required' using errcode='42501'; end if;
 select s.* into r from server_physiology_results s where s.algorithm_version='frwhoop-physiology-2'
   and exists(select 1 from compute_family_policy p where not exists(select 1 from server_compute_dispositions d
     where d.user_id=s.user_id and d.device_id=s.device_id and d.day=s.period_day and d.family=p.family
       and d.input_revision=s.input_revision and d.policy_version=p.policy_version))
   order by s.computed_at,s.user_id,s.device_id limit 1;
 if r.user_id is null then return false; end if;
 perform publish_compute_dispositions(r.user_id,r.device_id,r.period_day,r.input_revision);
 return true;
end $$;
revoke all on function public.process_compute_disposition() from public,anon,authenticated;
grant execute on function public.process_compute_disposition() to service_role;

alter function public.server_scoring_read_contract(uuid,date,uuid) rename to server_scoring_read_contract_v1;
create function public.server_scoring_read_contract(p_user uuid,p_day date,p_device uuid default null)
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
     and d.day=p_day and d.family=policy.family order by input_revision desc,revision desc limit 1;
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
revoke all on function public.server_scoring_read_contract(uuid,date,uuid) from public,anon;
grant execute on function public.server_scoring_read_contract(uuid,date,uuid) to authenticated,service_role;

create function public.server_scoring_pending_contract(p_user uuid,p_day date)
returns jsonb language plpgsql stable security invoker set search_path=pg_catalog,public as $$
declare families jsonb;
begin
 if auth.uid() is distinct from p_user and auth.role() is distinct from 'service_role' then
   raise exception 'owner required' using errcode='42501'; end if;
 select jsonb_object_agg(p.family,jsonb_build_object('owner','server','metrics',p.metrics,
   'status','unavailable','reason','device_registration_pending','result_revision',null,'input_revision',null,
   'algorithm_version','vps-only-1','configuration_version',p.policy_version,'model_version',null,
   'preprocessing_version',null,'quality_version',null,'manifest_hash',null,'feature_manifest_hash',null,
   'canonical_qualification',null,'owner_id',p_user,'device_id',null,'window',p_day,'timezone_id',null,
   'computed_at',null,'observed_through',null,'freshness','unavailable','expires_at',null,'decision_id',null,
   'values',(select jsonb_object_agg(m,null) from unnest(p.metrics) m),'details','{}'::jsonb)) into families
   from compute_family_policy p;
 return jsonb_build_object('schema_version',2,'contract_revision',2,'user_id',p_user,'day',p_day,
   'algorithm_version','per_feature','daily',null,'nights','[]'::jsonb,'measurements','[]'::jsonb,'sleep_overrides','[]'::jsonb,
   'computed_at',null,'stale',true,'features',(select jsonb_object_agg(f,jsonb_build_object('status','unavailable',
     'reason','device_registration_pending')) from unnest(array['sleep','hrv','respiration']) f),
   'compute',jsonb_build_object('mode','final_hosted','policy_version','vps-only-1','owner_id',p_user,
     'device_id',null,'day',p_day,'families',families));
end $$;
revoke all on function public.server_scoring_pending_contract(uuid,date) from public,anon,authenticated;
grant execute on function public.server_scoring_pending_contract(uuid,date) to service_role;
-- Rebind SQL wrappers after rename, retaining their authentication surfaces.
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
commit;
