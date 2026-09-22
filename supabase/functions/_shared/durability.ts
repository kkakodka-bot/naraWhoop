import { createHash } from 'node:crypto';
import { Decompress } from 'npm:fzstd@0.1.1';
import type { SupabaseRest } from './rest.ts';
import type { S3Store } from './s3.ts';
import { PushProtocolError } from './registry.ts';
import { MAX_OBJECT_LANE_BYTES } from './retention.ts';
import { ZstdBounds } from './zstdBounds.ts';
import { AuxiliaryIdentityValidator } from './auxiliaryIdentity.ts';

// Streaming verification bounds output even when the compressed input is small.
export const MAX_DECODED_OBJECT_BYTES = 512 * 1024 * 1024;

export interface DurabilityReceipt {
  version: 1;
  state: 'verified_indexed';
  receiptId: string;
  ownerUserId: string;
  deviceId: string;
  objectId: string;
  batchId: string | null;
  sourceId: string | null;
  stream: string;
  schemaVersion: number;
  objectKey: string;
  contentSha256: string;
  wireSha256: string;
  compressedBytes: number;
  uncompressedBytes: number;
  verifiedAt: string;
  indexedAt: string;
}

// Do not expose storage, SQL, or authentication response bodies to callers or logs.
export function intakeError(err: unknown): never {
  const message = err instanceof Error ? err.message : '';
  for (const code of ['device_owner_conflict', 'object_owner_conflict']) {
    if (message.includes(code)) throw new PushProtocolError(code, 403);
  }
  for (const code of ['batch_id_conflict', 'object_id_conflict', 'receipt_immutable', 'object_unavailable']) {
    if (message.includes(code)) throw new PushProtocolError(code, 409);
  }
  throw err;
}

export async function registerDevice(rest: SupabaseRest, row: Record<string, unknown>) {
  try {
    return await rest.rpc('noop_register_push_device', {
      p_user_id: row.user_id, p_device_id: row.id, p_external_device_id: row.external_device_id,
    });
  } catch (err) { intakeError(err); }
}

export async function reserveManifest(rest: SupabaseRest, row: Record<string, unknown>) {
  try { return await rest.rpc('noop_reserve_object_manifest', { p_manifest: row }); }
  catch (err) { intakeError(err); }
}

function mismatch(code: string): never { throw new PushProtocolError(code, 409); }

/** Reads the snapshot, not the mutable presigned PUT target. No whole-object buffering. */
export async function verifyStoredObject(raw: S3Store, row: any, key: string) {
  const expectedWire = Number(row.compressed_bytes);
  const expectedDecoded = row.uncompressed_bytes == null ? null : Number(row.uncompressed_bytes);
  if (!Number.isSafeInteger(expectedWire) || expectedWire <= 0 || expectedWire > MAX_OBJECT_LANE_BYTES ||
      (expectedDecoded != null && (!Number.isSafeInteger(expectedDecoded) || expectedDecoded <= 0 ||
        expectedDecoded > MAX_DECODED_OBJECT_BYTES))) mismatch('invalid_object_size');
  const response = await raw.getObjectStream(key);
  if (!response?.body) mismatch('object_missing');
  const wireHash = createHash('sha256');
  const contentHash = createHash('sha256');
  let compressedBytes = 0;
  let uncompressedBytes = 0;
  const auxiliary = row.object_kind === 'v18AuxSample' && row.push_protocol_version === '1.4'
    ? new AuxiliaryIdentityValidator(Number(row.sample_count), Date.parse(row.start_at) / 1000, Date.parse(row.end_at) / 1000) : null;
  const countWire = new TransformStream<Uint8Array, Uint8Array>({
    transform(chunk, controller) {
      compressedBytes += chunk.length;
      if (compressedBytes > expectedWire) mismatch('size_mismatch');
      wireHash.update(chunk);
      controller.enqueue(chunk);
    },
  });
  const wire = response.body.pipeThrough(countWire);
  let decoded: ReadableStream<Uint8Array>;
  if (row.compression === 'gzip') {
    decoded = wire.pipeThrough(new DecompressionStream('gzip') as ReadableWritablePair<Uint8Array, Uint8Array>);
  } else if (row.compression === 'zstd') {
    let decoder: Decompress;
    const bounds = new ZstdBounds(expectedDecoded ?? MAX_DECODED_OBJECT_BYTES);
    decoded = wire.pipeThrough(new TransformStream<Uint8Array, Uint8Array>({
      start(controller) {
        decoder = new Decompress((chunk) => {
          // Count in this callback, before enqueueing; a highly compressible input chunk may
          // synchronously produce many output chunks before the downstream reader runs.
          uncompressedBytes += chunk.length;
          if (uncompressedBytes > (expectedDecoded ?? MAX_DECODED_OBJECT_BYTES)) mismatch('decoded_size_mismatch');
          contentHash.update(chunk);
          controller.enqueue(new Uint8Array(0));
        });
      },
      transform(chunk) { bounds.push(chunk); decoder.push(chunk); },
      flush() { bounds.finish(); decoder.push(new Uint8Array(0), true); },
    }));
  } else { await wire.cancel(); mismatch('unsupported_compression'); }
  try {
    for await (const chunk of decoded) {
      if (row.compression === 'zstd') continue;
      uncompressedBytes += chunk.length;
      if (uncompressedBytes > (expectedDecoded ?? MAX_DECODED_OBJECT_BYTES)) mismatch('decoded_size_mismatch');
      contentHash.update(chunk);
      auxiliary?.push(chunk);
    }
  } catch (err) {
    if (err instanceof PushProtocolError) throw err;
    mismatch('invalid_compressed_object');
  }
  if (compressedBytes !== expectedWire) mismatch('size_mismatch');
  if (expectedDecoded != null && uncompressedBytes !== expectedDecoded) mismatch('decoded_size_mismatch');
  const wireSha256 = wireHash.digest('hex');
  const contentSha256 = contentHash.digest('hex');
  // Old inline manifests recorded the gzip digest; old binary manifests recorded decoded SHA.
  const scope = row.digest_scope ?? (String(row.format).startsWith('ndjson') ? 'wire' : 'decoded');
  if ((scope === 'wire' ? wireSha256 : contentSha256) !== String(row.sha256).toLowerCase()) mismatch('digest_mismatch');
  return { compressedBytes, uncompressedBytes, wireSha256, contentSha256,
    auxiliaryValidation: auxiliary?.finish() };
}

