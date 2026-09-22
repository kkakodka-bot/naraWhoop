begin;
create table public.noop_fleet_intake_policy (
  id boolean primary key default true check(id),
  source_requests_per_minute integer not null default 200 check(source_requests_per_minute between 1 and 10000),
  user_requests_per_minute integer not null default 600 check(user_requests_per_minute between 1 and 30000),
  model_slots integer not null default 1 check(model_slots between 1 and 16),
  history_slots integer not null default 1 check(history_slots between 1 and 16)
);
insert into public.noop_fleet_intake_policy default values;
-- Survives Auth deletion so restore operators can reapply erasure before opening admission.
create table public.noop_account_retirements(user_id uuid primary key,requested_at timestamptz not null default clock_timestamp());
create table public.noop_fleet_intake_usage (
  user_id uuid not null,
  source_id uuid not null,
  minute timestamptz not null,
  requests integer not null,
  primary key(user_id,source_id,minute),
  foreign key(user_id,source_id) references public.noop_app_installations(user_id,source_id) on delete cascade
);
create table public.scoring_lane_tenants (
  lane text not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  last_dispatch timestamptz not null default clock_timestamp(),
  primary key(lane,user_id)
);
do $$ declare t text; begin
  foreach t in array array['noop_fleet_intake_policy','noop_fleet_intake_usage','scoring_lane_tenants','noop_account_retirements'] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('revoke all on public.%I from anon,authenticated',t);
    execute format('grant all on public.%I to service_role',t);
    execute format('create policy service_all on public.%I for all to service_role using(true) with check(true)',t);
  end loop;
end $$;

create function public.begin_noop_account_deletion(p_user uuid) returns void
language plpgsql security definer set search_path='' as $$
begin
  if auth.role() is distinct from 'service_role' then raise exception 'service role required' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended('account-admission:'||p_user,0));
  insert into public.noop_account_retirements(user_id) values(p_user) on conflict do nothing;
  update public.noop_app_installations set retired_at=coalesce(retired_at,clock_timestamp()),
    retirement_id=coalesce(retirement_id,gen_random_uuid()),revoked_at=coalesce(revoked_at,clock_timestamp()) where user_id=p_user;
  update public.noop_ingest_tokens set revoked_at=coalesce(revoked_at,clock_timestamp()) where user_id=p_user;
end $$;
create function public.noop_account_retirement_admission() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  -- Shares the owner mutex with the deletion freeze; a raced enrollment either commits before
  -- the freeze and is revoked, or observes the tombstone and cannot create a fresh source.
  perform pg_advisory_xact_lock(hashtextextended('account-admission:'||new.user_id,0));
  if exists(select 1 from public.noop_account_retirements where user_id=new.user_id) then
    raise exception 'account_retired' using errcode='42501';
  end if;
  return new;
end $$;
create trigger noop_account_retirement_admission before insert on public.noop_app_installations
  for each row execute function public.noop_account_retirement_admission();

create function public.delete_noop_integration_credentials(p_user uuid) returns void
language plpgsql security definer set search_path='' as $$
begin
  if auth.role() is distinct from 'service_role' or not exists(
    select 1 from public.noop_account_retirements where user_id=p_user) then
    raise exception 'account_deletion_freeze_required' using errcode='42501';
  end if;
  delete from internal.integration_credentials where user_id=p_user;
end $$;

create function public.admit_noop_request(p_user uuid,p_source uuid) returns boolean
language plpgsql security definer set search_path='' as $$
declare m timestamptz:=date_trunc('minute',clock_timestamp()); p public.noop_fleet_intake_policy%rowtype;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'service role required' using errcode='42501'; end if;
  perform 1 from public.noop_app_installations where user_id=p_user and source_id=p_source
    and revoked_at is null and retired_at is null for share;
  if not found then raise exception 'inactive_installation' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended('intake-budget:'||p_user,0));
  select * into p from public.noop_fleet_intake_policy;
  if coalesce((select requests from public.noop_fleet_intake_usage
    where user_id=p_user and source_id=p_source and minute=m),0)>=p.source_requests_per_minute
    or coalesce((select sum(requests) from public.noop_fleet_intake_usage where user_id=p_user and minute=m),0)>=p.user_requests_per_minute
    then return false; end if;
  insert into public.noop_fleet_intake_usage values(p_user,p_source,m,1)
    on conflict(user_id,source_id,minute) do update set requests=noop_fleet_intake_usage.requests+1;
  return true;
