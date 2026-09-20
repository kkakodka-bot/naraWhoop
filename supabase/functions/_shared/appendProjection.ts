import { PushProtocolError } from './registry.ts';

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
