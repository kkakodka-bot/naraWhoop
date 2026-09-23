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
    'public.confirm_noop_wearable(uuid,uuid,uuid,uuid,jsonb)',
    'public.noop_intake_consumer_contract()',
    'public.noop_intake_consumer_poll(uuid,uuid,text,text,integer,integer,integer)',
    'public.noop_async_verification_ready()',
    'public.noop_intake_status()',
    'public.noop_claim_object_verification(bigint,bigint)',
    'public.noop_commit_object_receipt(uuid,uuid,text,text,text,bigint,bigint)',
    'public.noop_commit_push_projection(uuid,text,jsonb,jsonb,jsonb,uuid)'
  ] loop
    assert to_regprocedure(object_name) is not null, 'missing final function: ' || object_name;
  end loop;

  definition := pg_get_functiondef('public.server_scoring_read_contract(uuid,date,uuid)'::regprocedure);
  assert position('server_scoring_read_contract_v1' in definition) > 0,
    'final hosted contract does not wrap the signal-aware contract';
  assert position('''mode'',''final_hosted''' in definition) > 0,
    'final hosted response mode is absent';
  assert position('d.policy_version=policy.policy_version' in definition) > 0,
    'final hosted reader can reuse obsolete immutable dispositions';
  definition := pg_get_functiondef('public.server_scoring_read_contract_v1(uuid,date,uuid)'::regprocedure);
  assert position('server_scoring_read_contract_before_signals' in definition) > 0,
    'signal-aware contract does not wrap the qualified base contract';
  definition := pg_get_functiondef('public.server_scoring_for_day(uuid,date)'::regprocedure);
  assert position('server_scoring_read_contract' in definition) > 0,
    'account route bypasses the canonical final contract';
  definition := pg_get_functiondef('public.server_scoring_for_device_day(uuid,date,uuid)'::regprocedure);
  assert position('server_scoring_read_contract' in definition) > 0,
    'enrollment route bypasses the canonical final contract';

  assert public.noop_intake_consumer_contract() = jsonb_build_object(
    'contract_version',1,'completion','verified_indexed','projection','atomic_lifecycle_v1',
    'lanes',jsonb_build_array('verification','projection','legacy')),
    'intake service contract differs from the packaged consumer';
  definition := pg_get_functiondef('public.noop_apply_projection_rows(text,jsonb)'::regprocedure);
  assert position('noop_project_append_batch' in definition)>0,
    'atomic projection bypasses lifecycle/source admission';
  definition := pg_get_functiondef('public.noop_project_append_batch(uuid,uuid,uuid,uuid,text,jsonb)'::regprocedure);
  assert position('to_jsonb(x.*)' in definition)>0,
    'gravity projection has not disambiguated the row from the x-axis column';

  select count(*), coalesce(sum(cardinality(metrics)), 0)
    into strict metric_count, owned_metric_count
    from public.compute_family_policy;
  assert metric_count = 27, 'compute family count differs from the final hosted registry';
  assert owned_metric_count = 80, 'compute metric count differs from the final hosted registry';
  assert (
    select count(*) = 7 and bool_and(
      unavailable_status = 'unqualified' and unavailable_reason = 'producer_not_implemented'
      and policy_version = 'vps-only-producers-2')
    from public.compute_family_policy
    where family in ('spot_hrv','live_workout','intraday_temperature','stress_events',
                     'biofeedback','live_coaching','insights')
  ), 'unfinished server producers are mislabeled as unsupported acquisition';
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
    'compute_account_sources','compute_session_requests','compute_session_results',
    'noop_object_verification_debt','noop_object_copy_intents','noop_intake_consumers',
    'noop_intake_service_minutes','noop_verification_owner_service','noop_projection_owner_service'
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
  foreach object_name in array array[
    'public.noop_intake_consumer_contract()',
    'public.noop_intake_consumer_poll(uuid,uuid,text,text,integer,integer,integer)',
    'public.noop_async_verification_ready()',
    'public.noop_intake_status()',
    'public.noop_claim_object_verification(bigint,bigint)',
    'public.noop_commit_object_receipt(uuid,uuid,text,text,text,bigint,bigint)',
    'public.noop_commit_push_projection(uuid,text,jsonb,jsonb,jsonb,uuid)'
  ] loop
    assert has_function_privilege('service_role',object_name,'EXECUTE'),
      'intake consumer grant missing: ' || object_name;
    assert not has_function_privilege('authenticated',object_name,'EXECUTE')
      and not has_function_privilege('anon',object_name,'EXECUTE'),
      'client can service privileged intake: ' || object_name;
  end loop;
  assert not has_function_privilege('service_role',
    'public.noop_apply_projection_rows_intake_legacy(text,jsonb)','EXECUTE'),
    'legacy projection bypass remains callable';
  assert not has_function_privilege('service_role',
    'public.noop_commit_push_projection_intake_core(uuid,text,jsonb,jsonb,jsonb,uuid)','EXECUTE'),
    'unfenced projection core remains callable';

  for object_name in
    select required.name from (values
      ('noop_installation_immutable'),('noop_active_source'),('noop_alias_raw_dependency'),
      ('noop_account_retirement_admission'),('sensor_raw_coverage_unknown'),('sensor_raw_dependency'),
      ('noop_verification_owner_enqueued'),('noop_projection_owner_enqueued')
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
    'public.scoring_claim_one(integer,integer,uuid,uuid,date)'::regprocedure,
    'public.noop_intake_consumer_contract()'::regprocedure,
    'public.noop_intake_consumer_poll(uuid,uuid,text,text,integer,integer,integer)'::regprocedure,
    'public.noop_async_verification_ready()'::regprocedure,
    'public.noop_intake_status()'::regprocedure,
    'public.noop_claim_object_verification(bigint,bigint)'::regprocedure,
    'public.noop_commit_object_receipt(uuid,uuid,text,text,text,bigint,bigint)'::regprocedure,
    'public.noop_claim_projection_debt()'::regprocedure,
    'public.noop_apply_projection_rows(text,jsonb)'::regprocedure,
    'public.noop_commit_push_projection(uuid,text,jsonb,jsonb,jsonb,uuid)'::regprocedure,
    'public.noop_project_append_batch(uuid,uuid,uuid,uuid,text,jsonb)'::regprocedure
  )
), selected_triggers as (
  select n.nspname || '.' || c.relname || '.' || t.tgname identity,
    pg_get_triggerdef(t.oid, true) definition
  from pg_trigger t join pg_class c on c.oid = t.tgrelid
  join pg_namespace n on n.oid = c.relnamespace
  where not t.tgisinternal and t.tgname in (
    'noop_installation_immutable','noop_active_source','noop_alias_raw_dependency',
    'noop_account_retirement_admission','sensor_raw_coverage_unknown','sensor_raw_dependency',
    'noop_verification_owner_enqueued','noop_projection_owner_enqueued'
  )
), selected_policies as (
  select schemaname || '.' || tablename || '.' || policyname identity,
    concat_ws('|', cmd, roles::text, coalesce(qual,''), coalesce(with_check,'')) definition
  from pg_policies where schemaname = 'public' and policyname in (
    'compute_disposition_owner','compute_request_owner','compute_result_owner','sensor_capture_worker','service_all','owner_read',
    'noop_intake_consumers_service','noop_intake_service_minutes_service'
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
