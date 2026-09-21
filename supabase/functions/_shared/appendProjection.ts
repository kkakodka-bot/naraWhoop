import { PushProtocolError } from './registry.ts';
import type { SupabaseRest } from './rest.ts';

export interface EnrolledAppendProjection {
  userId: string;
  deviceId: string;
  sourceId: string;
  batchId: string;
  stream: string;
  rows: Record<string, unknown>[];
}

/** Project one enrolled append batch in the live database's single atomic statement. */
export async function projectEnrolledAppend(rest: Pick<SupabaseRest, 'rpc'>, batch: EnrolledAppendProjection) {
  const projected = await rest.rpc('noop_project_append_batch', {
    p_user: batch.userId, p_device: batch.deviceId, p_source: batch.sourceId,
    p_batch: batch.batchId, p_stream: batch.stream, p_rows: batch.rows,
  });
  if (projected !== batch.rows.length) throw new Error('incomplete_append_projection');
}

export interface ProjectionRetryClock {
  milliseconds(): number;
  sleep(milliseconds: number): Promise<void>;
}

/** Bound scoring-gate contention inside one request without replaying a partial projection. */
export function createProjectionRetry(clock: ProjectionRetryClock = {
  milliseconds: () => performance.now(),
  sleep: (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds)),
}) {
  const deadline = clock.milliseconds() + 20_000;
  return async (write: () => Promise<unknown>): Promise<void> => {
    let retries = 0;
    while (true) {
      try {
        await write();
        return;
      } catch (error) {
        if (!(error instanceof Error) ||
            (error as Error & { receiverCode?: string }).receiverCode !== 'scoring_input_gate_busy') throw error;
        const remaining = deadline - clock.milliseconds();
        if (remaining <= 0 || retries++ >= 40) throw error;
        await clock.sleep(Math.min(500, remaining));
        if (clock.milliseconds() >= deadline) throw error;
      }
    }
  };
}

// Types of every column currently used by an append projection's PostgreSQL conflict key.
// Validate projected values, not wire JSON: e.g. ts="1700000000" and ts=1700000000
// are the same bigint after the registry mapper has run.
const KEY_TYPES: Record<string, 'uuid' | 'bigint' | 'integer' | 'text'> = {
  user_id: 'uuid', device_id: 'uuid', ts: 'bigint', rrMs: 'integer', seq: 'integer',
  packetId: 'text', receiptId: 'text', kind: 'text',
};

function keyPart(column: string, value: unknown): string {
  switch (KEY_TYPES[column]) {
    case 'bigint':
    case 'integer': {
      // JSON numbers outside the exact integer range cannot preserve the claimed identity.
      if (typeof value !== 'number' || !Number.isSafeInteger(value) ||
          (KEY_TYPES[column] === 'integer' && (value < -2147483648 || value > 2147483647))) {
        throw new PushProtocolError('invalid_record_key', 422);
      }
      return String(value); // Includes PostgreSQL's equality of -0 and 0.
    }
    case 'uuid': {
      if (typeof value !== 'string') throw new PushProtocolError('invalid_record_key', 422);
      const normalized = value.replace(/^\{(.*)\}$/, '$1').replaceAll('-', '').toLowerCase();
      if (!/^[a-f0-9]{32}$/.test(normalized)) throw new PushProtocolError('invalid_record_key', 422);
      return normalized;
    }
    case 'text':
      if (typeof value !== 'string') throw new PushProtocolError('invalid_record_key', 422);
      return value;
    default:
      // A future conflict-column type must get an explicit database-compatible encoding.
      throw new Error('unsupported_append_conflict_column');
  }
}

/** Reject repeated projected identities across the entire batch before any chunk is written. */
export function validateAppendProjectionRows(rows: Record<string, unknown>[], onConflict: string): void {
  const columns = onConflict.split(',').map((column) => column.trim());
  const seen = new Set<string>();
  for (const row of rows) {
    // A JSON tuple preserves text boundaries; delimiter concatenation would conflate some keys.
    const key = JSON.stringify(columns.map((column) => keyPart(column, row[column])));
    if (seen.has(key)) throw new PushProtocolError('duplicate_record_key', 422);
    seen.add(key);
  }
}
