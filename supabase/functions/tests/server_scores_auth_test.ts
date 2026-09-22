// Phase 4: server score read-path contract + RLS migration assertions.
import { assert, assertEquals } from 'jsr:@std/assert';
import {
  parseServerScoringOverlay,
  SERVER_SCORING_ALGORITHM_VERSION,
  SERVER_SCORING_STALE_AFTER_MS,
} from '../_shared/serverScoring.ts';

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

// Authorization is executed against the full migration catalogue in multiuser_sql_test.ts.
