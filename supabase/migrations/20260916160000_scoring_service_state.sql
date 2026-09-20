-- Phase 3: server scoring state — shadow score tables, durable work queue, liveness heartbeat.
--
-- Contract (locked decisions):
--   * Server scores land in server_daily_scores / server_sleep_nights keyed by algorithm_version.
--     The scorer's writes NEVER touch device-pushed daily_metrics / sleep_nights rows, and one
--     algorithm version's rows never touch another's. Reprocessing a day replaces THIS version's
--     rows only (idempotent).
--   * Locked server scope: RR/HRV pipeline + sleep staging. The shadow tables carry NO
--     charge/effort/rest (or steps/kcal/vo2max/stress) columns, and engine_ingest_scored reads only
--     the scoped keys — a payload carrying Charge/Effort/Rest has them dropped at the contract.
--   * All service state is durable here (work queue + watermark + heartbeat): kill -9 the
--     container at any point and it resumes cleanly.
--   * Machine tables: service_role only. User-facing read policies arrive with the app read path
--     (Phase 4), not here.

-- ─────────────────────────────────────────────────────────────────────────────
-- Shadow score tables (canonical server scores pre-promotion; Phase 6 decides promotion)
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists public.server_daily_scores (
  user_id uuid not null references auth.users(id) on delete cascade,
  day date not null,
  algorithm_version text not null,
  source_device_id uuid,
  -- RR/HRV pipeline
  hrv_rmssd_ms numeric,
  hrv_sdnn_ms numeric,
  resting_hr_bpm numeric,
  overnight_hr_bpm numeric,
  readiness_level text,
  -- sleep staging (day rollup)
  sleep_total_min numeric,
  sleep_in_bed_min numeric,
  sleep_awake_min numeric,
  sleep_light_min numeric,
  sleep_deep_min numeric,
  sleep_rem_min numeric,
  sleep_efficiency numeric,
  sleep_onset_at timestamptz,
  wake_onset_at timestamptz,
  disturbances integer,
  -- sleep-adjacent physiology (baseline/readiness inputs)
  resp_rate_bpm numeric,
  skin_temp_c numeric,
  skin_temp_dev_c numeric,
  spo2_pct numeric,
  confidence jsonb not null default '{}'::jsonb,
  provenance jsonb not null default '{}'::jsonb,
  computed_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, day, algorithm_version)
);

create index if not exists server_daily_scores_user_day_idx
  on public.server_daily_scores (user_id, day desc);

drop trigger if exists server_daily_scores_updated_at on public.server_daily_scores;
create trigger server_daily_scores_updated_at
  before update on public.server_daily_scores
  for each row execute function public.set_updated_at();

create table if not exists public.server_sleep_nights (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid,
  period_day date not null,
  start_at timestamptz not null,
  end_at timestamptz not null,
  is_nap boolean not null default false,
  in_bed_min numeric,
  asleep_min numeric,
  awake_min numeric,
  light_min numeric,
  deep_min numeric,
  rem_min numeric,
  efficiency numeric,
  overnight_hr_bpm numeric,
  resting_hr_bpm numeric,
  hrv_rmssd_ms numeric,
  resp_rate_bpm numeric,
  disturbances integer,
  stages jsonb not null default '[]'::jsonb,
  hypnogram jsonb not null default '[]'::jsonb,
  algorithm_version text not null,
  computed_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, start_at, algorithm_version)
);

create index if not exists server_sleep_nights_user_day_idx
  on public.server_sleep_nights (user_id, period_day desc);

drop trigger if exists server_sleep_nights_updated_at on public.server_sleep_nights;
create trigger server_sleep_nights_updated_at
  before update on public.server_sleep_nights
  for each row execute function public.set_updated_at();

-- ─────────────────────────────────────────────────────────────────────────────
-- Durable work queue + discovery watermark
-- ─────────────────────────────────────────────────────────────────────────────

