// Phase 4: server score read-path contract + RLS migration assertions.
import { assert, assertEquals } from 'jsr:@std/assert';
import {
  parseServerScoringOverlay,
  SERVER_SCORING_ALGORITHM_VERSION,
  SERVER_SCORING_STALE_AFTER_MS,
  SERVER_SCORE_RLS_POLICIES,
} from '../_shared/serverScoring.ts';

const MIGRATION_PATH = new URL(
  '../../migrations/20260917180000_server_score_user_reads.sql',
  import.meta.url,
);

Deno.test('server scoring: parse overlay from get_day_snapshot shape', () => {
  const overlay = parseServerScoringOverlay({
    algorithm_version: 'frwhoop-server-1',
    daily: {
      day: '2026-09-16',
      hrv_rmssd_ms: 42.5,
      resting_hr_bpm: 52,
      sleep_total_min: 420,
      computed_at: '2026-09-16T08:00:00Z',
    },
    nights: [{
      id: 'night-1',
      period_day: '2026-09-16',
      start_at: '2026-09-15T23:00:00Z',
      end_at: '2026-09-16T07:00:00Z',
      asleep_min: 420,
      is_nap: false,
    }],
    computed_at: '2026-09-16T08:00:00Z',
    stale: false,
  });
  assert(overlay);
  assertEquals(overlay!.algorithm_version, SERVER_SCORING_ALGORITHM_VERSION);
  assertEquals(overlay!.daily?.hrv_rmssd_ms, 42.5);
  assertEquals(overlay!.nights.length, 1);
  assertEquals(overlay!.stale, false);
});

Deno.test('server scoring: rejects wrong algorithm_version', () => {
  assertEquals(
    parseServerScoringOverlay({ algorithm_version: 'other', daily: null, nights: [], stale: true }),
    null,
  );
});

Deno.test('server scoring: null daily is valid (no server row yet)', () => {
  const overlay = parseServerScoringOverlay({
    algorithm_version: 'frwhoop-server-1',
    daily: null,
    nights: [],
    computed_at: null,
    stale: true,
  });
  assert(overlay);
  assertEquals(overlay!.daily, null);
  assertEquals(overlay!.stale, true);
});

Deno.test('server scoring: stale threshold is six hours', () => {
  assertEquals(SERVER_SCORING_STALE_AFTER_MS, 6 * 60 * 60 * 1000);
});

Deno.test('server scoring RLS: migration defines owner-scoped SELECT policies', async () => {
  const sql = await Deno.readTextFile(MIGRATION_PATH);
  assert(sql.includes('server_daily_scores_select_own'), 'missing daily scores SELECT policy');
  assert(sql.includes('server_sleep_nights_select_own'), 'missing sleep nights SELECT policy');
  assert(sql.includes('grant select on public.server_daily_scores to authenticated'));
  assert(sql.includes('grant select on public.server_sleep_nights to authenticated'));
  assert(!sql.includes('grant select on public.server_daily_scores to anon'));
  for (const [name, expr] of Object.entries(SERVER_SCORE_RLS_POLICIES)) {
    assert(sql.includes(name), `policy ${name} missing from migration`);
    assert(sql.includes(expr), `policy ${name} must use ${expr}`);
  }
});

Deno.test('server scoring RLS: migration keeps service_role write policies', async () => {
  const sql = await Deno.readTextFile(MIGRATION_PATH);
  // Phase 3 service policies must remain (not dropped in this migration).
  assert(sql.includes('alter publication supabase_realtime add table only public.server_daily_scores'));
  assert(sql.includes('alter publication supabase_realtime add table only public.server_sleep_nights'));
  assert(sql.includes("'server_scoring', public.server_scoring_for_day(uid, p_day)"));
});

Deno.test('server scoring RLS: two-user isolation SQL proof script present', async () => {
  const proofPath = new URL('./server_scores_rls_proof.sql', import.meta.url);
  const proof = await Deno.readTextFile(proofPath);
  assert(proof.includes('user_a'), 'proof script must set user A');
  assert(proof.includes('user_b'), 'proof script must set user B');
  assert(proof.includes('server_daily_scores'));
  assert(proof.includes('request.jwt.claim.sub'));
});
