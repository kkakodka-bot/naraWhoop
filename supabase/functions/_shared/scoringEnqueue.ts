import { noopDeviceId } from './keys.ts';
import type { SupabaseRest } from './rest.ts';

const DAY_RE = /^\d{4}-\d{2}-\d{2}$/;

export function ymdInTimeZone(at: Date, timeZone: string): string {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(at);
  const year = parts.find((p) => p.type === 'year')?.value;
  const month = parts.find((p) => p.type === 'month')?.value;
  const day = parts.find((p) => p.type === 'day')?.value;
  return `${year}-${month}-${day}`;
}

export function localDaysTouched(at: Date, timeZone: string): string[] {
  const today = ymdInTimeZone(at, timeZone);
  const yesterday = ymdInTimeZone(new Date(at.getTime() - 12 * 60 * 60 * 1000), timeZone);
  return today === yesterday ? [today] : [yesterday, today];
}

export async function profileTimezone(rest: Pick<SupabaseRest, 'rpc' | 'select'>, userId: string): Promise<string> {
  try {
    const tz = await rest.rpc('profile_timezone', { p_user_id: userId });
    if (typeof tz === 'string' && tz.includes('/')) return tz;
  } catch {
    // Fall through to a direct profile read, then UTC.
  }
  try {
    const rows = await rest.select('profiles', `id=eq.${userId}&select=timezone,preferences`);
    const row = Array.isArray(rows) ? rows[0] : null;
    const fromColumn = typeof row?.timezone === 'string' ? row.timezone : '';
    const fromPrefs = typeof row?.preferences?.timezone === 'string' ? row.preferences.timezone : '';
    const tz = fromColumn || fromPrefs;
    if (tz.includes('/')) return tz;
  } catch {
    // UTC is a valid enqueue timezone; the scorer still owns calendar segments.
  }
  return 'UTC';
}

/** Best-effort: ingest success must not fail because the score queue is down. */
export async function enqueueScoringAfterIngest({
  rest,
  userId,
  deviceId,
  at = new Date(),
}: {
  rest: Pick<SupabaseRest, 'rpc' | 'select'>;
  userId: string;
  deviceId: unknown;
  at?: Date;
}): Promise<{ days: string[]; deviceId: string; timezone: string }> {
  let cloudDevice = '';
  try {
    if (deviceId) cloudDevice = noopDeviceId(userId, deviceId);
  } catch {
    cloudDevice = '';
  }
  if (!cloudDevice) {
    const rows = await rest.select(
      'devices',
      `user_id=eq.${userId}&select=id&order=last_seen_at.desc.nullslast&limit=1`,
    );
    cloudDevice = String(Array.isArray(rows) ? rows[0]?.id || '' : '');
  }
  if (!cloudDevice) {
    throw new Error('scoring_enqueue_device_required');
  }
  const timezone = await profileTimezone(rest, userId);
  const days = localDaysTouched(at, timezone).filter((day) => DAY_RE.test(day));
  for (const day of days) {
    await rest.rpc('scoring_enqueue_day', {
      p_user: userId,
      p_device: cloudDevice,
      p_day: day,
      p_timezone: timezone,
      p_debounce_seconds: 30,
    });
  }
  return { days, deviceId: cloudDevice, timezone };
}
