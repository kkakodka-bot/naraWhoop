import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import { canonicalJSON, sha256Hex } from './generate-migration-manifest.mjs';
import {
  CREDENTIAL_ENVIRONMENT,
  EXPECTED_DATABASE_SCHEMA_FINGERPRINT,
  HOSTED_PROJECT_REF,
  LEDGER_STATEMENT_TIMEOUT_SECONDS,
  MIGRATION_STATEMENT_TIMEOUT_SECONDS,
  PENDING_IDENTITIES,
  POSTVERIFY_STATEMENT_TIMEOUT_SECONDS,
  PSQL_CONNECT_TIMEOUT_SECONDS,
  PSQL_QUERY_TIMEOUT_MILLISECONDS,
  applyHostedMigrationPlan,
  connectionFromEnvironment,
  createHostedMigrationPlan,
  createPsqlRunner,
  createTargetBinding,
  inspectPsqlExecutable,
  migrationApplySQL,
  verifyHostedMigrationResult,
  verifyMigrationManifest,
  verifyTargetBinding,
} from './hosted-migration-release.mjs';

const sourceRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const catalogRelative = 'scoring-service/service/src/main/resources/scoring-migration-catalog.json';
const migrationRelative = 'supabase/migrations';
const verifierRelative = 'Tools/release/verify-integrated-schema.sql';

function git(repo, args) {
  const result = spawnSync('git', ['-C', repo, ...args], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}

function shellLiteral(value) {
  assert.equal(String(value).includes("'"), false, 'test shell fixture value contains an apostrophe');
  return `'${String(value)}'`;
}

function writeExecutable(filename, content) {
  fs.writeFileSync(filename, content, { mode: 0o700 });
  return fs.realpathSync(filename);
}

function fixture() {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'frwhoop-hosted-migration-'));
  const repo = path.join(directory, 'repo');
  const catalogPath = path.join(repo, catalogRelative);
  const migrations = path.join(repo, migrationRelative);
  const verifier = path.join(repo, verifierRelative);
  fs.mkdirSync(path.dirname(catalogPath), { recursive: true });
  fs.mkdirSync(path.dirname(verifier), { recursive: true });
  fs.copyFileSync(path.join(sourceRoot, catalogRelative), catalogPath);
  fs.cpSync(path.join(sourceRoot, migrationRelative), migrations, { recursive: true });
  fs.copyFileSync(path.join(sourceRoot, verifierRelative), verifier);
  git(repo, ['init', '--quiet']);
  git(repo, ['config', 'user.name', 'Hosted Migration Test']);
  git(repo, ['config', 'user.email', 'hosted-migration@example.invalid']);
  git(repo, ['add', '.']);
  git(repo, ['commit', '--quiet', '-m', 'fixture']);
  const candidateSha = git(repo, ['rev-parse', 'HEAD']);
  const candidateTree = git(repo, ['rev-parse', 'HEAD^{tree}']);
  const catalog = JSON.parse(fs.readFileSync(catalogPath, 'utf8'));
  const entries = catalog.map((row, index) => ({
    ordinal: index + 1,
    filename: row.basename,
    stableIdentity: row.basename,
    timestamp: row.basename.slice(0, 14),
    sha256: row.sha256,
    sizeBytes: fs.statSync(path.join(migrations, row.basename)).size,
    sourceWorkstream: index < 117 ? 'server-pipeline' :
      (index < 121 ? 'multiuser-scale' : index === 121 ? 'sensor-algorithms' : 'vps-only-compute'),
    sourceBranch: 'synthetic-test-branch',
    sourceTip: '1'.repeat(40),
    dependencies: index === 0 ? [] : [catalog[index - 1].basename],
    collisionRenameState: { state: 'unique' },
    hostedStatus: index < 117 ? 'applied' : 'pending',
    hostedIdentityState: index < 117 ? { state: 'active', reason: 'test baseline' } :
      { state: 'not_applied', reason: 'test pending' },
    freshInstallBehavior: { action: 'apply_exact_source_once', applyOrdinal: index + 1, verifySha256: true },
    upgradeBehavior: index < 117 ? { action: 'preserve_applied_identity', execute: false, reason: 'test' } :
      { action: 'apply_exact_source_once', execute: true, upgradeOrdinal: index - 116, reason: 'test' },
  }));
  const unsignedManifest = {
    schemaVersion: 1,
    kind: 'frwhoop-immutable-migration-manifest',
    candidate: { branch: 'release/integration', sha: candidateSha, tree: candidateTree },
    sourceWorkstreams: [],
    hostedBaseline: {
      environment: 'hosted-production',
      projectRef: HOSTED_PROJECT_REF,
      capturedAt: '2026-09-22T01:02:03Z',
      nativeLedgerRows: 110,
      fullIdentityRows: 117,
      highestKnownIdentity: entries[116].stableIdentity,
      evidenceArtifacts: [],
    },
    catalog: {
      path: catalogRelative,
      migrationDirectory: migrationRelative,
      entryCount: 124,
      baselineEntryCount: 117,
      pendingEntryCount: 7,
    },
    counts: { total: 124, applied: 117, pending: 7 },
    schemaFingerprintSha256: '910a1c74a760b496028d7c2c58c009f45e29f9643fd2c279c278156f9a23d4c5',
    entries,
  };
  const manifest = { ...unsignedManifest, manifestFingerprintSha256: sha256Hex(canonicalJSON(unsignedManifest)) };
  const binding = createTargetBinding({
    projectRef: HOSTED_PROJECT_REF,
    host: `db.${HOSTED_PROJECT_REF}.supabase.co`,
    port: 5432,
    database: 'postgres',
    user: 'postgres',
    expectedCurrentUser: 'postgres',
  });
  const psqlFixturePath = path.join(directory, 'reviewed-psql');
  fs.writeFileSync(psqlFixturePath, '#!/bin/sh\nprintf \'psql (PostgreSQL) 18.3 test\\n\'\n', { mode: 0o700 });
  const psqlPath = fs.realpathSync(psqlFixturePath);
  const databaseClient = inspectPsqlExecutable(psqlPath);
  const evidenceDir = path.join(directory, 'evidence');
  return {
    directory, repo, migrations, catalog, manifest, binding, psqlPath, databaseClient, evidenceDir,
    cleanup: () => fs.rmSync(directory, { recursive: true, force: true }),
  };
}

