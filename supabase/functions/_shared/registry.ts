// Port of the retired Node receiver — stream registry, projections, NDJSON parse, acks.
// This is the wire contract with the NOOP clients; keep semantics byte-identical with Node.
import {
  dailyMetricRow,
  sleepSessionRow,
  workoutSessionRow,
} from './structuredSync.ts';
import { OBJECT_LANE_STREAMS } from './keys.ts';

export const PUSH_PROTOCOL_VERSIONS = ['1.2', '1.1', '1.0'];

export const APPEND_STREAMS = new Set([
  'hrSample', 'rrInterval', 'rrPacketProvenance', 'standardHRReceipt', 'event', 'battery', 'spo2Sample', 'skinTempSample',
  'respSample', 'gravitySample', 'stepSample', 'sleepStateSample', 'ppgHrSample',
  'appleStepHour', 'ouraRaw', 'coachMessage',
]);

export const REPLACE_STREAMS = new Set([
  'dailyMetric', 'sleepSession', 'workout', 'journal', 'metricSeries', 'appleDaily',
  'scoreInputProvenance', 'labMarker', 'liveSession',
]);

export const BINARY_STREAMS = new Set([
  'ppgWaveformSample', 'v18AuxSample', 'rawBatch', 'rawImuSession',
]);

export const ALL_STREAMS = new Set([...APPEND_STREAMS, ...REPLACE_STREAMS, ...BINARY_STREAMS]);

/**
 * Object-lane streams are advertised ONLY at 1.2, because 1.2 is the version that carries the
 * `objectLane` block telling a sender where to PUT. Advertising them to a 1.1 sender would name a
 * stream it has no way to deliver: it would post the object inline, be refused with
 * `use_object_lane`, and have nowhere to go with that — a failure loop caused entirely by offering
 * a capability the negotiated version cannot exercise. A stream absent from the capability set is
 * simply not attempted, which is the correct outcome for a sender that predates the lane.
 */
const PROTOCOL_1_2_ONLY = new Set(OBJECT_LANE_STREAMS);

/** Streams added in protocol 1.1 — excluded from the 1.0 capability set. */
const PROTOCOL_1_1_ONLY_APPEND = new Set([
  'rrPacketProvenance', 'standardHRReceipt',
  'stepSample', 'sleepStateSample', 'ppgHrSample', 'appleStepHour', 'ouraRaw', 'coachMessage',
]);
const PROTOCOL_1_1_ONLY_REPLACE = new Set([
  'metricSeries', 'appleDaily', 'scoreInputProvenance', 'labMarker', 'liveSession',
]);

export const PROTOCOL_1_0_STREAMS = new Set([
  ...[...APPEND_STREAMS].filter((s) => !PROTOCOL_1_1_ONLY_APPEND.has(s)),
  ...[...REPLACE_STREAMS].filter((s) => !PROTOCOL_1_1_ONLY_REPLACE.has(s)),
]);

type AppendMapRowArgs = {
  userId: string;
  deviceId: string;
  sourceId: unknown;
  batchId: unknown;
  record: any;
};

