\set ON_ERROR_STOP on
begin;
-- Synthetic historical v1 result. No original payload or input is repaired in place.
do $$
declare
 u uuid:='aa291000-0000-4000-8000-000000000001'; d uuid:='aa291000-0000-4000-8000-000000000002';
 other uuid:='aa291000-0000-4000-8000-000000000003'; legacy_payload jsonb; oldhash text; m text; result jsonb; marked jsonb;
 helper text; key text;
begin
 insert into auth.users(id) values(u),(other);
 insert into public.profiles(id,timezone) values(u,'UTC'),(other,'UTC') on conflict(id) do nothing;
 insert into public.devices(id,user_id,source_kind,external_device_id,device_family)
   values(d,u,'noop_push','whoop-LEGACY-READ','whoop5');
 select manifest_hash into m from public.physiology_algorithm_versions where algorithm_version='frwhoop-server-1';
 legacy_payload:=jsonb_build_object('daily',jsonb_build_object('hrv_rmssd_ms',42,'hrv_sdnn_ms',52,'resting_hr_bpm',51,
   'resp_rate_bpm',12,'recovery',77,'sleep_total_min',450,'sleep_in_bed_min',480,'sleep_awake_min',30,
   'sleep_light_min',200,'sleep_deep_min',120,'sleep_rem_min',130,'sleep_efficiency',0.9375,'rest',90,
   'disturbances',3,'hrv_summary',jsonb_build_object('value',42),'respiration_summary',jsonb_build_object('value',12)),
   'nights',jsonb_build_array(jsonb_build_object('id','historical','user_id',u,'device_id',d,
   'algorithm_version','frwhoop-server-1','start_at','2026-09-17T00:00:00Z','end_at','2026-09-17T08:00:00Z',
   'hrv_rmssd_ms',42,'hrv_sdnn_ms',52,'resting_hr_bpm',51,'resp_rate_bpm',12,'recovery',77,
   'asleep_min',450,'in_bed_min',480,'deep_min',120,'efficiency',0.9375,
   'stages',jsonb_build_array(jsonb_build_object('start',1789603200,'end',1789632000,'stage','deep')))),
   'measurements','[]'::jsonb);
 perform public.scoring_enqueue_legacy_fenced(u,d,'2026-09-17','UTC',0);
 perform public.scoring_enqueue_legacy_fenced(u,d,'2026-09-18','UTC',0);
 oldhash:=encode(sha256(convert_to(legacy_payload::text,'UTF8')),'hex');
 insert into public.server_physiology_results(user_id,device_id,period_day,algorithm_version,input_revision,
   run_id,manifest_hash,payload,payload_hash,computed_at,publication_status)
 values(u,d,'2026-09-17','frwhoop-server-1',1,gen_random_uuid(),m,legacy_payload,oldhash,now(),'final');
 perform set_config('request.jwt.claim.role','service_role',true);
 foreach helper in array array['server_scoring_read_contract_before_signals','server_scoring_read_contract_v1',
                               'server_scoring_read_contract','server_scoring_for_device_day'] loop
   execute format('select public.%I($1,$2,$3)',helper) into result using u,'2026-09-17'::date,d;
   foreach key in array array['hrv_rmssd_ms','hrv_sdnn_ms','resp_rate_bpm','recovery','sleep_total_min',
       'sleep_awake_min','sleep_light_min','sleep_deep_min','sleep_rem_min','sleep_efficiency','disturbances','rest'] loop
     assert result#>array['daily',key]='null'::jsonb, helper||' leaked '||key;
   end loop;
   assert result#>>'{daily,resting_hr_bpm}'='51' and result#>>'{daily,sleep_in_bed_min}'='480',
     helper||' dropped independent scalar result';
   assert result#>'{nights,0,hrv_rmssd_ms}'='null'::jsonb and result#>'{nights,0,asleep_min}'='null'::jsonb
     and result#>'{nights,0,stages}'='[]'::jsonb, helper||' leaked nested result';
   assert result#>>'{nights,0,resting_hr_bpm}'='51' and result#>>'{nights,0,in_bed_min}'='480', 'lost session scalars';
 end loop;
 assert result#>>'{compute,families,respiration,status}'='unqualified' and
   result#>>'{compute,families,respiration,reason}'='beat_timing_unverified','respiration missingness absent';
 assert result#>>'{compute,families,night_hrv,details,metric_availability,hrv_rmssd_ms,reason}'='beat_timing_unverified',
   'partial family missingness absent';
 perform set_config('request.jwt.claim.sub',u::text,true);
 perform set_config('request.jwt.claim.role','authenticated',true);
 assert public.server_scoring_for_day(u,'2026-09-17')=result, 'account and enrolled APIs diverge';
 begin
   perform public.server_scoring_for_day(other,'2026-09-17');
   raise exception 'cross-owner read accepted';
 exception when insufficient_privilege then null; end;
 perform set_config('request.jwt.claim.role','service_role',true);
 -- A new exact exclusion marker permits existing scalar sleep, never beat-derived outputs.
 marked:=legacy_payload||'{"input_eligibility":{"policy_version":"legacy-rr-excluded-1","rr_input":"excluded"}}'::jsonb;
 insert into public.server_physiology_results(user_id,device_id,period_day,algorithm_version,input_revision,
   run_id,manifest_hash,payload,payload_hash,computed_at,publication_status)
 values(u,d,'2026-09-18','frwhoop-server-1',1,gen_random_uuid(),m,marked,
   encode(sha256(convert_to(marked::text,'UTF8')),'hex'),now(),'final');
 result:=public.server_scoring_for_device_day(u,'2026-09-18',d);
 assert result#>>'{daily,sleep_total_min}'='450' and result#>>'{daily,resting_hr_bpm}'='51', 'excluded scalar result lost';
 assert result#>'{daily,hrv_rmssd_ms}'='null'::jsonb and result#>'{daily,resp_rate_bpm}'='null'::jsonb
   and result#>'{daily,recovery}'='null'::jsonb, 'exclusion marker qualified a beat metric';
 assert result#>'{compute,families,sleep,details,input_eligibility}'=marked->'input_eligibility','marker missing from envelope';
 assert jsonb_array_length(result#>'{nights,0,stages}')=1,'excluded scalar hypnogram lost';
 assert public.server_legacy_read_eligibility(marked||'{"input_eligibility":{"policy_version":"legacy-rr-excluded-1","rr_input":"excluded","qualification":"fake"}}')#>'{daily,sleep_total_min}'='null'::jsonb,
   'extra marker key authorized contaminated sleep';
 assert (select payload_hash=oldhash and server_physiology_results.payload=legacy_payload
   from public.server_physiology_results where user_id=u and period_day='2026-09-17'), 'historical immutable bytes changed';
end $$;
rollback;
select '{"status":"PASS","fixture":"synthetic_legacy_beat_read_eligibility","old_payloads_unchanged":true,"account_enrolled_and_old_helpers":true,"physical_acceptance":"NOT_MEASURED"}'::jsonb;
