import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  ANDROID_INSPECTION_TOOLS,
  admissionEnvironment, atomicWrite, readPrivateJSON, validateAdmission,
  canonicalJSON,
  createWorkerDeployment as createWorkerDeploymentActual,
  compileIntakeCompose,
  intakeComposeContract,
  INTAKE_ENTRYPOINT,
  INTAKE_RUNTIME_IMAGE,
  inspectAapt2Version,
  inspectOCI,
  parseAndroidBadging,
  parseAndroidReleaseMetadata,
  POSTGRES_CLIENT,
  releaseInputFromManifest,
  sha256,
  validateLaunchCapacity,
  validateIOSExpectedIdentities,
  validateMigrationManifest,
  verifyAndroidInspectionTools,
  verifyBundleMatchesCommittedSource,
  verifyWorkerDeploymentContract,
} from './release-artifact-manifest.mjs';
import { prepareDeploymentSourceBundle } from './deployment-source-bundle.mjs';
import { generateMigrationManifest } from './generate-migration-manifest.mjs';

const REVISION = 'a'.repeat(40);
const BUILD_IMAGE = 'docker.io/library/eclipse-temurin@sha256:e573c097106f35634857604fdfbe70a2a2bbcaa52574bca3d2025703d0df994d';
const RUNTIME_IMAGE = 'docker.io/library/eclipse-temurin@sha256:24cd8eed18b5976441d27b45823490eb5e8efff4b3ecdc632e442717ea66f160';

function tarHeader(name, size) {
  const header = Buffer.alloc(512);
  header.write(name, 0, 100, 'utf8');
  header.write('0000644\0', 100, 8, 'ascii');
  header.write('0000000\0', 108, 8, 'ascii');
  header.write('0000000\0', 116, 8, 'ascii');
  header.write(size.toString(8).padStart(11, '0') + '\0', 124, 12, 'ascii');
  header.write('00000000000\0', 136, 12, 'ascii');
  header.fill(32, 148, 156);
  header[156] = '0'.charCodeAt(0);
  header.write('ustar\0', 257, 6, 'ascii');
  header.write('00', 263, 2, 'ascii');
  let checksum = 0;
  for (const byte of header) checksum += byte;
  header.write(checksum.toString(8).padStart(6, '0') + '\0 ', 148, 8, 'ascii');
  return header;
}
function tar(entries) {
  const chunks = [];
  for (const [name, bytes] of entries) {
    chunks.push(tarHeader(name, bytes.length), bytes);
    const padding = (512 - (bytes.length % 512)) % 512;
    if (padding) chunks.push(Buffer.alloc(padding));
  }
  chunks.push(Buffer.alloc(1024));
  return Buffer.concat(chunks);
}
const json = value => Buffer.from(JSON.stringify(value));
function ociFixture(role, mutateConfig = () => {}) {
  const provenance = {
    transport_patch_sha256: '1'.repeat(64),
    identity_patch_sha256: '2'.repeat(64),
  };
  const labels = {
    'org.opencontainers.image.revision': REVISION,
    'io.frwhoop.heartbeat.contract': 'physiology_worker_heartbeats-v1',
    'io.frwhoop.database.ca.sha256': '700723581420dd1ac98fd7e9ac529f0ef210eadcaf87fc868a3ad7d114c2f3b7',
    'io.frwhoop.build.image': BUILD_IMAGE,
    'io.frwhoop.runtime.image': RUNTIME_IMAGE,
    'io.frwhoop.image.platform': 'linux/amd64',
    ...(role === 'selected-v1' ? {
      'io.frwhoop.algorithm.version': 'frwhoop-server-1',
      'io.frwhoop.baseline.commit': '5caa31689da0023e111beb36850d3f81d67e1be2',
      'io.frwhoop.baseline.transport-sha256': provenance.transport_patch_sha256,
      'io.frwhoop.baseline.identity-sha256': provenance.identity_patch_sha256,
    } : {
      'io.frwhoop.algorithm.roles': 'frwhoop-physiology-2,frwhoop-server-2-history',
    }),
  };
  const configValue = { architecture: 'amd64', os: 'linux', config: { Labels: labels } };
  if (role === 'selected-v1') configValue.config.Env = ['JAVA_OPTS=-Xmx512m -XX:+UseContainerSupport'];
  if (role === 'intake') {
    configValue.config.Labels = {
      'org.opencontainers.image.revision': REVISION, 'org.frwhoop.worker.role': 'intake',
      'org.frwhoop.intake.contract-version': '2', 'io.frwhoop.runtime.image': INTAKE_RUNTIME_IMAGE,
      'io.frwhoop.image.platform': 'linux/amd64',
    };
    Object.assign(configValue.config, { User: 'deno', WorkingDir: '/app',
      Entrypoint: [...INTAKE_ENTRYPOINT], Cmd: [] });
  }
  mutateConfig(configValue);
  const config = json(configValue);
  const configDigest = 'sha256:' + sha256(config);
  const manifest = json({ schemaVersion: 2, mediaType: 'application/vnd.oci.image.manifest.v1+json',
    config: { mediaType: 'application/vnd.oci.image.config.v1+json', digest: configDigest, size: config.length }, layers: [] });
  const manifestDigest = 'sha256:' + sha256(manifest);
  const index = json({ schemaVersion: 2, mediaType: 'application/vnd.oci.image.index.v1+json', manifests: [{
    mediaType: 'application/vnd.oci.image.manifest.v1+json', digest: manifestDigest, size: manifest.length,
    platform: { architecture: 'amd64', os: 'linux' },
  }] });
  const bytes = tar([
    ['oci-layout', json({ imageLayoutVersion: '1.0.0' })],
    ['index.json', index],
    [`blobs/sha256/${manifestDigest.slice(7)}`, manifest],
    [`blobs/sha256/${configDigest.slice(7)}`, config],
  ]);
  const metadata = { 'containerimage.digest': manifestDigest, 'containerimage.config.digest': configDigest,
    'containerimage.descriptor': { digest: manifestDigest } };
  return { bytes, metadata, provenance, manifestDigest, configDigest };
}

