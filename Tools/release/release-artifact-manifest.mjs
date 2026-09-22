#!/usr/bin/env node

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { verifyDeploymentSourceBundle } from './deployment-source-bundle.mjs';
import { verifyEdgeSourceBundle } from './edge-source-bundle.mjs';

const SHA256 = /^[0-9a-f]{64}$/;
const DIGEST = /^sha256:[0-9a-f]{64}$/;
const REVISION = /^[0-9a-f]{40}$/;
const BASELINE_COMMIT = '5caa31689da0023e111beb36850d3f81d67e1be2';
const PLATFORM = 'linux/amd64';
const BUILD_IMAGE = 'docker.io/library/eclipse-temurin@sha256:e573c097106f35634857604fdfbe70a2a2bbcaa52574bca3d2025703d0df994d';
const RUNTIME_IMAGE = 'docker.io/library/eclipse-temurin@sha256:24cd8eed18b5976441d27b45823490eb5e8efff4b3ecdc632e442717ea66f160';
const EDGE_FUNCTIONS = ['account-deletion', 'ingest-verify', 'push', 'reconcile', 'retention-sweep', 'scores'];
const CONTRACT_FILES = [
  'Tools/release/VerifyApk.java',
  'Tools/release/deployment-source-bundle.mjs',
  'Tools/release/edge-source-bundle.mjs',
  'Tools/release/generate-migration-manifest.mjs',
  'Tools/release/inspect_ipa.py',
  'Tools/release/release-artifact-manifest.mjs',
  'android/app/build.gradle.kts',
  'android/app/src/main/AndroidManifest.xml',
  'android/fork-debug.keystore',
  'infra/vps/templates/Dockerfile.baseline',
  'infra/vps/templates/docker-compose.scoring-override.yml',
  'project.yml',
  'scoring-service/Dockerfile',
  'scoring-service/legacy-baseline/build.py',
  'scoring-service/legacy-baseline/runtime-identity.patch',
  'scoring-service/legacy-baseline/transport.patch',
  'scoring-service/service/src/main/kotlin/com/frwhoop/scoring/ScoringConfig.kt',
  'scoring-service/service/src/main/kotlin/com/frwhoop/scoring/health/HeartbeatReporter.kt',
  'supabase/migrations/20260919020000_physiology_worker_heartbeats.sql',
];

function invariant(value, message) {
  if (!value) throw new Error(`NOT_READY: ${message}`);
}
function isObject(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function exactKeys(value, keys, label) {
  invariant(isObject(value), `${label} must be an object`);
  invariant(JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...keys].sort()), `${label} fields differ`);
}
function sorted(value) {
  if (Array.isArray(value)) return value.map(sorted);
  if (!isObject(value)) return value;
  return Object.fromEntries(Object.keys(value).sort().map(key => [key, sorted(value[key])]));
}
export const canonicalJSON = value => JSON.stringify(sorted(value));
export const sha256 = bytes => crypto.createHash('sha256').update(bytes).digest('hex');

function run(program, args, options = {}) {
  const result = spawnSync(program, args, { ...options, maxBuffer: options.maxBuffer ?? 64 * 1024 * 1024 });
  invariant(!result.error && !result.signal && result.status === 0,
    `${path.basename(program)} failed${result.stderr?.length ? `: ${result.stderr.toString('utf8').trim().slice(0, 500)}` : ''}`);
  return result.stdout;
}
function git(repo, ...args) {
  return run('git', ['--no-replace-objects', '-c', 'core.fsmonitor=false', '-c', 'core.hooksPath=/dev/null',
    '-c', 'protocol.allow=never', ...args], { cwd: repo,
    env: { PATH: process.env.PATH, TMPDIR: process.env.TMPDIR, GIT_CONFIG_NOSYSTEM: '1',
      GIT_CONFIG_GLOBAL: '/dev/null', GIT_NO_LAZY_FETCH: '1', GIT_NO_REPLACE_OBJECTS: '1' } });
}
function relative(value, label = 'artifact path') {
  invariant(typeof value === 'string' && value.length > 0 && value.length <= 1024 &&
    !path.isAbsolute(value) && !value.includes('\\') && !/[\x00-\x1f\x7f]/.test(value) &&
    value.split('/').every(part => part && part !== '.' && part !== '..'), `invalid ${label}`);
  return value;
}
function artifactFile(root, name) {
  relative(name);
  const base = fs.realpathSync(root);
  let current = base;
  for (const part of name.split('/')) {
    current = path.join(current, part);
    const stat = fs.lstatSync(current);
    invariant(!stat.isSymbolicLink(), `artifact path contains a symlink: ${name}`);
  }
  const stat = fs.statSync(current);
  invariant(stat.isFile() && stat.size >= 0, `artifact is not a regular file: ${name}`);
  invariant(fs.realpathSync(current).startsWith(base + path.sep), `artifact escapes root: ${name}`);
  return current;
}
function boundedJSON(filename, limit = 64 * 1024 * 1024) {
  const stat = fs.statSync(filename);
  invariant(stat.size <= limit, `JSON artifact exceeds ${limit} bytes`);
  try { return JSON.parse(fs.readFileSync(filename, 'utf8')); } catch { invariant(false, `malformed JSON: ${path.basename(filename)}`); }
}
function hashFile(filename) {
  const descriptor = fs.openSync(filename, 'r');
  try {
    const digest = crypto.createHash('sha256'), buffer = Buffer.allocUnsafe(1024 * 1024);
    let offset = 0;
    while (true) {
      const count = fs.readSync(descriptor, buffer, 0, buffer.length, offset);
      if (!count) break;
      digest.update(buffer.subarray(0, count)); offset += count;
    }
    return digest.digest('hex');
  } finally { fs.closeSync(descriptor); }
}
function fileIdentity(root, name) {
  const filename = artifactFile(root, name), stat = fs.statSync(filename);
  return { path: name, sizeBytes: stat.size, sha256: hashFile(filename) };
}
function sameIdentity(actual, expected, label) {
  invariant(actual.path === expected.path && actual.sizeBytes === expected.sizeBytes && actual.sha256 === expected.sha256,
    `${label} artifact identity changed`);
}