function nativeLedger() {
  return Array.from({ length: 110 }, (_, index) => ({
    version: String(20260000000000 + index),
    name: `historical_${index}`,
  }));
}

function rawSnapshot(manifest, pendingPrefix = 0, overrides = {}) {
  return {
    serverTime: '2026-09-22T12:00:00Z',
    database: 'postgres',
    currentUser: 'postgres',
    serverAddress: '10.0.0.8',
    serverPort: 5432,
    serverVersion: '17.6',
    serverVersionNum: '170006',
    databaseOid: '5',
    nativeLedger: nativeLedger(),
    fullIdentityLedger: manifest.entries.slice(0, 117 + pendingPrefix)
      .map(row => ({ stableIdentity: row.stableIdentity, sha256: row.sha256 }))
      .sort((left, right) => left.stableIdentity.localeCompare(right.stableIdentity)),
    ...overrides,
  };
}

function postverify() {
  return {
    status: 'PASS',
    schema_fingerprint_sha256: EXPECTED_DATABASE_SCHEMA_FINGERPRINT,
    compute_families: 27,
    compute_metrics: 80,
    rls_tables: 42,
    selected_functions: 8,
    selected_triggers: 6,
    selected_policies: 6,
  };
}

function mockedDatabase(manifest, {
  failApplyOrdinal = null, failAfterCommit = false, failPostverify = false, snapshot = null,
  postverifyResult = null,
} = {}) {
  let prefix = 0;
  let mutableSnapshot = snapshot;
  const calls = [];
  const query = (sql, label) => {
    calls.push({ sql, label });
    if (label.startsWith('hosted ledger export')) {
      return mutableSnapshot ?? rawSnapshot(manifest, prefix);
    }
    if (label.startsWith('apply ')) {
      const identity = label.slice('apply '.length);
      const ordinal = PENDING_IDENTITIES.indexOf(identity) + 1;
      assert.equal(ordinal, prefix + 1, 'mock observed out-of-order apply');
      assert.match(sql, new RegExp(`frwhoop:hosted-apply:${ordinal}:${identity.replaceAll('.', '\\.')}`));
      assert.match(sql, /insert into supabase_migrations\.scoring_source_identities/);
      assert.doesNotMatch(sql, /insert into supabase_migrations\.schema_migrations/i);
      if (failApplyOrdinal === ordinal && !failAfterCommit) throw new Error(`synthetic apply ${ordinal} rollback`);
      prefix += 1;
      if (failApplyOrdinal === ordinal && failAfterCommit) throw new Error(`synthetic apply ${ordinal} response lost`);
      return { status: 'APPLIED', stableIdentity: identity, sha256: manifest.entries[116 + ordinal].sha256 };
    }
    if (label === 'integrated schema verification') {
      if (failPostverify) throw new Error('synthetic postverify failure');
      assert.match(sql, /begin transaction read only/);
      assert.match(sql, /missing final function/);
      return postverifyResult ?? postverify();
    }
    throw new Error(`unexpected mock query: ${label}`);
  };
  return { query, calls, prefix: () => prefix };
}

