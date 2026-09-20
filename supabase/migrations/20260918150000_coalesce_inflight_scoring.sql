-- Live ingest was incrementing input_revision on every push batch and clearing the
-- running lease, so a day with continuous HR never published. Coalesce arrivals that
-- are still pending, keep a live lease until it publishes, then requeue if newer
-- samples landed during the run.

begin;

create or replace function public.physiology_enqueue_day(p_user uuid, p_device uuid, p_day date, p_timezone text,
  p_debounce_seconds integer default 2) returns bigint
language plpgsql security definer set search_path='' as $$
declare v_revision bigint;
begin
  perform public.scoring_lock_device(p_user, p_device);
  if not exists(select 1 from public.devices where id=p_device and user_id=p_user) then
    raise exception 'device does not belong to user' using errcode='23503';
  end if;
  if not exists(select 1 from pg_timezone_names where name=p_timezone) then
    raise exception 'invalid timezone' using errcode='22023';
  end if;
  insert into public.physiology_work_items(user_id, device_id, day, timezone_id, next_attempt_at)
    values (p_user, p_device, p_day, p_timezone,
      clock_timestamp()+make_interval(secs=>greatest(0, p_debounce_seconds)))
  on conflict (user_id, device_id, day) do update set
    dirty_at = clock_timestamp(),
    input_revision = case
      when physiology_work_items.status='running'
        and physiology_work_items.lease_expires_at is not null
        and physiology_work_items.lease_expires_at > clock_timestamp()
        then physiology_work_items.input_revision
      when physiology_work_items.done_at is not null
        or physiology_work_items.status in ('done', 'exhausted')
        then physiology_work_items.input_revision + 1
      else physiology_work_items.input_revision
    end,
    measurement_revision = case
      when physiology_work_items.status='running'
        and physiology_work_items.lease_expires_at is not null
        and physiology_work_items.lease_expires_at > clock_timestamp()
        then physiology_work_items.measurement_revision
      when physiology_work_items.done_at is not null
        or physiology_work_items.status in ('done', 'exhausted')
        then physiology_work_items.measurement_revision + 1
      else physiology_work_items.measurement_revision
    end,
    failure_revision = case
      when physiology_work_items.status='running'
        and physiology_work_items.lease_expires_at is not null
        and physiology_work_items.lease_expires_at > clock_timestamp()
        then physiology_work_items.failure_revision
      when physiology_work_items.done_at is not null
        or physiology_work_items.status in ('done', 'exhausted')
        then physiology_work_items.input_revision + 1
      else physiology_work_items.failure_revision
    end,
    consecutive_failures = case
      when physiology_work_items.status='running'
        and physiology_work_items.lease_expires_at is not null
        and physiology_work_items.lease_expires_at > clock_timestamp()
        then physiology_work_items.consecutive_failures
      else 0
    end,
    attempts = case
      when physiology_work_items.status='running'
        and physiology_work_items.lease_expires_at is not null
        and physiology_work_items.lease_expires_at > clock_timestamp()
        then physiology_work_items.attempts
      else 0
    end,
    done_at = case
      when physiology_work_items.status='running'
        and physiology_work_items.lease_expires_at is not null
        and physiology_work_items.lease_expires_at > clock_timestamp()
        then physiology_work_items.done_at
      else null
    end,
    claimed_at = case
      when physiology_work_items.status='running'
        and physiology_work_items.lease_expires_at is not null
        and physiology_work_items.lease_expires_at > clock_timestamp()
        then physiology_work_items.claimed_at
      else null
    end,
    claimed_revision = case
      when physiology_work_items.status='running'
        and physiology_work_items.lease_expires_at is not null
        and physiology_work_items.lease_expires_at > clock_timestamp()
        then physiology_work_items.claimed_revision
      else null
    end,
    lease_token = case
      when physiology_work_items.status='running'
        and physiology_work_items.lease_expires_at is not null
        and physiology_work_items.lease_expires_at > clock_timestamp()
        then physiology_work_items.lease_token
      else null
    end,
    run_id = case
      when physiology_work_items.status='running'
        and physiology_work_items.lease_expires_at is not null
        and physiology_work_items.lease_expires_at > clock_timestamp()
        then physiology_work_items.run_id
      else null
    end,
    lease_expires_at = case
      when physiology_work_items.status='running'
        and physiology_work_items.lease_expires_at is not null
        and physiology_work_items.lease_expires_at > clock_timestamp()
        then physiology_work_items.lease_expires_at
      else null
    end,
    status = case
      when physiology_work_items.status='running'
        and physiology_work_items.lease_expires_at is not null
        and physiology_work_items.lease_expires_at > clock_timestamp()
        then 'running'
      else 'pending'
    end,
    last_error = case
      when physiology_work_items.status='running'
        and physiology_work_items.lease_expires_at is not null
        and physiology_work_items.lease_expires_at > clock_timestamp()
        then physiology_work_items.last_error
      else null
    end,
    next_attempt_at = case
      when physiology_work_items.status='running'
        and physiology_work_items.lease_expires_at is not null
        and physiology_work_items.lease_expires_at > clock_timestamp()
        then physiology_work_items.next_attempt_at
      when physiology_work_items.next_attempt_at > clock_timestamp()
        and physiology_work_items.done_at is null
        and physiology_work_items.status not in ('done', 'exhausted')
        then physiology_work_items.next_attempt_at
      else clock_timestamp()+make_interval(secs=>greatest(0, p_debounce_seconds))
    end
  returning input_revision into v_revision;
  return v_revision;
