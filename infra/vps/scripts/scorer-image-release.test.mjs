import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { prepare, publish, readRelease, validateRelease, verifyImage, imageReference, hash, runCommand, deployPinned } from './scorer-image-release.mjs';
import { fixture, releaseFixture, copyMigrationCatalog } from './sync-evidence-fixtures.mjs';
import { verifyEvidence } from './verify-sync-evidence.mjs';

const scripts = path.dirname(fileURLToPath(import.meta.url));
const bytes = value => Buffer.from(JSON.stringify(value, null, 2) + '\n');
const postgresClient = {
  reference: 'docker.io/library/postgres@sha256:aa90e97ee862e558111d34cfb8b2c4bec768c2b039fb791341686928560263b3',
  configDigest: 'sha256:79bd7c99e923138f136f8009d6bffa66e21e9d4fda5c0c561b00fc9c90cfe537',
  platform: 'linux/amd64', version: '17.11-alpine3.24',
};
const deploymentFingerprint = '5'.repeat(64);
const targetHostKeyLine = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcH';
const targetFingerprint = `SHA256:${'A'.repeat(43)}`;
const deploymentTarget = {
  ip: '192.0.2.10', sshPort: 22,
  sshHostPublicKey: { type: 'ssh-ed25519', line: targetHostKeyLine, fingerprint: targetFingerprint },
  deployPublicKeyFingerprint: targetFingerprint,
};
function local(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'scorer-image-offline-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return root;
}
function gitFixture(t) {
  const root = local(t), repo = path.join(root, 'repo'); fs.mkdirSync(repo);
  const git = (...args) => {
    const r = spawnSync('/usr/bin/git', args, { cwd: repo, env: { PATH: '/usr/bin:/bin',
      GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null', GIT_NO_LAZY_FETCH: '1' } });
    assert.equal(r.status, 0, r.stderr.toString()); return r.stdout.toString().trim();
  };
  git('init', '--quiet'); git('config', 'user.name', 'Synthetic Fixture'); git('config', 'user.email', 'fixture@example.invalid');
  const contents = new Map();
  const add = (name, content) => { const b = Buffer.from(content); contents.set(name, b); fs.mkdirSync(path.dirname(path.join(repo, name)), { recursive: true }); fs.writeFileSync(path.join(repo, name), b); };
  for (const name of ['Dockerfile', 'gradlew', 'gradle.properties', 'settings.gradle.kts', 'build.gradle.kts',
    'gradle/wrapper/gradle-wrapper.properties', 'service/build.gradle.kts', 'analytics-kernel/build.gradle.kts']) add(`scoring-service/${name}`, `synthetic ${name}\n`);
  add('scoring-service/gradle/wrapper/gradle-wrapper.jar', [0x50, 0x4b, 0x00, 0xff, 0x80, 0xc0]);
  for (const name of ['scoring-service/service/src/main/kotlin/Main.kt', 'scoring-service/analytics-kernel/src/main/kotlin/Kernel.kt',
    'android/app/src/main/java/com/noop/analytics/Twin.kt', 'android/app/src/test/java/com/noop/analytics/TwinTest.kt']) add(name, 'package synthetic\n');
  git('add', '.'); git('commit', '--quiet', '-m', 'synthetic local inputs');
  const commit = git('rev-parse', 'HEAD');
  fs.writeFileSync(path.join(root, 'native-log.txt'), 'SYNTHETIC TEST LOG');
  const native = { schemaVersion: 1, inputFiles: [...contents].filter(([name]) => name !== 'scoring-service/Dockerfile')
    .map(([name, b]) => ({ path: name, sha256: hash(b) })), reports: [{ path: 'native-log.txt', sha256: hash('SYNTHETIC TEST LOG') }] };
  fs.writeFileSync(path.join(root, 'native.json'), bytes(native));
  const args = { repo, commit, output: path.join(root, 'prepared'), platform: 'linux/amd64',
    buildImage: `fixture.invalid/jdk@sha256:${'1'.repeat(64)}`, runtimeImage: `fixture.invalid/jre@sha256:${'2'.repeat(64)}`,
    nativeEvidence: path.join(root, 'native.json') };
  return { root, repo, git, commit, add, contents, args, native };
}
function publisher(plan, { indexed = false, fault = '' } = {}) {
  const calls = [], config = `sha256:${'d'.repeat(64)}`;
  const child = bytes({ schemaVersion: 2, mediaType: 'application/vnd.oci.image.manifest.v1+json', config: { digest: config } });
  const childDigest = `sha256:${hash(child)}`;
  const descriptor = { mediaType: 'application/vnd.oci.image.manifest.v1+json', digest: childDigest,
    platform: { os: 'linux', architecture: 'amd64' } };
  const top = indexed ? bytes({ schemaVersion: 2, mediaType: 'application/vnd.oci.image.index.v1+json',
    manifests: fault === 'ambiguous' ? [descriptor, descriptor] : [descriptor,
      { ...descriptor, platform: { os: 'unknown', architecture: 'unknown' } }] }) : child;
  const registryDigest = `sha256:${hash(top)}`;
  const run = (program, args) => {
    calls.push({ program, args }); assert.equal(program, 'docker');
    if (args.join(' ') === 'buildx version') return Buffer.from('synthetic-buildx 1\n');
    if (args[1] === 'build') {
      assert.ok(args.includes('--push')); assert.ok(args.includes(`VCS_REF=${plan.source.commit}`));
      if (fault === 'build') throw new Error('NOT_READY: synthetic build failed');
      fs.writeFileSync(args[args.indexOf('--metadata-file') + 1], bytes({ 'containerimage.digest': registryDigest,
        'containerimage.config.digest': fault === 'config' ? `sha256:${'e'.repeat(64)}` : config }));
      return Buffer.from('synthetic pushed');
    }
    if (args[1] === 'imagetools') {
      const raw = args.at(-1).endsWith(registryDigest) ? top : child;
      return fault === 'descriptor' ? Buffer.from('{}') : Buffer.concat([raw, Buffer.from('\n')]);
    }
    if (args[0] === 'pull') { assert.ok(args.at(-1).includes('@sha256:')); return Buffer.from('synthetic pulled'); }
    if (args[0] === 'image') return bytes({ id: config, revision: fault === 'label' ? '' : plan.source.commit,
      os: 'linux', architecture: fault === 'platform' ? 'arm64' : 'amd64',
      repoDigests: fault === 'digest' ? [] : [`fixture.invalid/scorer@${registryDigest}`] });
    assert.fail(`unexpected mocked command ${JSON.stringify(args)}`);
  };
  return { run, calls };
}

test('prepare exports actual local commit bytes including binary wrapper, excluding dirty/untracked/generated/config files', t => {
  const f = gitFixture(t);
  f.add('scoring-service/.env', 'SYNTHETIC EXCLUDED'); f.add('android/app/build/Untracked.kt', 'SYNTHETIC EXCLUDED');
  f.add('scoring-service/service/src/main/kotlin/Main.kt', 'DIRTY COPY MUST NOT SHIP');
  const calls = [];
  const plan = prepare(f.args, (program, args, options) => { calls.push({ program, args }); return runCommand(program, args, options); });
  assert.ok(calls.every(c => c.program === 'git' && !c.args.some(a => ['fetch', 'clone', 'pull'].includes(a))));
  assert.deepEqual(fs.readFileSync(path.join(f.args.output, 'context/scoring-service/gradle/wrapper/gradle-wrapper.jar')),
    Buffer.from([0x50, 0x4b, 0x00, 0xff, 0x80, 0xc0]));
  assert.equal(fs.readFileSync(path.join(f.args.output, 'context/scoring-service/service/src/main/kotlin/Main.kt'), 'utf8'), 'package synthetic\n');
  assert.equal(fs.existsSync(path.join(f.args.output, 'context/scoring-service/.env')), false);
  assert.equal(fs.existsSync(path.join(f.args.output, 'context/android/app/build')), false);
  assert.equal(plan.source.commit, f.commit); assert.notEqual(plan.source.nativeInputSha256, plan.source.commit);
  assert.throws(() => prepare(f.args), /EEXIST/);
});
test('tracked excluded files are never read as blobs, and source symlinks fail before an export', t => {
  const f = gitFixture(t); f.add('scoring-service/local.properties', 'SYNTHETIC PRIVATE'); f.git('add', '.'); f.git('commit', '--quiet', '-m', 'excluded');
  f.args.commit = f.git('rev-parse', 'HEAD');
  const excluded = f.git('rev-parse', `${f.args.commit}:scoring-service/local.properties`), reads = [];
  prepare(f.args, (p, a, o) => { if (a.includes('blob')) reads.push(a.at(-1)); return runCommand(p, a, o); });
  assert.ok(!reads.includes(excluded));
  fs.symlinkSync('Main.kt', path.join(f.repo, 'scoring-service/service/src/main/kotlin/Alias.kt'));
  f.git('add', '.'); f.git('commit', '--quiet', '-m', 'symlink');
  assert.throws(() => prepare({ ...f.args, commit: f.git('rev-parse', 'HEAD'), output: path.join(f.root, 'symlink-out') }), /symlinks/);
});
test('partial/promisor/included Git metadata is rejected before object access and never fetches', t => {
  for (const key of ['remote.synthetic.promisor', 'extensions.partialClone', 'include.path']) {
    const f = gitFixture(t); f.git('config', key, key === 'include.path' ? '/does-not-exist/synthetic' : 'true');
    const calls = [];
    assert.throws(() => prepare(f.args, (p, a, o) => { calls.push(a); return runCommand(p, a, o); }), /partial|included/);
    assert.ok(calls.every(a => !a.includes('cat-file') && !a.includes('ls-tree') && !a.includes('fetch')));
    assert.equal(fs.existsSync(f.args.output), false);
  }
});
function linkedFixture(f) {
  const linked = path.join(f.root, 'linked');
  f.git('worktree', 'add', '--detach', linked, f.commit);
  return linked;
}
function rejectedBeforeObjects(f, repo, expected) {
  const calls = [];
  assert.throws(() => prepare({ ...f.args, repo }, (program, args, options) => {
    assert.equal(program, 'git'); calls.push(args); return runCommand(program, args, options);
  }), expected);
  assert.ok(calls.length > 0);
  assert.ok(calls.every(args => !args.some(a => ['cat-file', 'ls-tree', 'fetch', 'clone', 'pull'].includes(a)) &&
    !args.some(a => a.includes('^{tree}'))));
  assert.ok(calls.filter(args => args.includes('config')).every(args => args.includes('--no-includes')));
  assert.equal(fs.existsSync(f.args.output), false);
}
for (const perWorktree of [undefined, false, true]) test(`clean linked worktree exports exact bytes with worktreeConfig=${perWorktree}`, t => {
  const f = gitFixture(t);
  if (perWorktree !== undefined) f.git('config', 'extensions.worktreeConfig', String(perWorktree));
  const linked = linkedFixture(f);
  if (perWorktree) f.git('-C', linked, 'config', '--worktree', 'review.synthetic', 'local-only');
  const calls = [];
  const plan = prepare({ ...f.args, repo: linked }, (program, args, options) => {
    assert.equal(program, 'git'); calls.push(args); return runCommand(program, args, options);
  });
  assert.equal(plan.source.commit, f.commit);
  for (const [name, content] of f.contents) assert.deepEqual(fs.readFileSync(path.join(f.args.output, 'context', name)), content);
  const firstObject = calls.findIndex(args => args.includes('cat-file'));
  for (const scope of perWorktree ? ['--local', '--worktree'] : ['--local']) {
    const config = calls.findIndex(args => args.includes('config') && args.includes(scope));
    assert.ok(config >= 0 && config < firstObject);
    assert.ok(calls[config].includes('--no-includes'));
  }
  if (!perWorktree) assert.ok(calls.every(args => !args.includes('--worktree')));
});
for (const linked of [false, true]) {
  for (const key of ['include.path', 'includeIf.gitdir:/**.path', 'extensions.partialClone', 'remote.synthetic.promisor']) {
    test(`effective worktree ${key} rejects before object reads, linked=${linked}`, t => {
      const f = gitFixture(t);
      f.git('config', 'extensions.worktreeConfig', 'true');
      const repo = linked ? linkedFixture(f) : f.repo;
      const included = path.join(f.root, 'included.config');
      fs.writeFileSync(included, '[review]\n\tsynthetic = local-only\n');
      f.git('-C', repo, 'config', '--worktree', key, key.startsWith('include') ? included : 'true');
      rejectedBeforeObjects(f, repo, /included Git configuration|partial\/promisor/);
    });
  }
}
test('conditional include in common config rejects before object reads from a linked worktree', t => {
  const f = gitFixture(t), linked = linkedFixture(f), included = path.join(f.root, 'included.config');
  fs.writeFileSync(included, '[review]\n\tsynthetic = local-only\n');
  f.git('config', 'includeIf.gitdir:/**.path', included);
  rejectedBeforeObjects(f, linked, /included Git configuration/);
});
for (const linked of [false, true]) {
  for (const marker of ['info/alternates', 'pack/synthetic.promisor']) {
    test(`external/promisor object-store guard rejects ${marker} before object reads, linked=${linked}`, t => {
      const f = gitFixture(t), repo = linked ? linkedFixture(f) : f.repo;
      const externalObjects = path.join(f.root, 'external-objects');
      fs.mkdirSync(externalObjects);
      fs.writeFileSync(path.join(f.repo, '.git/objects', marker), marker === 'info/alternates' ? `${externalObjects}\n` : '');
      rejectedBeforeObjects(f, repo, /alternate\/promisor object stores/);
    });
  }
}
test('missing local object fails without fetching and malformed revision/base/platform never invokes a command', t => {
  const f = gitFixture(t), calls = [];
  assert.throws(() => prepare({ ...f.args, commit: 'f'.repeat(40) }, (p, a, o) => { calls.push(a); return runCommand(p, a, o); }), /command failed/);
  assert.ok(calls.every(a => !a.includes('fetch')));
  for (const override of [{ commit: 'abc' }, { commit: 'A'.repeat(40) }, { commit: f.commit + '\n' },
    { buildImage: 'temurin:17' }, { platform: 'linux/amd64\n' }]) {
    assert.throws(() => prepare({ ...f.args, ...override }, () => assert.fail('no command permitted')), /NOT_READY/);
  }
});
test('native byte identity and report bytes must match; source commit label alone never qualifies', t => {
  const f = gitFixture(t);
  f.native.inputFiles[0].sha256 = '0'.repeat(64); fs.writeFileSync(f.args.nativeEvidence, bytes(f.native));
  assert.throws(() => prepare(f.args), /native input bytes differ/); assert.equal(fs.existsSync(f.args.output), false);
  f.native.inputFiles[0].sha256 = hash(f.contents.get(f.native.inputFiles[0].path));
  fs.writeFileSync(f.args.nativeEvidence, bytes(f.native)); fs.writeFileSync(path.join(f.root, 'native-log.txt'), 'changed');
  assert.throws(() => prepare(f.args), /native report digest mismatch/);
});
for (const indexed of [false, true]) test(`mocked publish binds actual descriptor bytes to distinct config ID, index=${indexed}`, t => {
  const f = gitFixture(t), plan = prepare(f.args), runner = publisher(plan, { indexed });
  const output = path.join(f.root, 'release');
  const release = publish({ preparedFile: path.join(f.args.output, 'prepared.json'), output, repository: 'fixture.invalid/scorer' }, runner.run);
  assert.deepEqual(readRelease(path.join(output, 'release.json')), release);
  assert.notEqual(release.image.registryDigest, release.image.configId);
  assert.equal(runner.calls.filter(c => c.args[1] === 'build').length, 1);
  assert.ok(runner.calls.filter(c => c.args[1] === 'imagetools').every(c => c.args.at(-1).includes('@sha256:')));
  assert.ok(runner.calls.every(c => !c.args.includes('login')));
});
test('changed prepared bytes or extra files fail before any Docker command', t => {
  const f = gitFixture(t); prepare(f.args);
  fs.writeFileSync(path.join(f.args.output, 'context/scoring-service/.env'), 'EXCLUDED');
  const a = { preparedFile: path.join(f.args.output, 'prepared.json'), output: path.join(f.root, 'release'), repository: 'fixture.invalid/scorer' };
  assert.throws(() => publish(a, () => assert.fail('no Docker')), /inventory changed/);
  fs.unlinkSync(path.join(f.args.output, 'context/scoring-service/.env'));
  fs.writeFileSync(path.join(f.args.output, 'context/scoring-service/Dockerfile'), 'changed');
  assert.throws(() => publish(a, () => assert.fail('no Docker')), /bytes changed/);
});
test('publish builds a private captured byte snapshot even if the prepared directory changes afterward', t => {
  const f = gitFixture(t), plan = prepare(f.args), runner = publisher(plan);
  const original = 'package synthetic\n', name = 'scoring-service/service/src/main/kotlin/Main.kt';
  const release = publish({ preparedFile: path.join(f.args.output, 'prepared.json'), output: path.join(f.root, 'release'),
    repository: 'fixture.invalid/scorer' }, (program, args, options) => {
    if (args.join(' ') === 'buildx version') fs.writeFileSync(path.join(f.args.output, 'context', name), 'changed after capture');
    if (args[1] === 'build') {
      assert.equal(fs.readFileSync(path.join(args.at(-1), name), 'utf8'), original);
      assert.notEqual(args.at(-1), path.join(f.args.output, 'context'));
    }
    return runner.run(program, args, options);
  });
  assert.equal(release.source.contextSha256, plan.source.contextSha256);
});
for (const fault of ['build', 'config', 'descriptor', 'ambiguous', 'label', 'platform', 'digest']) test(`mocked publish ${fault} failure leaves no qualified release`, t => {
  const f = gitFixture(t), plan = prepare(f.args), runner = publisher(plan, { indexed: fault === 'ambiguous', fault });
  const output = path.join(f.root, 'release');
  assert.throws(() => publish({ preparedFile: path.join(f.args.output, 'prepared.json'), output, repository: 'fixture.invalid/scorer' }, runner.run), /NOT_READY/);
  assert.equal(fs.existsSync(path.join(output, 'release.json')), false);
});
test('release references/digests/metadata cannot substitute another source or platform', t => {
  const root = local(t), f = releaseFixture(root);
  for (const apply of [r => { r.source.commit = 'a'.repeat(40); }, r => { r.image.configId = `sha256:${'c'.repeat(64)}`; },
    r => { r.image.platform = 'linux/arm64'; }, r => { r.image.reference = 'fixture.invalid/scorer:latest'; },
    r => { r.source.nativeInputSha256 = 'c'.repeat(64); }, r => { r.artifacts.push(r.artifacts[0]); }]) {
    const value = structuredClone(f.release); apply(value); assert.throws(() => validateRelease(value, root), /NOT_READY/);
  }
  for (const value of ['', 'fixture.invalid/scorer:latest', 'x@sha256:' + 'a'.repeat(64), f.release.image.reference + '\n']) {
    assert.throws(() => imageReference(value), /NOT_READY/);
  }
});
test('schema2 packets require hash-bound image provenance matching existing independent server selectors', t => {
  const f = fixture(t);
  delete f.evidence.server.imageProvenanceArtifact;
  assert.throws(() => verifyEvidence(f.evidence, f.directory, f.now), /no verified artifact/);
  f.evidence.server.imageProvenanceArtifact = 'image-release/release.json';
  f.evidence.server.commit = 'a'.repeat(40);
  assert.throws(() => verifyEvidence(f.evidence, f.directory, f.now), /provenance differs/);
});
test('container labels are not an immutable-image label substitute', t => {
  const f = releaseFixture(local(t));
  for (const override of [{ revision: '' }, { revision: 'c'.repeat(40) }, { repoDigests: [] },
    { id: f.release.image.registryDigest }, { architecture: 'arm64' }]) {
    assert.throws(() => verifyImage({ ...f.inspection, ...override }, f.release.image), /NOT_READY/);
  }
  assert.doesNotThrow(() => verifyImage(f.inspection, f.release.image));
});
test('fixed command runner rejects nonzero, signal, timeout and oversized successful-looking output', () => {
  for (const script of ['process.stdout.write("{}");process.exit(1)', 'process.kill(process.pid,"SIGTERM")',
    'setInterval(()=>{},1000)', 'process.stdout.write("x".repeat(5*1024*1024))']) {
    assert.throws(() => runCommand(process.execPath, ['-e', script], { timeout: 200 }), /command failed/);
  }
});
test('actual deploy CLI rejects invalid image manifest before deployment configuration can execute', t => {
  const root = local(t), repo = path.join(root, 'repo'), dir = path.join(repo, 'infra/vps/scripts'); fs.mkdirSync(dir, { recursive: true });
  for (const name of ['deploy-scoring-service.sh', 'scorer-image-release.mjs', 'sync-evidence-contract.mjs', 'scoring-migration-catalog.mjs']) fs.copyFileSync(path.join(scripts, name), path.join(dir, name));
  copyMigrationCatalog(repo);
  fs.writeFileSync(path.join(repo, 'infra/vps/droplet.env'), 'echo CONFIG_EXECUTED; exit 88\n');
  fs.writeFileSync(path.join(root, 'bad.json'), '{}');
  const bin = path.join(root, 'bin'); fs.mkdirSync(bin); fs.symlinkSync(process.execPath, path.join(bin, 'node')); fs.symlinkSync('/usr/bin/dirname', path.join(bin, 'dirname'));
  const r = spawnSync('/bin/bash', [path.join(dir, 'deploy-scoring-service.sh'), '--image-manifest', path.join(root, 'bad.json')], { env: { PATH: bin }, encoding: 'utf8' });
  assert.equal(r.status, 3); assert.doesNotMatch(r.stdout + r.stderr, /CONFIG_EXECUTED/);
});
test('pinned deployment uses the exact digest, preserves pin, never rebuilds or starts dependencies', t => {
  const root = local(t), f = releaseFixture(path.join(root, 'release'));
  const key = path.join(root, 'key'), knownHosts = path.join(root, 'known-hosts'); fs.writeFileSync(key, 'SYNTHETIC'); fs.writeFileSync(knownHosts, 'SYNTHETIC');
  const calls = [], retained = new Map();
  const run = (program, args, options = {}) => {
    assert.equal(program, 'ssh'); const command = args.at(-1); calls.push(command);
    assert.doesNotMatch(command, /docker build|rsync|:latest|\.Config.Env/);
    if (command.includes('ps -q')) return Buffer.from('c'.repeat(64) + '\n');
    if (command.startsWith('docker pull')) { assert.ok(command.includes(f.release.image.reference)); return Buffer.from(''); }
    if (command.startsWith('docker image inspect')) return bytes(f.inspection);
    if (command.startsWith('docker inspect --type container')) return bytes({ id: 'c'.repeat(64), running: true,
      imageId: f.release.image.configId, imageReference: f.release.image.reference });
    if (command.startsWith('umask')) { retained.set(command, options.input); return Buffer.from(''); }
    assert.ok(command.endsWith('up -d --no-build --no-deps --pull never scoring')); return Buffer.from('');
  };
  const result = deployPinned({ manifest: f.filename, host: 'fixture.invalid', key, knownHosts }, run);
  assert.equal(result.containerId, 'c'.repeat(64)); assert.match(result.productionReadiness, /NOT_READY/);
  assert.equal(retained.size, 2); assert.ok([...retained.values()].some(b => b.toString().includes(f.release.image.reference)));
  assert.equal(calls.filter(c => c.includes(' up ')).length, 1);
  assert.throws(() => deployPinned({ manifest: f.filename, host: 'fixture.invalid', key, knownHosts }, () => { throw new Error('NOT_READY: pull failed'); }), /NOT_READY/);
});

test('actual deployment verifies the aggregate plan before config or SSH and archives its exact source for all lanes', t => {
  const root = local(t), repo = path.join(root, 'repo'), dir = path.join(repo, 'infra/vps/scripts');
  fs.mkdirSync(dir, { recursive: true });
  for (const name of ['deploy-scoring-service.sh', 'scorer-image-release.mjs', 'sync-evidence-contract.mjs', 'scoring-migration-catalog.mjs']) fs.copyFileSync(path.join(scripts, name), path.join(dir, name));
  copyMigrationCatalog(repo);
  const f = releaseFixture(path.join(root, 'release'));
  fs.writeFileSync(path.join(repo, 'infra/vps/droplet.env'), 'DROPLET_IP=fixture.invalid\n');
  fs.mkdirSync(path.join(repo, 'infra/vps/keys'));
  fs.writeFileSync(path.join(repo, 'infra/vps/keys/frwhoop_deploy'), 'SYNTHETIC KEY', { mode: 0o600 });
  const hosts = path.join(root, 'known-hosts'); fs.writeFileSync(hosts, 'SYNTHETIC HOSTS');
  const bin = path.join(root, 'bin'); fs.mkdirSync(bin); fs.symlinkSync('/usr/bin/dirname', path.join(bin, 'dirname'));
  const record = path.join(root, 'calls.jsonl');
  const v1 = `registry.invalid/frwhoop-v1@sha256:${'1'.repeat(64)}`;
  const v2 = `registry.invalid/frwhoop-v2@sha256:${'2'.repeat(64)}`;
  const v1Config = `sha256:${'3'.repeat(64)}`, v2Config = `sha256:${'4'.repeat(64)}`;
  fs.writeFileSync(path.join(bin, 'node'), `#!${process.execPath}\n
    const fs=require('node:fs'), cp=require('node:child_process'); const args=process.argv.slice(2);
    if(args[0]?.endsWith('/Tools/release/release-artifact-manifest.mjs') && args[1]==='verify-deployment') {
      fs.appendFileSync(${JSON.stringify(record)},JSON.stringify({program:'release-verifier',args,stdin:''})+'\\n');
      if(process.env.PLAN_REJECT==='1') { process.stderr.write('NOT_READY: synthetic deployment binding differs\\n'); process.exit(1); }
      process.stdout.write(JSON.stringify({status:'WORKER_DEPLOYMENT_VERIFIED',scope:'full-fleet',sourceSha:'${'a'.repeat(40)}',sourceTree:'${'b'.repeat(40)}',fingerprint:${JSON.stringify(deploymentFingerprint)},
        selectedV1:{reference:process.env.MALICIOUS_REF||${JSON.stringify(v1)},configDigest:${JSON.stringify(v1Config)}},
        shadowV2:{reference:${JSON.stringify(v2)},configDigest:${JSON.stringify(v2Config)}},
        postgresqlClient:${JSON.stringify(postgresClient)},target:${JSON.stringify(deploymentTarget)}})+'\\n');
    } else {
      const child=cp.spawnSync(${JSON.stringify(process.execPath)},args,{stdio:'inherit'}); process.exit(child.status ?? 1);
    }
  `, { mode: 0o700 });
  for (const name of ['ssh', 'scp', 'rsync', 'python3', 'git', 'ssh-keygen']) fs.writeFileSync(path.join(bin, name), `#!${process.execPath}\n
    const fs=require('node:fs'); const args=process.argv.slice(2); const command=args.at(-1);
    const stdin=fs.readFileSync(0,'utf8');
    fs.appendFileSync(${JSON.stringify(record)},JSON.stringify({program:${JSON.stringify(name)},args,stdin})+'\\n');
    if(${JSON.stringify(name)}==='python3'&&args.includes('-c')) process.stdout.write('11111111-1111-4111-8111-111111111111\\n');
    else if(${JSON.stringify(name)}==='python3') process.stdout.write('fixture.invalid|22\\n');
    else if(${JSON.stringify(name)}==='ssh-keygen') process.stdout.write('256 ${targetFingerprint} synthetic (ED25519)\\n');
    else if(${JSON.stringify(name)}==='git'&&args.includes('rev-parse'))
      process.stdout.write((args.some(value=>value.endsWith('^{tree}'))?'${'b'.repeat(40)}':'${'a'.repeat(40)}')+'\\n');
    else if(${JSON.stringify(name)}==='git'&&args.includes('archive')) process.stdout.write('EXACT_COMMITTED_ARCHIVE');
    else if(${JSON.stringify(name)}==='ssh'&&command.includes('FRWHOOP_TARGET_IDENTITY_OBSERVED_'))
      process.stdout.write(command.match(/FRWHOOP_TARGET_IDENTITY_OBSERVED_[0-9a-f]{64}/)[0]+'\\n');
    else if(command.includes('mktemp -d')) process.stdout.write('/opt/frwhoop/build/frwhoop-scoring/${'a'.repeat(40)}.aaaaaa\\n');
    else if(command.includes('ps -q')) process.stdout.write('${'c'.repeat(64)}\\n');
    else if(command.startsWith('docker image inspect')) process.stdout.write(${JSON.stringify(JSON.stringify(f.inspection))});
    else if(command.startsWith('docker inspect --type container')) process.stdout.write(${JSON.stringify(JSON.stringify({ id: 'c'.repeat(64), running: true, imageId: f.release.image.configId, imageReference: f.release.image.reference }))});
  `, { mode: 0o700 });
  const env = { PATH: `${bin}:/usr/bin:/bin`, TMPDIR: root, SCORER_KNOWN_HOSTS: hosts };
  const invoke = (args, expectedStatus = 0, extraEnv = {}) => {
    fs.writeFileSync(record, '');
    const r = spawnSync('/bin/bash', [path.join(dir, 'deploy-scoring-service.sh'), ...args],
      { env: { ...env, ...extraEnv }, encoding: 'utf8', timeout: 10_000 });
    assert.equal(r.status, expectedStatus, r.stderr); assert.equal(r.signal, null);
    const lines = fs.readFileSync(record, 'utf8').trim();
    return { ...r, calls: lines ? lines.split('\n').map(JSON.parse) : [] };
  };
  const pinned = invoke(['--image-manifest', f.filename], 3);
  assert.match(pinned.stdout, /IMAGE_PROVENANCE_VALIDATED/); assert.match(pinned.stderr, /single-worker self-hosted/);
  assert.deepEqual(pinned.calls, []); // No configs, dependency starts, or SSH before rejection.
  for (const args of [[], ['--release-manifest', 'aggregate.json', '--artifact-root', 'artifacts']]) {
    const rejected = invoke(args, 3);
    assert.match(rejected.stderr, /NOT_READY/); assert.deepEqual(rejected.calls, []);
  }
  const deploymentArgs = ['--release-manifest', path.join(root, 'aggregate.json'), '--artifact-root', root,
    '--worker-deployment', path.join(root, 'workers.json')];
  const rejected = invoke(deploymentArgs, 1, { PLAN_REJECT: '1' });
  assert.match(rejected.stderr, /deployment binding differs/);
  assert.deepEqual(rejected.calls.map(call => call.program), ['release-verifier']);
  const injected = invoke(deploymentArgs, 3,
    { MALICIOUS_REF: `registry.invalid/image;touch-pwned@sha256:${'1'.repeat(64)}` });
  assert.match(injected.stderr, /reference is invalid/);
  assert.deepEqual(injected.calls.map(call => call.program), ['release-verifier']);
  const exact = invoke(deploymentArgs);
  assert.match(exact.stdout, /Scoring scope complete: a{40} full-fleet; intake acceptance remains separately required/);
  assert.equal(exact.calls[0].program, 'release-verifier');
  assert.ok(exact.calls.every(c => !['rsync','scp'].includes(c.program)));
  const archive = exact.calls.find(c => c.program === 'git' && c.args.includes('archive'));
  assert.equal(archive.args[archive.args.indexOf('archive')+1], 'a'.repeat(40));
  for (const call of exact.calls.filter(c => c.program === 'git')) {
    assert.ok(call.args.includes('--no-replace-objects'));
    assert.ok(call.args.includes('core.hooksPath=/dev/null'));
    assert.ok(call.args.includes('protocol.allow=never'));
  }
  assert.ok(exact.calls.some(c => c.program === 'ssh' && c.stdin === 'EXACT_COMMITTED_ARCHIVE'));
  const remoteShells = exact.calls.filter(c => c.program === 'ssh' && c.args.includes('bash') && c.args.includes('-s'));
  const acquire = remoteShells.find(c => c.stdin.includes('mkdir "$lock"'));
  const release = remoteShells.find(c => c.stdin.includes('rm -rf -- "$lock"'));
  assert.ok(acquire);
  assert.ok(release);
  assert.ok(exact.calls.indexOf(acquire) < exact.calls.findIndex(c => c.program === 'git' && c.args.includes('archive')));
  assert.equal(exact.calls.at(-1), release);
  const lanes = exact.calls.filter(c => c.program === 'ssh' && c.args.includes('bash') && c.args.includes('-s') && c.args.length && c.stdin.includes('scoring_wait_for_progress'));
  assert.deepEqual(lanes.map(c => c.args[c.args.indexOf('--') + 3]),
    ['scoring-baseline-v1','scoring-physiology-v2','scoring-history']);
  for (const lane of lanes) {
    assert.doesNotMatch(lane.stdin, /docker build|scoring-service:latest|rsync/);
    assert.deepEqual(lane.args.slice(-9), [v1, v2, v1Config, v2Config,
      postgresClient.reference, postgresClient.configDigest, postgresClient.platform, postgresClient.version, 'full-fleet']);
    assert.match(lane.stdin, /SCORING_EXPECTED_IMAGE_ID/);
    assert.match(lane.stdin, /\.RepoDigests/);
    assert.doesNotMatch(lane.stdin, /docker start/);
    assert.match(lane.stdin, /ROLLBACK_BLOCKED/);
    assert.match(lane.stdin, /--check-config/);
    assert.ok(lane.stdin.indexOf('scoring_wait_for_progress') < lane.stdin.indexOf('docker update --restart unless-stopped'));
    assert.match(lane.stdin, /SCORING_REQUIRE_PUBLICATION=true/);
  }
  const fleet = remoteShells.find(c => c.stdin.includes('missing_planned='));
  assert.ok(fleet);
  assert.match(fleet.stdin, /last_score_at is not null/);
  assert.match(fleet.stdin, /RestartPolicy\.Name/);
  assert.match(fleet.stdin, /\["--history"\]/);
});

test('deployment session lock is retained on every incomplete path and released only after final verification', t => {
  const root = local(t), repo = path.join(root, 'repo'), dir = path.join(repo, 'infra/vps/scripts');
  fs.mkdirSync(dir, { recursive: true });
  fs.copyFileSync(path.join(scripts, 'deploy-scoring-service.sh'), path.join(dir, 'deploy-scoring-service.sh'));
  fs.mkdirSync(path.join(repo, 'infra/vps/keys'), { recursive: true });
  fs.writeFileSync(path.join(repo, 'infra/vps/droplet.env'), 'DROPLET_IP=192.0.2.10\nSSH_PORT=22\n');
  fs.writeFileSync(path.join(repo, 'infra/vps/keys/frwhoop_deploy'), 'SYNTHETIC KEY\n', { mode: 0o600 });

  const bin = path.join(root, 'bin'); fs.mkdirSync(bin);
  fs.symlinkSync('/usr/bin/dirname', path.join(bin, 'dirname'));
  const release = 'a'.repeat(40), tree = 'b'.repeat(40);
  const v1 = `registry.invalid/frwhoop-v1@sha256:${'1'.repeat(64)}`;
  const v2 = `registry.invalid/frwhoop-v2@sha256:${'2'.repeat(64)}`;
  const v1Config = `sha256:${'3'.repeat(64)}`, v2Config = `sha256:${'4'.repeat(64)}`;
  const uuid = '11111111-1111-4111-8111-111111111111';
  const stateFile = path.join(root, 'remote-state.json');

  fs.writeFileSync(path.join(bin, 'node'), `#!${process.execPath}\n
const cp=require('node:child_process');
const args=process.argv.slice(2);
if(args[0]?.endsWith('/Tools/release/release-artifact-manifest.mjs') && args[1]==='verify-deployment') {
  process.stdout.write(JSON.stringify({status:'WORKER_DEPLOYMENT_VERIFIED',scope:'full-fleet',sourceSha:'${release}',sourceTree:'${tree}',fingerprint:${JSON.stringify(deploymentFingerprint)},
    selectedV1:{reference:${JSON.stringify(v1)},configDigest:${JSON.stringify(v1Config)}},
    shadowV2:{reference:${JSON.stringify(v2)},configDigest:${JSON.stringify(v2Config)}},
    postgresqlClient:${JSON.stringify(postgresClient)},target:${JSON.stringify(deploymentTarget)}})+'\\n');
} else {
  const child=cp.spawnSync(${JSON.stringify(process.execPath)},args,{stdio:'inherit'});
  process.exit(child.status ?? 1);
}
`, { mode: 0o700 });

  fs.writeFileSync(path.join(bin, 'ssh-keygen'), `#!${process.execPath}\n
process.stdout.write('256 ${targetFingerprint} synthetic (ED25519)\\n');
`, { mode: 0o700 });

  fs.writeFileSync(path.join(bin, 'python3'), `#!${process.execPath}\n
const args=process.argv.slice(2);
process.stdout.write(args.includes('-c') ? '${uuid}\\n' : '192.0.2.10|22\\n');
`, { mode: 0o700 });

  fs.writeFileSync(path.join(bin, 'git'), `#!${process.execPath}\n
const args=process.argv.slice(2);
if(args.includes('rev-parse')) process.stdout.write((args.some(value=>value.endsWith('^{tree}'))?'${tree}':'${release}')+'\\n');
else if(args.includes('archive')) process.stdout.write('EXACT_COMMITTED_ARCHIVE');
else if(!args.includes('status')) process.exit(91);
`, { mode: 0o700 });

  fs.writeFileSync(path.join(bin, 'ssh'), `#!${process.execPath}\n
const fs=require('node:fs');
const args=process.argv.slice(2), input=fs.readFileSync(0,'utf8'), scenario=process.env.LOCK_SCENARIO;
const filename=process.env.REMOTE_STATE;
const state=JSON.parse(fs.readFileSync(filename,'utf8'));
const separator=args.indexOf('--'), remote=separator<0?[]:args.slice(separator+1), token=remote[0]??null;
const command=args.at(-1);
const save=()=>fs.writeFileSync(filename,JSON.stringify(state)+'\\n');
const event=(kind,extra={})=>state.events.push({kind,owner:state.owner,...extra});
if(typeof command==='string' && command.includes('FRWHOOP_TARGET_IDENTITY_OBSERVED_')) {
  event('target-probe'); save();
  process.stdout.write(command.match(/FRWHOOP_TARGET_IDENTITY_OBSERVED_[0-9a-f]{64}/)[0]+'\\n'); process.exit(0);
} else if(input.includes('mkdir "$lock"')) {
  event('acquire',{token});
  if(state.owner!==null) { save(); process.exit(61); }
  state.owner=token; save(); process.exit(0);
}
if(typeof command==='string' && command.includes('mktemp -d')) {
  event('build-directory'); save();
  if(scenario==='sigterm') process.kill(process.ppid,'SIGTERM');
  setTimeout(()=>{ process.stdout.write('/opt/frwhoop/build/frwhoop-scoring/${release}.aaaaaa\\n'); process.exit(0); },25);
} else if(input.includes('scoring_wait_for_progress')) {
  const lane=remote[2]; event('lane',{lane}); save();
  if((scenario==='lane1'&&lane==='scoring-baseline-v1') ||
     (scenario==='lane2'&&lane==='scoring-physiology-v2')) process.exit(62);
  if(state.owner===null) process.exit(63);
  process.exit(0);
} else if(input.includes('selection_violations=')) {
  event('final-verify');
  if(scenario==='wrong-owner') state.owner='different-owner-token';
  save();
  if(scenario==='final') process.exit(64);
  if(state.owner===null) process.exit(65);
  process.exit(0);
} else if(input.includes('rm -rf -- "$lock"')) {
  event('unlock',{token}); save();
  if(scenario==='unlock-failure') process.exit(66);
  if(state.owner!==token) process.exit(67);
  state.owner=null; save(); process.exit(0);
} else if(typeof command==='string' && command.includes('tar -xf -')) {
  event('archive'); save();
  if(state.owner===null || input!=='EXACT_COMMITTED_ARCHIVE') process.exit(68);
  process.exit(0);
} else {
  event('unexpected',{command,input}); save(); process.exit(69);
}
`, { mode: 0o700 });

  const deploymentArgs = ['--release-manifest', path.join(root, 'aggregate.json'), '--artifact-root', root,
    '--worker-deployment', path.join(root, 'workers.json')];
  const invoke = (scenario) => {
    fs.writeFileSync(stateFile, JSON.stringify({ owner: null, events: [] }) + '\n');
    const result = spawnSync('/bin/bash', [path.join(dir, 'deploy-scoring-service.sh'), ...deploymentArgs], {
      env: { PATH: `${bin}:/usr/bin:/bin`, TMPDIR: root, LOCK_SCENARIO: scenario, REMOTE_STATE: stateFile },
      encoding: 'utf8', timeout: 10_000,
    });
    return { result, state: JSON.parse(fs.readFileSync(stateFile, 'utf8')) };
  };

  for (const [scenario, expectedLanes] of [['lane1', ['scoring-baseline-v1']],
    ['lane2', ['scoring-baseline-v1', 'scoring-physiology-v2']],
    ['final', ['scoring-baseline-v1', 'scoring-physiology-v2', 'scoring-history']]]) {
    const attempt = invoke(scenario);
    assert.notEqual(attempt.result.status, 0, scenario);
    assert.match(attempt.result.stderr, /DEPLOYMENT_LOCK_RETAINED/, scenario);
    assert.notEqual(attempt.state.owner, null, scenario);
    assert.deepEqual(attempt.state.events.filter(item => item.kind === 'lane').map(item => item.lane), expectedLanes);
    assert.equal(attempt.state.events.some(item => item.kind === 'unlock'), false, scenario);
  }

  const interrupted = invoke('sigterm');
  assert.equal(interrupted.result.status, 143, interrupted.result.stderr);
  assert.match(interrupted.result.stderr, /DEPLOYMENT_LOCK_RETAINED/);
  assert.notEqual(interrupted.state.owner, null);
    assert.deepEqual(interrupted.state.events.map(item => item.kind), ['target-probe', 'acquire', 'build-directory']);

  const wrongOwner = invoke('wrong-owner');
  assert.equal(wrongOwner.result.status, 1, wrongOwner.result.stderr);
  assert.match(wrongOwner.result.stderr, /lock could not be released/);
  assert.equal(wrongOwner.state.owner, 'different-owner-token');
  assert.equal(wrongOwner.state.events.at(-1).kind, 'unlock');
  assert.notEqual(wrongOwner.state.events.at(-1).token, wrongOwner.state.owner);

  const unlockFailure = invoke('unlock-failure');
  assert.equal(unlockFailure.result.status, 1, unlockFailure.result.stderr);
  assert.match(unlockFailure.result.stderr, /lock could not be released/);
  assert.notEqual(unlockFailure.state.owner, null);
  assert.equal(unlockFailure.state.events.at(-1).kind, 'unlock');
  assert.equal(unlockFailure.state.events.at(-1).token, unlockFailure.state.owner);

  const success = invoke('success');
  assert.equal(success.result.status, 0, success.result.stderr);
  assert.equal(success.state.owner, null);
  assert.deepEqual(success.state.events.filter(item => item.kind === 'lane').map(item => item.lane),
    ['scoring-baseline-v1', 'scoring-physiology-v2', 'scoring-history']);
  const kinds = success.state.events.map(item => item.kind);
  assert.ok(kinds.indexOf('final-verify') > kinds.lastIndexOf('lane'));
  assert.equal(kinds.at(-1), 'unlock');
  const acquireIndex = kinds.indexOf('acquire');
  for (const item of success.state.events.slice(acquireIndex + 1, -1)) assert.notEqual(item.owner, null, item.kind);
});

test('actual Dockerfile binds either release-tool revision and rejects contradictory source labels', () => {
  const dockerfile = fs.readFileSync(path.resolve(scripts, '../../../scoring-service/Dockerfile'), 'utf8');
  assert.match(dockerfile, /ARG BUILD_IMAGE=docker\.io\/library\/eclipse-temurin@sha256:e573c097106f35634857604fdfbe70a2a2bbcaa52574bca3d2025703d0df994d/);
  assert.match(dockerfile, /ARG RUNTIME_IMAGE=docker\.io\/library\/eclipse-temurin@sha256:24cd8eed18b5976441d27b45823490eb5e8efff4b3ecdc632e442717ea66f160/);
  assert.match(dockerfile, /ARG RELEASE_PLATFORM=linux\/amd64/);
  assert.match(dockerfile, /FROM --platform=\$\{RELEASE_PLATFORM\} \$\{BUILD_IMAGE\} AS build/);
  assert.match(dockerfile, /FROM --platform=\$\{RELEASE_PLATFORM\} \$\{RUNTIME_IMAGE\}/);
  assert.match(dockerfile, /ARG VCS_REF\nARG RELEASE_SHA=\$\{VCS_REF\}/);
  assert.match(dockerfile, /LABEL org\.opencontainers\.image\.revision=\$RELEASE_SHA/);
  assert.match(dockerfile, /io\.frwhoop\.algorithm\.roles="frwhoop-physiology-2,frwhoop-server-2-history"/);
  assert.match(dockerfile, /io\.frwhoop\.heartbeat\.contract="physiology_worker_heartbeats-v1"/);
  assert.match(dockerfile, /io\.frwhoop\.build\.image=\$BUILD_IMAGE/);
  assert.match(dockerfile, /io\.frwhoop\.runtime\.image=\$RUNTIME_IMAGE/);
  assert.match(dockerfile, /io\.frwhoop\.image\.platform=\$RELEASE_PLATFORM/);
  assert.match(dockerfile, /test -z "\$VCS_REF" \|\| test "\$VCS_REF" = "\$RELEASE_SHA"/);
  assert.match(dockerfile, /> \/app\/release.sha && chmod 444/);
  assert.match(dockerfile, /:service:installDist --no-daemon -x test -PscoringSourceRevision="\$RELEASE_SHA"/);
  assert.match(dockerfile, /ENTRYPOINT \["\/app\/bin\/service"\]/);
});

test('pinned pull/inspection/start/returned-container failures never select latest or return success', t => {
  for (const fault of ['pull', 'image', 'up', 'container']) {
    const root = local(t), f = releaseFixture(path.join(root, 'release'));
    const key = path.join(root, 'key'), knownHosts = path.join(root, 'hosts'); fs.writeFileSync(key, 'SYNTHETIC'); fs.writeFileSync(knownHosts, 'SYNTHETIC');
    const calls = [];
    assert.throws(() => deployPinned({ manifest: f.filename, host: 'fixture.invalid', key, knownHosts }, (program, args) => {
      assert.equal(program, 'ssh'); const c = args.at(-1); calls.push(c);
      assert.doesNotMatch(c, /:latest|docker build|rsync/);
      if (c.includes('ps -q')) return Buffer.from('c'.repeat(64) + '\n');
      if (c.startsWith('docker pull') && fault === 'pull') throw new Error('NOT_READY: synthetic pull failed');
      if (c.startsWith('docker image inspect')) return bytes({ ...f.inspection, ...(fault === 'image' ? { revision: '' } : {}) });
      if (c.includes(' up ') && fault === 'up') throw new Error('NOT_READY: synthetic up failed');
      if (c.startsWith('docker inspect --type container')) return bytes({ id: fault === 'container' ? 'd'.repeat(64) : 'c'.repeat(64),
        running: true, imageId: f.release.image.configId, imageReference: f.release.image.reference });
      return Buffer.from('');
    }), /NOT_READY/);
    if (fault === 'pull' || fault === 'image') assert.ok(calls.every(c => !c.includes(' up ')));
  }
});