for (const role of ['selected-v1', 'shadow-v2', 'intake']) test(`OCI inspection binds ${role} revision, platform, bases and role`, t => {
  const fixture = ociFixture(role), directory = fs.mkdtempSync(path.join(os.tmpdir(), 'release-oci-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const filename = path.join(directory, 'image.tar');
  fs.writeFileSync(filename, fixture.bytes);
  const result = inspectOCI(filename, role, REVISION, fixture.metadata,
    role === 'selected-v1' ? fixture.provenance : undefined);
  assert.equal(result.manifestDigest, fixture.manifestDigest);
  assert.equal(result.configDigest, fixture.configDigest);
  assert.equal(result.sourceRevision, REVISION);
});

test('OCI inspection rejects source/metadata substitutions and changed bytes', t => {
  const fixture = ociFixture('shadow-v2'), directory = fs.mkdtempSync(path.join(os.tmpdir(), 'release-oci-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const filename = path.join(directory, 'image.tar');
  fs.writeFileSync(filename, fixture.bytes);
  assert.throws(() => inspectOCI(filename, 'shadow-v2', 'b'.repeat(40), fixture.metadata), /NOT_READY/);
  assert.throws(() => inspectOCI(filename, 'shadow-v2', REVISION,
    { ...fixture.metadata, 'containerimage.digest': 'sha256:' + '0'.repeat(64) }), /NOT_READY/);
  const changed = Buffer.from(fixture.bytes);
  changed[0] ^= 1;
  fs.writeFileSync(filename, changed);
  assert.throws(() => inspectOCI(filename, 'shadow-v2', REVISION, fixture.metadata), /NOT_READY/);
});

test('worker OCI rejects a coherently rebuilt image with missing or substituted database trust', t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'release-worker-trust-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const filename = path.join(directory, 'image.tar');
  for (const role of ['selected-v1', 'shadow-v2']) for (const ca of [undefined, '0'.repeat(64)]) {
    const fixture = ociFixture(role, value => { value.config.Labels['io.frwhoop.database.ca.sha256'] = ca; });
    fs.writeFileSync(filename, fixture.bytes);
    assert.throws(() => inspectOCI(filename, role, REVISION, fixture.metadata,
      role === 'selected-v1' ? fixture.provenance : undefined), /database trust labels differ/);
  }
});

test('baseline OCI rejects expanded heap and alternate Java option overrides', t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'release-baseline-heap-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const filename = path.join(directory, 'image.tar');
  for (const environment of [[], ['JAVA_OPTS=-Xmx1g -XX:+UseContainerSupport'],
    ['JAVA_OPTS=-Xmx512m -XX:+UseContainerSupport', 'JAVA_TOOL_OPTIONS=-Xmx2g'],
    ['JAVA_OPTS=-Xmx512m -XX:+UseContainerSupport', '_JAVA_OPTIONS=-Xmx2g']]) {
    const fixture = ociFixture('selected-v1', value => { value.config.Env = environment; });
    fs.writeFileSync(filename, fixture.bytes);
    assert.throws(() => inspectOCI(filename, 'selected-v1', REVISION, fixture.metadata, fixture.provenance),
      /heap or Java override differs/);
  }
});

test('intake OCI rejects coherently rebuilt incompatible role, contract and runtime commands', t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'release-intake-oci-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const filename = path.join(directory, 'image.tar');
  for (const mutate of [
    value => { value.config.Labels['org.frwhoop.worker.role'] = 'shadow-v2'; },
    value => { value.config.Labels['org.frwhoop.intake.contract-version'] = '1'; },
    value => { value.config.Labels['io.frwhoop.runtime.image'] = 'denoland/deno:latest'; },
    value => { value.config.User = 'root'; },
    value => { value.config.WorkingDir = '/tmp'; },
    value => { value.config.Cmd = ['--once']; },
    value => { value.config.Entrypoint = ['sh', '-c']; },
    value => { value.architecture = 'arm64'; },
  ]) {
    const fixture = ociFixture('intake', mutate);
    fs.writeFileSync(filename, fixture.bytes);
    assert.throws(() => inspectOCI(filename, 'intake', REVISION, fixture.metadata), /NOT_READY/);
  }
});

test('compiled intake deployment rejects scope, privilege, command, resources and mutable image changes', () => {
  const release = releaseForDeployment();
  const v1 = `registry.invalid/frwhoop-v1@${release.artifacts.selectedV1.image.manifestDigest}`;
  const v2 = `registry.invalid/frwhoop-v2@${release.artifacts.shadowV2.image.manifestDigest}`;
  for (const mutate of [
    value => { value.reference = 'registry.invalid/frwhoop-intake:latest'; },
    value => { value.reference = v1; },
    value => { value.instanceId = 'not-a-uuid'; },
    value => { value.projectRef = 'differentproject1234'; },
    value => { value.compiledCompose.services['intake-consumer'].environment.INTAKE_WORKER_SOURCE_REVISION = 'b'.repeat(40); },
    value => { value.compiledCompose.services['intake-consumer'].environment.NOOP_ASYNC_OBJECT_VERIFICATION = '1'; },
    value => { value.compiledCompose.services['intake-consumer'].command = ['--status']; },
    value => { value.compiledCompose.services['intake-consumer'].privileged = true; },
    value => { value.compiledCompose.services['intake-consumer'].cpus = 4; },
    value => { value.compiledCompose.services['intake-consumer'].env_file.reverse(); },
    value => { value.compiledCompose.services['intake-consumer'].tmpfs = ['/tmp:rw', 'noexec', 'nosuid', 'size=64m']; },
  ]) {
    const intake = intakeForDeployment(release); mutate(intake);
    assert.throws(() => createWorkerDeployment(release, v1, v2, targetForDeployment(), intake), /NOT_READY/);
  }
});

test('actual Compose compilation binds committed template with isolated nonsecret env probes', t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'release-intake-compile-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const git = (...args) => {
    const result = spawnSync('git', ['-C', directory, ...args], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr); return result.stdout.trim();
  };
  git('init', '--quiet'); git('config', 'user.name', 'Intake Compile Test');
  git('config', 'user.email', 'fixture@example.invalid');
  const relative = 'infra/vps/templates/docker-compose.intake.yml';
  const filename = path.join(directory, relative);
  fs.mkdirSync(path.dirname(filename), { recursive: true });
  const template = fs.readFileSync(new URL('../../infra/vps/templates/docker-compose.intake.yml', import.meta.url), 'utf8');
  fs.writeFileSync(filename, template);
  git('add', relative); git('commit', '--quiet', '-m', 'fixture');
  const intake = intakeForDeployment(releaseForDeployment());
  const commit = git('rev-parse', 'HEAD');
  fs.writeFileSync(filename, 'dirty worktree is deliberately ignored\n');
  assert.deepEqual(compileIntakeCompose({ repoRoot: directory, commit, ...intake }),
    intakeComposeContract(intake.reference, commit, intake.instanceId, intake.projectRef, intake.admission));
  const privateConfig = path.join(directory, 'admission.json');
  const privateOutput = path.join(directory, 'compiled-private.json');
  atomicWrite(privateConfig, CANARY, 0o600);
  const cli = spawnSync(process.execPath, [fileURLToPath(new URL('./release-artifact-manifest.mjs', import.meta.url)),
    'compile-intake', '--repo-root', directory, '--commit', commit, '--intake-image', intake.reference,
    '--intake-instance-id', intake.instanceId, '--intake-project-ref', intake.projectRef,
    '--admission-config', privateConfig, '--output', privateOutput], {encoding:'utf8'});
  assert.equal(cli.status, 0, cli.stderr);
  assert.equal(fs.statSync(privateOutput).mode & 0o777, 0o600);
  assert.deepEqual(readPrivateJSON(privateOutput),
    intakeComposeContract(intake.reference, commit, intake.instanceId, intake.projectRef, CANARY));
  for (const value of [CANARY.ownerId, CANARY.deviceId]) assert.ok(!(cli.stdout + cli.stderr).includes(value));
  fs.writeFileSync(filename, template.replace('command: []', 'command: [--once]'));
  git('add', relative); git('commit', '--quiet', '-m', 'incompatible command');
  assert.throws(() => compileIntakeCompose({ repoRoot: directory, commit: git('rev-parse', 'HEAD'), ...intake }),
    /committed intake Compose differs/);
});

