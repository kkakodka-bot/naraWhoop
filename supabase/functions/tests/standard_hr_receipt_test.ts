import assert from 'node:assert/strict';
import { APPEND_STREAM_PROJECTIONS, advertisedStreams, recordTimestamp } from '../_shared/registry.ts';

const sessionId = '00000000-0000-4000-8000-000000000001';
const record = { key: { receiptId: `${sessionId}:0` }, data: {
  ts: 1700000000, sessionId, notificationOrdinal: 0, receivedUnixMs: 1700000000123,
  receivedMonotonicNs: '9007199254740993', rawHex: '103c0004', schemaVersion: 1, clockVersion: 'host-arrival-unmapped',
  verifiedSpan: { start: 1700000000, end: 1700000300 },
} };
const context = { userId: 'u', deviceId: 'd', sourceId: 's', batchId: 'b', record };
const projection = APPEND_STREAM_PROJECTIONS.standardHRReceipt;

Deno.test('standard HR receipt projection retains identity and clocks without timing promotion', () => {
  assert.ok(advertisedStreams('1.1').includes('standardHRReceipt'));
  assert.ok(!advertisedStreams('1.0').includes('standardHRReceipt'));
  const row = projection.mapRow(context)!;
  assert.equal(row.receivedMonotonicNs, '9007199254740993');
  assert.equal(row.rawHex, record.data.rawHex);
  assert.equal(row.verifiedSpan, undefined);
  assert.equal(recordTimestamp('standardHRReceipt', record), record.data.ts);
  const second = projection.mapRow({ ...context, record: { key: { receiptId: `${sessionId}:1` }, data: { ...record.data, notificationOrdinal: 1 } } })!;
  assert.notEqual(row.receiptId, second.receiptId);
  assert.equal(row.ts, second.ts);
});

Deno.test('standard HR receipt rejects corrupt identity or imprecise clocks', () => {
  for (const patch of [
    { receivedMonotonicNs: 9007199254740992 }, { receivedMonotonicNs: '9223372036854775808' },
    { receivedMonotonicNs: '-1' }, { receivedMonotonicNs: '00' }, { notificationOrdinal: 1 },
    { notificationOrdinal: -1 }, { receivedUnixMs: null }, { ts: 1700000001 },
    { rawHex: '123' }, { rawHex: 'xx' }, { rawHex: '' }, { rawHex: 'ff'.repeat(513) },
    { schemaVersion: 2 }, { clockVersion: 'verified' }, { sessionId: 'not-a-session' },
  ]) {
    assert.equal(projection.mapRow({ ...context, record: { ...record, data: { ...record.data, ...patch } } }), null, JSON.stringify(patch));
  }
});