function tarString(buffer, start, length) {
  const end = buffer.indexOf(0, start);
  return buffer.subarray(start, end >= start && end < start + length ? end : start + length).toString('utf8');
}
function tarNumber(buffer, start, length) {
  const raw = buffer.subarray(start, start + length);
  invariant((raw[0] & 0x80) === 0, 'base-256 tar numbers are unsupported');
  const text = raw.toString('ascii').replace(/\0.*$/, '').trim();
  invariant(!text || /^[0-7]+$/.test(text), 'invalid tar numeric field');
  return text ? Number.parseInt(text, 8) : 0;
}
function parseTar(filename) {
  const stat = fs.statSync(filename);
  const descriptor = fs.openSync(filename, 'r'), entries = new Map(), header = Buffer.alloc(512);
  let offset = 0, ended = false;
  try {
    while (offset + 512 <= stat.size) {
      invariant(fs.readSync(descriptor, header, 0, 512, offset) === 512, 'truncated tar header');
      if (header.every(byte => byte === 0)) { ended = true; break; }
      const stored = tarNumber(header, 148, 8);
      let sum = 0;
      for (let i = 0; i < 512; i++) sum += i >= 148 && i < 156 ? 32 : header[i];
      invariant(stored === sum, 'tar header checksum differs');
      const prefix = tarString(header, 345, 155), leaf = tarString(header, 0, 100);
      const name = prefix ? `${prefix}/${leaf}` : leaf;
      relative(name.replace(/\/$/, ''), 'tar member');
      invariant(!entries.has(name), `duplicate tar member: ${name}`);
      const size = tarNumber(header, 124, 12), type = String.fromCharCode(header[156] || 48);
      invariant(Number.isSafeInteger(size) && size >= 0, 'invalid tar member size');
      const dataOffset = offset + 512;
      invariant(dataOffset + size <= stat.size, `truncated tar member: ${name}`);
      invariant(type === '0' || type === '5', `non-regular OCI tar member: ${name}`);
      entries.set(name, { name, type, size, offset: dataOffset });
      offset = dataOffset + Math.ceil(size / 512) * 512;
    }
  } finally { fs.closeSync(descriptor); }
  invariant(ended, 'tar has no zero-block terminator');
  return entries;
}
function readTarEntry(filename, entry, limit = 32 * 1024 * 1024) {
  invariant(entry?.type === '0' && entry.size <= limit, `missing or excessive tar entry: ${entry?.name ?? 'unknown'}`);
  const bytes = Buffer.alloc(entry.size), descriptor = fs.openSync(filename, 'r');
  try { invariant(fs.readSync(descriptor, bytes, 0, bytes.length, entry.offset) === bytes.length, 'short tar entry read'); }
  finally { fs.closeSync(descriptor); }
  return bytes;
}
function hashTarEntry(filename, entry) {
  const descriptor = fs.openSync(filename, 'r'), digest = crypto.createHash('sha256'), buffer = Buffer.allocUnsafe(1024 * 1024);
  let remaining = entry.size, offset = entry.offset;
  try {
    while (remaining) {
      const wanted = Math.min(buffer.length, remaining);
      const count = fs.readSync(descriptor, buffer, 0, wanted, offset);
      invariant(count > 0, 'short tar blob read');
      digest.update(buffer.subarray(0, count)); remaining -= count; offset += count;
    }
  } finally { fs.closeSync(descriptor); }
  return digest.digest('hex');
}
function parseJSONBytes(bytes, label) {
  try { return JSON.parse(bytes.toString('utf8')); } catch { invariant(false, `malformed ${label}`); }
}
function descriptorEntry(archive, entries, descriptor, label) {
  invariant(isObject(descriptor) && DIGEST.test(descriptor.digest) && Number.isSafeInteger(descriptor.size), `invalid ${label} descriptor`);
  const entry = entries.get(`blobs/sha256/${descriptor.digest.slice(7)}`);
  invariant(entry?.type === '0' && entry.size === descriptor.size, `${label} blob size differs`);
  invariant(hashTarEntry(archive, entry) === descriptor.digest.slice(7), `${label} blob digest differs`);
  return entry;
}
export function inspectOCI(filename, role, sourceRevision, buildMetadata, provenance = undefined) {
  invariant(['selected-v1', 'shadow-v2'].includes(role), 'unsupported OCI role');
  const entries = parseTar(filename);
  const layout = parseJSONBytes(readTarEntry(filename, entries.get('oci-layout')), 'OCI layout');
  invariant(layout?.imageLayoutVersion === '1.0.0', 'unsupported OCI layout');
  const indexBytes = readTarEntry(filename, entries.get('index.json'));
  const index = parseJSONBytes(indexBytes, 'OCI index');
  invariant(index?.schemaVersion === 2 && Array.isArray(index.manifests), 'invalid OCI index');
  const manifests = index.manifests.filter(item => item?.platform?.os === 'linux' &&
    item.platform.architecture === 'amd64' && !item.platform.variant &&
    ['application/vnd.oci.image.manifest.v1+json', 'application/vnd.docker.distribution.manifest.v2+json'].includes(item.mediaType));
  invariant(manifests.length === 1, 'OCI archive lacks one linux/amd64 image manifest');
  const selected = manifests[0], manifestEntry = descriptorEntry(filename, entries, selected, 'image manifest');
  const manifest = parseJSONBytes(readTarEntry(filename, manifestEntry), 'OCI image manifest');
  invariant(manifest?.schemaVersion === 2 && isObject(manifest.config) && Array.isArray(manifest.layers), 'invalid OCI image manifest');
  const configEntry = descriptorEntry(filename, entries, manifest.config, 'image config');
  for (const [index, layer] of manifest.layers.entries()) descriptorEntry(filename, entries, layer, `image layer ${index + 1}`);
  const config = parseJSONBytes(readTarEntry(filename, configEntry), 'OCI image config');
  invariant(config.os === 'linux' && config.architecture === 'amd64', 'OCI config platform differs');
  const labels = config?.config?.Labels;
  invariant(isObject(labels) && labels['org.opencontainers.image.revision'] === sourceRevision, 'OCI source revision label differs');
  const expectedDigest = selected.digest, expectedConfig = manifest.config.digest;
  invariant(buildMetadata?.['containerimage.digest'] === expectedDigest &&
    buildMetadata?.['containerimage.config.digest'] === expectedConfig, 'BuildKit metadata differs from OCI descriptors');
  invariant(buildMetadata?.['containerimage.descriptor']?.digest === expectedDigest, 'BuildKit descriptor digest differs');
  if (role === 'selected-v1') {
    invariant(labels['io.frwhoop.algorithm.version'] === 'frwhoop-server-1' &&
      labels['io.frwhoop.baseline.commit'] === BASELINE_COMMIT, 'v1 algorithm/baseline labels differ');
    invariant(labels['io.frwhoop.baseline.transport-sha256'] === provenance?.transport_patch_sha256 &&
      labels['io.frwhoop.baseline.identity-sha256'] === provenance?.identity_patch_sha256, 'v1 patch labels differ');
  } else {
    invariant(labels['io.frwhoop.algorithm.roles'] === 'frwhoop-physiology-2,frwhoop-server-2-history',
      'v2 algorithm-role label differs');
  }
  invariant(labels['io.frwhoop.heartbeat.contract'] === 'physiology_worker_heartbeats-v1' &&
    labels['io.frwhoop.build.image'] === BUILD_IMAGE && labels['io.frwhoop.runtime.image'] === RUNTIME_IMAGE &&
    labels['io.frwhoop.image.platform'] === PLATFORM, `${role} platform/base/heartbeat labels differ`);
  return {
    platform: PLATFORM,
    manifestDigest: expectedDigest,
    configDigest: expectedConfig,
    indexJsonSha256: sha256(indexBytes),
    sourceRevision,
    labels: Object.fromEntries(Object.entries(labels).sort()),
  };
}

