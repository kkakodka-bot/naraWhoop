// Authenticated direct-to-bucket intake. Upload targets are not durability receipts.
import {
  OBJECT_LANE_RECORD_HZ,
  OBJECT_LANE_STREAMS,
  looksLikePii,
  isUuid,
  noopDeviceId,
  pushArchiveSpecForStream,
  rawObjectKeyV3,
} from './keys.ts';
import { MAX_OBJECT_LANE_BYTES, MAX_RANGE_MS, expiresAt } from './retention.ts';
import { createManifestStore, type ManifestStore } from './manifests.ts';
import { completeDurableObject, registerDevice, reserveManifest, MAX_DECODED_OBJECT_BYTES } from './durability.ts';
import { PushProtocolError, schemaVersionFor } from './registry.ts';
import type { SupabaseRest } from './rest.ts';
import type { S3Store } from './s3.ts';
import type { PushFunctionConfig } from './config.ts';
import { requestObjectVerification } from './objectVerification.ts';

/** Presigned PUT lifetime. Long enough for a large object on a slow link, short enough to expire. */
export const UPLOAD_URL_TTL_SEC = 15 * 60;

const SHA_RE = /^[0-9a-f]{64}$/i;
const MIN_PLAUSIBLE_UNIX = 1_400_000_000;

/** Only stored-byte verification plus the index transaction earns server_verified. */
export const SHA_SOURCE = Object.freeze({ claimed: 'client_claimed', verified: 'server_verified' });

function fail(code: string, status = 400): PushProtocolError {
  return new PushProtocolError(code, status);
}

/**
 * Validates the `binaryObject` manifest the device already builds for the inline lane, plus the
 * `compressedBytes` the direct lane needs. Committing the byte count BEFORE the upload is what makes
 * the completion check meaningful — a count supplied afterwards would just describe whatever landed.
 */
export function validateObjectIntent(manifest: any) {
  const errors: string[] = [];
  const m = manifest || {};
  const protocolVersion = m.protocolVersion ?? '1.2';
  const schemaVersion = m.schemaVersion ?? schemaVersionFor(m.stream, protocolVersion);
  if (!['1.2', '1.3', '1.4'].includes(protocolVersion)) errors.push('protocolVersion');
  if (m.type !== 'binaryObject') errors.push('type');
  if (!OBJECT_LANE_STREAMS.has(m.stream)) errors.push('stream');
  if (!isUuid(m.objectId)) errors.push('objectId');
  if (!isUuid(m.batchId)) errors.push('batchId');
  if (!isUuid(m.sourceId)) errors.push('sourceId');
  if (typeof m.deviceId !== 'string' || !m.deviceId || looksLikePii(m.deviceId)) errors.push('deviceId');

  const startTs = Number(m.startTs);
  const endTs = Number(m.endTs);
  if (!Number.isInteger(startTs) || startTs < MIN_PLAUSIBLE_UNIX) errors.push('startTs');
  if (!Number.isInteger(endTs) || endTs <= startTs) errors.push('endTs');
  if (Number.isInteger(startTs) && Number.isInteger(endTs) && (endTs - startTs) * 1000 > MAX_RANGE_MS) {
    errors.push('window');
  }

  const sampleCount = Number(m.sampleCount);
  if (!Number.isInteger(sampleCount) || sampleCount < 0) errors.push('sampleCount');
  const uncompressedBytes = Number(m.uncompressedBytes);
  if (!Number.isSafeInteger(uncompressedBytes) || uncompressedBytes <= 0 || uncompressedBytes > MAX_DECODED_OBJECT_BYTES) errors.push('uncompressedBytes');
  if (schemaVersion !== schemaVersionFor(m.stream, protocolVersion)) errors.push('schemaVersion');
  const compressedBytes = Number(m.compressedBytes);
  if (!Number.isInteger(compressedBytes) || compressedBytes <= 0 || compressedBytes > MAX_OBJECT_LANE_BYTES) {
    errors.push('compressedBytes');
  }
  if (!SHA_RE.test(String(m.contentSha256 || ''))) errors.push('contentSha256');

  // The wire encoding is a property of the stream, not a client choice: the reader picks its
  // decompressor from the stream registry, so an object encoded some other way is unreadable.
  if (OBJECT_LANE_STREAMS.has(m.stream)) {
    const spec = pushArchiveSpecForStream(m.stream);
    if (m.contentEncoding !== spec.compression) errors.push('contentEncoding');
  }
  // Paths are minted here. A client-chosen key is how one subject writes into another's prefix.
  if (m.objectKey || m.object_key) errors.push('objectKey');

  return {
    ok: errors.length === 0,
    errors,
    startTs,
    endTs,
    sampleCount,
    uncompressedBytes,
    compressedBytes,
    protocolVersion,
    schemaVersion,
  };
}

