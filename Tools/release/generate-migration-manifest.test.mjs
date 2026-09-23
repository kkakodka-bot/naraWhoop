import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import { canonicalJSON, sha256Hex } from './generate-migration-manifest.mjs';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const sourceRoot = path.resolve(testDirectory, '../..');
const generator = path.join(testDirectory, 'generate-migration-manifest.mjs');
const catalogRelative = 'scoring-service/service/src/main/resources/scoring-migration-catalog.json';
const migrationsRelative = 'supabase/migrations';
const expectedFingerprint = 'bd78bdc02131edb3f5de974158202dc948e899cffb85b05970a45b1db2ae4edd';

const sources = {
  'persistent-sync-followup': {
    branch: 'codex/persistent-sync-followup-2026-09-22',
    tip: 'a972493212f2eae29f01ecaddf9182260153400f',
  },
  'server-repair': { branch: 'repair/vps-server-20260922', tip: 'a'.repeat(40) },
  'server-pipeline': {
    branch: 'fix/server-pipeline',
    tip: 'cfb94434b1b4ed4dba587e5c4e7af405e782e560',
  },
  'multiuser-scale': {
    branch: 'feat/multiuser-scale',
    tip: '0eac19cce495e761dc3d832dd1cfd8a07221c61d',
  },
  'sensor-algorithms': {
    branch: 'feat/sensor-algorithms',
    tip: '198b99924a79148ff01833115fe2f47f2025bfa4',
  },
  'ble-sync': {
    branch: 'fix/ble-sync',
    tip: 'af9468f7a48cc3fddeb33d7a3b983204af620ca6',
  },
  'vps-only-compute': {
    branch: 'feat/vps-only-compute',
    tip: '63ac35d0cab0644d197e8225d9fc97e1bd9446cf',
  },
};

function fixture() {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'frwhoop-migration-manifest-'));
  const repo = path.join(directory, 'repository');
  const catalogPath = path.join(repo, catalogRelative);
  const migrations = path.join(repo, migrationsRelative);
  fs.mkdirSync(path.dirname(catalogPath), { recursive: true });
  fs.mkdirSync(path.dirname(migrations), { recursive: true });
  fs.copyFileSync(path.join(sourceRoot, catalogRelative), catalogPath);
  fs.cpSync(path.join(sourceRoot, migrationsRelative), migrations, { recursive: true });
  const catalog = JSON.parse(fs.readFileSync(catalogPath, 'utf8'));

  const candidatePath = path.join(directory, 'candidate-sources.json');
  const hostedPath = path.join(directory, 'hosted-ledger.json');
  const output = path.join(directory, 'migration-manifest.json');
  fs.writeFileSync(candidatePath, JSON.stringify({
    schemaVersion: 1,
    candidate: {
      branch: 'repair/vps-server-20260922',
      sha: 'a'.repeat(40),
      tree: 'b'.repeat(40),
    },
    sources,
  }));
  fs.writeFileSync(hostedPath, JSON.stringify({
    schemaVersion: 1,
    environment: 'hosted-production',
    projectRef: 'sgoyxzcagqyxexmsidtk',
    capturedAt: '2026-09-22T01:02:03Z',
    nativeLedgerRows: 110,
    fullIdentityRows: 117,
    highestKnownIdentity: '20260921104000_server_unrepresentable_clock.sql',
    applied: catalog.slice(0, 117).reverse().map(row => ({ stableIdentity: row.basename, sha256: row.sha256 })),
    identityStates: {
      '20260918234000_motion_evidence_provenance.sql': {
        state: 'superseded_in_hosted_schema',
        reason: 'The hosted schema already had the equivalent columns and constraints through a later forward repair.',
      },
    },
    evidenceArtifacts: [
      {
        label: 'post-ledger-verification',
        path: '/Volumes/Untitled/server-pipeline-live-deploy.DzU5wM/post-ledger-verification.json',
        sha256: '2478552af3343fa3d634939a01c27050f696f0d870c1362f140cce66ea77944e',
      },
      {
        label: 'full-source-identity-ledger',
        path: '/Volumes/Untitled/server-pipeline-live-deploy.DzU5wM/scoring-source-identities.sql',
        sha256: '2cc8f8dcd90110ae63b2c7806e9057c080e6476431322bf32dc448ccebd8681c',
      },
    ],
  }));
  return {
    directory, repo, catalog, catalogPath, migrations, candidatePath, hostedPath, output,
    cleanup: () => fs.rmSync(directory, { recursive: true, force: true }),
  };
}