export function parseAndroidBadging(text) {
  const first = text.split('\n').find(line => line.startsWith('package: '));
  const match = first?.match(/name='([^']+)' versionCode='([^']+)' versionName='([^']+)'/);
  invariant(match, 'aapt2 package identity missing');
  const min = text.match(/^minSdkVersion:'([^']+)'$/m), target = text.match(/^targetSdkVersion:'([^']+)'$/m);
  invariant(min && target, 'aapt2 SDK identity missing');
  return { applicationId: match[1], versionCode: Number(match[2]), versionName: match[3],
    minSdk: Number(min[1]), targetSdk: Number(target[1]) };
}
export function parseAndroidReleaseMetadata(text, sourceRevision) {
  const blocks = [...text.matchAll(/^\s*E: meta-data[^\n]*\n((?:\s+A:[^\n]*\n?)+)/gm)].map(match => match[1]);
  const source = blocks.find(block => block.includes('"com.noop.release.source_revision"'));
  const hosted = blocks.find(block => block.includes('"com.noop.release.final_hosted_compute"'));
  invariant(source && source.includes(`"${sourceRevision}"`), 'APK embedded source revision differs');
  invariant(hosted && (/=true\b/.test(hosted) || hosted.includes('(Raw: "true")')), 'APK final-hosted marker differs');
  return { sourceRevision, finalHostedCompute: true };
}