/** v1.0 append streams with Supabase projection tables (P1.1). */
export const APPEND_STREAM_PROJECTIONS: Record<string, {
  table: string;
  onConflict: string;
  tsKey: string;
  mapRow: (args: AppendMapRowArgs) => Record<string, unknown> | null;
}> = {
  hrSample: {
    table: 'noop_hr_samples',
    onConflict: 'user_id,device_id,ts',
    tsKey: 'ts',
    mapRow: ({ userId, deviceId, sourceId, batchId, record }) => {
      const ts = Number(record.key?.ts);
      const bpm = Number(record.data?.bpm);
      if (!Number.isFinite(ts) || !Number.isFinite(bpm)) return null;
      return {
        user_id: userId,
        device_id: deviceId,
        source_id: sourceId,
        ts,
        bpm,
        batch_id: batchId,
      };
    },
  },
  rrInterval: {
    table: 'noop_rr_intervals',
    onConflict: 'user_id,device_id,ts,rrMs,seq',
    tsKey: 'ts',
    mapRow: ({ userId, deviceId, sourceId, batchId, record }) => {
      const ts = Number(record.key?.ts);
      const rrMs = Number(record.key?.rrMs);
      const seq = Number(record.key?.seq);
      if (!Number.isFinite(ts) || !Number.isFinite(rrMs) || !Number.isFinite(seq)) return null;
      const row: Record<string, unknown> = {
        user_id: userId,
        device_id: deviceId,
        source_id: sourceId,
        ts,
        rrMs,
        seq,
        batch_id: batchId,
      };
      // An absent order/channel/clock flag is unknown, not numeric zero.
      for (const field of ['ord', 'srcChannel', 'tsSuspect']) {
        const value = record.data?.[field];
        if (value === null) row[field] = null;
        else if (value !== undefined && Number.isFinite(Number(value))) row[field] = Number(value);
      }
      return row;
    },
  },
  rrPacketProvenance: {
    table: 'noop_rr_packet_provenance',
    onConflict: 'user_id,device_id,packetId',
    tsKey: 'ts',
    mapRow: ({ userId, deviceId, sourceId, batchId, record }) => {
      const d = record.data ?? {};
      const packetId = record.key?.packetId;
      if (typeof packetId !== 'string' || !/^[a-f0-9]{64}$/.test(packetId) ||
          typeof d.rawHex !== 'string' || !/^[a-f0-9]+$/.test(d.rawHex) ||
          d.rawHex.length % 2 !== 0 || d.rawHex.length < 56 || d.rawHex.length > 131086 ||
          d.schemaVersion !== 1 || d.srcChannel !== 5 || d.decoderVersion !== 'whoop5-v18-original-words-v1' ||
          !['sensor-second-unmapped', 'legacy-stale-clock-snap300-v1'].includes(String(d.clockVersion))) return null;
      for (const name of ['ts', 'sensorTs', 'recordIndex', 'clockOffsetSeconds', 'declaredCount']) {
        if (!Number.isSafeInteger(d[name])) return null;
      }
      if (Number(d.recordIndex) < 0 || Number(d.recordIndex) > 4294967295 ||
          Number(d.declaredCount) < 0 || Number(d.declaredCount) > 255 ||
          ![1, 300].includes(Number(d.timestampPrecisionSeconds)) ||
          Number(d.ts) - Number(d.sensorTs) !== Number(d.clockOffsetSeconds)) return null;
      // These are raw claimed receipt fields, not server-verified timing. The reader recomputes
      // CRC, sensor-record SHA256, word positions and all metadata before creating observations.
      return { user_id: userId, device_id: deviceId, source_id: sourceId, batch_id: batchId, packetId,
        ts: d.ts, sensorTs: d.sensorTs, recordIndex: d.recordIndex, rawHex: d.rawHex, srcChannel: d.srcChannel,
        schemaVersion: d.schemaVersion, decoderVersion: d.decoderVersion, clockVersion: d.clockVersion,
        timestampPrecisionSeconds: d.timestampPrecisionSeconds, clockOffsetSeconds: d.clockOffsetSeconds,
        declaredCount: d.declaredCount };
    },
  },
  standardHRReceipt: {
    table: 'noop_standard_hr_receipts',
    onConflict: 'user_id,device_id,receiptId',
    tsKey: 'ts',
    mapRow: ({ userId, deviceId, sourceId, batchId, record }) => {
      const d = record.data ?? {};
      const receiptId = record.key?.receiptId;
      if (typeof d.sessionId !== 'string' ||
          !/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(d.sessionId) ||
          typeof d.rawHex !== 'string' || !/^[a-f0-9]{2,1024}$/.test(d.rawHex) || d.rawHex.length % 2 !== 0 ||
          d.schemaVersion !== 1 || d.clockVersion !== 'host-arrival-unmapped') return null;
      for (const field of ['ts', 'notificationOrdinal', 'receivedUnixMs']) {
        if (!Number.isSafeInteger(d[field]) || d[field] < 0) return null;
      }
      // Nanosecond host uptime crosses JavaScript's safe-integer boundary after ~104 days.
      // Require a decimal string on the wire, retain it exactly for PostgreSQL bigint parsing.
      if (typeof d.receivedMonotonicNs !== 'string' || !/^(0|[1-9][0-9]{0,18})$/.test(d.receivedMonotonicNs) ||
          BigInt(d.receivedMonotonicNs) > 9223372036854775807n ||
          receiptId !== `${d.sessionId}:${d.notificationOrdinal}` ||
          d.ts !== Math.floor(d.receivedUnixMs / 1000)) return null;
      // Arrival clocks and consecutive notifications do not assert sensor beat timing/continuity.
      return { user_id: userId, device_id: deviceId, source_id: sourceId, batch_id: batchId, receiptId,
        ts: d.ts, sessionId: d.sessionId, notificationOrdinal: d.notificationOrdinal,
        receivedUnixMs: d.receivedUnixMs, receivedMonotonicNs: d.receivedMonotonicNs,
        rawHex: d.rawHex, schemaVersion: d.schemaVersion, clockVersion: d.clockVersion };
    },
  },
  stepSample: {
    table: 'noop_step_samples',
    onConflict: 'user_id,device_id,ts',
    tsKey: 'ts',
    mapRow: ({ userId, deviceId, sourceId, batchId, record }) => {
      const ts = record.key?.ts;
      const counter = record.data?.counter;
      if (ts == null || counter == null || !Number.isSafeInteger(Number(ts)) ||
          !Number.isSafeInteger(Number(counter)) || Number(counter) < 0) return null;
      const row: Record<string, unknown> = {
        user_id: userId, device_id: deviceId, source_id: sourceId,
        ts: Number(ts), counter: Number(counter), batch_id: batchId,
      };
      const activityClass = record.data?.activityClass;
      if (activityClass === null) row.activityClass = null;
      else if (activityClass !== undefined && Number.isSafeInteger(Number(activityClass))) {
        row.activityClass = Number(activityClass);
      }
      return row;
    },
  },
  event: {
    table: 'noop_events',
    onConflict: 'user_id,device_id,ts,kind',
    tsKey: 'ts',
    mapRow: ({ userId, deviceId, sourceId, batchId, record }) => {
      const ts = Number(record.key?.ts);
      const kind = record.key?.kind;
      const payloadJSON = record.data?.payloadJSON;
      if (!Number.isFinite(ts) || typeof kind !== 'string' || !kind || typeof payloadJSON !== 'string') return null;
      return {
        user_id: userId,
        device_id: deviceId,
        source_id: sourceId,
        ts,
        kind,
        payloadJSON,
        batch_id: batchId,
      };
    },
  },
  battery: {
    table: 'noop_battery_samples',
    onConflict: 'user_id,device_id,ts',
    tsKey: 'ts',
    mapRow: ({ userId, deviceId, sourceId, batchId, record }) => {
      const ts = Number(record.key?.ts);
      if (!Number.isFinite(ts)) return null;
      const row: Record<string, unknown> = {
        user_id: userId,
        device_id: deviceId,
        source_id: sourceId,
        ts,
        batch_id: batchId,
      };
      const soc = Number(record.data?.soc);
      if (Number.isFinite(soc)) row.soc = soc;
      const mv = Number(record.data?.mv);
      if (Number.isFinite(mv)) row.mv = mv;
      if (record.data?.charging === true || record.data?.charging === false) row.charging = record.data.charging;
      return row;
    },
  },
  spo2Sample: {
    table: 'noop_spo2_samples',
    onConflict: 'user_id,device_id,ts',
    tsKey: 'ts',
    mapRow: ({ userId, deviceId, sourceId, batchId, record }) => {
      const ts = Number(record.key?.ts);
      const red = Number(record.data?.red);
      const ir = Number(record.data?.ir);
      if (!Number.isFinite(ts) || !Number.isFinite(red) || !Number.isFinite(ir)) return null;
      return {
        user_id: userId,
        device_id: deviceId,
        source_id: sourceId,
        ts,
        red,
        ir,
        batch_id: batchId,
      };
    },
  },
  skinTempSample: {
    table: 'noop_skin_temp_samples',
    onConflict: 'user_id,device_id,ts',
    tsKey: 'ts',
    mapRow: ({ userId, deviceId, sourceId, batchId, record }) => {
      const ts = Number(record.key?.ts);
      const raw = Number(record.data?.raw);
      if (!Number.isFinite(ts) || !Number.isFinite(raw)) return null;
      const row: Record<string, unknown> = {
        user_id: userId,
        device_id: deviceId,
        source_id: sourceId,
        ts,
        raw,
        batch_id: batchId,
      };
      const aux1Raw = Number(record.data?.aux1Raw);
      if (Number.isFinite(aux1Raw)) row.aux1Raw = aux1Raw;
      const aux2Raw = Number(record.data?.aux2Raw);
      if (Number.isFinite(aux2Raw)) row.aux2Raw = aux2Raw;
      return row;
    },
  },
  respSample: {
    table: 'noop_resp_samples',
    onConflict: 'user_id,device_id,ts',
    tsKey: 'ts',
    mapRow: ({ userId, deviceId, sourceId, batchId, record }) => {
      const ts = Number(record.key?.ts);
      const raw = Number(record.data?.raw);
      if (!Number.isFinite(ts) || !Number.isFinite(raw)) return null;
      return {
        user_id: userId,
        device_id: deviceId,
        source_id: sourceId,
        ts,
        raw,
        batch_id: batchId,
      };
    },
  },
  gravitySample: {
    table: 'noop_gravity_samples',
    onConflict: 'user_id,device_id,ts',
    tsKey: 'ts',
    mapRow: ({ userId, deviceId, sourceId, batchId, record }) => {
      const ts = Number(record.key?.ts);
      const x = Number(record.data?.x);
      const y = Number(record.data?.y);
      const z = Number(record.data?.z);
      if (!Number.isFinite(ts) || !Number.isFinite(x) || !Number.isFinite(y) || !Number.isFinite(z)) return null;
      const row: Record<string, unknown> = {
        user_id: userId,
        device_id: deviceId,
        source_id: sourceId,
        ts,
        x,
        y,
        z,
        batch_id: batchId,
      };
      const dynAccel = Number(record.data?.dynAccel);
      if (Number.isFinite(dynAccel)) row.dynAccel = dynAccel;
      return row;
    },
  },
};

