-- Executed inside the isolated, fully migrated test database. Fixtures roll back.
begin;
insert into auth.users(id) values('a1111111-1111-4111-8111-111111111111'),('b1111111-1111-4111-8111-111111111111');
insert into public.devices(id,user_id,source_kind) values
 ('a2222222-2222-4222-8222-222222222222','a1111111-1111-4111-8111-111111111111','noop_push'),
 ('b2222222-2222-4222-8222-222222222222','b1111111-1111-4111-8111-111111111111','noop_push');
insert into public.server_daily_scores(user_id,source_device_id,day,algorithm_version,hrv_rmssd_ms)
select user_id,id,current_date,'frwhoop-server-1',42 from public.devices where id in
 ('a2222222-2222-4222-8222-222222222222','b2222222-2222-4222-8222-222222222222');
insert into public.server_sleep_nights(user_id,device_id,period_day,start_at,end_at,algorithm_version,asleep_min)
select user_id,id,current_date,current_date::timestamptz,current_date::timestamptz+interval '7 hours','frwhoop-server-1',420
 from public.devices where id in('a2222222-2222-4222-8222-222222222222','b2222222-2222-4222-8222-222222222222');
set local role authenticated;
select set_config('request.jwt.claim.sub','a1111111-1111-4111-8111-111111111111',true);
select set_config('request.jwt.claim.role','authenticated',true);
do $$ declare t text; n bigint; begin
  select count(*) into n from public.server_daily_scores where user_id='a1111111-1111-4111-8111-111111111111';
  assert n=1,'positive owner read control missing';
  select count(*) into n from public.devices where user_id='b1111111-1111-4111-8111-111111111111';
  assert n=0,'cross-owner device read';
  foreach t in array array['server_daily_scores','server_sleep_nights','server_physiology_results',
    'noop_projection_observations','noop_projection_conflicts','noop_wearable_aliases'] loop
    execute format('select count(*) from public.%I where user_id=$1',t) into n
      using 'b1111111-1111-4111-8111-111111111111'::uuid;
    assert n=0,'cross-owner result/provenance read';
  end loop;
  begin
    update public.server_daily_scores set hrv_rmssd_ms=999 where user_id='b1111111-1111-4111-8111-111111111111';
    get diagnostics n=row_count; assert n=0,'cross-owner score write';
  exception when insufficient_privilege then null; end;
  begin
    delete from public.server_sleep_nights where user_id='b1111111-1111-4111-8111-111111111111';
    get diagnostics n=row_count; assert n=0,'cross-owner night deletion';
  exception when insufficient_privilege then null; end;
  begin
    perform public.server_scoring_for_device_day('b1111111-1111-4111-8111-111111111111',current_date,
      'b2222222-2222-4222-8222-222222222222');
    raise exception 'cross-owner RPC allowed';
  exception when insufficient_privilege then null; end;
  begin
    perform public.retire_noop_installation(repeat('0',64));
    raise exception 'mobile retirement RPC allowed';
  exception when insufficient_privilege then null; end;
  begin
    delete from public.noop_projection_observations where user_id='b1111111-1111-4111-8111-111111111111';
    raise exception 'mobile administrative deletion allowed';
  exception when insufficient_privilege then null; end;
  begin
    update public.scoring_fleet_policy set per_user=8;
    raise exception 'mobile scheduler mutation allowed';
  exception when insufficient_privilege then null; end;
end $$;
set local role anon;
select set_config('request.jwt.claim.sub','',true);
select set_config('request.jwt.claim.role','anon',true);
do $$ begin
  begin
    perform public.scoring_claim_one();
    raise exception 'anonymous worker claim allowed';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
do $$ begin
  assert (select count(*)=1 from public.server_daily_scores where user_id='b1111111-1111-4111-8111-111111111111' and hrv_rmssd_ms=42),
    'other owner score changed';
  assert (select count(*)=1 from public.server_sleep_nights where user_id='b1111111-1111-4111-8111-111111111111'),
    'other owner night deleted';
end $$;
rollback;