test('Android inspection parsers bind staging package/build and signed manifest release markers', () => {
  const badging = [
    "package: name='com.noop.whoop.staging' versionCode='450' versionName='11.1.1-staging' platformBuildVersionName='15'",
    "sdkVersion:'26'",
    "targetSdkVersion:'34'",
  ].join('\n');
  assert.deepEqual(parseAndroidBadging(badging), {
    applicationId: 'com.noop.whoop.staging', versionCode: 450, versionName: '11.1.1-staging', minSdk: 26, targetSdk: 34,
  });
  const xml = `    E: meta-data
      A: android:name="com.noop.release.source_revision"
      A: android:value="${REVISION}"
    E: meta-data
      A: android:name="com.noop.release.final_hosted_compute"
      A: android:value=true
`;
  assert.deepEqual(parseAndroidReleaseMetadata(xml, REVISION), { sourceRevision: REVISION, finalHostedCompute: true });
  assert.throws(() => parseAndroidReleaseMetadata(xml, 'b'.repeat(40)), /NOT_READY/);
});

test('aapt2 version inspection reads the exact reviewed version from stderr and rejects other output', t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'release-aapt2-version-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  let serial = 0;
  const tool = body => {
    const filename = path.join(directory, `aapt2-${serial++}`);
    fs.writeFileSync(filename, `#!/bin/sh\n${body}\n`);
    fs.chmodSync(filename, 0o755);
    return filename;
  };
  const expected = ANDROID_INSPECTION_TOOLS.aapt2.version;
  assert.equal(inspectAapt2Version(tool(`printf '%s\\n' '${expected}' >&2`)), expected);
  for (const body of [
    `printf '%s\\n' 'substituted aapt2' >&2`,
    `printf '%s\\n' '${expected}'`,
    `printf '%s\\n' 'unexpected stdout'; printf '%s\\n' '${expected}' >&2`,
    `printf '%s\\n' '${expected}' >&2; exit 17`,
  ]) assert.throws(() => inspectAapt2Version(tool(body)), /NOT_READY/);
});