type ReplaceMapRowArgs = {
  userId: string;
  deviceId: string;
  headerDeviceId?: unknown;
  sourceId?: unknown;
  batchId?: unknown;
  replacementId?: unknown;
  record: any;
  protocolVersion?: string;
};

/** v1.0 replace-window streams with Supabase projection tables (P1.2). */
export const REPLACE_STREAM_PROJECTIONS: Record<string, {
  table: string;
  onConflict: string;
  windowSelector: 'day' | 'startTs';
  mapRow: (args: ReplaceMapRowArgs) => Record<string, unknown> | null;
  rowKey: (record: any, headerDeviceId?: unknown) => string;
}> = {
  dailyMetric: {
    table: 'daily_metrics',
    onConflict: 'user_id,day',
    windowSelector: 'day',
    mapRow: ({ userId, deviceId, sourceId, batchId, record, protocolVersion }) => {
      const day = record.key?.day;
      if (!day || typeof day !== 'string') return null;
      const data = record.data || {};
      const metric: Record<string, unknown> = {
        day,
        deviceId,
        totalSleepMin: data.totalSleepMin ?? null,
        efficiency: data.efficiency ?? null,
        deepMin: data.deepMin ?? null,
        remMin: data.remMin ?? null,
        lightMin: data.lightMin ?? null,
        restingHr: data.restingHr ?? null,
        avgHrv: data.avgHrv ?? null,
        recovery: data.recovery ?? null,
        strain: data.strain ?? null,
        exerciseCount: data.exerciseCount ?? null,
        spo2Pct: data.spo2Pct ?? null,
        skinTempDevC: data.skinTempDevC ?? null,
        respRateBpm: data.respRateBpm ?? null,
        steps: data.steps ?? null,
        activeKcalEst: data.activeKcalEst ?? null,
        spo2Red: data.spo2Red ?? null,
        spo2Ir: data.spo2Ir ?? null,
      };
      if (protocolVersion === '1.1') {
        metric.avgSdnn = data.avgSdnn ?? null;
        metric.skinTempC = data.skinTempC ?? null;
        metric.sleepHrOnly = data.sleepHrOnly ?? null;
      }
      const row: any = dailyMetricRow({
        userId,
        deviceUuid: deviceId,
        metric,
        provenance: { source: 'noop_push', source_id: sourceId, batch_id: batchId },
        computedAt: new Date().toISOString(),
        algorithmVersion: 'noop-client',
      });
      if (protocolVersion === '1.1' && data.skinTempC != null) {
        row.skin_temp_c = Number(data.skinTempC);
      }
      row.extras = {
        ...row.extras,
        noop_push: { source_id: sourceId, batch_id: batchId, protocol_version: protocolVersion },
        disturbances: data.disturbances ?? null,
        ...(protocolVersion === '1.1' && data.sleepHrOnly != null
          ? { sleep_hr_only: data.sleepHrOnly }
          : {}),
      };
      return row;
    },
    rowKey: (record) => String(record?.key?.day || ''),
  },
  sleepSession: {
    table: 'sessions',
    onConflict: 'id',
    windowSelector: 'startTs',
    mapRow: ({ userId, deviceId, headerDeviceId, record }) => {
      const startTs = Number(record.key?.startTs);
      const endTs = Number(record.data?.endTs);
      if (!Number.isFinite(startTs) || !Number.isFinite(endTs)) return null;
      const session = {
        deviceId: headerDeviceId,
        startTs,
        endTs,
        efficiency: record.data?.efficiency ?? null,
        restingHr: record.data?.restingHr ?? null,
        avgHrv: record.data?.avgHrv ?? null,
        stagesJSON: record.data?.stagesJSON ?? null,
        userEdited: record.data?.userEdited ?? false,
        startTsAdjusted: record.data?.startTsAdjusted ?? null,
        motionJSON: record.data?.motionJSON ?? null,
        sleepStateJSON: record.data?.sleepStateJSON ?? null,
        stagingSparse: record.data?.stagingSparse ?? false,
        source: 'noop_push',
      };
      const row: any = sleepSessionRow({ userId, deviceUuid: deviceId, session });
      row.summary = {
        ...row.summary,
        motion_json: session.motionJSON,
        sleep_state_json: session.sleepStateJSON,
        staging_sparse: session.stagingSparse,
        noop_external_device_id: headerDeviceId,
      };
      return row;
    },
    rowKey: (record, headerDeviceId) => `sleep:${headerDeviceId}:${record?.key?.startTs}`,
  },
  workout: {
    table: 'sessions',
    onConflict: 'id',
    windowSelector: 'startTs',
    mapRow: ({ userId, deviceId, headerDeviceId, record }) => {
      const startTs = Number(record.key?.startTs);
      const sport = record.key?.sport;
      const endTs = Number(record.data?.endTs);
      if (!Number.isFinite(startTs) || !sport || !Number.isFinite(endTs)) return null;
      const workout = {
        deviceId: headerDeviceId,
        startTs,
        sport,
        endTs,
        source: record.data?.source || 'noop_push',
        durationS: record.data?.durationS ?? null,
        energyKcal: record.data?.energyKcal ?? null,
        avgHr: record.data?.avgHr ?? null,
        maxHr: record.data?.maxHr ?? null,
        strain: record.data?.strain ?? null,
        distanceM: record.data?.distanceM ?? null,
        zonesJSON: record.data?.zonesJSON ?? null,
        notes: record.data?.notes ?? null,
        routePolyline: record.data?.routePolyline ?? null,
        steps: record.data?.steps ?? null,
      };
      const row: any = workoutSessionRow({ userId, deviceUuid: deviceId, workout });
      row.summary = {
        ...row.summary,
        distance_m: workout.distanceM,
        notes: workout.notes,
        route_polyline: workout.routePolyline,
        steps: workout.steps,
        noop_external_device_id: headerDeviceId,
      };
      return row;
    },
    rowKey: (record, headerDeviceId) => `workout:${headerDeviceId}:${record?.key?.startTs}:${record?.key?.sport}`,
  },
  journal: {
    table: 'noop_journal_entries',
    onConflict: 'user_id,device_id,day,question',
    windowSelector: 'day',
    mapRow: ({ userId, deviceId, sourceId, batchId, replacementId, record }) => {
      const day = record.key?.day;
      const question = record.key?.question;
      if (!day || !question) return null;
      return {
        user_id: userId,
        device_id: deviceId,
        source_id: sourceId,
        day,
        question,
        answered_yes: record.data?.answeredYes === true,
        notes: record.data?.notes ?? null,
        numeric_value: record.data?.numericValue ?? null,
        batch_id: batchId,
        replacement_id: replacementId,
      };
    },
    rowKey: (record) => `${record?.key?.day}|${record?.key?.question}`,
  },
};

