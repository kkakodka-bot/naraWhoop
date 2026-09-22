import { completeDurableObject, intakeError } from './durability.ts';
import { PushProtocolError } from './registry.ts';
import type { SupabaseRest } from './rest.ts';
import type { S3Store } from './s3.ts';

export const ASYNC_OBJECT_COMPLETION = 'async-v1';
export const ASYNC_OBJECT_HEADER = 'Noop-Push-Completion';

/** Shared by the authenticated HTTP handler and native tests; no opt-in means unchanged sync. */
export async function objectCompletionResponse({ mode, completeSync, enqueue, hasDebt }: {
  mode: string | null;
  completeSync: () => Promise<Record<string, unknown>>;
  enqueue: () => ReturnType<typeof requestObjectVerification>;
  hasDebt: () => Promise<boolean>;
}) {
  const pending = async () => {
    const result = await enqueue();
    return new Response(JSON.stringify(result.body), { status: result.status, headers: {
      'content-type': 'application/json', ...(result.retryAfter ? { 'retry-after': result.retryAfter } : {}),
    } });
  };
  if (mode === ASYNC_OBJECT_COMPLETION || await hasDebt()) return await pending();
  try { return Response.json({ type: 'objectAck', ...await completeSync() }); }
  catch (err) {
    // Enqueue can race the preceding lookup. The manifest-locked COPY reservation is the
    // final authority, so a mode downgrade still joins the durable pending/paused flow.
    if (err instanceof PushProtocolError && err.code === 'async_verification_required') return await pending();
    throw err;
  }
}

/** A pending response is deliberately non-2xx: existing clients require an exact receipt for 2xx. */
export async function requestObjectVerification(rest: SupabaseRest, userId: string, objectId: string) {
  let value: any;
  try { value = await rest.rpc('noop_enqueue_object_verification', { p_user_id: userId, p_object_id: objectId }); }
  catch (err) {
    if (err instanceof Error && err.message.includes('missing_manifest')) throw new PushProtocolError('missing_manifest', 404);
    intakeError(err);
  }
  const protocolVersion = value.protocolVersion ?? '1.2';
  if (value.state === 'complete' && value.receipt?.version === 1 && value.receipt?.state === 'verified_indexed') {
    return { status: 200, retryAfter: null, body: {
      type: 'objectAck', protocolVersion, objectId, status: 'ready', objectKey: value.receipt.objectKey,
      durabilityReceipt: value.receipt, duplicate: true,
    } };
  }
  if (value.state === 'paused_terminal') {
    const status = [400, 403, 404, 409, 413, 422].includes(value.failureStatus) ? value.failureStatus : 422;
    return { status, retryAfter: null, body: {
      type: 'error', protocolVersion, objectId, code: value.code ?? 'verification_failed', state: 'paused_terminal',
    } };
  }
  if (!['pending', 'leased', 'retry'].includes(value.state)) throw new Error('invalid_verification_debt');
  return { status: 503, retryAfter: String(value.retryAfter), body: {
    type: 'error', protocolVersion, objectId, code: 'verification_pending', state: 'pending_verification',
  } };
}

/** Serial, leased verification. Budgets stop admission between objects, not an in-flight storage call.
 * HEAD has a 30s timeout; COPY/streamed GET have 120s timeouts. No hard 10s execution claim.
 */
export async function reconcileObjectVerification(rest: SupabaseRest, raw: S3Store, {
  limit = 4, maxBytes = 256 * 1024 * 1024, maxDecodedBytes = 512 * 1024 * 1024,
  maxMilliseconds = 10_000, clock = () => performance.now(),
} = {}) {
  const cap = Math.max(0, Math.min(16, Math.floor(limit)));
  const bytesCap = Math.max(0, Math.min(256 * 1024 * 1024, Math.floor(maxBytes)));
  const decodedCap = Math.max(0, Math.min(512 * 1024 * 1024, Math.floor(maxDecodedBytes)));
  const started = clock();
  const report = { claimed: 0, verifiedIndexed: 0, retry: 0, paused: 0, leaseLost: 0, deferred: 0,
    admittedBytes: 0, admittedDecodedBytes: 0, verificationMs: 0 };
  while (report.claimed < cap && clock() - started < Math.max(0, maxMilliseconds)) {
    const claimed = await rest.rpc('noop_claim_object_verification', {
      p_max_bytes: bytesCap - report.admittedBytes,
      p_max_decoded_bytes: decodedCap - report.admittedDecodedBytes,
    });
    if (!claimed) break;
    const row = claimed.manifest;
    report.claimed++;
    report.admittedBytes += Number(row.compressed_bytes);
    report.admittedDecodedBytes += Number(row.uncompressed_bytes ?? 512 * 1024 * 1024);
    if (clock() - started >= Math.max(0, maxMilliseconds)) {
      await rest.rpc('noop_defer_object_verification', { p_object_id: row.id, p_lease_token: claimed.token });
      report.deferred++; break;
    }
    const before = clock();
    let failureCode: string | null = null, failureStatus = 503, retryable = true;
    try {
      // Receipt commit may have succeeded just before the worker or its HTTP response died.
      const prior = await rest.rpc('noop_current_object_receipt', { p_user_id: row.user_id, p_object_id: row.id });
      if (!prior && clock() - started >= Math.max(0, maxMilliseconds)) {
        await rest.rpc('noop_defer_object_verification', { p_object_id: row.id, p_lease_token: claimed.token });
        report.deferred++; break;
      }
      if (!prior) {
        await completeDurableObject({ rest, raw, row, verificationToken: claimed.token });
        const verified = await rest.rpc('noop_current_object_receipt', { p_user_id: row.user_id, p_object_id: row.id });
        if (!verified) throw new PushProtocolError('receipt_mismatch', 409);
      }
    } catch (err) {
      failureCode = err instanceof PushProtocolError ? err.code : 'verification_failed';
      failureStatus = err instanceof PushProtocolError ? err.status : 503;
      retryable = [408, 429].includes(failureStatus) || failureStatus >= 500;
    }
    const duration = Math.max(0, Math.round(clock() - before));
    report.verificationMs += duration;
    // One token can settle only once. The RPC also heals a lost receipt response from durable state.
    const settled = await rest.rpc('noop_finish_object_verification', {
      p_object_id: row.id, p_lease_token: claimed.token, p_failure_code: failureCode,
      p_failure_status: failureStatus, p_retryable: retryable, p_verification_ms: duration,
    });
    if (!settled) report.leaseLost++;
    else {
      const saved = await rest.rpc('noop_current_object_receipt', { p_user_id: row.user_id, p_object_id: row.id });
      if (saved) report.verifiedIndexed++;
      else if (retryable) report.retry++;
      else report.paused++;
    }
  }
  return report;
}
