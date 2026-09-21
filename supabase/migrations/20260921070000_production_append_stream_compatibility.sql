-- Repair the production schema after colliding 2026091805/06 migration versions caused
-- Supabase to record one branch while skipping the scalar projection branch.
begin;

-- The server-1 scorer reads the historical camel-case field while the physiology-2 scorer
-- reads the canonical snake-case field. Keep both projections identical during the rollout.
alter table public.noop_step_samples add column if not exists activity_class integer;

do $$ begin
  if exists (
    select 1 from public.noop_step_samples
    where activity_class is not null and "activityClass" is not null
      and activity_class <> "activityClass"
  ) then
    raise exception 'step_activity_schema_conflict';
  end if;
end $$;

-- This copies an already-stored field into its compatibility alias. Suppress scoring triggers
-- for the metadata backfill so deployment cannot contend with an active scorer input gate.
set local session_replication_role = replica;
update public.noop_step_samples
set activity_class = coalesce(activity_class, "activityClass"),
    "activityClass" = coalesce("activityClass", activity_class)
where activity_class is distinct from "activityClass";
set local session_replication_role = origin;

create or replace function public.noop_step_activity_compat() returns trigger
language plpgsql set search_path=pg_catalog,public as $$
begin
  if tg_op = 'UPDATE' then
    if new.activity_class is distinct from old.activity_class
      and new."activityClass" is not distinct from old."activityClass" then
      new."activityClass" := new.activity_class;
    elsif new."activityClass" is distinct from old."activityClass"
      and new.activity_class is not distinct from old.activity_class then
      new.activity_class := new."activityClass";
    end if;
  else
    new.activity_class := coalesce(new.activity_class, new."activityClass");
    new."activityClass" := coalesce(new."activityClass", new.activity_class);
  end if;
  if new.activity_class is distinct from new."activityClass" then
    raise exception 'step_activity_schema_conflict';
  end if;
  return new;
end $$;

drop trigger if exists a_step_activity_compat on public.noop_step_samples;
create trigger a_step_activity_compat before insert or update on public.noop_step_samples
  for each row execute function public.noop_step_activity_compat();
revoke all on function public.noop_step_activity_compat() from public,anon,authenticated;
grant execute on function public.noop_step_activity_compat() to service_role;

-- Preserve immutable scalar measurements. Metadata-only receipt retries remain idempotent.
create or replace function public.noop_scalar_measurement_immutable() returns trigger
language plpgsql set search_path=pg_catalog,public as $$
begin
  if (to_jsonb(new)-array['source_id','batch_id','ingested_at']) is distinct from
     (to_jsonb(old)-array['source_id','batch_id','ingested_at']) then
    raise exception 'scalar_identity_conflict' using errcode='23505';
  end if;
  return new;
end $$;

do $$ declare t text; begin
  foreach t in array array['noop_step_samples','noop_sleep_state_samples','noop_ppg_hr_samples'] loop
    execute format('drop trigger if exists noop_scalar_measurement_immutable on public.%I',t);
    execute format('create trigger noop_scalar_measurement_immutable before update on public.%I
      for each row execute function public.noop_scalar_measurement_immutable()',t);
  end loop;
end $$;
revoke all on function public.noop_scalar_measurement_immutable() from public,anon,authenticated;
grant execute on function public.noop_scalar_measurement_immutable() to service_role;

-- The receiver attests only finite numeric gravity rows. Existing rows remain explicitly
-- unattested; NOT VALID avoids a table rewrite while still enforcing the contract on new rows.
alter table public.noop_gravity_samples
  add column if not exists motion_evidence_version text,
  add column if not exists orientation_evidence_version text;

do $$ begin
  if not exists (select 1 from pg_constraint where conrelid='public.noop_gravity_samples'::regclass
    and conname='noop_gravity_orientation_evidence_contract') then
    alter table public.noop_gravity_samples add constraint noop_gravity_orientation_evidence_contract
      check (orientation_evidence_version is null or (
        orientation_evidence_version='projected-gravity-g-1'
        and ts between -9007199254740991 and 9007199254740991
        and x not in ('NaN'::double precision,'Infinity'::double precision,'-Infinity'::double precision)
        and y not in ('NaN'::double precision,'Infinity'::double precision,'-Infinity'::double precision)
        and z not in ('NaN'::double precision,'Infinity'::double precision,'-Infinity'::double precision))) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conrelid='public.noop_gravity_samples'::regclass
    and conname='noop_gravity_motion_evidence_contract') then
    alter table public.noop_gravity_samples add constraint noop_gravity_motion_evidence_contract
      check (motion_evidence_version is null or (
        motion_evidence_version='projected-dynamic-acceleration-g-1'
        and orientation_evidence_version='projected-gravity-g-1'
        and "dynAccel" is not null and "dynAccel">=0 and "dynAccel"<=8)) not valid;
  end if;
end $$;

comment on column public.noop_gravity_samples.orientation_evidence_version is
  'Receiver attestation of numeric finite gravity XYZ and a safe-integer timestamp. NULL means unavailable provenance.';
comment on column public.noop_gravity_samples.motion_evidence_version is
  'Receiver attestation of numeric finite 0..8 g dynamic acceleration. NULL means unavailable provenance.';

