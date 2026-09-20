-- A legacy manual boundary remains a source record. Continuing it creates a separately owned
-- physiology override only after an explicit client request with the observed source token.
create function public.physiology_legacy_sleep_boundaries(p_user uuid,p_device uuid)
returns table(id uuid,original_start_at timestamptz,original_end_at timestamptz,start_at timestamptz,
  end_at timestamptz,updated_at timestamptz,legacy_revision text)
language sql stable security definer set search_path='' as $$
  select s.id,coalesce(d.original_start_at,s.start_at),coalesce(d.original_end_at,s.end_at),
    coalesce(d.user_start_at,s.start_at),coalesce(d.user_end_at,s.end_at),greatest(s.updated_at,d.updated_at),
    encode(extensions.digest(jsonb_build_array(s.id,s.user_id,s.device_id,s.user_modified,
      extract(epoch from s.start_at),extract(epoch from s.end_at),extract(epoch from s.updated_at),
      extract(epoch from d.original_start_at),extract(epoch from d.original_end_at),
      extract(epoch from d.user_start_at),extract(epoch from d.user_end_at),extract(epoch from d.updated_at))::text,'sha256'),'hex')
  from public.sessions s left join public.sleep_details d on d.session_id=s.id and d.user_id=s.user_id
  where s.user_id=p_user and s.device_id=p_device and s.kind in ('sleep','nap')
    and (s.user_modified or d.user_start_at is not null or d.user_end_at is not null)
$$;
revoke all on function public.physiology_legacy_sleep_boundaries(uuid,uuid) from public,anon,authenticated;
grant execute on function public.physiology_legacy_sleep_boundaries(uuid,uuid) to service_role;

