begin;
set local lock_timeout='5s';
set local statement_timeout='60s';

create table public.compute_account_sources (
 source_id uuid primary key,
 user_id uuid not null references auth.users on delete cascade,
 created_at timestamptz not null default now(),
 revoked_at timestamptz
);
alter table public.compute_account_sources enable row level security;
revoke all on public.compute_account_sources from public,anon,authenticated;
grant select,insert on public.compute_account_sources to service_role;
create function public.register_account_compute_source(p_user uuid,p_source uuid)
returns boolean language plpgsql security invoker set search_path=pg_catalog,public as $$
begin
 if auth.role() is distinct from 'service_role' then raise exception 'service required' using errcode='42501'; end if;
 if exists(select 1 from noop_app_installations where source_id=p_source and (user_id<>p_user or revoked_at is not null)) then
   raise exception 'source binding conflict' using errcode='42501'; end if;
 insert into compute_account_sources(user_id,source_id) values(p_user,p_source) on conflict do nothing;
 if not exists(select 1 from compute_account_sources where user_id=p_user and source_id=p_source and revoked_at is null) then
   raise exception 'source binding conflict' using errcode='42501'; end if;
 return true;
end $$;
revoke all on function public.register_account_compute_source(uuid,uuid) from public,anon,authenticated;
grant execute on function public.register_account_compute_source(uuid,uuid) to service_role;

create table public.compute_session_requests (
 id uuid primary key,
 user_id uuid not null references auth.users on delete cascade,
 device_id uuid not null references public.devices on delete cascade,
 source_id uuid not null,
 family text not null references public.compute_family_policy,
 session_id uuid not null,
 event_start timestamptz not null,
 event_end timestamptz,
 timezone_id text not null,
 input_revision bigint not null check(input_revision>=0),
 algorithm_version text not null check(algorithm_version='vps-only-1'),
 configuration_version text not null check(configuration_version='vps-only-1'),
 consent boolean not null,
 expires_at timestamptz,
 request jsonb not null,
 created_at timestamptz not null default now(),
 check(event_end is null or event_end>=event_start)
);
create table public.compute_session_results (
 revision bigint generated always as identity primary key,
 request_id uuid not null unique references public.compute_session_requests on delete cascade,
 user_id uuid not null references auth.users on delete cascade,
 device_id uuid not null references public.devices on delete cascade,
 result jsonb not null,
 computed_at timestamptz not null default now()
);
alter table public.compute_session_requests enable row level security;
alter table public.compute_session_results enable row level security;
create policy compute_request_owner on public.compute_session_requests for select to authenticated using(user_id=auth.uid());
create policy compute_result_owner on public.compute_session_results for select to authenticated using(user_id=auth.uid());
grant select on public.compute_session_requests,public.compute_session_results to authenticated,service_role;
grant insert on public.compute_session_requests,public.compute_session_results to service_role;
grant usage,select on sequence public.compute_session_results_revision_seq to service_role;

create function public.submit_compute_session_request(p_user uuid,p_device uuid,p_source uuid,p_request jsonb)
returns jsonb language plpgsql security invoker set search_path=pg_catalog,public as $$
declare prior compute_session_requests; request_id uuid; family text;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'service required' using errcode='42501'; end if;
 if not exists(select 1 from devices where id=p_device and user_id=p_user) or not (
   exists(select 1 from noop_app_installations where user_id=p_user and source_id=p_source and revoked_at is null)
   or exists(select 1 from compute_account_sources where user_id=p_user and source_id=p_source and revoked_at is null)) then
   raise exception 'owned source/device required' using errcode='42501'; end if;
 request_id:=(p_request->>'id')::uuid; family:=p_request->>'family';
 if request_id is null or not exists(select 1 from pg_timezone_names where name=p_request->>'timezone_id') then
   raise exception 'invalid request identity/timezone' using errcode='22023'; end if;
 if family in ('live_coaching','stress_events','live_workout') and (
   nullif(p_request->>'expires_at','') is null or
   (p_request->>'expires_at')::timestamptz>(p_request->>'event_start')::timestamptz+interval '5 minutes' or
   (p_request->>'expires_at')::timestamptz<=(p_request->>'event_start')::timestamptz) then
   raise exception 'bounded expiry required' using errcode='22023'; end if;
 insert into compute_session_requests(id,user_id,device_id,source_id,family,session_id,event_start,event_end,
   timezone_id,input_revision,algorithm_version,configuration_version,consent,expires_at,request)
 values(request_id,p_user,p_device,p_source,family,(p_request->>'session_id')::uuid,
   (p_request->>'event_start')::timestamptz,(p_request->>'event_end')::timestamptz,p_request->>'timezone_id',
   (p_request->>'input_revision')::bigint,p_request->>'algorithm_version',p_request->>'configuration_version',
   (p_request->>'consent')::boolean,(p_request->>'expires_at')::timestamptz,p_request)
 on conflict(id) do nothing;
 select * into prior from compute_session_requests where id=request_id;
 if prior.user_id<>p_user or prior.device_id<>p_device or prior.source_id<>p_source or prior.request<>p_request then
   raise sqlstate 'PT409' using message='request_identity_conflict'; end if;
 return jsonb_build_object('request_id',request_id,'state','processing','result',null);
