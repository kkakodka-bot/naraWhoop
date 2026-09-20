-- W3 independent-review repairs. Keep deployed migration IDs and the legacy RPC signature.
-- The old implementation is private so its unfenced writes cannot bypass the compatibility guard.
alter function public.engine_ingest_scored(text,jsonb) set schema internal;
revoke all on function internal.engine_ingest_scored(text,jsonb) from public,anon,authenticated,service_role;

create function public.engine_ingest_scored(p_secret text,p_payload jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare u uuid; v text; d date; daily jsonb; nights jsonb;
begin
  perform internal.assert_ingest_secret(p_secret);
  u:=nullif(p_payload->>'user_id','')::uuid;
  v:=nullif(p_payload->>'algorithm_version','');
  if u is null then raise exception 'user_id required'; end if;
  if v is null then raise exception 'algorithm_version required'; end if;

  -- V2 publication takes this owner lock shared BEFORE its queue/projection locks. Exclusivity
  -- here also stabilizes an existing sleep's period_day while checking its unique start-time key.
  -- Only rolling-upgrade legacy traffic serializes this way; v2 workers retain shared admission.
  perform pg_advisory_xact_lock(hashtextextended('scoring-inputs-v2:'||u,0));
  for d in
    select day from (
      select (r->>'day')::date as day
        from jsonb_array_elements(coalesce(p_payload->'daily_metrics','[]'::jsonb)) r
      union
      select (r->>'period_day')::date
        from jsonb_array_elements(coalesce(p_payload->'sleep_nights','[]'::jsonb)) r
      union
      select s.period_day from server_sleep_nights s
        join jsonb_array_elements(coalesce(p_payload->'sleep_nights','[]'::jsonb)) r
          on s.start_at=(r->>'start_at')::timestamptz
        where s.user_id=u and s.algorithm_version=v
    ) affected where day is not null order by day
  loop
    perform pg_advisory_xact_lock(hashtextextended(u::text||d::text||v,0));
  end loop;

  -- A pending v2 job owns its key even before its first snapshot. Neither a legacy computed_at
  -- timestamp nor a caller-provided source can establish a newer v2 input/result generation.
  select coalesce(jsonb_agg(r order by ord),'[]'::jsonb) into daily
    from jsonb_array_elements(coalesce(p_payload->'daily_metrics','[]'::jsonb)) with ordinality rows(r,ord)
    where not exists(select 1 from scoring_jobs_v2 q
      where q.user_id=u and q.day=(r->>'day')::date and q.algorithm_version=v);
  select coalesce(jsonb_agg(r order by ord),'[]'::jsonb) into nights
    from jsonb_array_elements(coalesce(p_payload->'sleep_nights','[]'::jsonb)) with ordinality rows(r,ord)
    where not exists(select 1 from scoring_jobs_v2 q
      where q.user_id=u and q.day=(r->>'period_day')::date and q.algorithm_version=v)
      and not exists(select 1 from server_sleep_nights s join scoring_jobs_v2 q
        on q.user_id=s.user_id and q.day=s.period_day and q.algorithm_version=s.algorithm_version
        where s.user_id=u and s.algorithm_version=v and s.start_at=(r->>'start_at')::timestamptz);
  return internal.engine_ingest_scored(p_secret,p_payload ||
    jsonb_build_object('daily_metrics',daily,'sleep_nights',nights));
end $$;
revoke all on function public.engine_ingest_scored(text,jsonb) from public,anon,authenticated;
grant execute on function public.engine_ingest_scored(text,jsonb) to service_role;
comment on function public.engine_ingest_scored(text,jsonb) is
  'Legacy compatibility: original response and secret contract; ignores v2-owned day/start keys under the publication lock.';

-- Registration's snapshot cannot see a first input transaction that commits later. Every worker
-- pass repairs a bounded batch of missing version/day pairs, including those late commits. Existing
-- revisions, active leases, failures and completed results are never dirtied by this safety scan.
create function public.reconcile_scoring_versions_v2(p_limit integer default 128) returns integer
language plpgsql security definer set search_path=public as $$
declare r record; repaired integer:=0;
begin
  for r in
    insert into scoring_jobs_v2(user_id,device_id,day,algorithm_version,reason)
      select missing.user_id,missing.device_id,missing.day,missing.algorithm_version,'algorithm_reconciliation'
      from (
        select distinct q.user_id,q.device_id,q.day,a.algorithm_version
        from scoring_jobs_v2 q
        join devices d on d.id=q.device_id and d.user_id=q.user_id
        cross join scoring_algorithms_v2 a
        where a.enabled and not exists(select 1 from scoring_jobs_v2 existing
          where existing.user_id=q.user_id and existing.device_id=q.device_id
            and existing.day=q.day and existing.algorithm_version=a.algorithm_version)
        order by q.user_id,q.device_id,q.day,a.algorithm_version
        limit least(greatest(coalesce(p_limit,0),0),1000)
      ) missing
      on conflict do nothing returning user_id,day,algorithm_version
  loop
    repaired:=repaired+1;
    perform refresh_scoring_legacy_v2(r.user_id,r.day,r.algorithm_version);
  end loop;
  return repaired;
end $$;
revoke all on function public.reconcile_scoring_versions_v2(integer) from public,anon,authenticated;
grant execute on function public.reconcile_scoring_versions_v2(integer) to service_role;

-- Rebuild unknown-family histories, including those whose last modern evidence was deleted.
-- Expansion remains bounded by normal maintenance; raw rows and immutable snapshots are retained.
insert into scoring_invalidations_v2(user_id,device_id,algorithm_version,next_day,through_day,reason)
  select q.user_id,q.device_id,q.algorithm_version,min(q.day),max(q.day),'rr_window_inference_repair'
  from scoring_jobs_v2 q join devices d on d.id=q.device_id and d.user_id=q.user_id
  join scoring_algorithms_v2 a on a.algorithm_version=q.algorithm_version and a.enabled
  where d.device_family is null
  group by q.user_id,q.device_id,q.algorithm_version;