function clock() {
  let tick = 0;
  return () => new Date(Date.parse('2026-09-22T12:00:00Z') + tick++ * 1000).toISOString();
}

function planFor(f, database = mockedDatabase(f.manifest)) {
  const result = createHostedMigrationPlan({
    repoRoot: f.repo,
    manifest: f.manifest,
    binding: f.binding,
    databaseClient: f.databaseClient,
    query: database.query,
    now: clock(),
  });
  return { ...result, database };
}

test('binds only the exact FRWHOOP hosted project and a structurally matching credential target', () => {
  const f = fixture();
  try {
    assert.throws(() => createTargetBinding({
      projectRef: 'wrong-project', host: 'db.wrong-project.supabase.co', port: 5432,
      database: 'postgres', user: 'postgres', expectedCurrentUser: 'postgres',
    }), /project ref must be sgoyxzcagqyxexmsidtk/);
    assert.throws(() => createTargetBinding({
      projectRef: HOSTED_PROJECT_REF, host: 'example.invalid', port: 5432,
      database: 'postgres', user: 'postgres', expectedCurrentUser: 'postgres',
    }), /do not bind/);
    assert.equal(verifyTargetBinding(f.binding), f.binding);
    const password = 'never-print-this-password';
    const connection = connectionFromEnvironment(f.binding, {
      FRWHOOP_HOSTED_DATABASE_URL:
        `postgresql://postgres:${password}@db.${HOSTED_PROJECT_REF}.supabase.co:5432/postgres?sslmode=verify-full&sslrootcert=system`,
    });
    assert.equal(connection.password, password);
    let message = '';
    try {
      connectionFromEnvironment(f.binding, {
        FRWHOOP_HOSTED_DATABASE_URL:
          `postgresql://postgres:${password}@db.wrong.supabase.co:5432/postgres?sslmode=verify-full&sslrootcert=system`,
      });
    } catch (error) { message = error.message; }
    assert.match(message, /host differs/);
    assert.doesNotMatch(message, new RegExp(password));
  } finally { f.cleanup(); }
});

test('rejects an independently observed hosted current_user mismatch before planning', () => {
  const f = fixture();
  try {
    const database = mockedDatabase(f.manifest, {
      snapshot: rawSnapshot(f.manifest, 0, { currentUser: 'service_role' }),
    });
    assert.throws(() => planFor(f, database), /observed current_user differs/);
    assert.equal(database.calls.some(call => call.label.startsWith('apply ')), false);
  } finally { f.cleanup(); }
});

