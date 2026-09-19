// Deno mirror of the capabilities/negotiation cases from the retired Node receiver,
// plus NDJSON parse and ack parity from the Node pushRegistry suite.
import assert from 'node:assert/strict';
import {
  advertisedStreams,
  capabilitiesBody,
  negotiateProtocol,
  parseNdjsonEntity,
  buildAck,
  ackMatchesBatch,
  REPLACE_STREAM_PROJECTIONS,
  PushProtocolError,
  APPEND_STREAM_PROJECTIONS,
  recordTimestamp,
} from '../_shared/registry.ts';
import { OBJECT_LANE_STREAMS } from '../_shared/keys.ts';
import { deleteReplacementRows } from '../_shared/ingest.ts';

const OBJECT_LANE_PATH = '/functions/v1/push/objects';

Deno.test('existing scalar streams are enabled at 1.1 onward, never in 1.0 or the object lane', () => {
  for (const version of ['1.0', '1.1', '1.2', '1.3']) {
    const body = capabilitiesBody({ receiverStateId: 'fixture', protocolVersion: version,
      streams: advertisedStreams(version), objectLane: { endpoint: OBJECT_LANE_PATH, maxObjectBytes: 1024, urlTtlSec: 300 } });
    for (const stream of ['stepSample', 'sleepStateSample', 'ppgHrSample']) {
      assert.equal(body.streams.includes(stream), version !== '1.0');
      assert(!body.objectLane?.streams.includes(stream));
    }
  }
});

Deno.test('scalar mappings preserve nulls and reject malformed measurements without coercion', () => {
  const cases = [
    ['stepSample', { counter: 0 }, { counter: 0, activity_class: null }, 'counter'],
    ['sleepStateSample', { state: 0 }, { state: 0, raw_byte: null }, 'state'],
    ['ppgHrSample', { bpm: 70 }, { bpm: 70, conf: null }, 'bpm'],
  ] as const;
  for (const [stream, data, expected, required] of cases) {
    const map = (record: unknown) => APPEND_STREAM_PROJECTIONS[stream].mapRow({
      userId: 'owner', deviceId: 'device', sourceId: 'source', batchId: 'batch', record });
    assert.deepEqual(map({ key: { ts: 1_790_000_000 }, data }), {
      user_id: 'owner', device_id: 'device', source_id: 'source', batch_id: 'batch', ts: 1_790_000_000, ...expected });
    for (const value of [null, undefined, '1', true, 1.5, Infinity, 2147483648]) {
      assert.throws(() => map({ key: { ts: 1_790_000_000 }, data: { ...data, [required]: value } }), /invalid_scalar_record/);
    }
    for (const ts of [null, undefined, '1790000000', 0.5, Infinity]) {
      assert.throws(() => map({ key: { ts }, data }), /invalid_scalar_record/);
    }
  }
});

Deno.test('scalar numeric boundaries preserve counter wrap, raw band codes and nullable confidence', () => {
  const map = (stream: string, data: unknown) => APPEND_STREAM_PROJECTIONS[stream].mapRow({
    userId: 'owner', deviceId: 'device', sourceId: 'source', batchId: 'batch',
    record: { key: { ts: 1_790_000_000 }, data },
  });
  for (const counter of [0, 65535]) assert.equal(map('stepSample', { counter })?.counter, counter);
  for (const state of [0, 1, 2, 3]) assert.equal(map('sleepStateSample', { state, rawByte: state * 16 + 15 })?.state, state);
  for (const conf of [null, 0, 1]) assert.equal(map('ppgHrSample', { bpm: 70, conf })?.conf, conf);
  for (const [stream, data] of [
    ['stepSample', { counter: 65536 }], ['stepSample', { counter: -1 }],
    ['stepSample', { counter: 1, activityClass: 3 }], ['sleepStateSample', { state: 4 }],
    ['sleepStateSample', { state: 1, rawByte: 0 }], ['sleepStateSample', { state: 0, rawByte: 256 }],
    ['ppgHrSample', { bpm: 0 }], ['ppgHrSample', { bpm: 70, conf: 1.001 }],
    ['ppgHrSample', { bpm: 70, conf: -0.001 }], ['ppgHrSample', { bpm: 70, conf: '0.5' }],
  ] as const) assert.throws(() => map(stream, data), /invalid_scalar_record/);
});

