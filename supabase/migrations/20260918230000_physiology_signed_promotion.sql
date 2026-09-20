-- Canonical readback requires an independently signed, feature-specific release.
-- Existing snapshots remain immutable shadow evidence. No keys or approvals ship here.
begin;

update public.physiology_feature_defaults
set algorithm_version='frwhoop-server-1',updated_at=now();
update public.physiology_source_selection
set algorithm_version='frwhoop-server-1',updated_at=now()
where algorithm_version <> 'frwhoop-server-1';
update public.physiology_feature_qualifications
set qualification='shadow'
where algorithm_version <> 'frwhoop-server-1';

alter table public.physiology_feature_qualifications
  drop constraint if exists physiology_feature_qualifications_qualification_check;
alter table public.physiology_feature_qualifications
  add constraint physiology_feature_qualifications_qualification_check
  check(qualification in ('baseline','shadow','reference_qualified'));

-- Provisioning a release-signing key is an explicit database-owner operation. The
-- application roles, including service_role, cannot read or replace trusted keys.
create table internal.physiology_approval_keys (
  key_id text primary key check(key_id ~ '^[a-f0-9]{64}$'),
  secret bytea not null check(octet_length(secret)>=32),
  reviewer text not null check(length(reviewer)>0),
  revoked_at timestamptz,
  check(encode(sha256(secret),'hex')=key_id)
);
revoke all on internal.physiology_approval_keys from public,anon,authenticated,service_role;

create table public.physiology_feature_manifests (
  algorithm_version text not null references public.physiology_algorithm_versions,
  feature text not null references public.physiology_feature_defaults,
  manifest jsonb not null,
  canonical_manifest text not null,
  manifest_sha256 text not null check(manifest_sha256 ~ '^[a-f0-9]{64}$'),
  algorithm_manifest_sha256 text not null check(algorithm_manifest_sha256 ~ '^[a-f0-9]{64}$'),
  checkpoint_sha256 text not null check(checkpoint_sha256 ~ '^[a-f0-9]{64}$'),
  preprocessing_version text not null check(length(preprocessing_version)>0),
  preprocessing_sha256 text not null check(preprocessing_sha256 ~ '^[a-f0-9]{64}$'),
  quality_policy_version text not null check(length(quality_policy_version)>0),
  quality_policy_sha256 text not null check(quality_policy_sha256 ~ '^[a-f0-9]{64}$'),
  created_at timestamptz not null default now(),
  primary key(algorithm_version,feature),
  check(jsonb_typeof(manifest)='object'),
  check(canonical_manifest::jsonb=manifest),
  check(encode(sha256(convert_to(canonical_manifest,'UTF8')),'hex')=manifest_sha256),
  check((manifest->>'algorithm_version'=algorithm_version
    and manifest->>'feature'=feature
    and manifest->>'checkpoint_sha256'=checkpoint_sha256
    and manifest->>'preprocessing_version'=preprocessing_version
    and manifest->>'preprocessing_sha256'=preprocessing_sha256
    and manifest->>'quality_policy_version'=quality_policy_version
    and manifest->>'quality_policy_sha256'=quality_policy_sha256) is true)
);
create table public.physiology_promotion_approvals (
  approval_id uuid primary key,
  algorithm_version text not null,
  feature text not null,
  key_id text not null references internal.physiology_approval_keys,
  -- Signature covers these exact UTF-8 bytes, avoiding cross-language JSON formatting.
  signed_payload text not null check(octet_length(signed_payload)<=32768),
  signature_hex text not null check(signature_hex ~ '^[a-f0-9]{64}$'),
  created_at timestamptz not null default now(),
  foreign key(algorithm_version,feature)
    references public.physiology_feature_manifests(algorithm_version,feature)
);
create table public.physiology_promotion_revocations (
  approval_id uuid primary key references public.physiology_promotion_approvals,
  reason text not null check(length(reason)>0),
  revoked_at timestamptz not null default now()
);

alter table public.physiology_feature_manifests enable row level security;
alter table public.physiology_promotion_approvals enable row level security;
alter table public.physiology_promotion_revocations enable row level security;
revoke all on public.physiology_feature_manifests,public.physiology_promotion_approvals,
  public.physiology_promotion_revocations from public,anon,authenticated,service_role;
