-- Executed after the old coalescing migration and before its additive repair.
insert into auth.users values('a8880000-0000-4000-8000-000000000101');
insert into profiles(id,timezone) values('a8880000-0000-4000-8000-000000000101','UTC');
insert into devices(id,user_id) values('a8880000-0000-4000-8000-000000000102','a8880000-0000-4000-8000-000000000101');
select public.physiology_enqueue_day('a8880000-0000-4000-8000-000000000101','a8880000-0000-4000-8000-000000000102','2026-09-17','UTC',0);
create table public.queue_test_coalesced_claim as
select * from public.scoring_claim_one(300,8,'a8880000-0000-4000-8000-000000000101','a8880000-0000-4000-8000-000000000102','2026-09-17');
select public.physiology_enqueue_day('a8880000-0000-4000-8000-000000000101','a8880000-0000-4000-8000-000000000102','2026-09-17','UTC',0);
do $$ begin
  assert (select input_revision=1 and status='running' and dirty_at>claimed_at
    from public.physiology_work_items where user_id='a8880000-0000-4000-8000-000000000101');
end $$;
