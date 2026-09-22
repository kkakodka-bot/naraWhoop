import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  DEPLOYABLE_ROLES,
  INCLUDED_ROOTS,
  prepareEdgeSourceBundle,
  sha256Hex,
  verifyEdgeSourceBundle,
} from './edge-source-bundle.mjs';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const command = path.join(testDirectory, 'edge-source-bundle.mjs');

function git(repository, args) {
  const result = spawnSync('git', ['-C', repository, ...args], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}

function write(repository, relative, bytes, mode = 0o644) {
  const filename = path.join(repository, ...relative.split('/'));
  fs.mkdirSync(path.dirname(filename), { recursive: true });
  fs.writeFileSync(filename, bytes, { mode });
  fs.chmodSync(filename, mode);
}

function fixture() {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'frwhoop-edge-bundle-'));
  const repository = path.join(directory, 'repository');
  fs.mkdirSync(repository);
  git(repository, ['init', '--quiet']);
  git(repository, ['config', 'user.name', 'Edge Bundle Test']);
  git(repository, ['config', 'user.email', 'edge-bundle@example.invalid']);

  write(repository, 'supabase/config.toml', 'project_id = "committed"\n');
  write(repository, 'supabase/functions/deno.lock', '{"version":"4"}\n');
  write(repository, 'supabase/functions/_shared/helper.ts', 'export const committed = true;\n', 0o755);
  write(repository, 'supabase/functions/_shared/tests/helper_test.ts', 'throw new Error("never bundle tests");\n');
  write(repository, 'supabase/functions/_shared/docs/example.ts', 'throw new Error("never bundle docs");\n');
  write(repository, 'supabase/functions/_shared/README.md', '# Never bundle documentation\n');
  for (const role of DEPLOYABLE_ROLES) {
    write(repository, `supabase/functions/${role}/index.ts`, `export const role = ${JSON.stringify(role)};\n`);
  }
  git(repository, ['add', 'supabase']);
  git(repository, ['commit', '--quiet', '-m', 'fixture']);
  const commitSha = git(repository, ['rev-parse', 'HEAD']);
  const treeSha = git(repository, ['rev-parse', 'HEAD^{tree}']);
  const cleanup = () => fs.rmSync(directory, { recursive: true, force: true });
  return { directory, repository, commitSha, treeSha, cleanup };
}

function copyBundle(source, destination) {
  fs.cpSync(source, destination, { recursive: true, preserveTimestamps: true });
  return destination;
}

test('prepares deterministic exact committed Edge bytes without tests or documentation', () => {
  const f = fixture();
  try {
    write(f.repository, 'supabase/config.toml', 'project_id = "dirty-worktree"\n');
    const first = path.join(f.directory, 'bundle-a');
    const second = path.join(f.directory, 'bundle-b');
    const firstManifest = prepareEdgeSourceBundle({
      repoRoot: f.repository,
      commitSha: f.commitSha,
      outputDirectory: first,
    });
    const secondManifest = prepareEdgeSourceBundle({
      repoRoot: f.repository,
      commitSha: f.commitSha,
      outputDirectory: second,
    });

    assert.deepEqual(secondManifest, firstManifest);
    assert.equal(firstManifest.schemaVersion, 1);
    assert.equal(firstManifest.kind, 'frwhoop-edge-bundle');
    assert.deepEqual(firstManifest.source, { commit: f.commitSha, tree: f.treeSha });
    assert.deepEqual(firstManifest.deployableFunctions, DEPLOYABLE_ROLES);
    assert.deepEqual(firstManifest.includedRoots, INCLUDED_ROOTS);
    assert.equal(firstManifest.files.length, 9);
    assert.equal(fs.readFileSync(path.join(first, 'payload/supabase/config.toml'), 'utf8'),
      'project_id = "committed"\n');
    assert.equal(fs.statSync(path.join(first, 'payload/supabase/functions/_shared/helper.ts')).mode & 0o777, 0o755);
    assert.equal(firstManifest.files.some((file) => /(?:README|tests|docs)/.test(file.path)), false);
    assert.equal(fs.existsSync(path.join(first, 'payload/supabase/functions/_shared/tests')), false);
    assert.equal(fs.readFileSync(path.join(first, 'edge-source-bundle-manifest.json'), 'utf8'),
      fs.readFileSync(path.join(second, 'edge-source-bundle-manifest.json'), 'utf8'));
    assert.deepEqual(fs.readFileSync(path.join(first, firstManifest.bundle.filename)),
      fs.readFileSync(path.join(second, secondManifest.bundle.filename)));
    assert.equal(firstManifest.bundle.sizeBytes, fs.statSync(path.join(first, firstManifest.bundle.filename)).size);
    assert.equal(firstManifest.bundle.sha256, sha256Hex(fs.readFileSync(path.join(first, firstManifest.bundle.filename))));
    assert.equal(verifyEdgeSourceBundle(first, {
      expectedBundleSha256: firstManifest.bundle.sha256,
    }).bundle.sha256, firstManifest.bundle.sha256);
  } finally {
    f.cleanup();
  }
});