function sourceBytes(repo, commit, filename) {
  return git(repo, 'show', `${commit}:${filename}`);
}
function sourceContract(repo, commit) {
  const files = CONTRACT_FILES.map(filename => {
    const bytes = sourceBytes(repo, commit, filename);
    return { path: filename, sizeBytes: bytes.length, sha256: sha256(bytes) };
  });
  const text = filename => sourceBytes(repo, commit, filename).toString('utf8');
  for (const [filename, tokens] of Object.entries({
    'android/app/build.gradle.kts': ['NOOP_SOURCE_REVISION', 'noopSourceRevision'],
    'android/app/src/main/AndroidManifest.xml': ['com.noop.release.source_revision', 'com.noop.release.final_hosted_compute'],
    'project.yml': ['NOOPSourceRevision: $(NOOP_SOURCE_REVISION)', 'NOOPFinalHostedCompute: true'],
    'scoring-service/Dockerfile': ['io.frwhoop.algorithm.roles=', 'io.frwhoop.heartbeat.contract='],
    'infra/vps/templates/Dockerfile.baseline': ['io.frwhoop.algorithm.version=', 'io.frwhoop.heartbeat.contract='],
    'scoring-service/service/src/main/kotlin/com/frwhoop/scoring/ScoringConfig.kt':
      ['SCORING_WORKER_SOURCE_REVISION'],
    'scoring-service/service/src/main/kotlin/com/frwhoop/scoring/health/HeartbeatReporter.kt':
      ['physiology_worker_heartbeats', 'source_revision', 'algorithm_version'],
    'supabase/migrations/20260919020000_physiology_worker_heartbeats.sql':
      ['physiology_worker_heartbeats', 'source_revision', 'algorithm_version'],
  })) for (const token of tokens) invariant(text(filename).includes(token), `${filename} lacks release contract ${token}`);
  const gradle = text('android/app/build.gradle.kts'), project = text('project.yml');
  const androidVersion = gradle.match(/versionName\s*=\s*"([^"]+)"/)?.[1];
  const androidBuild = Number(gradle.match(/versionCode\s*=\s*([0-9]+)/)?.[1]);
  const appleVersion = project.match(/MARKETING_VERSION:\s*"([^"]+)"/)?.[1];
  const appleBuild = project.match(/CURRENT_PROJECT_VERSION:\s*"([0-9]+)"/)?.[1];
  invariant(androidVersion && Number.isSafeInteger(androidBuild) && appleVersion && appleBuild, 'mobile build identity is unavailable');
  return { files, versions: { androidVersion, androidBuild, appleVersion, appleBuild } };
}

