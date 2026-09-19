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
} from '../_shared/registry.ts';
import { OBJECT_LANE_STREAMS } from '../_shared/keys.ts';

const OBJECT_LANE_PATH = '/functions/v1/push/objects';

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
