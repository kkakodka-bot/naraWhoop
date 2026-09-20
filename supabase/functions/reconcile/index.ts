
// Scheduled manifest reconcile (Phase 2 port of the retired Node receiver reconcileObjects).
// Auth: WORKER_SECRET or service-role bearer (see retention-sweep).
import { createSupabaseRest, restConfigFromEnv } from '../_shared/rest.ts';
import { pushConfig } from '../_shared/config.ts';
import { createS3 } from '../_shared/s3.ts';
import { reconcileObjects } from '../_shared/workers.ts';
import { authorizeWorkerRequest, unauthorizedWorkerResponse } from '../_shared/workerAuth.ts';
import { reconcileIntake } from '../_shared/durability.ts';
import { reconcileProjections } from '../_shared/projections.ts';

const cfg = pushConfig();
const rest = createSupabaseRest({ cfg: restConfigFromEnv() });
const raw = cfg.b2KeyId && cfg.b2ApplicationKey && cfg.b2Bucket && cfg.b2S3Endpoint
  ? createS3({ endpoint: cfg.b2S3Endpoint, bucket: cfg.b2Bucket, region: cfg.b2Region,
               accessKeyId: cfg.b2KeyId, secretAccessKey: cfg.b2ApplicationKey, style: 'path' })
  : null;

Deno.serve(async (req: Request) => {
  if (!authorizeWorkerRequest(req, cfg)) return unauthorizedWorkerResponse();
  if (!raw) return Response.json({ error: 'archive_not_configured' }, { status: 503 });
  const url = new URL(req.url);
  const userId = url.searchParams.get('user_id') || undefined;
  try {
    const intake = await reconcileIntake(rest, raw);
    const projections = await reconcileProjections(rest, raw);
    const report = await reconcileObjects({ rest, objectStore: raw, userId });
    return Response.json({ ok: true, report, intake, projections });
  } catch (err: any) {
    console.error('[reconcile] intake_reconcile_failed');
    return Response.json({ ok: false, error: 'reconcile_failed' }, { status: 500 });
  }
});
