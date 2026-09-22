// NOOP push receiver as a Supabase Edge Function — port of the retired Node receiver
//
// Routes (path after /functions/v1/push):
//   GET  /                        capabilities (version negotiation + objectLane advert)
//   POST /                        inline NDJSON batch (gzip optional)
//   POST /objects                 object-lane intent → presigned B2 PUT
//   POST /objects/:objectId/complete   byte-count check → release device rows
//
// Auth is handled here, so the function is deployed with --no-verify-jwt. Uploads require a
// source-bound `noop_` installation bearer plus a separate fleet credential; enrollment uses the
// fleet bearer, and token management alone accepts a Supabase JWT.
//
// Differences from the Node original, all deliberate:
//   - replacement staging is Postgres-backed (isolates are stateless), same state machine;
//   - the Node wrapper's timezone-resolver warm-up is scoring plumbing, not push semantics, and
//     is not ported;
//   - metrics.inc counters are a Node-process facility and are not ported.
import { gunzipSync } from 'node:zlib';
import {
  INGEST_ENABLED_STREAMS,
  PushProtocolError,
  advertisedStreams,
  capabilitiesBody,
  negotiateProtocol,
} from '../_shared/registry.ts';
import { UPLOAD_URL_TTL_SEC, createPushObjects } from '../_shared/objects.ts';
import { MAX_OBJECT_LANE_BYTES } from '../_shared/retention.ts';
import { createPushIngest, createPushArchive, deleteReplacementRows } from '../_shared/ingest.ts';
import { createPushWalStore } from '../_shared/wal.ts';
import { createPushReplacementStaging } from '../_shared/staging.ts';
import { createSupabaseRest, restConfigFromEnv } from '../_shared/rest.ts';
import { createS3 } from '../_shared/s3.ts';
import { pushConfig, defaultReceiverStateId } from '../_shared/config.ts';
import { createDeviceRegistrar } from '../_shared/devices.ts';
import { enqueueScoringAfterIngest } from '../_shared/scoringEnqueue.ts';
import { inlineRequestProtocol, ingestProtocolErrorResponse, unexpectedIngestDiagnostic } from '../_shared/pushDiagnostics.ts';
import {
  IdentityError,
  resolveFleetAuthorization,
  resolveJwtUser,
  resolveUploadIdentity,
  createIngestTokenStore,
} from '../_shared/tokens.ts';
import { createEnrollmentService, EnrollmentError } from '../_shared/enrollment.ts';
import { createNoopDeviceResolver } from '../_shared/devices.ts';
import { createUploadReceiptStore } from '../_shared/receipts.ts';
import { projectEnrolledAppend } from '../_shared/appendProjection.ts';
import { createInstallationLifecycle } from '../_shared/installationLifecycle.ts';

const MAX_BODY_BYTES = 4 * 1024 * 1024 + 64 * 1024;

/** Cap on an intent body. A manifest is a few hundred bytes; anything larger is not one. */
const MAX_INTENT_BYTES = 8 * 1024;

/** Advertised object-lane path, resolved by clients against the function host. */
const OBJECT_LANE_PATH = '/functions/v1/push/objects';

const cfg = pushConfig();
const rest = createSupabaseRest({ cfg: restConfigFromEnv() });
const ingestTokenStore = createIngestTokenStore({ rest });
const enrollmentService = createEnrollmentService({
  rest,
  pepper: cfg.enrollmentPepper,
  retryWindowSeconds: cfg.enrollmentRetryWindowSeconds,
});
const receiptStore = createUploadReceiptStore({ rest });
const resolveDeviceId = createNoopDeviceResolver({ rest });
const installationLifecycle = createInstallationLifecycle(rest);
const raw = cfg.b2KeyId && cfg.b2ApplicationKey && cfg.b2Bucket && cfg.b2S3Endpoint
  ? createS3({
    endpoint: cfg.b2S3Endpoint,
    bucket: cfg.b2Bucket,
    region: cfg.b2Region,
    accessKeyId: cfg.b2KeyId,
    secretAccessKey: cfg.b2ApplicationKey,
    style: 'path',
  })
  : null;

