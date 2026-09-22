// NOOP push receiver as a Supabase Edge Function — port of the retired Node receiver
//
// Routes (path after /functions/v1/push):
//   GET  /                        capabilities (version negotiation + objectLane advert)
//   POST /                        inline NDJSON batch (gzip optional)
//   POST /objects                 object-lane intent → presigned B2 PUT
//   POST /objects/:objectId/complete   byte-count check → release device rows
//
// Auth is our own (bearer JWT via Supabase Auth, or opaque `noop_` ingest token), so the function
// is deployed with --no-verify-jwt: the gateway's JWT check would reject ingest tokens.
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
import { createPushIngest, createPushArchive } from '../_shared/ingest.ts';
import { createPushWalStore } from '../_shared/wal.ts';
import { createSupabaseRest, restConfigFromEnv } from '../_shared/rest.ts';
import { createS3 } from '../_shared/s3.ts';
import { pushConfig, defaultReceiverStateId } from '../_shared/config.ts';
import { IdentityError, resolvePushUser, createIngestTokenStore } from '../_shared/tokens.ts';
import { registerDevice } from '../_shared/durability.ts';
import { commitArchivedBatch } from '../_shared/projections.ts';
import { ASYNC_OBJECT_COMPLETION, ASYNC_OBJECT_HEADER, objectCompletionResponse } from '../_shared/objectVerification.ts';

const MAX_BODY_BYTES = 4 * 1024 * 1024 + 64 * 1024;

/** Cap on an intent body. A manifest is a few hundred bytes; anything larger is not one. */
const MAX_INTENT_BYTES = 8 * 1024;

/** Advertised object-lane path, resolved by clients against the function host. */
const OBJECT_LANE_PATH = '/functions/v1/push/objects';

const cfg = pushConfig();
const rest = createSupabaseRest({ cfg: restConfigFromEnv() });
const ingestTokenStore = createIngestTokenStore({ rest });
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
const pushUpsertRows = (table: string, rows: unknown[], opts: { onConflict: string }) => {
  if (!rest.configured) return Promise.resolve([]);
  return rest.upsert(table, rows, opts);
};
const pushEnsureDevice = (row: Record<string, unknown>) => {
  if (!rest.configured) return Promise.resolve([]);
  return registerDevice(rest, row);
};
const pushIngest = createPushIngest({
  walStore: pushWalStore!,
  archiveObject: (args: unknown) => pushArchive.archiveObject(args),
  ensureDevice: pushEnsureDevice,
  commitProjection: (receipt, body) => commitArchivedBatch(rest, receipt, body),
});
const pushObjects = createPushObjects({
  cfg,
  rest,
  raw,
  upsertRows: pushUpsertRows,
  ensureDevice: pushEnsureDevice,
});
const receiverStateId = defaultReceiverStateId(cfg);

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  });
}

function protocolError(err: any): Response {
  const status = err?.status || 500;
  const body: any = { type: 'error', protocolVersion: '1.2', code: err?.code || err?.message || 'push_failed' };
  if (Array.isArray(err?.fields)) body.fields = err.fields;
  return json(body, status);
}

function authError(err: any): Response {
  if (err instanceof IdentityError) {
    return json({ type: 'error', protocolVersion: '1.2', code: 'unauthorized' }, err.status || 401);
  }
  throw err;
}

async function authenticate(req: Request) {
  try {
    return await resolvePushUser({
      headers: req.headers,
      rest,
      supabaseUrl: cfg.supabaseUrl,
      anonKey: cfg.supabaseAnonKey,
    });
  } catch (err) {
    throw authError(err);
  }
}

