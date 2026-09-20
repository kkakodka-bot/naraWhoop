insert into auth.users values('00000000-0000-0000-0000-000000000001');
insert into profiles(id,timezone) values('00000000-0000-0000-0000-000000000001','America/Los_Angeles');
insert into devices(id,user_id) values('00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000001');
insert into scoring_work_items(user_id,device_id,day,attempts,done_at,claimed_at)
values('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000002','2026-09-01',400,now(),now());
insert into noop_resp_samples(user_id,device_id,source_id,ts,raw,batch_id)
values('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000002',
  '00000000-0000-0000-0000-000000000003',extract(epoch from '2026-09-03T23:00:00Z'::timestamptz),15,
  '00000000-0000-0000-0000-000000000004');