create or replace function public.physiology_owned_sleep_overrides(p_user uuid,p_device uuid,p_day date)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare edits jsonb;
begin
  if auth.uid() is distinct from p_user and auth.role() is distinct from 'service_role' then
    raise exception 'owner required' using errcode='42501';
  end if;
  with boundaries as (
    select o.id,o.original_start_at,o.original_end_at,o.start_at,o.end_at,o.updated_at,o.tombstone,
      o.revision,'physiology_override'::text as source,null::text as legacy_revision
    from public.physiology_sleep_overrides o where o.user_id=p_user and o.device_id=p_device
    union all
    select l.id,l.original_start_at,l.original_end_at,l.start_at,l.end_at,l.updated_at,false,0,
      'legacy_user_boundary',l.legacy_revision from public.physiology_legacy_sleep_boundaries(p_user,p_device) l
    where not exists(select 1 from public.physiology_sleep_overrides o
      where o.id=l.id and o.user_id=p_user and o.device_id=p_device)
  ) select coalesce(jsonb_agg(jsonb_build_object('id',o.id,'device_id',p_device,'revision',o.revision,
      'original_start',floor(extract(epoch from o.original_start_at))::bigint,
      'original_end',floor(extract(epoch from o.original_end_at))::bigint,
      'original_start_at',to_char(o.original_start_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
      'original_end_at',to_char(o.original_end_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
      'start',floor(extract(epoch from o.start_at))::bigint,'end',floor(extract(epoch from o.end_at))::bigint,
      'tombstone',o.tombstone,'source',o.source,'legacy_revision',o.legacy_revision,
      'boundary_provenance','user_boundary:'||o.source||':'||o.id::text) order by o.updated_at,o.id),'[]'::jsonb)
    into edits from boundaries o where exists(
      select 1 from (values (p_day-1),(p_day)) days(calendar_day)
      cross join lateral public.scoring_day_segments(p_user,days.calendar_day) s
      where (o.original_start_at<to_timestamp(s.end_ts) and o.original_end_at>to_timestamp(s.start_ts)) or
        (o.start_at<to_timestamp(s.end_ts) and o.end_at>to_timestamp(s.start_ts)));
  return edits;
end $$;

-- Preserve the public RPC signature while keeping the token-validated continuation as the
-- only first-write path that may reuse a source session identity.
alter function public.set_physiology_sleep_override(uuid,uuid,timestamptz,timestamptz,timestamptz,timestamptz,boolean,bigint)
  rename to physiology_write_sleep_override;
revoke all on function public.physiology_write_sleep_override(uuid,uuid,timestamptz,timestamptz,timestamptz,timestamptz,boolean,bigint)
  from public,anon,authenticated;
grant execute on function public.physiology_write_sleep_override(uuid,uuid,timestamptz,timestamptz,timestamptz,timestamptz,boolean,bigint)
  to service_role;
create function public.set_physiology_sleep_override(p_id uuid,p_device uuid,
  p_original_start timestamptz,p_original_end timestamptz,p_start timestamptz,p_end timestamptz,
  p_tombstone boolean,p_expected_revision bigint default 0)
returns bigint language plpgsql security definer set search_path='' as $$
begin
  if auth.uid() is null then raise exception 'owner required' using errcode='42501'; end if;
  if p_expected_revision=0 and exists(select 1 from public.sessions where id=p_id) then
    raise exception 'source session continuation required' using errcode='40001';
  end if;
  return public.physiology_write_sleep_override(p_id,p_device,p_original_start,p_original_end,
    p_start,p_end,p_tombstone,p_expected_revision);
end $$;
revoke all on function public.set_physiology_sleep_override(uuid,uuid,timestamptz,timestamptz,timestamptz,timestamptz,boolean,bigint)
  from public,anon;
grant execute on function public.set_physiology_sleep_override(uuid,uuid,timestamptz,timestamptz,timestamptz,timestamptz,boolean,bigint)
  to authenticated;

create function public.continue_legacy_physiology_sleep_override(p_id uuid,p_device uuid,
  p_original_start timestamptz,p_original_end timestamptz,p_start timestamptz,p_end timestamptz,
  p_tombstone boolean,p_expected_revision bigint,p_legacy_revision text)
returns bigint language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); legacy record;
begin
  if u is null then raise exception 'owned legacy boundary required' using errcode='42501'; end if;
  if p_expected_revision is distinct from 0 or p_legacy_revision is null or p_legacy_revision !~ '^[a-f0-9]{64}$' then
    raise exception 'legacy source revision required' using errcode='22023';
  end if;
  -- Legacy DML takes row locks before its revision trigger takes the device mutex. Keep that
  -- order here; the parent row lock also serializes a concurrent first sleep_details insert.
  perform 1 from public.sessions s where s.id=p_id and s.user_id=u and s.device_id=p_device
    and s.kind in ('sleep','nap') for update;
  if not found then raise exception 'owned legacy boundary required' using errcode='42501'; end if;
  perform 1 from public.sleep_details d where d.session_id=p_id and d.user_id=u for update;
  perform public.scoring_lock_device(u,p_device);
  select * into legacy from public.physiology_legacy_sleep_boundaries(u,p_device) l where l.id=p_id;
  if not found or legacy.legacy_revision is distinct from p_legacy_revision
      or legacy.original_start_at is distinct from p_original_start or legacy.original_end_at is distinct from p_original_end
      or exists(select 1 from public.physiology_sleep_overrides where id=p_id) then
    raise exception 'legacy source changed or already continued' using errcode='40001';
  end if;
  return public.physiology_write_sleep_override(p_id,p_device,legacy.original_start_at,legacy.original_end_at,
    p_start,p_end,p_tombstone,0);
end $$;
revoke all on function public.continue_legacy_physiology_sleep_override(uuid,uuid,timestamptz,timestamptz,timestamptz,timestamptz,boolean,bigint,text)
  from public,anon;
grant execute on function public.continue_legacy_physiology_sleep_override(uuid,uuid,timestamptz,timestamptz,timestamptz,timestamptz,boolean,bigint,text)
  to authenticated;
