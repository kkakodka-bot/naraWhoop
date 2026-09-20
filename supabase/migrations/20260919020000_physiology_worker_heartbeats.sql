-- A global algorithm-family heartbeat cannot attribute progress to a deployed process.
-- The operator supplies a fresh worker/deployment UUID; each JVM boot creates another UUID.
begin;

create table public.physiology_worker_heartbeats (
    worker_instance_id uuid not null check (worker_instance_id <> '00000000-0000-0000-0000-000000000000'),
    process_instance_id uuid not null unique check (process_instance_id <> '00000000-0000-0000-0000-000000000000'),
    source_revision text not null check (source_revision ~ '^[0-9a-f]{40}$'),
    algorithm_version text not null check (algorithm_version ~ '^[a-zA-Z0-9._-]{1,100}$'),
    started_at timestamptz not null default clock_timestamp(),
    last_poll_at timestamptz,
    last_score_at timestamptz,
    last_error text check (last_error ~ '^[A-Za-z][A-Za-z0-9_.:-]{0,127}$'),
    primary key (worker_instance_id, process_instance_id),
    check (last_poll_at is null or last_poll_at >= started_at),
    check (last_score_at is null or last_score_at >= started_at)
);

create function internal.enforce_physiology_worker_identity() returns trigger
language plpgsql set search_path=pg_catalog as $$
begin
    if (new.worker_instance_id,new.process_instance_id,new.source_revision,new.algorithm_version,new.started_at)
       is distinct from
       (old.worker_instance_id,old.process_instance_id,old.source_revision,old.algorithm_version,old.started_at) then
        raise exception 'physiology worker identity is immutable' using errcode='23514';
    end if;
    return new;
end;
$$;
revoke all on function internal.enforce_physiology_worker_identity() from public,anon,authenticated;
create trigger physiology_worker_identity_immutable before update on public.physiology_worker_heartbeats
for each row execute function internal.enforce_physiology_worker_identity();

alter table public.physiology_worker_heartbeats enable row level security;
revoke all on public.physiology_worker_heartbeats from public,anon,authenticated,service_role;
grant select,insert on public.physiology_worker_heartbeats to service_role;
grant update(last_poll_at,last_score_at,last_error) on public.physiology_worker_heartbeats to service_role;
create policy physiology_worker_heartbeats_service on public.physiology_worker_heartbeats
    for all to service_role using(true) with check(true);

comment on table public.physiology_worker_heartbeats is
    'Operator-only process liveness, not physiological validity. No owner, device, input, payload or credentials.';
commit;
