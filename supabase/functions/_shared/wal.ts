// Port of the retired Node receiver (Postgres backend) + pushWal.js facade +
// pushIngestQuota.js. Durability lives in noop_push_wal / noop_push_acks / the two RPCs from
// migration 20260907150000_noop_push_wal.sql — identical to the Node production path.
import { PushProtocolError } from './registry.ts';
import type { SupabaseRest } from './rest.ts';
import { intakeError } from './durability.ts';

export interface QuotaConfig {
  maxBatches: number;
  maxBytes: number;
  windowSec: number;
}

export function defaultQuotaConfig(env: Record<string, string | undefined> = Deno.env.toObject()): QuotaConfig {
  return {
    maxBatches: Number(env.FRWHOOP_PUSH_QUOTA_MAX_BATCHES || 10_000),
    maxBytes: Number(env.FRWHOOP_PUSH_QUOTA_MAX_BYTES || 512 * 1024 * 1024),
    windowSec: Number(env.FRWHOOP_PUSH_QUOTA_WINDOW_SEC || 3600),
  };
}

export function createPushWalStore({ rest, quota = {} }: {
  rest: SupabaseRest;
  quota?: Partial<QuotaConfig>;
}) {
  if (!rest?.configured) return null;

  const defaults = defaultQuotaConfig();
  const {
    maxBatches = defaults.maxBatches,
    maxBytes = defaults.maxBytes,
    windowSec = defaults.windowSec,
  } = quota;

  return {
    async appendWal(userId: string, entry: any) {
      try {
        return await rest.rpc('noop_reserve_push_batch', {
          p_user_id: userId, p_batch_id: entry.batchId, p_device_id: entry.canonicalDeviceId,
          p_body_sha256: entry.bodySha256, p_entry: entry,
        });
      } catch (err) { intakeError(err); }
    },
    async trimWal(userId: string, batchId: string) {
      await rest.delete('noop_push_wal', `user_id=eq.${userId}&batch_id=eq.${batchId}`);
    },
    async getAck(userId: string, batchId: string) {
      const rows = await rest.select(
        'noop_push_acks',
        `user_id=eq.${userId}&batch_id=eq.${batchId}&select=body_sha256,ack,saved_at`,
      );
      const row = rows[0];
      if (!row) return null;
      return {
        bodySha256: row.body_sha256,
        ack: row.ack,
        savedAt: row.saved_at,
      };
    },
    async saveAck(userId: string, batchId: string, ack: unknown, bodySha256: string) {
      try {
        await rest.rpc('noop_push_save_ack', {
          p_user_id: userId,
          p_batch_id: batchId,
          p_body_sha256: bodySha256,
          p_ack: ack,
        });
      } catch (err: any) {
        if (String(err?.message || '').includes('batch_id_conflict')) {
          throw new Error('batch_id_conflict');
        }
        throw err;
      }
    },
    async consumeQuota(userId: string, bytes: number, config: Partial<QuotaConfig> = {}) {
      const batchLimit = config.maxBatches ?? maxBatches;
      const byteLimit = config.maxBytes ?? maxBytes;
      const window = config.windowSec ?? windowSec;
      try {
        await rest.rpc('noop_push_consume_ingest_quota', {
          p_user_id: userId,
          p_bytes: bytes,
          p_max_batches: batchLimit,
          p_max_bytes: byteLimit,
          p_window_seconds: window,
        });
      } catch (err: any) {
        if (String(err?.message || '').includes('ingest_quota_exceeded')) {
          throw new Error('ingest_quota_exceeded');
        }
        throw err;
      }
    },
    quotaConfig: { maxBatches, maxBytes, windowSec },
  };
}

export type PushWalStore = NonNullable<ReturnType<typeof createPushWalStore>>;

/** Per-user push WAL + batch acknowledgement facade (production Postgres store). */
export function createPushWal({ userId, store }: { userId: string; store: PushWalStore }) {
  if (!store) throw new Error('push_wal_store_required');
  return {
    appendWal(entry: any) {
      return store.appendWal(userId, entry);
    },
    trimWal(batchId: string) {
      return store.trimWal(userId, batchId);
    },
    getAck(batchId: string) {
      return store.getAck(userId, batchId);
    },
    saveAck(batchId: string, ack: unknown, bodySha256: string) {
      return store.saveAck(userId, batchId, ack, bodySha256);
    },
  };
}

export function createPushIngestQuota({ store, config = defaultQuotaConfig() }: {
  store: Pick<PushWalStore, 'consumeQuota'> | null;
  config?: QuotaConfig;
}) {
  if (!store?.consumeQuota) {
    return {
      async reserve() {},
    };
  }
  return {
    async reserve(userId: string, bytes: number) {
      try {
        await store.consumeQuota(userId, bytes, config);
      } catch (err: any) {
        if (err?.message === 'ingest_quota_exceeded') {
          throw new PushProtocolError('ingest_quota_exceeded', 429);
        }
        throw err;
      }
    },
  };
}