end $$;

-- Operational counters contain no signal payload. Raw receipts, health projections and immutable
-- results are retained until their explicit object retention/account-deletion policy applies.
create function public.prune_multiuser_operational_records() returns jsonb
language plpgsql security definer set search_path='' as $$
declare completions integer; intake integer;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'service role required' using errcode='42501'; end if;
  delete from public.scoring_fleet_completions where completed_at<clock_timestamp()-interval '30 days';
  get diagnostics completions=row_count;
  delete from public.noop_fleet_intake_usage where minute<clock_timestamp()-interval '2 days';
  get diagnostics intake=row_count;
  return jsonb_build_object('completionRows',completions,'intakeRows',intake);
end $$;

-- Preserve the model activation, immutable input and output-validation machinery inside its
-- original function. A shared transaction mutex bounds slots across model IDs and replicas.
alter function public.physiology_claim_model(text,text,integer) rename to physiology_claim_model_core;
create or replace function public.physiology_claim_model_core(p_model text,p_activation_hash text,p_lease_seconds integer default 120)
returns setof public.physiology_model_work_items language plpgsql security definer set search_path='' as $$
declare candidate uuid;
begin
  if p_lease_seconds not between 10 and 600 then raise exception 'model_lease_bounds'; end if;
  -- One live job per model, not one global lock across all models or users.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('physiology-model:'||p_model,0));
  -- Reconcile after activation/input-commit races: neither transaction's trigger can
  -- see the other's uncommitted row. This scan is model-local and idempotent.
  insert into public.physiology_model_work_items(user_id,device_id,day,input_revision,timezone_id,model_id,activation_revision)
    select i.user_id,i.device_id,i.day,i.input_revision,i.timezone_id,s.model_id,s.activation_revision
    from public.physiology_work_items i cross join public.physiology_model_selection s
    join public.physiology_model_activations a using(model_id,activation_revision)
    where s.model_id=p_model and s.enabled and a.activation_sha256=p_activation_hash
    on conflict do nothing;
  if exists(select 1 from public.physiology_model_work_items where model_id=p_model and state='running' and lease_expires_at>clock_timestamp()) then return; end if;
  update public.physiology_model_work_items set state='failed',reason='retry_exhausted',finished_at=clock_timestamp(),lease_token=null,lease_expires_at=null
    where model_id=p_model and state='running' and lease_expires_at<=clock_timestamp() and attempts>=4;
  update public.physiology_model_work_items set state='retry',reason='model_lease_expired',lease_token=null,lease_expires_at=null,
    next_attempt_at=clock_timestamp()+pg_catalog.make_interval(secs=>least(3600,30*(2^attempts)::integer))
    where model_id=p_model and state='running' and lease_expires_at<=clock_timestamp() and attempts<4;
  select w.job_id into candidate from public.physiology_model_work_items w
    join public.physiology_model_selection s on s.model_id=w.model_id and s.activation_revision=w.activation_revision and s.enabled
    join public.physiology_model_activations a on a.model_id=w.model_id and a.activation_revision=w.activation_revision
    join public.physiology_work_items i on i.user_id=w.user_id and i.device_id=w.device_id and i.day=w.day and i.input_revision=w.input_revision
    where w.model_id=p_model and a.activation_sha256=p_activation_hash and w.attempts<4 and w.next_attempt_at<=clock_timestamp()
      and w.state in ('pending','retry','waiting')
    order by coalesce((select last_dispatch from public.scoring_lane_tenants where lane='model' and user_id=w.user_id),'-infinity'),
      w.next_attempt_at,w.created_at,w.job_id for update of w skip locked limit 1;
  return query update public.physiology_model_work_items set state='running',attempts=attempts+1,
    lease_token=extensions.gen_random_uuid(),lease_expires_at=clock_timestamp()+pg_catalog.make_interval(secs=>p_lease_seconds),reason=null
    where job_id=candidate returning *;
end $$;

