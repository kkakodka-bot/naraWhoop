-- Preserve ownership even for service-role ingestion. No existing rows are rewritten.
begin;

create function public.preserve_device_owner() returns trigger
language plpgsql set search_path = public, pg_temp as $$
begin
  if new.user_id is distinct from old.user_id then
    raise exception 'device_owner_immutable' using errcode = '23514';
  end if;
  return new;
end;
$$;

revoke all on function public.preserve_device_owner() from public, anon, authenticated;
create trigger preserve_device_owner before update of user_id on public.devices
for each row execute function public.preserve_device_owner();

-- ON CONFLICT holds the row lock through the ownership comparison. A retry can
-- update activity metadata for its owner, but cannot transfer a device.
create function public.register_noop_device(
  p_device uuid, p_user uuid, p_external_device_id text, p_last_seen_at timestamptz
) returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare registered uuid;
begin
  insert into public.devices(id,user_id,source_kind,external_device_id,last_seen_at)
  values(p_device,p_user,'noop_push',p_external_device_id,p_last_seen_at)
  on conflict(id) do update set
    last_seen_at = greatest(devices.last_seen_at,excluded.last_seen_at),
    updated_at = clock_timestamp()
  where devices.user_id = excluded.user_id
  returning id into registered;
  if registered is null then
    raise exception 'device_registration_conflict' using errcode = '23514';
  end if;
  return registered;
end;
$$;
revoke all on function public.register_noop_device(uuid,uuid,text,timestamptz) from public, anon, authenticated;
grant execute on function public.register_noop_device(uuid,uuid,text,timestamptz) to service_role;

-- Separate owner/device foreign keys do not prove that the pair belongs together.
-- Validation fails closed if pre-existing rows need investigation; do not delete,
-- reassign, or silently repair historical records to make this migration pass.
alter table public.devices add constraint devices_owner_identity unique(user_id,id);
do $$
declare relation_name text;
begin
  foreach relation_name in array array[
    'noop_step_samples','noop_rr_packet_provenance','physiology_source_selection',
    'server_physiology_results','physiology_sleep_overrides','physiology_hrv_dependency_snapshots',
    'physiology_work_items','legacy_scoring_receipts'
  ] loop
    execute format('alter table public.%I add constraint %I foreign key(user_id,device_id) references public.devices(user_id,id) on delete cascade',
      relation_name,relation_name || '_device_owner_fk');
  end loop;
end;
$$;

commit;
