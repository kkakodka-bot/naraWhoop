// Synthetic offline TEST support only, never operator evidence or credentials.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { CANARY_STAGES, REQUIRED_MIGRATIONS, SCENARIOS } from './sync-evidence-contract.mjs';
import { SOURCE_ROOTS } from './check-sync-sources.mjs';
import { hash } from './scorer-image-release.mjs';

// Deliberately synthetic descriptor bytes and metadata, never an actual build receipt.
export function releaseFixture(directory, commit = 'b'.repeat(40), configId = `sha256:${'b'.repeat(64)}`) {
  fs.mkdirSync(directory, { recursive: true });
  const bytes = value => Buffer.from(JSON.stringify(value, null, 2) + '\n');
  const artifacts = [];
  const save = (name, content) => {
    fs.writeFileSync(path.join(directory, name), content);
    artifacts.push({ path: name, sha256: hash(content) });
  };
  const files = ['scoring-service/Dockerfile', 'scoring-service/service/src/main/kotlin/Synthetic.kt']
    .map(name => ({ path: name, mode: '100644', size: 4, sha256: hash('test') }));
  const inputFiles = files.slice(1).map(({ path, sha256 }) => ({ path, sha256 }));
  save('inputs.json', bytes(files)); save('native-report.txt', Buffer.from('SYNTHETIC NATIVE EVIDENCE ONLY'));
  save('native.json', bytes({ schemaVersion: 1, inputFiles, reports: [artifacts[1]] }));
  const manifest = bytes({ schemaVersion: 2, mediaType: 'application/vnd.oci.image.manifest.v1+json', config: { digest: configId } });
  const registryDigest = `sha256:${hash(manifest)}`, reference = `fixture.invalid/scorer@${registryDigest}`;
  save('manifest.json', manifest);
  const inspection = { id: configId, revision: commit, os: 'linux', architecture: 'amd64', repoDigests: [reference] };
  save('image.json', bytes(inspection));
  save('build-result.json', bytes({ 'containerimage.digest': registryDigest, 'containerimage.config.digest': configId }));
  const release = { schemaVersion: 1, kind: 'scorer-image-release', source: { commit, tree: 'a'.repeat(40),
    contextSha256: hash(bytes(files)), dockerfileSha256: files[0].sha256,
    inputManifestArtifact: 'inputs.json', nativeEvidenceArtifact: 'native.json', nativeInputSha256: hash(bytes(inputFiles)) },
  build: { platform: 'linux/amd64', buildImage: `fixture.invalid/jdk@sha256:${'1'.repeat(64)}`,
    runtimeImage: `fixture.invalid/jre@sha256:${'2'.repeat(64)}`, builderVersion: 'SYNTHETIC', metadataArtifact: 'build-result.json' },
  image: { reference, registryDigest, platformManifestDigest: registryDigest, configId, revision: commit, platform: 'linux/amd64',
    registryArtifact: 'manifest.json', manifestArtifact: 'manifest.json', inspectionArtifact: 'image.json' }, artifacts };
  fs.writeFileSync(path.join(directory, 'release.json'), bytes(release));
  return { release, inspection, filename: path.join(directory, 'release.json') };
}

export function sourceFixture(root) {
  for (const relative of SOURCE_ROOTS) {
    fs.mkdirSync(path.join(root, relative), { recursive: true });
    fs.writeFileSync(path.join(root, relative, 'Synthetic.kt'), 'package fixture\nimport com.noop.data.HrSample\n');
  }
  const migrations = path.join(root, 'supabase/migrations'); fs.mkdirSync(migrations, { recursive: true });
  for (const id of REQUIRED_MIGRATIONS) fs.writeFileSync(path.join(migrations, `${id}_synthetic.sql`), '-- synthetic source-presence fixture only\n');
  fs.writeFileSync(path.join(migrations, '20260916160000_scoring_service_state.sql'), '-- scoring_service_heartbeats scoring_work_items engine_ingest_scored\n');
  return migrations;
}

export function fixture(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'sync-evidence-test-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const bytes = 'SYNTHETIC VALIDATOR TEST ONLY. NOT DEVICE OR DEPLOYMENT EVIDENCE.\n';
  fs.writeFileSync(path.join(directory, 'synthetic.txt'), bytes);
  const now = Date.now(), at = new Date(now - 1000).toISOString();
  const hash = 'a'.repeat(64), artifact = 'synthetic.txt';
  const imageFixture = releaseFixture(path.join(directory, 'image-release'));
  const identity = { ownerNamespace: hash, recordDigest: hash,
    ownerUserId: '11111111-1111-4111-8111-111111111111', deviceId: '22222222-2222-4222-8222-222222222222',
    objectId: '33333333-3333-4333-8333-333333333333', inputRevision: 1, resultRevision: 2 };
  const evidence = {
    schemaVersion: 2, environment: 'staging', endpoint: 'https://fixture.invalid',
    target: { sshHost: 'synthetic.invalid', bindingArtifact: artifact },
    collection: { startedAt: new Date(now - 4 * 86400_000).toISOString(), completedAt: at },
    build: { commit: 'a'.repeat(40), version: 'fixture', number: '1', configuration: 'Release', xcode: 'fixture', sdk: 'fixture' },
    server: { commit: 'b'.repeat(40), imageDigest: imageFixture.release.image.registryDigest, dockerImageId: `sha256:${'b'.repeat(64)}`,
      imageProvenanceArtifact: 'image-release/release.json',
      containerId: 'c'.repeat(64), edgeRevision: 'fixture', migrations: [...REQUIRED_MIGRATIONS],
      migrationLedgerRaw: [...REQUIRED_MIGRATIONS], heartbeats: [new Date(now - 20000).toISOString(), at] },
    canary: { credentialKind: 'userJWT', ...identity, recordDigestScope: 'object-content-sha256',
      day: '2026-09-18', algorithmVersion: 'synthetic-v1', inputBindingArtifact: artifact,
      stages: Object.fromEntries(CANARY_STAGES.map(name => [name, { at, ...identity, artifact }])), displayedRevision: 2 },
    scenarios: Object.fromEntries(SCENARIOS.map(name => [name, { status: 'pass', artifact, observedAt: at }])),
    performance: [60, 120].map(actualRefreshHz => ({ actualRefreshHz, device: 'synthetic', os: 'synthetic', artifact,
      physicalDevice: true, configuration: 'Release', metric: 'aggregateHitchesMsPerSecond', value: 1,
      unresolvedMainThreadStalls250ms: 0, toolVersion: 'synthetic', denominator: 'synthetic', observedAt: at, buildCommit: 'a'.repeat(40) })),
    latency: { warmNavigationP95Ms: 1, coldCachedDashboardP95Ms: 1, activeCommitToDisplayP95Ms: 1, artifact, observedAt: at },
    energy: { matchedBaseline: true, unexplainedRetryLoop: false, sustainedSeriousThermal: false, artifact, observedAt: at },
    security: { userLevelRls: 'pass', crossAccountRejected: 'pass', artifact, observedAt: at },
    artifacts: [{ path: artifact, sha256: crypto.createHash('sha256').update(bytes).digest('hex') }],
  };
  for (const name of fs.readdirSync(path.join(directory, 'image-release'))) {
    evidence.artifacts.push({ path: `image-release/${name}`,
      sha256: crypto.createHash('sha256').update(fs.readFileSync(path.join(directory, 'image-release', name))).digest('hex') });
  }
  return { evidence, directory, now, imageFixture };
}