test('Android semantic inspection accepts only the reviewed self-contained SDK tools', () => {
  const reviewed = {
    aapt2: { file: { path: 'tools/android-34/aapt2', sizeBytes: 1,
      sha256: ANDROID_INSPECTION_TOOLS.aapt2.sha256 }, version: ANDROID_INSPECTION_TOOLS.aapt2.version },
    apksigJar: { file: { path: 'tools/android-34/lib/apksigner.jar', sizeBytes: 1,
      sha256: ANDROID_INSPECTION_TOOLS.apksigJar.sha256 } },
  };
  assert.equal(verifyAndroidInspectionTools(reviewed), reviewed);
  for (const mutate of [
    value => { value.aapt2.file.sha256 = '0'.repeat(64); },
    value => { value.aapt2.version = 'substituted aapt2'; },
    value => { value.apksigJar.file.sha256 = '0'.repeat(64); },
    value => { value.apksigJar.file.path = '/tmp/unbound-apksigner.jar'; },
  ]) {
    const changed = structuredClone(reviewed); mutate(changed);
    assert.throws(() => verifyAndroidInspectionTools(changed), /NOT_READY/);
  }
});

test('aggregate regeneration input is derived only from bound artifact and tool paths', () => {
  const manifest = {
    source: { commit: REVISION },
    artifacts: {
      selectedV1: { file: { path: 'v1.tar' }, buildMetadata: { path: 'v1.json' },
        provenance: { path: 'v1-provenance.json' } },
      shadowV2: { file: { path: 'v2.tar' }, buildMetadata: { path: 'v2.json' } },
      intake: { file: { path: 'intake.tar' }, buildMetadata: { path: 'intake.json' } },
      android: { file: { path: 'app.apk' }, outputMetadata: { path: 'output-metadata.json' }, tools: {
        aapt2: { file: { path: 'tools/aapt2' } }, apksigJar: { file: { path: 'tools/apksigner.jar' } },
      } },
      ios: { file: { path: 'app.ipa' }, appGroup: 'group.example.noop',
        bundles: ['app', 'widget', 'watch', 'complication'].map(bundleIdentifier => ({ bundleIdentifier })) },
      edge: { file: { path: 'edge.tar' }, manifest: { path: 'edge.json' } },
      migrations: { file: { path: 'migrations.json' } },
      deployment: { file: { path: 'deployment.tar' }, manifest: { path: 'deployment.json' } },
    },
  };
  const input = releaseInputFromManifest(manifest);
  assert.equal(input.sourceSha, REVISION);
  assert.deepEqual(input.expected.iosBundleIdentifiers, ['app', 'widget', 'watch', 'complication']);
  assert.deepEqual(input.artifacts.android, {
    apk: 'app.apk', outputMetadata: 'output-metadata.json', aapt2: 'tools/aapt2',
    apksigJar: 'tools/apksigner.jar',
  });
  assert.equal(input.artifacts.migrations.manifest, 'migrations.json');
  assert.deepEqual(input.artifacts.intake, { oci: 'intake.tar', buildMetadata: 'intake.json' });
  assert.equal(input.artifacts.deployment.manifest, 'deployment.json');
});

test('iOS expected identities retain the committed phone/widget/watch/App Group topology', () => {
  const expected = {
    iosAppGroup: 'group.com.example.noop.staging',
    iosBundleIdentifiers: [
      'com.example.noop',
      'com.example.noop.widgets',
      'com.example.noop.watch',
      'com.example.noop.watch.complications',
    ],
  };
  assert.equal(validateIOSExpectedIdentities(expected), expected);
  for (const mutate of [
    value => { value.iosAppGroup = 'group.com.attacker.noop.staging'; },
    value => { value.iosBundleIdentifiers[1] = 'com.attacker.widget'; },
    value => { value.iosBundleIdentifiers[3] = 'com.example.noop.other'; },
  ]) {
    const changed = structuredClone(expected); mutate(changed);
    assert.throws(() => validateIOSExpectedIdentities(changed), /NOT_READY/);
  }
});

