-- Seed the already-deployed physiology schema before the history branch joins it.
insert into public.noop_step_samples(user_id,device_id,source_id,ts,counter,"activityClass",batch_id)
values('a8880000-0000-4000-8000-000000000001','a8880000-0000-4000-8000-000000000011',
  'a8880000-0000-4000-8000-000000000099',1789603200,321,2,'a8880000-0000-4000-8000-000000000099');