test('rejects manifest mutation and migration source mutation', async t => {
  await t.test('immutable manifest fingerprint', () => {
    const f = fixture();
    try {
      const changed = structuredClone(f.manifest);
      changed.entries[123].sha256 = '0'.repeat(64);
      assert.throws(() => verifyMigrationManifest(f.repo, changed), /manifest fingerprint differs/);
    } finally { f.cleanup(); }
  });

  await t.test('source bytes changed after reviewed plan', () => {
    const f = fixture();
    try {
      const { plan } = planFor(f);
      fs.appendFileSync(path.join(f.migrations, PENDING_IDENTITIES[0]), '\n-- changed after plan\n');
      const database = mockedDatabase(f.manifest);
      assert.throws(() => applyHostedMigrationPlan({
        repoRoot: f.repo, manifest: f.manifest, binding: f.binding, databaseClient: f.databaseClient, plan,
        authorizedPlanFingerprint: plan.planFingerprintSha256,
        evidenceDir: f.evidenceDir, query: database.query, now: clock(),
      }), /migration source size differs|migration source hash differs/);
      assert.equal(database.calls.length, 0);
    } finally { f.cleanup(); }
  });

  await t.test('ignores Git blob replacement refs while binding the candidate commit', () => {
    const f = fixture();
    try {
      const identity = PENDING_IDENTITIES.at(-1);
      const originalBlob = git(f.repo, ['rev-parse', `HEAD:${migrationRelative}/${identity}`]);
      const replacement = path.join(f.directory, 'replacement.sql');
      fs.writeFileSync(replacement, 'begin; select 1; commit;\n');
      const replacementBlob = git(f.repo, ['hash-object', '-w', replacement]);
      git(f.repo, ['replace', originalBlob, replacementBlob]);
      assert.equal(verifyMigrationManifest(f.repo, f.manifest).manifest, f.manifest);
    } finally { f.cleanup(); }
  });
});

test('rejects hosted full-identity ledger drift before mutation', () => {
  const f = fixture();
  try {
    const drift = rawSnapshot(f.manifest);
    drift.fullIdentityLedger.push({
      stableIdentity: '20260922999999_unreviewed.sql',
      sha256: 'e'.repeat(64),
    });
    const database = mockedDatabase(f.manifest, { snapshot: drift });
    assert.throws(() => planFor(f, database), /not the reviewed baseline plus an exact pending prefix/);
    assert.equal(database.calls.some(call => call.label.startsWith('apply ')), false);
  } finally { f.cleanup(); }
});

test('stops after an uncertain partial apply and records the exact committed prefix', () => {
  const f = fixture();
  try {
    const { plan } = planFor(f);
    const database = mockedDatabase(f.manifest, { failApplyOrdinal: 2, failAfterCommit: true });
    assert.throws(() => applyHostedMigrationPlan({
      repoRoot: f.repo, manifest: f.manifest, binding: f.binding, databaseClient: f.databaseClient, plan,
      authorizedPlanFingerprint: plan.planFingerprintSha256,
      evidenceDir: f.evidenceDir, query: database.query, now: clock(),
    }), /synthetic apply 2 response lost/);
    assert.equal(database.prefix(), 2);
    assert.equal(database.calls.filter(call => call.label.startsWith('apply ')).length, 2);
    const state = JSON.parse(fs.readFileSync(path.join(f.evidenceDir, 'hosted-migration-state.json')));
    assert.equal(state.status, 'STOPPED_AFTER_UNCERTAIN_RESPONSE');
    assert.equal(state.appliedPrefix, 2);
    assert.equal(state.receipts.at(-1).status, 'COMMITTED_RESPONSE_UNKNOWN');
    assert.equal(fs.readdirSync(path.join(f.evidenceDir, 'receipts'))
      .some(name => name.startsWith(`02-${PENDING_IDENTITIES[1]}-committed-response-unknown-`)), true);
  } finally { f.cleanup(); }
});

