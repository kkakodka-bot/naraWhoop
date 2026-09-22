// Closure versions of Mill's independent defect controls. All replies are synthetic;
// no SSH/Docker/SQL/build process or credential/configuration file is accessed.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { fixture } from './sync-evidence-fixtures.mjs';
import { candidateSelector, checkLive } from './check-sync-live.mjs';
import { migrationLedger, REQUIRED_MIGRATIONS } from './sync-evidence-contract.mjs';
import { canonicalMigrationLedger, SUPPORTED_LEDGER_BASENAMES } from './sync-migration-ledger.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const source = relative => fs.readFileSync(path.join(root, relative), 'utf8');
const filenames = REQUIRED_MIGRATIONS.map(id => SUPPORTED_LEDGER_BASENAMES.find(name => name.startsWith(id + '_')));
function replies(f, ledger = [...REQUIRED_MIGRATIONS]) {
  const c = f.evidence.canary;
  return [
    { workItems: true, heartbeats: true, ingest: true }, ledger,
    { containerId: f.evidence.server.containerId, running: true, imageId: f.evidence.server.dockerImageId,
      imageReference: f.imageFixture.release.image.reference,
      revision: f.evidence.server.commit, ports: {}, networkMode: 'synthetic-internal' },
    [`synthetic.invalid/scorer@${f.evidence.server.imageDigest}`],
    { lastPollAtMs: f.now - 20000, serverNowMs: f.now },
    { lastPollAtMs: f.now - 1000, serverNowMs: f.now },
    { ownerUserId: c.ownerUserId, deviceId: c.deviceId, inputRevision: c.inputRevision, resultRevision: c.resultRevision,
      day: c.day, algorithmVersion: c.algorithmVersion, objectId: c.objectId, recordDigest: c.recordDigest,
      receiptState: 'verified_indexed', receiptOwner: c.ownerUserId, receiptDevice: c.deviceId,
      receiptObject: c.objectId, indexedBeforeComputed: true },
    f.imageFixture.inspection,
  ];
}

test('control: native IDs and coherent replies pass only narrow read-only checks, preserving raw ledger', t => {
  const f = fixture(t), responses = replies(f), calls = [];
  const result = checkLive(f.evidence, f.directory, candidateSelector(f.evidence), (command, label) => {
    calls.push({ command, label }); return JSON.stringify(responses.shift());
  }, () => {}, () => f.now);
  assert.equal(result.status, 'READ_ONLY_CHECKS_PASSED');
  assert.match(result.productionReadiness, /^NOT_READY:/);
  assert.deepEqual(result.migrationLedger.observedRaw, REQUIRED_MIGRATIONS);
  assert.equal(calls.length, 8);
  assert.match(calls[1].command, /json_agg\(version order by version\)/);
  assert.match(calls[6].command, /s\.input_revision=1 and s\.result_revision=2/);
});

test('P1-1 closure: exact supported catalogue matches current migration-runner basename contract', () => {
  const runner = source('infra/vps/scripts/apply-migrations.sh');
  assert.ok(runner.includes('base=$(basename "$f")'));
  assert.ok(runner.includes("INSERT INTO supabase_migrations.schema_migrations (version) VALUES ('${base}')"));
  assert.deepEqual([...SUPPORTED_LEDGER_BASENAMES], fs.readdirSync(path.join(root, 'supabase/migrations')).filter(name => name.endsWith('.sql')).sort());
  assert.ok(SUPPORTED_LEDGER_BASENAMES.every(name => /^\d{14}_[a-z0-9_]+\.sql$/.test(name)));
  assert.equal(new Set(SUPPORTED_LEDGER_BASENAMES.map(name => name.slice(0, 14))).size, SUPPORTED_LEDGER_BASENAMES.length);
  assert.deepEqual(canonicalMigrationLedger(filenames), [...REQUIRED_MIGRATIONS]);
  assert.deepEqual(canonicalMigrationLedger([...REQUIRED_MIGRATIONS]), [...REQUIRED_MIGRATIONS]);
  // Evidence itself still takes IDs, not ledger basenames.
  assert.throws(() => migrationLedger(filenames), /distinct applied migration IDs/);
});

