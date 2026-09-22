import type { SupabaseRest } from './rest.ts';
import type { S3Store } from './s3.ts';

/** Service-only maintenance. Database claims exclude current receipts and fence late publishers. */
export async function sweepCopyIntents(rest: SupabaseRest, raw: Pick<S3Store, 'head' | 'deleteObject'>,
  { limit = 16, maxBytes = 512 * 1024 * 1024, maxMilliseconds = 10_000,
    clock = () => performance.now() } = {}) {
  const started = clock();
  const report = { claimed: 0, deleted: 0, absent: 0, failed: 0, deferred: 0, deletedBytes: 0 };
  const intents = await rest.rpc('noop_claim_copy_orphans', { p_limit: limit, p_max_bytes: maxBytes });
  report.claimed = intents.length;
  for (const intent of intents) {
    if (clock() - started >= maxMilliseconds) { report.deferred++; continue; }
    try {
      const head = await raw.head(intent.key);
      if (head?.exists) {
        if (!head.versionId) throw new Error('object_version_missing');
        // B2 retains versioned bytes behind an ordinary delete marker. Delete the exact
        // version observed at the server-only key; a late COPY stays discoverable on recheck.
        await raw.deleteObject(intent.key, { versionId: head.versionId });
        report.deleted++;
        report.deletedBytes += Number(intent.bytes);
      } else { report.absent++; }
      await rest.rpc('noop_finish_copy_sweep', {
        p_intent_id: intent.id, p_sweep_token: intent.token, p_succeeded: true,
      });
    } catch {
      report.failed++;
      await rest.rpc('noop_finish_copy_sweep', {
        p_intent_id: intent.id, p_sweep_token: intent.token, p_succeeded: false,
      }).catch(() => {});
    }
  }
  return report;
}
