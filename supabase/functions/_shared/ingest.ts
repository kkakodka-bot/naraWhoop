// Port of the retired Node receiver + pushArchive.js + pushDelete.js.
// acceptBatch: WAL commit → B2 archive → Supabase projection → ack. Scoring and frame decode are
// intentionally absent, same as the Node push path. The observability counters (metrics.inc) are
// a Node-process facility and are not ported.
import { gzipSync } from 'node:zlib';
import {
  OBJECT_LANE_STREAMS,
  rawObjectKeyV3,
  noopDeviceId,
  isUuid,
  isSafeExternalDeviceId,
  pushArchiveSpecForStream,
} from './keys.ts';
import {
  ALL_STREAMS,
  APPEND_STREAM_PROJECTIONS,
  REPLACE_STREAM_PROJECTIONS,
  INGEST_ENABLED_STREAMS,
  PushProtocolError,
  ackMatchesBatch,
  buildAck,
  parseNdjsonEntity,
  archiveWindowFromRecords,
  replacementKeys,
  windowBounds,
  scalarAppendFields,
  schemaVersionFor,
  streamsForVersion,
} from './registry.ts';
import { expiresAt } from './retention.ts';
import { createManifestStore } from './manifests.ts';
import { reserveManifest, completeDurableObject, type DurabilityReceipt } from './durability.ts';
import { sha256Hex, type S3Store } from './s3.ts';
import { createPushIngestQuota, createPushWal, type PushWalStore } from './wal.ts';
import { createPushReplacementStaging, type PushReplacementStaging } from './staging.ts';
import type { SupabaseRest } from './rest.ts';
import { ingestStep } from './pushDiagnostics.ts';
import {
  createProjectionRetry,
  validateAppendProjectionRows,
  type EnrolledAppendProjection,
  type ProjectionRetryClock,
} from './appendProjection.ts';
import type { PushFunctionConfig } from './config.ts';
import type { UploadReceiptStore } from './receipts.ts';
import type { UploadAuthMode } from './tokens.ts';

// A wire batch remains one replay/ACK unit, but each database statement has bounded work.
// This matters for packet provenance: full batches include raw bytes and scoring triggers.
const APPEND_PROJECTION_ROWS_PER_STATEMENT = 250;

async function applyReplacement({
  header,
  records,
  userId,
  deviceId,
  upsertRows,
  deleteRows,
}: {
  header: any;
  records: any[];
  userId: string;
  deviceId: string;
  upsertRows?: (table: string, rows: unknown[], opts: { onConflict: string }) => Promise<unknown>;
  deleteRows?: (table: string, filter: any) => Promise<void>;
}) {
  const projection = REPLACE_STREAM_PROJECTIONS[header.stream];
  if (!projection || typeof upsertRows !== 'function') return;

  const replacementId = header.window?.replacementId || header.batchId;
  const rows = records
    .map((record) => projection.mapRow({
      userId,
      deviceId,
      headerDeviceId: header.deviceId,
      sourceId: header.sourceId,
      batchId: header.batchId,
      replacementId,
      record,
      protocolVersion: header.protocolVersion,
    }))
    .filter(Boolean);

  if (rows.length) {
    await upsertRows(projection.table, rows, { onConflict: projection.onConflict });
  }

  if (typeof deleteRows !== 'function') return;
  const keys = replacementKeys(header.stream, records, header.deviceId);
  const bounds = windowBounds(header);
  if (!bounds) return;

  if (projection.windowSelector === 'day') {
    await deleteRows(projection.table, {
      userId,
      deviceId,
      dayGte: bounds.startInclusive,
      dayLt: bounds.endExclusive,
      keepKeys: keys,
      stream: header.stream,
    });
    return;
  }

  if (projection.windowSelector === 'startTs') {
    await deleteRows(projection.table, {
      userId,
      deviceId,
      startTsGte: Number(bounds.startInclusive),
      startTsLt: Number(bounds.endExclusive),
      keepKeys: keys,
      stream: header.stream,
      kind: header.stream === 'sleepSession' ? 'sleep' : 'workout',
    });
  }
}

