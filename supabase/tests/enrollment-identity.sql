\set ON_ERROR_STOP on
select set_config('request.jwt.claim.role','service_role',false);
insert into auth.users(id) values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
insert into profiles(id) values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
insert into noop_enrollment_codes(user_id,code_hash,expires_at) values
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',repeat('a',64),now()+interval '1 day'),
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',repeat('c',64),now()+interval '1 day'),
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',repeat('b',64),now()+interval '1 day');

create function pg_temp.expect_failure(statement text, expected_state text) returns void language plpgsql as $$
begin
  begin execute statement;
  exception when others then
    if sqlstate=expected_state then return; end if;
    raise exception 'unexpected SQL state: %, expected %',sqlstate,expected_state;
  end;
  raise exception 'statement unexpectedly succeeded';
end $$;

select * from redeem_noop_enrollment(repeat('a',64),'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1','ios','fixture',repeat('1',64),300);
select * from redeem_noop_enrollment(repeat('a',64),'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1','ios','fixture',repeat('1',64),300);
do $$ begin
  if (select count(*) from noop_ingest_tokens where user_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')<>1 then
    raise exception 'same-code retry changed credential count'; end if;
  if (select count(*) from noop_enrollment_redemptions where source_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1')<>2 then
    raise exception 'retry audit missing'; end if;
end $$;
select pg_temp.expect_failure($q$select * from redeem_noop_enrollment(repeat('a',64),'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2','ios','fixture',repeat('2',64),300)$q$,'P0001');
select pg_temp.expect_failure($q$select * from redeem_noop_enrollment(repeat('b',64),'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1','ios','fixture',repeat('2',64),300)$q$,'P0001');
update noop_ingest_tokens set revoked_at=now() where source_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1';
select pg_temp.expect_failure($q$select * from redeem_noop_enrollment(repeat('a',64),'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1','ios','fixture',repeat('1',64),300)$q$,'P0001');

select register_noop_device('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaad1','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','whoop-STRAP001',now());
select register_noop_device('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaad2','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','whoop-STRAP002',now());
select register_noop_device('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbd1','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','whoop-STRAP001',now());
select pg_temp.expect_failure($q$select register_noop_device('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaad1','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','whoop-STRAP001',now())$q$,'23514');
insert into physiology_source_selection(user_id,feature,device_id,algorithm_version)
  select 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',feature,'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaad2',algorithm_version
  from physiology_feature_defaults;
do $$ declare snapshot jsonb; feature jsonb;
begin
  snapshot:=server_scoring_for_device_day('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','2026-09-19','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaad1');
  for feature in select value from jsonb_each(snapshot->'features') loop
    if feature->>'device_id' is distinct from 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaad1' then
      raise exception 'explicit device read followed another selected strap'; end if;
  end loop;
  if exists(select 1 from physiology_source_selection where user_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
      and device_id<>'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaad2') then raise exception 'read mutated device selection'; end if;
end $$;
select pg_temp.expect_failure($q$select server_scoring_for_device_day('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','2026-09-19','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbd1')$q$,'42501');

-- A feature abstention keeps the requested device identity and cannot hide another qualified feature.
begin;
update physiology_feature_qualifications set qualification='shadow' where feature='sleep';
insert into physiology_work_items(user_id,device_id,day,timezone_id) values
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaad1','2026-09-19','UTC');
insert into server_physiology_results(user_id,device_id,period_day,algorithm_version,input_revision,
  run_id,manifest_hash,payload,payload_hash,computed_at,publication_status)
select 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaad1',
  '2026-09-19',algorithm_version,1,'ffffffff-ffff-4fff-8fff-ffffffffffff',repeat('f',64),
  '{"daily":{"hrv_rmssd_ms":42},"nights":[],"measurements":[]}'::jsonb,repeat('f',64),now(),'provisional'
from physiology_feature_defaults where feature='hrv';
do $$ declare snapshot jsonb;
begin
  snapshot:=server_scoring_for_device_day('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','2026-09-19','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaad1');
  if snapshot#>>'{features,sleep,reason}' is distinct from 'unqualified_version'
      or snapshot#>>'{features,sleep,device_id}' is distinct from 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaad1'
      or snapshot#>>'{features,hrv,status}' is distinct from 'available'
      or snapshot#>>'{features,hrv,device_id}' is distinct from 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaad1'
      or snapshot#>>'{daily,hrv_rmssd_ms}' is distinct from '42' then
    raise exception 'mixed unavailable feature lost device identity or qualified HRV'; end if;
end $$;
rollback;

select enrolled_physiology_sleep_override('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaad1',
  'dddddddd-dddd-4ddd-8ddd-dddddddddddd','2026-09-19 00:00Z','2026-09-19 08:00Z','2026-09-19 00:10Z','2026-09-19 08:00Z',false,0);
select pg_temp.expect_failure($q$select enrolled_physiology_sleep_override('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaad1',
  'dddddddd-dddd-4ddd-8ddd-dddddddddddd','2026-09-19 00:00Z','2026-09-19 08:00Z','2026-09-19 00:20Z','2026-09-19 08:00Z',false,0)$q$,'40001');
select pg_temp.expect_failure($q$select enrolled_physiology_sleep_override('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbd1',
  'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','2026-09-19 00:00Z','2026-09-19 08:00Z','2026-09-19 00:20Z','2026-09-19 08:00Z',false,0)$q$,'42501');
do $$ begin
  if nullif(current_setting('request.jwt.claim.sub',true),'') is not null then raise exception 'owner claim leaked after override'; end if;
  if (select user_id from physiology_sleep_overrides where id='dddddddd-dddd-4ddd-8ddd-dddddddddddd')<>'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' then
    raise exception 'override owner changed'; end if;
  if has_table_privilege('authenticated','noop_ingest_tokens','SELECT')
      or has_table_privilege('anon','noop_enrollment_codes','SELECT')
      or has_function_privilege('authenticated','server_scoring_for_device_day(uuid,date,uuid)','EXECUTE')
      or has_function_privilege('authenticated','enrolled_physiology_sleep_override(uuid,uuid,uuid,timestamptz,timestamptz,timestamptz,timestamptz,boolean,bigint,text)','EXECUTE') then
    raise exception 'client has backend-only privileges'; end if;
end $$;
select 'PASS: atomic retry, source isolation, revocation, device ownership, scoped reads, sleep concurrency and backend-only grants';
