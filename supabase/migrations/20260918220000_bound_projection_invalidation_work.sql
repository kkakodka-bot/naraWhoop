-- Serialize changed rows once per query, rather than once per device candidate.
-- PostgreSQL can inline the INSERT/DELETE JSON projection into the device join and
-- repeatedly serialize a complete packet for every same-owner device candidate.
-- Materialize it before either join, and deduplicate typed owner/device identities
-- before acquiring locks. Preserve full semantic old/new comparison on UPDATE,
-- including old and new time spans; arrival metadata alone is still an exact replay.
begin;

create or replace function public.scoring_dirty_projection() returns trigger language plpgsql security definer
set search_path='' as $$
declare q text; r record;
begin
  if tg_op='UPDATE' then
    q := '(select to_jsonb(n)-ARRAY[''ingested_at'',''updated_at'',''batch_id'',''replacement_id''] as j from new_rows n
      except select to_jsonb(o)-ARRAY[''ingested_at'',''updated_at'',''batch_id'',''replacement_id''] from old_rows o)
      union (select to_jsonb(o)-ARRAY[''ingested_at'',''updated_at'',''batch_id'',''replacement_id''] from old_rows o
      except select to_jsonb(n)-ARRAY[''ingested_at'',''updated_at'',''batch_id'',''replacement_id''] from new_rows n)';
  elsif tg_op='INSERT' then q := 'select to_jsonb(n) as j from new_rows n';
  else q := 'select to_jsonb(o) as j from old_rows o'; end if;
  for r in execute 'with changed as materialized ('||q||')
    select distinct d.user_id,d.id from (
      select distinct (j->>''user_id'')::uuid as owner,(j->>''device_id'')::uuid as device
      from changed
    ) identities join public.devices d
      on d.user_id=identities.owner and (identities.device is null or d.id=identities.device)
      order by d.user_id,d.id'
  loop perform public.scoring_lock_device(r.user_id,r.id); end loop;
  for r in execute 'with changed as materialized ('||q||'), spans as (
    select (j->>''user_id'')::uuid as owner,(j->>''device_id'')::uuid as device,
      coalesce((j->>''ts'')::bigint,(j->>''start_ts'')::bigint,
        extract(epoch from (j->>''start_at'')::timestamptz)::bigint) as first_ts,
      coalesce((j->>''end_ts'')::bigint,extract(epoch from (j->>''end_at'')::timestamptz)::bigint,
        case when j->>''ts'' is not null then least((j->>''ts'')::numeric+1,9223372036854775807)::bigint end,
        case when j->>''start_ts'' is not null then least((j->>''start_ts'')::numeric+1,9223372036854775807)::bigint end) as last_ts
    from changed
  ), coalesced as (
    select owner,device,min(first_ts) as first_ts,max(last_ts) as last_ts from spans
    where first_ts is not null group by owner,device,first_ts/3600
  ) select distinct s.owner,d.id as device,a.day,a.timezone_id
    from coalesced s join public.devices d on d.user_id=s.owner and (s.device is null or d.id=s.device)
    cross join lateral public.scoring_affected_days(s.owner,s.first_ts,s.last_ts) a
    where s.first_ts is not null order by s.owner,d.id,a.day,a.timezone_id'
  loop perform public.scoring_enqueue_day(r.owner,r.device,r.day,r.timezone_id); end loop;
  return null;
end $$;

commit;