/** Apply replace-window absence deletes for NOOP push projections. */
export async function deleteReplacementRows(rest: SupabaseRest, table: string, filter: any) {
  if (!rest?.configured) return;

  if (table === 'daily_metrics') {
    const rows = await rest.select(
      'daily_metrics',
      `user_id=eq.${filter.userId}&day=gte.${filter.dayGte}&day=lt.${filter.dayLt}&select=day`,
    );
    for (const row of rows) {
      if (!filter.keepKeys.has(String(row.day))) {
        await rest.delete('daily_metrics', `user_id=eq.${filter.userId}&day=eq.${row.day}`);
      }
    }
    return;
  }

  if (table === 'noop_journal_entries') {
    const rows = await rest.select(
      'noop_journal_entries',
      `user_id=eq.${filter.userId}&device_id=eq.${filter.deviceId}&day=gte.${filter.dayGte}&day=lt.${filter.dayLt}&select=day,question`,
    );
    for (const row of rows) {
      const key = `${row.day}|${row.question}`;
      if (!filter.keepKeys.has(key)) {
        await rest.delete(
          'noop_journal_entries',
          `user_id=eq.${filter.userId}&device_id=eq.${filter.deviceId}&day=eq.${row.day}&question=eq.${encodeURIComponent(row.question)}`,
        );
      }
    }
    return;
  }

  if (table === 'sessions') {
    const kinds = filter.kind === 'workout' ? ['workout', 'manual_workout'] : [filter.kind];
    const startIso = new Date(filter.startTsGte * 1000).toISOString();
    const endIso = new Date(filter.startTsLt * 1000).toISOString();
    for (const kind of kinds) {
      const rows = await rest.select(
        'sessions',
        `user_id=eq.${filter.userId}&kind=eq.${kind}&start_at=gte.${startIso}&start_at=lt.${endIso}&select=id,external_id`,
      );
      for (const row of rows) {
        if (!filter.keepKeys.has(row.external_id)) {
          await rest.delete('sessions', `id=eq.${row.id}`);
        }
      }
    }
  }
}

/** Archives one inline batch: manifest row → B2 PUT → byte-count completion. */
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
        sourceId, batchId, tokenId, authMode,
      } = args;
      const spec = pushArchiveSpecForStream(stream);
      const row: Record<string, unknown> = {
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
        content_type: spec.contentType,
        format: spec.format,
        compression: spec.compression,
        schema_version: schemaVersion,
        sha256,
        sha256_source: 'server_verified',
        retention_class: spec.retentionClass,
        expires_at: expiresAt(stream, new Date(), cfg as unknown as Record<string, unknown>),
        source_id: sourceId,
        batch_id: batchId,
        ingest_token_id: tokenId,
        auth_mode: authMode,
        status: 'pending',
      };
      row.uncompressed_bytes = args.uncompressedBytes ?? body.length;
      row.push_protocol_version = args.protocolVersion ?? '1.1';
      row.digest_scope = args.digestScope || 'wire';
      const reserved = await ingestStep('archive_manifest', stream, () => reserveManifest(rest, row));
      if (!reserved.durability_receipt) {
        await ingestStep('archive_write', stream, () => raw.putObject(reserved.upload_object_key || reserved.object_key || key, body, { contentType: spec.contentType }));
      }
      const durabilityReceipt = await ingestStep('archive_verify', stream, () => completeDurableObject({ rest, raw, row: reserved }));
      return { ready: true, objectKey: durabilityReceipt.objectKey, durabilityReceipt, manifest: reserved };
    },
  };
}

/**
 * Accept one NOOP push NDJSON batch: WAL commit → B2 archive → Supabase upsert → ack.
 * Scoring and frame decode are intentionally absent.
 */
