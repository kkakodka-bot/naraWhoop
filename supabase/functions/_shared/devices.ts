import { isSafeExternalDeviceId, isUuid, noopDeviceId } from './keys.ts';
import type { SupabaseRest } from './rest.ts';

/** Registration preserves the device owner atomically, including concurrent retries. */
export function createDeviceRegistrar(rest: SupabaseRest) {
  return async (row: Record<string, unknown>) => {
    if (!rest.configured) return [];
    return await rest.rpc('register_noop_device', {
      p_device: row.id,
      p_user: row.user_id,
      p_external_device_id: row.external_device_id,
      p_last_seen_at: row.last_seen_at,
    });
  };
}

/** Provisional Bluetooth UUIDs and legacy names are installation-local, never hardware evidence. */
export function scopedExternalDeviceId(externalDeviceId: unknown, sourceId?: string | null): string {
  const external = String(externalDeviceId || '').trim();
  if (!isSafeExternalDeviceId(external)) throw new Error('device id invalid');
  if (!sourceId) return external; // Explicit legacy receiver mode only.
  if (!isUuid(sourceId)) throw new Error('source id invalid');
  const serial = external.startsWith('whoop-') ? external.slice(6) : '';
  if (/^[A-Z0-9-]{6,}$/.test(serial) && !isUuid(serial)) return external;
  return `installation:${sourceId.toLowerCase()}:${external}`;
}

export async function findNoopDevice({ rest, userId, externalDeviceId, sourceId }: {
  rest: Pick<SupabaseRest, 'select'>;
  userId: string;
  externalDeviceId: unknown;
  sourceId?: string | null;
}): Promise<string | null> {
  if (!isUuid(userId)) throw new Error('user id invalid');
  const external = scopedExternalDeviceId(externalDeviceId, sourceId);
  const rows = await rest.select('devices',
    `user_id=eq.${userId}&source_kind=eq.noop_push&external_device_id=eq.${encodeURIComponent(external)}&select=id`);
  return isUuid(rows?.[0]?.id) ? rows[0].id : null;
}

/** Preserve existing owned foreign keys, then register through the atomic ownership RPC. */
export function createNoopDeviceResolver({ rest, now = () => new Date() }: {
  rest: SupabaseRest;
  now?: () => Date;
}) {
  const register = createDeviceRegistrar(rest);
  return async ({ userId, externalDeviceId, sourceId }: {
    userId: string; externalDeviceId: unknown; sourceId?: string | null;
  }) => {
    if (!isUuid(userId)) throw new Error('user id invalid');
    const external = scopedExternalDeviceId(externalDeviceId, sourceId);
    const prior = rest.configured ? await findNoopDevice({ rest, userId, externalDeviceId, sourceId }) : null;
    const id = prior || noopDeviceId(userId, external);
    if (rest.configured) {
      const registered = await register({ id, user_id: userId, external_device_id: external,
        last_seen_at: now().toISOString() });
      if (registered !== id) throw new Error('device_registration_conflict');
    }
    return id;
  };
}
