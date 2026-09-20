import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { verifyEvidence } from './verify-sync-evidence.mjs';
import { fixture } from './sync-evidence-fixtures.mjs';
import { SUPPORTED_LEDGER_BASENAMES } from './sync-migration-ledger.mjs';

test('validates internally consistent test evidence without calling it production-ready', t => {
  const f = fixture(t);
  assert.equal(verifyEvidence(f.evidence, f.directory, f.now).status, 'EVIDENCE_VALIDATED');
});
test('missing or skipped required gate fails', t => {
  const f = fixture(t);
  f.evidence.scenarios.overnightThroughWake.status = 'skipped';
  assert.throws(() => verifyEvidence(f.evidence, f.directory, f.now), /overnightThroughWake/);
});
test('every production-sync migration is required, including history and input-selection repairs', t => {
  const f = fixture(t);
  const applied = [...f.evidence.server.migrations];
  for (const missing of applied) {
    f.evidence.server.migrations = applied.filter(value => value !== missing);
    assert.throws(() => verifyEvidence(f.evidence, f.directory, f.now), new RegExp(`migration missing: ${missing}`));
  }
});
test('migration evidence cannot be a substring, number list or duplicate ledger', t => {
  const f = fixture(t);
  const applied = [...f.evidence.server.migrations];
  for (const malformed of [applied.join(','), applied.map(Number), [...applied, applied[0]], null]) {
    f.evidence.server.migrations = malformed;
    assert.throws(() => verifyEvidence(f.evidence, f.directory, f.now), /distinct applied migration IDs/);
  }
});
test('schema2 records raw ledger entries separately and rejects inconsistent canonical evidence', t => {
  const f = fixture(t), ids = [...f.evidence.server.migrations];
  const names = ids.map(id => SUPPORTED_LEDGER_BASENAMES.find(name => name.startsWith(id + '_')));
  f.evidence.server.migrationLedgerRaw = [...names];
  assert.equal(verifyEvidence(f.evidence, f.directory, f.now).status, 'EVIDENCE_VALIDATED');
  assert.deepEqual(f.evidence.server.migrationLedgerRaw, names); // No in-place normalization.
  for (const raw of [undefined, null, names.join(','), [...names, ids[0]], [...names, '20260801000000']]) {
    f.evidence.server.migrationLedgerRaw = raw;
    assert.throws(() => verifyEvidence(f.evidence, f.directory, f.now), /NOT_READY/);
  }
  f.evidence.server.migrationLedgerRaw = names;
  f.evidence.server.migrations = names;
  assert.throws(() => verifyEvidence(f.evidence, f.directory, f.now), /distinct applied migration IDs/);
});
test('container ID is explicit full lowercase hex, not a service name, short ID or image digest', t => {
  const f = fixture(t);
  for (const id of [undefined, null, '', 'scoring', 'synthetic-scoring-1', 'c'.repeat(12), 'C'.repeat(64),
    'sha256:' + 'c'.repeat(64), 'c'.repeat(63), 'c'.repeat(65), 'c'.repeat(64) + '\n', true]) {
    f.evidence.server.containerId = id;
    assert.throws(() => verifyEvidence(f.evidence, f.directory, f.now), /container ID/);
  }
});
test('existing but stalled heartbeat fails', t => {
  const f = fixture(t);
  f.evidence.server.heartbeats[1] = f.evidence.server.heartbeats[0];
  assert.throws(() => verifyEvidence(f.evidence, f.directory, f.now), /heartbeat must advance/);
});
test('other account result and older displayed revision fail', t => {
  const f = fixture(t);
  f.evidence.canary.stages.displayed.ownerNamespace = 'b'.repeat(64);
  assert.throws(() => verifyEvidence(f.evidence, f.directory, f.now), /correlation/);
  f.evidence.canary.stages.displayed.ownerNamespace = f.evidence.canary.ownerNamespace;
  f.evidence.canary.displayedRevision = 1;
  assert.throws(() => verifyEvidence(f.evidence, f.directory, f.now), /displayed result/);
});
test('wrong metric or missing physical trace cannot pass performance', t => {
  const f = fixture(t);
  f.evidence.performance[1].metric = 'fixed33msCounter';
  assert.throws(() => verifyEvidence(f.evidence, f.directory, f.now), /Hitches/);
});
test('changed artifact bytes fail verification', t => {
  const f = fixture(t);
  fs.writeFileSync(path.join(f.directory, 'synthetic.txt'), 'different fixture');
  assert.throws(() => verifyEvidence(f.evidence, f.directory, f.now), /digest mismatch/);
});
test('empty evidence and a missing manifest reference fail', t => {
  const f = fixture(t);
  assert.throws(() => verifyEvidence({}, f.directory, f.now), /schemaVersion/);
  f.evidence.canary.stages.displayed.artifact = 'missing.trace';
  assert.throws(() => verifyEvidence(f.evidence, f.directory, f.now), /no verified artifact/);
});