end $$;
revoke all on function public.submit_compute_session_request(uuid,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.submit_compute_session_request(uuid,uuid,uuid,jsonb) to service_role;

create function public.read_compute_session_result(p_user uuid,p_device uuid,p_source uuid,p_request uuid)
returns jsonb language plpgsql stable security invoker set search_path=pg_catalog,public as $$
declare r compute_session_requests; result jsonb;
begin
 if auth.role() is distinct from 'service_role' then raise exception 'service required' using errcode='42501'; end if;
 select * into r from compute_session_requests where id=p_request and user_id=p_user and device_id=p_device and source_id=p_source;
 if r.id is null then raise sqlstate 'PT404' using message='request_not_found'; end if;
 select s.result||jsonb_build_object('result_revision','session:'||s.revision,'computed_at',s.computed_at)
 into result from compute_session_results s where s.request_id=p_request;
 if result is not null and r.expires_at<=now() then
   result:=result||jsonb_build_object('status','unavailable','reason','decision_expired',
     'values',(select jsonb_object_agg(m,null) from jsonb_array_elements_text(result->'metrics') m),'freshness','expired'); end if;
 return jsonb_build_object('request_id',p_request,'state',coalesce(result->>'status','processing'),'result',result);
end $$;
revoke all on function public.read_compute_session_result(uuid,uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.read_compute_session_result(uuid,uuid,uuid,uuid) to service_role;

-- Independent bounded worker transaction: lock one pending request and publish once.
-- No client-requested algorithm can assert qualification; until a reviewed session
-- producer is selected these are immutable explicit abstentions, not fake scores.
create function public.process_compute_session_request()
returns boolean language plpgsql security invoker set search_path=pg_catalog,public as $$
declare r compute_session_requests; p compute_family_policy; vals jsonb; status text; reason text;
begin
 if auth.role() is distinct from 'service_role' and current_user not in ('postgres','supabase_admin') then
   raise exception 'worker required' using errcode='42501'; end if;
 select q.* into r from compute_session_requests q where not exists(select 1 from compute_session_results s where s.request_id=q.id)
   order by q.created_at,q.id for update skip locked limit 1;
 if r.id is null then return false; end if;
 select * into p from compute_family_policy where family=r.family;
 select jsonb_object_agg(m,null) into vals from unnest(p.metrics) m;
 status:=p.unavailable_status; reason:=p.unavailable_reason;
 if not r.consent then status:='unavailable'; reason:='consent_required';
 elsif r.expires_at<=now() then status:='unavailable'; reason:='decision_expired'; end if;
 insert into compute_session_results(request_id,user_id,device_id,result) values(r.id,r.user_id,r.device_id,
   jsonb_build_object('owner','server','metrics',p.metrics,'family',r.family,'status',status,'reason',reason,
     'input_revision',r.input_revision,'algorithm_version',r.algorithm_version,'configuration_version',r.configuration_version,
     'model_version',null,'preprocessing_version',null,'quality_version',null,'manifest_hash',null,'feature_manifest_hash',null,
     'canonical_qualification',null,'owner_id',r.user_id,'source_id',r.source_id,'device_id',r.device_id,
     'window',r.session_id,'timezone_id',r.timezone_id,'observed_through',null,
     'freshness',case when r.expires_at<=now() then 'expired' else 'current' end,
     'expires_at',r.expires_at,'decision_id',r.id,'values',vals,
     'details',jsonb_build_object('event_start',r.event_start,'event_end',r.event_end,'request_id',r.id,
       'input_qualification','not_attested','consent',r.consent))) on conflict(request_id) do nothing;
 return true;
end $$;
revoke all on function public.process_compute_session_request() from public,anon,authenticated;
grant execute on function public.process_compute_session_request() to service_role;
commit;
