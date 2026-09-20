-- Phase 4: authenticated read path for server-computed shadow scores.
-- Users may SELECT their own server_daily_scores / server_sleep_nights rows.
-- get_day_snapshot gains a server_scoring overlay; Realtime publication extended.

-- ── SELECT grants + owner-scoped policies ───────────────────────────────────

grant select on public.server_daily_scores to authenticated;
grant select on public.server_sleep_nights to authenticated;

drop policy if exists server_daily_scores_select_own on public.server_daily_scores;
create policy server_daily_scores_select_own
  on public.server_daily_scores for select to authenticated
  using ((select auth.uid()) = user_id);

drop policy if exists server_sleep_nights_select_own on public.server_sleep_nights;
create policy server_sleep_nights_select_own
  on public.server_sleep_nights for select to authenticated
  using ((select auth.uid()) = user_id);

-- ── server_scoring overlay helper ───────────────────────────────────────────

create or replace function public.server_scoring_for_day(p_user uuid, p_day date)
returns jsonb
language sql
stable
security invoker
set search_path = pg_catalog, public
as $$
  with daily as (
    select
      s.hrv_rmssd_ms,
      s.hrv_sdnn_ms,
      s.resting_hr_bpm,
      s.overnight_hr_bpm,
      s.readiness_level,
      s.sleep_total_min,
      s.sleep_in_bed_min,
      s.sleep_awake_min,
      s.sleep_light_min,
      s.sleep_deep_min,
      s.sleep_rem_min,
      s.sleep_efficiency,
      s.sleep_onset_at,
      s.wake_onset_at,
      s.disturbances,
      s.resp_rate_bpm,
      s.skin_temp_c,
      s.skin_temp_dev_c,
      s.spo2_pct,
      s.source_device_id,
      s.computed_at,
      s.algorithm_version
    from public.server_daily_scores s
    where s.user_id = p_user
      and s.day = p_day
      and s.algorithm_version = 'frwhoop-server-1'
    limit 1
  ),
  nights as (
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'id', n.id,
        'device_id', n.device_id,
        'period_day', n.period_day,
        'start_at', n.start_at,
        'end_at', n.end_at,
        'is_nap', n.is_nap,
        'in_bed_min', n.in_bed_min,
        'asleep_min', n.asleep_min,
        'awake_min', n.awake_min,
        'light_min', n.light_min,
        'deep_min', n.deep_min,
        'rem_min', n.rem_min,
        'efficiency', n.efficiency,
        'overnight_hr_bpm', n.overnight_hr_bpm,
        'resting_hr_bpm', n.resting_hr_bpm,
        'hrv_rmssd_ms', n.hrv_rmssd_ms,
        'resp_rate_bpm', n.resp_rate_bpm,
        'disturbances', n.disturbances,
        'stages', n.stages,
        'computed_at', n.computed_at
      ) order by n.start_at
    ), '[]'::jsonb) as items
    from public.server_sleep_nights n
    where n.user_id = p_user
      and n.period_day = p_day
      and n.algorithm_version = 'frwhoop-server-1'
  )
  select case
    when not exists (select 1 from daily) then
      jsonb_build_object(
        'algorithm_version', 'frwhoop-server-1',
        'daily', null,
        'nights', coalesce((select items from nights), '[]'::jsonb),
        'computed_at', null,
        'stale', true
      )
    else jsonb_build_object(
      'algorithm_version', 'frwhoop-server-1',
      'daily', (
        select jsonb_strip_nulls(jsonb_build_object(
          'day', p_day,
          'hrv_rmssd_ms', d.hrv_rmssd_ms,
          'hrv_sdnn_ms', d.hrv_sdnn_ms,
          'resting_hr_bpm', d.resting_hr_bpm,
          'overnight_hr_bpm', d.overnight_hr_bpm,
          'readiness_level', d.readiness_level,
          'sleep_total_min', d.sleep_total_min,
          'sleep_in_bed_min', d.sleep_in_bed_min,
          'sleep_awake_min', d.sleep_awake_min,
          'sleep_light_min', d.sleep_light_min,
          'sleep_deep_min', d.sleep_deep_min,
          'sleep_rem_min', d.sleep_rem_min,
          'sleep_efficiency', d.sleep_efficiency,
          'sleep_onset_at', d.sleep_onset_at,
          'wake_onset_at', d.wake_onset_at,
          'disturbances', d.disturbances,
          'resp_rate_bpm', d.resp_rate_bpm,
          'skin_temp_c', d.skin_temp_c,
          'skin_temp_dev_c', d.skin_temp_dev_c,
          'spo2_pct', d.spo2_pct,
          'source_device_id', d.source_device_id,
          'computed_at', d.computed_at
        ))
        from daily d
      ),
      'nights', coalesce((select items from nights), '[]'::jsonb),
      'computed_at', (select computed_at from daily),
      'stale', coalesce((select computed_at from daily) < (now() - interval '6 hours'), true)
    )
  end;