-- One row per (user, local day) that has seen ingest. dirty_at is the newest arrival that
-- (re)enqueued the day; claimed_at doubles as the claim token and the lease start; done_at marks
-- the last completed score covering dirty_at. A row is due when:
--   done_at is null and (claimed_at is null or claimed_at older than the lease) and attempts < cap.
-- New ingest while a run is in flight bumps dirty_at, so the completion update (guarded on
-- dirty_at <= claim) refuses to mark the day done and it is re-scored — no lost arrivals.
create table if not exists public.scoring_work_items (
  user_id uuid not null references auth.users(id) on delete cascade,
  day date not null,
  dirty_at timestamptz not null default now(),
  claimed_at timestamptz,
  done_at timestamptz,
  attempts integer not null default 0,
  last_error text,
  last_duration_ms integer,
  created_at timestamptz not null default now(),
  primary key (user_id, day)
);

create index if not exists scoring_work_items_due_idx
  on public.scoring_work_items (dirty_at asc)
  where done_at is null;

-- Singleton discovery high-water mark. Advanced only AFTER a discovery upsert commits, and always
-- to (read instant − overlap margin), so rows from ingest transactions still in flight at read
-- time are re-discovered on the next poll (idempotent; the work-item dirty_at guard dedupes).
create table if not exists public.scorer_state (
  id integer primary key check (id = 1),
  discovery_watermark timestamptz not null default 'epoch',
  updated_at timestamptz not null default now()
);

insert into public.scorer_state (id) values (1) on conflict (id) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- Liveness heartbeat (singleton row; the durable evidence of scorer life)
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists public.scoring_service_heartbeats (
  id integer primary key check (id = 1),
  version text not null default 'frwhoop-server-1',
  started_at timestamptz not null default now(),
  last_poll_at timestamptz,
  last_score_at timestamptz,
  last_error text,
  meta jsonb not null default '{}'::jsonb
);

insert into public.scoring_service_heartbeats (id, version)
values (1, 'frwhoop-server-1')
on conflict (id) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- RLS: machine-only (service_role). No anon/authenticated access in this phase.
-- ─────────────────────────────────────────────────────────────────────────────

alter table public.server_daily_scores enable row level security;
alter table public.server_sleep_nights enable row level security;
alter table public.scoring_work_items enable row level security;
alter table public.scorer_state enable row level security;
alter table public.scoring_service_heartbeats enable row level security;

create policy "server_daily_scores_service"
  on public.server_daily_scores for all
  using (auth.role() = 'service_role')
  with check (auth.role() = 'service_role');

create policy "server_sleep_nights_service"
  on public.server_sleep_nights for all
  using (auth.role() = 'service_role')
  with check (auth.role() = 'service_role');

create policy "scoring_work_items_service"
  on public.scoring_work_items for all
  using (auth.role() = 'service_role')
  with check (auth.role() = 'service_role');

create policy "scorer_state_service"
  on public.scorer_state for all
  using (auth.role() = 'service_role')
  with check (auth.role() = 'service_role');

create policy "scoring_heartbeats_service"
  on public.scoring_service_heartbeats for all
  using (auth.role() = 'service_role')
  with check (auth.role() = 'service_role');

