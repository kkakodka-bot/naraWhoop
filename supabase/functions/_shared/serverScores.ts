import { IdentityError, resolveUploadIdentity } from './tokens.ts';
import { createNoopDeviceResolver, findNoopDevice } from './devices.ts';
import { isSafeExternalDeviceId, isUuid } from './keys.ts';
import type { PushFunctionConfig } from './config.ts';
import type { SupabaseRest } from './rest.ts';

const DAY_RE = /^\d{4}-\d{2}-\d{2}$/;

export function utcDay(at = new Date()): string {
  return at.toISOString().slice(0, 10);
}

function fail(code: string, status: number): Error {
  return Object.assign(new Error(code), { code, status });
}

export async function readOwnerDayScores({ rest, userId, day, deviceId }: {
  rest: Pick<SupabaseRest, 'rpc'>; userId: string; day: string; deviceId: string | null;
}) {
  const date = new Date(day);
  if (!DAY_RE.test(day) || !Number.isFinite(date.getTime()) || utcDay(date) !== day) {
    throw fail('invalid_day', 400);
  }
  if (!deviceId) {
    return { server_scoring: {
      schema_version: 2, user_id: userId, day, algorithm_version: 'frwhoop-physiology-2',
      daily: null, nights: [], measurements: [], sleep_overrides: [], computed_at: null, stale: true,
      features: Object.fromEntries(['sleep', 'hrv', 'respiration'].map((feature) => [feature,
        { status: 'unavailable', reason: 'device_registration_pending' }])),
    } };
  }
  const overlay = await rest.rpc('server_scoring_for_device_day', {
    p_user: userId, p_day: day, p_device: deviceId,
  });
  return { server_scoring: overlay };
}

async function boundedBody(req: Request): Promise<any> {
  const bytes = new Uint8Array(await req.arrayBuffer());
  if (bytes.length > 8192) throw fail('payload_too_large', 413);
  try { return JSON.parse(new TextDecoder().decode(bytes)); }
  catch { throw fail('invalid_body', 400); }
}

function sleepArguments(value: any, canonicalDevice: string) {
  const keys = ['p_id', 'p_device', 'p_original_start', 'p_original_end', 'p_start', 'p_end',
    'p_tombstone', 'p_expected_revision'];
  if (!value || typeof value !== 'object' || Array.isArray(value)
      || Object.keys(value).some((key) => !keys.includes(key) && key !== 'p_legacy_revision')
      || keys.some((key) => !(key in value))
      || !isUuid(value.p_id) || value.p_device !== canonicalDevice
      || typeof value.p_tombstone !== 'boolean'
      || !Number.isSafeInteger(value.p_expected_revision) || value.p_expected_revision < 0
      || (value.p_legacy_revision != null && !/^[0-9a-f]{64}$/.test(value.p_legacy_revision))) {
    throw fail('invalid_override', 400);
  }
  for (const key of ['p_original_start', 'p_original_end', 'p_start', 'p_end']) {
    if (typeof value[key] !== 'string' || !Number.isFinite(Date.parse(value[key]))) {
      throw fail('invalid_override', 400);
    }
  }
  return { ...value, p_legacy_revision: value.p_legacy_revision ?? null };
}

export async function handleScoresRequest(req: Request, { rest, cfg: _cfg, fetchImpl: _fetchImpl = fetch }: {
  rest: SupabaseRest;
  cfg: Pick<PushFunctionConfig, 'supabaseUrl' | 'supabaseAnonKey'>;
  fetchImpl?: typeof fetch;
}): Promise<Response> {
  const url = new URL(req.url);
  const route = url.pathname.replace(/^\/functions\/v1/, '').replace(/^\/scores/, '') || '/';
  const isRead = req.method === 'GET' && route === '/';
  const isRegister = req.method === 'POST' && route === '/devices';
  const isOverride = req.method === 'POST' && route === '/sleep-overrides';
  if (!isRead && !isRegister && !isOverride) {
    return Response.json({ error: 'method_not_allowed' }, { status: 405 });
  }
  if (!rest.configured) return Response.json({ error: 'service_role_unconfigured' }, { status: 503 });
  try {
    const user = await resolveUploadIdentity({ headers: req.headers, rest, allowLegacyFleetUploads: false });
    if (user.authMode !== 'installation' || !user.sourceId) throw new IdentityError('installation required');
    const requestBody = isRead ? null : await boundedBody(req);
    const externalDeviceId = isRead ? url.searchParams.get('deviceId') : requestBody?.deviceId;
    if (!isSafeExternalDeviceId(externalDeviceId)) throw fail('invalid_device_id', 400);
    const lookup = { userId: user.id, sourceId: user.sourceId, externalDeviceId };
    const deviceId = isRegister
      ? await createNoopDeviceResolver({ rest })(lookup)
      : await findNoopDevice({ rest, ...lookup });
    const identity = { userId: user.id, sourceId: user.sourceId, deviceId, externalDeviceId };
    if (isRegister) return Response.json({ identity });
    if (isOverride) {
      if (!deviceId) throw fail('device_registration_pending', 409);
      const args = sleepArguments(requestBody?.arguments, deviceId);
      const revision = await rest.rpc('enrolled_physiology_sleep_override', { ...args, p_user: user.id });
      return Response.json(revision);
    }
    const body = await readOwnerDayScores({ rest, userId: user.id,
      day: url.searchParams.get('day') || utcDay(), deviceId });
    return Response.json({ ...body, identity }, { headers: { 'cache-control': 'no-store' } });
  } catch (err: any) {
    if (err instanceof IdentityError) return Response.json({ error: 'unauthorized' }, { status: err.status || 401 });
    if ([400, 403, 409, 413].includes(err?.status)) {
      return Response.json({ error: err.code || 'request_rejected' }, { status: err.status });
    }
    console.error('[scores] request failed');
    return Response.json({ error: 'scores_unavailable' }, { status: 500 });
  }
}