const pushWalStore = createPushWalStore({ rest });
const pushArchive = createPushArchive({ cfg, rest, raw });
const pushStaging = createPushReplacementStaging({ rest });
const pushUpsertRows = (table: string, rows: unknown[], opts: { onConflict: string }) => {
  if (!rest.configured) return Promise.resolve([]);
  return rest.upsert(table, rows, opts);
};
const pushEnsureDevice = createDeviceRegistrar(rest);
const pushIngest = createPushIngest({
  walStore: pushWalStore!,
  archiveObject: (args: unknown) => pushArchive.archiveObject(args),
  upsertRows: pushUpsertRows,
  projectAppend: (batch) => projectEnrolledAppend(rest, batch),
  deleteRows: (table: string, filter: unknown) => {
    if (!rest.configured) return Promise.resolve();
    return deleteReplacementRows(rest, table, filter);
  },
  ensureDevice: pushEnsureDevice,
  resolveDeviceId,
  replacementStaging: pushStaging,
  receiptStore,
});
const pushObjects = createPushObjects({
  cfg,
  rest,
  raw,
  upsertRows: pushUpsertRows,
  ensureDevice: pushEnsureDevice,
  resolveDeviceId,
  receiptStore,
});
const receiverStateId = defaultReceiverStateId(cfg);

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  });
}

function authError(err: any): Response {
  if (err instanceof IdentityError) {
    return json({ type: 'error', protocolVersion: '1.2', code: 'unauthorized' }, err.status || 401);
  }
  throw err;
}

async function authenticateUpload(req: Request) {
  try {
    const identity = await resolveUploadIdentity({
      headers: req.headers,
      rest,
      allowLegacyFleetUploads: cfg.allowLegacyFleetUploads,
    });
    if (req.method !== 'GET' && identity.sourceId &&
        !await rest.rpc('admit_noop_request',{p_user:identity.id,p_source:identity.sourceId})) {
      throw new Response(JSON.stringify({code:'intake_rate_limited'}),{status:429,
        headers:{'content-type':'application/json','retry-after':'60','cache-control':'no-store'}});
    }
    return identity;
  } catch (err) {
    if (err instanceof Response) throw err;
    throw authError(err);
  }
}

async function authenticateJwt(req: Request) {
  try {
    return await resolveJwtUser({
      headers: req.headers,
      supabaseUrl: cfg.supabaseUrl,
      anonKey: cfg.supabaseAnonKey,
    });
  } catch (err) {
    throw authError(err);
  }
}

async function authorizeEnrollment(req: Request) {
  try {
    return await resolveFleetAuthorization({ headers: req.headers, rest, fromAuthorization: true });
  } catch (err) {
    throw authError(err);
  }
}

async function handleCapabilities(req: Request): Promise<Response> {
  try {
    const user = await authenticateUpload(req);
    const version = negotiateProtocol(req.headers.get('noop-push-accept-version'));
    if (!version) return json({ type: 'error', protocolVersion: '1.2', code: 'unsupported_version' }, 406);
    const body = capabilitiesBody({
      protocolVersion: version,
      receiverStateId,
      streams: advertisedStreams(version, INGEST_ENABLED_STREAMS),
      userId: user.id,
      sourceId: user.sourceId,
      // Advertised whenever the lane can actually sign a URL. A sender that sees no `objectLane`
      // must keep its raw rows rather than assume they were taken.
      objectLane: pushObjects.configured
        ? {
          endpoint: OBJECT_LANE_PATH,
          maxObjectBytes: MAX_OBJECT_LANE_BYTES,
          urlTtlSec: UPLOAD_URL_TTL_SEC,
        }
        : null,
    });
    return json(body);
  } catch (err: any) {
    if (err instanceof Response) return err;
    const status = err.status || 500;
    return json({ type: 'error', protocolVersion: '1.2', code: err.code || 'push_failed' }, status);
  }
}

async function handleObjectIntent(req: Request): Promise<Response> {
  try {
    const user = await authenticateUpload(req);
    if (!pushObjects.configured) {
      return json({ type: 'error', protocolVersion: '1.2', code: 'object_lane_unavailable' }, 503);
    }
    const body = new Uint8Array(await req.arrayBuffer());
    if (body.length > MAX_INTENT_BYTES) {
      return json({ type: 'error', protocolVersion: '1.2', code: 'payload_too_large' }, 413);
    }
    let manifest: any;
    try {
      manifest = JSON.parse(new TextDecoder().decode(body));
    } catch {
      return json({ type: 'error', protocolVersion: '1.2', code: 'malformed_manifest' }, 400);
    }
    const intent = await pushObjects.createIntent({
      userId: user.id,
      sourceId: user.sourceId,
      tokenId: user.tokenId,
      authMode: user.authMode,
      manifest,
    });
    return json({ type: 'objectIntent', ...intent });
  } catch (err: any) {
    if (err instanceof Response) return err;
    if (err instanceof PushProtocolError) return ingestProtocolErrorResponse(err, '1.2');
    const diagnostic = unexpectedIngestDiagnostic(err, '1.2');
    console.error('[push] object intent failed:', JSON.stringify(diagnostic));
    return json(diagnostic, 500);
  }
}

