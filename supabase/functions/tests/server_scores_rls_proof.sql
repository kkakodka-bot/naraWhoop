-- Phase 4 RLS proof: run against a database with migration 20260917180000 applied.
-- Requires two auth.users rows (user_a, user_b) and one server_daily_scores row for user_a.
--
-- Example (replace UUIDs):
--   \set user_a '7f2c9a10-4b3e-4d8a-9c11-00000000f001'
--   \set user_b '7f2c9a10-4b3e-4d8a-9c11-00000000f002'
--
-- As user_a (SET request.jwt.claim.sub = :'user_a'; SET role authenticated;):
--   SELECT count(*) FROM server_daily_scores WHERE user_id = :'user_a'::uuid;  -- expect >= 1
--   SELECT count(*) FROM server_daily_scores WHERE user_id = :'user_b'::uuid;  -- expect 0 (RLS)
--
-- As anon (SET role anon;):
--   SELECT count(*) FROM server_daily_scores;  -- expect permission denied
--
-- service_role can still write (scorer unchanged):
--   SET role service_role;
--   -- engine_ingest_scored / INSERT still succeed

-- Minimal automated check when jwt claims are set (psql -v ON_ERROR_STOP=1):
begin;
  set local role authenticated;
  -- User A sees own row
  perform set_config('request.jwt.claim.sub', :'user_a', true);
  if not exists (
    select 1 from public.server_daily_scores
    where user_id = :'user_a'::uuid and algorithm_version = 'frwhoop-server-1'
  ) then
    raise exception 'user_a should see own server_daily_scores row';
  end if;
  -- User A cannot see user B rows
  perform set_config('request.jwt.claim.sub', :'user_a', true);
  if exists (
    select 1 from public.server_daily_scores where user_id = :'user_b'::uuid
  ) then
    raise exception 'user_a must not read user_b server_daily_scores (RLS leak)';
  end if;
  -- User B cannot see user A rows
  perform set_config('request.jwt.claim.sub', :'user_b', true);
  if exists (
    select 1 from public.server_daily_scores where user_id = :'user_a'::uuid
  ) then
    raise exception 'user_b must not read user_a server_daily_scores (RLS leak)';
  end if;
rollback;