export async function completeDurableObject({ rest, raw, row }: {
  rest: SupabaseRest; raw: S3Store; row: any;
}): Promise<DurabilityReceipt> {
  if (['deleted', 'deleting', 'expired'].includes(row.status)) mismatch('object_unavailable');
  const owner = await rest.select('devices', `id=eq.${row.device_id}&user_id=eq.${row.user_id}&select=id`);
  if (!owner.length) throw new PushProtocolError('device_owner_conflict', 403);
  let prior = row.durability_receipt as DurabilityReceipt | null;
  // Reserve a unique server-only key durably before COPY. An ambiguous outcome remains tracked;
  // only the leased receipt transaction may publish it and only the sweeper may retire it.
  const uploadKey = row.upload_object_key || row.object_key;
  let intent: any = null;
  if (!prior) {
    try {
      const reserved = await rest.rpc('noop_reserve_copy_intent', { p_user_id: row.user_id, p_object_id: row.id });
      if (reserved?.receipt) prior = reserved.receipt;
      else {
        if (!reserved?.id || !reserved.lease_token || !reserved.verified_key || reserved.upload_key !== uploadKey) {
          throw new Error('invalid_copy_intent');
        }
        intent = reserved;
      }
    } catch (err) {
      if (err instanceof Error && err.message.includes('copy_attempt_limit')) {
        throw new PushProtocolError('copy_attempt_limit', 503);
      }
      intakeError(err);
    }
  }
  const verifiedKey = prior?.objectKey || intent.verified_key;
  let failureCode = 'copy_failed';
  try {
    if (!prior) {
      const head = await raw.head(uploadKey);
      if (!head?.exists || (head.contentLength != null && Number(head.contentLength) !== Number(row.compressed_bytes))) {
        mismatch(!head?.exists ? 'object_missing' : 'size_mismatch');
      }
      await raw.copyObject(uploadKey, verifiedKey);
    }
    failureCode = 'verification_failed';
    const started = performance.now();
    const verified = await verifyStoredObject(raw, row, verifiedKey);
    failureCode = 'receipt_failed';
    const verifiedArgs = {
      p_wire_sha256: verified.wireSha256, p_content_sha256: verified.contentSha256,
      p_compressed_bytes: verified.compressedBytes, p_uncompressed_bytes: verified.uncompressedBytes,
    };
    const receipt: DurabilityReceipt = intent
      ? await rest.rpc('noop_commit_copy_receipt', {
        p_intent_id: intent.id, p_lease_token: intent.lease_token, ...verifiedArgs,
        p_verification_ms: Math.max(0, Math.round(performance.now() - started)),
        p_validation: verified.auxiliaryValidation ?? null,
      })
      : await rest.rpc(verified.auxiliaryValidation ? 'noop_commit_aux_object_receipt' : 'noop_commit_object_receipt', {
        p_user_id: row.user_id, p_object_id: row.id, p_verified_key: verifiedKey, ...verifiedArgs,
        ...(verified.auxiliaryValidation ? { p_validation: verified.auxiliaryValidation } : {}),
      });
    if (receipt.version !== 1 || receipt.state !== 'verified_indexed') throw new Error('invalid_durability_receipt');
    return receipt;
  } catch (err) {
    if (intent) await rest.rpc('noop_abandon_copy_intent', {
      p_intent_id: intent.id, p_lease_token: intent.lease_token, p_failure_code: failureCode,
    }).catch(() => {});
    // A failed or ambiguous commit never demotes a concurrent successful receipt.
    if (!prior) await rest.request(`object_manifests?id=eq.${row.id}&durability_receipt=is.null`, {
      method: 'PATCH', body: { status: 'failed' },
    }).catch(() => {});
    intakeError(err);
  }
}

/** The DB cursor persists across stateless worker invocations and wraps after the last page. */
export async function reconcileIntake(rest: SupabaseRest, raw: S3Store, limit = 16) {
  const rows = await rest.rpc('noop_intake_reconcile_page', { p_limit: limit });
  const report = { scanned: 0, verifiedIndexed: 0, deferred: 0 };
  for (const row of rows) {
    report.scanned++;
    try { await completeDurableObject({ rest, raw, row }); report.verifiedIndexed++; }
    catch { report.deferred++; }
  }
  return report;
}
