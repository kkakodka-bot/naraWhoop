// Port of the retired Node receiver + pushArchive.js + pushDelete.js.
// acceptBatch: WAL reservation → verified archive → atomic projection/debt/ACK settlement. Scoring and frame decode are
// intentionally absent, same as the Node push path. The observability counters (metrics.inc) are
// a Node-process facility and are not ported.
import { gzipSync } from 'node:zlib';
import {
  OBJECT_LANE_STREAMS,
  rawObjectKeyV3,
  noopDeviceId,
  isUuid,
  pushArchiveSpecForStream,
} from './keys.ts';
import {
  ALL_STREAMS,
  APPEND_STREAM_PROJECTIONS,
  REPLACE_STREAM_PROJECTIONS,
  INGEST_ENABLED_STREAMS,
  PushProtocolError,
  parseNdjsonEntity,
  archiveWindowFromRecords,
  scalarAppendFields,
  schemaVersionFor,
  streamsForVersion,
} from './registry.ts';
import { expiresAt } from './retention.ts';
import { createManifestStore } from './manifests.ts';
import { reserveManifest, completeDurableObject, type DurabilityReceipt } from './durability.ts';
import { sha256Hex, type S3Store } from './s3.ts';
import { createPushIngestQuota, createPushWal, type PushWalStore } from './wal.ts';
import type { SupabaseRest } from './rest.ts';
import type { PushFunctionConfig } from './config.ts';

/** Archives one inline batch: manifest row → B2 PUT → verified immutable receipt. */
export function createPushArchive({ cfg, rest, raw }: {
  cfg: PushFunctionConfig;
  rest: SupabaseRest;
  raw: S3Store | null;
}) {
  const manifests = rest?.configured ? createManifestStore({ rest }) : null;

  return {
    configured: Boolean(manifests && cfg.b2KeyId && cfg.b2ApplicationKey && raw),
    async archiveObject(args: any) {
      if (!raw || !manifests) {
        return { ready: false, reason: 'archive_not_configured' };
      }
      const {
        userId, deviceId, stream, objectId, key, body,
        schemaVersion, sha256, sampleCount, startAt, endAt, periodDay,
      } = args;
      const spec = pushArchiveSpecForStream(stream);
      const row = {
        id: objectId,
        user_id: userId,
        device_id: deviceId,
        object_class: 'raw',
        object_kind: stream,
        provider: cfg.rawStore,
        bucket: cfg.b2Bucket,
        object_key: key,
        start_at: startAt,
        end_at: endAt,
        period_day: periodDay,
        sample_count: sampleCount,
        compressed_bytes: body.length,
        uncompressed_bytes: args.uncompressedBytes,
        content_type: spec.contentType,
        format: spec.format,
        compression: spec.compression,
        schema_version: schemaVersion,
        push_protocol_version: args.protocolVersion,
        sha256,
        digest_scope: 'wire',
        batch_id: args.batchId,
        source_id: args.sourceId,
        retention_class: spec.retentionClass,
        expires_at: expiresAt(stream, new Date(), cfg as unknown as Record<string, unknown>),
        status: 'pending',
      };
      const reserved = await reserveManifest(rest, row);
      if (!reserved.durability_receipt) {
        await raw.putObject(reserved.upload_object_key || reserved.object_key, body, { contentType: spec.contentType });
      }
      const durabilityReceipt = await completeDurableObject({ rest, raw, row: reserved });
      return { ready: true, objectKey: durabilityReceipt.objectKey, durabilityReceipt };
    },
  };
}

/**
 * Accept one NOOP push NDJSON batch: WAL reservation → B2 archive → atomic projection/ACK.
 * Scoring and frame decode are intentionally absent.
 */