function validateInput(input) {
  exactKeys(input, ['schemaVersion', 'sourceSha', 'expected', 'artifacts'], 'release input');
  invariant(input.schemaVersion === 1 && REVISION.test(input.sourceSha), 'release input source SHA differs');
  exactKeys(input.expected, ['iosAppGroup', 'iosBundleIdentifiers'], 'release expected identities');
  invariant(typeof input.expected.iosAppGroup === 'string' && input.expected.iosAppGroup.startsWith('group.'), 'iOS App Group required');
  invariant(Array.isArray(input.expected.iosBundleIdentifiers) && input.expected.iosBundleIdentifiers.length === 4 &&
    new Set(input.expected.iosBundleIdentifiers).size === 4, 'four iOS bundle identities required');
  exactKeys(input.artifacts, ['selectedV1', 'shadowV2', 'android', 'ios', 'edge', 'migrations', 'deployment'], 'release artifacts');
  exactKeys(input.artifacts.selectedV1, ['oci', 'buildMetadata', 'provenance'], 'selected v1 input');
  exactKeys(input.artifacts.shadowV2, ['oci', 'buildMetadata'], 'shadow v2 input');
  exactKeys(input.artifacts.android, ['apk', 'outputMetadata', 'aapt2', 'apksigJar'], 'Android input');
  exactKeys(input.artifacts.ios, ['ipa'], 'iOS input');
  exactKeys(input.artifacts.edge, ['bundle', 'manifest'], 'Edge input');
  exactKeys(input.artifacts.migrations, ['manifest'], 'migration input');
  exactKeys(input.artifacts.deployment, ['bundle', 'manifest'], 'deployment input');
  for (const group of Object.values(input.artifacts)) for (const [key, value] of Object.entries(group)) {
    if (!['aapt2', 'apksigJar'].includes(key)) relative(value);
  }
  for (const key of ['aapt2', 'apksigJar']) {
    const value = input.artifacts.android[key];
    invariant(path.isAbsolute(value) && fs.statSync(value).isFile(), `Android ${key} must be an absolute regular file`);
  }
  return input;
}
function validateV1Provenance(value, repo, sourceRevision) {
  invariant(value?.baseline_commit === BASELINE_COMMIT && value.algorithm_version === 'frwhoop-server-1' &&
    value.canonical_math_changed === false && value.build_status === 'built_and_repository_tests_passed' &&
    value.database_integration_environment === true && value.deployment_status === 'not_deployed',
    'v1 build/test provenance is incomplete');
  invariant(value?.image_build?.platform === PLATFORM && value.image_build.build_image === BUILD_IMAGE &&
    value.image_build.runtime_image === RUNTIME_IMAGE, 'v1 image inputs differ');
  invariant(SHA256.test(value.transport_patch_sha256) && SHA256.test(value.identity_patch_sha256) &&
    SHA256.test(value.frozen_files_sha256) && SHA256.test(value.baseline_result_mapper_sha256),
    'v1 source provenance hashes are invalid');
  invariant(value.transport_patch_sha256 === sha256(sourceBytes(repo, sourceRevision,
    'scoring-service/legacy-baseline/transport.patch')) &&
    value.identity_patch_sha256 === sha256(sourceBytes(repo, sourceRevision,
      'scoring-service/legacy-baseline/runtime-identity.patch')), 'v1 committed patch hashes differ');
  return value;
}
function validateMigrationManifest(value, commit, tree) {
  invariant(value?.schemaVersion === 1 && value.kind === 'frwhoop-immutable-migration-manifest' &&
    value.candidate?.sha === commit && value.candidate.tree === tree, 'migration manifest source differs');
  invariant(SHA256.test(value.schemaFingerprintSha256) && SHA256.test(value.manifestFingerprintSha256),
    'migration fingerprints are invalid');
  const { manifestFingerprintSha256, ...unsigned } = value;
  invariant(sha256(canonicalJSON(unsigned)) === manifestFingerprintSha256, 'migration manifest fingerprint differs');
  invariant(value.catalog?.entryCount === 124 && value.catalog.baselineEntryCount === 117 &&
    value.catalog.pendingEntryCount === 7 && value.counts?.total === 124 &&
    value.counts.applied === 117 && value.counts.pending === 7, 'migration counts differ');
  return { schemaFingerprintSha256: value.schemaFingerprintSha256,
    manifestFingerprintSha256, total: 124, applied: 117, pending: 7 };
}
function validateEdgeManifest(value, commit, tree, bundleIdentity) {
  exactKeys(value, ['schemaVersion', 'kind', 'source', 'bundle', 'includedRoots', 'exclusionPolicy',
    'deployableFunctions', 'files'], 'Edge manifest');
  exactKeys(value.source, ['commit', 'tree'], 'Edge source');
  exactKeys(value.bundle, ['filename', 'sha256', 'sizeBytes'], 'Edge bundle');
  invariant(value?.schemaVersion === 1 && value.kind === 'frwhoop-edge-bundle' &&
    value.source?.commit === commit && value.source.tree === tree, 'Edge bundle source differs');
  invariant(JSON.stringify([...value.deployableFunctions].sort()) === JSON.stringify(EDGE_FUNCTIONS), 'Edge function roles differ');
  invariant(value.bundle?.sha256 === bundleIdentity.sha256 && value.bundle.sizeBytes === bundleIdentity.sizeBytes &&
    value.bundle.filename === path.basename(bundleIdentity.path), 'Edge bundle identity differs');
  invariant(Array.isArray(value.files) && value.files.some(file => file.path === 'supabase/functions/deno.lock') &&
    value.files.some(file => file.path === 'supabase/functions/scores/index.ts'), 'Edge lockfile/scores source missing');
  return { deployableFunctions: EDGE_FUNCTIONS, fileCount: value.files.length };
}
function validateDeploymentManifest(value, commit, tree, bundleIdentity) {
  exactKeys(value, ['schemaVersion', 'kind', 'source', 'bundle', 'includedRoots',
    'requiredCapabilities', 'files'], 'deployment manifest');
  invariant(value.schemaVersion === 1 && value.kind === 'frwhoop-deployment-source-bundle' &&
    value.source?.commit === commit && value.source.tree === tree, 'deployment bundle source differs');
  invariant(value.bundle?.sha256 === bundleIdentity.sha256 && value.bundle.sizeBytes === bundleIdentity.sizeBytes &&
    value.bundle.filename === path.basename(bundleIdentity.path), 'deployment bundle identity differs');
  invariant(Array.isArray(value.files) && value.files.length > 0 &&
    value.files.some(file => file.path === 'infra/vps/scripts/deploy-scoring-service.sh') &&
    value.files.some(file => file.path === 'infra/vps/scripts/apply-migrations.sh') &&
    value.files.some(file => file.path === 'infra/vps/scripts/remote/verify-scoring-runtime.sh') &&
    value.files.some(file => file.path === 'Tools/release/release-artifact-manifest.mjs'),
  'deployment bundle lacks required release/rollback sources');
  return { requiredCapabilities: value.requiredCapabilities, fileCount: value.files.length };
}
function inspectAndroid(repo, commit, root, value, versions) {
  const apk = fileIdentity(root, value.apk), metadataFile = fileIdentity(root, value.outputMetadata);
  const apkPath = artifactFile(root, value.apk), aapt2 = fs.realpathSync(value.aapt2);
  const badging = run(aapt2, ['dump', 'badging', apkPath]).toString('utf8');
  const xml = run(aapt2, ['dump', 'xmltree', apkPath, '--file', 'AndroidManifest.xml']).toString('utf8');
  const identity = parseAndroidBadging(badging), release = parseAndroidReleaseMetadata(xml, commit);
  invariant(identity.applicationId === 'com.noop.whoop.staging' &&
    identity.versionCode === versions.androidBuild && identity.versionName === `${versions.androidVersion}-staging` &&
    identity.minSdk === 26 && identity.targetSdk === 34, 'Android package/build identity differs');
  const output = boundedJSON(artifactFile(root, value.outputMetadata));
  invariant(output?.version === 3 && output.applicationId === identity.applicationId && output.variantName === 'fullRelease' &&
    output.elements?.length === 1 && output.elements[0].outputFile === path.basename(value.apk) &&
    output.elements[0].versionCode === identity.versionCode && output.elements[0].versionName === identity.versionName,
    'Android Gradle output metadata differs');
  const helper = path.join(repo, 'Tools/release/VerifyApk.java'), apksig = fs.realpathSync(value.apksigJar);
  const signature = parseJSONBytes(run('java', ['-cp', apksig, helper, apkPath]), 'APK signature inspection');
  invariant(signature.verified === true && signature.certificateSha256?.length === 1, 'APK signature differs');
  const keyOutput = run('keytool', ['-list', '-v', '-keystore', path.join(repo, 'android/fork-debug.keystore'),
    '-storepass', 'android', '-alias', 'androiddebugkey']).toString('utf8');
  const expectedCertificate = keyOutput.match(/SHA256:\s*([0-9A-F:]+)/)?.[1]?.replaceAll(':', '').toLowerCase();
  invariant(SHA256.test(expectedCertificate) && signature.certificateSha256[0] === expectedCertificate,
    'APK signer is not the committed staging key');
  return { kind: 'android-staging-apk', file: apk, outputMetadata: metadataFile, package: identity, release, signature,
    tools: { aapt2: { sha256: hashFile(aapt2), version: run(aapt2, ['version']).toString('utf8').trim() },
      apksigJar: { sha256: hashFile(apksig) } } };
}
function inspectIOS(repo, commit, root, value, expected, versions) {
  const file = fileIdentity(root, value.ipa), filename = artifactFile(root, value.ipa);
  const inspection = parseJSONBytes(run('python3', [path.join(repo, 'Tools/release/inspect_ipa.py'), filename],
    { maxBuffer: 128 * 1024 * 1024 }), 'IPA inspection');
  invariant(Array.isArray(inspection.bundles) && inspection.bundles.length === 4, 'IPA must contain phone/widget/watch/complication bundles');
  const actualIDs = inspection.bundles.map(bundle => bundle.bundleIdentifier).sort();
  invariant(JSON.stringify(actualIDs) === JSON.stringify([...expected.iosBundleIdentifiers].sort()), 'IPA bundle identifiers differ');
  const teams = new Set();
  for (const bundle of inspection.bundles) {
    invariant(bundle.version === versions.appleVersion && bundle.build === versions.appleBuild &&
      bundle.finalHostedCompute === true, `IPA version/final-hosted marker differs: ${bundle.bundleIdentifier}`);
    const isPhone = bundle.path.split('/').length === 2;
    invariant(isPhone ? bundle.sourceRevision === commit : bundle.sourceRevision == null,
      `IPA source revision placement differs: ${bundle.bundleIdentifier}`);
    invariant(bundle.signature?.identifier === bundle.bundleIdentifier && bundle.signature.cdhash &&
      bundle.profile?.applicationIdentifier?.endsWith(`.${bundle.bundleIdentifier}`) &&
      bundle.profile.deviceCount > 0 && bundle.profile.getTaskAllow === true,
      `IPA signature/profile differs: ${bundle.bundleIdentifier}`);
    invariant(JSON.stringify(bundle.signature.entitlements?.applicationGroups ?? []) ===
      JSON.stringify([expected.iosAppGroup]) &&
      JSON.stringify(bundle.profile.applicationGroups ?? []) === JSON.stringify([expected.iosAppGroup]),
      `IPA App Group differs: ${bundle.bundleIdentifier}`);
    teams.add(bundle.signature.teamIdentifier); teams.add(bundle.profile.teamIdentifier);
  }
  invariant(teams.size === 1, 'IPA bundles do not share one signing team');
  return { kind: 'ios-development-ipa', file, version: versions.appleVersion, build: versions.appleBuild,
    sourceRevision: commit, signingTeam: [...teams][0], appGroup: expected.iosAppGroup,
    bundles: inspection.bundles.sort((a, b) => a.bundleIdentifier.localeCompare(b.bundleIdentifier)) };
}
function roleContract(commit) {
  const heartbeat = { table: 'physiology_worker_heartbeats', contract: 'physiology_worker_heartbeats-v1',
    sourceRevision: commit, requiredProgress: ['last_poll_at', 'last_score_at'], processIdentityRequired: true };
  return {
    selectedV1: { imageArtifact: 'selectedV1', algorithmVersion: 'frwhoop-server-1',
      publicationRole: 'selected', heartbeat },
    shadowV2: { imageArtifact: 'shadowV2', algorithmVersion: 'frwhoop-physiology-2',
      publicationRole: 'shadow', heartbeat },
    historyV2: { imageArtifact: 'shadowV2', algorithmVersion: 'frwhoop-server-2-history',
      publicationRole: 'shadow-history', command: ['--history'], heartbeat },
  };
}