-- Manifests contain release identity, never participant data or signing secrets.
create policy physiology_feature_manifest_read on public.physiology_feature_manifests
  for select to authenticated,service_role using(true);
grant select on public.physiology_feature_manifests to authenticated,service_role;

create function internal.physiology_immutable_release() returns trigger
language plpgsql set search_path='' as $$
begin
  raise exception 'release evidence is immutable; register a new version or append a revocation'
    using errcode='22023';
end $$;
create trigger physiology_feature_manifest_immutable before update or delete
  on public.physiology_feature_manifests for each row
  execute function internal.physiology_immutable_release();
create trigger physiology_approval_immutable before update or delete
  on public.physiology_promotion_approvals for each row
  execute function internal.physiology_immutable_release();
create trigger physiology_revocation_immutable before update or delete
  on public.physiology_promotion_revocations for each row
  execute function internal.physiology_immutable_release();

create function internal.physiology_algorithm_manifest_immutable() returns trigger
language plpgsql set search_path='' as $$
begin
  if tg_op='DELETE' or new.algorithm_version is distinct from old.algorithm_version
    or new.manifest is distinct from old.manifest
    or new.manifest_hash is distinct from old.manifest_hash
    or new.computation_kind is distinct from old.computation_kind then
    raise exception 'algorithm identity is immutable; register a new version' using errcode='22023';
  end if;
  return new;
end $$;
create trigger physiology_algorithm_identity_immutable before update or delete
  on public.physiology_algorithm_versions for each row
  execute function internal.physiology_algorithm_manifest_immutable();

create function internal.physiology_approval_valid(a public.physiology_promotion_approvals)
returns boolean language plpgsql stable security definer set search_path='' as $$
declare p jsonb; k internal.physiology_approval_keys; m public.physiology_feature_manifests;
  algorithm_hash text;
begin
  select * into k from internal.physiology_approval_keys where key_id=a.key_id and revoked_at is null;
  if not found then return false; end if;
  if encode(extensions.hmac(convert_to(a.signed_payload,'UTF8'),k.secret,'sha256'),'hex')
    is distinct from a.signature_hex then return false; end if;
  p := a.signed_payload::jsonb;
  select * into m from public.physiology_feature_manifests
    where algorithm_version=a.algorithm_version and feature=a.feature;
  if not found then return false; end if;
  select manifest_hash into algorithm_hash from public.physiology_algorithm_versions
    where algorithm_version=a.algorithm_version;
  return coalesce(
    p->>'schema_version'='1'
    and p->>'purpose'='physiology_feature_promotion'
    and p->>'approval_id'=a.approval_id::text
    and p->>'key_id'=a.key_id
    and p->>'reviewer'=k.reviewer
    and p->>'decision'='approved'
    and p->>'algorithm_version'=a.algorithm_version and p->>'feature'=a.feature
    and p->>'manifest_sha256'=m.manifest_sha256
    and p->>'algorithm_manifest_sha256'=algorithm_hash
    and m.algorithm_manifest_sha256=algorithm_hash
    and p->>'checkpoint_sha256'=m.checkpoint_sha256
    and p->>'preprocessing_version'=m.preprocessing_version
    and p->>'preprocessing_sha256'=m.preprocessing_sha256
    and p->>'quality_policy_version'=m.quality_policy_version
    and p->>'quality_policy_sha256'=m.quality_policy_sha256
    and p->>'evaluation_sha256' ~ '^[a-f0-9]{64}$'
    and p->>'policy_sha256' ~ '^[a-f0-9]{64}$'
    and p->>'reference_artifact_sha256' ~ '^[a-f0-9]{64}$'
    and p->>'reference_kind'=case a.feature when 'hrv' then 'synchronized_ecg_nn'
      when 'sleep' then 'psg_30s_and_sleep_opportunities'
      when 'respiration' then 'synchronized_respiratory_reference' end
    and p->>'evaluation_partition' in ('test','external')
    and (p->>'participant_disjoint')::boolean
    and (p->>'functional_gates_passed')::boolean
    and (p->>'promotion_policy_passed')::boolean
    and (p->>'policy_frozen_at')::timestamptz < (p->>'evaluation_started_at')::timestamptz
    and (p->>'evaluation_started_at')::timestamptz <= (p->>'evaluation_finished_at')::timestamptz
    and (p->>'evaluation_finished_at')::timestamptz <= (p->>'approved_at')::timestamptz
    and (p->>'approved_at')::timestamptz <= now()
    and not exists(select 1 from public.physiology_promotion_revocations where approval_id=a.approval_id),
    false);
