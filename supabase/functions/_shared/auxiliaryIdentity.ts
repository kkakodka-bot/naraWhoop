import { createHash } from 'node:crypto';
import { PushProtocolError } from './registry.ts';

const WIDTHS = [4, 1, 1, 1, 1, 2, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 4];
const MAX_FIELDS = 5 + WIDTHS.reduce((a, b) => a + b, 0);
const invalid = (code = 'invalid_aux_envelope'): never => { throw new PushProtocolError(code, 422); };
const view = (bytes: Uint8Array) => new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);

export function auxiliaryFingerprint(deviceId: string, ts: number, recordIndex: number | null): string {
  return createHash('sha256').update(`v18AuxSample-v2\n${deviceId}\n${ts}\n${recordIndex ?? 'unknown'}`).digest('hex');
}

export function strictAuxiliaryFields(bytes: Uint8Array): { supported: boolean; recordIndex: number | null } {
  const unknown = { supported: false, recordIndex: null };
  if (bytes.length < 5 || bytes[0] !== 2) return unknown;
  const bitmap = view(bytes).getUint32(1, true);
  if (bitmap & ~0x1ffff) return unknown;
  const expected = 5 + WIDTHS.reduce((sum, width, bit) => sum + ((bitmap & (1 << bit)) ? width : 0), 0);
  if (bytes.length !== expected) return unknown;
  return { supported: true, recordIndex: bitmap & 1 ? view(bytes).getUint32(5, true) : null };
}

export type AuxiliaryValidation = {
  version: 1; format: 2; records: number; supportedRecords: number;
  unknownIdentityRecords: number; unsupportedFieldsRecords: number;
  state: 'validated' | 'pending';
};

/** Incremental framing/identity validation; buffers at most64KiB, never an entire object. */
export class AuxiliaryIdentityValidator {
  private parser: Generator<number, AuxiliaryValidation, Uint8Array>;
  private next: IteratorResult<number, AuxiliaryValidation>;
  private piece = new Uint8Array(0);
  private used = 0;

  constructor(sampleCount: number, startTs: number, endTs: number) {
    this.parser = this.records(sampleCount, startTs, endTs);
    this.next = this.parser.next();
    this.allocate();
  }
  private allocate() {
    if (!this.next.done) this.piece = new Uint8Array(this.next.value);
    this.used = 0;
  }
  push(bytes: Uint8Array) {
    let offset = 0;
    while (offset < bytes.length) {
      if (this.next.done) invalid('aux_trailing_bytes');
      const length = Math.min(bytes.length - offset, this.piece.length - this.used);
      this.piece.set(bytes.subarray(offset, offset + length), this.used);
      offset += length; this.used += length;
      if (this.used === this.piece.length) {
        this.next = this.parser.next(this.piece);
        this.allocate();
      }
    }
  }
  finish(): AuxiliaryValidation {
    if (!this.next.done) invalid('aux_truncated_envelope');
    return this.next.value as AuxiliaryValidation;
  }
  private *records(sampleCount: number, startTs: number, endTs: number): Generator<number, AuxiliaryValidation, Uint8Array> {
    const header = yield 10;
    if (new TextDecoder().decode(header.subarray(0, 4)) !== 'NPB1' || header[4] !== 2 || header[5] !== 2) invalid();
    const count = view(header).getUint32(6, true);
    if (count !== sampleCount) invalid('aux_count_mismatch');
    let min = Infinity, max = -Infinity, supported = 0, unknown = 0, unsupported = 0;
    for (let row = 0; row < count; row++) {
      const identity = view(yield 17);
      const rowId = identity.getBigInt64(0, true);
      const ts = Number(identity.getBigInt64(8, true));
      if (rowId <= 0n || !Number.isSafeInteger(ts) || ts < startTs || ts >= endTs) invalid('aux_identity_window');
      min = Math.min(min, ts); max = Math.max(max, ts);
      const present = identity.getUint8(16);
      if (present !== 0 && present !== 1) invalid('aux_index_presence');
      let index: number | null = null;
      if (present) {
        const original = view(yield 8).getBigInt64(0, true);
        if (original < 0n || original > 4294967295n) invalid('aux_index_range');
        index = Number(original);
      } else unknown++;
      const length = view(yield 4).getUint32(0, true);
      let fields: Uint8Array = new Uint8Array(0);
      if (length > 0 && length <= MAX_FIELDS) fields = yield length;
      else for (let left = length; left > 0;) { const take = Math.min(left, 65536); yield take; left -= take; }
      const decoded = strictAuxiliaryFields(fields);
      if (!decoded.supported) { unsupported++; continue; }
      if (decoded.recordIndex !== index) invalid('aux_fields_identity_mismatch');
      supported++;
    }
    if (count > 0 && (min !== startTs || max + 1 !== endTs)) invalid('aux_window_mismatch');
    return { version: 1, format: 2, records: count, supportedRecords: supported,
      unknownIdentityRecords: unknown, unsupportedFieldsRecords: unsupported,
      state: unsupported > 0 ? 'pending' : 'validated' };
  }
}