create function public.physiology_claim_model(p_model text,p_activation_hash text,p_lease_seconds integer default 120)
returns setof public.physiology_model_work_items language plpgsql security definer set search_path='' as $$
declare w public.physiology_model_work_items%rowtype;
begin
  perform pg_advisory_xact_lock(21113001);
  if (select count(*) from public.physiology_model_work_items where state='running' and lease_expires_at>clock_timestamp())
    >=(select model_slots from public.noop_fleet_intake_policy) then return; end if;
  for w in select * from public.physiology_claim_model_core(p_model,p_activation_hash,p_lease_seconds) loop
    insert into public.scoring_lane_tenants values('model',w.user_id,clock_timestamp())
      on conflict(lane,user_id) do update set last_dispatch=excluded.last_dispatch;
    return next w;
  end loop;
end $$;

create or replace function public.claim_scoring_history_v3(p_version text,p_lease_seconds integer default 300)
returns setof public.scoring_jobs_v2 language plpgsql security definer set search_path=public as $$
declare j scoring_jobs_v2; g bigint; predecessor bigint;
begin
  if p_lease_seconds<1 or p_lease_seconds>3600 then raise exception 'invalid_lease'; end if;
  perform pg_advisory_xact_lock(21113002);
  if (select count(*) from scoring_jobs_v2 where algorithm_version=p_version and lease_until>clock_timestamp())
    >=(select history_slots from noop_fleet_intake_policy) then return; end if;
  select q.* into j from scoring_jobs_v2 q join scoring_history_heads_v3 h
    using(user_id,device_id,algorithm_version)
  where q.algorithm_version=p_version and q.day>=h.dirty_from and q.history_generation=h.generation
    and q.completed_revision<q.input_revision and not q.dead_letter and q.not_before<=clock_timestamp()
    and (q.lease_until is null or q.lease_until<=clock_timestamp())
    and not exists(select 1 from scoring_jobs_v2 active where active.user_id=q.user_id
      and active.algorithm_version=p_version and active.lease_until>clock_timestamp())
    and exists(select 1 from scoring_algorithms_v2 a where a.algorithm_version=p_version and a.enabled)
    and not exists(select 1 from scoring_jobs_v2 prior where prior.user_id=q.user_id
      and prior.device_id=q.device_id and prior.algorithm_version=q.algorithm_version
      and prior.day>=h.dirty_from and prior.day<q.day)
    and not exists(select 1 from scoring_invalidations_v2 i where i.user_id=q.user_id
      and i.device_id=q.device_id and i.algorithm_version=q.algorithm_version and i.next_day<=q.day)
  order by coalesce((select last_dispatch from scoring_lane_tenants where lane='history' and user_id=q.user_id),'-infinity'),
    q.dirty_at,q.user_id,q.day,q.device_id for update of q skip locked limit 1;
  if not found then return; end if;
  select generation into g from scoring_history_heads_v3
    where user_id=j.user_id and device_id=j.device_id and algorithm_version=p_version;
  select result_revision into predecessor from scoring_history_checkpoints_v3
    where user_id=j.user_id and device_id=j.device_id and algorithm_version=p_version and day<j.day
    order by day desc,result_revision desc limit 1;
  insert into scoring_lane_tenants values('history',j.user_id,clock_timestamp())
    on conflict(lane,user_id) do update set last_dispatch=excluded.last_dispatch;
  return query update scoring_jobs_v2 q set lease_token=gen_random_uuid(),
    lease_until=clock_timestamp()+make_interval(secs=>p_lease_seconds),history_claim_generation=g,
    history_predecessor_revision=predecessor,last_claimed_at=clock_timestamp(),claim_count=q.claim_count+1,
    lease_expiry_count=q.lease_expiry_count+case when q.lease_token is null then 0 else 1 end
    where (q.user_id,q.device_id,q.day,q.algorithm_version)=(j.user_id,j.device_id,j.day,j.algorithm_version)
    returning q.*;
end $$;

revoke all on function public.physiology_claim_model_core(text,text,integer) from public,anon,authenticated,service_role;
revoke all on function public.admit_noop_request(uuid,uuid),public.prune_multiuser_operational_records(),
  public.physiology_claim_model(text,text,integer),public.begin_noop_account_deletion(uuid),
  public.delete_noop_integration_credentials(uuid),
  public.noop_account_retirement_admission() from public,anon,authenticated;
grant execute on function public.admit_noop_request(uuid,uuid),public.prune_multiuser_operational_records(),
  public.physiology_claim_model(text,text,integer),public.begin_noop_account_deletion(uuid),
  public.delete_noop_integration_credentials(uuid) to service_role;
commit;