async function handleCapabilities(req: Request): Promise<Response> {
  try {
    const user = await authenticate(req);
    const version = negotiateProtocol(req.headers.get('noop-push-accept-version'));
    if (!version) return json({ type: 'error', protocolVersion: '1.2', code: 'unsupported_version' }, 406);
    const body = capabilitiesBody({
      protocolVersion: version,
      receiverStateId,
      streams: advertisedStreams(version, INGEST_ENABLED_STREAMS),
      userId: user.id,
      // Advertised whenever the lane can actually sign a URL. A sender that sees no `objectLane`
      // must keep its raw rows rather than assume they were taken.
      objectLane: pushObjects.configured
        ? {
          endpoint: OBJECT_LANE_PATH,
          maxObjectBytes: MAX_OBJECT_LANE_BYTES,
          urlTtlSec: UPLOAD_URL_TTL_SEC,
          ...(cfg.asyncObjectVerification ? { completionModes: ['sync', ASYNC_OBJECT_COMPLETION] } : {}),
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
    const user = await authenticate(req);
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
    const intent = await pushObjects.createIntent({ userId: user.id, manifest });
    return json({ type: 'objectIntent', ...intent });
  } catch (err: any) {
    if (err instanceof Response) return err;
    if (err instanceof PushProtocolError) return protocolError(err);
    console.error('[push] object_intent_failed');
    return json({ type: 'error', protocolVersion: '1.2', code: 'push_failed' }, 500);
  }
}

async function handleObjectComplete(req: Request, objectId: string): Promise<Response> {
  try {
    const user = await authenticate(req);
    if (!pushObjects.configured) {
      return json({ type: 'error', protocolVersion: '1.2', code: 'object_lane_unavailable' }, 503);
    }
    // Advertisement may be disabled after a job negotiated async-v1. Keep honoring that
    // persisted mode; capability rollback must not turn polls into synchronous verification.
    return await objectCompletionResponse({
      mode: req.headers.get(ASYNC_OBJECT_HEADER),
      completeSync: () => pushObjects.completeObject({ userId: user.id, objectId }),
      enqueue: () => pushObjects.requestVerification({ userId: user.id, objectId }),
      hasDebt: () => pushObjects.hasVerificationDebt({ userId: user.id, objectId }),
    });
  } catch (err: any) {
    if (err instanceof Response) return err;
    if (err instanceof PushProtocolError) return protocolError(err);
    console.error('[push] object_complete_failed');
    return json({ type: 'error', protocolVersion: '1.2', code: 'push_failed' }, 500);
  }
}

async function handleInlineBatch(req: Request): Promise<Response> {
  try {
    const user = await authenticate(req);
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
    const ack = await pushIngest.acceptBatch({ userId: user.id, decodedBody: body });
    return json(ack);
  } catch (err: any) {
    if (err instanceof Response) return err;
    if (err instanceof PushProtocolError) {
      return json({ type: 'error', protocolVersion: '1.1', code: err.message }, err.status);
    }
    if (err?.message === 'batch_id_conflict') {
      return json({ type: 'error', protocolVersion: '1.1', code: 'batch_id_conflict' }, 409);
    }
    // The client can attribute every other branch from its receiver code; this one it sees as a bare
    // 500. Log the cause here or the only record of why a batch was refused is lost.
    console.error('[push] ingest_failed');
    return json({ type: 'error', protocolVersion: '1.1', code: 'push_failed' }, 500);
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
  const user = await authenticate(req);
  const storeError = await requireTokenStore();
  if (storeError) return storeError;
  try {
    let label = '';
    try {
      const body = await req.json();
      label = (body?.label ?? '') as string;
    } catch { /* empty body is fine */ }
    const minted = await ingestTokenStore.mint({ userId: user.id, label });
    return json({ token: minted.token, ...minted.row }, 201);
  } catch (err: any) {
    console.error('[push] mint ingest token failed:', err?.stack || err);
    return json({ error: 'ingest_token_mint_failed' }, 500);
  }
}

async function handleTokenList(req: Request): Promise<Response> {
  const user = await authenticate(req);
  const storeError = await requireTokenStore();
  if (storeError) return storeError;
  try {
    const tokens = await ingestTokenStore.list({ userId: user.id });
    return json({ tokens });
  } catch (err: any) {
    console.error('[push] list ingest tokens failed:', err?.stack || err);
    return json({ error: 'ingest_token_list_failed' }, 500);
  }
}

async function handleTokenRevoke(req: Request, id: string): Promise<Response> {
  const user = await authenticate(req);
  const storeError = await requireTokenStore();
  if (storeError) return storeError;
  try {
    const revoked = await ingestTokenStore.revoke({ userId: user.id, id });
    if (!revoked) return json({ error: 'ingest_token_not_found' }, 404);
    return json(revoked);
  } catch (err: any) {
    console.error('[push] revoke ingest token failed:', err?.stack || err);
    return json({ error: 'ingest_token_revoke_failed' }, 500);
  }
}