$$;

revoke all on function public.server_scoring_for_day(uuid, date) from public, anon;
grant execute on function public.server_scoring_for_day(uuid, date) to authenticated, service_role;

-- ── get_day_snapshot: additive server_scoring key ───────────────────────────

create or replace function public.get_day_snapshot(p_day date)
returns jsonb
language plpgsql
stable
security invoker
set search_path = pg_catalog, public
as $$
declare
  uid uuid := (select auth.uid());
  tz text;
  bounds record;
  base jsonb;
begin
  if uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  tz := public.profile_timezone(uid);
  select * into bounds from public.day_bounds(p_day, tz);

  base := jsonb_build_object(
    'day', p_day,
    'timezone_name', bounds.timezone_name,
    'day_start_at', bounds.day_start_at,
    'day_end_at', bounds.day_end_at,
    'timezone_offset_seconds', bounds.timezone_offset_seconds,
    'metrics', (
      select jsonb_build_object(
        'day', m.day,
        'recovery_score', coalesce(m.recovery_score, m.charge),
        'strain_score', coalesce(m.strain_score, m.effort),
        'strain_score_v2', m.strain_score_v2,
        'strain_v2', m.strain_v2,
        'vo2max', m.vo2max,
        'sleep_debt_balance_min', m.sleep_debt_balance_min,
        'sleep_consistency', m.sleep_consistency,
        'spo2_source', case
          when m.spo2_pct is not null then 'validated'
          when nullif(coalesce(
            m.extras#>>'{spo2_candidate,spo2_candidate_pct}',
            m.extras->>'spo2_candidate_pct'
          ), '') is not null then 'whoop_v18_candidate'
          else null
        end,
        'sleep_performance_pct', coalesce(m.sleep_performance_pct, m.rest),
        'hrv_rmssd_ms', m.hrv_rmssd_ms,
        'resting_hr_bpm', m.resting_hr_bpm,
        'avg_hr_bpm', m.avg_hr_bpm,
        'max_hr_bpm', m.max_hr_bpm,
        'resp_rate_bpm', m.resp_rate_bpm,
        'spo2_pct', m.spo2_pct,
        'skin_temp_c', m.skin_temp_c,
        'skin_temp_dev_c', m.skin_temp_dev_c,
        'steps', m.steps,
        'watch_steps', (
          select sum(b.step_count)
          from public.apple_watch_step_buckets b
          where b.user_id = uid
            and b.bucket_size_seconds = 60
            and b.bucket_start >= bounds.day_start_at
            and b.bucket_start < bounds.day_end_at
        ),
        'active_kcal', coalesce(e.active_kcal, m.active_kcal),
        'basal_kcal', coalesce(e.resting_kcal, m.basal_kcal),
        'energy_kcal', coalesce(
          e.total_kcal,
          case
            when coalesce(e.active_kcal, m.active_kcal) is not null
              or coalesce(e.resting_kcal, m.basal_kcal) is not null
            then coalesce(e.active_kcal, m.active_kcal, 0)
               + coalesce(e.resting_kcal, m.basal_kcal, 0)
          end
        ),
        'sleep_total_min', coalesce(m.sleep_total_min, (
          select max(coalesce(
            nullif(s.summary->>'asleep_min', '')::numeric,
            extract(epoch from (s.end_at - s.start_at)) / 60.0
          ))
          from public.sessions s
          where s.user_id = uid
            and s.kind in ('sleep', 'nap')
            and s.end_at is not null
            and s.end_at >= bounds.day_start_at
            and s.end_at < bounds.day_end_at
        )),
        'sleep_in_bed_min', m.sleep_in_bed_min,
        'sleep_need_min', m.sleep_need_min,
        'sleep_efficiency', m.sleep_efficiency,
        'sleep_onset_at', m.sleep_onset_at,
        'wake_onset_at', m.wake_onset_at,
        'timezone_name', coalesce(m.timezone_name, bounds.timezone_name),
        'day_start_at', coalesce(m.day_start_at, bounds.day_start_at),
        'day_end_at', coalesce(m.day_end_at, bounds.day_end_at),
        'algorithm_version', m.algorithm_version,
        'computed_at', m.computed_at,
        'confidence', m.confidence,
        'spo2_candidate_pct', (m.extras->'spo2_candidate'->>'spo2_candidate_pct')::numeric,
        'spo2_candidate', m.extras->'spo2_candidate',
        'hr_v2', m.extras->'hr_v2',
        'steps_v2', (m.extras->'steps_v2') - 'event_buckets_60s',
        'steps_v3', ((m.extras->'steps_v3') - 'event_buckets_60s') - 'buckets_60s',
        'energy_v2', m.extras->'energy_v2',
        'energy_v2_blocker', m.extras->'energy_v2_blocker',
        'energy_v3_shadow', m.extras->'energy_v3_shadow',
        'energy_v3_blocker', m.extras->'energy_v3_blocker',
        'device_state', m.extras->'device_state',
        'battery_timeline', m.provenance->'battery_timeline',
        'shadows', m.extras->'shadows'
      )
      from public.daily_metrics m
      left join public.energy_daily e
        on e.user_id = m.user_id and e.day = m.day
      where m.user_id = uid and m.day = p_day and m.record_class = 'user'
    ),
    'sleep', coalesce((
      select jsonb_agg(item order by item->>'original_start_at')
      from (
        select jsonb_build_object(
          'session_id', d.session_id,
          'is_nap', d.is_nap,
          'persist_state', coalesce(sess.summary->>'persist_state', case when d.is_nap then 'nap' else 'complete' end),
          'performance_pct', d.performance_pct,
          'efficiency', d.efficiency,
          'asleep_min', d.asleep_min,
          'in_bed_min', d.in_bed_min,
          'light_min', d.light_min,
          'deep_min', d.deep_min,
          'rem_min', d.rem_min,
          'awake_min', d.awake_min,
          'need_min', d.need_min,
          'debt_min', d.debt_min,
          'consistency_pct', d.consistency_pct,
          'hypnogram', d.hypnogram,
          'shadow_v3', case
            when d.shadow_v3 is null then null
            else jsonb_strip_nulls(jsonb_build_object(
              'mode', d.shadow_v3->'mode',
              'path', d.shadow_v3->'path',
              'fallback', d.shadow_v3->'fallback',
              'fallback_reason', d.shadow_v3->'fallback_reason',
              'v3_not_executed_reason', d.shadow_v3->'v3_not_executed_reason',
              'stager_version', d.shadow_v3->'stager_version',
              'vs_v2', d.shadow_v3->'vs_v2',
              'unscored_sec', d.shadow_v3->'unscored_sec',
              'modality_coverage', d.shadow_v3->'modality_coverage',
              'calibration_status', d.shadow_v3->'calibration_status'
            ))
          end,
          'original_start_at', d.original_start_at,
          'original_end_at', d.original_end_at
        ) as item
        from public.sleep_details d
        left join public.sessions sess on sess.id = d.session_id
        where d.user_id = uid
          and (
            (d.original_end_at is not null
              and d.original_end_at >= bounds.day_start_at
              and d.original_end_at < bounds.day_end_at)
            or (d.original_end_at is null
              and d.original_start_at >= bounds.day_start_at
              and d.original_start_at < bounds.day_end_at)
          )
        union all
        select jsonb_build_object(
          'session_id', s.id,
          'is_nap', coalesce((s.summary->>'is_nap')::boolean, s.kind = 'nap'),
          'persist_state', coalesce(
            s.summary->>'persist_state',
            case when s.kind = 'nap' or coalesce((s.summary->>'is_nap')::boolean, false) then 'nap' else 'complete' end
          ),
          'performance_pct', nullif(s.summary->>'performance', '')::numeric,
          'efficiency', nullif(s.summary->>'efficiency', '')::numeric,
          'asleep_min', coalesce(
            nullif(s.summary->>'asleep_min', '')::numeric,
            extract(epoch from (s.end_at - s.start_at)) / 60.0
          ),
          'in_bed_min', coalesce(
            nullif(s.summary->>'in_bed_min', '')::numeric,
            extract(epoch from (s.end_at - s.start_at)) / 60.0
          ),
          'light_min', nullif(s.summary->>'light_min', '')::numeric,
          'deep_min', nullif(s.summary->>'deep_min', '')::numeric,
          'rem_min', nullif(s.summary->>'rem_min', '')::numeric,
          'awake_min', nullif(s.summary->>'awake_min', '')::numeric,
          'need_min', nullif(s.summary->>'need_min', '')::numeric,
          'debt_min', nullif(s.summary->>'debt_min', '')::numeric,
          'consistency_pct', nullif(s.summary->>'consistency_pct', '')::numeric,
          'hypnogram', s.segments,
          'original_start_at', s.start_at,
          'original_end_at', s.end_at
        ) as item
        from public.sessions s
        where s.user_id = uid
          and s.kind in ('sleep', 'nap')
          and not exists (
            select 1 from public.sleep_details d
            where d.session_id = s.id
          )
          and (
            (s.end_at is not null
              and s.end_at >= bounds.day_start_at
              and s.end_at < bounds.day_end_at)
            or (s.end_at is null
              and s.start_at >= bounds.day_start_at
              and s.start_at < bounds.day_end_at)
          )
      ) sleep_rows
    ), '[]'::jsonb),
    'sessions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', s.id, 'kind', s.kind, 'source', s.source,
        'start_at', s.start_at, 'end_at', s.end_at,
        'summary', s.summary, 'user_modified', s.user_modified
      ) order by s.start_at)
      from public.sessions s
      where s.user_id = uid
        and s.start_at < bounds.day_end_at
        and coalesce(s.end_at, s.start_at) > bounds.day_start_at
    ), '[]'::jsonb),
    'events', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', e.id, 'event_type', e.event_type, 'occurred_at', e.occurred_at,
        'text_value', e.text_value, 'numeric_value', e.numeric_value, 'payload', e.payload
      ) order by e.occurred_at)
      from public.events e
      where e.user_id = uid
        and e.occurred_at >= bounds.day_start_at
        and e.occurred_at < bounds.day_end_at
    ), '[]'::jsonb),
    'strain_series', coalesce((
      select s.strain_series
      from public.daily_physiology_series s
      where s.user_id = uid and s.day = p_day
    ), '[]'::jsonb),
    'spo2_candidate_series', coalesce((
      select m.extras->'spo2_candidate_series'
      from public.daily_metrics m
      where m.user_id = uid and m.day = p_day and m.record_class = 'user'
        and jsonb_typeof(m.extras->'spo2_candidate_series') = 'array'
    ), '[]'::jsonb),
    'skin_temp_series', coalesce((
      select s.skin_temp_series
      from public.daily_physiology_series s
      where s.user_id = uid and s.day = p_day
    ), '[]'::jsonb),
    'chart', coalesce((
      select s.hr_series
      from public.daily_physiology_series s
      where s.user_id = uid and s.day = p_day
    ), '[]'::jsonb),
    'gaps', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', g.id, 'kind', g.kind, 'start_at', g.start_at, 'end_at', g.end_at,
        'expected_samples', g.expected_samples, 'received_samples', g.received_samples
      ) order by g.start_at)
      from public.ingest_gaps g
      where g.user_id = uid
        and g.start_at < bounds.day_end_at
        and g.end_at > bounds.day_start_at
    ), '[]'::jsonb),
    'shadows', (
      select m.extras->'shadows'
      from public.daily_metrics m
      where m.user_id = uid and m.day = p_day and m.record_class = 'user'
    ),
    'battery_timeline', coalesce((
      select m.provenance->'battery_timeline'
      from public.daily_metrics m
      where m.user_id = uid and m.day = p_day and m.record_class = 'user'
    ), '[]'::jsonb),
    'availability', jsonb_build_object(
      'hr', jsonb_build_object(
        'status', case
          when coalesce((
            select public.hr_series_occupied_buckets(s.hr_series)
            from public.daily_physiology_series s
            where s.user_id = uid and s.day = p_day
          ), 0) > 0 then 'available' else 'unavailable' end,
        'buckets', coalesce((
          select public.hr_series_occupied_buckets(s.hr_series)
          from public.daily_physiology_series s
          where s.user_id = uid and s.day = p_day
        ), 0),
        'expected_buckets', 288,
        'coverage_pct', round((
          100.0 * coalesce((
            select public.hr_series_occupied_buckets(s.hr_series)
            from public.daily_physiology_series s
            where s.user_id = uid and s.day = p_day
          ), 0) / 288.0
        )::numeric, 1)
      ),
      'steps', jsonb_build_object(
        'status', case
          when (
            select m.steps from public.daily_metrics m
            where m.user_id = uid and m.day = p_day and m.record_class = 'user'
          ) is not null then 'available' else 'unavailable' end,
        'value', (
          select m.steps from public.daily_metrics m
          where m.user_id = uid and m.day = p_day and m.record_class = 'user'
        ),
        'source', case
          when (
            select m.steps from public.daily_metrics m
            where m.user_id = uid and m.day = p_day and m.record_class = 'user'
          ) is not null then 'strap' else null end,
        'watch_steps', (
          select sum(b.step_count)
          from public.apple_watch_step_buckets b
          where b.user_id = uid
            and b.bucket_size_seconds = 60
            and b.bucket_start >= bounds.day_start_at
            and b.bucket_start < bounds.day_end_at
        )
      ),
      'sleep', public.sleep_day_availability(uid, bounds.day_start_at, bounds.day_end_at),
      'rhr', jsonb_build_object(
        'status', case
          when exists (
            select 1 from public.daily_metrics m
            where m.user_id = uid and m.day = p_day and m.record_class = 'user' and m.resting_hr_bpm is not null
          ) then 'available' else 'unavailable' end
      ),
      'hrv', jsonb_build_object(
        'status', case
          when exists (
            select 1 from public.daily_metrics m
            where m.user_id = uid and m.day = p_day and m.record_class = 'user' and m.hrv_rmssd_ms is not null
          ) then 'available' else 'unavailable' end
      ),
      'energy', jsonb_build_object(
        'status', case
          when exists (
            select 1 from public.energy_daily e
            where e.user_id = uid and e.day = p_day and e.total_kcal is not null
          ) or exists (
            select 1 from public.daily_metrics m
            where m.user_id = uid and m.day = p_day and m.record_class = 'user'
              and (m.active_kcal is not null or m.basal_kcal is not null)
          ) then 'available' else 'unavailable' end
      ),
      'strain', jsonb_build_object(
        'status', case
          when exists (
            select 1 from public.daily_metrics m
            where m.user_id = uid and m.day = p_day and m.record_class = 'user'
              and coalesce(m.strain_score, m.effort) is not null
          ) then 'available' else 'unavailable' end
      ),
      'skin_temp', jsonb_build_object(
        'status', case
          when exists (
            select 1 from public.daily_metrics m
            where m.user_id = uid and m.day = p_day and m.record_class = 'user'
              and m.skin_temp_c is not null
          ) then 'available' else 'unavailable' end,
        'value', (
          select m.skin_temp_c from public.daily_metrics m
          where m.user_id = uid and m.day = p_day and m.record_class = 'user'
        ),
        'series_buckets', coalesce((
          select jsonb_array_length(s.skin_temp_series)
          from public.daily_physiology_series s
          where s.user_id = uid and s.day = p_day
        ), 0)
      )
    ),
    'server_scoring', public.server_scoring_for_day(uid, p_day)
  );

  return base;
end;
$$;

grant execute on function public.get_day_snapshot(date) to authenticated, service_role;
revoke all on function public.get_day_snapshot(date) from public, anon;

-- ── Realtime publication ────────────────────────────────────────────────────

do $$
begin
  begin
    alter publication supabase_realtime add table only public.server_daily_scores;
  exception when duplicate_object then
    null;
  end;
  begin
    alter publication supabase_realtime add table only public.server_sleep_nights;
  exception when duplicate_object then
    null;
  end;
end $$;

comment on function public.server_scoring_for_day(uuid, date) is
  'Phase 4: server-computed HRV/sleep overlay for get_day_snapshot. algorithm_version = frwhoop-server-1 only; stale when computed_at older than 6 hours.';
