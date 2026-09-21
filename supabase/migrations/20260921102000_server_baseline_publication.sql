-- Forward repair: the fenced baseline publisher accidentally called the older rolling-
-- upgrade wrapper, which discards a day whenever scoring_jobs_v2 contains that key.
-- The independent baseline queue has its own revision/lease authority. Keep that full
-- fence and the frozen baseline serializer, without the unrelated history-queue filter.
create or replace function public.engine_publish_legacy_fenced(p_secret text,p_payload jsonb) returns jsonb
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
revoke all on function public.engine_publish_legacy_fenced(text,jsonb) from public,anon,authenticated;
grant execute on function public.engine_publish_legacy_fenced(text,jsonb) to service_role;
-- Neither the pre-fence wrapper nor the serializer is a callable transport endpoint.
revoke all on function public.engine_ingest_scored_legacy_internal(text,jsonb),
  internal.engine_ingest_scored(text,jsonb) from public,anon,authenticated,service_role;