test('recovers one atomic remote receipt after interruption between apply response and read-only export', () => {
  const f = fixture();
  try {
    const { plan } = planFor(f);
    const database = mockedDatabase(f.manifest);
    let interruptExport = true;
    const interruptedQuery = (sql, label) => {
      if (interruptExport && label === `hosted ledger export after ${PENDING_IDENTITIES[0]}`) {
        interruptExport = false;
        throw new Error('synthetic ledger export interruption');
      }
      return database.query(sql, label);
    };
    assert.throws(() => applyHostedMigrationPlan({
      repoRoot: f.repo, manifest: f.manifest, binding: f.binding, databaseClient: f.databaseClient, plan,
      authorizedPlanFingerprint: plan.planFingerprintSha256,
      evidenceDir: f.evidenceDir, query: interruptedQuery, now: clock(),
    }), /synthetic ledger export interruption/);
    assert.equal(database.prefix(), 1);
    let state = JSON.parse(fs.readFileSync(path.join(f.evidenceDir, 'hosted-migration-state.json')));
    assert.equal(state.status, 'BLOCKED_LEDGER_DRIFT');
    assert.equal(state.appliedPrefix, 0);

    const result = applyHostedMigrationPlan({
      repoRoot: f.repo, manifest: f.manifest, binding: f.binding, databaseClient: f.databaseClient, plan,
      authorizedPlanFingerprint: plan.planFingerprintSha256,
      evidenceDir: f.evidenceDir, query: database.query, now: clock(),
    });
    assert.equal(result.status, 'PASS');
    state = result.state;
    assert.equal(state.receipts[0].status, 'RECOVERED_ATOMIC_REMOTE_COMMIT');
    assert.equal(state.receipts.length, 7);
    assert.equal(database.prefix(), 7);
  } finally { f.cleanup(); }
});

test('records POSTVERIFY_FAILED after all seven atomic applies and never claims PASS', () => {
  const f = fixture();
  try {
    const { plan } = planFor(f);
    const database = mockedDatabase(f.manifest, { failPostverify: true });
    assert.throws(() => applyHostedMigrationPlan({
      repoRoot: f.repo, manifest: f.manifest, binding: f.binding, databaseClient: f.databaseClient, plan,
      authorizedPlanFingerprint: plan.planFingerprintSha256,
      evidenceDir: f.evidenceDir, query: database.query, now: clock(),
    }), /synthetic postverify failure/);
    assert.equal(database.prefix(), 7);
    const state = JSON.parse(fs.readFileSync(path.join(f.evidenceDir, 'hosted-migration-state.json')));
    assert.equal(state.status, 'POSTVERIFY_FAILED');
    assert.equal(state.appliedPrefix, 7);
    assert.equal(state.receipts.length, 7);
  } finally { f.cleanup(); }
});

test('rejects a passing verifier result with the wrong disposable-database schema fingerprint', () => {
  const f = fixture();
  try {
    const { plan } = planFor(f);
    const wrong = { ...postverify(), schema_fingerprint_sha256: 'd'.repeat(64) };
    const database = mockedDatabase(f.manifest, { postverifyResult: wrong });
    assert.throws(() => applyHostedMigrationPlan({
      repoRoot: f.repo, manifest: f.manifest, binding: f.binding, databaseClient: f.databaseClient, plan,
      authorizedPlanFingerprint: plan.planFingerprintSha256,
      evidenceDir: f.evidenceDir, query: database.query, now: clock(),
    }), /database schema fingerprint differs/);
    const state = JSON.parse(fs.readFileSync(path.join(f.evidenceDir, 'hosted-migration-state.json')));
    assert.equal(state.status, 'POSTVERIFY_FAILED');
  } finally { f.cleanup(); }
});

test('executes the verifier bytes captured during source verification even if the worktree changes later', () => {
  const f = fixture();
  try {
    const { plan } = planFor(f);
    const database = mockedDatabase(f.manifest);
    const query = (sql, label) => {
      const result = database.query(sql, label);
      if (label === `hosted ledger export after ${PENDING_IDENTITIES.at(-1)}`) {
        fs.writeFileSync(path.join(f.repo, verifierRelative), '\\echo unreviewed-worktree-verifier\n');
      }
      return result;
    };
    const result = applyHostedMigrationPlan({
      repoRoot: f.repo, manifest: f.manifest, binding: f.binding, databaseClient: f.databaseClient, plan,
      authorizedPlanFingerprint: plan.planFingerprintSha256,
      evidenceDir: f.evidenceDir, query, now: clock(),
    });
    assert.equal(result.status, 'PASS');
    const verificationCall = database.calls.find(call => call.label === 'integrated schema verification');
    assert.match(verificationCall.sql, /missing final function/);
    assert.doesNotMatch(verificationCall.sql, /unreviewed-worktree-verifier/);
  } finally { f.cleanup(); }
});

