import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

import {
  INCLUDED_ROOTS,
  REQUIRED_CAPABILITIES,
  prepareDeploymentSourceBundle,
  verifyDeploymentSourceBundle,
} from './deployment-source-bundle.mjs';

function git(repo, args) {
  const result = spawnSync('git', ['-C', repo, ...args], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}
function write(repo, relative, bytes = 'fixture\n', mode = 0o644) {
  const filename = path.join(repo, ...relative.split('/'));
  fs.mkdirSync(path.dirname(filename), { recursive: true });
  fs.writeFileSync(filename, bytes, { mode }); fs.chmodSync(filename, mode);
}
function fixture() {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'frwhoop-deployment-bundle-'));
  const repo = path.join(directory, 'repo'); fs.mkdirSync(repo);
  git(repo, ['init', '--quiet']); git(repo, ['config', 'user.name', 'Bundle Test']);
  git(repo, ['config', 'user.email', 'bundle@example.invalid']);
  for (const paths of Object.values(REQUIRED_CAPABILITIES)) for (const relative of paths) {
    write(repo, relative, `committed:${relative}\n`, relative.endsWith('.sh') ? 0o755 : 0o644);
  }
  write(repo, 'infra/vps/tests/test_complete_surface.py');
  write(repo, 'infra/vps/templates/extra-compose.yml');
  write(repo, 'Tools/release/release-artifact-manifest.test.mjs');
  write(repo, 'Tools/release/ignored.txt', 'not selected\n');
  write(repo, 'Tools/release/nested/ignored.mjs', 'not selected\n');
  git(repo, ['add', '.']); git(repo, ['commit', '--quiet', '-m', 'fixture']);
  return { directory, repo, commit: git(repo, ['rev-parse', 'HEAD']), tree: git(repo, ['rev-parse', 'HEAD^{tree}']),
    cleanup: () => fs.rmSync(directory, { recursive: true, force: true }) };
}
function copy(source, destination) { fs.cpSync(source, destination, { recursive: true }); return destination; }

test('bundle is deterministic and reads exact committed bytes despite dirty worktree files', () => {
  const f = fixture();
  try {
    write(f.repo, 'infra/vps/scripts/deploy-scoring-service.sh', 'dirty\n', 0o755);
    const first = path.join(f.directory, 'first'), second = path.join(f.directory, 'second');
    const a = prepareDeploymentSourceBundle({ repoRoot: f.repo, commit: f.commit, outputDirectory: first });
    const b = prepareDeploymentSourceBundle({ repoRoot: f.repo, commit: f.commit, outputDirectory: second });
    assert.deepEqual(a, b);
    assert.deepEqual(a.source, { commit: f.commit, tree: f.tree });
    assert.equal(a.kind, 'frwhoop-deployment-source-bundle');
    assert.deepEqual(a.includedRoots, INCLUDED_ROOTS);
    assert.deepEqual(a.requiredCapabilities, REQUIRED_CAPABILITIES);
    assert.equal(fs.readFileSync(path.join(first, 'payload/infra/vps/scripts/deploy-scoring-service.sh'), 'utf8'),
      'committed:infra/vps/scripts/deploy-scoring-service.sh\n');
    assert.equal(a.files.some(file => file.path === 'infra/vps/tests/test_complete_surface.py'), true);
    assert.equal(a.files.some(file => file.path === 'Tools/release/release-artifact-manifest.test.mjs'), true);
    assert.equal(a.files.some(file => file.path.endsWith('ignored.txt') || file.path.includes('/nested/')), false);
    assert.deepEqual(fs.readFileSync(path.join(first, a.bundle.filename)), fs.readFileSync(path.join(second, b.bundle.filename)));
    assert.equal(verifyDeploymentSourceBundle(first, { expectedBundleSha256: a.bundle.sha256 }).bundle.sha256, a.bundle.sha256);
  } finally { f.cleanup(); }
});
test('preparation rejects a commit missing any semantic required path', () => {
  const f = fixture();
  try {
    fs.rmSync(path.join(f.repo, 'Tools/release/VerifyApk.java'));
    git(f.repo, ['add', '-u']); git(f.repo, ['commit', '--quiet', '-m', 'remove verifier']);
    const incomplete = git(f.repo, ['rev-parse', 'HEAD']);
    assert.throws(() => prepareDeploymentSourceBundle({
      repoRoot: f.repo, commit: incomplete, outputDirectory: path.join(f.directory, 'rejected'),
    }), /required mobileArtifactVerification source is missing: Tools\/release\/VerifyApk\.java/);
  } finally { f.cleanup(); }
});

test('offline verification rejects mutation, missing, extra, and symlink payloads', async t => {
  const f = fixture();
  try {
    const pristine = path.join(f.directory, 'pristine');
    prepareDeploymentSourceBundle({ repoRoot: f.repo, commit: f.commit, outputDirectory: pristine });
    await t.test('mutation', () => {
      const value = copy(pristine, path.join(f.directory, 'mutation'));
      fs.appendFileSync(path.join(value, 'payload/infra/vps/scripts/apply-migrations.sh'), 'changed\n');
      assert.throws(() => verifyDeploymentSourceBundle(value), /file bytes differ/);
    });
    await t.test('missing', () => {
      const value = copy(pristine, path.join(f.directory, 'missing'));
      fs.rmSync(path.join(value, 'payload/Tools/release/inspect_ipa.py'));
      assert.throws(() => verifyDeploymentSourceBundle(value), /payload file set has missing or extra entries/);
    });
    await t.test('extra', () => {
      const value = copy(pristine, path.join(f.directory, 'extra'));
      write(path.join(value, 'payload'), 'infra/vps/unrecorded.sh');
      assert.throws(() => verifyDeploymentSourceBundle(value), /payload file set has missing or extra entries/);
    });
    await t.test('symlink', () => {
      const value = copy(pristine, path.join(f.directory, 'symlink'));
      const filename = path.join(value, 'payload/infra/vps/templates/Dockerfile.baseline');
      fs.rmSync(filename); fs.symlinkSync('docker-compose.fleet.yml', filename);
      assert.throws(() => verifyDeploymentSourceBundle(value), /payload contains a symlink/);
    });
  } finally { f.cleanup(); }
});