/**
 * Coverage for one object, from the stream's nominal record rate. Reported as expected/received
 * counts rather than a filled series: a gap in a seizure corpus must stay legible as absence, and
 * an interpolated stretch looks exactly like quiet data. `null` when the stream has no fixed rate.
 */
export function windowCoverage({ stream, startTs, endTs, sampleCount }: {
  stream: string;
  startTs: number;
  endTs: number;
  sampleCount: number;
}) {
  const hz = OBJECT_LANE_RECORD_HZ[stream];
  const seconds = Math.max(0, Number(endTs) - Number(startTs));
  if (hz == null || !seconds) {
    return { expectedRecords: null, receivedRecords: sampleCount, coverage: null, missingRecords: null };
  }
  const expectedRecords = Math.round(seconds * hz);
  const missingRecords = Math.max(0, expectedRecords - sampleCount);
  return {
    expectedRecords,
    receivedRecords: sampleCount,
    coverage: expectedRecords ? Math.min(1, sampleCount / expectedRecords) : null,
    missingRecords,
  };
}

/**
 * Direct-to-bucket lane for the high-rate raw streams.
 *
 * Completion reads a server-only snapshot, checks both digests and sizes, and atomically
 * publishes the coverage index and durability receipt. A bare ready flag is insufficient.
 */
