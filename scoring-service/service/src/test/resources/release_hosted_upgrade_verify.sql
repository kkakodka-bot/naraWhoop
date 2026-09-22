\set ON_ERROR_STOP on
do $$
declare
  expected jsonb;
  actual jsonb;
  account_route jsonb;
  enrollment_route jsonb;
begin
  select value into expected from release_upgrade_fixture.expected where key='installations';
  select jsonb_agg(jsonb_build_object('source',source_id,'user',user_id,'platform',platform,
    'version',app_version,'revoked',revoked_at) order by source_id) into actual
    from public.noop_app_installations where app_version='hosted-upgrade-fixture';
  assert actual=expected, 'existing installation identity changed during upgrade';
  assert not exists(select 1 from public.noop_app_installations where app_version='hosted-upgrade-fixture'
    and (retired_at is not null or retirement_id is not null)),
    'upgrade retired an existing active installation';

  select value into expected from release_upgrade_fixture.expected where key='tokens';
  select jsonb_agg(jsonb_build_object('id',id,'user',user_id,'source',source_id,'kind',token_kind,
    'hash',token_hash,'revoked',revoked_at) order by id) into actual from public.noop_ingest_tokens
    where id in('a9910000-0000-4000-8000-000000000041','b9910000-0000-4000-8000-000000000041');
  assert actual=expected, 'installation credentials changed during upgrade';

  select value into expected from release_upgrade_fixture.expected where key='samples';
  select jsonb_agg(jsonb_build_object('user',user_id,'device',device_id,'source',source_id,
    'ts',ts,'bpm',bpm) order by user_id) into actual from public.noop_hr_samples where batch_id in(
      'a9910000-0000-4000-8000-000000000051','b9910000-0000-4000-8000-000000000051');
  assert actual=expected, 'existing raw samples changed during upgrade';

  select value into expected from release_upgrade_fixture.expected where key='work';
  select jsonb_agg(jsonb_build_object('user',user_id,'device',device_id,'day',day,
    'revision',input_revision,'timezone',timezone_id) order by user_id,day) into actual
    from public.physiology_work_items where user_id in(
      'a9910000-0000-4000-8000-000000000001','b9910000-0000-4000-8000-000000000001');
  assert actual=expected, 'existing work revisions changed during upgrade';

  select value into expected from release_upgrade_fixture.expected where key='result';
  select jsonb_agg(jsonb_build_object('user',user_id,'device',device_id,'day',period_day,
    'algorithm',algorithm_version,'revision',input_revision,'run',run_id,'payload',payload,
    'payload_hash',payload_hash,'status',publication_status) order by user_id,period_day) into actual
    from public.server_physiology_results where run_id='a9910000-0000-4000-8000-000000000061';
  assert actual=expected, 'immutable result changed during upgrade';

  select value into expected from release_upgrade_fixture.expected where key='object';
  select jsonb_agg(jsonb_build_object('id',id,'user',user_id,'device',device_id,'source',source_id,
    'token',ingest_token_id,'auth',auth_mode,'key',object_key,'sha256',sha256,'status',status)
    order by id) into actual from public.object_manifests where id='a9910000-0000-4000-8000-000000000071';
  assert actual=expected, 'raw object identity changed during upgrade';

  perform set_config('request.jwt.claim.role','service_role',true);
  account_route:=public.server_scoring_for_day('a9910000-0000-4000-8000-000000000001','2026-09-17');
  enrollment_route:=public.server_scoring_for_device_day('a9910000-0000-4000-8000-000000000001',
    '2026-09-17','a9910000-0000-4000-8000-000000000011');
  assert account_route#>>'{compute,mode}'='final_hosted', 'account route did not enter final hosted mode';
  assert enrollment_route#>>'{compute,mode}'='final_hosted', 'enrollment route did not enter final hosted mode';
  assert account_route->>'contract_revision'='2' and enrollment_route->>'contract_revision'='2',
    'account/enrollment contract revisions diverged';
  assert enrollment_route->>'user_id'='a9910000-0000-4000-8000-000000000001',
    'enrollment route lost owner identity';
  assert enrollment_route->'daily'->>'hrv_rmssd_ms'='42',
    'retained v1 result is not readable after upgrade';
end $$;

select jsonb_build_object(
  'status','PASS',
  'upgrade_baseline_full_identities',117,
  'pending_migrations_applied',7,
  'preserved_installations',2,
  'preserved_users',2,
  'preserved_devices',2,
  'preserved_raw_samples',2,
  'preserved_raw_objects',1,
  'preserved_immutable_results',1,
  'account_enrollment_contract_revision',2
)::text;
