import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

import {
  DEPLOYABLE_ROLES,
  prepareEdgeSourceBundle,
  sha256Hex,
} from '../../../Tools/release/edge-source-bundle.mjs';
import {
  HOSTED_PROJECT_REF,
  deployHostedEdge,
} from './deploy-hosted-edge-functions.mjs';

const functions = DEPLOYABLE_ROLES.join(',');
const accessSecret = 'never-print-this-auth-token';
const paritySecrets = {
  FRWHOOP_HOSTED_ACCOUNT_JWT: 'header.payload.signature',
  FRWHOOP_HOSTED_ANON_KEY: 'protected-anon-key',
  FRWHOOP_HOSTED_ENROLLMENT_TOKEN: 'noop_installation-secret',
  FRWHOOP_HOSTED_FLEET_TOKEN: 'noop_fleet-secret',
  FRWHOOP_HOSTED_USER_ID: '11111111-1111-4111-8111-111111111111',
  FRWHOOP_HOSTED_SOURCE_ID: '22222222-2222-4222-8222-222222222222',
  FRWHOOP_HOSTED_DEVICE_ID: 'whoop-test-strap',
  FRWHOOP_HOSTED_DAY: '2026-09-22',
};

function command(executable, args, options = {}) {
  const spawned = spawnSync(executable, args, {
    cwd: options.cwd,
    env: options.env ?? process.env,
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
  });
  if (spawned.status !== 0) throw new Error(`${executable} failed (${spawned.status}): ${spawned.stderr}`);
  return spawned;
}

function write(root, relative, contents, mode = 0o644) {
  const filename = path.join(root, relative);
  fs.mkdirSync(path.dirname(filename), { recursive: true });
  fs.writeFileSync(filename, contents, { mode });
  fs.chmodSync(filename, mode);
  return filename;
}

function makeExecutable(root, relative, contents) {
  return write(root, relative, contents, 0o755);
}

function mockParitySource(repository) {
  return `#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
const args = process.argv.slice(2);
const root = ${JSON.stringify(repository)};
const control = JSON.parse(fs.readFileSync(path.join(root, '.test-control.json'), 'utf8'));
const log = path.join(root, '.test-parity-log.jsonl');
fs.appendFileSync(log, JSON.stringify({ args, envKeys: Object.keys(process.env).sort() }) + '\\n');
if (process.env.SUPABASE_ACCESS_TOKEN) process.exit(80);
if (args.length === 1 && args[0] === '--contract-version') {
  process.stdout.write(JSON.stringify({ kind: 'frwhoop-hosted-score-route-parity', schemaVersion: 1 }) + '\\n');
  process.exit(0);
}
if (control.parityFail) process.exit(81);
const required = ${JSON.stringify(Object.keys(paritySecrets))};
if (required.some((name) => !process.env[name])) process.exit(82);
const value = (flag) => args[args.indexOf(flag) + 1];
const envelope = crypto.createHash('sha256').update('same-production-envelope').digest('hex');
const comparison = crypto.createHash('sha256').update('account-enrollment-comparison').digest('hex');
process.stdout.write(JSON.stringify({
  status: 'PASS', projectRef: value('--project-ref'), bundleSha256: value('--bundle-sha256'),
  sourceCommit: value('--source-commit'),
  account: { status: 'PASS', responseEnvelopeSha256: envelope },
  enrollment: { status: 'PASS', responseEnvelopeSha256: envelope },
  parity: { status: 'PASS', comparisonSha256: comparison },
}) + '\\n');
`;
}

function createFixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'frwhoop-hosted-edge-test-'));
  const repository = path.join(root, 'repo');
  const artifactRoot = path.join(root, 'artifacts');
  fs.mkdirSync(repository);
  fs.mkdirSync(artifactRoot);
  command('git', ['init', '-q', repository]);
  command('git', ['-C', repository, 'config', 'user.name', 'Hosted Edge Test']);
  command('git', ['-C', repository, 'config', 'user.email', 'hosted-edge@example.invalid']);
  write(repository, 'supabase/config.toml', DEPLOYABLE_ROLES.map((role) =>
    `[functions.${role}]\nverify_jwt = false\n`).join(''));
  write(repository, 'supabase/functions/deno.lock', '{"version":"4"}\n');
  write(repository, 'supabase/functions/_shared/helper.ts', 'export const source = "verified-bundle";\n');
  for (const role of DEPLOYABLE_ROLES) {
    write(repository, `supabase/functions/${role}/index.ts`, `export const role = ${JSON.stringify(role)};\n`);
  }
  const parity = makeExecutable(repository, 'infra/vps/scripts/verify-hosted-score-route-parity.mjs',
    mockParitySource(repository));
  command('git', ['-C', repository, 'add', '.']);
  command('git', ['-C', repository, 'commit', '-qm', 'fixture']);
  const commit = command('git', ['-C', repository, 'rev-parse', 'HEAD']).stdout.trim();
  const tree = command('git', ['-C', repository, 'rev-parse', `${commit}^{tree}`]).stdout.trim();
  const bundle = path.join(artifactRoot, 'edge');
  const manifest = prepareEdgeSourceBundle({ repoRoot: repository, commitSha: commit, outputDirectory: bundle });

  const release = {
    schemaVersion: 1,
    kind: 'frwhoop-phone-test-artifact-manifest',
    source: { commit, tree },
    artifacts: {
      edge: {
        kind: 'edge-source-bundle',
        file: {
          path: 'edge/edge-source-bundle.tar',
          sizeBytes: manifest.bundle.sizeBytes,
          sha256: manifest.bundle.sha256,
        },
      },
    },
    manifestFingerprintSha256: 'f'.repeat(64),
  };
  const releaseManifest = write(artifactRoot, 'release-manifest.json', `${JSON.stringify(release)}\n`);
  const state = write(root, 'remote-state.json', `${JSON.stringify({
    functions: DEPLOYABLE_ROLES.map((role) => ({
      id: `function-${role}`,
      slug: role,
      version: 1,
      status: 'ACTIVE',
      updated_at: '2026-09-22T00:00:00.000Z',
      verify_jwt: false,
    })),
  })}\n`);
  const control = write(root, 'control.json', '{}\n');
  const cliLog = path.join(root, 'cli-log.jsonl');
  const parityLog = path.join(repository, '.test-parity-log.jsonl');
  write(repository, '.test-control.json', '{}\n');

  const cli = makeExecutable(root, 'mock-supabase.mjs', `#!${process.execPath}
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = path.dirname(fileURLToPath(import.meta.url));
const statePath = path.join(root, 'remote-state.json');
const control = JSON.parse(fs.readFileSync(path.join(root, 'control.json'), 'utf8'));
const args = process.argv.slice(2);
fs.appendFileSync(path.join(root, 'cli-log.jsonl'), JSON.stringify({
  args, cwd: process.cwd(), envKeys: Object.keys(process.env).sort(),
}) + '\\n');
if (Object.keys(process.env).some((name) => name.startsWith('FRWHOOP_HOSTED_'))) process.exit(76);
if (!process.env.SUPABASE_ACCESS_TOKEN) process.exit(77);
if (args.length === 1 && args[0] === '--version') {
  process.stdout.write('2.75.0\\n'); process.exit(0);
}
if (args[0] === 'projects' && args[1] === 'list') {
  process.stdout.write(JSON.stringify([{ id: control.projectRef ?? '${HOSTED_PROJECT_REF}' }]) + '\\n'); process.exit(0);
}
if (args[0] === 'functions' && args[1] === 'list') {
  process.stdout.write(fs.readFileSync(statePath, 'utf8')); process.exit(0);
}
if (args[0] === 'functions' && args[1] === 'deploy') {
  const role = args[2];
  const workdir = args[args.indexOf('--workdir') + 1];
  if (!args.includes('--no-verify-jwt') || !workdir ||
      fs.realpathSync(process.cwd()) !== fs.realpathSync(workdir)) process.exit(72);
  const source = fs.readFileSync(workdir + '/supabase/functions/' + role + '/index.ts');
  if (!source.includes(Buffer.from(role))) process.exit(73);
  if (control.failRole === role) process.exit(74);
  const state = JSON.parse(fs.readFileSync(statePath, 'utf8'));
  const row = state.functions.find((candidate) => candidate.slug === role);
  row.version += 1;
  row.updated_at = '2026-09-22T01:00:' + String(row.version).padStart(2, '0') + '.000Z';
  row.source_sha256 = crypto.createHash('sha256').update(source).digest('hex');
  if (control.inactiveAfterRole === role) row.status = 'INACTIVE';
  if (control.jwtAfterRole === role) row.verify_jwt = true;
  if (control.mutateEarlyAfterRole === role) {
    state.functions.find((candidate) => candidate.slug === 'account-deletion').version += 1;
  }
  fs.writeFileSync(statePath, JSON.stringify(state) + '\\n');
  process.stdout.write(JSON.stringify({ message: 'deployed', secretEcho: process.env.SUPABASE_ACCESS_TOKEN }) + '\\n');
  process.exit(0);
}
process.exit(75);
`);
  const cliSha256 = sha256Hex(fs.readFileSync(cli));
  return {
    root, repository, artifactRoot, bundle, manifest, release, releaseManifest, state, control,
    cli, cliSha256, cliLog, parity, parityLog,
  };
}

