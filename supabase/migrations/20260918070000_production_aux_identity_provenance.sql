-- Additive1.4 receiver support. Advertisement remains disabled until cross-stack golden gates.
alter table public.noop_step_samples add column provenance jsonb;
alter table public.noop_sleep_state_samples add column provenance jsonb;
alter table public.noop_ppg_hr_samples add column provenance jsonb;

create function public.noop_valid_scalar_provenance(p jsonb) returns boolean
language plpgsql immutable set search_path=pg_catalog,public as $$
declare k text; v jsonb; n numeric;
begin
  if p is null then return true; end if;
  if jsonb_typeof(p) is distinct from 'object' or octet_length(p::text)>1024
    or p->'v' is distinct from '1'::jsonb
    or coalesce(p->>'origin','') not in ('whoop-v18','whoop-v26-ppg-derived','legacy-unknown') then return false; end if;
  for k,v in select * from jsonb_each(p) loop
    if k not in ('v','origin','recordIndex','frameSHA256','algorithm','sampleRateHz',
      'windowSettingSeconds','inputStartTs','inputEndTs','inputSHA256')
      or jsonb_typeof(v) not in ('string','number') then return false; end if;
    if k in ('recordIndex','sampleRateHz','windowSettingSeconds','inputStartTs','inputEndTs') then
      if jsonb_typeof(v)<>'number' then return false; end if;
      n:=(v::text)::numeric;
      if n<>trunc(n) or abs(n)>9007199254740991 then return false; end if;
      if k='recordIndex' and (n<0 or n>4294967295) then return false; end if;
      if k in ('sampleRateHz','windowSettingSeconds') and n<=0 then return false; end if;
    end if;
    if k in ('frameSHA256','inputSHA256') and (jsonb_typeof(v)<>'string' or (v#>>'{}') !~ '^[0-9a-f]{64}$') then return false; end if;
    if k='algorithm' and (v#>>'{}') not in ('ppg-acf-v1','ppg-acf-sublag-v1') then return false; end if;
  end loop;
  if p ? 'inputStartTs' and p ? 'inputEndTs' and (p->>'inputEndTs')::numeric<=(p->>'inputStartTs')::numeric then return false; end if;
  if p->>'origin'='whoop-v26-ppg-derived' then
    if p ?| array['recordIndex','frameSHA256'] or not (p ?& array['algorithm','sampleRateHz','windowSettingSeconds','inputStartTs','inputEndTs','inputSHA256']) then return false; end if;
  else
    if p ?| array['algorithm','sampleRateHz','windowSettingSeconds','inputStartTs','inputEndTs','inputSHA256'] then return false; end if;
    if p->>'origin'='legacy-unknown' and p ?| array['recordIndex','frameSHA256'] then return false; end if;
  end if;
  return true;
end $$;
alter table public.noop_step_samples add constraint noop_step_provenance_valid check(public.noop_valid_scalar_provenance(provenance));
alter table public.noop_sleep_state_samples add constraint noop_state_provenance_valid check(public.noop_valid_scalar_provenance(provenance));
alter table public.noop_ppg_hr_samples add constraint noop_ppghr_provenance_valid check(public.noop_valid_scalar_provenance(provenance));
revoke all on function public.noop_valid_scalar_provenance(jsonb) from public,anon,authenticated;
grant execute on function public.noop_valid_scalar_provenance(jsonb) to service_role;

-- This is typed validation status, not evidence that a scorer consumed the archive. Unsupported
-- fields are retained exactly; pending prevents automatic retention from deleting that evidence.
create table public.noop_aux_object_validation (
  object_id uuid primary key references public.object_manifests(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null references public.devices(id),
  content_sha256 text not null check(content_sha256 ~ '^[0-9a-f]{64}$'),
  wire_sha256 text not null check(wire_sha256 ~ '^[0-9a-f]{64}$'),
  state text not null check(state in ('validated','pending')),
  validation jsonb not null,
  verified_at timestamptz not null default now()
);
alter table public.noop_aux_object_validation enable row level security;
create policy noop_aux_validation_owner on public.noop_aux_object_validation for select to authenticated using(user_id=auth.uid());
revoke all on public.noop_aux_object_validation from public,anon,authenticated;
grant select on public.noop_aux_object_validation to authenticated;
grant all on public.noop_aux_object_validation to service_role;

-- Both entrypoints share020's receipt/index transaction. A direct service call to the legacy
-- entrypoint cannot publish1.4 auxiliary without the digest-bound validation record.
create function public.noop_aux_receipt_requires_validation() returns trigger
language plpgsql set search_path=pg_catalog,public as $$
begin
  if new.object_kind='v18AuxSample' and new.push_protocol_version='1.4' and new.durability_receipt is not null
    and not exists(select 1 from public.noop_aux_object_validation v where v.object_id=new.id
      and v.user_id=new.user_id and v.device_id=new.device_id
      and v.content_sha256=new.durability_receipt->>'contentSha256'
      and v.wire_sha256=new.durability_receipt->>'wireSha256') then
    raise exception 'aux_validation_required' using errcode='23514';
  end if;
  return new;
end $$;
create trigger noop_aux_receipt_requires_validation before insert or update on public.object_manifests
  for each row execute function public.noop_aux_receipt_requires_validation();
revoke all on function public.noop_aux_receipt_requires_validation() from public,anon,authenticated;
grant execute on function public.noop_aux_receipt_requires_validation() to service_role;

-- Identity-v2 auxiliary records are not a one-record-per-second stream. Distinct
-- same-second siblings must not conceal missing seconds in020's inherited index.
-- Preserve received_records as the actual identity count; no temporal coverage
-- policy has been defined for this format. A trigger also covers the legacy
-- receipt entrypoint when it reconstructs an already-validated object's index.
create function public.noop_aux_window_coverage_unknown() returns trigger
language plpgsql set search_path=pg_catalog,public as $$
begin
  if new.stream='v18AuxSample' and exists (
    select 1 from public.object_manifests m where m.id=new.object_id
      and m.user_id=new.user_id and m.device_id=new.device_id
      and m.object_kind='v18AuxSample' and m.push_protocol_version='1.4' and m.schema_version=2
  ) then
    new.expected_records:=null;
    new.missing_records:=null;
    new.coverage:=null;
  end if;
  return new;
end $$;
create trigger noop_aux_window_coverage_unknown
  before insert or update on public.noop_signal_windows
  for each row execute function public.noop_aux_window_coverage_unknown();
revoke all on function public.noop_aux_window_coverage_unknown() from public,anon,authenticated;
grant execute on function public.noop_aux_window_coverage_unknown() to service_role;

create function public.noop_commit_aux_object_receipt(
  p_user_id uuid,p_object_id uuid,p_verified_key text,p_wire_sha256 text,p_content_sha256 text,
  p_compressed_bytes bigint,p_uncompressed_bytes bigint,p_validation jsonb
) returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare m public.object_manifests; v public.noop_aux_object_validation; k text; n bigint;
begin
  select * into m from public.object_manifests where id=p_object_id for update;
  if not found or m.user_id is distinct from p_user_id or m.object_kind<>'v18AuxSample'
    or m.push_protocol_version is distinct from '1.4' or m.schema_version<>2 then
    raise exception 'object_owner_conflict' using errcode='42501';
  end if;
  if jsonb_typeof(p_validation) is distinct from 'object' or octet_length(p_validation::text)>1024
    or p_validation->'version' is distinct from '1'::jsonb or p_validation->'format' is distinct from '2'::jsonb
    or coalesce(p_validation->>'state','') not in ('validated','pending') then raise exception 'invalid_aux_validation'; end if;
  foreach k in array array['records','supportedRecords','unknownIdentityRecords','unsupportedFieldsRecords'] loop
    if jsonb_typeof(p_validation->k) is distinct from 'number' or (p_validation->>k) !~ '^[0-9]+$' then raise exception 'invalid_aux_validation'; end if;
    n:=(p_validation->>k)::bigint;
    if n>m.sample_count then raise exception 'invalid_aux_validation'; end if;
  end loop;
  if (p_validation->>'records')::bigint<>m.sample_count
    or (p_validation->>'supportedRecords')::bigint+(p_validation->>'unsupportedFieldsRecords')::bigint<>m.sample_count
    or (p_validation->>'state'='validated') is distinct from ((p_validation->>'unsupportedFieldsRecords')::bigint=0)
    then raise exception 'invalid_aux_validation'; end if;
  insert into public.noop_aux_object_validation(object_id,user_id,device_id,content_sha256,wire_sha256,state,validation)
    values(m.id,m.user_id,m.device_id,p_content_sha256,p_wire_sha256,p_validation->>'state',p_validation)
    on conflict(object_id) do nothing;
  select * into v from public.noop_aux_object_validation where object_id=m.id;
  if v.user_id is distinct from m.user_id or v.device_id is distinct from m.device_id
    or v.content_sha256 is distinct from p_content_sha256 or v.wire_sha256 is distinct from p_wire_sha256
    or v.validation is distinct from p_validation then raise exception 'receipt_immutable'; end if;
  return public.noop_commit_object_receipt(p_user_id,p_object_id,p_verified_key,p_wire_sha256,p_content_sha256,p_compressed_bytes,p_uncompressed_bytes);
end $$;
revoke all on function public.noop_commit_aux_object_receipt(uuid,uuid,text,text,text,bigint,bigint,jsonb) from public,anon,authenticated;
grant execute on function public.noop_commit_aux_object_receipt(uuid,uuid,text,text,text,bigint,bigint,jsonb) to service_role;