test('applies exactly seven migrations in order, reconciles every receipt, and passes independent verification', () => {
  const f = fixture();
  try {
    const planDatabase = mockedDatabase(f.manifest);
    const { plan, snapshot } = planFor(f, planDatabase);
    assert.equal(snapshot.fullIdentityLedger.length, 117);
    assert.deepEqual(plan.migrations.map(row => row.stableIdentity), PENDING_IDENTITIES);
    const database = mockedDatabase(f.manifest);
    const result = applyHostedMigrationPlan({
      repoRoot: f.repo, manifest: f.manifest, binding: f.binding, databaseClient: f.databaseClient, plan,
      authorizedPlanFingerprint: plan.planFingerprintSha256,
      evidenceDir: f.evidenceDir, query: database.query, now: clock(),
    });
    assert.equal(result.status, 'PASS');
    assert.equal(result.state.appliedPrefix, 7);
    assert.equal(result.state.receipts.length, 7);
    assert.equal(database.prefix(), 7);
    assert.deepEqual(database.calls.filter(call => call.label.startsWith('apply '))
      .map(call => call.label.slice('apply '.length)), PENDING_IDENTITIES);
    assert.equal(result.ledger.fullIdentityLedger.length, 124);
    assert.equal(result.ledger.nativeLedger.length, 110);
    assert.equal(result.verification.status, 'PASS');
    const verification = verifyHostedMigrationResult({
      repoRoot: f.repo, manifest: f.manifest, binding: f.binding, databaseClient: f.databaseClient, plan,
      evidenceDir: path.join(f.directory, 'verify-evidence'), query: database.query, now: clock(),
    });
    assert.equal(verification.status, 'PASS');
    assert.match(verification.verificationReceiptFingerprintSha256, /^[0-9a-f]{64}$/);
  } finally { f.cleanup(); }
});

test('generated apply SQL folds reviewed outer transaction into the atomic full-identity receipt', () => {
  const f = fixture();
  try {
    const { plan, snapshot } = planFor(f);
    const migration = plan.migrations[0];
    const sql = migrationApplySQL({
      migrationBytes: fs.readFileSync(path.join(f.migrations, migration.stableIdentity)),
      migration,
      expectedNativeLedger: snapshot.nativeLedger,
      expectedFullIdentityLedger: snapshot.fullIdentityLedger,
    });
    assert.equal((sql.match(/^begin;/gmi) ?? []).length, 1);
    assert.equal((sql.match(/^commit;/gmi) ?? []).length, 1);
    assert.match(sql, /lock table supabase_migrations\.schema_migrations in share mode/);
    assert.match(sql, /frwhoop_native_ledger_drift/);
    assert.match(sql, /frwhoop_full_identity_ledger_drift/);
    assert.match(sql, new RegExp(migration.stableIdentity.replaceAll('.', '\\.')));
  } finally { f.cleanup(); }
});

test('psql runner uses the pinned executable, exact flags, minimal environment, and bounded timeout', () => {
  const f = fixture();
  try {
    const password = 'spawn-contract-password';
    const databaseURL = `postgresql://postgres:${password}@db.${HOSTED_PROJECT_REF}.supabase.co:5432/postgres?sslmode=verify-full&sslrootcert=system`;
    let observed;
    const runner = createPsqlRunner(f.binding, f.databaseClient, {
      [CREDENTIAL_ENVIRONMENT]: databaseURL,
      AWS_SECRET_ACCESS_KEY: 'must-not-reach-psql',
      PGOPTIONS: 'must-not-reach-psql',
      PATH: '/unreviewed/path',
    }, (executable, args, options) => {
      observed = { executable, args, options };
      return { error: undefined, signal: null, status: 0, stdout: 'query-result\n', stderr: '' };
    });
    assert.equal(runner('select 1;', 'spawn contract'), 'query-result');
    assert.equal(observed.executable, f.psqlPath);
    assert.deepEqual(observed.args, [
      '-X', '-w', '-qAt', '-v', 'ON_ERROR_STOP=1',
      '-h', `db.${HOSTED_PROJECT_REF}.supabase.co`, '-p', '5432', '-U', 'postgres', '-d', 'postgres',
    ]);
    assert.equal(observed.options.timeout, PSQL_QUERY_TIMEOUT_MILLISECONDS);
    assert.equal(observed.options.killSignal, 'SIGKILL');
    assert.deepEqual(observed.options.env, {
      LANG: 'C',
      LC_ALL: 'C',
      PGPASSWORD: password,
      PGSSLMODE: 'verify-full',
      PGSSLROOTCERT: 'system',
      PGCONNECT_TIMEOUT: String(PSQL_CONNECT_TIMEOUT_SECONDS),
      PGAPPNAME: 'frwhoop-hosted-migration-release',
    });
  } finally { f.cleanup(); }
});