exception when data_exception then return false;
end $$;
revoke all on function internal.physiology_approval_valid(public.physiology_promotion_approvals)
  from public,anon,authenticated,service_role;

create function public.physiology_feature_is_canonical(p_version text,p_feature text)
returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.physiology_feature_qualifications q
    join public.physiology_algorithm_versions v using(algorithm_version)
    where q.algorithm_version=p_version and q.feature=p_feature and (
      (p_version='frwhoop-server-1' and q.qualification='baseline' and v.qualification='baseline')
      or (q.qualification='reference_qualified' and exists(
        select 1 from public.physiology_promotion_approvals a
        where a.algorithm_version=p_version and a.feature=p_feature
          and a.signed_payload::jsonb->>'policy_sha256'=q.policy_sha256
          and a.signed_payload::jsonb->>'evaluation_sha256'=q.evaluation_sha256
          and internal.physiology_approval_valid(a)))));
$$;
revoke all on function public.physiology_feature_is_canonical(text,text) from public,anon;
grant execute on function public.physiology_feature_is_canonical(text,text) to authenticated,service_role;

create function public.register_physiology_promotion(p_payload text,p_signature text)
returns uuid language plpgsql security definer set search_path='' as $$
declare p jsonb; a public.physiology_promotion_approvals;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'service role required' using errcode='42501';
  end if;
  p := p_payload::jsonb;
  a.approval_id := (p->>'approval_id')::uuid;
  a.algorithm_version := p->>'algorithm_version'; a.feature := p->>'feature';
  a.key_id := p->>'key_id'; a.signed_payload := p_payload; a.signature_hex := p_signature;
  if not internal.physiology_approval_valid(a) then
    raise exception 'signed reference approval required' using errcode='22023';
  end if;
  insert into public.physiology_promotion_approvals
    (approval_id,algorithm_version,feature,key_id,signed_payload,signature_hex)
    values(a.approval_id,a.algorithm_version,a.feature,a.key_id,a.signed_payload,a.signature_hex);
  return a.approval_id;
end $$;
revoke all on function public.register_physiology_promotion(text,text) from public,anon,authenticated;
grant execute on function public.register_physiology_promotion(text,text) to service_role;

create function internal.physiology_selection_guard() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if not public.physiology_feature_is_canonical(new.algorithm_version,new.feature) then
    raise exception 'feature lacks signed reference qualification' using errcode='22023';
  end if;
  return new;
end $$;
create trigger physiology_default_qualification before insert or update
  on public.physiology_feature_defaults for each row execute function internal.physiology_selection_guard();
create trigger physiology_selection_qualification before insert or update
  on public.physiology_source_selection for each row execute function internal.physiology_selection_guard();

create or replace function public.select_physiology_source(p_feature text,p_device uuid,p_version text)
returns void language plpgsql security definer set search_path=pg_catalog,public as $$
declare u uuid := auth.uid();
begin
  if u is null or not exists(select 1 from public.devices where id=p_device and user_id=u) then
    raise exception 'owned device required' using errcode='42501';
  end if;
  if not public.physiology_feature_is_canonical(p_version,p_feature) then
    raise exception 'algorithm is not qualified for canonical display' using errcode='22023';
  end if;
  insert into public.physiology_source_selection(user_id,feature,device_id,algorithm_version)
    values(u,p_feature,p_device,p_version)
  on conflict(user_id,feature) do update set device_id=excluded.device_id,
    algorithm_version=excluded.algorithm_version,updated_at=now();
end $$;

create or replace function public.server_scoring_for_day(p_user uuid, p_day date)
returns jsonb language plpgsql stable security invoker set search_path = pg_catalog, public as $$
declare
  feature_key text;
  device uuid;
  version text;
  result jsonb;
  daily jsonb := '{}'::jsonb;
  nights jsonb := '[]'::jsonb;
  measurements jsonb := '[]'::jsonb;
  sleep_overrides jsonb := '[]'::jsonb;
  features jsonb := '{}'::jsonb;
  current_revision bigint;
  result_revision bigint;
  is_stale boolean := false;
  feature_stale boolean;
  computed timestamptz;
  feature_computed timestamptz;
  key text;
  keys text[];
  selected_versions text[] := '{}'::text[];
  selected_devices uuid[] := '{}'::uuid[];
  processing jsonb;
  period_zone text;
  result_unavailable_reason text;
