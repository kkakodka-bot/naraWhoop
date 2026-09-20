import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { fixture, sourceFixture } from './sync-evidence-fixtures.mjs';
import { candidateSelector, checkLive } from './check-sync-live.mjs';
import { REQUIRED_MIGRATIONS } from './sync-evidence-contract.mjs';
import { SUPPORTED_LEDGER_BASENAMES } from './sync-migration-ledger.mjs';

const scripts = path.dirname(fileURLToPath(import.meta.url));
function subprocessFixture(t) {
  const f = fixture(t), root = path.join(f.directory, 'fake-repo'), bin = path.join(f.directory, 'bin');
  const scriptDir = path.join(root, 'infra/vps/scripts');
  sourceFixture(root); fs.mkdirSync(scriptDir, { recursive: true }); fs.mkdirSync(bin);
  for (const name of ['phase3-acceptance-checks.sh', 'verify-sync-evidence.mjs', 'sync-evidence-contract.mjs', 'sync-migration-ledger.mjs', 'check-sync-sources.mjs', 'check-sync-live.mjs', 'scorer-image-release.mjs']) {
    fs.copyFileSync(path.join(scripts, name), path.join(scriptDir, name));
  }
  // PATH has NO system directory and thus no real SSH/Gradle fallback.
  fs.symlinkSync(process.execPath, path.join(bin, 'node'));
  fs.symlinkSync('/usr/bin/dirname', path.join(bin, 'dirname'));
  const writeExecutable = (filename, body) => fs.writeFileSync(filename, `#!${process.execPath}\n${body}\n`, { mode: 0o700 });
  const calls = path.join(f.directory, 'calls.jsonl');
  const recorder = `const fs = require('node:fs'); fs.appendFileSync(process.env.FIXTURE_CALLS, JSON.stringify({program: require('node:path').basename(process.argv[1]), args:process.argv.slice(2)})+'\\n');`;
  writeExecutable(path.join(bin, 'sleep'), `${recorder} process.exit(Number(process.env.FIXTURE_SLEEP_EXIT || 0));`);
  writeExecutable(path.join(bin, 'ssh'), `${recorder}
    const remote = process.argv.at(-1);
    if (remote.startsWith('docker inspect --type container ')) {
      const id = /'([0-9a-f]{64})'$/.exec(remote)?.[1];
      const containers = JSON.parse(fs.readFileSync(process.env.FIXTURE_CONTAINERS));
      // Resolve the exact ID, not a Compose service/name or queued successful reply.
      if (!id || containers.filter(c => c.id === id).length !== 1) process.exit(42);
    }
    const file=process.env.FIXTURE_RESPONSES; const responses=JSON.parse(fs.readFileSync(file));
    if (!responses.length) process.exit(99);
    const response=responses.shift(); fs.writeFileSync(file, JSON.stringify(responses));
    if (response.signal) process.kill(process.pid, response.signal);
    process.stdout.write(response.raw === undefined ? JSON.stringify(response.value) : response.raw);
    process.exit(response.exit || 0);`);
  for (const module of ['android', 'scoring-service']) {
    fs.mkdirSync(path.join(root, module), { recursive: true });
    writeExecutable(path.join(root, module, 'gradlew'), `${recorder}
      const n=fs.readFileSync(process.env.FIXTURE_CALLS,'utf8').trim().split('\\n').map(JSON.parse).filter(x=>x.program==='gradlew').length;
      process.exit(n === Number(process.env.FIXTURE_GRADLE_FAIL) ? 41 : 0);`);
  }
  const javaHome = path.join(f.directory, 'synthetic-jdk'); fs.mkdirSync(path.join(javaHome, 'bin'), { recursive: true });
  writeExecutable(path.join(javaHome, 'bin/java'), 'process.exit(0);');
  for (const name of ['droplet.env', 'secrets.env']) fs.writeFileSync(path.join(root, 'infra/vps', name), 'echo DEPLOYMENT_ENV_EXECUTED >&2\nexit 88\n');
  const key = path.join(f.directory, 'synthetic-key'), hosts = path.join(f.directory, 'synthetic-known-hosts');
  fs.writeFileSync(key, 'NOT A REAL KEY'); fs.writeFileSync(hosts, 'NOT A REAL HOST KEY');
  const c = f.evidence.canary;
  const replies = [
    { workItems: true, heartbeats: true, ingest: true }, [...REQUIRED_MIGRATIONS],
    { containerId: f.evidence.server.containerId, running: true, imageId: f.evidence.server.dockerImageId,
      imageReference: f.imageFixture.release.image.reference, revision: f.evidence.server.commit, ports: {}, networkMode: 'synthetic-internal' },
    [`fixture.invalid/scorer@${f.evidence.server.imageDigest}`],
    { lastPollAtMs: f.now - 20000, serverNowMs: f.now }, { lastPollAtMs: f.now - 1000, serverNowMs: f.now },
    { ownerUserId: c.ownerUserId, deviceId: c.deviceId, inputRevision: c.inputRevision, resultRevision: c.resultRevision,
      day: c.day, algorithmVersion: c.algorithmVersion, objectId: c.objectId, recordDigest: c.recordDigest,
      receiptState: 'verified_indexed', receiptOwner: c.ownerUserId, receiptDevice: c.deviceId, receiptObject: c.objectId, indexedBeforeComputed: true },
    f.imageFixture.inspection,
  ].map(value => ({ value }));
  const manifest = path.join(f.directory, 'evidence.json'), selector = path.join(f.directory, 'selector.json'), responses = path.join(f.directory, 'responses.json');
  const expected = candidateSelector(f.evidence);
  const containers = [{ id: f.evidence.server.containerId, name: 'synthetic-scoring-1', project: 'synthetic', service: 'scoring' },
    { id: 'd'.repeat(64), name: 'scoring', project: 'unrelated', service: 'scoring' }];
  const containerFile = path.join(f.directory, 'containers.json');
  const env = { PATH: bin, JAVA_HOME: javaHome, SYNC_ACCEPTANCE_EVIDENCE: manifest, SYNC_ACCEPTANCE_TARGET: selector,
    SYNC_ACCEPTANCE_SSH_KEY: key, SYNC_ACCEPTANCE_KNOWN_HOSTS: hosts, FIXTURE_CALLS: calls, FIXTURE_RESPONSES: responses,
    FIXTURE_CONTAINERS: containerFile };
  function run(mode, overrides = {}) {
    fs.writeFileSync(manifest, JSON.stringify(f.evidence)); fs.writeFileSync(selector, JSON.stringify(expected));
    fs.writeFileSync(responses, JSON.stringify(replies)); fs.writeFileSync(calls, '');
    fs.writeFileSync(containerFile, JSON.stringify(containers));
    const result = spawnSync('/bin/bash', [path.join(scriptDir, 'phase3-acceptance-checks.sh'), mode], {
      cwd: root, env: { ...env, ...overrides }, encoding: 'utf8', timeout: 10_000, maxBuffer: 1024 * 1024,
    });
    assert.equal(result.error, undefined);
    const output = result.stdout + result.stderr;
    assert.doesNotMatch(output, /DEPLOYMENT_ENV_EXECUTED/);
    const text = fs.readFileSync(calls, 'utf8').trim();
    return { ...result, output, calls: text ? text.split('\n').map(JSON.parse) : [] };
  }
  return { ...f, root, bin, scriptDir, replies, expected, containers, env, run };
}

