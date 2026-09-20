-- The v2 scorer reads temperature, so its durable changes need the same atomic
-- revision/gate contract as HR and motion. No raw samples or result snapshots change.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

-- Freeze the bounded catch-up set before adding triggers. Larger deployments must
-- use a reviewed batched catch-up; never silently leave a subset of old scores fresh.
-- This reads publication identities, not the potentially very large raw history.
lock table public.server_physiology_results in share mode;
do $$
begin
  if (select count(*) from (
    select distinct r.user_id,r.device_id,r.period_day
    from public.server_physiology_results r
    where r.algorithm_version='frwhoop-physiology-2'
    limit 10001
  ) affected) > 10000 then
    raise exception 'skin_temperature_dependency_backfill_requires_reviewed_batches'
      using errcode='54000';
  end if;
end $$;

create trigger scoring_dirty_insert after insert on public.noop_skin_temp_samples
  referencing new table as new_rows for each statement execute function public.scoring_dirty_projection();
create trigger scoring_dirty_update after update on public.noop_skin_temp_samples
  referencing old table as old_rows new table as new_rows for each statement execute function public.scoring_dirty_projection();
create trigger scoring_dirty_delete after delete on public.noop_skin_temp_samples
  referencing old table as old_rows for each statement execute function public.scoring_dirty_projection();

-- Recompute every already-published v2 day, even if its temperature was corrected
-- or deleted before this repair. Never-published pending jobs already read current
-- inputs. Existing timezone ownership is retained, with the historical resolver
-- used only if a publication has no surviving work row. Immutable outputs remain.
do $$ declare affected record;
begin
  for affected in
    select r.user_id,r.device_id,r.period_day,
      coalesce(w.timezone_id,public.scoring_timezone_at(r.user_id,
        r.period_day::timestamp at time zone 'UTC')) as timezone_id
    from (select distinct user_id,device_id,period_day
      from public.server_physiology_results where algorithm_version='frwhoop-physiology-2') r
    join public.devices d on d.user_id=r.user_id and d.id=r.device_id
    left join public.physiology_work_items w on w.user_id=r.user_id and w.device_id=r.device_id and w.day=r.period_day
    order by r.user_id,r.device_id,r.period_day
  loop
    perform public.physiology_enqueue_day(affected.user_id,affected.device_id,affected.period_day,affected.timezone_id,0);
  end loop;
end $$;

commit;