export function createPushIngest({
  walStore,
  archiveObject,
  ensureDevice,
  commitProjection,
  quotaConfig,
  now = () => new Date(),
}: {
  walStore: PushWalStore;
  archiveObject: (args: any) => Promise<{ ready: boolean; durabilityReceipt?: DurabilityReceipt }>;
  ensureDevice: (row: Record<string, unknown>) => Promise<unknown>;
  commitProjection: (receipt: DurabilityReceipt, decodedBody: Uint8Array) => Promise<any>;
  quotaConfig?: { maxBatches: number; maxBytes: number; windowSec: number };
  now?: () => Date;
}) {
  if (!walStore) throw new Error('walFactory required');
  const quota = createPushIngestQuota({ store: walStore, config: quotaConfig });

  return {
    async acceptBatch({ userId, decodedBody }: { userId: string; decodedBody: Uint8Array }) {
      if (!isUuid(userId)) throw new PushProtocolError('unauthorized', 401);
      const bodySha256 = sha256Hex(decodedBody);
      const { header, records } = parseNdjsonEntity(decodedBody);
      const wal = createPushWal({ userId, store: walStore });

      if (!ALL_STREAMS.has(header.stream)) {
        throw new PushProtocolError('unsupported_stream', 422);
      }
      if (!INGEST_ENABLED_STREAMS.has(header.stream)) {
        throw new PushProtocolError('stream_not_enabled', 422);
      }
      // An object-lane stream IS enabled, just not here. Without this the request would fall through
      // to the delivery switch below and be refused as `unsupported_delivery`, which names the wrong
      // cause and sends whoever reads it looking for a malformed header.
      if (OBJECT_LANE_STREAMS.has(header.stream)) {
        throw new PushProtocolError('use_object_lane', 422);
      }
      if ((header.delivery === 'append' && !APPEND_STREAM_PROJECTIONS[header.stream]) ||
          (header.delivery === 'replace_window' && !REPLACE_STREAM_PROJECTIONS[header.stream]) ||
          (header.delivery !== 'append' && header.delivery !== 'replace_window')) {
        throw new PushProtocolError('unsupported_delivery', 422);
      }
      const deviceId = noopDeviceId(userId, header.deviceId);
      // Reject malformed scalar rows before reservation/archive; ACK must cover every row.
      if (!streamsForVersion(header.protocolVersion).has(header.stream)) throw new PushProtocolError('unsupported_version', 422);
      const schemaVersion = schemaVersionFor(header.stream, header.protocolVersion);
      if (header.schemaVersion != null && header.schemaVersion !== schemaVersion) throw new PushProtocolError('invalid_schema_version', 422);
      for (const record of records) scalarAppendFields(header.stream, record, header.protocolVersion);
      await ensureDevice({
          id: deviceId, user_id: userId, source_kind: 'noop_push',
          external_device_id: String(header.deviceId || ''), last_seen_at: now().toISOString(),
      });

      // Reserve before archive, projection, quota, or ACK. A reservation survives WAL trimming
      // and a crash before ACK, so a changed body cannot reuse the batch identity.
      const reservedAt = await wal.appendWal({
        batchId: header.batchId, stream: header.stream, deviceId: header.deviceId,
        canonicalDeviceId: deviceId, sourceId: header.sourceId, recordCount: header.recordCount,
        bodySha256, receivedAt: now().toISOString(),
      });

      const prior = await wal.getAck(header.batchId);
      if (prior?.bodySha256 === bodySha256 && prior?.ack?.durabilityReceipt?.version === 1 &&
          prior?.ack?.durabilityReceipt?.state === 'verified_indexed') {
        await wal.trimWal(header.batchId);
        return prior.ack;
      }
      if (prior && prior.bodySha256 !== bodySha256) {
        throw new PushProtocolError('batch_id_conflict', 409);
      }

      await quota.reserve(userId, decodedBody.length);

      const objectId = header.batchId && isUuid(header.batchId) ? header.batchId : crypto.randomUUID();
      const archiveRecords = records;
      const fallbackAt = new Date(reservedAt);
      if (!Number.isFinite(fallbackAt.getTime())) throw new Error('reservation_timestamp_missing');
      const { startAt, endAt } = archiveWindowFromRecords(header.stream, archiveRecords, fallbackAt, header);
      const archiveBytes = gzipSync(decodedBody);
      const archiveSha256 = sha256Hex(archiveBytes);
      const key = rawObjectKeyV3({
        userId,
        deviceId,
        stream: header.stream,
        startAt,
        objectId,
      });

      const manifest = await archiveObject({
        userId,
        deviceId,
        stream: header.stream,
        objectId,
        key,
        body: archiveBytes,
        contentType: 'application/x-ndjson',
        format: 'ndjson_gzip_noop_push_v1',
        compression: 'gzip',
        schemaVersion,
        protocolVersion: header.protocolVersion,
        sha256: archiveSha256,
        uncompressedBytes: decodedBody.length,
        batchId: header.batchId,
        sourceId: header.sourceId,
        sampleCount: header.recordCount,
        startAt,
        endAt,
        periodDay: startAt.slice(0, 10),
      });

      if (!manifest?.ready || !manifest.durabilityReceipt) {
        throw new PushProtocolError('archive_not_ready', 503);
      }

      // Projection writes, scoring invalidation, ACK and debt settle in one SQL transaction.
      return await commitProjection(manifest.durabilityReceipt, decodedBody);
    },
  };
}
