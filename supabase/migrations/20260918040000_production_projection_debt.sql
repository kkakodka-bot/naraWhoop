-- Archive receipts and projection completion are separate durable facts. Additive to 020000.
create table public.noop_projection_debt (
  object_id uuid primary key references public.object_manifests(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null references public.devices(id) on delete cascade,
  state text not null default 'pending' check (state in ('pending','staged','complete')),
  created_at timestamptz not null default clock_timestamp(),
  completed_at timestamptz,
  lease_token uuid,
  lease_until timestamptz,
  failures integer not null default 0,
  not_before timestamptz not null default clock_timestamp(),
  last_error text,
  header jsonb,
  mapped_rows jsonb,
  keep_keys jsonb,
  check ((lease_token is null) = (lease_until is null))
);
create index noop_projection_due on public.noop_projection_debt(not_before,created_at,object_id)
  where state='pending';
create index noop_projection_generation on public.noop_projection_debt
  (user_id,device_id,(header->>'sourceId'),(header->>'stream'),(header->'window'->>'replacementId'))
  where header is not null;
create table public.noop_projection_scan (
  id boolean primary key default true check(id), cursor_id uuid
);
insert into public.noop_projection_scan(id) values(true);

-- Completed windows retain tombstones too: delayed older archives cannot resurrect deletions.
create table public.noop_projection_replacements (
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null references public.devices(id) on delete cascade,
  source_id uuid not null,
  stream text not null,
  replacement_id text not null,
  accepted_at timestamptz not null,
  window_start numeric not null,
  window_end numeric not null check(window_end>window_start),
  primary key(user_id,device_id,source_id,stream,replacement_id)
);
create index noop_projection_replacement_order on public.noop_projection_replacements(user_id,device_id,stream,accepted_at);

create function public.noop_projection_coordinate(p_stream text,p_row jsonb) returns numeric
language sql stable set search_path=pg_catalog,public as $$
  select case when p_stream in ('dailyMetric','journal') then ((p_row->>'day')::date-date '1970-01-01')::numeric*86400
    else extract(epoch from (p_row->>'start_at')::timestamptz) end
$$;

create function public.noop_projection_archive_debt() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if new.format like 'ndjson%' and new.durability_receipt->>'state'='verified_indexed' then
    insert into public.noop_projection_debt(object_id,user_id,device_id,created_at)
      values(new.id,new.user_id,new.device_id,coalesce(new.created_at,clock_timestamp()))
      on conflict(object_id) do nothing;
  end if;
  return new;
end $$;
create trigger noop_projection_archive_debt after insert or update of durability_receipt
  on public.object_manifests for each row execute function public.noop_projection_archive_debt();

-- Bounded upgrade repair also covers already-indexed manifests excluded by intake reconciliation.
-- Keep completed ledger entries: replay after a lost response must never rewrite newer inputs.
create function public.noop_seed_projection_debt(p_limit integer default 16) returns integer
language plpgsql security definer set search_path=pg_catalog,public as $$
declare c uuid; m public.object_manifests; n integer:=0; last_id uuid;
begin
  select cursor_id into c from public.noop_projection_scan where id for update;
  for m in select * from public.object_manifests where format like 'ndjson%'
    and durability_receipt->>'state'='verified_indexed' and status in ('ready','verified')
    and (c is null or id>c) order by id limit greatest(1,least(p_limit,64)) loop
    -- Older ACKs imply completion except for replacement parts still in the durable staging
    -- table. Those parts must be reconstructed along with an unacknowledged completing part.
    insert into public.noop_projection_debt(object_id,user_id,device_id,created_at,state,completed_at)
      values(m.id,m.user_id,m.device_id,m.created_at,
        case when exists(select 1 from public.noop_push_acks a where a.user_id=m.user_id and a.batch_id=m.batch_id)
          and not exists(select 1 from public.noop_push_staging_parts s where s.user_id=m.user_id and s.batch_id=m.batch_id::text)
          then 'complete' else 'pending' end,
        case when exists(select 1 from public.noop_push_acks a where a.user_id=m.user_id and a.batch_id=m.batch_id)
          and not exists(select 1 from public.noop_push_staging_parts s where s.user_id=m.user_id and s.batch_id=m.batch_id::text)
          then clock_timestamp() else null end)
      on conflict(object_id) do nothing;
    n:=n+1; last_id:=m.id;
  end loop;
  update public.noop_projection_scan set cursor_id=last_id where id;
  return n;
end $$;

-- Claim one at a time so later objects do not spend their lease waiting for earlier downloads.
create function public.noop_claim_projection_debt() returns jsonb
language plpgsql security definer set search_path=pg_catalog,public as $$
declare d public.noop_projection_debt; m public.object_manifests;
begin
  select q.* into d from public.noop_projection_debt q join public.object_manifests o on o.id=q.object_id
    where q.state='pending' and q.not_before<=clock_timestamp()
      and (q.lease_until is null or q.lease_until<=clock_timestamp())
      and o.status in ('ready','verified') and o.durability_receipt->>'state'='verified_indexed'
    order by q.not_before,q.created_at,q.object_id for update of q skip locked limit 1;
  if not found then return null; end if;
  update public.noop_projection_debt set lease_token=gen_random_uuid(),lease_until=clock_timestamp()+interval '2 minutes'
    where object_id=d.object_id returning * into d;
  select * into m from public.object_manifests where id=d.object_id;
  return jsonb_build_object('manifest',to_jsonb(m),'leaseToken',d.lease_token);
end $$;

create function public.noop_fail_projection_debt(p_object_id uuid,p_token uuid) returns void
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  update public.noop_projection_debt set failures=least(failures+1,16),last_error='projection_replay_failed',
    not_before=clock_timestamp()+make_interval(secs=>least(3600,10*power(2,least(failures,8)))::integer),
    lease_token=null,lease_until=null
    where object_id=p_object_id and state='pending' and lease_token=p_token;
end $$;

-- Table/column names come from closed registries, never SQL interpolated from an HTTP payload.
-- Row values remain bound JSON. INSERT/UPDATE triggers enqueue scoring in this same transaction.
create function public.noop_apply_projection_rows(p_stream text,p_rows jsonb) returns void
language plpgsql security definer set search_path=pg_catalog,public as $$
declare t text; keys text; cols text; assignments text; changed text; ordering text:='';
begin
  select tab,conf into t,keys from (values
    ('hrSample','noop_hr_samples','user_id,device_id,ts'),
    ('rrInterval','noop_rr_intervals','user_id,device_id,ts,"rrMs",seq'),
    ('event','noop_events','user_id,device_id,ts,kind'),
    ('battery','noop_battery_samples','user_id,device_id,ts'),
    ('spo2Sample','noop_spo2_samples','user_id,device_id,ts'),
    ('skinTempSample','noop_skin_temp_samples','user_id,device_id,ts'),
    ('respSample','noop_resp_samples','user_id,device_id,ts'),
    ('gravitySample','noop_gravity_samples','user_id,device_id,ts'),
    ('dailyMetric','daily_metrics','user_id,day'),('sleepSession','sessions','id'),
    ('workout','sessions','id'),('journal','noop_journal_entries','user_id,device_id,day,question')
  ) registry(stream,tab,conf) where stream=p_stream;
  if t is null or jsonb_typeof(p_rows) is distinct from 'array' then raise exception 'invalid_projection'; end if;
  if jsonb_array_length(p_rows)=0 then return; end if;
  if exists(select 1 from jsonb_array_elements(p_rows) r,jsonb_object_keys(r) k
    where not exists(select 1 from pg_attribute a where a.attrelid=('public.'||t)::regclass
      and a.attname=k and a.attnum>0 and not a.attisdropped and a.attgenerated='')) then
    raise exception 'invalid_projection_column';
  end if;
  select string_agg(format('%I',k),',' order by k),
    string_agg(format('%1$I=excluded.%1$I',k),',' order by k),
    string_agg(format('target.%1$I is distinct from excluded.%1$I',k),' or ' order by k)
    into cols,assignments,changed from (select distinct k from jsonb_array_elements(p_rows) r,jsonb_object_keys(r) k) s;
  -- A delayed archive repair cannot replace a newer accepted correction of the same append key.
  if p_stream in ('hrSample','rrInterval','event','battery','spo2Sample','skinTempSample','respSample','gravitySample') then
    ordering := ' and coalesce((select created_at from public.noop_push_reservations where user_id=target.user_id and batch_id=target.batch_id),''-infinity''::timestamptz)
      <= (select created_at from public.noop_push_reservations where user_id=excluded.user_id and batch_id=excluded.batch_id)';
  end if;
  execute format('insert into public.%1$I as target (%2$s) select %2$s from jsonb_populate_recordset(null::public.%1$I,$1)
    on conflict (%3$s) do update set %4$s where (%5$s)%6$s',t,cols,keys,assignments,changed,ordering) using p_rows;
end $$;

create function public.noop_commit_push_projection(p_object_id uuid,p_body_sha256 text,p_header jsonb,
  p_rows jsonb,p_keep_keys jsonb,p_token uuid default null) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public as $$
<<settlement>>
declare m public.object_manifests; d public.noop_projection_debt; r public.noop_push_reservations;
  ack jsonb; rows_to_apply jsonb:=p_rows; keys_to_keep jsonb:=p_keep_keys; w jsonb; part_count integer;
  stream text:=p_header->>'stream'; generation text; source text; window_identity jsonb; g record;
  generation_at timestamptz; window_start numeric; window_end numeric; later_windows nummultirange;
begin
  select * into m from public.object_manifests where id=p_object_id;
  if not found or m.status not in ('ready','verified') or m.format not like 'ndjson%'
    or m.durability_receipt->>'state' is distinct from 'verified_indexed'
    or m.durability_receipt->>'contentSha256' is distinct from p_body_sha256
    or m.batch_id::text is distinct from p_header->>'batchId' or m.source_id::text is distinct from p_header->>'sourceId'
    or m.object_kind is distinct from stream or m.sample_count is distinct from (p_header->>'recordCount')::bigint
    or not exists(select 1 from public.devices where id=m.device_id and user_id=m.user_id)
    or not exists(select 1 from public.noop_signal_windows where object_id=m.id and object_key=m.object_key) then
    raise exception 'projection_archive_mismatch';
  end if;
  -- Same ordering as receipt publication's scoring trigger; serializes source-window settlement.
  perform pg_advisory_xact_lock(hashtextextended('scoring-inputs-v2:'||m.user_id,0));
  select * into r from public.noop_push_reservations where user_id=m.user_id and batch_id=m.batch_id for update;
  if not found or r.body_sha256<>p_body_sha256 or r.device_id<>m.device_id then raise exception 'batch_id_conflict'; end if;
  insert into public.noop_projection_debt(object_id,user_id,device_id,created_at)
    values(m.id,m.user_id,m.device_id,m.created_at) on conflict do nothing;
  select * into d from public.noop_projection_debt where object_id=m.id for update;
  if d.state in ('complete','staged') then
    select a.ack into ack from public.noop_push_acks a where a.user_id=m.user_id and a.batch_id=m.batch_id;
    if ack is not null then
      delete from public.noop_push_wal where user_id=m.user_id and batch_id=m.batch_id;
      return ack;
    end if;
  end if;
  if p_token is not null and (d.lease_token is distinct from p_token or d.lease_until<=clock_timestamp()) then
    raise exception 'projection_lease_lost';
  end if;
  if jsonb_typeof(p_rows) is distinct from 'array' or jsonb_typeof(p_keep_keys) is distinct from 'array'
    or exists(select 1 from jsonb_array_elements(p_rows) x where x->>'user_id' is distinct from m.user_id::text
      or coalesce(x->>'device_id',x->>'source_device_id') is distinct from m.device_id::text) then raise exception 'projection_owner_mismatch'; end if;
  if p_header->>'delivery'='replace_window' then
    w:=p_header->'window'; generation:=w->>'replacementId'; source:=p_header->>'sourceId';
    window_identity:=w-'part';
    if generation is null or coalesce((w->>'part')::integer,0)<1 or coalesce((w->>'parts')::integer,0)<1
      or (w->>'part')::integer>(w->>'parts')::integer or (w->>'parts')::integer>128
      or coalesce(w->>'selector','') not in ('day','startTs') or w->>'startInclusive' is null
      or w->>'endExclusive' is null then raise exception 'invalid_window'; end if;
    if (stream in ('dailyMetric','journal') and w->>'selector'<>'day')
      or (stream in ('sleepSession','workout') and w->>'selector'<>'startTs')
      or stream not in ('dailyMetric','journal','sleepSession','workout') then raise exception 'invalid_window'; end if;
    window_start:=case when w->>'selector'='day' then ((w->>'startInclusive')::date-date '1970-01-01')::numeric*86400
      else (w->>'startInclusive')::numeric end;
    window_end:=case when w->>'selector'='day' then ((w->>'endExclusive')::date-date '1970-01-01')::numeric*86400
      else (w->>'endExclusive')::numeric end;
    if window_end<=window_start or exists(select 1 from jsonb_array_elements(p_rows) x
      where public.noop_projection_coordinate(stream,x) is null
        or not(public.noop_projection_coordinate(stream,x)<@numrange(window_start,window_end,'[)'))) then
      raise exception 'projection_outside_window';
    end if;
    for g in select object_id,header from public.noop_projection_debt where user_id=m.user_id and device_id=m.device_id
      and header->>'stream'=stream and header->>'sourceId'=source and header->'window'->>'replacementId'=generation loop
      if ((g.header->'window')-'part') is distinct from window_identity then raise exception 'replacement_window_conflict'; end if;
      if g.object_id<>m.id and g.header->'window'->>'part'=w->>'part' then raise exception 'replacement_part_conflict'; end if;
    end loop;
    update public.noop_projection_debt set header=p_header,mapped_rows=p_rows,keep_keys=p_keep_keys where object_id=m.id;
    select count(*) into part_count from public.noop_projection_debt where user_id=m.user_id and device_id=m.device_id
      and header->>'stream'=stream and header->>'sourceId'=source and header->'window'->>'replacementId'=generation;
    if part_count=(w->>'parts')::integer then
      if (select sum(pg_column_size(mapped_rows)) from public.noop_projection_debt where user_id=m.user_id and device_id=m.device_id
          and header->>'stream'=stream and header->>'sourceId'=source and header->'window'->>'replacementId'=generation)>33554432 then
        raise exception 'replacement_projection_too_large';
      end if;
      select coalesce(jsonb_agg(x.row order by (q.header->'window'->>'part')::integer,x.ord),'[]') into rows_to_apply
        from public.noop_projection_debt q cross join lateral jsonb_array_elements(q.mapped_rows) with ordinality x(row,ord)
        where q.user_id=m.user_id and q.device_id=m.device_id and q.header->>'stream'=stream
          and q.header->>'sourceId'=source and q.header->'window'->>'replacementId'=generation;
      select coalesce(jsonb_agg(x.key),'[]') into keys_to_keep from public.noop_projection_debt q,
        lateral jsonb_array_elements(q.keep_keys) x(key) where q.user_id=m.user_id and q.device_id=m.device_id
          and q.header->>'stream'=stream and q.header->>'sourceId'=source and q.header->'window'->>'replacementId'=generation;
      select min(b.created_at) into generation_at from public.noop_projection_debt q
        join public.noop_push_reservations b on b.user_id=q.user_id and b.batch_id=q.object_id
        where q.user_id=m.user_id and q.device_id=m.device_id and q.header->>'stream'=settlement.stream
          and q.header->>'sourceId'=source and q.header->'window'->>'replacementId'=generation;
      select coalesce(range_agg(numrange(c.window_start,c.window_end,'[)')),'{}'::nummultirange) into later_windows
        from public.noop_projection_replacements c where c.user_id=m.user_id and c.device_id=m.device_id and c.stream=settlement.stream
          and (c.accepted_at,c.replacement_id)>(generation_at,generation)
          and c.window_start<settlement.window_end and c.window_end>settlement.window_start;
      select coalesce(jsonb_agg(x),'[]') into rows_to_apply from jsonb_array_elements(rows_to_apply) x
        where not(public.noop_projection_coordinate(stream,x)<@later_windows);
      perform public.noop_apply_projection_rows(stream,rows_to_apply);
      if stream='dailyMetric' then
        delete from public.daily_metrics where user_id=m.user_id and source_device_id=m.device_id
          and day>=(w->>'startInclusive')::date and day<(w->>'endExclusive')::date and not (keys_to_keep ? day::text)
          and not((day-date '1970-01-01')::numeric*86400<@later_windows);
      elsif stream='journal' then
        delete from public.noop_journal_entries where user_id=m.user_id and device_id=m.device_id
          and day>=(w->>'startInclusive')::date and day<(w->>'endExclusive')::date and not (keys_to_keep ? (day::text||'|'||question))
          and not((day-date '1970-01-01')::numeric*86400<@later_windows);
      elsif stream in ('sleepSession','workout') then
        delete from public.sessions where user_id=m.user_id and device_id=m.device_id
          and kind=any(case when stream='sleepSession' then array['sleep'] else array['workout','manual_workout'] end)
          and start_at>=to_timestamp((w->>'startInclusive')::double precision)
          and start_at<to_timestamp((w->>'endExclusive')::double precision) and not(keys_to_keep ? external_id)
          and not(extract(epoch from start_at)<@later_windows);
      else raise exception 'unsupported_projection'; end if;
      insert into public.noop_projection_replacements(user_id,device_id,source_id,stream,replacement_id,accepted_at,window_start,window_end)
        values(m.user_id,m.device_id,source::uuid,stream,generation,generation_at,window_start,window_end) on conflict do nothing;
      update public.noop_projection_debt set state='complete',completed_at=clock_timestamp(),mapped_rows=null,keep_keys=null,
        lease_token=null,lease_until=null where user_id=m.user_id and device_id=m.device_id and header->>'stream'=stream
          and header->>'sourceId'=source and header->'window'->>'replacementId'=generation;
      delete from public.noop_push_staging_parts where user_id=m.user_id and replacement_id=generation
        and scope=m.user_id::text||'|'||source||'|'||(p_header->>'deviceId')||'|'||stream;
    else
      update public.noop_projection_debt set state='staged',lease_token=null,lease_until=null where object_id=m.id;
    end if;
  elsif p_header->>'delivery'='append' then
    perform public.noop_apply_projection_rows(stream,p_rows);
    update public.noop_projection_debt set state='complete',completed_at=clock_timestamp(),lease_token=null,lease_until=null,
      failures=0,last_error=null where object_id=m.id;
  else raise exception 'unsupported_delivery'; end if;
  ack:=jsonb_build_object('protocolVersion',p_header->>'protocolVersion','batchId',p_header->>'batchId',
    'stream',stream,'deviceId',p_header->>'deviceId','endCursor',p_header->'endCursor',
    'acceptedRows',(p_header->>'recordCount')::integer,'status','accepted','durabilityReceipt',m.durability_receipt);
  perform public.noop_push_save_ack(m.user_id,m.batch_id,p_body_sha256,ack);
  delete from public.noop_push_wal where user_id=m.user_id and batch_id=m.batch_id;
  return ack;
end $$;

create view public.noop_projection_metrics as select
  count(*) filter(where state='pending') as pending,
  count(*) filter(where state='staged') as waiting_for_parts,
  count(*) filter(where state='pending' and lease_until>clock_timestamp()) as running,
  count(*) filter(where state='pending' and not_before>clock_timestamp()) as backing_off,
  coalesce(extract(epoch from clock_timestamp()-min(created_at) filter(where state<>'complete')),0) as oldest_pending_seconds
  from public.noop_projection_debt;
revoke all on public.noop_projection_metrics from public,anon,authenticated;
grant select on public.noop_projection_metrics to service_role;

do $$ declare t text; f record; begin
  foreach t in array array['noop_projection_debt','noop_projection_scan','noop_projection_replacements'] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('revoke all on public.%I from public,anon,authenticated',t);
    execute format('grant all on public.%I to service_role',t);
    execute format('create policy projection_service on public.%I for all to service_role using(true) with check(true)',t);
  end loop;
  for f in select oid::regprocedure sig from pg_proc where pronamespace='public'::regnamespace and proname in
    ('noop_projection_archive_debt','noop_seed_projection_debt','noop_claim_projection_debt','noop_fail_projection_debt',
     'noop_apply_projection_rows','noop_commit_push_projection','noop_projection_coordinate') loop
    execute format('revoke all on function %s from public,anon,authenticated',f.sig);
    execute format('grant execute on function %s to service_role',f.sig);
  end loop;
end $$;