async function handleObjectComplete(req: Request, objectId: string): Promise<Response> {
  try {
    const user = await authenticateUpload(req);
    if (!pushObjects.configured) {
      return json({ type: 'error', protocolVersion: '1.2', code: 'object_lane_unavailable' }, 503);
    }
    const ack = await pushObjects.completeObject({
      userId: user.id,
      sourceId: user.sourceId,
      tokenId: user.tokenId,
      authMode: user.authMode,
      objectId,
    });
    void enqueueScoringAfterIngest({ rest, userId: user.id, deviceId: ack?.deviceId })
      .catch(() => console.error('[push] scoring enqueue failed'));
    return json({ type: 'objectAck', ...ack });
  } catch (err: any) {
    if (err instanceof Response) return err;
    if (err instanceof PushProtocolError) return ingestProtocolErrorResponse(err, '1.2');
    const diagnostic = unexpectedIngestDiagnostic(err, '1.2');
    console.error('[push] object complete failed:', JSON.stringify(diagnostic));
    return json(diagnostic, 500);
  }
}

async function handleInlineBatch(req: Request): Promise<Response> {
  let protocolVersion: '1.0' | '1.1' = '1.1';
  try {
    const user = await authenticateUpload(req);
    let body = new Uint8Array(await req.arrayBuffer());
    if (body.length > MAX_BODY_BYTES) {
      return json({ type: 'error', protocolVersion: '1.1', code: 'payload_too_large' }, 413);
    }
    const encoding = String(req.headers.get('content-encoding') || '').toLowerCase();
    if (encoding === 'gzip') {
      try {
        body = new Uint8Array(gunzipSync(body, { maxOutputLength: 4 * 1024 * 1024 }));
      } catch {
        return json({ type: 'error', protocolVersion: '1.1', code: 'invalid_gzip' }, 400);
      }
    }
    if (body.length > 4 * 1024 * 1024) {
      return json({ type: 'error', protocolVersion: '1.1', code: 'decoded_body_too_large' }, 413);
    }
    protocolVersion = inlineRequestProtocol(body);
    const ack = await pushIngest.acceptBatch({
      userId: user.id,
      sourceId: user.sourceId,
      tokenId: user.tokenId,
      authMode: user.authMode,
      decodedBody: body,
    });
    void enqueueScoringAfterIngest({ rest, userId: user.id, deviceId: ack?.deviceId })
      .catch(() => console.error('[push] scoring enqueue failed'));
    return json(ack);
  } catch (err: any) {
    if (err instanceof Response) return err;
    if (err instanceof PushProtocolError) {
      return ingestProtocolErrorResponse(err, protocolVersion);
    }
    if (err?.message === 'batch_id_conflict') {
      return json({ type: 'error', protocolVersion, code: 'batch_id_conflict' }, 409);
    }
    // This pair identifies the failing stage without logging database messages or raw health data.
    const diagnostic = unexpectedIngestDiagnostic(err, protocolVersion);
    console.error('[push] unexpected ingest failure:', JSON.stringify(diagnostic));
    return json(diagnostic, 500);
  }
}