end $$;

create or replace function public.scoring_finish_work(p_user uuid, p_device uuid, p_day date, p_revision bigint,
  p_lease_token uuid, p_run_id uuid, p_outcome text, p_duration_ms integer default null, p_error text default null)
returns boolean language plpgsql security definer set search_path='' as $$
declare failures integer; claimed timestamptz; dirtied timestamptz;
begin
  if p_outcome not in ('done', 'waiting', 'failed') then raise exception 'invalid outcome'; end if;
  begin
    perform public.scoring_begin_publication(p_user, p_device, p_day, p_revision, p_lease_token, p_run_id);
  exception when serialization_failure then return false; end;
  select case when failure_revision=p_revision then consecutive_failures else 0 end,
         claimed_at, dirty_at
    into failures, claimed, dirtied
    from public.physiology_work_items
    where user_id=p_user and device_id=p_device and day=p_day;
  if p_outcome='failed' then failures:=failures+1;
  elsif p_outcome='done' then failures:=0; end if;
  if p_outcome='done' and dirtied is not null and claimed is not null and dirtied > claimed then
    update public.physiology_work_items set
      input_revision=input_revision+1,
      measurement_revision=measurement_revision+1,
      done_at=null, claimed_at=null, claimed_revision=null, lease_token=null, run_id=null,
      lease_expires_at=null, consecutive_failures=0, failure_revision=input_revision+1, attempts=0,
      status='pending', last_error=null, last_duration_ms=p_duration_ms,
      next_attempt_at=clock_timestamp()
    where user_id=p_user and device_id=p_device and day=p_day;
    return true;
  end if;
  update public.physiology_work_items set
    done_at=case when p_outcome='done' then clock_timestamp() end,
    claimed_at=null, claimed_revision=null, lease_token=null, run_id=null, lease_expires_at=null,
    consecutive_failures=failures, failure_revision=p_revision, attempts=failures,
    status=case when p_outcome='failed' then case when failures>=8 then 'exhausted' else 'retry' end
      else p_outcome end,
    next_attempt_at=clock_timestamp()+make_interval(secs=>case when p_outcome='failed'
      then least(3600, 5*power(2, least(failures-1, 10))) when p_outcome='waiting' then 300 else 0 end),
    last_error=case when p_outcome='done' then null else left(p_error, 2000) end,
    last_duration_ms=p_duration_ms
  where user_id=p_user and device_id=p_device and day=p_day;
  return true;
end $$;

commit;