/**
 * Streams this receiver accepts. The row-shaped streams are enabled by their Supabase projection;
 * the object-lane streams are enabled unconditionally, because their durability does not depend on
 * a projection existing — they land in the bucket and are indexed by manifest.
 */
export const INGEST_ENABLED_STREAMS = new Set([
  ...Object.keys(APPEND_STREAM_PROJECTIONS),
  ...Object.keys(REPLACE_STREAM_PROJECTIONS),
  ...OBJECT_LANE_STREAMS,
]);

export function recordTimestamp(stream: string, record: any): number | null {
  const tsKey = APPEND_STREAM_PROJECTIONS[stream]?.tsKey;
  if (!tsKey) return null;
  const ts = Number(['rrPacketProvenance', 'standardHRReceipt'].includes(stream) ? record?.data?.[tsKey] : record?.key?.[tsKey]);
  return Number.isFinite(ts) ? ts : null;
}

export function archiveWindowFromRecords(stream: string, records: any[], fallbackDate: Date = new Date(), header: any = null) {
  const projection = (APPEND_STREAM_PROJECTIONS as any)[stream] || (REPLACE_STREAM_PROJECTIONS as any)[stream];
  if (projection?.windowSelector === 'day') {
    const days = records.map((record) => record?.key?.day).filter((d) => typeof d === 'string');
    const startDay = days.length ? days.reduce((a, b) => (a < b ? a : b)) : header?.window?.startInclusive;
    const endDay = days.length ? days.reduce((a, b) => (a > b ? a : b)) : null;
    const startAt = startDay ? `${startDay}T00:00:00.000Z` : fallbackDate.toISOString();
    const endAt = endDay ? `${endDay}T23:59:59.999Z` : startAt;
    return { startAt, endAt };
  }
  if (projection?.windowSelector === 'startTs') {
    const timestamps = records
      .map((record) => Number(record?.key?.startTs))
      .filter((n) => Number.isFinite(n));
    if (!timestamps.length && header?.window) {
      const start = Number(header.window.startInclusive);
      const end = Number(header.window.endExclusive);
      if (Number.isFinite(start) && Number.isFinite(end)) {
        return {
          startAt: new Date(start * 1000).toISOString(),
          endAt: new Date((end - 1) * 1000).toISOString(),
        };
      }
    }
    if (!timestamps.length) {
      const iso = fallbackDate.toISOString();
      return { startAt: iso, endAt: iso };
    }
    return {
      startAt: new Date(Math.min(...timestamps) * 1000).toISOString(),
      endAt: new Date(Math.max(...timestamps) * 1000).toISOString(),
    };
  }
  const timestamps = records
    .map((record) => recordTimestamp(stream, record))
    .filter((n): n is number => Number.isFinite(n));
  if (!timestamps.length) {
    const iso = fallbackDate.toISOString();
    return { startAt: iso, endAt: iso };
  }
  return {
    startAt: new Date(Math.min(...timestamps) * 1000).toISOString(),
    endAt: new Date(Math.max(...timestamps) * 1000).toISOString(),
  };
}