async function handleEnroll(req: Request): Promise<Response> {
  try {
    await authorizeEnrollment(req);
    if (!enrollmentService.configured) {
      return json({ type: 'error', protocolVersion: '1.1', code: 'enrollment_not_configured' }, 503);
    }
    const bytes = new Uint8Array(await req.arrayBuffer());
    if (bytes.length > MAX_INTENT_BYTES) {
      return json({ type: 'error', protocolVersion: '1.1', code: 'payload_too_large' }, 413);
    }
    let body: unknown;
    try {
      body = JSON.parse(new TextDecoder().decode(bytes));
    } catch {
      return json({ type: 'error', protocolVersion: '1.1', code: 'malformed_enrollment' }, 400);
    }
    const result = await enrollmentService.redeem(body);
    return json(result, 201);
  } catch (err: any) {
    if (err instanceof Response) return err;
    if (err instanceof EnrollmentError) {
      return json({ type: 'error', protocolVersion: '1.1', code: err.code }, err.status);
    }
    console.error('[push] enrollment failed:', err?.stack || err);
    return json({ type: 'error', protocolVersion: '1.1', code: 'enrollment_failed' }, 500);
  }
}

Deno.serve(async (req: Request) => {
  const url = new URL(req.url);
  // Accept both the deployed shape (/functions/v1/push/...) and the local `supabase functions
  // serve` shape (/push/...).
  const path = url.pathname.replace(/^\/functions\/v1/, '');
  const sub = path.replace(/^\/push/, '') || '/';

  if (req.method === 'GET' && (sub === '/' || sub === '')) {
    return handleCapabilities(req);
  }
  if (req.method === 'POST' && (sub === '/' || sub === '')) {
    return handleInlineBatch(req);
  }
  if (req.method === 'POST' && sub === '/enroll') {
    return handleEnroll(req);
  }
  if (req.method === 'POST' && sub === '/installation/retire') return installationLifecycle(req, 'retire');
  if (req.method === 'POST' && sub === '/wearables/confirm') return installationLifecycle(req, 'confirm');
  if (req.method === 'POST' && sub === '/wearables/handoff') return installationLifecycle(req, 'handoff');
  if (req.method === 'POST' && sub === '/objects') {
    return handleObjectIntent(req);
  }
  const completeMatch = /^\/objects\/([^/]+)\/complete$/.exec(sub);
  if (req.method === 'POST' && completeMatch) {
    return handleObjectComplete(req, completeMatch[1]);
  }
  if (req.method === 'POST' && sub === '/tokens') {
    return handleTokenMint(req);
  }
  if (req.method === 'GET' && sub === '/tokens') {
    return handleTokenList(req);
  }
  const tokenRevoke = /^\/tokens\/([^/]+)$/.exec(sub);
  if (req.method === 'DELETE' && tokenRevoke) {
    return handleTokenRevoke(req, tokenRevoke[1]);
  }
  return json({ type: 'error', protocolVersion: '1.2', code: 'not_found' }, 404);
});

async function requireTokenStore() {
  if (!ingestTokenStore.configured) {
    return json({ error: 'ingest token store unavailable' }, 503);
  }
  return null;
}

async function handleTokenMint(req: Request): Promise<Response> {
  try {
    const user = await authenticateJwt(req);
    const storeError = await requireTokenStore();
    if (storeError) return storeError;
    let label = '';
    try {
      const body = await req.json();
      label = (body?.label ?? '') as string;
    } catch { /* empty body is fine */ }
    const minted = await ingestTokenStore.mint({ userId: user.id, label });
    return json({ token: minted.token, ...minted.row }, 201);
  } catch (err: any) {
    if (err instanceof Response) return err;
    console.error('[push] mint ingest token failed:', err?.stack || err);
    return json({ error: 'ingest_token_mint_failed' }, 500);
  }
}

async function handleTokenList(req: Request): Promise<Response> {
  try {
    const user = await authenticateJwt(req);
    const storeError = await requireTokenStore();
    if (storeError) return storeError;
    const tokens = await ingestTokenStore.list({ userId: user.id });
    return json({ tokens });
  } catch (err: any) {
    if (err instanceof Response) return err;
    console.error('[push] list ingest tokens failed:', err?.stack || err);
    return json({ error: 'ingest_token_list_failed' }, 500);
  }
}

async function handleTokenRevoke(req: Request, id: string): Promise<Response> {
  try {
    const user = await authenticateJwt(req);
    const storeError = await requireTokenStore();
    if (storeError) return storeError;
    const revoked = await ingestTokenStore.revoke({ userId: user.id, id });
    if (!revoked) return json({ error: 'ingest_token_not_found' }, 404);
    return json(revoked);
  } catch (err: any) {
    if (err instanceof Response) return err;
    console.error('[push] revoke ingest token failed:', err?.stack || err);
    return json({ error: 'ingest_token_revoke_failed' }, 500);
  }
}
