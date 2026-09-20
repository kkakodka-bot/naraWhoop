begin;

-- Optional inference never owns a deterministic scoring lease or canonical projection.
create table public.physiology_model_activations (
  model_id text not null check (model_id ~ '^[a-z0-9][a-z0-9-]{0,79}$'),
  activation_revision bigint generated always as identity,
  activation_payload text not null check (octet_length(activation_payload) <= 1048576),
  activation_sha256 text not null check (activation_sha256 ~ '^[0-9a-f]{64}$'),
  checkpoint_sha256 text not null check (checkpoint_sha256 ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default clock_timestamp(),
  primary key(model_id,activation_revision),
  check (activation_sha256=encode(extensions.digest(convert_to(activation_payload,'UTF8'),'sha256'),'hex')),
  check (coalesce((activation_payload::jsonb)->>'model_id'=model_id,false)),
  check (coalesce((activation_payload::jsonb)->>'publication_mode'='shadow',false)),
  check (coalesce((activation_payload::jsonb)->'canonical_outputs_allowed'='false'::jsonb,false))
);
create trigger physiology_model_activation_immutable before update or delete on public.physiology_model_activations
  for each row execute function internal.physiology_immutable_release();

create table public.physiology_model_selection (
  model_id text primary key,
  activation_revision bigint not null,
  enabled boolean not null default true,
  changed_at timestamptz not null default clock_timestamp(),
  foreign key(model_id,activation_revision) references public.physiology_model_activations
);
create table public.physiology_model_work_items (
  job_id uuid primary key default extensions.gen_random_uuid(),
  user_id uuid not null,
  device_id uuid not null,
  day date not null,
  input_revision bigint not null check (input_revision > 0),
  timezone_id text not null,
  model_id text not null,
  activation_revision bigint not null,
  state text not null default 'pending' check (state in ('pending','running','retry','waiting','complete','abstained','failed','cancelled')),
  attempts integer not null default 0 check (attempts >= 0),
  next_attempt_at timestamptz not null default clock_timestamp(),
  lease_token uuid,
  lease_expires_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  finished_at timestamptz,
  reason text,
  foreign key(user_id,device_id) references public.devices(user_id,id) on delete cascade,
  foreign key(model_id,activation_revision) references public.physiology_model_activations,
  unique(user_id,device_id,day,input_revision,model_id,activation_revision)
);
create index physiology_model_runnable on public.physiology_model_work_items(model_id,next_attempt_at)
  where state in ('pending','running','retry','waiting');
create table public.physiology_model_results (
  job_id uuid primary key references public.physiology_model_work_items on delete cascade,
  output jsonb not null check (octet_length(output::text) <= 4194304),
  output_sha256 text not null check (output_sha256 ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default clock_timestamp(),
  check (output->>'publication_mode'='shadow'),
  check (output->'canonical_outputs_allowed'='false'::jsonb)
);
-- No client or canonical read path consumes this research-only result table.
alter table public.physiology_model_activations enable row level security;
alter table public.physiology_model_selection enable row level security;
alter table public.physiology_model_work_items enable row level security;
alter table public.physiology_model_results enable row level security;
revoke all on public.physiology_model_activations,public.physiology_model_selection,
  public.physiology_model_work_items,public.physiology_model_results from public,anon,authenticated,service_role;
grant select on public.physiology_model_activations,public.physiology_model_selection,
  public.physiology_model_work_items,public.physiology_model_results to service_role;

create function internal.physiology_enqueue_models() returns trigger language plpgsql security definer set search_path='' as $$
begin
  update public.physiology_model_work_items set state='cancelled',reason='input_superseded',
    lease_token=null,lease_expires_at=null,finished_at=clock_timestamp()
  where user_id=new.user_id and device_id=new.device_id and day=new.day and input_revision<>new.input_revision
    and state in ('pending','running','retry','waiting');
  insert into public.physiology_model_work_items(user_id,device_id,day,input_revision,timezone_id,model_id,activation_revision)
    select new.user_id,new.device_id,new.day,new.input_revision,new.timezone_id,s.model_id,s.activation_revision
    from public.physiology_model_selection s where s.enabled
    on conflict do nothing;
  return new;
end $$;
create trigger physiology_model_input_revision after insert or update of input_revision on public.physiology_work_items
  for each row execute function internal.physiology_enqueue_models();

-- Explicit operator activation is a durable, revisioned historical backfill event.
create function public.physiology_activate_model(p_payload text,p_checkpoint text) returns bigint
language plpgsql security definer set search_path='' as $$
declare p jsonb := p_payload::jsonb; model text := p->>'model_id'; revision bigint; digest text;
begin
  if coalesce(p->>'publication_mode','')<>'shadow' or coalesce(p->'canonical_outputs_allowed','null'::jsonb)<>'false'::jsonb
    then raise exception 'shadow_activation_required'; end if;
  if p_checkpoint is distinct from coalesce(p#>>'{assets,weights,sha256}',
    encode(extensions.digest(convert_to('no-checkpoint:'||model,'UTF8'),'sha256'),'hex'))
    then raise exception 'checkpoint_identity_mismatch'; end if;
  digest:=encode(extensions.digest(convert_to(p_payload,'UTF8'),'sha256'),'hex');
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('physiology-model:'||model,0));
  select a.activation_revision into revision from public.physiology_model_selection s
    join public.physiology_model_activations a using(model_id,activation_revision)
    where s.model_id=model and s.enabled and a.activation_sha256=digest and a.checkpoint_sha256=p_checkpoint;
  if found then return revision; end if;
  insert into public.physiology_model_activations(model_id,activation_payload,activation_sha256,checkpoint_sha256)
    values(model,p_payload,digest,p_checkpoint) returning activation_revision into revision;
  insert into public.physiology_model_selection(model_id,activation_revision,enabled) values(model,revision,true)
    on conflict(model_id) do update set activation_revision=excluded.activation_revision,enabled=true,changed_at=clock_timestamp();
  update public.physiology_model_work_items set state='cancelled',reason='activation_superseded',
    lease_token=null,lease_expires_at=null,finished_at=clock_timestamp()
    where model_id=model and activation_revision<>revision and state in ('pending','running','retry','waiting');
  insert into public.physiology_model_work_items(user_id,device_id,day,input_revision,timezone_id,model_id,activation_revision)
    select w.user_id,w.device_id,w.day,w.input_revision,w.timezone_id,model,revision from public.physiology_work_items w
    on conflict do nothing;
  return revision;
end $$;

create function public.physiology_claim_model(p_model text,p_activation_hash text,p_lease_seconds integer default 120)
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
    order by w.next_attempt_at,w.created_at,w.job_id for update of w skip locked limit 1;
  return query update public.physiology_model_work_items set state='running',attempts=attempts+1,
    lease_token=extensions.gen_random_uuid(),lease_expires_at=clock_timestamp()+pg_catalog.make_interval(secs=>p_lease_seconds),reason=null
    where job_id=candidate returning *;
end $$;

create function public.physiology_renew_model(p_job uuid,p_token uuid,p_seconds integer default 120) returns boolean
language plpgsql security definer set search_path='' as $$
begin
  if p_seconds not between 10 and 600 then raise exception 'model_lease_bounds'; end if;
  update public.physiology_model_work_items set lease_expires_at=clock_timestamp()+pg_catalog.make_interval(secs=>p_seconds)
    where job_id=p_job and lease_token=p_token and state='running' and lease_expires_at>clock_timestamp();
  return found;
end $$;

create function public.physiology_finish_model(p_job uuid,p_token uuid,p_output jsonb,p_failure text default null) returns boolean
language plpgsql security definer set search_path='' as $$
declare w public.physiology_model_work_items; a public.physiology_model_activations;
begin
  select * into w from public.physiology_model_work_items where job_id=p_job for update;
  if not found or w.state<>'running' or w.lease_token is distinct from p_token or w.lease_expires_at<=clock_timestamp() then return false; end if;
  if not exists(select 1 from public.physiology_model_selection where model_id=w.model_id and activation_revision=w.activation_revision and enabled)
    or not exists(select 1 from public.physiology_work_items where user_id=w.user_id and device_id=w.device_id and day=w.day and input_revision=w.input_revision)
    then return false; end if;
  if p_failure is not null then
    if p_failure='verified_model_inputs_waiting' then
      update public.physiology_model_work_items set state='waiting',reason=p_failure,lease_token=null,lease_expires_at=null,
        attempts=greatest(attempts-1,0),next_attempt_at=clock_timestamp()+interval '15 minutes' where job_id=p_job;
      return true;
    end if;
    update public.physiology_model_work_items set state=case when attempts>=4 then 'failed' else 'retry' end,
      reason=left(p_failure,500),lease_token=null,lease_expires_at=null,
      next_attempt_at=clock_timestamp()+pg_catalog.make_interval(secs=>least(3600,30*(2^attempts)::integer)),
      finished_at=case when attempts>=4 then clock_timestamp() else null end where job_id=p_job;
    return true;
  end if;
  select * into a from public.physiology_model_activations where model_id=w.model_id and activation_revision=w.activation_revision;
  if p_output is null or not coalesce(p_output->>'user_id'=w.user_id::text and p_output->>'device_id'=w.device_id::text
    and p_output->>'input_revision'=w.input_revision::text and p_output->>'model_id'=w.model_id
    and p_output->>'activation_sha256'=a.activation_sha256 and p_output->>'checkpoint_sha256'=a.checkpoint_sha256
    and p_output->>'publication_mode'='shadow' and p_output->'canonical_outputs_allowed'='false'::jsonb
    and p_output->>'status' in ('complete','abstained'),false) then raise exception 'model_output_identity_or_contract_mismatch'; end if;
  insert into public.physiology_model_results(job_id,output,output_sha256)
    values(p_job,p_output,encode(extensions.digest(convert_to(p_output::text,'UTF8'),'sha256'),'hex'));
  update public.physiology_model_work_items set state=case when p_output->>'status'='complete' then 'complete' else 'abstained' end,
    reason=left(p_output->>'reason',500),lease_token=null,lease_expires_at=null,finished_at=clock_timestamp() where job_id=p_job;
  return true;
end $$;

create function public.physiology_cancel_model(p_model text,p_activation bigint) returns integer
language plpgsql security definer set search_path='' as $$
declare affected integer;
begin
  update public.physiology_model_selection set enabled=false,changed_at=clock_timestamp()
    where model_id=p_model and activation_revision=p_activation;
  update public.physiology_model_work_items set state='cancelled',reason='operator_cancelled',lease_token=null,
    lease_expires_at=null,finished_at=clock_timestamp() where model_id=p_model and activation_revision=p_activation and state in ('pending','running','retry','waiting');
  get diagnostics affected=row_count;
  return affected;
end $$;

create function public.physiology_shadow_model_for_day(p_model text,p_day date,p_device uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare owner uuid := auth.uid(); result jsonb;
begin
  if owner is null or not exists(select 1 from public.devices where id=p_device and user_id=owner)
    then raise exception 'owned_device_required' using errcode='42501'; end if;
  select jsonb_build_object('schema_version',1,'publication_mode','shadow','canonical_outputs_allowed',false,
    'user_id',owner,'device_id',p_device,'day',p_day,'model_id',w.model_id,'status',w.state,'reason',w.reason,
    'input_revision',w.input_revision::text,'activation_revision',w.activation_revision,
    'activation_sha256',a.activation_sha256,'checkpoint_sha256',a.checkpoint_sha256,'output',r.output)
    into result from public.physiology_model_work_items w
    join public.physiology_model_selection s on s.model_id=w.model_id and s.activation_revision=w.activation_revision and s.enabled
    join public.physiology_model_activations a on a.model_id=w.model_id and a.activation_revision=w.activation_revision
    join public.physiology_work_items i on i.user_id=w.user_id and i.device_id=w.device_id and i.day=w.day and i.input_revision=w.input_revision
    left join public.physiology_model_results r on r.job_id=w.job_id
    where w.user_id=owner and w.device_id=p_device and w.day=p_day and w.model_id=p_model;
  return coalesce(result,jsonb_build_object('schema_version',1,'publication_mode','shadow','canonical_outputs_allowed',false,
    'user_id',owner,'device_id',p_device,'day',p_day,'model_id',p_model,'status','unavailable','reason','no_current_shadow_job','output',null));
end $$;
revoke all on function public.physiology_shadow_model_for_day(text,date,uuid) from public,anon;
grant execute on function public.physiology_shadow_model_for_day(text,date,uuid) to authenticated,service_role;

create table public.physiology_model_acquisition_contracts (
  user_id uuid not null,
  device_id uuid not null,
  input_revision bigint not null check (input_revision>0),
  model_id text not null,
  checkpoint_sha256 text not null check (checkpoint_sha256 ~ '^[0-9a-f]{64}$'),
  preprocess_version text not null,
  quality_policy_version text not null,
  scope_start_s bigint not null,
  scope_end_s bigint not null check (scope_end_s>scope_start_s and scope_end_s-scope_start_s<=273600),
  contract_sha256 text not null check (contract_sha256 ~ '^[0-9a-f]{64}$'),
  contract_bytes bytea not null check (octet_length(contract_bytes) between 1 and 33554432),
  created_at timestamptz not null default clock_timestamp(),
  primary key(user_id,device_id,input_revision,model_id,checkpoint_sha256,preprocess_version,quality_policy_version,scope_start_s,scope_end_s),
  foreign key(user_id,device_id) references public.devices(user_id,id) on delete cascade,
  check (contract_sha256=encode(extensions.digest(contract_bytes,'sha256'),'hex'))
);
alter table public.physiology_model_acquisition_contracts enable row level security;
revoke all on public.physiology_model_acquisition_contracts from public,anon,authenticated,service_role;
grant select,insert on public.physiology_model_acquisition_contracts to service_role;
create trigger physiology_model_contract_immutable before update on public.physiology_model_acquisition_contracts
  for each row execute function internal.physiology_immutable_release();
-- Ordinary deletion is denied by privileges. Device/account erasure retains its existing cascade.
create function internal.physiology_wake_model_contract() returns trigger language plpgsql security definer set search_path='' as $$
begin
  update public.physiology_model_work_items w set next_attempt_at=clock_timestamp()
    from public.physiology_model_activations a where w.model_id=a.model_id and w.activation_revision=a.activation_revision
      and w.user_id=new.user_id and w.device_id=new.device_id and w.input_revision=new.input_revision
      and w.model_id=new.model_id and a.checkpoint_sha256=new.checkpoint_sha256 and w.state='waiting';
  return new;
end $$;
create trigger physiology_model_contract_arrival after insert on public.physiology_model_acquisition_contracts
  for each row execute function internal.physiology_wake_model_contract();
revoke all on function internal.physiology_wake_model_contract() from public,anon,authenticated,service_role;
revoke all on function internal.physiology_enqueue_models() from public,anon,authenticated,service_role;
revoke all on function public.physiology_activate_model(text,text),public.physiology_claim_model(text,text,integer),
  public.physiology_renew_model(uuid,uuid,integer),public.physiology_finish_model(uuid,uuid,jsonb,text),
  public.physiology_cancel_model(text,bigint) from public,anon,authenticated;
grant execute on function public.physiology_activate_model(text,text),public.physiology_claim_model(text,text,integer),
  public.physiology_renew_model(uuid,uuid,integer),public.physiology_finish_model(uuid,uuid,jsonb,text),
  public.physiology_cancel_model(text,bigint) to service_role;
commit;
