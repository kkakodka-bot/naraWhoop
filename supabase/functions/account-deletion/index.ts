
// Scheduled/on-demand account deletion (Phase 2 port of the retired Node receiver
// createDeletionService). Resumable deletion_jobs state machine; B2 → rows → Auth, never Auth first.
import { createSupabaseRest, restConfigFromEnv } from '../_shared/rest.ts';
import { pushConfig } from '../_shared/config.ts';
import { createS3 } from '../_shared/s3.ts';
import { createDeletionService } from '../_shared/workers.ts';
import { isUuid } from '../_shared/keys.ts';
import { authorizeWorkerRequest, unauthorizedWorkerResponse } from '../_shared/workerAuth.ts';

const cfg = pushConfig();
const rest = createSupabaseRest({ cfg: restConfigFromEnv() });
const raw = cfg.b2KeyId && cfg.b2ApplicationKey && cfg.b2Bucket && cfg.b2S3Endpoint
  ? createS3({ endpoint: cfg.b2S3Endpoint, bucket: cfg.b2Bucket, region: cfg.b2Region,
               accessKeyId: cfg.b2KeyId, secretAccessKey: cfg.b2ApplicationKey, style: 'path' })
  : null;

const deletion = raw ? createDeletionService({ rest, objectStore: raw }) : null;

Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') return Response.json({ error: 'method_not_allowed' }, { status: 405 });
  if (!authorizeWorkerRequest(req, cfg)) return unauthorizedWorkerResponse();
  if (!deletion) return Response.json({ error: 'archive_not_configured' }, { status: 503 });
  let body: any = {};
  try { body = await req.json(); } catch { /* empty body — cron retry sweep */ }
  const userId = String(body.user_id || '').trim();

  try {
    if (isUuid(userId)) {
      const result = await deletion.run(userId);
      return Response.json({ ok: true, result });
    }

    // pg_cron posts {} — retry every pending/blocked deletion job.
    const pending = await rest.select(
      'deletion_jobs',
      'status=in.(pending,running,blocked)&select=*&order=created_at.asc&limit=20',
    ) as any[];
    if (!pending.length) return Response.json({ ok: true, swept: 0, results: [] });

    const results = [];
    for (const job of pending) {
      if (!isUuid(job.user_id)) continue;
      results.push({ user_id: job.user_id, result: await deletion.run(job.user_id, { existing: job }) });
    }
    return Response.json({ ok: true, swept: results.length, results });
  } catch (err: any) {
    console.error('[account-deletion] failed:', err?.stack || err);
    return Response.json({ ok: false, error: String(err?.message || err).slice(0, 300) }, { status: 500 });
  }
});