begin
  if auth.uid() is distinct from p_user and auth.role() is distinct from 'service_role' then
    raise exception 'owner required' using errcode = '42501';
  end if;
  for feature_key in select feature from public.physiology_feature_defaults order by feature loop
    select s.device_id, s.algorithm_version into device, version
      from public.physiology_source_selection s where s.user_id=p_user and s.feature=feature_key;
    if device is null then
      select d.id into device
        from public.devices d
        where d.user_id=p_user
        order by (
          select max(h.ts) from public.noop_hr_samples h
          where h.user_id=p_user and h.device_id=d.id
        ) desc nulls last,
        d.last_seen_at desc nulls last,
        d.id
        limit 1;
      if device is null then
        features := features || jsonb_build_object(feature_key,
          jsonb_build_object('status','unavailable','reason','source_selection_required'));
        is_stale := true;
        continue;
      end if;
      select algorithm_version into version from public.physiology_feature_defaults where feature=feature_key;
    end if;
    if not public.physiology_feature_is_canonical(version,feature_key) then
      features := features || jsonb_build_object(feature_key,
        jsonb_build_object('status','unavailable','reason','unqualified_version'));
      is_stale := true;
      continue;
    end if;
    result := null; result_revision := null; feature_computed := null;
    select payload,input_revision,computed_at into result,result_revision,feature_computed
      from public.server_physiology_results where user_id=p_user and device_id=device
        and period_day=p_day and algorithm_version=version
        and manifest_hash=(select v.manifest_hash from public.physiology_algorithm_versions v
          where v.algorithm_version=version)
        and (version='frwhoop-server-1' or payload->'feature_manifest_hashes'->>feature_key=(
          select m.manifest_sha256 from public.physiology_feature_manifests m
          where m.algorithm_version=version and m.feature=feature_key))
      order by input_revision desc limit 1;
    if result is null and version='frwhoop-server-1' then
      select jsonb_build_object('daily',to_jsonb(d),'nights',coalesce((
        select jsonb_agg(to_jsonb(n) order by n.start_at) from public.server_sleep_nights n
        where n.user_id=p_user and n.device_id=device and n.period_day=p_day and n.algorithm_version=version
      ),'[]'::jsonb)),d.computed_at into result,feature_computed
      from public.server_daily_scores d where d.user_id=p_user and d.source_device_id=device
        and d.day=p_day and d.algorithm_version=version;
    end if;
    processing := public.physiology_processing_metadata(p_user,device,p_day,version,result_revision);
    current_revision := (processing->>'required_revision')::bigint;
    period_zone := processing->>'timezone_id';
    feature_stale := case when version='frwhoop-server-1' and result_revision is null
      then result is null or not coalesce((processing->>'legacy_result_current')::boolean,false)
      else result is null or coalesce(result_revision < current_revision,false)
        or (result_revision is null and current_revision is not null) end;
    is_stale := is_stale or feature_stale;
    selected_versions := array_append(selected_versions,version);
    selected_devices := array_append(selected_devices,device);
    if feature_computed is not null then computed := greatest(computed,feature_computed); end if;
    result_unavailable_reason := nullif(result->>'unavailable_reason','');
    features := features || jsonb_build_object(feature_key,jsonb_build_object(
      'status',case when result is null then 'unavailable' when feature_stale then 'stale'
        when result_unavailable_reason is not null then 'unavailable' else 'available' end,
      'reason',case when result is null then 'awaiting_result' when feature_stale then 'newer_input_pending'
        else result_unavailable_reason end,
      'device_id',device,'algorithm_version',version,'input_revision',result_revision,
      'required_revision',current_revision,'computed_at',feature_computed,
      'observed_through',result->'observed_through','publication_status',result->'publication_status',
      'manifest_hash',result->'manifest_hash','computation_mode',result->'computation_mode',
      'feature_manifest_hash',result->'feature_manifest_hashes'->feature_key,
      'canonical_qualification',case when version='frwhoop-server-1' then 'retained_legacy'
        else 'signed_reference_approval' end,
      'archive_status',processing->'archive_status','processing_status',processing->'processing_status',
      'revision_protocol',processing->'revision_protocol',
      'timezone_id',period_zone,'timezone_ids',processing->'timezone_ids',
      'day_intervals',processing->'day_intervals','context_intervals',processing->'context_intervals',
      'supports_boundary_overrides',feature_key='sleep' and version='frwhoop-physiology-2'));
    keys := case feature_key
      when 'hrv' then array['hrv_rmssd_ms','hrv_sdnn_ms','resting_hr_bpm','overnight_hr_bpm','hrv_summary','heart_rate_windows',
        'recovery','strain','spo2_pct','skin_temp_c','skin_temp_dev_c']
      when 'respiration' then array['resp_rate_bpm','respiration_summary','respiration_unavailable_reason']
      else array['sleep_total_min','sleep_in_bed_min','sleep_awake_min','sleep_light_min','sleep_deep_min',
        'sleep_rem_min','sleep_efficiency','sleep_onset_at','wake_onset_at','sleep_unstaged_min',
        'state_unknown_min','off_body_min','main_sleep_group_id','opportunity_kind','disturbances','full_day_sleep_epochs'] end;
    foreach key in array keys loop
      daily := daily || jsonb_build_object(key,result->'daily'->key);
    end loop;
    measurements := measurements || coalesce((select jsonb_agg(m) from jsonb_array_elements(
      coalesce(result->'measurements','[]'::jsonb)) m where m->>'feature'=feature_key),'[]'::jsonb);
    if feature_key='sleep' then
      nights := coalesce(result->'nights','[]'::jsonb);
      sleep_overrides := public.physiology_owned_sleep_overrides(p_user,device,p_day);
    end if;
  end loop;
  -- Episodes are selected by sleep. Embedded physiology must independently match its
  -- selected, qualified feature snapshot; sleep promotion cannot authorize HRV/RR.
  if not coalesce(
      features->'hrv'->>'status' in ('available','stale')
      and features->'hrv'->>'algorithm_version'=features->'sleep'->>'algorithm_version'
      and features->'hrv'->>'device_id'=features->'sleep'->>'device_id'
      and (features->'hrv'->'input_revision') is not distinct from (features->'sleep'->'input_revision'),false) then
    select coalesce(jsonb_agg(n - array['hrv_rmssd_ms','hrv_sdnn_ms','resting_hr_bpm',
      'overnight_hr_bpm','hrv_summary','heart_rate_windows'] order by ordinal),'[]'::jsonb)
      into nights from jsonb_array_elements(nights) with ordinality as episode(n,ordinal);
  end if;
  if not coalesce(
      features->'respiration'->>'status' in ('available','stale')
      and features->'respiration'->>'algorithm_version'=features->'sleep'->>'algorithm_version'
      and features->'respiration'->>'device_id'=features->'sleep'->>'device_id'
      and (features->'respiration'->'input_revision') is not distinct from (features->'sleep'->'input_revision'),false) then
    select coalesce(jsonb_agg(n - array['resp_rate_bpm','respiration_summary','respiration_unavailable_reason']
      order by ordinal),'[]'::jsonb) into nights
      from jsonb_array_elements(nights) with ordinality as episode(n,ordinal);
  end if;
  return jsonb_build_object('schema_version',2,'user_id',p_user,'day',p_day,
    'algorithm_version',case when cardinality(array(select distinct unnest(selected_versions)))=1
      then selected_versions[1] else 'per_feature' end,
    'daily',case when computed is null then null else daily || jsonb_build_object('day',p_day,'computed_at',computed,
      'source_device_id',case when cardinality(array(select distinct unnest(selected_devices)))=1
        then selected_devices[1] else null end) end,
    'nights',nights,'features',features,'measurements',measurements,'sleep_overrides',sleep_overrides,
    'computed_at',computed,'stale',is_stale);
end;
$$;

revoke all on function public.server_scoring_for_day(uuid, date) from public, anon;
grant execute on function public.server_scoring_for_day(uuid, date) to authenticated, service_role;

commit;