test('aggregate source contract separates historical fixture capacity from unmeasured explicit canary limits', () => {
  const capacity = JSON.parse(fs.readFileSync(new URL('../../infra/vps/launch-capacity.json', import.meta.url)));
  assert.equal(validateLaunchCapacity(capacity), capacity);
  for (const mutate of [
    value => { value.targetVpsCapacity = 'PASS'; },
    value => { value.fleetCapacityReadiness = 'PASS'; },
    value => { value.currentAdmission.safeActiveOwners = 10; },
    value => { value.currentAdmission.ownerAllowlist = false; },
    value => { value.publicationSlo.seconds = 60; },
    value => { value.proposedInitialTopology.status = 'APPROVED'; },
    value => { value.proposedInitialTopology.services[1].memoryBytes *= 2; },
    value => { value.historicalScalarFixture.appliesToCurrentAdmission = true; },
    value => { value.databaseConnections.intakeTransport = 'THREE_POSTGRES_CONNECTIONS'; },
    value => { value.unsupportedClaims[0].status = 'SUPPORTED'; },
  ]) {
    const changed = structuredClone(capacity); mutate(changed);
    assert.throws(() => validateLaunchCapacity(changed), /NOT_READY/);
  }
});

test('canonical release fingerprints ignore object insertion order but preserve array roles', () => {
  assert.equal(canonicalJSON({ b: 2, a: { d: 4, c: 3 } }), canonicalJSON({ a: { c: 3, d: 4 }, b: 2 }));
  assert.notEqual(canonicalJSON({ roles: ['v1', 'v2'] }), canonicalJSON({ roles: ['v2', 'v1'] }));
  assert.match(sha256(canonicalJSON({ source: REVISION })), /^[0-9a-f]{64}$/);
});

function releaseForDeployment() {
  const v1 = ociFixture('selected-v1'), v2 = ociFixture('shadow-v2'), intake = ociFixture('intake');
  const heartbeat = { table: 'physiology_worker_heartbeats', contract: 'physiology_worker_heartbeats-v1',
    sourceRevision: REVISION, requiredProgress: ['last_poll_at', 'last_score_at'], processIdentityRequired: true };
  return {
    schemaVersion: 1,
    kind: 'frwhoop-phone-test-artifact-manifest',
    source: { commit: REVISION, tree: 'b'.repeat(40), contractFiles: [
      'infra/vps/scoped-canary-stop-policy.json', 'infra/vps/scripts/scoped-canary-guard.py',
      'infra/vps/templates/frwhoop-scoped-canary.service', 'infra/vps/scripts/scoring-admission.py',
      'infra/vps/scripts/verify-worker-image.py', 'infra/vps/scripts/verify-pinned-postgres-client.py',
    ].map(filename => ({path:filename, sha256:sha256(fs.readFileSync(new URL('../../'+filename, import.meta.url))),
      sizeBytes:fs.statSync(new URL('../../'+filename,import.meta.url)).size})) },
    manifestFingerprintSha256: 'c'.repeat(64),
    runtimeClients: { postgresql: structuredClone(POSTGRES_CLIENT) },
    roles: {
      selectedV1: { imageArtifact: 'selectedV1', algorithmVersion: 'frwhoop-server-1',
        publicationRole: 'selected', heartbeat },
      shadowV2: { imageArtifact: 'shadowV2', algorithmVersion: 'frwhoop-physiology-2',
        publicationRole: 'shadow', heartbeat },
      intake: { imageArtifact: 'intake', contractVersion: 2, sourceRevision: REVISION,
        publicationRole: 'verified-indexed-input', lanes: ['verification', 'projection', 'legacy'],
        asyncAdmission: 'DISABLED_UNTIL_SEPARATELY_AUTHORIZED', progressTable: 'noop_intake_consumers' },
      historyV2: { imageArtifact: 'shadowV2', algorithmVersion: 'frwhoop-server-2-history',
        publicationRole: 'shadow-history', command: ['--history'], heartbeat },
    },
    artifacts: {
      intake: { image: { platform: 'linux/amd64', manifestDigest: intake.manifestDigest,
        configDigest: intake.configDigest } },
      selectedV1: { image: { platform: 'linux/amd64', manifestDigest: v1.manifestDigest,
        configDigest: v1.configDigest } },
      shadowV2: { image: { platform: 'linux/amd64', manifestDigest: v2.manifestDigest,
        configDigest: v2.configDigest } },
    },
  };
}

const CANARY = { mode: 'canary', ownerId: '11111111-1111-4111-8111-111111111112',
  deviceId: '11111111-1111-4111-8111-111111111113' };
function intakeForDeployment(release, admission = { mode: 'all-eligible' }) {
  const reference = `registry.invalid/frwhoop-intake@${release.artifacts.intake.image.manifestDigest}`;
  const instanceId = '11111111-1111-4111-8111-111111111111', projectRef = 'sgoyxzcagqyxexmsidtk';
  return { reference, instanceId, projectRef, admission,
    compiledCompose: intakeComposeContract(reference, release.source.commit, instanceId, projectRef, admission) };
}
function createWorkerDeployment(release, v1, v2, target, intake = intakeForDeployment(release)) {
  return createWorkerDeploymentActual(release, v1, v2, target, intake, 'full-fleet', { mode: 'all-eligible' });
}

function targetForDeployment() {
  const type = Buffer.from('ssh-ed25519');
  const blob = Buffer.concat([Buffer.from([0, 0, 0, type.length]), type, Buffer.from([0, 0, 0, 32]), Buffer.alloc(32, 7)]);
  return {
    ip: '192.0.2.44',
    sshPort: 2222,
    sshHostPublicKeyLine: `ssh-ed25519 ${blob.toString('base64')}`,
    sshHostPublicKeyFingerprint: `SHA256:${crypto.createHash('sha256').update(blob).digest('base64').replace(/=+$/, '')}`,
    deployPublicKeyFingerprint: 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
  };
}