test('preflight validates offline, never sources configs or executes native/remote commands', t => {
  const f = subprocessFixture(t); const r = f.run('--preflight');
  assert.equal(r.status, 0); assert.equal(r.calls.length, 0); assert.match(r.output, /EVIDENCE_VALIDATED/);
  const missing = f.run('--preflight', { SYNC_ACCEPTANCE_EVIDENCE: '' });
  assert.notEqual(missing.status, 0); assert.equal(missing.calls.length, 0); assert.match(missing.output, /NOT_READY/);
});
test('local success remains NOT_READY and invokes only the four synthetic native commands', t => {
  const f = subprocessFixture(t); const r = f.run('--local');
  assert.equal(r.status, 3); assert.match(r.output, /LOCAL_CHECKS_PASSED/);
  assert.deepEqual(r.calls.map(x => x.program), Array(4).fill('gradlew'));
  assert.match(r.output, /separate whole-day parity/);
});
test('each failed native command aborts before local success or remote checks', t => {
  const f = subprocessFixture(t);
  for (let n = 1; n <= 4; n++) {
    const r = f.run('--local', { FIXTURE_GRADLE_FAIL: String(n) });
    assert.notEqual(r.status, 0); assert.doesNotMatch(r.output, /LOCAL_CHECKS_PASSED/);
    assert.equal(r.calls.length, n); assert.match(r.output, /NOT_READY/);
  }
});
test('failed/missing scanner cannot be interpreted as clean', t => {
  const f = subprocessFixture(t); fs.unlinkSync(path.join(f.scriptDir, 'check-sync-sources.mjs'));
  const r = f.run('--local'); assert.notEqual(r.status, 0); assert.doesNotMatch(r.output, /LOCAL_CHECKS_PASSED/);
});
test('source policy failure stops shell and never reaches SSH', t => {
  const f = subprocessFixture(t);
  fs.writeFileSync(path.join(f.root, 'scoring-service/service/src/main/kotlin/Synthetic.kt'), 'import com.noop.data.WhoopDatabase\n');
  const r = f.run('--remote'); assert.notEqual(r.status, 0); assert.match(r.output, /forbidden import/);
  assert.ok(r.calls.every(call => call.program !== 'ssh'));
});
test('remote success binds reviewed selector, strict SSH identity, image and exact SQL revisions', t => {
  const f = subprocessFixture(t); const r = f.run('--remote');
  assert.equal(r.status, 0, r.output); assert.match(r.output, /READ_ONLY_CHECKS_PASSED/); assert.match(r.output, /NOT_READY/);
  const ssh = r.calls.filter(call => call.program === 'ssh'); assert.equal(ssh.length, 8);
  for (const call of ssh) {
    assert.ok(call.args.includes('StrictHostKeyChecking=yes')); assert.ok(call.args.includes('/dev/null'));
    assert.ok(call.args.includes('deploy@synthetic.invalid')); assert.doesNotMatch(call.args.at(-1), /\|\| true|\.Config.Env/);
    if (call.args.at(-1).includes('psql')) assert.match(call.args.at(-1), /-X -v ON_ERROR_STOP=1/);
    if (call.args.at(-1).includes('psql')) assert.match(call.args.at(-1), /default_transaction_read_only=on -c statement_timeout=10000/);
  }
  const query = ssh[6].args.at(-1);
  for (const text of ['s.input_revision=1', 's.result_revision=2', f.evidence.canary.ownerUserId, f.evidence.canary.deviceId, f.evidence.canary.objectId]) assert.ok(query.includes(text));
  assert.ok(ssh[2].args.at(-1).endsWith(` '${f.evidence.server.containerId}'`));
  assert.ok(ssh[2].args.at(-1).includes('{{json .Id}}'));
});