for (const prepend of [false, true]) {
  test(`all performance traces are checked, bad duplicate first=${prepend}`, t => {
    const f = fixture(t);
    const bad = { ...f.evidence.performance[1], value: 100, unresolvedMainThreadStalls250ms: 7 };
    f.evidence.performance[prepend ? 'unshift' : 'push'](bad);
    assert.throws(() => verifyEvidence(f.evidence, f.directory, f.now), /Hitches/);
  });
}
test('every additional trace needs physical build, time, metric, denominator and stall checks', t => {
  const f = fixture(t);
  for (const [field, value] of Object.entries({ actualRefreshHz: '120', physicalDevice: false, configuration: 'Debug',
    value: -1, unresolvedMainThreadStalls250ms: 1, toolVersion: '', denominator: '', buildCommit: 'b'.repeat(40), observedAt: '2020-01-01T00:00:00.000Z' })) {
    const e = structuredClone(f.evidence);
    e.performance.push({ ...e.performance[1], [field]: value });
    assert.throws(() => verifyEvidence(e, f.directory, f.now), /NOT_READY/, field);
  }
  f.evidence.performance.push({ ...f.evidence.performance[0], actualRefreshHz: 90 });
  assert.equal(verifyEvidence(f.evidence, f.directory, f.now).status, 'EVIDENCE_VALIDATED');
});
test('all intermediate heartbeats are valid, strictly advancing and inside the window', t => {
  const f = fixture(t);
  for (const middle of ['invalid', new Date(f.now - 30000).toISOString(), f.evidence.server.heartbeats[0],
    new Date(f.now + 1).toISOString(), new Date(f.now - 366 * 86400_000).toISOString(), 123]) {
    f.evidence.server.heartbeats = [new Date(f.now - 20000).toISOString(), middle, new Date(f.now - 1000).toISOString()];
    assert.throws(() => verifyEvidence(f.evidence, f.directory, f.now), /heartbeat/);
  }
});
test('fresh heartbeat cannot admit old canary completion', t => {
  const f = fixture(t);
  for (const age of [366 * 86400_000, 3600_000]) {
    for (const stage of Object.values(f.evidence.canary.stages)) stage.at = new Date(f.now - age).toISOString();
    assert.throws(() => verifyEvidence(f.evidence, f.directory, f.now), /window|stale/);
  }
});
test('72-hour collection and old physiology day are permitted, recent completion required', t => {
  const f = fixture(t);
  f.evidence.canary.stages.committed.at = new Date(f.now - 3 * 86400_000).toISOString();
  f.evidence.canary.day = '2020-01-01';
  assert.equal(verifyEvidence(f.evidence, f.directory, f.now).status, 'EVIDENCE_VALIDATED');
});
test('collection window rejects reversed, unbounded, stale and future intervals', t => {
  const f = fixture(t);
  for (const [start, end] of [[-1, -2], [-8 * 86400_000, -1000], [-86400_000, -3600_000], [-86400_000, 61000]]) {
    f.evidence.collection = { startedAt: new Date(f.now + start).toISOString(), completedAt: new Date(f.now + end).toISOString() };
    assert.throws(() => verifyEvidence(f.evidence, f.directory, f.now), /collection window/);
  }
});
test('canonical timestamps reject rolled-over calendar dates and numeric values', t => {
  const f = fixture(t);
  for (const timestamp of ['2026-02-30T00:00:00.000Z', '2026-09-18', 0, null]) {
    f.evidence.collection.startedAt = timestamp;
    assert.throws(() => verifyEvidence(f.evidence, f.directory, f.now), /collection window/);
  }
});
test('explicit canary identity/revisions must match at every stage', t => {
  const f = fixture(t);
  for (const stage of Object.keys(f.evidence.canary.stages)) {
    for (const field of ['ownerUserId', 'deviceId', 'objectId', 'inputRevision', 'resultRevision']) {
      const e = structuredClone(f.evidence);
      e.canary.stages[stage][field] = 'mismatch';
      assert.throws(() => verifyEvidence(e, f.directory, f.now), /correlation/);
    }
  }
});
test('UUID, digest scope, algorithm and numeric revisions cannot be coerced', t => {
  const f = fixture(t);
  for (const [field, value] of [['ownerUserId', '-'.repeat(36)], ['deviceId', 'not-a-uuid'], ['objectId', null],
    ['recordDigestScope', 'unspecified'], ['algorithmVersion', "bad'algorithm"], ['day', '2026-02-30'],
    ...[true, '1', 0, -1, 1.5, Number.MAX_SAFE_INTEGER + 1].map(v => ['inputRevision', v])]) {
    const e = structuredClone(f.evidence);
    e.canary[field] = value;
    for (const stage of Object.values(e.canary.stages)) if (field in stage) stage[field] = value;
    assert.throws(() => verifyEvidence(e, f.directory, f.now), /NOT_READY/, field);
  }
});
test('all time-bearing reports are inside the collection window', t => {
  const f = fixture(t);
  for (const report of [f.evidence.energy, f.evidence.security, f.evidence.latency, ...Object.values(f.evidence.scenarios)]) {
    const at = report.observedAt;
    report.observedAt = '2020-01-01T00:00:00.000Z';
    assert.throws(() => verifyEvidence(f.evidence, f.directory, f.now), /window/);
    report.observedAt = at;
  }
});
test('target and HTTPS origin reject credentials, paths, shell/SSH syntax', t => {
  const f = fixture(t);
  for (const endpoint of ['http://fixture.invalid', 'https://u:p@fixture.invalid', 'https://fixture.invalid/a', 'https://fixture.invalid?q=x']) {
    assert.throws(() => verifyEvidence({ ...f.evidence, endpoint }, f.directory, f.now), /HTTPS/);
  }
  for (const host of ['-oProxyCommand=x', 'u@host', 'host;date', 'host\nother', 'host:22']) {
    const e = structuredClone(f.evidence); e.target.sshHost = host;
    assert.throws(() => verifyEvidence(e, f.directory, f.now), /SSH host/);
  }
});
test('artifacts reject duplicate names, directories and escape through a synthetic symlink', t => {
  const f = fixture(t);
  f.evidence.artifacts.push({ ...f.evidence.artifacts[0] });
  assert.throws(() => verifyEvidence(f.evidence, f.directory, f.now), /duplicate/);
  f.evidence.artifacts.pop();
  const sibling = fixture(t);
  fs.symlinkSync(path.join(sibling.directory, 'synthetic.txt'), path.join(f.directory, 'outside.txt'));
  f.evidence.artifacts[0].path = 'outside.txt';
  assert.throws(() => verifyEvidence(f.evidence, f.directory, f.now), /escaped/);
});
