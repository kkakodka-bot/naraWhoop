-- Active claims from both pre-isolation protocols must survive the additive split.
insert into auth.users values('10000000-0000-0000-0000-000000000001');
insert into profiles(id,timezone) values('10000000-0000-0000-0000-000000000001','UTC');
insert into devices(id,user_id) values('10000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001');
select scoring_enqueue_day('10000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000002','2026-09-10','UTC',0);
update scoring_work_items set claimed_at=clock_timestamp(),attempts=1
  where user_id='10000000-0000-0000-0000-000000000001' and day='2026-09-10';
select scoring_enqueue_day('10000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000002','2026-09-11','UTC',0);
select * from scoring_claim_one(3600,8,'10000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000002','2026-09-11');