Deno.test('versioned RR packet receipt keeps immutable bytes and cannot assert beat timing', () => {
  assert.ok(advertisedStreams('1.1').includes('rrPacketProvenance'));
  assert.ok(!advertisedStreams('1.0').includes('rrPacketProvenance'));
  const record = { key: { packetId: 'e52beecb9be542acaabce3b8e6d34e4b95e19e31b0c39c910df986da3b2b578b' }, data: {
    ts: 1700000000, sensorTs: 1700000000, recordIndex: 0,
    rawHex: 'aa011a00010023592f12000000000000f153650000003c03000400000002c74eaa5b',
    srcChannel: 5, schemaVersion: 1, decoderVersion: 'whoop5-v18-original-words-v1',
    clockVersion: 'sensor-second-unmapped', timestampPrecisionSeconds: 1, clockOffsetSeconds: 0, declaredCount: 3,
    verifiedSpan: { start: 1700000000, end: 1700000300 },
  } };
  const context = { userId: 'u', deviceId: 'd', sourceId: 's', batchId: 'b', record };
  const row = APPEND_STREAM_PROJECTIONS.rrPacketProvenance.mapRow(context);
  assert.equal(row?.rawHex, record.data.rawHex); assert.equal(row?.packetId, record.key.packetId);
  assert.equal(row?.verifiedSpan, undefined); assert.equal(recordTimestamp('rrPacketProvenance', record), 1700000000);
  assert.equal(APPEND_STREAM_PROJECTIONS.rrPacketProvenance.mapRow({ ...context,
    record: { ...record, data: { ...record.data, schemaVersion: 2 } } }), null);
});

Deno.test('capabilities: object-lane streams are offered at 1.2 only', () => {
  const at12 = advertisedStreams('1.2');
  for (const stream of OBJECT_LANE_STREAMS) {
    assert.ok(at12.includes(stream), `${stream} must be offered to a 1.2 sender`);
  }

  for (const version of ['1.1', '1.0']) {
    const offered = advertisedStreams(version);
    for (const stream of OBJECT_LANE_STREAMS) {
      assert.ok(
        !offered.includes(stream),
        `${stream} offered at ${version}, which has no object lane to deliver it through`,
      );
    }
    // The ordinary inline streams must keep working for older senders.
    assert.ok(offered.includes('hrSample'));
  }
});

Deno.test('capabilities: the objectLane block appears only alongside the streams it describes', () => {
  const lane = { endpoint: OBJECT_LANE_PATH, maxObjectBytes: 1024, urlTtlSec: 900 };

  const v12 = capabilitiesBody({
    receiverStateId: 'r',
    streams: advertisedStreams('1.2'),
    protocolVersion: '1.2',
    userId: '11111111-1111-4111-8111-111111111111',
    sourceId: '22222222-2222-4222-8222-222222222222',
    objectLane: lane,
  });
  assert.equal(v12.userId, '11111111-1111-4111-8111-111111111111');
  assert.equal(v12.sourceId, '22222222-2222-4222-8222-222222222222');
  assert.equal(v12.objectLane.endpoint, OBJECT_LANE_PATH);
  assert.deepEqual(
    [...v12.objectLane.streams].sort(),
    [...OBJECT_LANE_STREAMS].sort(),
    'the lane must list exactly the streams it accepts',
  );

  const v11 = capabilitiesBody({
    receiverStateId: 'r',
    streams: advertisedStreams('1.1'),
    protocolVersion: '1.1',
    objectLane: lane,
  });
  assert.equal(v11.objectLane, undefined, 'a 1.1 sender must not be told about the object lane');
});