export function createPushIngest({
  walStore,
  archiveObject,
  upsertRows,
  deleteRows,
  ensureDevice,
  resolveDeviceId,
  replacementStaging,
  receiptStore,
  commitProjection,
  projectionRetryClock,
  projectAppend,
  quotaConfig,
  now = () => new Date(),
}: {
  walStore: PushWalStore;
  archiveObject: (args: any) => Promise<{ ready: boolean; durabilityReceipt?: DurabilityReceipt }>;
  upsertRows?: (table: string, rows: unknown[], opts: { onConflict: string }) => Promise<unknown>;
  deleteRows?: (table: string, filter: any) => Promise<void>;
  ensureDevice?: (row: Record<string, unknown>) => Promise<unknown>;
  resolveDeviceId?: (args: { userId: string; externalDeviceId: unknown; sourceId?: string | null }) => Promise<string>;
  replacementStaging?: PushReplacementStaging;
  receiptStore?: UploadReceiptStore;
  commitProjection?: (receipt: DurabilityReceipt, decodedBody: Uint8Array) => Promise<any>;
  projectionRetryClock?: ProjectionRetryClock;
  projectAppend?: (batch: EnrolledAppendProjection) => Promise<void>;
  quotaConfig?: { maxBatches: number; maxBytes: number; windowSec: number };
  now?: () => Date;
}) {
  if (!walStore) throw new Error('walFactory required');
  const quota = createPushIngestQuota({ store: walStore, config: quotaConfig });

  return {
    async acceptBatch({
      userId,
      sourceId,
      tokenId,
      authMode,
      decodedBody,
    }: {
      userId: string;
      sourceId: string | null;
      tokenId: string | null;
      authMode: UploadAuthMode;
      decodedBody: Uint8Array;
    }) {
      const retryProjection = createProjectionRetry(projectionRetryClock);
      const bodySha256 = sha256Hex(decodedBody);
      const { header, records } = parseNdjsonEntity(decodedBody);
      const wal = createPushWal({ userId, store: walStore });

      if (!isUuid(header.batchId)) throw new PushProtocolError('invalid_batch_id', 400);
      if (!isUuid(header.sourceId)) throw new PushProtocolError('invalid_source_id', 400);
      if (!isSafeExternalDeviceId(header.deviceId)) {
        throw new PushProtocolError('invalid_device_id', 400);
      }
      const headerSourceId = String(header.sourceId).toLowerCase();
      if (sourceId && headerSourceId !== sourceId.toLowerCase()) {
        throw new PushProtocolError('source_id_mismatch', 403);
      }
      const effectiveSourceId = sourceId ? sourceId.toLowerCase() : headerSourceId;
      const stampedHeader = { ...header, sourceId: effectiveSourceId };

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
      if (!streamsForVersion(header.protocolVersion).has(header.stream)) {
        throw new PushProtocolError('unsupported_version', 422);
      }
      const schemaVersion = schemaVersionFor(header.stream, header.protocolVersion);
      if (header.schemaVersion != null && header.schemaVersion !== schemaVersion) {
        throw new PushProtocolError('invalid_schema_version', 422);
      }
      for (const record of records) scalarAppendFields(header.stream, record, header.protocolVersion);

      const resolveCanonicalDevice = async () => {
        if (typeof resolveDeviceId === 'function') {
          return await resolveDeviceId({ userId, externalDeviceId: header.deviceId, sourceId: effectiveSourceId });
        }
        const fallback = noopDeviceId(userId, header.deviceId);
        if (typeof ensureDevice === 'function') {
          const registered = await ensureDevice({
            id: fallback,
            user_id: userId,
            source_kind: 'noop_push',
            external_device_id: String(header.deviceId || ''),
            last_seen_at: now().toISOString(),
          });
          if (typeof registered === 'string' && isUuid(registered)) return registered.toLowerCase();
        }
        return fallback;
      };

      const prior = await ingestStep('receipt_lookup', header.stream, () => wal.getAck(header.batchId));
      const priorReceipt = prior?.ack?.durabilityReceipt as DurabilityReceipt | undefined;
      const priorIsDurable = prior?.bodySha256 === bodySha256 && prior?.ack
        && priorReceipt?.version === 1 && priorReceipt.state === 'verified_indexed'
        && priorReceipt.ownerUserId === userId && priorReceipt.batchId === header.batchId
        && priorReceipt.objectId === header.batchId && priorReceipt.sourceId === effectiveSourceId
        && priorReceipt.stream === header.stream && priorReceipt.contentSha256 === bodySha256
        && ackMatchesBatch(prior.ack, stampedHeader);
      if (priorIsDurable) {
        const priorDeviceId = await resolveCanonicalDevice();
        if (priorReceipt.deviceId !== priorDeviceId) {
          throw new PushProtocolError('device_owner_conflict', 403);
        }
        if (receiptStore) {
          await receiptStore.recordAccepted({
            userId,
            sourceId: effectiveSourceId,
            deviceId: priorDeviceId,
            tokenId,
            authMode,
            lane: 'inline',
            stream: header.stream,
            batchId: header.batchId,
            objectId: header.batchId,
            bodySha256,
            acceptedStatus: String(prior.ack.status || 'accepted'),
            acceptedRows: Number(prior.ack.acceptedRows ?? header.recordCount),
          });
        }
        await wal.trimWal(header.batchId);
        return prior.ack;
      }
      if (prior && prior.bodySha256 !== bodySha256) {
        throw new PushProtocolError('batch_id_conflict', 409);
      }

      let deviceId = noopDeviceId(userId, header.deviceId);
      const appendProjection = header.delivery === 'append' ? APPEND_STREAM_PROJECTIONS[header.stream] : undefined;
      let appendRows: Record<string, unknown>[] = [];
      if (header.delivery === 'append') {
        if (!appendProjection) throw new PushProtocolError('unsupported_delivery', 422);
        appendRows = records.map((record) => {
          const row = appendProjection.mapRow({ userId, deviceId, sourceId: effectiveSourceId,
            batchId: header.batchId, record, protocolVersion: header.protocolVersion });
          // An ACK's acceptedRows must not count records discarded by a projection mapper.
          if (!row) throw new PushProtocolError('invalid_record', 422);
          return row;
        });
        validateAppendProjectionRows(appendRows, appendProjection.onConflict);
      }

      await ingestStep('quota', header.stream, () => quota.reserve(userId, decodedBody.length));

      deviceId = await ingestStep('device', header.stream, resolveCanonicalDevice);
      await ingestStep('wal', header.stream, () => wal.appendWal({
        batchId: header.batchId,
        stream: header.stream,
        deviceId: header.deviceId,
        canonicalDeviceId: deviceId,
        sourceId: effectiveSourceId,
        recordCount: header.recordCount,
        bodySha256,
        receivedAt: now().toISOString(),
      }));

      // Validation precedes durable writes; the canonical lookup may preserve an older owned UUID.
      appendRows = appendRows.map((row) => ({ ...row, device_id: deviceId }));

      const objectId = header.batchId && isUuid(header.batchId) ? header.batchId : crypto.randomUUID();
      const archiveRecords = records;
      const { startAt, endAt } = archiveWindowFromRecords(header.stream, archiveRecords, now(), header);
      const archiveBytes = gzipSync(decodedBody);
      const archiveSha256 = sha256Hex(archiveBytes);
      const key = rawObjectKeyV3({
        userId,
        deviceId,
        stream: header.stream,
        startAt,
        objectId,
      });

      const manifest = await ingestStep('archive', header.stream, () => archiveObject({
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
        sampleCount: header.recordCount,
        startAt,
        endAt,
        periodDay: startAt.slice(0, 10),
        sourceId: effectiveSourceId,
        batchId: header.batchId,
        tokenId,
        authMode,
      }));

      if (commitProjection && manifest?.durabilityReceipt) {
        const receipt = manifest.durabilityReceipt;
        const ack = await ingestStep('projection', header.stream, () => commitProjection(receipt, decodedBody));
        if (receiptStore) {
          await receiptStore.recordAccepted({
            userId, sourceId: effectiveSourceId, deviceId, tokenId, authMode,
            lane: 'inline', stream: header.stream, batchId: header.batchId, objectId,
            bodySha256, acceptedStatus: ack.status, acceptedRows: ack.acceptedRows,
          });
        }
        return ack;
      }

      if (header.delivery === 'append') {
        const projection = appendProjection;
        if (projection && (typeof upsertRows === 'function' || projectAppend)) {
          const rows = appendRows;
          if (rows.length) {
            await ingestStep('projection', header.stream, async () => {
              if (projectAppend && authMode === 'installation' && effectiveSourceId) {
                await retryProjection(() => projectAppend({ userId, deviceId, sourceId: effectiveSourceId,
                  batchId: header.batchId, stream: header.stream, rows }));
                return;
              }
              if (!upsertRows) throw new Error('append_projection_unavailable');
              for (let start = 0; start < rows.length; start += APPEND_PROJECTION_ROWS_PER_STATEMENT) {
                await upsertRows!(projection.table, rows.slice(start, start + APPEND_PROJECTION_ROWS_PER_STATEMENT),
                  { onConflict: projection.onConflict });
              }
            });
          }
        }
      } else if (header.delivery === 'replace_window') {
        if (!REPLACE_STREAM_PROJECTIONS[header.stream]) {
          throw new PushProtocolError('unsupported_delivery', 422);
        }
        if (!replacementStaging) {
          throw new PushProtocolError('replacement_staging_unavailable', 503);
        }
        var staged = await ingestStep('replacement', header.stream,
          () => replacementStaging!.stagePart({ userId, header: stampedHeader, records, bodySha256 }));
        const superseded = staged.supersededComplete;
        if (superseded) {
          await ingestStep('projection', header.stream, () => applyReplacement({
            header: superseded.header,
            records: superseded.records,
            userId,
            deviceId,
            upsertRows,
            deleteRows,
          }));
          await ingestStep('replacement', header.stream,
            () => replacementStaging!.clearGeneration({ userId, header: superseded.header }));
          staged = await ingestStep('replacement', header.stream,
            () => replacementStaging!.stagePart({ userId, header: stampedHeader, records, bodySha256 }));
        }
        if (staged.isCompletingPart) {
          await ingestStep('projection', header.stream, () => applyReplacement({
            header: stampedHeader,
            records: staged.records,
            userId,
            deviceId,
            upsertRows,
            deleteRows,
          }));
          await ingestStep('replacement', header.stream, () => replacementStaging!.clearGeneration({ userId, header: stampedHeader }));
        }
      } else {
        throw new PushProtocolError('unsupported_delivery', 422);
      }

      if (!manifest?.ready || !manifest.durabilityReceipt) {
        throw new PushProtocolError('archive_not_ready', 503);
      }

      const ack = { ...buildAck(header), durabilityReceipt: manifest.durabilityReceipt };
      if (!ackMatchesBatch(ack, header)) {
        throw new PushProtocolError('ack_internal_mismatch', 500);
      }
      await ingestStep('ack', header.stream, () => wal.saveAck(header.batchId, ack, bodySha256));
      if (receiptStore) {
        await receiptStore.recordAccepted({
          userId,
          sourceId: effectiveSourceId,
          deviceId,
          tokenId,
          authMode,
          lane: 'inline',
          stream: header.stream,
          batchId: header.batchId,
          objectId,
          bodySha256,
          acceptedStatus: ack.status,
          acceptedRows: ack.acceptedRows,
        });
      }
      await ingestStep('wal_cleanup', header.stream, () => wal.trimWal(header.batchId));
      return ack;
    },
  };
}
