import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import {
  canonicalJSON,
  inspectOCI,
  parseAndroidBadging,
  parseAndroidReleaseMetadata,
  sha256,
} from './release-artifact-manifest.mjs';

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
function ociFixture(role) {
  const provenance = {
    transport_patch_sha256: '1'.repeat(64),
    identity_patch_sha256: '2'.repeat(64),
  };
  const labels = {
    'org.opencontainers.image.revision': REVISION,
    'io.frwhoop.heartbeat.contract': 'physiology_worker_heartbeats-v1',
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
  const config = json({ architecture: 'amd64', os: 'linux', config: { Labels: labels } });
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

for (const role of ['selected-v1', 'shadow-v2']) test(`OCI inspection binds ${role} revision, platform, bases and role`, t => {
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

test('Android inspection parsers bind staging package/build and signed manifest release markers', () => {
  const badging = [
    "package: name='com.noop.whoop.staging' versionCode='450' versionName='11.1.1-staging' platformBuildVersionName='15'",
    "minSdkVersion:'26'",
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

test('canonical release fingerprints ignore object insertion order but preserve array roles', () => {
  assert.equal(canonicalJSON({ b: 2, a: { d: 4, c: 3 } }), canonicalJSON({ a: { c: 3, d: 4 }, b: 2 }));
  assert.notEqual(canonicalJSON({ roles: ['v1', 'v2'] }), canonicalJSON({ roles: ['v2', 'v1'] }));
  assert.match(sha256(canonicalJSON({ source: REVISION })), /^[0-9a-f]{64}$/);
});
