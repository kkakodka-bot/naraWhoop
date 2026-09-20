import { PushProtocolError } from './registry.ts';

const keys = new Set(['v', 'origin', 'recordIndex', 'frameSHA256', 'algorithm', 'sampleRateHz',
  'windowSettingSeconds', 'inputStartTs', 'inputEndTs', 'inputSHA256', 'inputSelection']);
const integerKeys = new Set(['recordIndex', 'sampleRateHz', 'windowSettingSeconds', 'inputStartTs', 'inputEndTs']);

/** Absent provenance stays unknown. Never infer it from current flags or scalar values. */
export function scalarProvenance(value: unknown, protocolVersion: string): Record<string, unknown> | null {
  if (value == null) return null;
  const invalid = (): never => { throw new PushProtocolError('invalid_scalar_provenance', 422); };
  if (protocolVersion !== '1.4' || typeof value !== 'object' || Array.isArray(value)) invalid();
  const p = value as Record<string, unknown>;
  if (new TextEncoder().encode(JSON.stringify(p)).length > 1024 || p.v !== 1 || typeof p.origin !== 'string' ||
      !['whoop-v18', 'whoop-v26-ppg-derived', 'legacy-unknown'].includes(p.origin as string)) invalid();
  for (const [key, field] of Object.entries(p)) {
    if (!keys.has(key) || field == null || typeof field === 'object' || typeof field === 'boolean') invalid();
    if (integerKeys.has(key) && (typeof field !== 'number' || !Number.isSafeInteger(field))) invalid();
    if (key === 'recordIndex' && ((field as number) < 0 || (field as number) > 4294967295)) invalid();
    if (['sampleRateHz', 'windowSettingSeconds'].includes(key) && (field as number) <= 0) invalid();
    if (['frameSHA256', 'inputSHA256'].includes(key) && (typeof field !== 'string' || !/^[0-9a-f]{64}$/.test(field))) invalid();
    if (key === 'algorithm' && (typeof field !== 'string' || !['ppg-acf-v1', 'ppg-acf-sublag-v1'].includes(field))) invalid();
    if (key === 'inputSelection' && (typeof field !== 'string' ||
        !['last-record-per-second-v1', 'concat-records-per-second-v1'].includes(field))) invalid();
  }
  if (p.inputStartTs != null && p.inputEndTs != null && Number(p.inputEndTs) <= Number(p.inputStartTs)) invalid();
  const derivation = ['algorithm', 'sampleRateHz', 'windowSettingSeconds', 'inputStartTs', 'inputEndTs', 'inputSHA256'];
  if (p.origin === 'whoop-v26-ppg-derived') {
    if (p.recordIndex != null || p.frameSHA256 != null || derivation.some((key) => p[key] == null)) invalid();
  } else {
    if (p.inputSelection != null || derivation.some((key) => p[key] != null)) invalid();
    if (p.origin === 'legacy-unknown' && (p.recordIndex != null || p.frameSHA256 != null)) invalid();
  }
  return p;
}