-- ppgHrSample was added after the original scoring trigger list. If the v1 trigger function is
-- present, give PPG-derived HR the same invalidation behavior as the other scalar inputs.
do $$ begin
  if to_regprocedure('public.scoring_dirty_projection()') is not null then
    execute 'drop trigger if exists scoring_dirty_insert on public.noop_ppg_hr_samples';
    execute 'drop trigger if exists scoring_dirty_update on public.noop_ppg_hr_samples';
    execute 'drop trigger if exists scoring_dirty_delete on public.noop_ppg_hr_samples';
    execute 'create trigger scoring_dirty_insert after insert on public.noop_ppg_hr_samples
      referencing new table as new_rows for each statement execute function public.scoring_dirty_projection()';
    execute 'create trigger scoring_dirty_update after update on public.noop_ppg_hr_samples
      referencing old table as old_rows new table as new_rows for each statement execute function public.scoring_dirty_projection()';
    execute 'create trigger scoring_dirty_delete after delete on public.noop_ppg_hr_samples
      referencing old table as old_rows for each statement execute function public.scoring_dirty_projection()';
  end if;
end $$;

grant select on public.noop_sleep_state_samples,public.noop_ppg_hr_samples to authenticated;
revoke insert,update,delete,truncate,references,trigger
  on public.noop_sleep_state_samples,public.noop_ppg_hr_samples from anon,authenticated;
grant all on public.noop_sleep_state_samples,public.noop_ppg_hr_samples to service_role;

-- Keep one enrolled batch atomic and expose every scalar stream advertised by Edge.
create or replace function public.noop_project_append_batch(p_user uuid,p_device uuid,p_source uuid,p_batch uuid,
  p_stream text,p_rows jsonb) returns integer
language plpgsql security definer set search_path='' as $$
declare target_table text; conflict_columns text; columns_sql text; updates_sql text;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'service role required' using errcode='42501';
  end if;
  select table_name,conflict_key into target_table,conflict_columns from (values
    ('hrSample','noop_hr_samples','user_id,device_id,ts'),
    ('rrInterval','noop_rr_intervals','user_id,device_id,ts,"rrMs",seq'),
    ('rrPacketProvenance','noop_rr_packet_provenance','user_id,device_id,"packetId"'),
    ('standardHRReceipt','noop_standard_hr_receipts','user_id,device_id,"receiptId"'),
    ('stepSample','noop_step_samples','user_id,device_id,ts'),
    ('sleepStateSample','noop_sleep_state_samples','user_id,device_id,ts'),
    ('ppgHrSample','noop_ppg_hr_samples','user_id,device_id,ts'),
    ('event','noop_events','user_id,device_id,ts,kind'),
    ('battery','noop_battery_samples','user_id,device_id,ts'),
    ('spo2Sample','noop_spo2_samples','user_id,device_id,ts'),
    ('skinTempSample','noop_skin_temp_samples','user_id,device_id,ts'),
    ('respSample','noop_resp_samples','user_id,device_id,ts'),
    ('gravitySample','noop_gravity_samples','user_id,device_id,ts')
  ) allowed(stream,table_name,conflict_key) where stream=p_stream;
  if target_table is null then raise exception 'unsupported append stream' using errcode='22023'; end if;
  if jsonb_typeof(p_rows) is distinct from 'array' then
    raise exception 'append rows must be an array' using errcode='22023';
  end if;
  if jsonb_array_length(p_rows) not between 1 and 5000 then
    raise exception 'append batch size out of bounds' using errcode='22023';
  end if;
  if p_batch is null or not exists(select 1 from public.devices where id=p_device and user_id=p_user)
      or not exists(select 1 from public.noop_app_installations
        where source_id=p_source and user_id=p_user and revoked_at is null) then
    raise exception 'owned device and active installation required' using errcode='42501';
  end if;
  if exists(select 1 from jsonb_array_elements(p_rows) r where jsonb_typeof(r)<>'object'
      or (r->>'user_id')::uuid is distinct from p_user
      or (r->>'device_id')::uuid is distinct from p_device
      or (r->>'source_id')::uuid is distinct from p_source
      or (r->>'batch_id')::uuid is distinct from p_batch) then
    raise exception 'append row identity mismatch' using errcode='42501';
  end if;
  if exists(select 1 from jsonb_array_elements(p_rows) r cross join lateral jsonb_object_keys(r) k
      where not exists(select 1 from pg_catalog.pg_attribute a
        where a.attrelid=to_regclass('public.'||target_table) and a.attname=k
          and a.attnum>0 and not a.attisdropped and a.attgenerated='')) then
    raise exception 'unknown append column' using errcode='22023';
  end if;
  select string_agg(format('%I',k),',' order by k),
    string_agg(format('%I=excluded.%I',k,k),',' order by k)
    into columns_sql,updates_sql
    from (select distinct k from jsonb_array_elements(p_rows) r
      cross join lateral jsonb_object_keys(r) k) keys;

  if not pg_try_advisory_xact_lock_shared(
      hashtextextended('physiology-input:'||p_user::text||':'||p_device::text,230919)) then
    raise exception 'scoring_input_gate_busy' using errcode='55P03';
  end if;
  execute format('insert into public.%I (%s) select %s from jsonb_populate_recordset(null::public.%I,$1)
    on conflict (%s) do update set %s',target_table,columns_sql,columns_sql,target_table,conflict_columns,updates_sql)
    using p_rows;
  return jsonb_array_length(p_rows);
end $$;

revoke all on function public.noop_project_append_batch(uuid,uuid,uuid,uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.noop_project_append_batch(uuid,uuid,uuid,uuid,text,jsonb) to service_role;
notify pgrst, 'reload schema';
commit;