Deno.test('event labels are advertised only to 1.2 clients and map to durable annotations', () => {
  assert.ok(advertisedStreams('1.2').includes('eventLabel'));
  assert.ok(!advertisedStreams('1.1').includes('eventLabel'));
  assert.ok(!advertisedStreams('1.0').includes('eventLabel'));

  const row = REPLACE_STREAM_PROJECTIONS.eventLabel.mapRow({
    userId: '11111111-1111-4111-8111-111111111111',
    deviceId: '22222222-2222-4222-8222-222222222222',
    sourceId: '33333333-3333-4333-8333-333333333333',
    batchId: '44444444-4444-4444-8444-444444444444',
    replacementId: '55555555-5555-4555-8555-555555555555',
    record: {
      key: { id: '66666666-6666-4666-8666-666666666666', startTs: 1_789_763_348 },
      data: {
        label: 'Outdoor walk', endTs: 1_789_763_438, notes: 'sunny',
        timeZoneIdentifier: 'America/Los_Angeles', source: 'manual_experiment',
      },
    },
  });
  assert.equal(row?.external_id, '66666666-6666-4666-8666-666666666666');
  assert.equal(row?.label, 'Outdoor walk');
  assert.equal(row?.source, 'patient');
  assert.equal(row?.confidence, 'confirmed');
  assert.equal(row?.local_source, 'manual_experiment');
});

Deno.test('event-label replacement deletes are scoped to the uploading installation', async () => {
  const selects: string[] = [];
  const deletes: string[] = [];
  const rest = {
    configured: true,
    async select(_table: string, query: string) {
      selects.push(query);
      return [
        { id: 'delete-me', external_id: 'old-event' },
        { id: 'keep-me', external_id: 'current-event' },
      ];
    },
    async delete(_table: string, query: string) { deletes.push(query); },
  };

  await deleteReplacementRows(rest as any, 'noop_event_labels', {
    userId: 'user',
    deviceId: 'device',
    sourceId: '33333333-3333-4333-8333-333333333333',
    startTsGte: 1_789_689_600,
    startTsLt: 1_789_776_000,
    keepKeys: new Set(['current-event']),
  });

  assert.match(selects[0], /source_id=eq\.33333333-3333-4333-8333-333333333333/);
  assert.deepEqual(deletes, ['id=eq.delete-me']);
});

Deno.test('negotiateProtocol picks the newest mutually-supported version or refuses', () => {
  assert.equal(negotiateProtocol('1.2,1.1,1.0'), '1.2');
  assert.equal(negotiateProtocol('1.1,1.0'), '1.1');
  assert.equal(negotiateProtocol('1.0'), '1.0');
  assert.equal(negotiateProtocol(' 1.2 , 1.1 '), '1.2');
  assert.equal(negotiateProtocol('0.9'), null);
  assert.equal(negotiateProtocol(''), null);
  assert.equal(negotiateProtocol(undefined), null);
});

Deno.test('parseNdjsonEntity refuses a wrong-shape batch with the Node error codes', () => {
  assert.throws(
    () => parseNdjsonEntity(new TextEncoder().encode('')),
    (err: any) => err instanceof PushProtocolError && err.code === 'empty_ndjson' && err.status === 400,
  );
  assert.throws(
    () => parseNdjsonEntity(new TextEncoder().encode('not json\n')),
    (err: any) => err.code === 'malformed_batch_header',
  );
  assert.throws(
    () => parseNdjsonEntity(new TextEncoder().encode('{"type":"notBatch"}\n')),
    (err: any) => err.code === 'missing_batch_header',
  );
  assert.throws(
    () => parseNdjsonEntity(new TextEncoder().encode('{"type":"batch","recordCount":2}\n{"type":"record"}\n')),
    (err: any) => err.code === 'record_count_mismatch' && err.status === 422,
  );
  assert.throws(
    () => parseNdjsonEntity(new TextEncoder().encode('{"type":"batch","recordCount":1}\n{"type":"nope"}\n')),
    (err: any) => err.code === 'invalid_record_line',
  );
});

Deno.test('buildAck echoes the batch and ackMatchesBatch guards it', () => {
  const header = {
    protocolVersion: '1.1',
    batchId: 'b',
    stream: 'hrSample',
    deviceId: 'strap-1',
    endCursor: { rowId: 42 },
    recordCount: 3,
  };
  const ack = buildAck(header);
  assert.equal(ack.status, 'accepted');
  assert.equal(ack.acceptedRows, 3);
  assert.ok(ackMatchesBatch(ack, header));
  assert.ok(!ackMatchesBatch({ ...ack, acceptedRows: 4 }, header));
  assert.ok(!ackMatchesBatch({ ...ack, endCursor: null }, header));
});
