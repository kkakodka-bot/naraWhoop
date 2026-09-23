\set ON_ERROR_STOP on
begin;

insert into auth.users(id) values
  ('a9910000-0000-4000-8000-000000000001'),
  ('b9910000-0000-4000-8000-000000000001');
insert into public.profiles(id,timezone) values
  ('a9910000-0000-4000-8000-000000000001','America/Los_Angeles'),
  ('b9910000-0000-4000-8000-000000000001','Europe/London')
on conflict(id) do update set timezone=excluded.timezone;
insert into public.devices(id,user_id,source_kind,external_device_id,device_family) values
  ('a9910000-0000-4000-8000-000000000011','a9910000-0000-4000-8000-000000000001','noop_push','whoop-UPGRADE-A','whoop5'),
  ('b9910000-0000-4000-8000-000000000011','b9910000-0000-4000-8000-000000000001','noop_push','whoop-UPGRADE-B','whoop5');
insert into public.noop_enrollment_codes(id,user_id,code_hash,expires_at,redeemed_source_id,redeemed_at,redemption_count) values
  ('a9910000-0000-4000-8000-000000000021','a9910000-0000-4000-8000-000000000001',repeat('a',64),now()+interval '1 day','a9910000-0000-4000-8000-000000000031',now(),1),
  ('b9910000-0000-4000-8000-000000000021','b9910000-0000-4000-8000-000000000001',repeat('b',64),now()+interval '1 day','b9910000-0000-4000-8000-000000000031',now(),1);
insert into public.noop_app_installations(source_id,user_id,enrollment_code_id,platform,app_version) values
  ('a9910000-0000-4000-8000-000000000031','a9910000-0000-4000-8000-000000000001','a9910000-0000-4000-8000-000000000021','ios','hosted-upgrade-fixture'),
  ('b9910000-0000-4000-8000-000000000031','b9910000-0000-4000-8000-000000000001','b9910000-0000-4000-8000-000000000021','android','hosted-upgrade-fixture');
insert into public.noop_ingest_tokens(id,user_id,token_hash,token_kind,source_id,expires_at,enrollment_code_id) values
  ('a9910000-0000-4000-8000-000000000041','a9910000-0000-4000-8000-000000000001',repeat('c',64),'installation','a9910000-0000-4000-8000-000000000031',now()+interval '1 day','a9910000-0000-4000-8000-000000000021'),
  ('b9910000-0000-4000-8000-000000000041','b9910000-0000-4000-8000-000000000001',repeat('d',64),'installation','b9910000-0000-4000-8000-000000000031',now()+interval '1 day','b9910000-0000-4000-8000-000000000021');

insert into public.noop_hr_samples(user_id,device_id,source_id,batch_id,ts,bpm) values
  ('a9910000-0000-4000-8000-000000000001','a9910000-0000-4000-8000-000000000011','a9910000-0000-4000-8000-000000000031','a9910000-0000-4000-8000-000000000051',1789603200,61),
  ('b9910000-0000-4000-8000-000000000001','b9910000-0000-4000-8000-000000000011','b9910000-0000-4000-8000-000000000031','b9910000-0000-4000-8000-000000000051',1789603200,72);

insert into public.server_physiology_results(user_id,device_id,period_day,algorithm_version,input_revision,
  run_id,manifest_hash,payload,payload_hash,computed_at,publication_status)
select 'a9910000-0000-4000-8000-000000000001','a9910000-0000-4000-8000-000000000011',
  '2026-09-17','frwhoop-server-1',w.input_revision,'a9910000-0000-4000-8000-000000000061',
  v.manifest_hash,p.payload,encode(sha256(convert_to(p.payload::text,'UTF8')),'hex'),now(),'final'
from public.physiology_work_items w
join public.physiology_algorithm_versions v on v.algorithm_version='frwhoop-server-1'
cross join lateral (select '{"daily":{"hrv_rmssd_ms":42,"resting_hr_bpm":51,"sleep_in_bed_min":480},"nights":[],"measurements":[]}'::jsonb payload) p
where w.user_id='a9910000-0000-4000-8000-000000000001'
  and w.device_id='a9910000-0000-4000-8000-000000000011' and w.day='2026-09-17';

insert into public.object_manifests(id,user_id,device_id,source_id,ingest_token_id,auth_mode,
  object_kind,object_key,start_at,end_at,period_day,sample_count,compressed_bytes,content_type,
  format,compression,schema_version,sha256,status,retention_class)
values('a9910000-0000-4000-8000-000000000071','a9910000-0000-4000-8000-000000000001',
  'a9910000-0000-4000-8000-000000000011','a9910000-0000-4000-8000-000000000031',
  'a9910000-0000-4000-8000-000000000041','installation','ppg',
  'upgrade-fixture/a991/raw.ppg.zst','2026-09-17T00:00:00Z','2026-09-17T00:05:00Z',
  '2026-09-17',300,1024,'application/x-protobuf','ppg_v1','zstd',1,repeat('1',64),'ready','core');