test('worker deployment binds aggregate fingerprint, OCI descriptors and lane order to registry digests', () => {
  const release = releaseForDeployment();
  const v1 = `registry.invalid/frwhoop-v1@${release.artifacts.selectedV1.image.manifestDigest}`;
  const v2 = `registry.invalid/frwhoop-v2@${release.artifacts.shadowV2.image.manifestDigest}`;
  const deployment = createWorkerDeployment(release, v1, v2, targetForDeployment());
  assert.equal(verifyWorkerDeploymentContract(release, deployment), deployment);
  assert.deepEqual(deployment.laneOrder.map(lane => lane.service),
    ['intake-consumer', 'scoring-baseline-v1', 'scoring-physiology-v2', 'scoring-history']);
  assert.equal(deployment.images.selectedV1.configDigest, release.artifacts.selectedV1.image.configDigest);
  assert.equal(deployment.images.shadowV2.configDigest, release.artifacts.shadowV2.image.configDigest);
  assert.deepEqual(deployment.runtimeClients.postgresql, POSTGRES_CLIENT);
  assert.equal(deployment.target.ip, '192.0.2.44');
  assert.equal(deployment.rollbackState, 'REQUIRES_SEPARATE_REVIEWED_COMPATIBLE_ARTIFACT');
});

test('worker deployment rejects mutable refs, role swaps and all identity mutations', () => {
  const release = releaseForDeployment();
  const v1 = `registry.invalid/frwhoop-v1@${release.artifacts.selectedV1.image.manifestDigest}`;
  const v2 = `registry.invalid/frwhoop-v2@${release.artifacts.shadowV2.image.manifestDigest}`;
  assert.throws(() => createWorkerDeployment(release, 'registry.invalid/frwhoop-v1:latest', v2, targetForDeployment()), /NOT_READY/);
  assert.throws(() => createWorkerDeployment(release, v2, v1, targetForDeployment()), /NOT_READY/);
  for (const mutate of [
    value => { value.ip = 'vps.example.invalid'; },
    value => { value.sshPort = 0; },
    value => { value.sshHostPublicKeyFingerprint = 'SHA256:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'; },
    value => { value.deployPublicKeyFingerprint = 'not-a-fingerprint'; },
  ]) {
    const target = targetForDeployment(); mutate(target);
    assert.throws(() => createWorkerDeployment(release, v1, v2, target), /NOT_READY/);
  }
  const changedClientRelease = structuredClone(release);
  changedClientRelease.runtimeClients.postgresql.reference = 'docker.io/library/postgres:17-alpine';
  assert.throws(() => createWorkerDeployment(changedClientRelease, v1, v2, targetForDeployment()), /NOT_READY/);
  for (const prefix of [
    'registry.invalid/$(touch${IFS}pwned)',
    'registry.invalid/image;touch-pwned',
    'registry.invalid/image`touch-pwned`',
    'registry.invalid/image\"quoted',
    'registry.invalid/image/../substitute',
    'registry.invalid/image//substitute',
    'REGISTRY.invalid/image',
  ]) {
    assert.throws(() => createWorkerDeployment(release,
      `${prefix}@${release.artifacts.selectedV1.image.manifestDigest}`, v2, targetForDeployment()), /NOT_READY/);
  }
  const valid = createWorkerDeployment(release, v1, v2, targetForDeployment());
  const mutations = [
    value => { value.source.commit = 'd'.repeat(40); },
    value => { value.releaseManifestFingerprintSha256 = 'd'.repeat(64); },
    value => { value.images.intake.configDigest = 'sha256:' + 'd'.repeat(64); },
    value => { value.intake.contractVersion = 1; },
    value => { value.intake.asyncAdmission = 'ENABLED'; },
    value => { value.intake.compiledCompose.services['intake-consumer'].command = ['--once']; },
    value => { value.intake.compiledComposeSha256 = 'e'.repeat(64); },
    value => { value.images.selectedV1.configDigest = 'sha256:' + 'd'.repeat(64); },
    value => { value.images.shadowV2.manifestDigest = 'sha256:' + 'd'.repeat(64); },
    value => { value.runtimeClients.postgresql.configDigest = 'sha256:' + 'd'.repeat(64); },
    value => { value.target.ip = '192.0.2.45'; },
    value => { value.target.sshHostPublicKey.fingerprint = 'SHA256:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'; },
    value => { value.laneOrder.reverse(); },
    value => { value.extra = true; },
    value => { value.deploymentFingerprintSha256 = 'd'.repeat(64); },
  ];
  for (const mutate of mutations) {
    const changed = structuredClone(valid); mutate(changed);
    assert.throws(() => verifyWorkerDeploymentContract(release, changed), /NOT_READY/);
  }
});

