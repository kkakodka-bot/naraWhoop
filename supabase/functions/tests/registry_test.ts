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
  PushProtocolError,
  APPEND_STREAM_PROJECTIONS,
} from '../_shared/registry.ts';
import { OBJECT_LANE_STREAMS } from '../_shared/keys.ts';

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
    objectLane: lane,
  });
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

Deno.test('negotiateProtocol picks the newest mutually-supported version or refuses', () => {
  assert.equal(negotiateProtocol('1.3,1.2,1.1,1.0'), '1.3');
  const caps = capabilitiesBody({ receiverStateId: 'r', protocolVersion: '1.3', streams: advertisedStreams('1.3'),
    objectLane: { endpoint: OBJECT_LANE_PATH, maxObjectBytes: 1024, urlTtlSec: 900 } });
  assert(caps.objectLane.streams.includes('ppgWaveformSample'));
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
    endCursor: { rowId: 42, ts: 100, nested: { a: 1, b: [2, 3] } },
    recordCount: 3,
  };
  const ack = buildAck(header);
  assert.equal(ack.status, 'accepted');
  assert.equal(ack.acceptedRows, 3);
  assert.ok(ackMatchesBatch(ack, header));
  assert.ok(!ackMatchesBatch({ ...ack, acceptedRows: 4 }, header));
  assert.ok(!ackMatchesBatch({ ...ack, endCursor: null }, header));
  assert.ok(ackMatchesBatch({ ...ack, endCursor: { nested: { b: [2, 3], a: 1 }, ts: 100, rowId: 42 } }, header));
  assert.ok(!ackMatchesBatch({ ...ack, endCursor: { ...header.endCursor, rowId: '42' } }, header));
  assert.ok(!ackMatchesBatch({ ...ack, endCursor: { ...header.endCursor, nested: { a: 1, b: [3, 2] } } }, header));
});
