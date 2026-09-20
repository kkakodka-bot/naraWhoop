-- Defensive invariants for a disposable fully migrated Supabase database.
-- All fixture changes roll back; no deployed credentials or existing data required.
\set ON_ERROR_STOP on
begin;
insert into auth.users(id) values
 ('a8880000-0000-4000-8000-000000000001'),
 ('a8880000-0000-4000-8000-000000000002');
do $$
declare
  owner_id uuid := 'a8880000-0000-4000-8000-000000000001';
  other_id uuid := 'a8880000-0000-4000-8000-000000000002';
  device_id uuid := 'a8880000-0000-4000-8000-000000000011';
  relation_name text;
begin
  assert public.register_noop_device(device_id,owner_id,'fixture','2026-09-18T01:00:00Z') = device_id;
  assert public.register_noop_device(device_id,owner_id,'fixture','2026-09-18T02:00:00Z') = device_id;
  assert public.register_noop_device(device_id,owner_id,'fixture','2026-09-18T00:00:00Z') = device_id;
  assert (select last_seen_at='2026-09-18T02:00:00Z'::timestamptz from public.devices where id=device_id);
  insert into public.noop_step_samples(user_id,device_id,source_id,ts,counter,batch_id)
    values(owner_id,device_id,device_id,1789693200,123,device_id);
  begin
    update public.devices set user_id=other_id where id=device_id;
    raise exception 'immutable owner guard missing';
  exception when check_violation then null;
  end;
  begin
    perform public.register_noop_device(device_id,other_id,'fixture','2026-09-18T03:00:00Z');
    raise exception 'registration owner guard missing';
  exception when check_violation then null;
  end;
  assert (select user_id=owner_id from public.devices where id=device_id);
  assert (select count(*)=1 from public.noop_step_samples where user_id=owner_id and counter=123);
  assert not has_function_privilege('authenticated','public.register_noop_device(uuid,uuid,text,timestamptz)','EXECUTE');
  assert not has_function_privilege('anon','public.register_noop_device(uuid,uuid,text,timestamptz)','EXECUTE');
  assert has_function_privilege('service_role','public.register_noop_device(uuid,uuid,text,timestamptz)','EXECUTE');
  foreach relation_name in array array[
    'noop_step_samples','noop_rr_packet_provenance','physiology_source_selection',
    'server_physiology_results','physiology_sleep_overrides','physiology_hrv_dependency_snapshots',
    'physiology_work_items','legacy_scoring_receipts'
  ] loop
    assert exists(select 1 from pg_constraint where conrelid=('public.'||relation_name)::regclass
      and conname=relation_name||'_device_owner_fk' and convalidated), relation_name||' owner constraint missing';
  end loop;
  raise notice 'PASS idempotent registration, monotonic activity, immutable owner, retained rows, privileges and eight validated owner constraints';
end;
$$;
rollback;