export function replacementKeys(stream: string, records: any[], headerDeviceId: unknown): Set<string> {
  const projection = REPLACE_STREAM_PROJECTIONS[stream];
  if (!projection) return new Set();
  return new Set(records.map((record) => projection.rowKey(record, headerDeviceId)).filter(Boolean));
}

export function windowBounds(header: any) {
  const window = header?.window;
  if (!window) return null;
  return {
    selector: window.selector,
    startInclusive: window.startInclusive,
    endExclusive: window.endExclusive,
    replacementId: window.replacementId,
    part: window.part,
    parts: window.parts,
  };
}

export function streamsForVersion(version: string): Set<string> {
  if (version === '1.2') return ALL_STREAMS;
  if (version === '1.1') return new Set([...ALL_STREAMS].filter((s) => !PROTOCOL_1_2_ONLY.has(s)));
  if (version === '1.0') return PROTOCOL_1_0_STREAMS;
  return new Set();
}

export function advertisedStreams(protocolVersion: string, enabledStreams: Set<string> = INGEST_ENABLED_STREAMS): string[] {
  const allowed = streamsForVersion(protocolVersion);
  return [...enabledStreams].filter((s) => allowed.has(s)).sort();
}

export function negotiateProtocol(acceptHeader: unknown): string | null {
  const offered = String(acceptHeader || '')
    .split(',')
    .map((v) => v.trim())
    .filter(Boolean);
  for (const version of PUSH_PROTOCOL_VERSIONS) {
    if (offered.includes(version)) return version;
  }
  return null;
}

