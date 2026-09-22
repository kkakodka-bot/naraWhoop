import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { prepare, publish, readRelease, validateRelease, verifyImage, imageReference, hash, runCommand, deployPinned } from './scorer-image-release.mjs';
import { fixture, releaseFixture } from './sync-evidence-fixtures.mjs';
import { verifyEvidence } from './verify-sync-evidence.mjs';

const scripts = path.dirname(fileURLToPath(import.meta.url));
const bytes = value => Buffer.from(JSON.stringify(value, null, 2) + '\n');
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
  for (const name of ['deploy-scoring-service.sh', 'scorer-image-release.mjs', 'sync-evidence-contract.mjs']) fs.copyFileSync(path.join(scripts, name), path.join(dir, name));
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

test('actual deployment entrypoint supports pinned and legacy modes on a PATH containing only mocks', t => {
  const root = local(t), repo = path.join(root, 'repo'), dir = path.join(repo, 'infra/vps/scripts');
  fs.mkdirSync(dir, { recursive: true });
  for (const name of ['deploy-scoring-service.sh', 'scorer-image-release.mjs', 'sync-evidence-contract.mjs']) fs.copyFileSync(path.join(scripts, name), path.join(dir, name));
  const f = releaseFixture(path.join(root, 'release'));
  fs.writeFileSync(path.join(repo, 'infra/vps/droplet.env'), 'DROPLET_IP=fixture.invalid\n');
  fs.mkdirSync(path.join(repo, 'infra/vps/keys')); fs.writeFileSync(path.join(repo, 'infra/vps/keys/frwhoop_deploy'), 'SYNTHETIC KEY');
  const hosts = path.join(root, 'known-hosts'); fs.writeFileSync(hosts, 'SYNTHETIC HOSTS');
  const bin = path.join(root, 'bin'); fs.mkdirSync(bin); fs.symlinkSync(process.execPath, path.join(bin, 'node')); fs.symlinkSync('/usr/bin/dirname', path.join(bin, 'dirname'));
  const record = path.join(root, 'calls.jsonl');
  for (const name of ['ssh', 'scp', 'rsync']) fs.writeFileSync(path.join(bin, name), `#!${process.execPath}\n
    const fs=require('node:fs'); const args=process.argv.slice(2); const command=args.at(-1);
    const stdin=fs.readFileSync(0,'utf8');
    fs.appendFileSync(${JSON.stringify(record)},JSON.stringify({program:${JSON.stringify(name)},args,stdin})+'\\n');
    if(command.includes('ps -q')) process.stdout.write('${'c'.repeat(64)}\\n');
    else if(command.startsWith('docker image inspect')) process.stdout.write(${JSON.stringify(JSON.stringify(f.inspection))});
    else if(command.startsWith('docker inspect --type container')) process.stdout.write(${JSON.stringify(JSON.stringify({ id: 'c'.repeat(64), running: true, imageId: f.release.image.configId, imageReference: f.release.image.reference }))});
  `, { mode: 0o700 });
  const env = { PATH: bin, TMPDIR: root, SCORER_KNOWN_HOSTS: hosts };
  const invoke = args => {
    fs.writeFileSync(record, '');
    const r = spawnSync('/bin/bash', [path.join(dir, 'deploy-scoring-service.sh'), ...args], { env, encoding: 'utf8', timeout: 10_000 });
    assert.equal(r.status, 0, r.stderr); assert.equal(r.signal, null);
    return { ...r, calls: fs.readFileSync(record, 'utf8').trim().split('\n').map(JSON.parse) };
  };
  const pinned = invoke(['--image-manifest', f.filename]);
  assert.match(pinned.stdout, /PINNED_DEPLOYMENT_SELECTED/); assert.match(pinned.stdout, /NOT_READY/);
  assert.ok(pinned.calls.every(c => c.program === 'ssh'));
  assert.ok(pinned.calls.some(c => c.args.at(-1).endsWith('up -d --no-build --no-deps --pull never scoring')));
  assert.ok(pinned.calls.every(c => !c.args.at(-1).includes('docker build')));
  const legacy = invoke([]);
  assert.match(legacy.stderr, /Legacy mutable-image deployment: NOT_READY/);
  assert.deepEqual(legacy.calls.map(c => c.program), ['ssh', 'rsync', 'rsync', 'scp', 'ssh']);
  assert.match(legacy.calls.at(-1).stdin, /docker build -t frwhoop\/scoring-service:latest/);
  assert.match(legacy.calls.at(-1).stdin, /docker-compose\.scoring\.yml up -d scoring/);
});

test('actual Dockerfile final stage has revision and optional legacy-compatible base arguments', () => {
  const dockerfile = fs.readFileSync(path.resolve(scripts, '../../../scoring-service/Dockerfile'), 'utf8');
  assert.match(dockerfile, /ARG BUILD_IMAGE=eclipse-temurin:17-jdk-jammy/);
  assert.match(dockerfile, /ARG RUNTIME_IMAGE=eclipse-temurin:17-jre-jammy/);
  assert.match(dockerfile, /FROM \$\{RUNTIME_IMAGE\}\nARG VCS_REF\nLABEL org\.opencontainers\.image\.revision="\$\{VCS_REF\}"/);
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
