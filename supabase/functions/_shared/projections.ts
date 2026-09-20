import { createHash } from 'node:crypto';
import { noopDeviceId } from './keys.ts';
import { APPEND_STREAM_PROJECTIONS, REPLACE_STREAM_PROJECTIONS, parseNdjsonEntity,
  replacementKeys, ackMatchesBatch, PushProtocolError, schemaVersionFor } from './registry.ts';
import { sha256Hex, type S3Store } from './s3.ts';
import type { SupabaseRest } from './rest.ts';
import type { DurabilityReceipt } from './durability.ts';

export const MAX_INLINE_ARCHIVE_BYTES = 4 * 1024 * 1024 + 64 * 1024;

/** Both the live request and server repair use the same mapper and atomic SQL settlement. */
export async function commitArchivedBatch(rest: SupabaseRest, receipt: DurabilityReceipt,
  decodedBody: Uint8Array, leaseToken: string | null = null) {
  const { header, records } = parseNdjsonEntity(decodedBody);
  const digest = sha256Hex(decodedBody);
  if (decodedBody.length > MAX_INLINE_ARCHIVE_BYTES || receipt.state !== 'verified_indexed' || receipt.version !== 1 ||
      receipt.contentSha256 !== digest || receipt.uncompressedBytes !== decodedBody.length ||
      receipt.batchId !== header.batchId || receipt.objectId !== header.batchId || receipt.sourceId !== header.sourceId ||
      receipt.stream !== header.stream || receipt.schemaVersion !== schemaVersionFor(header.stream, header.protocolVersion) ||
      receipt.deviceId !== noopDeviceId(receipt.ownerUserId, header.deviceId)) {
    throw new Error('projection_archive_mismatch');
  }
  const projection = header.delivery === 'append' ? APPEND_STREAM_PROJECTIONS[header.stream]
    : header.delivery === 'replace_window' ? REPLACE_STREAM_PROJECTIONS[header.stream] : null;
  if (!projection) throw new Error('unsupported_projection');
  const rows = records.map((record) => projection.mapRow({
    userId: receipt.ownerUserId, deviceId: receipt.deviceId, sourceId: header.sourceId,
    batchId: header.batchId, headerDeviceId: header.deviceId, record,
    replacementId: header.window?.replacementId || header.batchId, protocolVersion: header.protocolVersion,
  })).filter(Boolean);
  const ack = await rest.rpc('noop_commit_push_projection', {
    p_object_id: receipt.objectId, p_body_sha256: digest, p_header: header, p_rows: rows,
    p_keep_keys: [...replacementKeys(header.stream, records, header.deviceId)], p_token: leaseToken,
  }).catch((error: unknown) => {
    if (error instanceof Error && error.message.includes('scalar_identity_conflict')) {
      throw new PushProtocolError('scalar_identity_conflict', 409);
    }
    throw error;
  });
  if (!ackMatchesBatch(ack, header) || Object.keys(receipt).some((key) =>
    ack.durabilityReceipt?.[key] !== receipt[key as keyof DurabilityReceipt])) throw new Error('projection_ack_mismatch');
  return ack;
}

/** Decode only bounded inline NDJSON, validating the exact bytes being replayed, not a prior GET. */
async function readVerifiedArchive(raw: S3Store, manifest: any): Promise<Uint8Array> {
  const receipt = manifest.durability_receipt as DurabilityReceipt;
  if (!String(manifest.format).startsWith('ndjson') || manifest.compression !== 'gzip' ||
      receipt?.state !== 'verified_indexed' || receipt.objectKey !== manifest.object_key ||
      receipt.objectId !== manifest.id || receipt.ownerUserId !== manifest.user_id || receipt.deviceId !== manifest.device_id ||
      !Number.isSafeInteger(receipt.uncompressedBytes) || receipt.uncompressedBytes <= 0 || receipt.uncompressedBytes > MAX_INLINE_ARCHIVE_BYTES ||
      !Number.isSafeInteger(receipt.compressedBytes) || receipt.compressedBytes <= 0 || receipt.compressedBytes > MAX_INLINE_ARCHIVE_BYTES + 65536) {
    throw new Error('projection_archive_mismatch');
  }
  const response = await raw.getObjectStream(receipt.objectKey);
  if (!response?.body) throw new Error('projection_archive_missing');
  const wireHash = createHash('sha256');
  const decodedHash = createHash('sha256');
  let wireBytes = 0;
  let decodedBytes = 0;
  const chunks: Uint8Array[] = [];
  const wire = response.body.pipeThrough(new TransformStream<Uint8Array, Uint8Array>({
    transform(chunk, controller) {
      wireBytes += chunk.length;
      if (wireBytes > receipt.compressedBytes) throw new Error('projection_wire_size_mismatch');
      wireHash.update(chunk); controller.enqueue(chunk);
    },
  }));
  const decoded = wire.pipeThrough(new DecompressionStream('gzip') as ReadableWritablePair<Uint8Array, Uint8Array>);
  for await (const chunk of decoded) {
    decodedBytes += chunk.length;
    if (decodedBytes > receipt.uncompressedBytes) throw new Error('projection_decoded_size_mismatch');
    decodedHash.update(chunk); chunks.push(chunk);
  }
  if (wireBytes !== receipt.compressedBytes || decodedBytes !== receipt.uncompressedBytes ||
      wireHash.digest('hex') !== receipt.wireSha256 || decodedHash.digest('hex') !== receipt.contentSha256) {
    throw new Error('projection_digest_mismatch');
  }
  const bytes = new Uint8Array(decodedBytes);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  return bytes;
}

export async function reconcileProjections(rest: SupabaseRest, raw: S3Store, limit = 16) {
  const boundedLimit = Math.max(1, Math.min(64, Math.trunc(limit) || 16));
  await rest.rpc('noop_seed_projection_debt', { p_limit: boundedLimit });
  const report = { scanned: 0, settled: 0, deferred: 0 };
  for (let count = 0; count < boundedLimit; count++) {
    const job = await rest.rpc('noop_claim_projection_debt', {});
    if (!job) break;
    report.scanned++;
    try {
      const bytes = await readVerifiedArchive(raw, job.manifest);
      await commitArchivedBatch(rest, job.manifest.durability_receipt, bytes, job.leaseToken);
      report.settled++;
    } catch {
      report.deferred++;
      await rest.rpc('noop_fail_projection_debt', { p_object_id: job.manifest.id, p_token: job.leaseToken });
    }
  }
  return report;
}