test('offline verification rejects payload mutation, missing, extra, symlink, and role-set drift', async (t) => {
  const f = fixture();
  try {
    const pristine = path.join(f.directory, 'pristine');
    const manifest = prepareEdgeSourceBundle({
      repoRoot: f.repository,
      commitSha: f.commitSha,
      outputDirectory: pristine,
    });

    await t.test('mutated bytes', () => {
      const bundle = copyBundle(pristine, path.join(f.directory, 'mutated'));
      fs.appendFileSync(path.join(bundle, 'payload/supabase/functions/push/index.ts'), '// mutation\n');
      assert.throws(() => verifyEdgeSourceBundle(bundle), /file size differs: supabase\/functions\/push\/index\.ts/);
    });

    await t.test('missing file', () => {
      const bundle = copyBundle(pristine, path.join(f.directory, 'missing'));
      fs.rmSync(path.join(bundle, 'payload/supabase/functions/scores/index.ts'));
      assert.throws(() => verifyEdgeSourceBundle(bundle), /payload file set has missing or extra entries/);
    });

    await t.test('extra file', () => {
      const bundle = copyBundle(pristine, path.join(f.directory, 'extra'));
      write(path.join(bundle, 'payload'), 'supabase/functions/push/extra.ts', 'extra\n');
      assert.throws(() => verifyEdgeSourceBundle(bundle), /payload file set has missing or extra entries/);
    });

    await t.test('extra empty directory', () => {
      const bundle = copyBundle(pristine, path.join(f.directory, 'extra-directory'));
      fs.mkdirSync(path.join(bundle, 'payload/supabase/functions/push/empty'));
      assert.throws(() => verifyEdgeSourceBundle(bundle), /payload directory set has missing or extra entries/);
    });

    await t.test('symlink', () => {
      const bundle = copyBundle(pristine, path.join(f.directory, 'symlink'));
      const target = path.join(bundle, 'payload/supabase/functions/reconcile/index.ts');
      fs.rmSync(target);
      fs.symlinkSync('../push/index.ts', target);
      assert.throws(() => verifyEdgeSourceBundle(bundle), /payload contains a symlink/);
    });

    await t.test('role set', () => {
      const bundle = copyBundle(pristine, path.join(f.directory, 'roles'));
      const manifestPath = path.join(bundle, 'edge-source-bundle-manifest.json');
      const changed = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
      changed.deployableFunctions = changed.deployableFunctions.filter((role) => role !== 'scores');
      fs.writeFileSync(manifestPath, `${JSON.stringify(changed, null, 2)}\n`);
      assert.throws(() => verifyEdgeSourceBundle(bundle), /deployable function set or order differs/);
    });

    await t.test('recorded release identity', () => {
      assert.throws(() => verifyEdgeSourceBundle(pristine, { expectedBundleSha256: '0'.repeat(64) }),
        /differs from the expected release identity/);
      assert.equal(verifyEdgeSourceBundle(pristine, {
        expectedBundleSha256: manifest.bundle.sha256,
      }).bundle.sha256, manifest.bundle.sha256);
    });

    await t.test('tar mutation', () => {
      const bundle = copyBundle(pristine, path.join(f.directory, 'tar-mutated'));
      fs.appendFileSync(path.join(bundle, 'edge-source-bundle.tar'), Buffer.from([0]));
      assert.throws(() => verifyEdgeSourceBundle(bundle), /bundle tar size differs/);
    });
  } finally {
    f.cleanup();
  }
});

test('CLI requires a full commit SHA and verifies a prepared bundle offline', () => {
  const f = fixture();
  try {
    const rejected = spawnSync(process.execPath, [
      command, 'prepare', '--repo-root', f.repository, '--commit', f.commitSha.slice(0, 12),
      '--output', path.join(f.directory, 'rejected'),
    ], { encoding: 'utf8' });
    assert.notEqual(rejected.status, 0);
    assert.match(rejected.stderr, /full lowercase 40-character Git SHA/);

    const bundle = path.join(f.directory, 'cli-bundle');
    const prepared = spawnSync(process.execPath, [
      command, 'prepare', '--repo-root', f.repository, '--commit', f.commitSha, '--output', bundle,
    ], { encoding: 'utf8' });
    assert.equal(prepared.status, 0, prepared.stderr);
    const identity = JSON.parse(prepared.stdout);
    assert.equal(identity.status, 'prepared');

    const verified = spawnSync(process.execPath, [
      command, 'verify', '--bundle', bundle, '--expected-bundle-sha', identity.bundleSha256,
    ], { encoding: 'utf8' });
    assert.equal(verified.status, 0, verified.stderr);
    assert.equal(JSON.parse(verified.stdout).status, 'verified');
  } finally {
    f.cleanup();
  }
});