export function prepareReleaseManifest({ repoRoot, artifactRoot, input }) {
  const repo = fs.realpathSync(repoRoot), root = fs.realpathSync(artifactRoot), value = validateInput(input);
  const commit = value.sourceSha;
  invariant(git(repo, 'cat-file', '-t', commit).toString().trim() === 'commit', 'source commit is unavailable locally');
  const tree = git(repo, 'rev-parse', `${commit}^{tree}`).toString().trim();
  invariant(REVISION.test(tree), 'source tree is invalid');
  const contract = sourceContract(repo, commit);

  const v1Input = value.artifacts.selectedV1, v2Input = value.artifacts.shadowV2;
  const v1File = fileIdentity(root, v1Input.oci), v1MetadataFile = fileIdentity(root, v1Input.buildMetadata);
  const v1ProvenanceFile = fileIdentity(root, v1Input.provenance);
  const v1Metadata = boundedJSON(artifactFile(root, v1Input.buildMetadata));
  const v1Provenance = validateV1Provenance(boundedJSON(artifactFile(root, v1Input.provenance)), repo, commit);
  const v1OCI = inspectOCI(artifactFile(root, v1Input.oci), 'selected-v1', commit, v1Metadata, v1Provenance);
  const v2File = fileIdentity(root, v2Input.oci), v2MetadataFile = fileIdentity(root, v2Input.buildMetadata);
  const v2Metadata = boundedJSON(artifactFile(root, v2Input.buildMetadata));
  const v2OCI = inspectOCI(artifactFile(root, v2Input.oci), 'shadow-v2', commit, v2Metadata);

  const edgeInput = value.artifacts.edge, edgeBundlePath = artifactFile(root, edgeInput.bundle);
  const edgeBundle = fileIdentity(root, edgeInput.bundle);
  const edgeManifestFile = fileIdentity(root, edgeInput.manifest);
  const edgeManifest = boundedJSON(artifactFile(root, edgeInput.manifest));
  const verifiedEdge = verifyEdgeSourceBundle(path.dirname(edgeBundlePath), { expectedBundleSha256: edgeBundle.sha256 });
  invariant(canonicalJSON(verifiedEdge) === canonicalJSON(edgeManifest), 'Edge verified manifest differs');
  const edge = validateEdgeManifest(edgeManifest, commit, tree, edgeBundle);
  const migrationInput = value.artifacts.migrations, migrationFile = fileIdentity(root, migrationInput.manifest);
  const migrations = validateMigrationManifest(boundedJSON(artifactFile(root, migrationInput.manifest)), commit, tree);
  const deploymentInput = value.artifacts.deployment;
  const deploymentBundlePath = artifactFile(root, deploymentInput.bundle);
  const deploymentFile = fileIdentity(root, deploymentInput.bundle);
  const deploymentManifestFile = fileIdentity(root, deploymentInput.manifest);
  const deploymentManifest = boundedJSON(artifactFile(root, deploymentInput.manifest));
  const verifiedDeployment = verifyDeploymentSourceBundle(path.dirname(deploymentBundlePath),
    { expectedBundleSha256: deploymentFile.sha256 });
  invariant(canonicalJSON(verifiedDeployment) === canonicalJSON(deploymentManifest),
    'deployment verified manifest differs');
  const deployment = validateDeploymentManifest(deploymentManifest, commit, tree, deploymentFile);

  const unsigned = {
    schemaVersion: 1,
    kind: 'frwhoop-phone-test-artifact-manifest',
    source: { commit, tree, contractFiles: contract.files },
    roles: roleContract(commit),
    artifacts: {
      selectedV1: { kind: 'oci-image', file: v1File, buildMetadata: v1MetadataFile,
        provenance: v1ProvenanceFile, image: v1OCI, algorithmVersion: 'frwhoop-server-1' },
      shadowV2: { kind: 'oci-image', file: v2File, buildMetadata: v2MetadataFile,
        image: v2OCI, algorithmVersions: ['frwhoop-physiology-2', 'frwhoop-server-2-history'] },
      android: inspectAndroid(repo, commit, root, value.artifacts.android, contract.versions),
      ios: inspectIOS(repo, commit, root, value.artifacts.ios, value.expected, contract.versions),
      edge: { kind: 'edge-source-bundle', file: edgeBundle, manifest: edgeManifestFile, ...edge },
      migrations: { kind: 'migration-manifest', file: migrationFile, ...migrations },
      deployment: { kind: 'deployment-verification-bundle', file: deploymentFile,
        manifest: deploymentManifestFile, ...deployment },
    },
    operationalState: {
      registryPublication: 'BLOCKED',
      deployment: 'NOT_PERFORMED',
      productionMigrations: 'NOT_APPLIED',
      phoneInstallation: 'NOT_PERFORMED',
      heartbeatVerification: 'BLOCKED_UNTIL_AUTHORIZED_DEPLOYMENT',
    },
  };
  return { ...unsigned, manifestFingerprintSha256: sha256(canonicalJSON(unsigned)) };
}

