begin;

create table public.scoring_fleet_policy (
  id boolean primary key default true check(id),
  max_workers integer not null default 4 check(max_workers between 1 and 64),
  per_user integer not null default 2 check(per_user between 1 and 8),
  per_device integer not null default 2 check(per_device between 1 and 8),
  live_weight integer not null default 3 check(live_weight between 1 and 20),
  dispatches bigint not null default 0
);
insert into public.scoring_fleet_policy default values;
create table public.scoring_fleet_tenants (
  user_id uuid primary key references auth.users(id) on delete cascade,
  last_dispatch bigint not null default 0
);
create table public.scoring_fleet_reservations (
  lease_token uuid primary key,
  user_id uuid not null,
  device_id uuid not null,
  day date not null,
  work_class text not null check(work_class in ('live','backfill')),
  input_revision bigint not null,
  run_id uuid not null,
  acquired_at timestamptz not null default clock_timestamp(),
  queued_at timestamptz not null,
  expires_at timestamptz not null,
  foreign key(user_id,device_id) references public.devices(user_id,id) on delete cascade
);
create index scoring_fleet_reservations_owner on public.scoring_fleet_reservations(user_id,device_id,expires_at);
create table public.scoring_fleet_completions (
  run_id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  work_class text not null,
  outcome text not null,
  completed_at timestamptz not null default clock_timestamp(),
  queue_seconds double precision not null,
  service_seconds double precision not null,
  latency_seconds double precision not null
);
create index scoring_fleet_completions_time on public.scoring_fleet_completions(completed_at);
do $$ declare t text; begin
  foreach t in array array['scoring_fleet_policy','scoring_fleet_tenants','scoring_fleet_reservations','scoring_fleet_completions'] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('create policy service_all on public.%I for all to service_role using(true) with check(true)',t);
    execute format('revoke all on public.%I from anon,authenticated',t);
    execute format('grant all on public.%I to service_role',t);
  end loop;
end $$;

create function public.scoring_work_class(p_day date,p_timezone text) returns text
language sql stable set search_path='' as $$
  select case when p_day >= (now() at time zone p_timezone)::date-1 then 'live' else 'backfill' end;
$$;

create view public.scoring_fleet_candidates with(security_invoker=true) as
select w.*,public.scoring_work_class(w.day,w.timezone_id) as work_class,
  coalesce(t.last_dispatch,0) as last_dispatch,
  case when public.scoring_work_class(w.day,w.timezone_id)=
    case when p.dispatches%(p.live_weight+1)=p.live_weight then 'backfill' else 'live' end
    then 0 else 1 end as class_rank
from public.physiology_work_items w cross join public.scoring_fleet_policy p
left join public.scoring_fleet_tenants t using(user_id)
where w.done_at is null and w.next_attempt_at<=clock_timestamp()
  and (w.lease_expires_at is null or w.lease_expires_at<=clock_timestamp())
  and not exists(select 1 from public.scoring_fleet_reservations r where r.user_id=w.user_id
    and r.device_id=w.device_id and r.day=w.day and r.expires_at>clock_timestamp())
  and (select count(*) from public.scoring_fleet_reservations r where r.user_id=w.user_id
    and r.device_id=w.device_id and r.expires_at>clock_timestamp())<p.per_device
  and (select count(*) from public.scoring_fleet_reservations r
    where r.user_id=w.user_id and r.expires_at>clock_timestamp())<p.per_user
  and (select count(*) from public.scoring_fleet_reservations r where r.expires_at>clock_timestamp())<p.max_workers;
revoke all on public.scoring_fleet_candidates from public,anon,authenticated;
grant select on public.scoring_fleet_candidates to service_role;

alter function public.scoring_claim_one(integer,integer,uuid,uuid,date) rename to scoring_claim_one_core;
alter function public.scoring_renew_lease(uuid,uuid,date,bigint,uuid,uuid,integer) rename to scoring_renew_lease_core;
alter function public.scoring_finish_work(uuid,uuid,date,bigint,uuid,uuid,text,integer,text) rename to scoring_finish_work_core;

create function public.scoring_claim_one(p_lease_seconds integer default 300,p_max_failures integer default 8,
  p_user uuid default null,p_device uuid default null,p_day date default null)
returns setof public.scoring_work_items language plpgsql security definer set search_path='' as $$
declare c record; w public.scoring_work_items%rowtype; ticket bigint;
begin
  -- A short scheduler transaction, never held while loading inputs or computing.
  perform pg_advisory_xact_lock(21112000);
  delete from public.scoring_fleet_reservations where expires_at<=clock_timestamp();
  select * into c from public.scoring_fleet_candidates
    where (p_user is null or user_id=p_user) and (p_device is null or device_id=p_device)
      and (p_day is null or day=p_day)
      and (failure_revision<>input_revision or consecutive_failures<p_max_failures)
    order by class_rank,last_dispatch,next_attempt_at,dirty_at,user_id,device_id,day limit 1;
  if not found then return; end if;
  select * into w from public.scoring_claim_one_core(p_lease_seconds,p_max_failures,c.user_id,c.device_id,c.day);
  if not found then return; end if;
  update public.scoring_fleet_policy set dispatches=dispatches+1 returning dispatches into ticket;
  insert into public.scoring_fleet_tenants values(w.user_id,ticket)
    on conflict(user_id) do update set last_dispatch=excluded.last_dispatch;
  insert into public.scoring_fleet_reservations(lease_token,user_id,device_id,day,work_class,input_revision,
    run_id,queued_at,expires_at) values(w.lease_token,w.user_id,w.device_id,w.day,c.work_class,w.input_revision,
      w.run_id,w.dirty_at,w.lease_expires_at);
  return next w;