test('runner-basename ledger passes subprocess boundary and preserves exact raw rows in result', t => {
  const f = subprocessFixture(t);
  f.replies[1].value = [...SUPPORTED_LEDGER_BASENAMES];
  f.evidence.server.migrationLedgerRaw = [...SUPPORTED_LEDGER_BASENAMES];
  f.evidence.server.migrations = SUPPORTED_LEDGER_BASENAMES.map(name => name.slice(0, 14));
  const r = f.run('--remote'); assert.equal(r.status, 0, r.output);
  const result = JSON.parse(r.stdout.trim().split('\n').at(-1));
  assert.deepEqual(result.migrationLedger.observedRaw, SUPPORTED_LEDGER_BASENAMES);
  assert.deepEqual(result.migrationLedger.recordedRaw, f.evidence.server.migrationLedgerRaw);
  assert.deepEqual(result.migrationLedger.canonicalIDs, f.evidence.server.migrations);
});
test('live ledger rejects mixed-representation duplicates, arbitrary truncation and extra canonical IDs', t => {
  const f = subprocessFixture(t);
  const requiredNames = REQUIRED_MIGRATIONS.map(id => SUPPORTED_LEDGER_BASENAMES.find(name => name.startsWith(id + '_')));
  for (const ledger of [[...REQUIRED_MIGRATIONS, requiredNames[0]], [...requiredNames, requiredNames[0]],
    [requiredNames[0] + '.backup', ...requiredNames.slice(1)], [...REQUIRED_MIGRATIONS, '20260801000000'],
    ...requiredNames.map((_, missing) => requiredNames.filter((_, index) => index !== missing))]) {
    f.replies[1].value = ledger;
    const r = f.run('--remote'); assert.equal(r.status, 3); assert.match(r.output, /NOT_READY/);
    assert.equal(r.calls.filter(call => call.program === 'ssh').length, 2);
  }
});
test('generated Compose instance is inspected by ID even with an unrelated literal scoring container', t => {
  const f = subprocessFixture(t);
  assert.equal(f.containers[0].name, 'synthetic-scoring-1');
  const r = f.run('--remote'); assert.equal(r.status, 0, r.output);
  const command = r.calls.filter(call => call.program === 'ssh')[2].args.at(-1);
  assert.ok(command.endsWith(` '${f.containers[0].id}'`));
  assert.doesNotMatch(command, / scoring$|docker ps|head -1|rename/);
});
test('wrong-project service or unrelated literal scoring cannot replace missing exact container', t => {
  const f = subprocessFixture(t);
  f.containers.splice(0, 1); // Only the unrelated project/name remains.
  let r = f.run('--remote'); assert.equal(r.status, 3); assert.match(r.output, /scorer inspection command failed/);
  f.containers.length = 0;
  r = f.run('--remote'); assert.equal(r.status, 3); assert.match(r.output, /scorer inspection command failed/);
});
test('inspection must return the selected full ID even when image and provenance match', t => {
  const f = subprocessFixture(t);
  for (const id of ['d'.repeat(64), 'c'.repeat(12), '', null, 'C'.repeat(64)]) {
    f.replies[2].value.containerId = id;
    const r = f.run('--remote'); assert.equal(r.status, 3); assert.match(r.output, /container ID differs/);
  }
});

