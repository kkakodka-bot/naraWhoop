-- Existing timestamp-keyed scalar streams. Apply after 050000, before enabling them in Edge.
-- 020000/040000 remain unchanged; atomic settlement still belongs to noop_commit_push_projection.
create or replace function public.noop_apply_projection_rows(p_stream text,p_rows jsonb) returns void
language plpgsql security definer set search_path=pg_catalog,public as $$
declare t text; keys text; cols text; assignments text; changed text; ordering text:='';
begin
  select tab,conf into t,keys from (values
    ('hrSample','noop_hr_samples','user_id,device_id,ts'),
    ('rrInterval','noop_rr_intervals','user_id,device_id,ts,"rrMs",seq'),
    ('event','noop_events','user_id,device_id,ts,kind'),
    ('battery','noop_battery_samples','user_id,device_id,ts'),
    ('spo2Sample','noop_spo2_samples','user_id,device_id,ts'),
    ('skinTempSample','noop_skin_temp_samples','user_id,device_id,ts'),
    ('respSample','noop_resp_samples','user_id,device_id,ts'),
    ('gravitySample','noop_gravity_samples','user_id,device_id,ts'),
    ('stepSample','noop_step_samples','user_id,device_id,ts'),
    ('sleepStateSample','noop_sleep_state_samples','user_id,device_id,ts'),
    ('ppgHrSample','noop_ppg_hr_samples','user_id,device_id,ts'),
    ('dailyMetric','daily_metrics','user_id,day'),('sleepSession','sessions','id'),
    ('workout','sessions','id'),('journal','noop_journal_entries','user_id,device_id,day,question')
  ) registry(stream,tab,conf) where stream=p_stream;
  if t is null or jsonb_typeof(p_rows) is distinct from 'array' then raise exception 'invalid_projection'; end if;
  if jsonb_array_length(p_rows)=0 then return; end if;
  if exists(select 1 from jsonb_array_elements(p_rows) r,jsonb_object_keys(r) k
    where not exists(select 1 from pg_attribute a where a.attrelid=('public.'||t)::regclass
      and a.attname=k and a.attnum>0 and not a.attisdropped and a.attgenerated='')) then
    raise exception 'invalid_projection_column';
  end if;
  select string_agg(format('%I',k),',' order by k),
    string_agg(format('%1$I=excluded.%1$I',k),',' order by k),
    string_agg(format('target.%1$I is distinct from excluded.%1$I',k),' or ' order by k)
    into cols,assignments,changed from (select distinct k from jsonb_array_elements(p_rows) r,jsonb_object_keys(r) k) s;
  -- A delayed archive repair cannot replace a newer accepted correction at the same timestamp.
  -- The three immutable scalar streams instead reach their conflict trigger even on old replay.
  if p_stream in ('hrSample','rrInterval','event','battery','spo2Sample','skinTempSample','respSample','gravitySample') then
    ordering := ' and coalesce((select created_at from public.noop_push_reservations where user_id=target.user_id and batch_id=target.batch_id),''-infinity''::timestamptz)
      <= (select created_at from public.noop_push_reservations where user_id=excluded.user_id and batch_id=excluded.batch_id)';
  end if;
  execute format('insert into public.%1$I as target (%2$s) select %2$s from jsonb_populate_recordset(null::public.%1$I,$1)
    on conflict (%3$s) do update set %4$s where (%5$s)%6$s',t,cols,keys,assignments,changed,ordering) using p_rows;
end $$;

revoke all on function public.noop_apply_projection_rows(text,jsonb) from public,anon,authenticated;
grant execute on function public.noop_apply_projection_rows(text,jsonb) to service_role;

-- Scalar timestamp views are immutable measurements, not a last-writer correction API.
-- ON CONFLICT UPDATE invokes this under the row lock, including concurrent settlements.
-- Metadata-only retries remain idempotent and do not dirty scoring through its existing triggers.
create function public.noop_scalar_measurement_immutable() returns trigger
language plpgsql set search_path=pg_catalog,public as $$
begin
  if (to_jsonb(new)-array['source_id','batch_id','ingested_at']) is distinct from
     (to_jsonb(old)-array['source_id','batch_id','ingested_at']) then
    raise exception 'scalar_identity_conflict' using errcode='23505';
  end if;
  return new;
end $$;
create trigger noop_scalar_measurement_immutable before update on public.noop_step_samples
  for each row execute function public.noop_scalar_measurement_immutable();
create trigger noop_scalar_measurement_immutable before update on public.noop_sleep_state_samples
  for each row execute function public.noop_scalar_measurement_immutable();
create trigger noop_scalar_measurement_immutable before update on public.noop_ppg_hr_samples
  for each row execute function public.noop_scalar_measurement_immutable();
revoke all on function public.noop_scalar_measurement_immutable() from public,anon,authenticated;
grant execute on function public.noop_scalar_measurement_immutable() to service_role;

-- Legacy scalar tables had owner policies but did not explicitly grant normal-user reads.
-- Writes remain receiver-only. Step table grants/policies and triggers are owned by 050000.
grant select on public.noop_sleep_state_samples,public.noop_ppg_hr_samples to authenticated;
revoke insert,update,delete,truncate,references,trigger on public.noop_sleep_state_samples,public.noop_ppg_hr_samples from anon,authenticated;
grant all on public.noop_sleep_state_samples,public.noop_ppg_hr_samples to service_role;
