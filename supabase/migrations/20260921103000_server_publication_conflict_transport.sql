-- A stale lease cannot become valid by retrying the same HTTP transaction. PostgREST
-- retries SQLSTATE 40001 internally; exposing the domain fence with that code can keep
-- a request busy forever. Preserve the private SQL fence, translate only publication
-- transport failures to an explicit HTTP 409, and roll back all attempted writes.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

alter function public.engine_publish_legacy_fenced(text,jsonb) set schema internal;
alter function public.engine_publish_physiology(text,jsonb) set schema internal;
revoke all on function internal.engine_publish_legacy_fenced(text,jsonb),
  internal.engine_publish_physiology(text,jsonb) from public,anon,authenticated,service_role;

create function public.engine_publish_legacy_fenced(p_secret text,p_payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
  return internal.engine_publish_legacy_fenced(p_secret,p_payload);
exception when serialization_failure then
  raise exception 'stale scoring lease or input revision' using errcode='PT409';
end $$;

create function public.engine_publish_physiology(p_secret text,p_payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
  return internal.engine_publish_physiology(p_secret,p_payload);
exception when serialization_failure then
  raise exception 'stale scoring lease or input revision' using errcode='PT409';
end $$;

revoke all on function public.engine_publish_legacy_fenced(text,jsonb),
  public.engine_publish_physiology(text,jsonb) from public,anon,authenticated;
grant execute on function public.engine_publish_legacy_fenced(text,jsonb),
  public.engine_publish_physiology(text,jsonb) to service_role;
commit;
