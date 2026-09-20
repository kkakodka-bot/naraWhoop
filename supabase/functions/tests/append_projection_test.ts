import assert from 'node:assert/strict';
import { validateAppendProjectionRows } from '../_shared/appendProjection.ts';
import { APPEND_STREAM_PROJECTIONS, PushProtocolError } from '../_shared/registry.ts';

const owner = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const device = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

Deno.test('append conflict key validator covers every registered conflict column type', () => {
  const row = { user_id: owner, device_id: device, ts: 1700000000, rrMs: 1000, seq: 0,
    packetId: 'a'.repeat(64), receiptId: 'receipt:0', kind: 'event' };
  for (const projection of Object.values(APPEND_STREAM_PROJECTIONS)) {
    validateAppendProjectionRows([row], projection.onConflict);
  }
});

Deno.test('projected UUID and signed-zero aliases collide while distinct text keys remain distinct', () => {
  const row = { user_id: owner, device_id: device, ts: 0, kind: '01' };
  validateAppendProjectionRows([row, { ...row, kind: '1' }, { ...row, kind: '1,2' }], 'user_id,device_id,ts,kind');
  assert.throws(() => validateAppendProjectionRows([row,
    { ...row, user_id: owner.replaceAll('-', '').toUpperCase(), device_id: `{${device}}`, ts: -0 }],
  'user_id,device_id,ts,kind'),
  (error: unknown) => error instanceof PushProtocolError && error.code === 'duplicate_record_key');
});