function identities(value) {
  const result = [];
  const visit = current => {
    if (isObject(current) && typeof current.path === 'string' && Number.isSafeInteger(current.sizeBytes) && SHA256.test(current.sha256)) {
      result.push(current); return;
    }
    if (Array.isArray(current)) current.forEach(visit);
    else if (isObject(current)) Object.values(current).forEach(visit);
  };
  visit(value.artifacts);
  const unique = new Map();
  for (const item of result) {
    const prior = unique.get(item.path);
    if (prior) invariant(canonicalJSON(prior) === canonicalJSON(item), `artifact identity is inconsistent: ${item.path}`);
    unique.set(item.path, item);
  }
  return [...unique.values()];
}
export function verifyReleaseManifest({ repoRoot, artifactRoot, manifest }) {
  invariant(manifest?.schemaVersion === 1 && manifest.kind === 'frwhoop-phone-test-artifact-manifest' &&
    REVISION.test(manifest.source?.commit) && REVISION.test(manifest.source?.tree), 'release artifact manifest is invalid');
  const { manifestFingerprintSha256, ...unsigned } = manifest;
  invariant(SHA256.test(manifestFingerprintSha256) &&
    sha256(canonicalJSON(unsigned)) === manifestFingerprintSha256, 'release artifact manifest fingerprint differs');
  const repo = fs.realpathSync(repoRoot), root = fs.realpathSync(artifactRoot);
  invariant(git(repo, 'rev-parse', `${manifest.source.commit}^{tree}`).toString().trim() === manifest.source.tree,
    'release source tree differs');
  invariant(canonicalJSON(sourceContract(repo, manifest.source.commit).files) === canonicalJSON(manifest.source.contractFiles),
    'release source contracts differ');
  for (const item of identities(manifest)) sameIdentity(fileIdentity(root, item.path), item, item.path);
  const v1 = manifest.artifacts.selectedV1, v2 = manifest.artifacts.shadowV2;
  const v1Provenance = validateV1Provenance(boundedJSON(artifactFile(root, v1.provenance.path)),
    repo, manifest.source.commit);
  invariant(canonicalJSON(inspectOCI(artifactFile(root, v1.file.path), 'selected-v1', manifest.source.commit,
    boundedJSON(artifactFile(root, v1.buildMetadata.path)), v1Provenance)) === canonicalJSON(v1.image), 'v1 OCI inspection differs');
  invariant(canonicalJSON(inspectOCI(artifactFile(root, v2.file.path), 'shadow-v2', manifest.source.commit,
    boundedJSON(artifactFile(root, v2.buildMetadata.path)))) === canonicalJSON(v2.image), 'v2 OCI inspection differs');
  validateMigrationManifest(boundedJSON(artifactFile(root, manifest.artifacts.migrations.file.path)),
    manifest.source.commit, manifest.source.tree);
  validateEdgeManifest(boundedJSON(artifactFile(root, manifest.artifacts.edge.manifest.path)),
    manifest.source.commit, manifest.source.tree, manifest.artifacts.edge.file);
  const edgeManifest = boundedJSON(artifactFile(root, manifest.artifacts.edge.manifest.path));
  const verifiedEdge = verifyEdgeSourceBundle(path.dirname(artifactFile(root, manifest.artifacts.edge.file.path)),
    { expectedBundleSha256: manifest.artifacts.edge.file.sha256 });
  invariant(canonicalJSON(verifiedEdge) === canonicalJSON(edgeManifest), 'Edge verified manifest differs');
  const deploymentManifest = boundedJSON(artifactFile(root, manifest.artifacts.deployment.manifest.path));
  validateDeploymentManifest(deploymentManifest, manifest.source.commit, manifest.source.tree,
    manifest.artifacts.deployment.file);
  const verifiedDeployment = verifyDeploymentSourceBundle(
    path.dirname(artifactFile(root, manifest.artifacts.deployment.file.path)),
    { expectedBundleSha256: manifest.artifacts.deployment.file.sha256 });
  invariant(canonicalJSON(verifiedDeployment) === canonicalJSON(deploymentManifest),
    'deployment verified manifest differs');
  invariant(canonicalJSON(manifest.roles) === canonicalJSON(roleContract(manifest.source.commit)), 'worker role/heartbeat contract differs');
  return manifest;
}