test('P1-1 closure: complete runner ledger reaches all checks and remains unchanged in evidence/result', t => {
  const f = fixture(t), raw = [...SUPPORTED_LEDGER_BASENAMES].reverse();
  f.evidence.server.migrationLedgerRaw = [...raw];
  f.evidence.server.migrations = canonicalMigrationLedger(raw);
  const responses = replies(f, raw), calls = [];
  const result = checkLive(f.evidence, f.directory, candidateSelector(f.evidence), (command, label) => {
    calls.push({ command, label }); return JSON.stringify(responses.shift());
  }, () => {}, () => f.now);
  assert.equal(result.status, 'READ_ONLY_CHECKS_PASSED'); assert.equal(calls.length, 8);
  assert.deepEqual(result.migrationLedger.observedRaw, raw);
  assert.deepEqual(result.migrationLedger.recordedRaw, raw);
  assert.deepEqual(result.migrationLedger.canonicalIDs, f.evidence.server.migrations);
  assert.deepEqual(f.evidence.server.migrationLedgerRaw, raw);
  // Raw representation need not be identical if the complete canonical set is unchanged.
  const native = replies(f, f.evidence.server.migrations);
  const second = checkLive(f.evidence, f.directory, candidateSelector(f.evidence), () => JSON.stringify(native.shift()), () => {}, () => f.now);
  assert.deepEqual(second.migrationLedger.observedRaw, f.evidence.server.migrations);
  assert.deepEqual(second.migrationLedger.recordedRaw, raw);
});

test('P1-2 closure: Compose-generated instance is inspected by the independently selected full ID', t => {
  const compose = source('infra/vps/templates/docker-compose.scoring-override.yml');
  assert.match(compose, /^  scoring:$/m); assert.doesNotMatch(compose, /^\s*container_name:/m);
  assert.match(source('infra/vps/scripts/deploy-scoring-service.sh'), /docker-compose\.scoring\.yml up -d scoring/);
  const f = fixture(t), responses = replies(f), calls = [];
  const instances = new Map([[f.evidence.server.containerId, { name: 'synthetic-scoring-1' }],
    ['d'.repeat(64), { name: 'scoring' }]]);
  const result = checkLive(f.evidence, f.directory, candidateSelector(f.evidence), (command, label) => {
    calls.push({ command, label });
    if (label === 'scorer inspection') {
      const id = /'([0-9a-f]{64})'$/.exec(command)?.[1];
      assert.equal(instances.get(id)?.name, 'synthetic-scoring-1');
      assert.ok(command.includes('{{json .Id}}'));
      assert.doesNotMatch(command, / scoring$|docker ps|rename/);
    }
    return JSON.stringify(responses.shift());
  }, () => {}, () => f.now);
  assert.equal(result.containerId, f.evidence.server.containerId); assert.equal(calls.length, 8);
});

test('control: each required omission in either format and canonical duplicates remain NOT_READY', () => {
  for (const raw of [[...REQUIRED_MIGRATIONS], filenames]) {
    for (let missing = 0; missing < raw.length; missing++) {
      assert.throws(() => canonicalMigrationLedger(raw.filter((_, index) => index !== missing)), /migration missing/);
    }
    assert.throws(() => canonicalMigrationLedger([...raw, raw[0]]), /distinct/);
  }
  assert.throws(() => canonicalMigrationLedger([...filenames, REQUIRED_MIGRATIONS[0]]), /distinct/);
  assert.throws(() => canonicalMigrationLedger([...REQUIRED_MIGRATIONS, filenames[0]]), /distinct/);
  const mixed = REQUIRED_MIGRATIONS.map((id, index) => index % 2 ? filenames[index] : id);
  assert.deepEqual(canonicalMigrationLedger(mixed), [...REQUIRED_MIGRATIONS]);
});

