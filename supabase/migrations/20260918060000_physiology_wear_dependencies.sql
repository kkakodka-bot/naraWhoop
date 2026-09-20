-- Wear state persists beyond a finite raw-data lookback. A changed transition affects existing
-- scored calendars until the next transition, not just its own timestamp's calendar date.
create function public.scoring_dirty_wear_state() returns trigger
language plpgsql security definer set search_path='' as $$
declare changes text; owner_device record; affected record;
begin
  if tg_op='UPDATE' then
    changes := '(select to_jsonb(n)-ARRAY[''ingested_at'',''updated_at'',''batch_id'',''replacement_id''] as j from new_rows n
      except select to_jsonb(o)-ARRAY[''ingested_at'',''updated_at'',''batch_id'',''replacement_id''] from old_rows o)
      union (select to_jsonb(o)-ARRAY[''ingested_at'',''updated_at'',''batch_id'',''replacement_id''] from old_rows o
      except select to_jsonb(n)-ARRAY[''ingested_at'',''updated_at'',''batch_id'',''replacement_id''] from new_rows n)';
  elsif tg_op='INSERT' then changes:='select to_jsonb(n) as j from new_rows n';
  else changes:='select to_jsonb(o) as j from old_rows o'; end if;
  -- Same globally sorted owner/device mutex order as projection/publication. No unbounded future jobs.
  for owner_device in execute 'with changed as ('||changes||')
    select distinct (j->>''user_id'')::uuid as owner,(j->>''device_id'')::uuid as device from changed
    where left(j->>''kind'',9)=''WRIST_OFF'' or left(j->>''kind'',8)=''WRIST_ON'' order by owner,device'
  loop
    perform public.scoring_lock_device(owner_device.owner,owner_device.device);
    for affected in execute 'with changed as ('||changes||'), spans as (
      select (j->>''ts'')::bigint as lo,coalesce((select min(e.ts) from public.noop_events e
        where e.user_id=$1 and e.device_id=$2 and e.ts>(j->>''ts'')::bigint
          and (left(e.kind,9)=''WRIST_OFF'' or left(e.kind,8)=''WRIST_ON'')),9223372036854775807) as hi
      from changed where (j->>''user_id'')::uuid=$1 and (j->>''device_id'')::uuid=$2
        and (left(j->>''kind'',9)=''WRIST_OFF'' or left(j->>''kind'',8)=''WRIST_ON''))
      select distinct q.day,q.timezone_id from public.scoring_work_items q
      where q.user_id=$1 and q.device_id=$2
        and q.day<=(clock_timestamp() at time zone public.scoring_timezone_at($1,clock_timestamp()))::date
        and exists(select 1 from spans s cross join lateral (
          select start_ts,end_ts from public.scoring_day_segments($1,q.day)
          union all select start_ts,end_ts from public.scoring_day_segments($1,q.day-1)
        ) calendar where s.lo<calendar.end_ts and s.hi>calendar.start_ts)
      order by q.day,q.timezone_id'
      using owner_device.owner,owner_device.device
    loop
      perform public.scoring_enqueue_day(owner_device.owner,owner_device.device,affected.day,affected.timezone_id);
    end loop;
  end loop;
  return null;
end;
$$;
create trigger scoring_wear_insert after insert on public.noop_events
  referencing new table as new_rows for each statement execute function public.scoring_dirty_wear_state();
create trigger scoring_wear_update after update on public.noop_events
  referencing old table as old_rows new table as new_rows for each statement execute function public.scoring_dirty_wear_state();
create trigger scoring_wear_delete after delete on public.noop_events
  referencing old table as old_rows for each statement execute function public.scoring_dirty_wear_state();
revoke all on function public.scoring_dirty_wear_state() from public,anon,authenticated;
grant execute on function public.scoring_dirty_wear_state() to service_role;
