// Port of the retired Node receiver — push-lane subset. Keep byte-identical semantics with the
// Node original: object keys, retention classes, and archive specs are a cross-process contract.
import { createHash } from 'node:crypto';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

/** Deterministic UUID from opaque parts (device MAC hashes, local-demo, etc.). */
export function uuidFromParts(parts: unknown[]): string {
  const hex = createHash('sha256').update((parts || []).join('|')).digest('hex').slice(0, 32);
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-5${hex.slice(13, 16)}-a${hex.slice(17, 20)}-${hex.slice(20, 32)}`;
}

/**
 * Cloud device uuid for a NOOP push `deviceId`, which is a strap-local opaque id rather than a uuid.
 * Both push lanes must mint identically or the same strap lands under two device ids and its object
 * keys stop lining up with its row projections.
 */
export function noopDeviceId(userId: string, deviceId: unknown): string {
  if (isUuid(deviceId)) return String(deviceId);
  return uuidFromParts([userId, 'noop', String(deviceId || 'strap')]);
}

// Deliberately NOT a `value is string` guard: callers pass strings and the guard's false-branch
// narrowing (string & not-string → never) breaks downstream string ops under Deno's type check.
export function isUuid(value: unknown): boolean {
  return typeof value === 'string' && UUID_RE.test(value);
}

const STREAM_EXT: Record<string, string> = {
  frames: 'ndjson.gz',
  frames_reassembled: 'ndjson.gz',
  physiology: 'ndjson.gz',
  hr: 'ndjson.gz',
  rr: 'ndjson.gz',
  hr_rr: 'ndjson.gz',
  hrSample: 'ndjson.gz',
  rrInterval: 'ndjson.gz',
  event: 'ndjson.gz',
  battery: 'ndjson.gz',
  spo2Sample: 'ndjson.gz',
  skinTempSample: 'ndjson.gz',
  respSample: 'ndjson.gz',
  gravitySample: 'ndjson.gz',
  stepSample: 'ndjson.gz',
  sleepStateSample: 'ndjson.gz',
  ppgHrSample: 'ndjson.gz',
  appleStepHour: 'ndjson.gz',
  ouraRaw: 'ndjson.gz',
  coachMessage: 'ndjson.gz',
  dailyMetric: 'ndjson.gz',
  sleepSession: 'ndjson.gz',
  workout: 'ndjson.gz',
  journal: 'ndjson.gz',
  metricSeries: 'ndjson.gz',
  appleDaily: 'ndjson.gz',
  scoreInputProvenance: 'ndjson.gz',
  labMarker: 'ndjson.gz',
  liveSession: 'ndjson.gz',
  ppgWaveformSample: 'bin.gz',
  v18AuxSample: 'bin.gz',
  rawBatch: 'pb.zst',
  rawImuSession: 'bin.zst',
  ppg: 'bin.gz',
  imu: 'bin.gz',
  ble: 'bin.gz',
  diagnostic: 'bin.gz',
  ecg: 'bin.gz',
  derived: 'json.gz',
  export: 'json.gz',
  imu_raw: 'ndjson.gz',
  ppg_raw: 'ndjson.gz',
  whoop5_imu_v21: 'ndjson.gz',
  whoop5_ppg_v26: 'ndjson.gz',
  whoop5_optical_v20: 'ndjson.gz',
  events: 'ndjson.gz',
  console_logs: 'ndjson.gz',
  cmd_battery: 'ndjson.gz',
};

export const RETENTION_CLASS: Record<string, string> = {
  frames: 'core',
  frames_reassembled: 'core',
  physiology: 'core',
  hr: 'core',
  rr: 'core',
  hr_rr: 'core',
  live_hr: 'core',
  derived: 'core',
  ppg: 'ppg',
  imu: 'imu',
  imu_raw: 'core',
  ppg_raw: 'core',
  whoop5_imu_v21: 'core',
  whoop5_ppg_v26: 'core',
  whoop5_optical_v20: 'core',
  hrSample: 'core',
  rrInterval: 'core',
  event: 'core',
  battery: 'core',
  spo2Sample: 'core',
  skinTempSample: 'core',
  respSample: 'core',
  gravitySample: 'core',
  stepSample: 'core',
  sleepStateSample: 'core',
  ppgHrSample: 'core',
  appleStepHour: 'core',
  ouraRaw: 'core',
  coachMessage: 'core',
  dailyMetric: 'core',
  sleepSession: 'core',
  workout: 'core',
  journal: 'core',
  metricSeries: 'core',
  appleDaily: 'core',
  scoreInputProvenance: 'core',
  labMarker: 'core',
  liveSession: 'core',
  // Object-lane raw signal. `research` never expires and carries no B2 lifecycle rule, so the
  // longitudinal corpus is not deleted underneath the manifests. `v18AuxSample` stays `diag`: it is
  // an unpinned diagnostic field dump, not signal anyone will train on.
  ppgWaveformSample: 'research',
  rawImuSession: 'research',
  rawBatch: 'research',
  v18AuxSample: 'diag',
  ble: 'diag',
  diagnostic: 'diag',
  export: 'export',
};

/**
 * Streams the device uploads straight to the bucket with a presigned PUT instead of posting inline
 * through the push endpoint. Bytes never transit the function; it brokers the URL and owns the manifest.
 */
export const OBJECT_LANE_STREAMS: ReadonlySet<string> = Object.freeze(new Set([
  'ppgWaveformSample',
  'rawImuSession',
  'rawBatch',
  'v18AuxSample',
]));

/** Nominal records per second for an object-lane stream, or null when the stream has no fixed rate. */
export const OBJECT_LANE_RECORD_HZ: Record<string, number | null> = Object.freeze({
  ppgWaveformSample: 1,
  rawImuSession: 1,
  v18AuxSample: 1,
  rawBatch: null,
});

function sanitizeStream(stream: unknown): string {
  return String(stream || 'physiology').replace(/[^a-z0-9_]/gi, '') || 'physiology';
}

/** Retention class for a stream — must match rawObjectKeyV3's v3/{class}/ prefix. */
export function retentionClassForStream(stream: unknown): string {
  return RETENTION_CLASS[sanitizeStream(stream)] || 'core';
}

/** Parse the retention-class segment from a v3 object key. */
export function retentionClassFromObjectKey(objectKey: unknown): string | null {
  const m = /^v3\/([^/]+)\//.exec(String(objectKey || ''));
  return m ? m[1] : null;
}

const PUSH_ARCHIVE_BY_EXT: Record<string, { format: string; contentType: string; compression: string }> = {
  'ndjson.gz': {
    format: 'ndjson_gzip_noop_push_v1',
    contentType: 'application/x-ndjson',
    compression: 'gzip',
  },
  'bin.gz': {
    format: 'bin_gzip_noop_push_v1',
    contentType: 'application/octet-stream',
    compression: 'gzip',
  },
  'bin.zst': {
    format: 'bin_zstd_noop_push_v1',
    contentType: 'application/octet-stream',
    compression: 'zstd',
  },
  'pb.zst': {
    format: 'protobuf_zstd_noop_push_v1',
    contentType: 'application/octet-stream',
    compression: 'zstd',
  },
};

/** Canonical NOOP push archive metadata for object_manifests (format/type/compression/class). */
export function pushArchiveSpecForStream(stream: unknown) {
  const safe = sanitizeStream(stream);
  const ext = STREAM_EXT[safe] || 'ndjson.gz';
  const wire = PUSH_ARCHIVE_BY_EXT[ext] || PUSH_ARCHIVE_BY_EXT['ndjson.gz'];
  return {
    retentionClass: retentionClassForStream(safe),
    format: wire.format,
    contentType: wire.contentType,
    compression: wire.compression,
  };
}

function assertIds({ userId, deviceId, objectId, allowMissingDevice = false }: {
  userId: unknown;
  deviceId?: unknown;
  objectId: unknown;
  allowMissingDevice?: boolean;
}) {
  if (!isUuid(userId)) throw new Error('user id must be a uuid');
  if (looksLikePii(userId) || looksLikePii(deviceId) || looksLikePii(objectId)) {
    throw new Error('pii in object identity');
  }
  if (!allowMissingDevice && !isUuid(deviceId)) throw new Error('device id must be a uuid');
  if (!isUuid(objectId)) throw new Error('object id must be a uuid');
}

/**
 * v3 key: retention class is the first path segment so B2 lifecycle prefixes work.
 * v3/{core|ppg|imu|diag|export}/users/{user}/devices/{device}/{stream}/YYYY/MM/DD/HH/{id}.ext
 */
export function rawObjectKeyV3({ userId, deviceId, stream = 'physiology', startAt, objectId }: {
  userId: string;
  deviceId: string;
  stream?: string;
  startAt: Date | string | number;
  objectId: string;
}): string {
  assertIds({ userId, deviceId, objectId });
  const d = startAt instanceof Date ? startAt : new Date(startAt);
  if (Number.isNaN(d.getTime())) throw new Error('startAt must be a UTC instant');
  const p = (n: number) => String(n).padStart(2, '0');
  const yyyy = d.getUTCFullYear();
  const mm = p(d.getUTCMonth() + 1);
  const dd = p(d.getUTCDate());
  const hh = p(d.getUTCHours());
  const safe = sanitizeStream(stream);
  const cls = retentionClassForStream(safe);
  const ext = STREAM_EXT[safe] || 'ndjson.gz';
  return `v3/${cls}/users/${userId}/devices/${deviceId}/${safe}/${yyyy}/${mm}/${dd}/${hh}/${objectId}.${ext}`;
}

/**
 * Inverse of `rawObjectKeyV3`. Returns null for anything that is not a well-formed v3 key rather
 * than guessing, so a reconciliation sweep cannot silently attribute an object to the wrong subject.
 * `rawObjectKeyV3(parseRawObjectKeyV3(k))` reproduces `k` for every key the builder can emit.
 */
export function parseRawObjectKeyV3(objectKey: unknown) {
  const parts = String(objectKey || '').split('/');
  if (parts.length !== 12) return null;
  const [v3, cls, users, userId, devices, deviceId, stream, yyyy, mm, dd, hh, leaf] = parts;
  if (v3 !== 'v3' || users !== 'users' || devices !== 'devices') return null;
  if (!isUuid(userId) || !isUuid(deviceId)) return null;
  if (sanitizeStream(stream) !== stream) return null;
  if (retentionClassForStream(stream) !== cls) return null;
  const dot = leaf.indexOf('.');
  if (dot <= 0) return null;
  const objectId = leaf.slice(0, dot);
  const ext = leaf.slice(dot + 1);
  if (!isUuid(objectId) || (STREAM_EXT[stream] || 'ndjson.gz') !== ext) return null;
  if (!/^\d{4}$/.test(yyyy) || !/^\d{2}$/.test(mm) || !/^\d{2}$/.test(dd) || !/^\d{2}$/.test(hh)) return null;
  const startAt = new Date(`${yyyy}-${mm}-${dd}T${hh}:00:00.000Z`);
  if (Number.isNaN(startAt.getTime())) return null;
  return { userId, deviceId, stream, startAt, objectId, retentionClass: cls, ext };
}

export function looksLikePii(value: unknown): boolean {
  if (value == null) return false;
  const s = String(value);
  if (isUuid(s)) return false;
  if (s.includes('@')) return true;
  if (/^\+?\d{7,}$/.test(s.replace(/[\s-]/g, ''))) return true;
  return false;
}

export function periodParts(isoDay: unknown) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(isoDay));
  return m ? { yyyy: m[1], mm: m[2], dd: m[3] } : null;
}

/** v1 subject prefix. Mirrors the retired Node receiver userPrefix. */
export function userPrefix(userId: string): string {
  if (!isUuid(userId)) throw new Error('user id must be a uuid');
  return `v1/users/${userId}/`;
}

/** v2 subject prefix. */
export function userPrefixV2(userId: string): string {
  if (!isUuid(userId)) throw new Error('user id must be a uuid');
  return `v2/users/${userId}/`;
}

/**
 * Every prefix a subject's bytes can live under. Per-subject deletion walks this list, so a new
 * retention class that is not listed here leaves objects behind that no delete request can reach.
 * RETENTION_CLASS is the source of truth; v3 entries are derived from it.
 */
/** Canonical B2 key for one JVM-scored day archive (json.zst). */
export function derivedScoresObjectKey(userId: string, day: string, algorithmVersion: string): string {
  if (!isUuid(userId)) throw new Error('user id must be a uuid');
  if (!/^\d{4}-\d{2}-\d{2}$/.test(String(day))) throw new Error('day must be YYYY-MM-DD');
  const ver = String(algorithmVersion || 'frwhoop-server-1');
  return `v3/derived/users/${userId}/days/${day}/${ver}.json.zst`;
}

export function allUserPrefixes(userId: string): string[] {
  if (!isUuid(userId)) throw new Error('user id must be a uuid');
  const classes = [...new Set(Object.values(RETENTION_CLASS))].sort();
  return [
    userPrefix(userId),
    userPrefixV2(userId),
    `v3/derived/users/${userId}/`,
    ...classes.map((cls) => `v3/${cls}/users/${userId}/`),
  ];
}
