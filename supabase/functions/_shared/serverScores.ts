import { IdentityError, resolveUploadIdentity, resolveJwtUser, bearerToken, looksLikeJwt } from './tokens.ts';
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
    return { server_scoring: await rest.rpc('server_scoring_pending_contract',{p_user:userId,p_day:day}) };
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
  const isDiagnostics = req.method === 'GET' && route === '/diagnostics';
  const isRegister = req.method === 'POST' && route === '/devices';
  const isOverride = req.method === 'POST' && route === '/sleep-overrides';
  const isComputeSubmit = req.method === 'POST' && route === '/compute-requests';
  const isComputeRead = req.method === 'GET' && route === '/compute-requests';
  if (!isRead && !isDiagnostics && !isRegister && !isOverride && !isComputeSubmit && !isComputeRead) {
    return Response.json({ error: 'method_not_allowed' }, { status: 405 });
  }
  if (!rest.configured) return Response.json({ error: 'service_role_unconfigured' }, { status: 503 });
  try {
    const jwt = looksLikeJwt(bearerToken(req.headers));
    let user: {id: string; sourceId: string};
    if (jwt) {
      const account = await resolveJwtUser({headers:req.headers,supabaseUrl:_cfg.supabaseUrl,
        anonKey:_cfg.supabaseAnonKey,fetchImpl:_fetchImpl});
      const sourceId = req.headers.get('x-noop-source-id');
      if (!isUuid(sourceId)) throw new IdentityError('registered source required');
      if (isRegister) {
        await rest.rpc('register_account_compute_source',{p_user:account.id,p_source:sourceId});
      } else {
        const registered = await rest.select('compute_account_sources',
          `user_id=eq.${account.id}&source_id=eq.${sourceId}&revoked_at=is.null&select=source_id`);
        const installation = await rest.select('noop_app_installations',
          `source_id=eq.${sourceId}&select=user_id,revoked_at`);
        if (installation?.[0] && (installation[0].user_id!==account.id || installation[0].revoked_at!=null)) {
          throw new IdentityError('source revoked');
        }
        if (!registered?.[0] && !installation?.[0]) throw new IdentityError('registered source required');
      }
      user={id:account.id,sourceId:sourceId!};
    } else {
      const installation=await resolveUploadIdentity({headers:req.headers,rest,allowLegacyFleetUploads:false});
      if (installation.authMode!=='installation' || !installation.sourceId) throw new IdentityError('installation required');
      user={id:installation.id,sourceId:installation.sourceId};
    }
    const requestBody = isRead || isDiagnostics || isComputeRead ? null : await boundedBody(req);
    const externalDeviceId = isRead || isDiagnostics || isComputeRead ? url.searchParams.get('deviceId') : requestBody?.deviceId;
    if (!isSafeExternalDeviceId(externalDeviceId)) throw fail('invalid_device_id', 400);
    const lookup = { userId: user.id, sourceId: user.sourceId, externalDeviceId };
    const deviceId = isRegister
      ? await createNoopDeviceResolver({ rest })(lookup)
      : await findNoopDevice({ rest, ...lookup });
    const project = _cfg.supabaseUrl.replace(/\/+$/,'');
    const identity = { userId: user.id, sourceId: user.sourceId, deviceId, externalDeviceId, project };
    if (isRegister) return Response.json({ identity });
    if (isComputeSubmit || isComputeRead) {
      if (!deviceId) throw fail('device_registration_pending',409);
      let result: any;
      if (isComputeSubmit) {
        const request=requestBody?.request;
        const keys=['id','family','session_id','event_start','event_end','timezone_id','input_revision',
          'algorithm_version','configuration_version','consent','expires_at'];
        if (!request || Object.keys(request).some(k=>!keys.includes(k)) || keys.some(k=>!(k in request)) ||
          !isUuid(request.id) || !isUuid(request.session_id) || typeof request.family!=='string' ||
          typeof request.timezone_id!=='string' || !Number.isSafeInteger(request.input_revision) || request.input_revision<0 ||
          request.algorithm_version!=='vps-only-1' || request.configuration_version!=='vps-only-1' ||
          typeof request.consent!=='boolean' || !Number.isFinite(Date.parse(request.event_start)) ||
          (request.event_end!==null && !Number.isFinite(Date.parse(request.event_end))) ||
          (request.expires_at!==null && !Number.isFinite(Date.parse(request.expires_at)))) throw fail('invalid_compute_request',400);
        result=await rest.rpc('submit_compute_session_request',{p_user:user.id,p_device:deviceId,p_source:user.sourceId,p_request:request});
      } else {
        const requestId=url.searchParams.get('requestId');
        if (!isUuid(requestId)) throw fail('invalid_request_id',400);
        result=await rest.rpc('read_compute_session_result',{p_user:user.id,p_device:deviceId,p_source:user.sourceId,p_request:requestId});
      }
      if (result?.result) result.result={...result.result,project};
      return Response.json({...result,identity},{headers:{'cache-control':'no-store'}});
    }
    if (isOverride) {
      if (!deviceId) throw fail('device_registration_pending', 409);
      const args = sleepArguments(requestBody?.arguments, deviceId);
      const revision = await rest.rpc('enrolled_physiology_sleep_override', { ...args, p_user: user.id });
      return Response.json(revision);
    }
    if (isDiagnostics) {
      const day = url.searchParams.get('day') || utcDay();
      const parsed = new Date(day);
      if (!DAY_RE.test(day) || !Number.isFinite(parsed.getTime()) || utcDay(parsed) !== day) throw fail('invalid_day', 400);
      if (!deviceId) throw fail('device_registration_pending', 409);
      const diagnostics = await rest.rpc('server_pipeline_diagnostics', {
        p_user: user.id, p_source: user.sourceId, p_device: deviceId, p_day: day,
      });
      return Response.json(diagnostics, { headers: { 'cache-control': 'no-store' } });
    }
    const body = await readOwnerDayScores({ rest, userId: user.id,
      day: url.searchParams.get('day') || utcDay(), deviceId });
    const overlay = body.server_scoring as any;
    if (overlay?.compute) {
      overlay.compute={...overlay.compute,project,source_id:user.sourceId};
      for (const result of Object.values(overlay.compute.families ?? {}) as any[]) {
        result.project=project; result.source_id=user.sourceId;
      }
    }
    return Response.json({ ...body, identity }, { headers: { 'cache-control': 'no-store' } });
  } catch (err: any) {
    if (err instanceof IdentityError) return Response.json({ error: 'unauthorized' }, { status: err.status || 401 });
    if ([400, 403, 404, 409, 413].includes(err?.status)) {
      return Response.json({ error: err.code || 'request_rejected' }, { status: err.status });
    }
    console.error('[scores] request failed');
    return Response.json({ error: 'scores_unavailable' }, { status: 500 });
  }
}