function setControl(fixture, value) {
  fs.writeFileSync(fixture.control, `${JSON.stringify(value)}\n`);
  fs.writeFileSync(path.join(fixture.repository, '.test-control.json'), `${JSON.stringify(value)}\n`);
}

function invoke(fixture, overrides = {}) {
  setControl(fixture, overrides.control ?? {});
  const receipt = overrides.receipt ?? path.join(fixture.root, `receipt-${crypto.randomUUID()}.json`);
  const releaseVerifier = overrides.releaseVerifier ?? (({ repoRoot, artifactRoot, manifest }) => {
    assert.equal(repoRoot, fs.realpathSync(fixture.repository));
    assert.equal(artifactRoot, fs.realpathSync(fixture.artifactRoot));
    assert.deepEqual(manifest, fixture.release);
    return manifest;
  });
  let result = null;
  let error = null;
  try {
    result = deployHostedEdge({
      projectRef: overrides.projectRef ?? HOSTED_PROJECT_REF,
      repoRoot: fixture.repository,
      artifactRoot: fixture.artifactRoot,
      releaseManifest: fixture.releaseManifest,
      bundle: fixture.bundle,
      expectedBundleSha256: overrides.expectedBundleSha256 ?? fixture.manifest.bundle.sha256,
      functions: overrides.functions ?? functions,
      supabaseCli: fixture.cli,
      expectedCliVersion: overrides.expectedCliVersion ?? '2.75.0',
      expectedCliSha256: overrides.expectedCliSha256 ?? fixture.cliSha256,
      parityCommand: fixture.parity,
      receipt,
      environment: {
        PATH: process.env.PATH,
        HOME: process.env.HOME,
        TMPDIR: process.env.TMPDIR ?? '/tmp',
        SUPABASE_ACCESS_TOKEN: accessSecret,
        ...paritySecrets,
        SHOULD_NOT_REACH_SUBPROCESSES: 'excluded',
        ...overrides.environment,
      },
    }, { verifyReleaseManifest: releaseVerifier });
  } catch (caught) {
    error = caught;
  }
  return { result, error, receipt, value: JSON.parse(fs.readFileSync(receipt, 'utf8')) };
}

