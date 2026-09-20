import assert from 'node:assert/strict';
import { APPEND_STREAM_PROJECTIONS } from '../_shared/registry.ts';
import { windowCoverage } from '../_shared/objects.ts';

const owner = { userId: 'user-a', deviceId: 'device-a', sourceId: 'source-a', batchId: 'batch-a' };

Deno.test('multiple PPG records in a second do not establish time coverage', () => {
  const coverage = windowCoverage({ stream: 'ppgWaveformSample', startTs: 100, endTs: 400, sampleCount: 300 });
  assert.equal(coverage.receivedRecords, 300);
  assert.equal(coverage.coverage, null);
  assert.equal(coverage.expectedRecords, null);
});

Deno.test('RR projections preserve missing provenance as null', () => {
  const row = APPEND_STREAM_PROJECTIONS.rrInterval.mapRow({ ...owner,
    record: { key: { ts: 100, rrMs: 800, seq: 1 }, data: { ord: null, srcChannel: null, tsSuspect: null } },
  });
  assert.equal(row?.ord, null);
  assert.equal(row?.srcChannel, null);
  assert.equal(row?.tsSuspect, null);
  assert.equal(row?.seq, 1);
});

Deno.test('steps project observed counter and activity without manufacturing missing zero', () => {
  const projection = APPEND_STREAM_PROJECTIONS.stepSample;
  assert.equal(projection.table, 'noop_step_samples');
  const row = projection.mapRow({ ...owner,
    record: { key: { ts: 100 }, data: { counter: 0, activityClass: null } },
  });
  assert.equal(row?.counter, 0);
  assert.equal(row?.activityClass, null);
  assert.equal(row?.device_id, owner.deviceId);
  assert.equal(row?.user_id, owner.userId);
  for (const counter of [null, undefined, -1, 0.5, 'bad']) {
    assert.equal(projection.mapRow({ ...owner, record: { key: { ts: 100 }, data: { counter } } }), null);
  }
});