test('invalid manifest is rejected before any build or remote command', t => {
  const f = subprocessFixture(t); f.evidence.canary.inputRevision = '1';
  const r = f.run('--remote'); assert.equal(r.status, 3); assert.equal(r.calls.length, 0);
});
test('oversized manifest fails preflight without executing commands', t => {
  const f = subprocessFixture(t); f.evidence.syntheticPadding = 'x'.repeat(1024 * 1024);
  const r = f.run('--preflight'); assert.equal(r.status, 3); assert.equal(r.calls.length, 0); assert.match(r.output, /at most 1 MiB/);
});
test('signal and oversized command output fail closed', t => {
  const f = subprocessFixture(t);
  for (const reply of [{ signal: 'SIGTERM', value: {} }, { raw: 'x'.repeat(2 * 1024 * 1024) }]) {
    f.replies[0] = reply;
    const r = f.run('--remote'); assert.equal(r.status, 3); assert.match(r.output, /command failed/);
    assert.equal(r.calls.filter(call => call.program === 'ssh').length, 1);
  }
});
test('evidence expiring during inspection is rejected at completion', t => {
  const f = subprocessFixture(t);
  const responses = structuredClone(f.replies); let now = f.now;
  assert.throws(() => checkLive(f.evidence, f.directory, f.expected, () => {
    const reply = responses.shift();
    if (responses.length === 0) now += 16 * 60_000;
    return JSON.stringify(reply.value);
  }, () => {}, () => now), /collection window/);
});
test('missing explicit selector or SSH files abort before remote access', t => {
  const f = subprocessFixture(t);
  for (const field of ['SYNC_ACCEPTANCE_TARGET', 'SYNC_ACCEPTANCE_SSH_KEY', 'SYNC_ACCEPTANCE_KNOWN_HOSTS']) {
    const r = f.run('--remote', { [field]: '' }); assert.equal(r.status, 3, field);
    assert.ok(r.calls.every(call => call.program !== 'ssh'));
  }
});
test('empty or malformed Docker/canary output is not a successful inspection', t => {
  const f = subprocessFixture(t);
  for (const index of [2, 3, 6, 7]) {
    const reply = f.replies[index];
    for (const raw of ['', '{}\n{}', 'null', 'unexpected']) {
      f.replies[index] = { raw };
      assert.equal(f.run('--remote').status, 3, `${index}:${raw}`);
    }
    f.replies[index] = reply;
  }
});
test('every independently selected target field mismatch aborts before SSH', t => {
  const f = subprocessFixture(t);
  for (const key of Object.keys(f.expected)) {
    const value = f.expected[key]; f.expected[key] = typeof value === 'number' ? value + 1 : `${value}-different`;
    const r = f.run('--remote'); assert.equal(r.status, 3, key); assert.match(r.output, /operator target differs/);
    assert.ok(r.calls.every(call => call.program !== 'ssh'), key); f.expected[key] = value;
  }
});
for (let position = 0; position < 8; position++) {
  test(`failed SSH/psql/Docker inspection ${position + 1} stops even with successful-looking output`, t => {
    const f = subprocessFixture(t); f.replies[position].exit = position === 0 ? 255 : 1;
    const r = f.run('--remote'); assert.equal(r.status, 3); assert.match(r.output, /command failed/);
    assert.doesNotMatch(r.output, /READ_ONLY_CHECKS_PASSED/);
    assert.equal(r.calls.filter(call => call.program === 'ssh').length, position + 1);
  });
}
test('missing schema objects, absent/duplicate ledger IDs and malformed output fail closed', t => {
  const f = subprocessFixture(t), original = structuredClone(f.replies);
  for (const [index, reply] of [[0, { value: { workItems: false, heartbeats: true, ingest: true } }],
    [0, { raw: '' }], [1, { value: REQUIRED_MIGRATIONS.slice(1) }], [1, { value: [...REQUIRED_MIGRATIONS, REQUIRED_MIGRATIONS[0]] }],
    [1, { raw: 'psql error' }]]) {
    f.replies[index] = reply;
    const r = f.run('--remote'); assert.equal(r.status, 3); assert.doesNotMatch(r.output, /READ_ONLY_CHECKS_PASSED/);
    f.replies[index] = structuredClone(original[index]);
  }
});
test('running image/config revision/registry digest and port inspection are all mandatory', t => {
  const f = subprocessFixture(t), original = structuredClone(f.replies[2].value);
  for (const [key, value] of [['running', false], ['imageId', `sha256:${'c'.repeat(64)}`], ['revision', 'c'.repeat(40)],
    ['ports', null], ['ports', []], ['ports', { '8080/tcp': [{ HostIp: '0.0.0.0', HostPort: '8080' }] }],
    ['networkMode', 'host'], ['networkMode', 'container:another'], ['networkMode', null]]) {
    f.replies[2].value = { ...original, [key]: value };
    const r = f.run('--remote'); assert.equal(r.status, 3, key); assert.doesNotMatch(r.output, /READ_ONLY_CHECKS_PASSED/);
  }
  f.replies[2].value = original;
  for (const value of [[], null, ['fixture.invalid/scorer@sha256:' + 'c'.repeat(64)]]) {
    f.replies[3].value = value; assert.equal(f.run('--remote').status, 3);
  }
});
test('all live canary fields reject mismatches without revision/owner coercion', t => {
  const f = subprocessFixture(t), original = structuredClone(f.replies[6].value);
  for (const key of Object.keys(original)) {
    f.replies[6].value = { ...original, [key]: typeof original[key] === 'boolean' ? false : `${original[key]}-different` };
    const r = f.run('--remote'); assert.equal(r.status, 3, key); assert.match(r.output, /live canary receipt\/snapshot differs/);
  }
  f.replies[6] = { raw: '' }; assert.equal(f.run('--remote').status, 3);
});
test('immutable image metadata and configured digest pin remain mandatory even with correct container labels', t => {
  const f = subprocessFixture(t);
  f.replies[2].value.imageReference = 'fixture.invalid/scorer:latest';
  let r = f.run('--remote'); assert.equal(r.status, 3); assert.match(r.output, /reviewed image pin/);
  f.replies[2].value.imageReference = f.imageFixture.release.image.reference;
  const original = structuredClone(f.replies[7].value);
  for (const override of [{ revision: null }, { revision: 'd'.repeat(40) }, { architecture: 'arm64' },
    { id: f.evidence.server.imageDigest }, { repoDigests: [] }, { repoDigests: ['another.invalid/scorer@' + f.evidence.server.imageDigest] }]) {
    f.replies[7].value = { ...original, ...override };
    r = f.run('--remote'); assert.equal(r.status, 3); assert.doesNotMatch(r.output, /READ_ONLY_CHECKS_PASSED/);
    assert.equal(r.calls.filter(c => c.program === 'ssh').length, 8);
  }
});
test('stale, nonadvancing, malformed or wrong-clock live heartbeats cannot pass', t => {
  const f = subprocessFixture(t), original = structuredClone(f.replies[5].value);
  for (const value of [{ ...original, lastPollAtMs: f.now - 20000 }, { ...original, lastPollAtMs: f.now - 86400_000 },
    { ...original, lastPollAtMs: String(f.now) }, { ...original, serverNowMs: f.now + 86400_000 }]) {
    f.replies[5].value = value;
    const r = f.run('--remote'); assert.equal(r.status, 3); assert.match(r.output, /heartbeat/);
  }
  f.replies[5].value = original;
  assert.equal(f.run('--remote', { FIXTURE_SLEEP_EXIT: '1' }).status, 3);
});