function readLog(filename) {
  if (!fs.existsSync(filename)) return [];
  return fs.readFileSync(filename, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
}

function loggedDeployments(fixture) {
  return readLog(fixture.cliLog).filter((entry) =>
    entry.args[0] === 'functions' && entry.args[1] === 'deploy');
}

function withFixture(callback) {
  const fixture = createFixture();
  try { callback(fixture); } finally { fs.rmSync(fixture.root, { recursive: true, force: true }); }
}

test('aggregate release verification and exact candidate binding fail before CLI access', () => {
  withFixture((fixture) => {
    const verifierFailure = invoke(fixture, { releaseVerifier: () => { throw new Error('invalid aggregate'); } });
    assert.equal(verifierFailure.error.code, 'RELEASE_MANIFEST_INVALID');
    assert.deepEqual(readLog(fixture.cliLog), []);

    fs.appendFileSync(fixture.parity, '\n// mutable replacement\n');
    const parityFailure = invoke(fixture);
    assert.equal(parityFailure.error.code, 'PARITY_COMMAND_MISMATCH');
    assert.deepEqual(readLog(fixture.cliLog), []);
  });
});

test('wrong CLI SHA-256 fails before executing the CLI and records no remote mutation', () => {
  withFixture((fixture) => {
    const attempt = invoke(fixture, { expectedCliSha256: '0'.repeat(64) });
    assert.equal(attempt.error.code, 'CLI_IDENTITY_MISMATCH');
    assert.equal(attempt.value.status, 'PREFLIGHT_FAILED');
    assert.deepEqual(readLog(fixture.cliLog), []);
  });
});

test('missing parity credentials fail before executing the CLI or mutating functions', () => {
  withFixture((fixture) => {
    const attempt = invoke(fixture, { environment: { FRWHOOP_HOSTED_ACCOUNT_JWT: undefined } });
    assert.equal(attempt.error.code, 'CONFIGURATION_MISSING');
    assert.equal(attempt.value.status, 'PREFLIGHT_FAILED');
    assert.deepEqual(readLog(fixture.cliLog), []);
  });
});

test('parity uses the bound Node interpreter and never exposes credentials to a PATH hijack', () => {
  withFixture((fixture) => {
    const fakeBin = path.join(fixture.root, 'fake-bin');
    const hijackMarker = path.join(fixture.root, 'fake-node-executed');
    fs.mkdirSync(fakeBin);
    makeExecutable(fakeBin, 'node', `#!/bin/sh
set > ${JSON.stringify(hijackMarker)}
exit 97
`);

    const attempt = invoke(fixture, { environment: { PATH: fakeBin } });
    assert.equal(attempt.error, null);
    assert.equal(attempt.result.status, 'SUCCEEDED');
    assert.equal(fs.existsSync(hijackMarker), false);
    assert.deepEqual(attempt.value.parityCommand.interpreter, {
      path: fs.realpathSync(process.execPath),
      sizeBytes: fs.statSync(fs.realpathSync(process.execPath)).size,
      sha256: sha256Hex(fs.readFileSync(fs.realpathSync(process.execPath))),
      version: process.version,
    });
    assert.equal(attempt.value.parityCommand.environmentKeys.includes('PATH'), false);
    assert.ok(readLog(fixture.parityLog).every((entry) => entry.envKeys.includes('PATH') === false));
  });
});

test('wrong hosted project and incomplete role lists fail before function mutation', () => {
  withFixture((fixture) => {
    let attempt = invoke(fixture, { control: { projectRef: 'aaaaaaaaaaaaaaaaaaaa' } });
    assert.equal(attempt.error.code, 'PROJECT_MISMATCH');
    assert.deepEqual(loggedDeployments(fixture), []);

    attempt = invoke(fixture, { functions: DEPLOYABLE_ROLES.slice(0, -1).join(',') });
    assert.equal(attempt.error.code, 'ROLE_MISMATCH');
    assert.deepEqual(loggedDeployments(fixture), []);
  });
});

test('mutated Edge bundle fails offline before CLI mutation', () => {
  withFixture((fixture) => {
    fs.appendFileSync(path.join(fixture.bundle, 'payload/supabase/functions/scores/index.ts'), '// mutation\n');
    const attempt = invoke(fixture);
    assert.equal(attempt.error.code, 'BUNDLE_INVALID');
    assert.deepEqual(loggedDeployments(fixture), []);
  });
});

test('partial deployment stops immediately and records mixed-version recovery state', () => {
  withFixture((fixture) => {
    const attempt = invoke(fixture, { control: { failRole: 'push' } });
    assert.equal(attempt.error.code, 'FUNCTION_DEPLOY_FAILED');
    assert.equal(attempt.value.status, 'PARTIAL_FAILURE');
    assert.equal(attempt.value.safeState.classification, 'MIXED_FUNCTION_VERSIONS_RECONCILIATION_REQUIRED');
    assert.deepEqual(attempt.value.deployments.map((entry) => [entry.role, entry.state]), [
      ['account-deletion', 'VERIFIED'], ['ingest-verify', 'VERIFIED'], ['push', 'FAILED'],
    ]);
    assert.equal(fs.readFileSync(attempt.receipt, 'utf8').includes(accessSecret), false);
  });
});

test('post-deploy discovery requires ACTIVE and verify_jwt=false for every exact role', () => {
  for (const control of [{ inactiveAfterRole: 'account-deletion' }, { jwtAfterRole: 'account-deletion' }]) {
    withFixture((fixture) => {
      const attempt = invoke(fixture, { control });
      assert.equal(attempt.error.code, 'FUNCTION_IDENTITY_UNVERIFIED');
      assert.equal(attempt.value.status, 'PARTIAL_FAILURE');
      assert.equal(attempt.value.deployments.length, 1);
      assert.equal(attempt.value.deployments[0].state, 'COMMAND_SUCCEEDED_IDENTITY_PENDING');
    });
  }
});

test('final discovery rejects a later change to an earlier function identity', () => {
  withFixture((fixture) => {
    const attempt = invoke(fixture, { control: { mutateEarlyAfterRole: 'scores' } });
    assert.equal(attempt.error.code, 'FUNCTION_IDENTITY_UNVERIFIED');
    assert.equal(attempt.value.status, 'PARITY_FAILED');
    assert.deepEqual(readLog(fixture.parityLog).map((entry) => entry.args), [['--contract-version']]);
  });
});

test('route parity failure is distinct from six verified function deployments', () => {
  withFixture((fixture) => {
    const attempt = invoke(fixture, { control: { parityFail: true } });
    assert.equal(attempt.error.code, 'PARITY_FAILED');
    assert.equal(attempt.value.status, 'PARITY_FAILED');
    assert.equal(attempt.value.deployments.length, DEPLOYABLE_ROLES.length);
    assert.ok(attempt.value.deployments.every((entry) => entry.state === 'VERIFIED'));
    assert.equal(attempt.value.safeState.classification, 'ALL_FUNCTIONS_DEPLOYED_ROUTE_PARITY_UNVERIFIED');
  });
});

test('success binds release, CLI provenance, isolated environments and final function policy', () => {
  withFixture((fixture) => {
    const attempt = invoke(fixture);
    assert.equal(attempt.error, null);
    assert.equal(attempt.result.status, 'SUCCEEDED');
    assert.equal(attempt.value.release.sourceCommit, fixture.release.source.commit);
    assert.equal(attempt.value.release.manifestFingerprintSha256, fixture.release.manifestFingerprintSha256);
    assert.equal(attempt.value.bundle.sha256, fixture.manifest.bundle.sha256);
    assert.equal(attempt.value.cli.sha256, fixture.cliSha256);
    assert.equal(attempt.value.cli.expectedSha256, fixture.cliSha256);
    assert.equal(attempt.value.cli.version, '2.75.0');
    assert.equal(attempt.value.parityCommand.candidateSha256, sha256Hex(fs.readFileSync(fixture.parity)));
    assert.ok(attempt.value.deployments.every((entry) => entry.identity.status === 'ACTIVE' &&
      entry.identity.verifyJwt === false));
    assert.ok(attempt.value.finalFunctions.every((entry) => entry.status === 'ACTIVE' &&
      entry.verifyJwt === false));
    assert.deepEqual(loggedDeployments(fixture).map((entry) => entry.args[2]), DEPLOYABLE_ROLES);
    assert.ok(loggedDeployments(fixture).every((entry) => entry.args.includes('--no-verify-jwt')));

    for (const entry of readLog(fixture.cliLog)) {
      assert.equal(entry.envKeys.includes('SUPABASE_ACCESS_TOKEN'), true);
      assert.equal(entry.envKeys.some((name) => name.startsWith('FRWHOOP_HOSTED_')), false);
      assert.equal(entry.envKeys.includes('SHOULD_NOT_REACH_SUBPROCESSES'), false);
    }
    for (const entry of readLog(fixture.parityLog)) {
      assert.equal(entry.envKeys.includes('SUPABASE_ACCESS_TOKEN'), false);
      assert.ok(Object.keys(paritySecrets).every((name) => entry.envKeys.includes(name)));
      assert.equal(entry.envKeys.includes('SHOULD_NOT_REACH_SUBPROCESSES'), false);
    }
    const receiptText = fs.readFileSync(attempt.receipt, 'utf8');
    assert.equal(receiptText.includes(accessSecret), false);
    for (const credential of [
      paritySecrets.FRWHOOP_HOSTED_ACCOUNT_JWT,
      paritySecrets.FRWHOOP_HOSTED_ANON_KEY,
      paritySecrets.FRWHOOP_HOSTED_ENROLLMENT_TOKEN,
      paritySecrets.FRWHOOP_HOSTED_FLEET_TOKEN,
    ]) assert.equal(receiptText.includes(credential), false);
  });
});
