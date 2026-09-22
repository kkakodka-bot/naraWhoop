-- Opt-in completion debt. This does not change the verified_indexed receipt or default sender path.
create table public.noop_object_verification_debt (
  object_id uuid primary key references public.object_manifests(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  state text not null default 'pending' check(state in ('pending','leased','retry','paused_terminal','complete')),
  requested_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  next_attempt_at timestamptz not null default now(),
  lease_token uuid,
  lease_until timestamptz,
  attempts integer not null default 0,
  retry_attempts integer not null default 0,
  lease_recoveries integer not null default 0,
  failures integer not null default 0,
  failure_code text,
  failure_status integer,
  verification_ms integer check(verification_ms >= 0),
  completed_at timestamptz,
  receipt_indexed_at timestamptz,
  resolution_count integer not null default 0
);
create index noop_object_verification_due on public.noop_object_verification_debt(next_attempt_at,requested_at,object_id)
  where state in ('pending','retry','leased');
alter table public.noop_object_verification_debt enable row level security;
revoke all on public.noop_object_verification_debt from public,anon,authenticated;
grant all on public.noop_object_verification_debt to service_role;
create policy noop_object_verification_service on public.noop_object_verification_debt
  for all to service_role using(true) with check(true);

-- Reserve under the same manifest lock as opt-in enqueue. A synchronous request admitted
-- before opt-in may finish, but a later mode downgrade cannot start another COPY. The old
-- implementation remains private so there is one public reservation entry point.
alter function public.noop_reserve_copy_intent(uuid,uuid) rename to noop_reserve_copy_intent_unfenced;
revoke all on function public.noop_reserve_copy_intent_unfenced(uuid,uuid) from public,anon,authenticated,service_role;
create function public.noop_reserve_copy_intent(p_user_id uuid,p_object_id uuid,p_verification_token uuid default null)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare m public.object_manifests; d public.noop_object_verification_debt;
begin
  select * into m from public.object_manifests where id=p_object_id for update;
  if not found or m.user_id is distinct from p_user_id then raise exception 'object_owner_conflict'; end if;
  select * into d from public.noop_object_verification_debt where object_id=m.id;
  if found then
    if p_verification_token is null then raise exception 'async_verification_required'; end if;
    if d.state <> 'leased' or d.lease_token is distinct from p_verification_token or d.lease_until<=now()
      then raise exception 'verification_lease_lost'; end if;
  elsif p_verification_token is not null then raise exception 'verification_lease_lost'; end if;
  return public.noop_reserve_copy_intent_unfenced(p_user_id,p_object_id);
end;
$$;

-- Private structural predicate. It returns a boolean, never an unindexed receipt that a
-- caller could mistake for source-release authority. Invalid persisted fields fail closed.
create function public.noop_object_receipt_matches_manifest(m public.object_manifests)
returns boolean language plpgsql stable set search_path=pg_catalog,public as $$
declare r jsonb := m.durability_receipt; field text; verified timestamptz; indexed timestamptz;
begin
  if jsonb_typeof(r) is distinct from 'object' then return false; end if;
  foreach field in array array['state','receiptId','ownerUserId','deviceId','objectId','batchId','sourceId',
    'stream','objectKey','contentSha256','wireSha256','verifiedAt','indexedAt'] loop
    if jsonb_typeof(r->field) is distinct from 'string' then return false; end if;
  end loop;
  foreach field in array array['version','schemaVersion','compressedBytes','uncompressedBytes'] loop
    if jsonb_typeof(r->field) is distinct from 'number' then return false; end if;
  end loop;
  foreach field in array array['receiptId','ownerUserId','deviceId','objectId','batchId','sourceId'] loop
    if r->>field !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return false; end if;
  end loop;
  if r->>'version' <> '1' or r->>'state' <> 'verified_indexed'
    or coalesce(m.schema_version,1)<=0 or r->>'schemaVersion' is distinct from coalesce(m.schema_version,1)::text
    or r->>'ownerUserId' is distinct from m.user_id::text or r->>'deviceId' is distinct from m.device_id::text
    or r->>'objectId' is distinct from m.id::text or r->>'objectKey' is distinct from m.object_key
    or r->>'batchId' is distinct from m.batch_id::text or r->>'sourceId' is distinct from m.source_id::text
    or r->>'stream' is distinct from m.object_kind or r->>'stream'=''
    or length(r->>'objectKey') not between 1 and 1024 or r->>'objectKey' ~ '[[:space:]]'
    or r->>'wireSha256' !~ '^[0-9a-f]{64}$' or r->>'contentSha256' !~ '^[0-9a-f]{64}$'
    or r->>'wireSha256' is distinct from m.wire_sha256
    or r->>'compressedBytes' !~ '^[1-9][0-9]*$' or r->>'uncompressedBytes' !~ '^[1-9][0-9]*$'
    or r->>'compressedBytes' is distinct from m.compressed_bytes::text
    or (m.uncompressed_bytes is not null and r->>'uncompressedBytes' is distinct from m.uncompressed_bytes::text)
    or (case when m.digest_scope='wire' then r->>'wireSha256' else r->>'contentSha256' end) is distinct from lower(m.sha256)
    then return false; end if;
  foreach field in array array['verifiedAt','indexedAt'] loop
    if r->>field !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$'
      then return false; end if;
  end loop;
  begin
    verified := (r->>'verifiedAt')::timestamptz; indexed := (r->>'indexedAt')::timestamptz;
  exception when invalid_datetime_format or datetime_field_overflow then return false;
  end;
  return verified>to_timestamp(0) and indexed>=verified;
end;
$$;

-- Read-only proof for polling: return the original receipt only when its owner, immutable key,
-- manifest identity/digests/sizes and exact committed range/count index agree. Never invent one.
create function public.noop_current_object_receipt(p_user_id uuid,p_object_id uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare m public.object_manifests; r jsonb;
begin
  select * into m from public.object_manifests where id=p_object_id and user_id=p_user_id;
  if not found or m.status not in ('ready','verified') or m.sha256_source is distinct from 'server_verified'
    or m.indexed_at is null or not exists(select 1 from public.devices where id=m.device_id and user_id=p_user_id)
    or not public.noop_object_receipt_matches_manifest(m) then return null; end if;
  r := m.durability_receipt;
  if not exists(select 1 from public.noop_signal_windows w where w.object_id=m.id and w.user_id=m.user_id
      and w.device_id=m.device_id and w.stream=m.object_kind and w.object_key=m.object_key
      and w.compressed_bytes=m.compressed_bytes and w.uncompressed_bytes::text=r->>'uncompressedBytes'
      and w.start_ts=floor(extract(epoch from m.start_at))
      and w.end_ts=greatest(floor(extract(epoch from m.start_at))+1,ceil(extract(epoch from m.end_at)))
      and w.received_records=coalesce(m.sample_count,0)) then return null; end if;
  return r;
end;
$$;

-- Lock order is manifest -> debt. Claims/settlements lock only debt; their manifest reads are MVCC.
-- No database lock is held across object I/O. Repeated completion never resets a lease or backoff.
create function public.noop_enqueue_object_verification(p_user_id uuid,p_object_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare m public.object_manifests; d public.noop_object_verification_debt; r jsonb;
begin
  select * into m from public.object_manifests where id=p_object_id for update;
  if not found then raise exception 'missing_manifest'; end if;
  if m.user_id is distinct from p_user_id or not exists(select 1 from public.devices where id=m.device_id and user_id=p_user_id)
    then raise exception 'object_owner_conflict' using errcode='42501'; end if;
  if m.object_class <> 'raw' or m.status in ('deleted','deleting','expired') then raise exception 'object_unavailable'; end if;
  r := public.noop_current_object_receipt(p_user_id,p_object_id);
  if r is not null then
    update public.noop_object_verification_debt set state='complete',completed_at=coalesce(completed_at,now()),
      receipt_indexed_at=(r->>'indexedAt')::timestamptz,updated_at=now(),lease_until=null where object_id=m.id and state <> 'complete';
    return jsonb_build_object('state','complete','receipt',r,'protocolVersion',m.push_protocol_version,'objectId',m.id);
  end if;
  insert into public.noop_object_verification_debt(object_id,user_id) values(m.id,m.user_id) on conflict do nothing;
  if m.durability_receipt is not null and not public.noop_object_receipt_matches_manifest(m) then
    update public.noop_object_verification_debt set state='paused_terminal',failure_code='receipt_mismatch',failure_status=409,
      lease_until=null,updated_at=now() where object_id=m.id and (state <> 'paused_terminal' or failure_code is distinct from 'receipt_mismatch');
  end if;
  -- Missing index/receipt after prior completion is repair debt, never cached success.
  update public.noop_object_verification_debt set state='pending',next_attempt_at=now(),updated_at=now(),
    lease_token=null,lease_until=null,completed_at=null,receipt_indexed_at=null where object_id=m.id and state='complete';
  select * into d from public.noop_object_verification_debt where object_id=m.id;
  return jsonb_build_object('state',d.state,'protocolVersion',m.push_protocol_version,'objectId',m.id,
    'code',d.failure_code,'failureStatus',d.failure_status,
    'retryAfter',greatest(15,least(3600,ceil(extract(epoch from d.next_attempt_at-now()))::integer)));
end;
$$;

-- Claim one object at a time, under the caller's remaining declared byte budgets. SKIP LOCKED
-- prevents overlapping worker invocations from sharing a live lease. Expired claims are recoverable.
create function public.noop_claim_object_verification(p_max_bytes bigint default 268435456,p_max_decoded_bytes bigint default 536870912)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare d public.noop_object_verification_debt; m public.object_manifests; token uuid := gen_random_uuid();
begin
  select v.* into d from public.noop_object_verification_debt v join public.object_manifests o on o.id=v.object_id
    where v.state in ('pending','retry','leased') and v.next_attempt_at<=now()
      and (v.state <> 'leased' or v.lease_until<=now()) and o.user_id=v.user_id
      and o.status not in ('deleted','deleting','expired')
      and o.compressed_bytes>0 and o.compressed_bytes<=least(greatest(p_max_bytes,0),268435456)
      and coalesce(o.uncompressed_bytes,536870912)<=least(greatest(p_max_decoded_bytes,0),536870912)
      and not exists(select 1 from public.noop_object_copy_intents c where c.object_id=o.id
        and c.state='copying' and c.lease_until>now())
    order by v.next_attempt_at,v.requested_at,v.object_id for update of v skip locked limit 1;
  if not found then return null; end if;
  select * into m from public.object_manifests where id=d.object_id and user_id=d.user_id;
  if not found then return null; end if;
  update public.noop_object_verification_debt set state='leased',lease_token=token,
    lease_until=now()+interval '10 minutes',attempts=attempts+1,
    retry_attempts=retry_attempts+case when d.state='retry' then 1 else 0 end,
    lease_recoveries=lease_recoveries+case when d.state='leased' then 1 else 0 end,
    updated_at=now() where object_id=d.object_id;
  return jsonb_build_object('objectId',d.object_id,'token',token,'manifest',to_jsonb(m));
end;
$$;

create function public.noop_finish_object_verification(p_object_id uuid,p_lease_token uuid,p_failure_code text default null,
  p_failure_status integer default 503,p_retryable boolean default true,p_verification_ms integer default 0)
returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$
declare d public.noop_object_verification_debt; r jsonb; code text;
begin
  select * into d from public.noop_object_verification_debt where object_id=p_object_id for update;
  if not found or d.lease_token is distinct from p_lease_token then return false; end if;
  if d.state='complete' then return true; end if;
  if d.state <> 'leased' or d.lease_until<=now() then return false; end if;
  r := public.noop_current_object_receipt(d.user_id,d.object_id);
  if r is not null then
    update public.noop_object_verification_debt set state='complete',completed_at=now(),updated_at=now(),lease_until=null,
      receipt_indexed_at=(r->>'indexedAt')::timestamptz,failure_code=null,failure_status=null,
      verification_ms=greatest(0,p_verification_ms) where object_id=d.object_id;
  else
    code := case when p_failure_code in ('object_missing','size_mismatch','decoded_size_mismatch','digest_mismatch',
      'invalid_compressed_object','unsupported_compression','invalid_object_size','object_unavailable','device_owner_conflict',
      'copy_attempt_limit','verification_failed','receipt_failed','receipt_mismatch','invalid_auxiliary_identity') then p_failure_code else 'verification_failed' end;
    update public.noop_object_verification_debt set state=case when p_retryable then 'retry' else 'paused_terminal' end,
      failures=failures+1,failure_code=code,failure_status=case when p_failure_status between 400 and 599 then p_failure_status else 503 end,
      next_attempt_at=now()+make_interval(secs=>greatest(1,random()*least(3600,5*power(2,least(d.failures+1,10))))),
      lease_until=null,updated_at=now(),verification_ms=greatest(0,p_verification_ms) where object_id=d.object_id;
  end if;
  return true;
end;
$$;

-- A claim can outlast its caller's admission window. Release it without a failure increment
-- before beginning storage work; an old caller cannot release a successor's lease.
create function public.noop_defer_object_verification(p_object_id uuid,p_lease_token uuid)
returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  update public.noop_object_verification_debt set state='pending',lease_until=null,updated_at=now()
    where object_id=p_object_id and lease_token=p_lease_token and state='leased' and lease_until>now();
  return found;
end;
$$;

-- Explicit operator/compatible-upgrade resolution only. Polling and ordinary worker retries
-- cannot unpause a terminal selection; source objects and receipts are retained.
create function public.noop_retry_object_verification(p_user_id uuid,p_object_id uuid)
returns boolean language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if not exists(select 1 from public.object_manifests m join public.devices d on d.id=m.device_id and d.user_id=m.user_id
    where m.id=p_object_id and m.user_id=p_user_id and m.status not in ('deleted','deleting','expired')) then return false; end if;
  update public.noop_object_verification_debt set state='pending',next_attempt_at=now(),lease_token=null,lease_until=null,
    updated_at=now(),resolution_count=resolution_count+1 where object_id=p_object_id and user_id=p_user_id and state='paused_terminal';
  return found;
end;
$$;

-- Keep the existing fleet cursor for legacy repair, excluding opt-in debt even when paused.
create or replace function public.noop_intake_reconcile_page(p_limit integer default 16)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare v_cursor uuid; v_rows jsonb; v_last uuid;
begin
  select cursor_id into v_cursor from public.noop_intake_reconcile_state where id for update;
  select jsonb_agg(to_jsonb(x) order by x.id),max(x.id::text)::uuid into v_rows,v_last from (
    select * from public.object_manifests m where object_class='raw'
      and status not in ('deleted','deleting','expired') and sha256 is not null
      and not exists(select 1 from public.noop_object_verification_debt v where v.object_id=m.id)
      and (durability_receipt is null or indexed_at is null or status not in ('ready','verified')
        or not exists(select 1 from public.noop_signal_windows w where w.object_id=m.id and w.user_id=m.user_id
          and w.device_id=m.device_id and w.object_key=m.object_key))
      and (v_cursor is null or id>v_cursor) order by id limit greatest(1,least(p_limit,64))
  ) x;
  update public.noop_intake_reconcile_state set cursor_id=v_last,updated_at=now() where id;
  return coalesce(v_rows,'[]'::jsonb);
end;
$$;

create view public.noop_object_verification_metrics as select
  count(*) filter(where state in ('pending','retry','leased')) as queue_depth,
  min(requested_at) filter(where state in ('pending','retry','leased')) as oldest_debt_at,
  count(*) filter(where state='paused_terminal') as paused_count,
  count(*) filter(where state='leased' and lease_until>now()) as active_leases,
  count(*) filter(where state='leased' and lease_until<=now()) as expired_leases,
  coalesce(sum(retry_attempts),0) as retries,
  coalesce(sum(failures),0) as failures,
  coalesce(sum(lease_recoveries),0) as lease_recoveries,
  avg(verification_ms) filter(where state='complete') as verification_ms_avg,
  max(verification_ms) filter(where state='complete') as verification_ms_max,
  avg(greatest(0,extract(epoch from receipt_indexed_at-requested_at)*1000)) filter(where state='complete') as receipt_latency_ms_avg,
  max(greatest(0,extract(epoch from receipt_indexed_at-requested_at)*1000)) filter(where state='complete') as receipt_latency_ms_max
  from public.noop_object_verification_debt;
revoke all on public.noop_object_verification_metrics from public,anon,authenticated;
grant select on public.noop_object_verification_metrics to service_role;
revoke all on function public.noop_current_object_receipt(uuid,uuid) from public,anon,authenticated;
revoke all on function public.noop_enqueue_object_verification(uuid,uuid) from public,anon,authenticated;
revoke all on function public.noop_claim_object_verification(bigint,bigint) from public,anon,authenticated;
revoke all on function public.noop_finish_object_verification(uuid,uuid,text,integer,boolean,integer) from public,anon,authenticated;
revoke all on function public.noop_retry_object_verification(uuid,uuid) from public,anon,authenticated;
revoke all on function public.noop_defer_object_verification(uuid,uuid) from public,anon,authenticated;
revoke all on function public.noop_reserve_copy_intent(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.noop_current_object_receipt(uuid,uuid) to service_role;
grant execute on function public.noop_enqueue_object_verification(uuid,uuid) to service_role;
grant execute on function public.noop_claim_object_verification(bigint,bigint) to service_role;
grant execute on function public.noop_finish_object_verification(uuid,uuid,text,integer,boolean,integer) to service_role;
grant execute on function public.noop_retry_object_verification(uuid,uuid) to service_role;
grant execute on function public.noop_defer_object_verification(uuid,uuid) to service_role;
grant execute on function public.noop_reserve_copy_intent(uuid,uuid,uuid) to service_role;

revoke all on function public.noop_object_receipt_matches_manifest(public.object_manifests) from public,anon,authenticated,service_role;