end $$;

create function public.scoring_renew_lease(p_user uuid,p_device uuid,p_day date,p_revision bigint,
  p_lease_token uuid,p_run_id uuid,p_lease_seconds integer default 300) returns boolean
language plpgsql security definer set search_path='' as $$
declare renewed boolean;
begin
  if not exists(select 1 from public.scoring_fleet_reservations where lease_token=p_lease_token
      and user_id=p_user and device_id=p_device and day=p_day and run_id=p_run_id
      and input_revision=p_revision and expires_at>clock_timestamp()) then return false; end if;
  renewed:=public.scoring_renew_lease_core(p_user,p_device,p_day,p_revision,p_lease_token,p_run_id,p_lease_seconds);
  if renewed then
    update public.scoring_fleet_reservations set expires_at=clock_timestamp()+make_interval(secs=>greatest(1,least(p_lease_seconds,3600)))
      where lease_token=p_lease_token;
  end if;
  return renewed;
end $$;

create function public.scoring_finish_work(p_user uuid,p_device uuid,p_day date,p_revision bigint,
  p_lease_token uuid,p_run_id uuid,p_outcome text,p_duration_ms integer default null,p_error text default null)
returns boolean language plpgsql security definer set search_path='' as $$
declare finished boolean; r public.scoring_fleet_reservations%rowtype;
begin
  -- The original function still owns all publication, revision and lease validation.
  finished:=public.scoring_finish_work_core(p_user,p_device,p_day,p_revision,p_lease_token,p_run_id,
    p_outcome,p_duration_ms,p_error);
  delete from public.scoring_fleet_reservations where lease_token=p_lease_token and user_id=p_user
    and device_id=p_device and day=p_day and input_revision=p_revision and run_id=p_run_id returning * into r;
  if found then
    insert into public.scoring_fleet_completions(run_id,user_id,work_class,outcome,queue_seconds,service_seconds,latency_seconds)
      values(r.run_id,r.user_id,r.work_class,case when finished then p_outcome else 'superseded' end,
        greatest(0,extract(epoch from r.acquired_at-r.queued_at)),
        greatest(0,extract(epoch from clock_timestamp()-r.acquired_at)),
        greatest(0,extract(epoch from clock_timestamp()-r.queued_at))) on conflict do nothing;
  end if;
  return finished;
end $$;

create view public.scoring_fleet_metrics with(security_invoker=true) as
select classes.work_class,
  (select count(*) from public.physiology_work_items w where w.done_at is null
    and public.scoring_work_class(w.day,w.timezone_id)=classes.work_class) as pending,
  (select coalesce(max(extract(epoch from clock_timestamp()-w.dirty_at)),0) from public.physiology_work_items w
    where w.done_at is null and public.scoring_work_class(w.day,w.timezone_id)=classes.work_class) as oldest_seconds,
  (select count(*) from public.scoring_fleet_reservations r where r.work_class=classes.work_class
    and r.expires_at>clock_timestamp()) as running,
  percentile_cont(0.5) within group(order by c.latency_seconds) filter(where c.outcome='done') as p50_seconds,
  percentile_cont(0.95) within group(order by c.latency_seconds) filter(where c.outcome='done') as p95_seconds,
  percentile_cont(0.99) within group(order by c.latency_seconds) filter(where c.outcome='done') as p99_seconds,
  count(c.run_id) as attempts,
  count(c.run_id) filter(where c.outcome='superseded') as superseded
from (values('live'),('backfill')) classes(work_class)
left join public.scoring_fleet_completions c on c.work_class=classes.work_class
  and c.completed_at>clock_timestamp()-interval '1 hour'
group by classes.work_class;
revoke all on public.scoring_fleet_metrics from public,anon,authenticated;
grant select on public.scoring_fleet_metrics to service_role;

revoke all on function public.scoring_claim_one_core(integer,integer,uuid,uuid,date),
  public.scoring_renew_lease_core(uuid,uuid,date,bigint,uuid,uuid,integer),
  public.scoring_finish_work_core(uuid,uuid,date,bigint,uuid,uuid,text,integer,text)
  from public,anon,authenticated,service_role;
revoke all on function public.scoring_work_class(date,text),public.scoring_claim_one(integer,integer,uuid,uuid,date),
  public.scoring_renew_lease(uuid,uuid,date,bigint,uuid,uuid,integer),
  public.scoring_finish_work(uuid,uuid,date,bigint,uuid,uuid,text,integer,text) from public,anon,authenticated;
grant execute on function public.scoring_work_class(date,text),public.scoring_claim_one(integer,integer,uuid,uuid,date),
  public.scoring_renew_lease(uuid,uuid,date,bigint,uuid,uuid,integer),
  public.scoring_finish_work(uuid,uuid,date,bigint,uuid,uuid,text,integer,text) to service_role;
commit;