export function createPushObjects({
  cfg,
  rest,
  raw,
  upsertRows,
  ensureDevice,
  now = () => new Date(),
  urlTtlSec = UPLOAD_URL_TTL_SEC,
}: {
  cfg: PushFunctionConfig;
  rest: SupabaseRest;
  raw: S3Store | null;
  upsertRows?: (table: string, rows: unknown[], opts: { onConflict: string }) => Promise<unknown>;
  ensureDevice?: (row: Record<string, unknown>) => Promise<unknown>;
  now?: () => Date;
  urlTtlSec?: number;
}) {
  const manifests: ManifestStore | null = rest?.configured ? createManifestStore({ rest, now }) : null;

  return {
    get configured() {
      return Boolean(manifests && cfg?.b2KeyId && cfg?.b2ApplicationKey && cfg?.b2Bucket && raw);
    },

    async createIntent({ userId, manifest }: { userId: string; manifest: any }) {
      if (!isUuid(userId)) throw fail('unauthorized', 401);
      if (!manifests) throw fail('archive_not_configured', 503);
      if (!raw) throw fail('archive_not_configured', 503);

      const v = validateObjectIntent(manifest);
      if (!v.ok) {
        const err = fail('invalid_object_manifest', 400);
        err.fields = v.errors;
        throw err;
      }

      const deviceId = noopDeviceId(userId, manifest.deviceId);
      const startAt = new Date(v.startTs * 1000);
      const endAt = new Date(v.endTs * 1000);
      const key = rawObjectKeyV3({
        userId,
        deviceId,
        stream: manifest.stream,
        startAt,
        objectId: manifest.objectId,
      });

      await registerDevice(rest, {
          id: deviceId,
          user_id: userId,
          source_kind: 'noop_push',
          external_device_id: String(manifest.deviceId || ''),
          last_seen_at: now().toISOString(),
      });

      const spec = pushArchiveSpecForStream(manifest.stream);
      const row = await reserveManifest(rest, {
        id: manifest.objectId,
        user_id: userId,
        device_id: deviceId,
        object_class: 'raw',
        object_kind: manifest.stream,
        provider: cfg?.rawStore || 'b2',
        bucket: cfg?.b2Bucket || null,
        object_key: key,
        start_at: startAt.toISOString(),
        end_at: endAt.toISOString(),
        period_day: startAt.toISOString().slice(0, 10),
        sample_count: v.sampleCount,
        compressed_bytes: v.compressedBytes,
        uncompressed_bytes: v.uncompressedBytes,
        content_type: spec.contentType,
        format: spec.format,
        compression: spec.compression,
        schema_version: v.schemaVersion,
        push_protocol_version: v.protocolVersion,
        sha256: manifest.contentSha256.toLowerCase(),
        digest_scope: 'decoded',
        sha256_source: SHA_SOURCE.claimed,
        retention_class: spec.retentionClass,
        expires_at: expiresAt(manifest.stream, now(), cfg as unknown as Record<string, unknown>),
        batch_id: manifest.batchId,
        source_id: manifest.sourceId,
        status: 'pending',
      });

      if (row.durability_receipt) {
        const durabilityReceipt = await completeDurableObject({ rest, raw, row });
        return { protocolVersion: row.push_protocol_version ?? '1.2', objectId: row.id, status: 'ready', objectKey: durabilityReceipt.objectKey, duplicate: true, durabilityReceipt };
      }
      if (['deleted', 'deleting', 'expired'].includes(row.status)) throw fail('object_unavailable', 409);
      const uploadKey = row.upload_object_key || row.object_key;
      // Never issue a presigned write to a verified key, including on legacy retries.
      if (uploadKey.includes('/verified/')) throw fail('object_unavailable', 409);
      const signed = raw.presignPut(uploadKey, urlTtlSec, now());
      return {
        protocolVersion: v.protocolVersion,
        objectId: manifest.objectId,
        status: 'pending',
        objectKey: uploadKey,
        uploadUrl: signed.url,
        requiredHeaders: { 'content-type': spec.contentType },
        expiresAt: signed.expiresAt,
        duplicate: false,
      };
    },

    /** Only a verified_indexed receipt permits local pruning. */
    async completeObject({ userId, objectId }: { userId: string; objectId: string }) {
      if (!isUuid(userId)) throw fail('unauthorized', 401);
      if (!isUuid(objectId)) throw fail('invalid_object_id', 400);
      if (!manifests) throw fail('archive_not_configured', 503);
      if (!raw) throw fail('archive_not_configured', 503);

      const row = await manifests.get(objectId);
      if (!row) throw fail('missing_manifest', 404);
      if (row.user_id !== userId) throw fail('forbidden', 403);
      if ((await rest.select('noop_object_verification_debt', `object_id=eq.${objectId}&user_id=eq.${userId}&select=object_id&limit=1`)).length) {
        throw fail('async_verification_required', 503);
      }
      const duplicate = Boolean(row.durability_receipt);
      const durabilityReceipt = await completeDurableObject({ rest, raw, row });
      return { protocolVersion: row.push_protocol_version ?? '1.2', objectId: row.id, status: 'ready', objectKey: durabilityReceipt.objectKey,
        durabilityReceipt, duplicate };
    },

    /** Explicitly negotiated mode: enqueue/poll only, with no storage reads or verification work. */
    async requestVerification({ userId, objectId }: { userId: string; objectId: string }) {
      if (!isUuid(userId)) throw fail('unauthorized', 401);
      if (!isUuid(objectId)) throw fail('invalid_object_id', 400);
      if (!manifests || !raw) throw fail('archive_not_configured', 503);
      return await requestObjectVerification(rest, userId, objectId);
    },

    async hasVerificationDebt({ userId, objectId }: { userId: string; objectId: string }) {
      if (!isUuid(userId)) throw fail('unauthorized', 401);
      if (!isUuid(objectId)) throw fail('invalid_object_id', 400);
      if (!manifests) throw fail('archive_not_configured', 503);
      return (await rest.select('noop_object_verification_debt',
        `object_id=eq.${objectId}&user_id=eq.${userId}&select=object_id&limit=1`)).length > 0;
    },
  };
}

export type PushObjects = ReturnType<typeof createPushObjects>;