test('initial deployment scope binds intake and selected v1 without shadow or history starts', () => {
  const release = releaseForDeployment();
  const v1 = `registry.invalid/frwhoop-v1@${release.artifacts.selectedV1.image.manifestDigest}`;
  const v2 = `registry.invalid/frwhoop-v2@${release.artifacts.shadowV2.image.manifestDigest}`;
  const initial = createWorkerDeploymentActual(release, v1, v2, targetForDeployment(),
    intakeForDeployment(release, CANARY), 'initial-selected-v1', CANARY);
  assert.equal(verifyWorkerDeploymentContract(release, initial), initial);
  assert.deepEqual(initial.laneOrder.map(lane => lane.service), ['intake-consumer', 'scoring-baseline-v1']);
  const expanded = structuredClone(initial);
  expanded.scope = 'full-fleet';
  assert.throws(() => verifyWorkerDeploymentContract(release, expanded), /NOT_READY/);
  assert.throws(() => createWorkerDeploymentActual(release, v1, v2, targetForDeployment(),
    intakeForDeployment(release), 'one-owner', { mode: 'all-eligible' }), /scope differs/);
});

test('migration binding rejects coherently reauthored catalogs and binds all 129 committed source files', () => {
  const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
  const git = (...args) => {
    const result = spawnSync('git', ['-C', repo, ...args], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    return result.stdout.trim();
  };
  const commit = git('rev-parse', 'HEAD'), tree = git('rev-parse', `${commit}^{tree}`);
  const catalog = JSON.parse(fs.readFileSync(path.join(repo,
    'scoring-service/service/src/main/resources/scoring-migration-catalog.json'), 'utf8'));
  const sources = {
    'persistent-sync-followup': { branch: 'codex/persistent-sync-followup-2026-09-22', tip: 'a972493212f2eae29f01ecaddf9182260153400f' },
    'server-repair': { branch: 'repair/vps-server-20260922', tip: commit },
    'server-pipeline': { branch: 'fix/server-pipeline', tip: 'cfb94434b1b4ed4dba587e5c4e7af405e782e560' },
    'multiuser-scale': { branch: 'feat/multiuser-scale', tip: '0eac19cce495e761dc3d832dd1cfd8a07221c61d' },
    'sensor-algorithms': { branch: 'feat/sensor-algorithms', tip: '198b99924a79148ff01833115fe2f47f2025bfa4' },
    'ble-sync': { branch: 'fix/ble-sync', tip: 'af9468f7a48cc3fddeb33d7a3b983204af620ca6' },
    'vps-only-compute': { branch: 'feat/vps-only-compute', tip: '63ac35d0cab0644d197e8225d9fc97e1bd9446cf' },
  };
  const manifest = generateMigrationManifest({
    repoRoot: repo,
    candidateSources: { schemaVersion: 1,
      candidate: { branch: 'repair/vps-server-20260922', sha: commit, tree }, sources },
    hostedLedgerEvidence: {
      schemaVersion: 1, environment: 'hosted-production', projectRef: 'sgoyxzcagqyxexmsidtk',
      capturedAt: '2026-09-22T01:02:03Z', nativeLedgerRows: 110, fullIdentityRows: 117,
      highestKnownIdentity: '20260921104000_server_unrepresentable_clock.sql',
      applied: catalog.slice(0, 117).map(row => ({ stableIdentity: row.basename, sha256: row.sha256 })),
      identityStates: { '20260918234000_motion_evidence_provenance.sql': {
        state: 'superseded_in_hosted_schema', reason: 'Reviewed hosted forward repair supersedes this identity.',
      } },
      evidenceArtifacts: [{ label: 'reviewed-ledger', path: '/immutable/evidence/ledger.json',
        sha256: '9'.repeat(64) }],
    },
  });
  assert.deepEqual(validateMigrationManifest(manifest, repo, commit, tree), {
    schemaFingerprintSha256: manifest.schemaFingerprintSha256,
    manifestFingerprintSha256: manifest.manifestFingerprintSha256,
    total: 129, applied: 117, pending: 12,
  });
  const rehash = value => {
    const { manifestFingerprintSha256: ignored, ...unsigned } = value;
    value.manifestFingerprintSha256 = sha256(canonicalJSON(unsigned));
    return value;
  };
  for (const mutate of [
    value => { value.entries[0].sha256 = '0'.repeat(64); },
    value => { value.entries[0].sizeBytes += 1; },
    value => { [value.entries[0], value.entries[1]] = [value.entries[1], value.entries[0]]; },
    value => { value.entries[123].upgradeBehavior.upgradeOrdinal = 1; },
    value => { value.sourceWorkstreams[0].tip = '0'.repeat(40); },
    value => { value.unreviewed = true; },
  ]) {
    const changed = structuredClone(manifest); mutate(changed); rehash(changed);
    assert.throws(() => validateMigrationManifest(changed, repo, commit, tree), /NOT_READY/);
  }
});

test('aggregate verification regenerates deployment bundle metadata from exact committed bytes', () => {
  const source = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'frwhoop-aggregate-source-'));
  try {
    const repo = path.join(directory, 'repo');
    fs.mkdirSync(path.join(repo, 'Tools'), { recursive: true });
    fs.cpSync(path.join(source, 'Tools/release'), path.join(repo, 'Tools/release'), { recursive: true });
    fs.copyFileSync(path.join(source, 'Tools/prepare-ios-sideload-app.sh'),
      path.join(repo, 'Tools/prepare-ios-sideload-app.sh'));
    fs.mkdirSync(path.join(repo, 'infra'), { recursive: true });
    fs.cpSync(path.join(source, 'infra/vps'), path.join(repo, 'infra/vps'), { recursive: true });
    for (const args of [
      ['init', '-q'], ['add', '.'], ['-c', 'user.name=Release Test', '-c', 'user.email=release@test.invalid',
        'commit', '-qm', 'fixture'],
    ]) {
      const result = spawnSync('git', ['-C', repo, ...args], { encoding: 'utf8' });
      assert.equal(result.status, 0, result.stderr);
    }
    const commit = spawnSync('git', ['-C', repo, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).stdout.trim();
    const output = path.join(directory, 'deployment');
    const manifest = prepareDeploymentSourceBundle({ repoRoot: repo, commit, outputDirectory: output });
    assert.doesNotThrow(() => verifyBundleMatchesCommittedSource(repo, commit, manifest, 'deployment'));
    const reauthored = structuredClone(manifest);
    reauthored.files.splice(reauthored.files.findIndex(file => file.path.endsWith('test_scoring_deploy.py')), 1);
    assert.throws(() => verifyBundleMatchesCommittedSource(repo, commit, reauthored, 'deployment'),
      /differs from deterministic committed source/);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});


test('one canonical private admission binds both consumers and cannot expand scope', () => {
  const release = releaseForDeployment();
  const v1 = `registry.invalid/frwhoop-v1@${release.artifacts.selectedV1.image.manifestDigest}`;
  const v2 = `registry.invalid/frwhoop-v2@${release.artifacts.shadowV2.image.manifestDigest}`;
  const plan = createWorkerDeploymentActual(release, v1, v2, targetForDeployment(),
    intakeForDeployment(release, CANARY), 'initial-selected-v1', CANARY);
  assert.deepEqual(plan.baselineEnvironment, admissionEnvironment(CANARY, 'SCORING'));
  const env = plan.intake.compiledCompose.services['intake-consumer'].environment;
  assert.equal(env.INTAKE_CANARY_OWNER_ID, plan.baselineEnvironment.SCORING_CANARY_OWNER_ID);
  assert.equal(env.INTAKE_CANARY_DEVICE_ID, plan.baselineEnvironment.SCORING_CANARY_DEVICE_ID);
  assert.equal(plan.admissionSha256, sha256(canonicalJSON(CANARY)));
  assert.equal(plan.canaryGuard.dependencies.length,3);
  assert.equal(plan.intake.compiledCompose.services['intake-consumer'].restart,'no');
  const unbound = structuredClone(release); unbound.source.contractFiles=[];
  assert.throws(() => createWorkerDeploymentActual(unbound,v1,v2,targetForDeployment(),
    intakeForDeployment(unbound,CANARY),'initial-selected-v1',CANARY), /guard source binding missing/);
  for (const mutate of [
    p => { p.admission.deviceId = '11111111-1111-4111-8111-111111111114'; },
    p => { p.baselineEnvironment.SCORING_CANARY_OWNER_ID = p.admission.deviceId; },
    p => { p.intake.compiledCompose.services['intake-consumer'].environment.INTAKE_ADMISSION_MODE = 'all-eligible'; },
    p => { p.admissionSha256 = '0'.repeat(64); },
    p => { p.canaryGuard.policy.sha256 = '0'.repeat(64); },
    p => { p.canaryGuard.dependencies.pop(); },
    p => { p.canaryGuard.helper.sizeBytes += 1; },
  ]) {
    const changed = structuredClone(plan); mutate(changed);
    assert.throws(() => verifyWorkerDeploymentContract(release, changed), /NOT_READY/);
  }
  assert.throws(() => createWorkerDeploymentActual(release, v1, v2, targetForDeployment(),
    intakeForDeployment(release), 'initial-selected-v1', { mode: 'all-eligible' }), /initial deployment requires canary/);
  assert.throws(() => createWorkerDeploymentActual(release, v1, v2, targetForDeployment(),
    intakeForDeployment(release, CANARY), 'full-fleet', CANARY), /initial deployment requires canary/);
  for (const value of [undefined, {}, {mode:'canary'}, {...CANARY, deviceId:'1-1-1-1-1'},
    {...CANARY, ownerId:'00000000-0000-0000-0000-000000000000'}, {...CANARY, mode:'all-eligible'},
    {...CANARY, ownerId:[CANARY.ownerId]}, {...CANARY, deviceId:[CANARY.deviceId]},
    {...CANARY, extra:true}]) assert.throws(() => validateAdmission(value), /NOT_READY/);
});

test('private scope files reject public modes and symlinks and atomic outputs stay private', t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'release-private-admission-'));
  t.after(() => fs.rmSync(directory, {recursive:true, force:true}));
  const filename = path.join(directory, 'admission.json');
  atomicWrite(filename, CANARY, 0o600);
  assert.equal(fs.statSync(filename).mode & 0o777, 0o600);
  assert.deepEqual(validateAdmission(readPrivateJSON(filename)), CANARY);
  const link = path.join(directory, 'link.json'); fs.symlinkSync(filename, link);
  assert.throws(() => readPrivateJSON(link), /private deployment file is invalid/);
  fs.chmodSync(filename, 0o644);
  assert.throws(() => readPrivateJSON(filename), /private deployment file is invalid/);
  atomicWrite(filename, CANARY, 0o600);
  assert.equal(fs.statSync(filename).mode & 0o777, 0o600);
  fs.writeFileSync(filename, '{bad private contents');
  assert.throws(() => readPrivateJSON(filename), /private deployment file is invalid/);
});