test('real plan CLI spawn binds psql identity, target, flags, environment, SQL timeouts, and schema fingerprint', () => {
  const f = fixture();
  try {
    const manifestPath = path.join(f.directory, 'migration-manifest.json');
    const bindingPath = path.join(f.directory, 'target-binding.json');
    fs.writeFileSync(manifestPath, `${JSON.stringify(f.manifest)}\n`);
    fs.writeFileSync(bindingPath, `${JSON.stringify(f.binding)}\n`);
    const argsLog = fs.realpathSync(f.directory) + '/psql-args.log';
    const envLog = fs.realpathSync(f.directory) + '/psql-env.log';
    const stdinLog = fs.realpathSync(f.directory) + '/psql-stdin.sql';
    const fakePsql = writeExecutable(path.join(f.directory, 'cli-psql'), `#!/bin/sh
if [ "$#" -eq 1 ] && [ "$1" = "--version" ]; then
  printf '%s\\n' 'psql (PostgreSQL) 18.3 cli-fixture'
  exit 0
fi
: > ${shellLiteral(argsLog)}
for argument in "$@"; do printf '%s\\n' "$argument" >> ${shellLiteral(argsLog)}; done
/usr/bin/env > ${shellLiteral(envLog)}
/bin/cat > ${shellLiteral(stdinLog)}
printf '%s\\n' ${shellLiteral(JSON.stringify(rawSnapshot(f.manifest)))}
`);
    const password = 'real-cli-password';
    const databaseURL = `postgresql://postgres:${password}@db.${HOSTED_PROJECT_REF}.supabase.co:5432/postgres?sslmode=verify-full&sslrootcert=system`;
    const result = spawnSync(process.execPath, [
      path.join(sourceRoot, 'Tools/release/hosted-migration-release.mjs'), 'plan',
      '--repo-root', f.repo,
      '--manifest', manifestPath,
      '--project-ref', HOSTED_PROJECT_REF,
      '--target-binding', bindingPath,
      '--evidence-dir', f.evidenceDir,
      '--psql-path', fakePsql,
    ], {
      encoding: 'utf8',
      env: {
        PATH: process.env.PATH,
        [CREDENTIAL_ENVIRONMENT]: databaseURL,
        UNRELATED_SECRET: 'must-not-reach-real-psql',
        PGOPTIONS: 'must-not-reach-real-psql',
      },
      timeout: 30 * 1000,
    });
    assert.equal(result.status, 0, result.stderr);
    assert.doesNotMatch(`${result.stdout}\n${result.stderr}`, /real-cli-password|FRWHOOP_HOSTED_DATABASE_URL/);
    assert.deepEqual(fs.readFileSync(argsLog, 'utf8').trim().split('\n'), [
      '-X', '-w', '-qAt', '-v', 'ON_ERROR_STOP=1',
      '-h', `db.${HOSTED_PROJECT_REF}.supabase.co`, '-p', '5432', '-U', 'postgres', '-d', 'postgres',
    ]);
    const childEnvironment = fs.readFileSync(envLog, 'utf8');
    assert.match(childEnvironment, /^LANG=C$/m);
    assert.match(childEnvironment, /^LC_ALL=C$/m);
    assert.match(childEnvironment, new RegExp(`^PGCONNECT_TIMEOUT=${PSQL_CONNECT_TIMEOUT_SECONDS}$`, 'm'));
    assert.match(childEnvironment, /^PGSSLMODE=verify-full$/m);
    assert.match(childEnvironment, /^PGSSLROOTCERT=system$/m);
    assert.match(childEnvironment, /^PGAPPNAME=frwhoop-hosted-migration-release$/m);
    assert.match(childEnvironment, new RegExp(`^PGPASSWORD=${password}$`, 'm'));
    assert.doesNotMatch(childEnvironment, /UNRELATED_SECRET|must-not-reach-real-psql|PGOPTIONS|FRWHOOP_HOSTED_DATABASE_URL/);
    const sql = fs.readFileSync(stdinLog, 'utf8');
    assert.match(sql, /begin transaction read only/);
    assert.match(sql, /set local statement_timeout='30s'/);
    const plan = JSON.parse(fs.readFileSync(path.join(f.evidenceDir, 'hosted-migration-plan.json')));
    assert.equal(plan.databaseClient.path, fakePsql);
    assert.equal(plan.databaseClient.sha256, sha256Hex(fs.readFileSync(fakePsql)));
    assert.equal(plan.databaseClient.version, 'psql (PostgreSQL) 18.3 cli-fixture');
    assert.equal(plan.executionContract.psqlConnectTimeoutSeconds, PSQL_CONNECT_TIMEOUT_SECONDS);
    assert.equal(plan.executionContract.psqlQueryTimeoutMilliseconds, PSQL_QUERY_TIMEOUT_MILLISECONDS);
    assert.equal(plan.executionContract.ledgerStatementTimeoutSeconds, LEDGER_STATEMENT_TIMEOUT_SECONDS);
    assert.equal(plan.executionContract.migrationStatementTimeoutSeconds, MIGRATION_STATEMENT_TIMEOUT_SECONDS);
    assert.equal(plan.executionContract.postverifyStatementTimeoutSeconds, POSTVERIFY_STATEMENT_TIMEOUT_SECONDS);
    assert.equal(plan.databaseSchemaFingerprintSha256, EXPECTED_DATABASE_SCHEMA_FINGERPRINT);
  } finally { f.cleanup(); }
});

