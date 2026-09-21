// Ops-only ingest pipeline verification (slim rewrite of backend /api/ingest/verify).
// Auth: WORKER_SECRET or service-role bearer — not user-scoped (behavior change from Node).
import { createSupabaseRest, restConfigFromEnv } from '../_shared/rest.ts';
import { pushConfig } from '../_shared/config.ts';
import { createS3 } from '../_shared/s3.ts';
import { buildIngestVerifyReport } from '../_shared/ingestVerify.ts';
import { authorizeWorkerRequest, unauthorizedWorkerResponse } from '../_shared/workerAuth.ts';

const cfg = pushConfig();
const rest = createSupabaseRest({ cfg: restConfigFromEnv() });
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

Deno.serve(async (req: Request) => {
  if (req.method !== 'GET') return Response.json({ error: 'method_not_allowed' }, { status: 405 });
  if (!authorizeWorkerRequest(req, cfg)) return unauthorizedWorkerResponse();
  if (!rest.configured) return Response.json({ error: 'service_role_unconfigured' }, { status: 503 });

  const url = new URL(req.url);
  const userId = url.searchParams.get('user_id') || '';
  const day = url.searchParams.get('day') || new Date().toISOString().slice(0, 10);

  try {
    const report = await buildIngestVerifyReport({
      rest,
      objectStore: raw,
      userId,
      day,
      sourceId: url.searchParams.get('source_id') ?? undefined,
      deviceId: url.searchParams.get('device_id') ?? undefined,
    });
    return Response.json(report);
  } catch (err: any) {
    const code = err?.code;
    if (code === 'unauthorized') return Response.json({ error: 'user required' }, { status: 400 });
    if (code === 'invalid_day') return Response.json({ error: 'invalid day' }, { status: 400 });
    if (code === 'invalid_scope') return Response.json({ error: 'source and device required' }, { status: 400 });
    console.error('[ingest-verify] failed');
    return Response.json({ error: 'ingest_verify_failed' }, { status: 500 });
  }
});
