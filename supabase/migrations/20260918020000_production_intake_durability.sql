-- Additive intake repair. No ownership reassignment or historical data deletion.
alter table public.object_manifests
  add column if not exists upload_object_key text,
  add column if not exists push_protocol_version text,
  add column if not exists digest_scope text,
  add column if not exists wire_sha256 text,
  add column if not exists indexed_at timestamptz,
  add column if not exists durability_receipt jsonb;

-- Explicit grants: do not depend on a project's historical default privileges.
revoke all on public.noop_signal_windows from anon, authenticated;
grant select on public.noop_signal_windows to authenticated;
grant all on public.noop_signal_windows to service_role;
create index if not exists noop_signal_windows_object_lookup_idx on public.noop_signal_windows(object_id);

create table if not exists public.noop_push_reservations (
  user_id uuid not null references auth.users(id) on delete cascade,
  batch_id uuid not null,
  device_id uuid not null references public.devices(id) on delete cascade,
  body_sha256 text not null check (body_sha256 ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now(),
  primary key (user_id, batch_id)
);
alter table public.noop_push_reservations enable row level security;
revoke all on public.noop_push_reservations from anon, authenticated;
grant select on public.noop_push_reservations to authenticated;
grant all on public.noop_push_reservations to service_role;
create policy noop_push_reservations_owner_read on public.noop_push_reservations
  for select to authenticated using ((select auth.uid()) = user_id);
create policy noop_push_reservations_service on public.noop_push_reservations
  for all to service_role using (true) with check (true);

create or replace function public.noop_keep_device_owner() returns trigger
language plpgsql set search_path = pg_catalog, public as $$
begin
  if new.id is distinct from old.id or new.user_id is distinct from old.user_id then
    raise exception 'device_owner_immutable' using errcode = '23514';
  end if;
  return new;
end;
$$;
create trigger noop_device_owner_immutable before update on public.devices
  for each row execute function public.noop_keep_device_owner();

-- Called only after Edge validates the user's credential. Existing UUIDs are never adopted.
create or replace function public.noop_register_push_device(
  p_user_id uuid, p_device_id uuid, p_external_device_id text
) returns uuid language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_owner uuid;
begin
  if p_user_id is null or p_device_id is null or nullif(p_external_device_id, '') is null then
    raise exception 'invalid_device_registration' using errcode = '22023';
  end if;
  insert into public.devices (id, user_id, source_kind, external_device_id, last_seen_at)
    values (p_device_id, p_user_id, 'noop_push', p_external_device_id, now())
    on conflict (id) do nothing;
  select user_id into v_owner from public.devices where id = p_device_id for update;
  if v_owner is distinct from p_user_id then
    raise exception 'device_owner_conflict' using errcode = '42501';
  end if;
  update public.devices set last_seen_at = now() where id = p_device_id;
  return p_device_id;
end;
$$;

create or replace function public.noop_reserve_push_batch(
  p_user_id uuid, p_batch_id uuid, p_device_id uuid, p_body_sha256 text, p_entry jsonb
) returns timestamptz language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_hash text; v_device uuid; v_created timestamptz;
begin
  if not exists (select 1 from public.devices where id = p_device_id and user_id = p_user_id) then
    raise exception 'device_owner_conflict' using errcode = '42501';
  end if;
  insert into public.noop_push_reservations(user_id, batch_id, device_id, body_sha256)
    values (p_user_id, p_batch_id, p_device_id, p_body_sha256)
    on conflict (user_id, batch_id) do nothing;
  select body_sha256, device_id, created_at into v_hash, v_device, v_created from public.noop_push_reservations
    where user_id = p_user_id and batch_id = p_batch_id for update;
  if v_hash is distinct from p_body_sha256 or v_device is distinct from p_device_id
     or exists (select 1 from public.noop_push_wal where user_id = p_user_id
                and batch_id = p_batch_id and body_sha256 <> p_body_sha256)
     or exists (select 1 from public.noop_push_acks where user_id = p_user_id
                and batch_id = p_batch_id and body_sha256 <> p_body_sha256) then
    raise exception 'batch_id_conflict' using errcode = '23505';
  end if;
  insert into public.noop_push_wal
    (user_id, batch_id, stream, device_id, source_id, record_count, body_sha256, received_at)
    values (p_user_id, p_batch_id, p_entry->>'stream', p_entry->>'deviceId',
            (p_entry->>'sourceId')::uuid, (p_entry->>'recordCount')::integer,
            p_body_sha256, now()) on conflict (user_id, batch_id) do nothing;
  return v_created;
end;
$$;

create or replace function public.noop_reserve_object_manifest(p_manifest jsonb)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare v public.object_manifests; p public.object_manifests;
begin
  p := jsonb_populate_record(null::public.object_manifests, p_manifest);
  if not exists (select 1 from public.devices where id = p.device_id and user_id = p.user_id) then
    raise exception 'device_owner_conflict' using errcode = '42501';
  end if;
  if p.object_class is distinct from 'raw' or coalesce(p.sha256,'') !~ '^[0-9a-f]{64}$'
     or coalesce(p.digest_scope,'') not in ('decoded', 'wire')
     or p.batch_id is null or p.source_id is null
     or coalesce(p.schema_version,0) not in (1,2)
     or coalesce(p.compressed_bytes,0) <= 0 or p.compressed_bytes > 268435456
     or coalesce(p.uncompressed_bytes,0) <= 0 or p.uncompressed_bytes > 536870912 then
    raise exception 'invalid_object_manifest' using errcode = '22023';
  end if;
  insert into public.object_manifests
    (id,user_id,device_id,object_class,object_kind,provider,bucket,object_key,upload_object_key,
     start_at,end_at,period_day,sample_count,compressed_bytes,uncompressed_bytes,content_type,
     format,compression,schema_version,push_protocol_version,sha256,sha256_source,digest_scope,retention_class,
     expires_at,batch_id,source_id,status)
  values
    (p.id,p.user_id,p.device_id,'raw',p.object_kind,p.provider,p.bucket,p.object_key,p.object_key,
     p.start_at,p.end_at,p.period_day,p.sample_count,p.compressed_bytes,p.uncompressed_bytes,p.content_type,
     p.format,p.compression,p.schema_version,p.push_protocol_version,p.sha256,'client_claimed',p.digest_scope,p.retention_class,
     p.expires_at,p.batch_id,p.source_id,'pending') on conflict (id) do nothing;
  select * into v from public.object_manifests where id = p.id for update;
  if v.user_id is distinct from p.user_id or v.device_id is distinct from p.device_id then
    raise exception 'object_owner_conflict' using errcode = '42501';
  end if;
  if v.object_class <> 'raw' or v.object_kind is distinct from p.object_kind
     or lower(v.sha256) is distinct from lower(p.sha256)
     or v.compressed_bytes is distinct from p.compressed_bytes
     or (v.uncompressed_bytes is not null and v.uncompressed_bytes is distinct from p.uncompressed_bytes)
     or coalesce(v.digest_scope, case when v.format like 'ndjson%' then 'wire' else 'decoded' end) is distinct from p.digest_scope
     or v.compression is distinct from p.compression
     or coalesce(v.schema_version,1) <> coalesce(p.schema_version,1)
     or (v.push_protocol_version is not null and v.push_protocol_version is distinct from p.push_protocol_version)
     or v.start_at is distinct from p.start_at or v.end_at is distinct from p.end_at
     or v.sample_count is distinct from p.sample_count
     or (v.batch_id is not null and v.batch_id is distinct from p.batch_id)
     or (v.source_id is not null and v.source_id is distinct from p.source_id) then
    raise exception 'object_id_conflict' using errcode = '23505';
  end if;
  -- Legacy rows did not store all immutable fields. Bind them once only after matching their
  -- pre-existing identity/digest. This is a repair, never a new digest under an old id.
  if v.uncompressed_bytes is null or v.batch_id is null or v.source_id is null
     or v.push_protocol_version is null or v.digest_scope is null or v.upload_object_key is null then
    update public.object_manifests set
      uncompressed_bytes=coalesce(uncompressed_bytes,p.uncompressed_bytes),
      batch_id=coalesce(batch_id,p.batch_id),source_id=coalesce(source_id,p.source_id),
      push_protocol_version=coalesce(push_protocol_version,p.push_protocol_version),
      digest_scope=coalesce(digest_scope,p.digest_scope),upload_object_key=coalesce(upload_object_key,object_key)
      where id=v.id returning * into v;
  end if;
  return to_jsonb(v);
end;
$$;

-- Verification is performed by the receiver against stored bytes. Publication and indexing
-- happen in this transaction; an index error rolls back the ready state and the receipt.
create or replace function public.noop_commit_object_receipt(
  p_user_id uuid, p_object_id uuid, p_verified_key text, p_wire_sha256 text,
  p_content_sha256 text, p_compressed_bytes bigint, p_uncompressed_bytes bigint
) returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare
  v public.object_manifests; v_receipt jsonb; v_scope text;
  v_start bigint; v_end bigint; v_expected bigint; v_key text; v_index_changes integer; v_now timestamptz := now();
begin
  select * into v from public.object_manifests where id = p_object_id for update;
  if not found or v.user_id is distinct from p_user_id or not exists
    (select 1 from public.devices where id = v.device_id and user_id = p_user_id) then
    raise exception 'object_owner_conflict' using errcode = '42501';
  end if;
  v_scope := coalesce(v.digest_scope, case when v.format like 'ndjson%' then 'wire' else 'decoded' end);
  if v.object_class <> 'raw' or v.status in ('deleted','deleting','expired')
     or coalesce(p_wire_sha256,'') !~ '^[0-9a-f]{64}$'
     or coalesce(p_content_sha256,'') !~ '^[0-9a-f]{64}$'
     or p_compressed_bytes is distinct from v.compressed_bytes
     or coalesce(p_uncompressed_bytes,0) <= 0 or p_uncompressed_bytes > 536870912
     or (v.uncompressed_bytes is not null and p_uncompressed_bytes <> v.uncompressed_bytes)
     or lower(v.sha256) is distinct from
       (case when v_scope = 'wire' then p_wire_sha256 else p_content_sha256 end)
     or coalesce(p_verified_key,'') not like ('%/users/' || v.user_id::text || '/%/verified/' || v.id::text || '/%') then
    raise exception 'object_verification_mismatch' using errcode = '23514';
  end if;
  if v.durability_receipt is not null and (
       v.durability_receipt->>'wireSha256' is distinct from p_wire_sha256
       or v.durability_receipt->>'contentSha256' is distinct from p_content_sha256) then
    raise exception 'receipt_immutable' using errcode = '23514';
  end if;
  -- A concurrent identical verifier may already have published another immutable snapshot.
  v_key := coalesce(v.durability_receipt->>'objectKey',p_verified_key);
  v_start := floor(extract(epoch from v.start_at));
  v_end := greatest(v_start + 1, ceil(extract(epoch from v.end_at)));
  if v_start is null or v_end is null then
    raise exception 'object_window_missing' using errcode = '23514';
  end if;
  v_expected := case when v.object_kind in ('ppgWaveformSample','v18AuxSample','rawImuSession')
    then v_end - v_start else null end;
  insert into public.noop_signal_windows
    (user_id,device_id,stream,hour_start,object_id,object_key,start_ts,end_ts,expected_records,
     received_records,missing_records,coverage,interpolated_records,compressed_bytes,uncompressed_bytes)
  values (v.user_id,v.device_id,v.object_kind,(v_start / 3600)*3600,v.id,v_key,v_start,v_end,
    v_expected,coalesce(v.sample_count,0),case when v_expected is not null then greatest(v_expected-v.sample_count,0) end,
    case when v_expected > 0 then least(1.0,v.sample_count::double precision/v_expected) else null end,
    0,p_compressed_bytes,p_uncompressed_bytes)
  on conflict (user_id,device_id,stream,hour_start,object_id) do update set
    object_key=excluded.object_key, compressed_bytes=excluded.compressed_bytes,
    uncompressed_bytes=excluded.uncompressed_bytes, updated_at=v_now
    where public.noop_signal_windows.object_key is distinct from excluded.object_key
       or public.noop_signal_windows.compressed_bytes is distinct from excluded.compressed_bytes
       or public.noop_signal_windows.uncompressed_bytes is distinct from excluded.uncompressed_bytes;
  get diagnostics v_index_changes = row_count;
  v_receipt := coalesce(v.durability_receipt, jsonb_build_object(
    'version',1,'state','verified_indexed','receiptId',gen_random_uuid(),
    'ownerUserId',v.user_id,'deviceId',v.device_id,'objectId',v.id,
    'batchId',v.batch_id,'sourceId',v.source_id,'stream',v.object_kind,
    'schemaVersion',coalesce(v.schema_version,1),'objectKey',v_key,
    'contentSha256',p_content_sha256,'wireSha256',p_wire_sha256,
    'compressedBytes',p_compressed_bytes,'uncompressedBytes',p_uncompressed_bytes,
    'verifiedAt',v_now,'indexedAt',v_now));
  -- A legacy repair may precede the original intent retry. Fill unknown provenance once;
  -- already-bound provenance is compared by reservation and is never reassigned.
  if v_receipt->>'batchId' is null and v.batch_id is not null then
    v_receipt := v_receipt || jsonb_build_object('batchId',v.batch_id);
  end if;
  if v_receipt->>'sourceId' is null and v.source_id is not null then
    v_receipt := v_receipt || jsonb_build_object('sourceId',v.source_id);
  end if;
  update public.object_manifests set
    upload_object_key=coalesce(upload_object_key,object_key), object_key=v_key,
    wire_sha256=p_wire_sha256, sha256_source='server_verified', digest_scope=v_scope,
    status='ready', verified_at=(v_receipt->>'verifiedAt')::timestamptz, indexed_at=v_now,
    uploaded_at=coalesce(uploaded_at,v_now), durability_receipt=v_receipt, updated_at=v_now
    where id=v.id and (status <> 'ready' or object_key is distinct from v_key
      or wire_sha256 is distinct from p_wire_sha256 or durability_receipt is distinct from v_receipt
      or indexed_at is null or v_index_changes > 0);
  return v_receipt;
end;
$$;

-- ACK publication shares the permanent reservation lock. The previous function could silently
-- affect zero rows in a digest race; it also accepted ACKs without a verified archive receipt.
create or replace function public.noop_push_save_ack(
  p_user_id uuid, p_batch_id uuid, p_body_sha256 text, p_ack jsonb
) returns void language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_hash text; v_receipt jsonb;
begin
  select body_sha256 into v_hash from public.noop_push_reservations
    where user_id=p_user_id and batch_id=p_batch_id for update;
  if not found or v_hash is distinct from p_body_sha256 then
    raise exception 'batch_id_conflict' using errcode='23505';
  end if;
  select durability_receipt into v_receipt from public.object_manifests
    where id=p_batch_id and user_id=p_user_id and status='ready' and indexed_at is not null;
  if v_receipt is null or p_ack->'durabilityReceipt' is distinct from v_receipt
     or not exists (select 1 from public.noop_signal_windows where object_id=p_batch_id
                    and user_id=p_user_id and object_key=v_receipt->>'objectKey') then
    raise exception 'archive_not_ready' using errcode='23514';
  end if;
  insert into public.noop_push_acks(user_id,batch_id,body_sha256,ack)
    values(p_user_id,p_batch_id,p_body_sha256,p_ack)
    on conflict(user_id,batch_id) do update set ack=excluded.ack,saved_at=now()
    where public.noop_push_acks.body_sha256=excluded.body_sha256;
  if not found then raise exception 'batch_id_conflict' using errcode='23505'; end if;
end;
$$;

create table if not exists public.noop_intake_reconcile_state (
  id boolean primary key default true check(id), cursor_id uuid, updated_at timestamptz not null default now()
);
alter table public.noop_intake_reconcile_state enable row level security;
revoke all on public.noop_intake_reconcile_state from anon, authenticated;
grant all on public.noop_intake_reconcile_state to service_role;
create policy noop_intake_reconcile_service on public.noop_intake_reconcile_state
  for all to service_role using (true) with check (true);
insert into public.noop_intake_reconcile_state(id) values(true) on conflict do nothing;

create or replace function public.noop_intake_reconcile_page(p_limit integer default 16)
returns jsonb language plpgsql security definer set search_path = pg_catalog, public as $$
declare v_cursor uuid; v_rows jsonb; v_last uuid;
begin
  select cursor_id into v_cursor from public.noop_intake_reconcile_state where id for update;
  select jsonb_agg(to_jsonb(x) order by x.id), max(x.id::text)::uuid into v_rows,v_last from (
    select * from public.object_manifests m where object_class='raw'
      and status not in ('deleted','deleting','expired') and sha256 is not null
      and (durability_receipt is null or indexed_at is null or status not in ('ready','verified')
        or not exists (select 1 from public.noop_signal_windows w
          where w.object_id=m.id and w.user_id=m.user_id and w.device_id=m.device_id and w.object_key=m.object_key))
      and (v_cursor is null or id > v_cursor) order by id limit greatest(1,least(p_limit,64))
  ) x;
  update public.noop_intake_reconcile_state set cursor_id=v_last,updated_at=now() where id;
  return coalesce(v_rows,'[]'::jsonb);
end;
$$;

revoke all on function public.noop_register_push_device(uuid,uuid,text) from public,anon,authenticated;
revoke all on function public.noop_reserve_push_batch(uuid,uuid,uuid,text,jsonb) from public,anon,authenticated;
revoke all on function public.noop_reserve_object_manifest(jsonb) from public,anon,authenticated;
revoke all on function public.noop_commit_object_receipt(uuid,uuid,text,text,text,bigint,bigint) from public,anon,authenticated;
revoke all on function public.noop_intake_reconcile_page(integer) from public,anon,authenticated;
revoke all on function public.noop_push_save_ack(uuid,uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.noop_register_push_device(uuid,uuid,text) to service_role;
grant execute on function public.noop_reserve_push_batch(uuid,uuid,uuid,text,jsonb) to service_role;
grant execute on function public.noop_reserve_object_manifest(jsonb) to service_role;
grant execute on function public.noop_commit_object_receipt(uuid,uuid,text,text,text,bigint,bigint) to service_role;
grant execute on function public.noop_intake_reconcile_page(integer) to service_role;
grant execute on function public.noop_push_save_ack(uuid,uuid,text,jsonb) to service_role;
