\set ON_ERROR_STOP on
do $$
declare
  object_name text;
  definition text;
  metric_count integer;
  owned_metric_count integer;
begin
  foreach object_name in array array[
    'public.server_scoring_read_contract(uuid,date,uuid)',
    'public.server_scoring_read_contract_v1(uuid,date,uuid)',
    'public.server_scoring_read_contract_before_signals(uuid,date,uuid)',
    'public.server_scoring_for_day(uuid,date)',
    'public.server_scoring_for_device_day(uuid,date,uuid)',
    'public.publish_compute_dispositions(uuid,uuid,date,bigint)',
    'public.process_compute_disposition()',
    'public.server_scoring_pending_contract(uuid,date)',
    'public.submit_compute_session_request(uuid,uuid,uuid,jsonb)',
    'public.read_compute_session_result(uuid,uuid,uuid,uuid)',
    'public.process_compute_session_request()',
    'public.sensor_enqueue_closed_windows(timestamptz,integer)',
    'public.scoring_claim_one(integer,integer,uuid,uuid,date)',
    'public.scoring_renew_lease(uuid,uuid,date,bigint,uuid,uuid,integer)',
    'public.scoring_finish_work(uuid,uuid,date,bigint,uuid,uuid,text,integer,text)',
    'public.retire_noop_installation(text)',
    'public.confirm_noop_wearable(uuid,uuid,uuid,uuid,jsonb)'
  ] loop
    assert to_regprocedure(object_name) is not null, 'missing final function: ' || object_name;
  end loop;

  definition := pg_get_functiondef('public.server_scoring_read_contract(uuid,date,uuid)'::regprocedure);
  assert position('server_scoring_read_contract_v1' in definition) > 0,
    'final hosted contract does not wrap the signal-aware contract';
  assert position('''mode'',''final_hosted''' in definition) > 0,
    'final hosted response mode is absent';
  definition := pg_get_functiondef('public.server_scoring_read_contract_v1(uuid,date,uuid)'::regprocedure);
  assert position('server_scoring_read_contract_before_signals' in definition) > 0,
    'signal-aware contract does not wrap the qualified base contract';
  definition := pg_get_functiondef('public.server_scoring_for_day(uuid,date)'::regprocedure);
  assert position('server_scoring_read_contract' in definition) > 0,
    'account route bypasses the canonical final contract';
  definition := pg_get_functiondef('public.server_scoring_for_device_day(uuid,date,uuid)'::regprocedure);
  assert position('server_scoring_read_contract' in definition) > 0,
    'enrollment route bypasses the canonical final contract';

  select count(*), coalesce(sum(cardinality(metrics)), 0)
    into strict metric_count, owned_metric_count
    from public.compute_family_policy;
  assert metric_count = 27, 'compute family count differs from the final hosted registry';
  assert owned_metric_count = 80, 'compute metric count differs from the final hosted registry';
  assert not exists(
    select metric from public.compute_family_policy policy,
      lateral unnest(policy.metrics) metric group by metric having count(*) <> 1
  ), 'a physiological metric has zero or multiple owners';

  assert exists(
    select 1 from pg_constraint
    where conrelid = 'public.server_physiology_results'::regclass and contype = 'p'
      and pg_get_constraintdef(oid) =
        'PRIMARY KEY (user_id, device_id, period_day, algorithm_version, input_revision)'
  ), 'immutable result identity is not the expected composite primary key';

  foreach object_name in array array[
    'noop_wearable_aliases','noop_collection_leases','noop_projection_observations',
    'noop_projection_conflicts','noop_rr_clock_conflicts','scoring_fleet_policy',
    'scoring_fleet_tenants','scoring_fleet_reservations','scoring_fleet_completions',
    'noop_fleet_intake_policy','noop_fleet_intake_usage','scoring_lane_tenants',
    'noop_account_retirements','sensor_acquisition_contracts','server_compute_dispositions',
    'compute_account_sources','compute_session_requests','compute_session_results'
  ] loop
    assert exists(
      select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relname = object_name and c.relrowsecurity
    ), 'RLS is not enabled: ' || object_name;
  end loop;

  foreach object_name in array array[
    'compute_disposition_owner','compute_request_owner','compute_result_owner',
    'sensor_capture_worker'
  ] loop
    assert exists(select 1 from pg_policies where schemaname = 'public' and policyname = object_name),
      'missing final RLS policy: ' || object_name;
  end loop;

  assert has_function_privilege('authenticated','public.server_scoring_for_day(uuid,date)','EXECUTE'),
    'authenticated account route grant is missing';
  assert not has_function_privilege('authenticated','public.server_scoring_for_device_day(uuid,date,uuid)','EXECUTE'),
    'backend-only enrollment route is executable by authenticated';
  assert has_function_privilege('authenticated','public.server_scoring_read_contract(uuid,date,uuid)','EXECUTE'),
    'authenticated canonical read contract grant is missing';
  assert not has_function_privilege('authenticated','public.process_compute_disposition()','EXECUTE'),
    'authenticated can process compute dispositions';
  assert not has_function_privilege('authenticated','public.process_compute_session_request()','EXECUTE'),
    'authenticated can process compute sessions';
  assert not has_function_privilege('authenticated','public.sensor_enqueue_closed_windows(timestamptz,integer)','EXECUTE'),
    'authenticated can enqueue sensor windows';
  assert not has_function_privilege('authenticated','public.scoring_claim_one(integer,integer,uuid,uuid,date)','EXECUTE'),
    'authenticated can claim scoring work';
  assert has_function_privilege('service_role','public.process_compute_disposition()','EXECUTE'),
    'service role compute-disposition grant is missing';
  assert has_function_privilege('service_role','public.process_compute_session_request()','EXECUTE'),
    'service role compute-session grant is missing';
  assert has_function_privilege('service_role','public.sensor_enqueue_closed_windows(timestamptz,integer)','EXECUTE'),
    'service role sensor-enqueue grant is missing';
  assert has_function_privilege('service_role','public.scoring_claim_one(integer,integer,uuid,uuid,date)','EXECUTE'),
    'service role scoring-claim grant is missing';
  assert has_table_privilege('authenticated','public.physiology_work_items','SELECT'),
    'expected Supabase authenticated table grant is missing';
  assert not exists(
    select 1 from pg_policies where schemaname='public' and tablename='physiology_work_items'
      and 'authenticated'=any(roles)
  ), 'authenticated has a queue RLS policy';
  assert not has_table_privilege('authenticated','public.scoring_fleet_reservations','SELECT'),
    'authenticated can read fleet reservations';
  assert has_table_privilege('authenticated','public.compute_family_policy','SELECT'),
    'authenticated compute policy read grant is missing';
  assert not has_table_privilege('authenticated','public.compute_family_policy','INSERT'),
    'authenticated can mutate compute policy';

  for object_name in
    select required.name from (values
      ('noop_installation_immutable'),('noop_active_source'),('noop_alias_raw_dependency'),
      ('noop_account_retirement_admission'),('sensor_raw_coverage_unknown'),('sensor_raw_dependency')
    ) required(name)
    where not exists(
      select 1 from pg_trigger trigger
      where not trigger.tgisinternal and trigger.tgname = required.name and trigger.tgenabled <> 'D'
    )
  loop
    raise exception 'missing or disabled final trigger: %', object_name;
  end loop;

  assert not public.physiology_feature_is_canonical('frwhoop-physiology-2','hrv');
  assert not public.physiology_feature_is_canonical('frwhoop-physiology-2','sleep');
  assert not public.physiology_feature_is_canonical('frwhoop-physiology-2','respiration');
