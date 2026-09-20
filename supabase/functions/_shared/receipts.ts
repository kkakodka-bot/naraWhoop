import { uuidFromParts } from './keys.ts';
import type { SupabaseRest } from './rest.ts';
import type { UploadAuthMode } from './tokens.ts';

export type UploadLane = 'inline' | 'object';

export function createUploadReceiptStore({
  rest,
  now = () => new Date(),
}: {
  rest: SupabaseRest;
  now?: () => Date;
}) {
  return {
    configured: Boolean(rest?.configured),
    async recordAccepted({
      userId,
      sourceId,
      deviceId,
      tokenId,
      authMode,
      lane,
      stream,
      batchId,
      objectId = null,
      bodySha256,
      acceptedStatus,
      acceptedRows = null,
    }: {
      userId: string;
      sourceId: string | null;
      deviceId: string;
      tokenId: string | null;
      authMode: UploadAuthMode;
      lane: UploadLane;
      stream: string;
      batchId: string;
      objectId?: string | null;
      bodySha256: string;
      acceptedStatus: string;
      acceptedRows?: number | null;
    }) {
      if (!rest?.configured) throw new Error('upload_receipt_store_required');
      const id = uuidFromParts([userId, 'upload-receipt', lane, batchId]);
      const rows = await rest.upsert('noop_upload_receipts', {
        id,
        user_id: userId,
        source_id: sourceId,
        device_id: deviceId,
        token_id: tokenId,
        auth_mode: authMode,
        lane,
        stream,
        batch_id: batchId,
        object_id: objectId,
        body_sha256: bodySha256,
        accepted_status: acceptedStatus,
        accepted_rows: acceptedRows,
        accepted_at: now().toISOString(),
      }, { onConflict: 'id', prefer: 'resolution=ignore-duplicates,return=representation' });
      return Array.isArray(rows) ? rows[0] || null : rows;
    },
  };
}

export type UploadReceiptStore = ReturnType<typeof createUploadReceiptStore>;
