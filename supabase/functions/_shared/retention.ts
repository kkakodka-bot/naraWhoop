// Port of the retired Node receiver — push-lane subset (lifecycle rules and the sweep stay in
// the Node backend; the functions only need per-stream expiry and the lane ceilings).
import { OBJECT_LANE_STREAMS, retentionClassForStream } from './keys.ts';

/** Per-class expiry in days for an object-lane stream. Absent means never. */
const OBJECT_LANE_CLASS_DAYS: Record<string, number | null> = { research: null, diag: 7 };

export const MAX_RANGE_MS = 48 * 60 * 60 * 1000;

/**
 * Ceiling for one presigned direct-to-bucket object. Generous against a real hour of any stream
 * (an hour of 100 Hz 6-axis i16 is ~4.3 MB before compression) while still bounding what a single
 * signed URL can write. B2 tolerates far larger single-part puts; this is our limit, not theirs.
 */
export const MAX_OBJECT_LANE_BYTES = 256 * 1024 * 1024;

export interface RetentionSpec {
  class: string;
  defaultDays: number | null;
}

export function retentionFor(kind: string, cfg: Record<string, unknown> = {}): RetentionSpec {
  // Object-lane wire streams are camelCase and never collide with an OBJECT_KINDS value, so this
  // resolves them off the one canonical stream->class map instead of a second list that can drift.
  if (OBJECT_LANE_STREAMS.has(kind)) {
    const cls = retentionClassForStream(kind);
    const days = OBJECT_LANE_CLASS_DAYS[cls];
    return { class: cls, defaultDays: days == null ? null : days };
  }
  if (kind === 'frames') return { class: 'core', defaultDays: null };
  if (kind === 'canonical' || kind === 'hr' || kind === 'rr' || kind === 'hr_rr' || kind === 'live_hr' || kind === 'physiology') {
    const days = kind === 'rr' ? cfg.retentionRrDays : cfg.retentionHrDays;
    return { class: 'core', defaultDays: days == null ? null : Number(days) };
  }
  if (kind === 'ppg') return { class: 'ppg', defaultDays: (cfg.retentionPpgDays as number) ?? 30 };
  if (kind === 'imu') return { class: 'research_imu', defaultDays: (cfg.retentionImuDays as number) ?? 30 };
  if (kind === 'ble' || kind === 'diagnostic') {
    return { class: 'diagnostic', defaultDays: ((kind === 'ble' ? cfg.retentionBleDays : cfg.retentionDiagDays) as number) ?? 7 };
  }
  if (kind === 'export') return { class: 'export', defaultDays: 7 };
  if (kind === 'derived_scores') return { class: 'derived', defaultDays: 90 };
  if (kind === 'derived' || kind === 'sleep_summary' || kind === 'daily_metrics') return { class: 'derived', defaultDays: null };
  return { class: 'core', defaultDays: null };
}

export function expiresAt(kind: string, now: Date = new Date(), cfg: Record<string, unknown> = {}): string | null {
  const spec = retentionFor(kind, cfg);
  if (!spec || spec.defaultDays == null) return null;
  return new Date(now.getTime() + spec.defaultDays * 86400 * 1000).toISOString();
}
