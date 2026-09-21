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
import { MIGRATION_CATALOG, verifyMigrationSources } from './scoring-migration-catalog.mjs';
import { migrationPlan } from './scoring-migration-plan.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const source = relative => fs.readFileSync(path.join(root, relative), 'utf8');
const filenames = [...REQUIRED_MIGRATIONS];
const appliedRows = () => MIGRATION_CATALOG.map(({basename,sha256}) => ({version:basename,sha256})).sort((a,b)=>a.version.localeCompare(b.version));
function replies(f, ledger = appliedRows()) {
  const c = f.evidence.canary;
  return [
    { workItems: true, heartbeats: true, ingest: true, sourceLedger: false }, ledger,
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
  assert.deepEqual(result.migrationLedger.observedRaw, appliedRows());
  assert.equal(calls.length, 8);
  assert.match(calls[1].command, /source_sha256/);
  assert.match(calls[1].command, /read-scoring-query.sh/);
  assert.doesNotMatch(calls[1].command, /supabase-db/);
  assert.match(calls[6].command, /s\.input_revision=1 and s\.result_revision=2/);
});

test('P1-1 closure: complete source hashes and full basenames preserve both collision streams', () => {
  const runner = source('infra/vps/scripts/apply-migrations.sh');
  assert.ok(runner.includes('base=$(basename "$f")'));
  assert.ok(runner.includes("INSERT INTO supabase_migrations.schema_migrations (version,source_sha256) VALUES ('${base}','${source_sha}')"));
  assert.match(runner, /scoring_execution_receipts/);
  assert.ok(runner.indexOf('scoring-migration-plan.mjs" "$MIG_DIR"') < runner.indexOf('CREATE SCHEMA IF NOT EXISTS'));
  assert.match(runner, /StrictHostKeyChecking=yes/);
  assert.doesNotMatch(runner, /StrictHostKeyChecking=accept-new/);
  assert.deepEqual([...SUPPORTED_LEDGER_BASENAMES], fs.readdirSync(path.join(root, 'supabase/migrations')).filter(name => name.endsWith('.sql')).sort());
  assert.ok(SUPPORTED_LEDGER_BASENAMES.every(name => /^\d{14}_[a-z0-9_]+\.sql$/.test(name)));
  assert.equal(SUPPORTED_LEDGER_BASENAMES.length - new Set(SUPPORTED_LEDGER_BASENAMES.map(name => name.slice(0, 14))).size, 6);
  assert.equal(verifyMigrationSources(path.join(root, 'supabase/migrations')), filenames.length);
  assert.deepEqual(canonicalMigrationLedger(filenames), [...REQUIRED_MIGRATIONS]);
  assert.deepEqual(canonicalMigrationLedger(MIGRATION_CATALOG.map(({basename,sha256}) => ({version:basename,sha256}))), [...REQUIRED_MIGRATIONS]);
  assert.throws(() => canonicalMigrationLedger(filenames.map(name => name.slice(0, 14))), /ambiguous/);
  migrationLedger(filenames);
});

test('reviewed source-identity ledgers use the same full-name/hash validation as runtime preflight', t => {
  const f = fixture(t), responses = replies(f), calls = [];
  responses[0].sourceLedger = true;
  responses[1] = {applied: [], attestations: appliedRows()};
  const result = checkLive(f.evidence, f.directory, candidateSelector(f.evidence), (command, label) => {
    calls.push({command,label}); return JSON.stringify(responses.shift());
  }, () => {}, () => f.now);
  assert.equal(result.status, 'READ_ONLY_CHECKS_PASSED');
  assert.match(calls[1].command, /supabase_migrations.scoring_source_identities/);
  assert.match(calls[1].command, /from supabase_migrations.schema_migrations/);
  assert.deepEqual(result.migrationLedger.observedRaw, []);
  assert.deepEqual(result.migrationLedger.observedSourceAttestations, appliedRows());
  for (const ledger of [
    {applied: [],attestations: appliedRows().slice(1)},
    {applied: [],attestations: appliedRows().map(row => ({...row,sha256:'0'.repeat(64)}))},
    {applied: [{version:'20260922000000_unknown.sql'}],attestations: appliedRows()},
    {applied: [{...appliedRows()[0],name:'contradictory_name'}],attestations: appliedRows()},
    {applied: [{...appliedRows()[0],exportHash:'0'.repeat(64)}],attestations: appliedRows()},
  ]) {
    const invalid = replies(f, ledger); invalid[0].sourceLedger = true;
    assert.throws(() => checkLive(f.evidence, f.directory, candidateSelector(f.evidence),
      () => JSON.stringify(invalid.shift()), () => {}, () => f.now), /NOT_READY/);
  }
});