/**
 * `objectLane` tells a 1.2 sender which streams bypass this endpoint entirely and go straight to
 * the bucket with a presigned PUT. Omitted below 1.2, so an older client keeps its inline behaviour.
 */
export function capabilitiesBody({
  receiverStateId,
  streams,
  userId,
  sourceId,
  protocolVersion = '1.2',
  objectLane = null,
}: {
  receiverStateId: string;
  streams: string[];
  userId?: string;
  sourceId?: string | null;
  protocolVersion?: string;
  objectLane?: { endpoint: string; maxObjectBytes: number; urlTtlSec: number } | null;
}) {
  const advertised = [...streams].sort();
  const body: any = {
    type: 'capabilities',
    protocolVersion,
    receiverStateId,
    streams: advertised,
    userId: userId || undefined,
    sourceId: sourceId || undefined,
  };
  if (protocolVersion === '1.2' && objectLane) {
    body.objectLane = {
      ...objectLane,
      streams: advertised.filter((s) => OBJECT_LANE_STREAMS.has(s)),
    };
  }
  return body;
}

export function parseNdjsonEntity(bytes: Uint8Array) {
  const text = new TextDecoder().decode(bytes);
  const lines = text.split('\n').filter((line) => line.length > 0);
  if (!lines.length) throw new PushProtocolError('empty_ndjson', 400);
  let header: any;
  try {
    header = JSON.parse(lines[0]);
  } catch {
    throw new PushProtocolError('malformed_batch_header', 400);
  }
  if (header?.type !== 'batch') throw new PushProtocolError('missing_batch_header', 400);
  const records: any[] = [];
  for (let i = 1; i < lines.length; i += 1) {
    try {
      const row = JSON.parse(lines[i]);
      if (row?.type !== 'record') throw new PushProtocolError('invalid_record_line', 400);
      records.push(row);
    } catch (err) {
      if (err instanceof PushProtocolError) throw err;
      throw new PushProtocolError('malformed_record_line', 400);
    }
  }
  if (records.length !== Number(header.recordCount)) {
    throw new PushProtocolError('record_count_mismatch', 422);
  }
  return { header, records, lineCount: lines.length };
}

export function buildAck(header: any) {
  return {
    protocolVersion: header.protocolVersion,
    batchId: header.batchId,
    stream: header.stream,
    deviceId: header.deviceId,
    endCursor: header.endCursor ?? null,
    acceptedRows: header.recordCount,
    status: 'accepted',
  };
}

export function ackMatchesBatch(ack: any, header: any): boolean {
  return ack?.protocolVersion === header.protocolVersion
    && ack?.batchId === header.batchId
    && ack?.stream === header.stream
    && ack?.deviceId === header.deviceId
    && JSON.stringify(ack?.endCursor ?? null) === JSON.stringify(header.endCursor ?? null)
    && ack?.acceptedRows === header.recordCount
    && ack?.status === 'accepted';
}

export class PushProtocolError extends Error {
  code: string;
  status: number;
  fields?: string[];
  constructor(code: string, status = 400) {
    super(code);
    this.code = code;
    this.status = status;
  }
}
