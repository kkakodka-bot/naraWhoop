// Server-scoring snapshot overlay contract (Phase 4 read path).
// Mirrors public.server_scoring_for_day / get_day_snapshot.server_scoring.

export const SERVER_SCORING_ALGORITHM_VERSION = 'frwhoop-server-1';
/** Matches Postgres: computed_at older than this interval marks stale = true. */
export const SERVER_SCORING_STALE_AFTER_MS = 6 * 60 * 60 * 1000;

export type ServerScoringDaily = {
  day?: string;
  hrv_rmssd_ms?: number | null;
  hrv_sdnn_ms?: number | null;
  resting_hr_bpm?: number | null;
  overnight_hr_bpm?: number | null;
  readiness_level?: string | null;
  sleep_total_min?: number | null;
  sleep_in_bed_min?: number | null;
  sleep_awake_min?: number | null;
  sleep_light_min?: number | null;
  sleep_deep_min?: number | null;
  sleep_rem_min?: number | null;
  sleep_efficiency?: number | null;
  sleep_onset_at?: string | null;
  wake_onset_at?: string | null;
  disturbances?: number | null;
  resp_rate_bpm?: number | null;
  skin_temp_c?: number | null;
  skin_temp_dev_c?: number | null;
  spo2_pct?: number | null;
  source_device_id?: string | null;
  computed_at?: string | null;
};

export type ServerScoringNight = {
  id?: string;
  device_id?: string | null;
  period_day?: string;
  start_at?: string;
  end_at?: string;
  is_nap?: boolean;
  in_bed_min?: number | null;
  asleep_min?: number | null;
  awake_min?: number | null;
  light_min?: number | null;
  deep_min?: number | null;
  rem_min?: number | null;
  efficiency?: number | null;
  overnight_hr_bpm?: number | null;
  resting_hr_bpm?: number | null;
  hrv_rmssd_ms?: number | null;
  resp_rate_bpm?: number | null;
  disturbances?: number | null;
  stages?: unknown;
  computed_at?: string | null;
};

export type ServerScoringOverlay = {
  algorithm_version: string;
  daily: ServerScoringDaily | null;
  nights: ServerScoringNight[];
  computed_at: string | null;
  stale: boolean;
};

export function parseServerScoringOverlay(raw: unknown): ServerScoringOverlay | null {
  if (!raw || typeof raw !== 'object') return null;
  const o = raw as Record<string, unknown>;
  if (o.algorithm_version !== SERVER_SCORING_ALGORITHM_VERSION) return null;
  const nights = Array.isArray(o.nights) ? o.nights as ServerScoringNight[] : [];
  const daily = o.daily && typeof o.daily === 'object' ? o.daily as ServerScoringDaily : null;
  const computedAt = typeof o.computed_at === 'string' ? o.computed_at : null;
  const stale = Boolean(o.stale);
  return {
    algorithm_version: SERVER_SCORING_ALGORITHM_VERSION,
    daily,
    nights,
    computed_at: computedAt,
    stale,
  };
}

/** RLS policy names the Phase 4 migration must create (used by tests). */
export const SERVER_SCORE_RLS_POLICIES = {
  server_daily_scores_select_own: '(select auth.uid()) = user_id',
  server_sleep_nights_select_own: '(select auth.uid()) = user_id',
} as const;
