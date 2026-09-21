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
  assert.equal(row?.activity_class, null);
  assert.equal(row?.device_id, owner.deviceId);
  assert.equal(row?.user_id, owner.userId);
  for (const counter of [null, undefined, -1, 0.5, 'bad']) {
    assert.throws(() => projection.mapRow({ ...owner,
      record: { key: { ts: 100 }, data: { counter } } }), /invalid_scalar_record/);
  }
});

Deno.test('gravity motion proof never coerces missing malformed or out-of-range input to stillness', () => {
  const map = APPEND_STREAM_PROJECTIONS.gravitySample.mapRow;
  for (const dynAccel of [null, undefined, false, true, '', '0', NaN, Infinity, -0.1, 8.1]) {
    const row = map({ ...owner, record: { key: { ts: 100 }, data: {
      x: 0, y: 0, z: 1, dynAccel, motion_evidence_version: 'projected-dynamic-acceleration-g-1',
    } } });
    assert.notEqual(row, null);
    assert.equal(row!.dynAccel, null);
    assert.equal(row!.motion_evidence_version, null);
    assert.equal(row!.orientation_evidence_version, 'projected-gravity-g-1');
  }
  for (const dynAccel of [0, 0.01, 0.3, 8]) {
    const row = map({ ...owner, record: { key: { ts: 100 }, data: { x: 0, y: 0, z: 1, dynAccel } } });
    assert.equal(row?.dynAccel, dynAccel);
    assert.equal(row?.motion_evidence_version, 'projected-dynamic-acceleration-g-1');
    assert.equal(row?.orientation_evidence_version, 'projected-gravity-g-1');
  }
});

Deno.test('gravity timestamp and XYZ require actual finite numeric values', () => {
  const map = APPEND_STREAM_PROJECTIONS.gravitySample.mapRow;
  for (const bad of [null, undefined, false, true, '', '0', NaN, Infinity]) {
    for (const key of ['x', 'y', 'z']) {
      assert.equal(map({ ...owner, record: { key: { ts: 100 }, data: { x: 0, y: 0, z: 1, [key]: bad, dynAccel: 0 } } }), null);
    }
    assert.equal(map({ ...owner, record: { key: { ts: bad }, data: { x: 0, y: 0, z: 1, dynAccel: 0 } } }), null);
  }
  for (const ts of [100.5, Number.MAX_SAFE_INTEGER + 1]) {
    assert.equal(map({ ...owner, record: { key: { ts }, data: { x: 0, y: 0, z: 1, dynAccel: 0 } } }), null);
  }
  const orientationOnly = map({ ...owner, record: { key: { ts: 100 }, data: {
    x: 0, y: 0, z: 1, orientation_evidence_version: 'untrusted-upload-label',
  } } });
  assert.equal(orientationOnly?.orientation_evidence_version, 'projected-gravity-g-1');
  assert.equal(orientationOnly?.dynAccel, null);
  assert.equal(orientationOnly?.motion_evidence_version, null);
  assert.equal(map({ ...owner, record: { key: { ts: 100 }, data: {
    x: null, y: false, z: 1, dynAccel: 0, orientation_evidence_version: 'projected-gravity-g-1',
  } } }), null);
});