test('P1-1 closure: complete runner ledger reaches all checks and remains unchanged in evidence/result', t => {
  const f = fixture(t), raw = appliedRows().reverse();
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
  const nativeRows = raw.map(row => ({version:row.version.slice(0,14),name:row.version.slice(15,-4),sha256:row.sha256}));
  const native = replies(f, nativeRows);
  const second = checkLive(f.evidence, f.directory, candidateSelector(f.evidence), () => JSON.stringify(native.shift()), () => {}, () => f.now);
  assert.deepEqual(second.migrationLedger.observedRaw, nativeRows);
  assert.deepEqual(second.migrationLedger.recordedRaw, raw);
});

test('P1-2 closure: versioned Compose instance is inspected by the independently selected full ID', t => {
  const compose = source('infra/vps/templates/docker-compose.scoring-override.yml');
  assert.match(compose, /^  scoring-physiology-v2:$/m);
  assert.match(compose, /SCORING_ALGORITHM_VERSION: frwhoop-physiology-2/);
  assert.match(source('infra/vps/scripts/deploy-scoring-service.sh'), /--name "\$SCORING_SERVICE" "\$SCORING_SERVICE"/);
  assert.match(compose, /SCORING_ALGORITHM_VERSION: frwhoop-server-1/);
  assert.match(compose, /command: \["--history"\]/);
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
  const mixed = REQUIRED_MIGRATIONS.map((id, index) => index % 2 ? {version:id.slice(0,14),name:id.slice(15,-4)} : id);
  assert.deepEqual(canonicalMigrationLedger(mixed), [...REQUIRED_MIGRATIONS]);
});

test('adapter rejects malformed/unknown basenames instead of truncating arbitrary strings', () => {
  const name = filenames[0], id = name.slice(0,14);
  for (const invalid of [null, Number(id), true, '', id + '0', id.slice(1), id + '\n', ' ' + id,
    name + '\n', name + '.bak', name.replace('.sql', '.SQL'), '../' + name, '/tmp/' + name,
    id + '_arbitrary.sql', name.replace('_frwhoop_', '_wrong_'), '20260101000000_unknown.sql']) {
    assert.throws(() => canonicalMigrationLedger([invalid, ...REQUIRED_MIGRATIONS.slice(1)]), /NOT_READY/);
  }
  for (const invalid of [null, {}, REQUIRED_MIGRATIONS.join(',')]) assert.throws(() => canonicalMigrationLedger(invalid), /array/);
});

test('full set validation rejects unknown live history, duplicate identities and hash drift', t => {
  const f = fixture(t);
  for (const raw of [[...filenames, '20260922000000_unknown.sql'], [...filenames, filenames[0]],
    filenames.map((name,index) => index ? name : {version:name,sha256:'0'.repeat(64)})]) {
    const responses = replies(f, raw);
    assert.throws(() => checkLive(f.evidence, f.directory, candidateSelector(f.evidence), () => JSON.stringify(responses.shift()), () => {}, () => f.now), /NOT_READY/);
  }
});

test('fresh plan orders the intake repair before its projection dependency without renaming it', () => {
  const plan = migrationPlan([]);
  const names = plan.pending.map(row => row.basename);
  assert.equal(plan.status, 'PLAN_REVIEWABLE');
  assert.ok(names.indexOf('20260921060000_production_intake_durability.sql') < names.indexOf('20260918040000_production_projection_debt.sql'));
  assert.equal(plan.mutationPerformed, false);
});

test('upgrade plans need applied hash evidence and never replay applied repair identities', () => {
  const rows = MIGRATION_CATALOG.map(({basename,sha256}) => ({version:basename,sha256}));
  assert.equal(migrationPlan(rows).pending.length, 0);
  assert.throws(() => migrationPlan(filenames), /hash not attested/);
  assert.equal(migrationPlan(filenames, rows).pending.length, 0);
  assert.equal(migrationPlan(rows.slice(1)).status, 'REVIEW_REQUIRED');
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
  const receipt = source('supabase/migrations/20260921060000_production_intake_durability.sql');
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