function usage() {
  return 'usage: release-artifact-manifest.mjs prepare --repo-root PATH --artifact-root PATH --inputs JSON --output JSON | verify --repo-root PATH --artifact-root PATH --manifest JSON';
}
function argumentsFor(argv, keys) {
  invariant(argv.length === keys.length * 2, usage());
  const result = {};
  for (let index = 0; index < argv.length; index += 2) {
    invariant(keys.includes(argv[index]) && !(argv[index] in result) && argv[index + 1], usage());
    result[argv[index]] = argv[index + 1];
  }
  invariant(keys.every(key => key in result), usage());
  return result;
}
function atomicWrite(filename, value) {
  const resolved = path.resolve(filename), bytes = Buffer.from(JSON.stringify(sorted(value), null, 2) + '\n');
  fs.mkdirSync(path.dirname(resolved), { recursive: true });
  const temporary = path.join(path.dirname(resolved), `.${path.basename(resolved)}.${process.pid}.tmp`);
  try { fs.writeFileSync(temporary, bytes, { flag: 'wx', mode: 0o644 }); fs.renameSync(temporary, resolved); }
  finally { fs.rmSync(temporary, { force: true }); }
}
export function runCLI(argv) {
  const [mode, ...rest] = argv;
  if (mode === 'prepare') {
    const args = argumentsFor(rest, ['--repo-root', '--artifact-root', '--inputs', '--output']);
    const manifest = prepareReleaseManifest({ repoRoot: args['--repo-root'], artifactRoot: args['--artifact-root'],
      input: boundedJSON(path.resolve(args['--inputs'])) });
    atomicWrite(args['--output'], manifest);
    process.stdout.write(JSON.stringify({ status: 'ARTIFACTS_BOUND_OFFLINE', output: path.resolve(args['--output']),
      fingerprint: manifest.manifestFingerprintSha256 }) + '\n');
    return manifest;
  }
  if (mode === 'verify') {
    const args = argumentsFor(rest, ['--repo-root', '--artifact-root', '--manifest']);
    const manifest = boundedJSON(path.resolve(args['--manifest']));
    verifyReleaseManifest({ repoRoot: args['--repo-root'], artifactRoot: args['--artifact-root'], manifest });
    process.stdout.write(JSON.stringify({ status: 'ARTIFACT_MANIFEST_VERIFIED',
      fingerprint: manifest.manifestFingerprintSha256 }) + '\n');
    return manifest;
  }
  invariant(false, usage());
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { runCLI(process.argv.slice(2)); }
  catch (error) { process.stderr.write(`${error instanceof Error ? error.message : 'NOT_READY: unknown artifact error'}\n`); process.exitCode = 1; }
}