create schema release_upgrade_fixture;
create table release_upgrade_fixture.expected(key text primary key,value jsonb not null);
insert into release_upgrade_fixture.expected values
  ('installations',(select jsonb_agg(jsonb_build_object('source',source_id,'user',user_id,
    'platform',platform,'version',app_version,'revoked',revoked_at) order by source_id)
    from public.noop_app_installations where app_version='hosted-upgrade-fixture')),
  ('tokens',(select jsonb_agg(jsonb_build_object('id',id,'user',user_id,'source',source_id,
    'kind',token_kind,'hash',token_hash,'revoked',revoked_at) order by id)
    from public.noop_ingest_tokens where id in('a9910000-0000-4000-8000-000000000041','b9910000-0000-4000-8000-000000000041'))),
  ('samples',(select jsonb_agg(jsonb_build_object('user',user_id,'device',device_id,'source',source_id,
    'ts',ts,'bpm',bpm) order by user_id) from public.noop_hr_samples where batch_id in(
      'a9910000-0000-4000-8000-000000000051','b9910000-0000-4000-8000-000000000051'))),
  ('work',(select jsonb_agg(jsonb_build_object('user',user_id,'device',device_id,'day',day,
    'revision',input_revision,'timezone',timezone_id) order by user_id,day)
    from public.physiology_work_items where user_id in(
      'a9910000-0000-4000-8000-000000000001','b9910000-0000-4000-8000-000000000001'))),
  ('result',(select jsonb_agg(jsonb_build_object('user',user_id,'device',device_id,'day',period_day,
    'algorithm',algorithm_version,'revision',input_revision,'run',run_id,'payload',payload,
    'payload_hash',payload_hash,'status',publication_status) order by user_id,period_day)
    from public.server_physiology_results where run_id='a9910000-0000-4000-8000-000000000061')),
  ('object',(select jsonb_agg(jsonb_build_object('id',id,'user',user_id,'device',device_id,
    'source',source_id,'token',ingest_token_id,'auth',auth_mode,'key',object_key,'sha256',sha256,
    'status',status) order by id) from public.object_manifests where id='a9910000-0000-4000-8000-000000000071'));

-- The original hosted boundary precedes this table. The runner calls this fixture
-- only after all released predecessors and immediately before the new forward repair.
create function release_upgrade_fixture.seed_previous_compute_dispositions()
returns void language plpgsql as $$
declare prior jsonb; inserted integer;
begin
  assert (select unavailable_status='unsupported' and policy_version='vps-only-1'
    from public.compute_family_policy where family='insights'), 'predecessor policy differs';
  insert into public.server_physiology_results(user_id,device_id,period_day,algorithm_version,input_revision,
    run_id,manifest_hash,payload,payload_hash,computed_at,publication_status)
  select r.user_id,r.device_id,r.period_day,'frwhoop-physiology-2',r.input_revision,
    'a9910000-0000-4000-8000-000000000062',v.manifest_hash,p.payload,
    encode(sha256(convert_to(p.payload::text,'UTF8')),'hex'),now(),'final'
  from public.server_physiology_results r
  join public.physiology_algorithm_versions v on v.algorithm_version='frwhoop-physiology-2'
  cross join lateral (select '{"daily":{},"nights":[],"measurements":[],"calendar_ownership":{"timezone_ids":["America/Los_Angeles"]}}'::jsonb payload) p
  where r.run_id='a9910000-0000-4000-8000-000000000061';
  perform set_config('request.jwt.claim.role','service_role',true);
  select public.publish_compute_dispositions('a9910000-0000-4000-8000-000000000001',
    'a9910000-0000-4000-8000-000000000011','2026-09-17',input_revision) into inserted
  from public.server_physiology_results where run_id='a9910000-0000-4000-8000-000000000062';
  assert inserted=27, 'predecessor dispositions were not generated';
  prior:=public.server_scoring_for_device_day('a9910000-0000-4000-8000-000000000001',
    '2026-09-17','a9910000-0000-4000-8000-000000000011');
  assert prior#>>'{compute,families,insights,status}'='unsupported', 'fixture did not reproduce old hardware label';
  assert prior#>>'{compute,families,insights,reason}'='qualified_insight_producer_unavailable',
    'fixture did not reproduce old producer reason';
  insert into release_upgrade_fixture.expected(key,value)
    select 'old_dispositions',jsonb_agg(to_jsonb(d) order by d.revision)
    from public.server_compute_dispositions d where d.user_id='a9910000-0000-4000-8000-000000000001';
end $$;
commit;