function invoke(f, output = f.output) {
  return spawnSync(process.execPath, [
    generator,
    '--repo-root', f.repo,
    '--candidate-sources', f.candidatePath,
    '--hosted-ledger-evidence', f.hostedPath,
    '--output', output,
  ], { encoding: 'utf8' });
}

test('emits one deterministic manifest for the 117 applied and twelve pending migrations', () => {
  const f = fixture();
  try {
    const first = invoke(f);
    assert.equal(first.status, 0, first.stderr);
    const firstBytes = fs.readFileSync(f.output, 'utf8');
    const secondOutput = path.join(f.directory, 'migration-manifest-second.json');
    const second = invoke(f, secondOutput);
    assert.equal(second.status, 0, second.stderr);
    assert.equal(fs.readFileSync(secondOutput, 'utf8'), firstBytes);

    const manifest = JSON.parse(firstBytes);
    assert.equal(manifest.schemaFingerprintSha256, expectedFingerprint);
    assert.deepEqual(manifest.counts, { applied: 117, pending: 12, total: 129 });
    assert.equal(manifest.entries.length, 129);
    assert.deepEqual(manifest.entries.map(row => row.ordinal), Array.from({ length: 129 }, (_, index) => index + 1));
    assert.equal(manifest.sourceWorkstreams.find(row => row.workstream === 'ble-sync').migrationCount, 0);

    const sensor = manifest.entries[121];
    const compute = manifest.entries[122];
    const sessions = manifest.entries[123];
    assert.equal(sensor.stableIdentity, '20260921120000_sensor_acquisition_windows.sql');
    assert.deepEqual(compute.dependencies, [sensor.stableIdentity]);
    assert.equal(compute.collisionRenameState.state, 'renamed_before_application');
    assert.equal(compute.collisionRenameState.proposedStableIdentity,
      '20260921110000_final_hosted_compute_contract.sql');
    assert.equal(compute.collisionRenameState.collidedWithStableIdentity,
      '20260921110000_installation_retirement.sql');
    assert.deepEqual(sessions.dependencies, [compute.stableIdentity]);
    assert.equal(sessions.upgradeBehavior.upgradeOrdinal, 7);
    assert.equal(manifest.entries[124].sourceWorkstream, 'persistent-sync-followup');
    assert.equal(manifest.entries[125].sourceWorkstream, 'persistent-sync-followup');
    assert.equal(manifest.entries[126].sourceWorkstream, 'server-repair');
    assert.equal(manifest.entries[126].sourceTip, manifest.candidate.sha);
    assert.deepEqual(manifest.entries[126].dependencies, [manifest.entries[125].stableIdentity]);
    assert.equal(manifest.entries.filter(row => row.collisionRenameState.state === 'historical_timestamp_collision').length, 12);
    assert.equal(manifest.entries.find(row => row.stableIdentity ===
      '20260918234000_motion_evidence_provenance.sql').hostedIdentityState.state, 'superseded_in_hosted_schema');

    const { manifestFingerprintSha256, ...unsigned } = manifest;
    assert.equal(manifestFingerprintSha256, sha256Hex(canonicalJSON(unsigned)));
  } finally {
    f.cleanup();
  }
});

test('fails when migration bytes drift from the runtime catalog hash', () => {
  const f = fixture();
  try {
    fs.appendFileSync(path.join(f.migrations, f.catalog[0].basename), '\n-- drift\n');
    const result = invoke(f);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /migration source hash differs/);
    assert.equal(fs.existsSync(f.output), false);
  } finally {
    f.cleanup();
  }
});

test('fails when the reviewed catalog apply order drifts', () => {
  const f = fixture();
  try {
    [f.catalog[0], f.catalog[1]] = [f.catalog[1], f.catalog[0]];
    fs.writeFileSync(f.catalogPath, JSON.stringify(f.catalog));
    const result = invoke(f);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /catalog order or identity\/hash contract drifted/);
  } finally {
    f.cleanup();
  }
});

test('fails on migration file-set or hosted applied-baseline drift', async t => {
  await t.test('extra SQL file', () => {
    const f = fixture();
    try {
      fs.writeFileSync(path.join(f.migrations, '20260921999999_unreviewed.sql'), 'select 1;\n');
      const result = invoke(f);
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /migration source file set differs/);
    } finally {
      f.cleanup();
    }
  });

  await t.test('missing hosted full identity', () => {
    const f = fixture();
    try {
      const hosted = JSON.parse(fs.readFileSync(f.hostedPath, 'utf8'));
      hosted.applied.pop();
      fs.writeFileSync(f.hostedPath, JSON.stringify(hosted));
      const result = invoke(f);
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /exactly 117 entries/);
    } finally {
      f.cleanup();
    }
  });
});