test('adapter rejects malformed/unknown basenames instead of truncating arbitrary strings', () => {
  const id = REQUIRED_MIGRATIONS[0], name = filenames[0];
  for (const invalid of [null, Number(id), true, '', id + '0', id.slice(1), id + '\n', ' ' + id,
    name + '\n', name + '.bak', name.replace('.sql', '.SQL'), '../' + name, '/tmp/' + name,
    id + '_arbitrary.sql', name.replace('_production_', '_wrong_'), '20260101000000_unknown.sql']) {
    assert.throws(() => canonicalMigrationLedger([invalid, ...REQUIRED_MIGRATIONS.slice(1)]), /NOT_READY/);
  }
  for (const invalid of [null, {}, REQUIRED_MIGRATIONS.join(',')]) assert.throws(() => canonicalMigrationLedger(invalid), /array/);
});

test('full canonical set comparison includes extra IDs, not just the required eight', t => {
  const f = fixture(t), extra = SUPPORTED_LEDGER_BASENAMES[0];
  let responses = replies(f, [...filenames, extra]);
  assert.throws(() => checkLive(f.evidence, f.directory, candidateSelector(f.evidence), () => JSON.stringify(responses.shift()), () => {}, () => f.now), /live migration ledger differs/);
  f.evidence.server.migrations.push(extra.slice(0, 14)); f.evidence.server.migrationLedgerRaw.push(extra);
  responses = replies(f, filenames);
  assert.throws(() => checkLive(f.evidence, f.directory, candidateSelector(f.evidence), () => JSON.stringify(responses.shift()), () => {}, () => f.now), /live migration ledger differs/);
});

test('selected-ID mismatch stops before reads; returned-ID mismatch stops before image inspection', t => {
  const f = fixture(t), selector = candidateSelector(f.evidence); selector.containerId = 'd'.repeat(64);
  assert.throws(() => checkLive(f.evidence, f.directory, selector, () => assert.fail('no remote reads permitted'), () => {}, () => f.now), /operator target differs/);
  const responses = replies(f); responses[2].containerId = 'd'.repeat(64); let calls = 0;
  assert.throws(() => checkLive(f.evidence, f.directory, candidateSelector(f.evidence), () => {
    calls++; return JSON.stringify(responses.shift());
  }, () => {}, () => f.now), /container ID differs/);
  assert.equal(calls, 3);
});

test('control: snapshot/receipt SQL still agrees with checked-in declarations and publication', t => {
  const snapshots = source('supabase/migrations/20260918010000_production_scoring_durability.sql');
  const receipt = source('supabase/migrations/20260918020000_production_intake_durability.sql');
  assert.match(snapshots, /create table public\.scoring_snapshots_v2/);
  for (const column of ['result_revision', 'user_id', 'device_id', 'day', 'algorithm_version', 'input_revision', 'computed_at']) {
    assert.match(snapshots.slice(snapshots.indexOf('create table public.scoring_snapshots_v2'), snapshots.indexOf('create index scoring_snapshot_read_v2')), new RegExp(`\\b${column}\\b`));
  }
  for (const key of ['ownerUserId', 'deviceId', 'objectId', 'contentSha256', 'verified_indexed']) assert.ok(receipt.includes(`'${key}'`));
  assert.match(receipt, /sha256_source='server_verified'/);
  assert.match(receipt, /status='ready', verified_at=.*indexed_at=v_now/);
  const f = fixture(t), responses = replies(f);
  assert.equal(checkLive(f.evidence, f.directory, candidateSelector(f.evidence), () => JSON.stringify(responses.shift()), () => {}, () => f.now).status, 'READ_ONLY_CHECKS_PASSED');
});