-- ─────────────────────────────────────────────────────────────────────────────
-- engine_ingest_scored: the scorer's canonical write path.
-- Same envelope shape as engine_ingest_upsert ({user_id, algorithm_version, daily_metrics[],
-- sleep_nights[]}) but writes ONLY the version-scoped shadow tables and reads ONLY the locked-scope
-- keys. Charge/Effort/Rest (or any unscoped key) in the payload is dropped here, by construction.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.engine_ingest_scored(p_secret text, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid;
  v_version text;
  r jsonb;
  n_daily integer := 0;
  n_nights integer := 0;
begin
  perform internal.assert_ingest_secret(p_secret);
  v_user := nullif(p_payload->>'user_id', '')::uuid;
  if v_user is null then
    raise exception 'user_id required';
  end if;
  v_version := nullif(p_payload->>'algorithm_version', '');
  if v_version is null then
    raise exception 'algorithm_version required';
  end if;

  for r in select value from jsonb_array_elements(coalesce(p_payload->'daily_metrics', '[]'::jsonb))
  loop
    insert into public.server_daily_scores (
      user_id, day, algorithm_version, source_device_id,
      hrv_rmssd_ms, hrv_sdnn_ms, resting_hr_bpm, overnight_hr_bpm, readiness_level,
      sleep_total_min, sleep_in_bed_min, sleep_awake_min,
      sleep_light_min, sleep_deep_min, sleep_rem_min,
      sleep_efficiency, sleep_onset_at, wake_onset_at, disturbances,
      resp_rate_bpm, skin_temp_c, skin_temp_dev_c, spo2_pct,
      confidence, provenance, computed_at
    ) values (
      v_user,
      (r->>'day')::date,
      v_version,
      nullif(r->>'source_device_id', '')::uuid,
      nullif(r->>'hrv_rmssd_ms', '')::numeric,
      nullif(r->>'hrv_sdnn_ms', '')::numeric,
      nullif(r->>'resting_hr_bpm', '')::numeric,
      nullif(r->>'overnight_hr_bpm', '')::numeric,
      nullif(r->>'readiness_level', ''),
      nullif(r->>'sleep_total_min', '')::numeric,
      nullif(r->>'sleep_in_bed_min', '')::numeric,
      nullif(r->>'sleep_awake_min', '')::numeric,
      nullif(r->>'sleep_light_min', '')::numeric,
      nullif(r->>'sleep_deep_min', '')::numeric,
      nullif(r->>'sleep_rem_min', '')::numeric,
      nullif(r->>'sleep_efficiency', '')::numeric,
      nullif(r->>'sleep_onset_at', '')::timestamptz,
      nullif(r->>'wake_onset_at', '')::timestamptz,
      nullif(r->>'disturbances', '')::integer,
      nullif(r->>'resp_rate_bpm', '')::numeric,
      nullif(r->>'skin_temp_c', '')::numeric,
      nullif(r->>'skin_temp_dev_c', '')::numeric,
      nullif(r->>'spo2_pct', '')::numeric,
      coalesce(r->'confidence', '{}'::jsonb),
      coalesce(r->'provenance', '{}'::jsonb),
      coalesce(nullif(r->>'computed_at', '')::timestamptz, now())
    )
    on conflict (user_id, day, algorithm_version) do update set
      source_device_id = excluded.source_device_id,
      hrv_rmssd_ms = excluded.hrv_rmssd_ms,
      hrv_sdnn_ms = excluded.hrv_sdnn_ms,
      resting_hr_bpm = excluded.resting_hr_bpm,
      overnight_hr_bpm = excluded.overnight_hr_bpm,
      readiness_level = excluded.readiness_level,
      sleep_total_min = excluded.sleep_total_min,
      sleep_in_bed_min = excluded.sleep_in_bed_min,
      sleep_awake_min = excluded.sleep_awake_min,
      sleep_light_min = excluded.sleep_light_min,
      sleep_deep_min = excluded.sleep_deep_min,
      sleep_rem_min = excluded.sleep_rem_min,
      sleep_efficiency = excluded.sleep_efficiency,
      sleep_onset_at = excluded.sleep_onset_at,
      wake_onset_at = excluded.wake_onset_at,
      disturbances = excluded.disturbances,
      resp_rate_bpm = excluded.resp_rate_bpm,
      skin_temp_c = excluded.skin_temp_c,
      skin_temp_dev_c = excluded.skin_temp_dev_c,
      spo2_pct = excluded.spo2_pct,
      confidence = excluded.confidence,
      provenance = excluded.provenance,
      computed_at = excluded.computed_at;
    n_daily := n_daily + 1;
  end loop;

  for r in select value from jsonb_array_elements(coalesce(p_payload->'sleep_nights', '[]'::jsonb))
  loop
    insert into public.server_sleep_nights (
      user_id, device_id, period_day, start_at, end_at, is_nap,
      in_bed_min, asleep_min, awake_min, light_min, deep_min, rem_min,
      efficiency, overnight_hr_bpm, resting_hr_bpm, hrv_rmssd_ms,
      resp_rate_bpm, disturbances, stages, hypnogram,
      algorithm_version, computed_at
    ) values (
      v_user,
      nullif(r->>'device_id', '')::uuid,
      (r->>'period_day')::date,
      (r->>'start_at')::timestamptz,
      (r->>'end_at')::timestamptz,
      coalesce((r->>'is_nap')::boolean, false),
      nullif(r->>'in_bed_min', '')::numeric,
      nullif(r->>'asleep_min', '')::numeric,
      nullif(r->>'awake_min', '')::numeric,
      nullif(r->>'light_min', '')::numeric,
      nullif(r->>'deep_min', '')::numeric,
      nullif(r->>'rem_min', '')::numeric,
      nullif(r->>'efficiency', '')::numeric,
      nullif(r->>'overnight_hr_bpm', '')::numeric,
      nullif(r->>'resting_hr_bpm', '')::numeric,
      nullif(r->>'hrv_rmssd_ms', '')::numeric,
      nullif(r->>'resp_rate_bpm', '')::numeric,
      nullif(r->>'disturbances', '')::integer,
      coalesce(r->'stages', '[]'::jsonb),
      coalesce(r->'hypnogram', '[]'::jsonb),
      v_version,
      coalesce(nullif(r->>'computed_at', '')::timestamptz, now())
    )
    on conflict (user_id, start_at, algorithm_version) do update set
      device_id = excluded.device_id,
      period_day = excluded.period_day,
      end_at = excluded.end_at,
      is_nap = excluded.is_nap,
      in_bed_min = excluded.in_bed_min,
      asleep_min = excluded.asleep_min,
      awake_min = excluded.awake_min,
      light_min = excluded.light_min,
      deep_min = excluded.deep_min,
      rem_min = excluded.rem_min,
      efficiency = excluded.efficiency,
      overnight_hr_bpm = excluded.overnight_hr_bpm,
      resting_hr_bpm = excluded.resting_hr_bpm,
      hrv_rmssd_ms = excluded.hrv_rmssd_ms,
      resp_rate_bpm = excluded.resp_rate_bpm,
      disturbances = excluded.disturbances,
      stages = excluded.stages,
      hypnogram = excluded.hypnogram,
      computed_at = excluded.computed_at;
    n_nights := n_nights + 1;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'user_id', v_user,
    'algorithm_version', v_version,
    'daily_metrics', n_daily,
    'sleep_nights', n_nights
  );
end;
$$;

revoke all on function public.engine_ingest_scored(text, jsonb) from public, anon, authenticated;
grant execute on function public.engine_ingest_scored(text, jsonb) to service_role;

comment on table public.server_daily_scores is
  'Phase 3: canonical server-computed daily scores, keyed by algorithm_version. Never written by device push; never overwrites daily_metrics.';
comment on table public.server_sleep_nights is
  'Phase 3: canonical server-computed sleep nights, keyed by algorithm_version. Never written by device push; never overwrites sleep_nights.';
comment on table public.scoring_work_items is
  'Phase 3: durable score-on-arrival work queue (one row per user/local-day with new ingest).';
comment on table public.scorer_state is
  'Phase 3: singleton discovery watermark for the scoring poller.';
comment on table public.scoring_service_heartbeats is
  'Phase 3: singleton heartbeat row for the JVM scoring container.';
comment on function public.engine_ingest_scored(text, jsonb) is
  'Phase 3: scorer write path. Version-scoped shadow tables only; locked-scope keys only; idempotent per (user, day/start_at, algorithm_version).';
