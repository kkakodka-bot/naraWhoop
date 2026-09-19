begin;
insert into auth.users(id) values('a8880000-0000-4000-8000-000000000001');
insert into profiles(id,timezone) values('a8880000-0000-4000-8000-000000000001','America/Los_Angeles')
  on conflict(id) do update set timezone=excluded.timezone;
insert into devices(id,user_id,source_kind,device_family) values('a8880000-0000-4000-8000-000000000011','a8880000-0000-4000-8000-000000000001','noop_push','whoop5');
insert into noop_hr_samples(user_id,device_id,source_id,ts,bpm,batch_id) values('a8880000-0000-4000-8000-000000000001','a8880000-0000-4000-8000-000000000011','a8880000-0000-4000-8000-000000000099',1789603200,60,'a8880000-0000-4000-8000-000000000099');
insert into noop_rr_intervals(user_id,device_id,source_id,ts,"rrMs",seq,ord,"srcChannel","tsSuspect",batch_id)
  select 'a8880000-0000-4000-8000-000000000001','a8880000-0000-4000-8000-000000000011','a8880000-0000-4000-8000-000000000099',1789603200,800,n,n,5,0,'a8880000-0000-4000-8000-000000000099' from generate_series(1,3) n;
insert into noop_gravity_samples(user_id,device_id,source_id,ts,x,y,z,"dynAccel",batch_id)
  select 'a8880000-0000-4000-8000-000000000001','a8880000-0000-4000-8000-000000000011','a8880000-0000-4000-8000-000000000099',1789603200+n,0,0,1,n*0.01,'a8880000-0000-4000-8000-000000000099' from generate_series(0,1) n;
insert into server_daily_scores(user_id,day,algorithm_version,source_device_id,hrv_rmssd_ms)
  values('a8880000-0000-4000-8000-000000000001','2026-09-17','frwhoop-server-1','a8880000-0000-4000-8000-000000000011',45);
insert into server_sleep_nights(user_id,device_id,period_day,start_at,end_at,algorithm_version,asleep_min)
  values('a8880000-0000-4000-8000-000000000001','a8880000-0000-4000-8000-000000000011','2026-09-17','2026-09-17T01:00:00Z','2026-09-17T02:00:00Z','frwhoop-server-1',60);
insert into sessions(id,user_id,device_id,kind,start_at,end_at,user_modified) values('a8880000-0000-4000-8000-000000000033','a8880000-0000-4000-8000-000000000001','a8880000-0000-4000-8000-000000000011','sleep','2026-09-17T01:00:00Z','2026-09-17T02:00:00Z',true);
insert into sleep_details(session_id,user_id,original_start_at,original_end_at,user_start_at,user_end_at) values('a8880000-0000-4000-8000-000000000033','a8880000-0000-4000-8000-000000000001','2026-09-17T01:00:00Z','2026-09-17T02:00:00Z','2026-09-17T01:10:00Z','2026-09-17T02:10:00Z');
insert into scoring_work_items(user_id,device_id,day,done_at,attempts) values('a8880000-0000-4000-8000-000000000001','a8880000-0000-4000-8000-000000000011','2026-09-17',now(),400);
create schema audit_fixture;
create table audit_fixture.before_rows(table_name text primary key,rows jsonb);
do $$ declare t text; j jsonb; begin
  foreach t in array array['profiles','devices','noop_hr_samples','noop_rr_intervals','noop_gravity_samples','server_daily_scores','server_sleep_nights','sessions','sleep_details'] loop
    execute format('select jsonb_agg(to_jsonb(r) order by to_jsonb(r)::text) from public.%I r',t) into j;
    insert into audit_fixture.before_rows values(t,j);
  end loop;
end $$;
commit;
