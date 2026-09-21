-- Metadata-only trace of the same explicitly enrolled device read. No health payloads.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

create function public.server_pipeline_diagnostics(p_user uuid,p_source uuid,p_device uuid,p_day date)
returns jsonb language plpgsql stable security invoker set search_path=pg_catalog,public as $$
declare
  selected jsonb; selected_features jsonb; publications jsonb; workers jsonb;
  receipts integer; objects integer; projection_pending integer; projection_failed integer;
  projection_oldest timestamptz; truncated boolean;
  work jsonb; claimed boolean; computed boolean; selected_ready boolean;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'service role required' using errcode='42501';
  end if;
  if not exists(select 1 from public.devices where id=p_device and user_id=p_user)
    or not exists(select 1 from public.noop_app_installations
      where user_id=p_user and source_id=p_source and revoked_at is null) then
    raise exception 'owned installation and device required' using errcode='42501';
  end if;
  selected := public.server_scoring_for_device_day(p_user,p_day,p_device);
  select jsonb_object_agg(key,value-array['device_id','day_intervals','context_intervals','timezone_ids'])
    into selected_features from jsonb_each(selected->'features');
  select count(*) into receipts from (select 1 from public.noop_upload_receipts r
    where r.user_id=p_user and r.source_id=p_source and r.device_id=p_device
      and exists(select 1 from public.scoring_day_segments(p_user,p_day) s
        where extract(epoch from r.accepted_at)>=s.start_ts and extract(epoch from r.accepted_at)<s.end_ts)
    limit 1001) bounded;
  with bounded as (
    select m.id from public.object_manifests m where m.user_id=p_user and m.device_id=p_device
      and m.source_id=p_source and m.object_class='raw' and m.period_day=p_day and m.format like 'ndjson%'
      and m.status not in ('deleted','deleting','expired') order by m.created_at,m.id limit 1001
  ) select count(*),count(*) filter(where d.state is distinct from 'complete'),
      count(*) filter(where d.state is distinct from 'complete' and d.failures>0),
      min(d.created_at) filter(where d.state is distinct from 'complete')
    into objects,projection_pending,projection_failed,projection_oldest
    from bounded m left join public.noop_projection_debt d on d.object_id=m.id;
  truncated := receipts>=1001 or objects>=1001;
  select coalesce(jsonb_agg(to_jsonb(q)),'[]'::jsonb) into work from (
    select 'frwhoop-physiology-2'::text algorithm_version,input_revision,status,
      claimed_at,lease_expires_at,consecutive_failures,next_attempt_at,dirty_at
      from public.physiology_work_items where user_id=p_user and device_id=p_device and day=p_day
    union all
    select 'frwhoop-server-1',input_revision,status,claimed_at,lease_expires_at,
      consecutive_failures,next_attempt_at,dirty_at
      from public.scoring_work_items where user_id=p_user and device_id=p_device and day=p_day
  ) q;
  select coalesce(jsonb_agg(to_jsonb(r)),'[]'::jsonb) into publications from (
    select distinct on(algorithm_version) algorithm_version,input_revision,computed_at,manifest_hash
    from public.server_physiology_results where user_id=p_user and device_id=p_device and period_day=p_day
    order by algorithm_version,input_revision desc limit 32
  ) r;
  select coalesce(jsonb_agg(to_jsonb(w)),'[]'::jsonb) into workers from (
    select distinct on(h.algorithm_version) h.algorithm_version,h.worker_instance_id,h.process_instance_id,
      h.source_revision,h.started_at,h.last_poll_at,h.last_score_at,
      case when h.last_poll_at is null then 'never_polled'
        when h.last_poll_at<now()-interval '2 minutes' then 'stale' else 'polling' end status
    from public.physiology_worker_heartbeats h where h.algorithm_version in (
      select value->>'algorithm_version' from jsonb_each(selected->'features'))
    order by h.algorithm_version,h.started_at desc limit 32
  ) w;
  claimed := exists(select 1 from jsonb_array_elements(work) q where q->>'status'='running');
  computed := jsonb_array_length(publications)>0;
  selected_ready := exists(select 1 from jsonb_each(selected->'features') f where f.value->>'status' in ('available','stale'));
  return jsonb_build_object('schema_version',1,
    'correlation_id',encode(sha256(convert_to(p_user::text||':'||p_source::text||':'||p_device::text||':'||p_day::text,'UTF8')),'hex'),
    'scope','enrolled_owner_source_device_day','read_rpc','server_scoring_for_device_day',
    'observation_is_atomic',true,'counts_truncated',truncated,
    'receipt_window','accepted_on_requested_calendar_day','result_window','measurement_calendar_day',
    'stages',jsonb_build_object(
      'acquired',jsonb_build_object('status','not_measured','reason','requires_device_capture_evidence'),
      'durable',jsonb_build_object('status','not_measured','reason','requires_phone_commit_evidence'),
      'accepted',jsonb_build_object('status',case when receipts>0 then 'observed' else 'not_observed' end,'receipts',receipts),
      'projected',jsonb_build_object('status',case when truncated then 'incomplete_diagnostics'
        when projection_failed>0 then 'retrying' when projection_pending>0 then 'pending'
        when objects>0 then 'complete' else 'not_observed' end,
        'pending_objects',projection_pending,'retrying_objects',projection_failed,'oldest_pending_at',projection_oldest),
      'queued',jsonb_build_object('status',case when jsonb_array_length(work)>0 then 'observed' else 'not_observed' end),
      'claimed',jsonb_build_object('status',case when claimed then 'running' else 'not_running' end),
      'computed',jsonb_build_object('status',case when computed then 'published_evidence' else 'not_observed' end),
      'published',jsonb_build_object('status',case when computed then 'observed' else 'not_observed' end),
      'selected',jsonb_build_object('status',case when selected_ready then 'available' else 'unavailable' end),
      'decoded',jsonb_build_object('status','not_measured','reason','requires_client_decoder_evidence'),
      'displayed',jsonb_build_object('status','not_measured','reason','requires_client_presentation_evidence')),
    'work',work,'publications',publications,'selected_features',selected_features,'selected_workers',workers,
    'capabilities',jsonb_build_object(
      'hrv_timing',jsonb_build_object('status','observed_unqualified','reason','continuity_unverified'),
      'calibrated_spo2',jsonb_build_object('status','unsupported','reason','calibrated_source_unavailable')),
    'complete_scope','server_metadata_only');
end $$;
revoke all on function public.server_pipeline_diagnostics(uuid,uuid,uuid,date) from public,anon,authenticated;
grant execute on function public.server_pipeline_diagnostics(uuid,uuid,uuid,date) to service_role;
commit;