test('real plan CLI spawn redacts the credential URL and password from psql failure output', () => {
  const f = fixture();
  try {
    const manifestPath = path.join(f.directory, 'migration-manifest.json');
    const bindingPath = path.join(f.directory, 'target-binding.json');
    fs.writeFileSync(manifestPath, `${JSON.stringify(f.manifest)}\n`);
    fs.writeFileSync(bindingPath, `${JSON.stringify(f.binding)}\n`);
    const password = 'redaction-password-93841';
    const databaseURL = `postgresql://postgres:${password}@db.${HOSTED_PROJECT_REF}.supabase.co:5432/postgres?sslmode=verify-full&sslrootcert=system`;
    const fakePsql = writeExecutable(path.join(f.directory, 'failing-psql'), `#!/bin/sh
if [ "$#" -eq 1 ] && [ "$1" = "--version" ]; then
  printf '%s\\n' 'psql (PostgreSQL) 18.3 failure-fixture'
  exit 0
fi
/bin/cat > /dev/null
printf '%s\\n' ${shellLiteral(`synthetic failure ${password} ${databaseURL}`)} >&2
exit 23
`);
    const result = spawnSync(process.execPath, [
      path.join(sourceRoot, 'Tools/release/hosted-migration-release.mjs'), 'plan',
      '--repo-root', f.repo,
      '--manifest', manifestPath,
      '--project-ref', HOSTED_PROJECT_REF,
      '--target-binding', bindingPath,
      '--evidence-dir', f.evidenceDir,
      '--psql-path', fakePsql,
    ], {
      encoding: 'utf8',
      env: { PATH: process.env.PATH, [CREDENTIAL_ENVIRONMENT]: databaseURL },
      timeout: 30 * 1000,
    });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /\[REDACTED\]/);
    assert.doesNotMatch(`${result.stdout}\n${result.stderr}`, new RegExp(`${password}|${HOSTED_PROJECT_REF}\.supabase\.co:5432/postgres`));
  } finally { f.cleanup(); }
});