end $$;

with selected_functions as (
  select p.oid, n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' identity,
    pg_get_functiondef(p.oid) definition, coalesce(p.proacl::text, '') acl
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.oid in (
    'public.server_scoring_read_contract(uuid,date,uuid)'::regprocedure,
    'public.server_scoring_read_contract_v1(uuid,date,uuid)'::regprocedure,
    'public.server_scoring_read_contract_before_signals(uuid,date,uuid)'::regprocedure,
    'public.server_scoring_for_day(uuid,date)'::regprocedure,
    'public.server_scoring_for_device_day(uuid,date,uuid)'::regprocedure,
    'public.publish_compute_dispositions(uuid,uuid,date,bigint)'::regprocedure,
    'public.process_compute_session_request()'::regprocedure,
    'public.scoring_claim_one(integer,integer,uuid,uuid,date)'::regprocedure
  )
), selected_triggers as (
  select n.nspname || '.' || c.relname || '.' || t.tgname identity,
    pg_get_triggerdef(t.oid, true) definition
  from pg_trigger t join pg_class c on c.oid = t.tgrelid
  join pg_namespace n on n.oid = c.relnamespace
  where not t.tgisinternal and t.tgname in (
    'noop_installation_immutable','noop_active_source','noop_alias_raw_dependency',
    'noop_account_retirement_admission','sensor_raw_coverage_unknown','sensor_raw_dependency'
  )
), selected_policies as (
  select schemaname || '.' || tablename || '.' || policyname identity,
    concat_ws('|', cmd, roles::text, coalesce(qual,''), coalesce(with_check,'')) definition
  from pg_policies where schemaname = 'public' and policyname in (
    'compute_disposition_owner','compute_request_owner','compute_result_owner','sensor_capture_worker','service_all','owner_read'
  )
), material as (
  select 'function|' || identity || '|' || definition || '|' || acl value from selected_functions
  union all select 'trigger|' || identity || '|' || definition from selected_triggers
  union all select 'policy|' || identity || '|' || definition from selected_policies
), fingerprint as (
  select encode(sha256(convert_to(string_agg(value, E'\n' order by value), 'UTF8')), 'hex') sha256
  from material
)
select jsonb_build_object(
  'status','PASS',
  'schema_fingerprint_sha256',(select sha256 from fingerprint),
  'compute_families',(select count(*) from public.compute_family_policy),
  'compute_metrics',(select sum(cardinality(metrics)) from public.compute_family_policy),
  'rls_tables',(select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relrowsecurity),
  'selected_functions',(select count(*) from selected_functions),
  'selected_triggers',(select count(*) from selected_triggers),
  'selected_policies',(select count(*) from selected_policies)
)::text;
