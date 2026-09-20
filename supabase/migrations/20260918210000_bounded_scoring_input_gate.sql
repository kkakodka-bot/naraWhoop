-- A scoring run needs a bounded opportunity to finish under continuous ingest.
-- This mutex is deliberately separate from scoring_lock_device: publication uses a
-- different HTTP/database session. Never hold the publication mutex during inference.
begin;

create function public.scoring_acquire_input_gate(p_user uuid,p_device uuid) returns void
language plpgsql security definer set search_path='' as $$
begin
  if not exists(select 1 from public.devices where id=p_device and user_id=p_user) then
    raise exception 'device does not belong to user' using errcode='23503';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('physiology-input:'||p_user::text||':'||p_device::text,230919));
end $$;
revoke all on function public.scoring_acquire_input_gate(uuid,uuid) from public,anon,authenticated;
grant execute on function public.scoring_acquire_input_gate(uuid,uuid) to service_role;

create or replace function public.physiology_enqueue_day(p_user uuid,p_device uuid,p_day date,p_timezone text,
  p_debounce_seconds integer default 2) returns bigint language plpgsql security definer set search_path='' as $$
declare v_revision bigint;
begin
  if not exists(select 1 from public.devices where id=p_device and user_id=p_user) then
    raise exception 'device does not belong to user' using errcode='23503';
  end if;
  if not exists(select 1 from pg_timezone_names where name=p_timezone) then
    raise exception 'invalid timezone' using errcode='22023';
  end if;
  -- Input writes and their revision still commit atomically. A blocked projection rolls
  -- back before the receiver saves its ACK, and retries the unchanged durable batch.
  -- NONBLOCKING is essential: a caller may already own the publication mutex from an
  -- earlier statement/trigger. Waiting here would deadlock the separate HTTP publisher.
  if not pg_try_advisory_xact_lock_shared(
      hashtextextended('physiology-input:'||p_user::text||':'||p_device::text,230919)) then
    raise exception 'scoring_input_gate_busy' using errcode='55P03';
  end if;
  perform public.scoring_lock_device(p_user,p_device);
  insert into public.physiology_work_items(user_id,device_id,day,timezone_id,next_attempt_at)
    values(p_user,p_device,p_day,p_timezone,clock_timestamp()+make_interval(secs=>greatest(0,p_debounce_seconds)))
  on conflict(user_id,device_id,day) do update set
    input_revision=physiology_work_items.input_revision+1,
    measurement_revision=physiology_work_items.measurement_revision+1,
    failure_revision=physiology_work_items.input_revision+1,consecutive_failures=0,attempts=0,
    dirty_at=clock_timestamp(),done_at=null,claimed_at=null,claimed_revision=null,
    lease_token=null,run_id=null,lease_expires_at=null,status='pending',last_error=null,
    next_attempt_at=case when physiology_work_items.status='pending' and physiology_work_items.done_at is null
      then least(physiology_work_items.next_attempt_at,excluded.next_attempt_at)
      else excluded.next_attempt_at end
  returning input_revision into v_revision;
  return v_revision;
end $$;

commit;
